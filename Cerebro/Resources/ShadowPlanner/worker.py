#!/usr/bin/env python3
"""Local stdio-only Drake shadow IK. No sockets, arm APIs or actuator imports.

All positions are MODEL coordinates. The reference is a scan estimate, never
live vision or vendor feedback. Every response permanently disables hardware.
"""
import hashlib
import json
import math
from pathlib import Path
import sys
import time
import xml.etree.ElementTree as ET

import numpy as np
from pydrake.common.eigen_geometry import Quaternion
from pydrake.math import RigidTransform, RotationMatrix
from pydrake.multibody.inverse_kinematics import InverseKinematics
from pydrake.multibody.parsing import Parser
from pydrake.multibody.plant import MultibodyPlant
from pydrake.solvers import SnoptSolver, Solve

PROTOCOL = "rob-shadow-ik/1"
MAX_BYTES = 32768


def pose_dict(transform):
    q = transform.rotation().ToQuaternion().wxyz()
    return dict(position=transform.translation().tolist(), quaternion=q[[1, 2, 3, 0]].tolist())


def pose_matrix(pose):
    if set(pose) != {"position", "quaternion"}:
        raise ValueError("Invalid pose fields")
    xyz, q = np.asarray(pose["position"], float), np.asarray(pose["quaternion"], float)
    if xyz.shape != (3,) or q.shape != (4,) or not np.isfinite(xyz).all() or not np.isfinite(q).all():
        raise ValueError("Invalid pose vector")
    if np.max(np.abs(xyz)) > 100 or abs(float(q @ q) - 1) >= .001:
        raise ValueError("Invalid position or quaternion")
    q /= np.linalg.norm(q)
    return RigidTransform(RotationMatrix(Quaternion(q[[3, 0, 1, 2]])), xyz)


class ShadowPlanner:
    def __init__(self, directory=None, monotonic=time.monotonic, wall=time.time):
        self.clock, self.wall = monotonic, wall
        directory = Path(directory or Path(__file__).parent)
        self.reference = json.loads((directory / "reference.json").read_text())
        model_path = directory / "model.urdf"
        if (self.reference.get("simulationOnly") is not True
                or hashlib.sha256(model_path.read_bytes()).hexdigest() != self.reference["modelID"]):
            raise ValueError("Shadow model hash or simulation-only marker is invalid")
        root = ET.parse(model_path).getroot()
        if root.findall(".//mesh") or root.findall(".//collision"):
            raise ValueError("This milestone uses a mesh-free kinematic model")
        self.plant = MultibodyPlant(0.0)
        self.model = Parser(self.plant).AddModels(str(model_path))[0]
        self.plant.WeldFrames(self.plant.world_frame(), self.plant.GetFrameByName("base_link", self.model))
        self.plant.Finalize()
        self.context = self.plant.CreateDefaultContext()
        self.joints = {j.get("name"): self.plant.GetJointByName(j.get("name"), self.model)
                       for j in root.findall("joint") if j.get("type") != "fixed"}
        self.frames = [link.get("name") for link in root.findall("link")]
        self.indices = [self.joints[f"left_joint{i}"].position_start() for i in range(1, 8)]
        self.fixed_indices = [i for i in range(self.plant.num_positions()) if i not in self.indices]
        self.q0 = self.plant.GetPositions(self.context).copy()
        for name, joint in self.joints.items():
            self.q0[joint.position_start()] = self.reference["positions"].get(name, 0)
        lower, upper = self.plant.GetPositionLowerLimits(), self.plant.GetPositionUpperLimits()
        # URDF endpoint serialization may differ by <1e-10 radians. This is
        # unrelated to the unresolved 0.417-degree right-arm reference overrun.
        if np.any(self.q0 < lower - 1e-10) or np.any(self.q0 > upper + 1e-10):
            raise ValueError("Scan reference exceeds source URDF bounds")
        self.q0 = np.clip(self.q0, lower, upper)
        self.plant.SetPositions(self.context, self.q0)
        for name, joint in self.joints.items():
            if not name.startswith("left_joint"):
                joint.Lock(self.context)
        self.tip = self.plant.GetFrameByName("left_tool", self.model)
        self.reference_frames = self.frame_poses(self.q0)
        self.q = self.q0.copy()
        self.owner = None
        self.sequence = 0
        self.tracking_id = None
        self.alignment = None
        self.clutch = None
        self.last_sample_id = 0
        self.last_input_time = 0

    def frame_poses(self, q):
        self.plant.SetPositions(self.context, q)
        return [dict(name=name, pose=pose_dict(self.plant.CalcRelativeTransform(
            self.context, self.plant.world_frame(), self.plant.GetFrameByName(name, self.model))))
                for name in self.frames]

    def tool(self):
        self.plant.SetPositions(self.context, self.q)
        return self.plant.CalcRelativeTransform(self.context, self.plant.world_frame(), self.tip)

    def response(self, request, status, detail, **extra):
        return dict(protocol=PROTOCOL, kind="response", controllerID=request["controllerID"],
                    sessionID=request["sessionID"], sequence=request["sequence"],
                    shadowID=request["command"]["shadowID"], requestID=request["command"]["requestID"], modelID=self.reference["modelID"],
                    referenceID=self.reference["referenceID"], status=status, detail=detail,
                    hardwareOutputEnabled=False, referenceSource="approved_scan_estimate",
                    collisionStatus="not_checked", frame="base_link",
                    referenceFrames=self.reference_frames, ghostFrames=self.frame_poses(self.q),
                    positions=self.q[self.indices].tolist(), solveMilliseconds=0, **extra)

    def tracking(self, request):
        sample = request["command"].get("tracking", {})
        if set(sample) != {"trackingID", "sampleID", "ageMilliseconds", "quality", "pose"}:
            raise ValueError("Missing tracking metadata")
        transit = max(0, self.wall() * 1000 - request["sentAtMilliseconds"])
        age = sample["ageMilliseconds"]
        if (sample["quality"] != "tracked" or not math.isfinite(age) or age < 0
                or age + transit > 150):
            raise ValueError("Tracking is stale or uncertain; release the grip before resuming")
        restarting_alignment = request["command"]["action"] == "align" and sample["trackingID"] != self.tracking_id
        if not isinstance(sample["sampleID"], int) or sample["sampleID"] <= (0 if restarting_alignment else self.last_sample_id):
            raise ValueError("Replayed tracking sample; wait for a fresh observation")
        value = pose_matrix(sample["pose"])
        self.last_sample_id = sample["sampleID"]
        return sample["trackingID"], value

    def handle(self, request):
        command = request.get("command", {})
        action = command.get("action")
        owner = (request.get("controllerID"), request.get("sessionID"), command.get("shadowID"))
        if (set(request) != {"protocol", "kind", "controllerID", "sessionID", "sequence", "sentAtMilliseconds", "command"}
                or request["protocol"] != PROTOCOL or request["kind"] != "request"
                or any(not isinstance(x, str) for x in owner)
                or not isinstance(request["sequence"], int) or request["sequence"] <= 0):
            raise ValueError("Invalid request envelope")
        allowed = {"action", "shadowID", "requestID", "modelID"}
        if action in ("align", "clutch", "pose"):
            allowed.add("tracking")
        if action == "clutch":
            allowed.add("translationScale")
        if action == "nudge":
            allowed.add("delta")
        if action == "start" or (action == "end" and "modelID" not in command):
            allowed.remove("modelID")
        if action not in ("start", "align", "clutch", "pose", "release", "nudge", "end") or set(command) != allowed:
            raise ValueError("Invalid command fields")
        age = self.wall() * 1000 - request["sentAtMilliseconds"]
        if not -100 <= age <= (5000 if action == "start" else 500):
            self.clutch = None
            return self.response(request, "paused", "Expired shadow request; release and re-engage")
        if self.owner is not None and request["sequence"] <= self.sequence:
            self.clutch = None
            return self.response(request, "paused", "Out-of-order shadow request")
        self.sequence = request["sequence"]
        if action == "start":
            self.owner = owner
            self.q = self.q0.copy()
            self.alignment = self.clutch = self.tracking_id = None
            self.last_sample_id = 0
            return self.response(request, "ready", "Left R-11 scan reference loaded. Align forward, then hold the left grip. Clearance is unverified.")
        if owner != self.owner or (action != "end" and command.get("modelID") != self.reference["modelID"]):
            self.clutch = None
            return self.response(request, "paused", "Preview session or model changed; start a new preview")
        try:
            if action == "end":
                self.owner = self.alignment = self.clutch = None
                return self.response(request, "ended", "Shadow preview ended")
            if action == "release":
                self.clutch = None
                return self.response(request, "paused", "Ghost held. Re-engage the left grip to reposition your hand.")
            if action == "nudge":
                self.clutch = None
                delta = np.asarray(command["delta"], float)
                if delta.shape != (3,) or not np.isfinite(delta).all() or np.max(np.abs(delta)) > .010000001 or np.count_nonzero(delta) != 1:
                    raise ValueError("Use one XYZ step of at most 10 mm")
                current = self.tool()
                return self.solve(request, RigidTransform(current.rotation(), current.translation() + delta))
            tracking_id, controller = self.tracking(request)
            if action == "align":
                forward = controller.rotation().matrix() @ np.array([0., 0., -1.])
                forward[1] = 0
                if np.linalg.norm(forward) < .5:
                    raise ValueError("Point the controller forward, approximately level, to align")
                forward /= np.linalg.norm(forward)
                up = np.array([0., 1., 0.])
                left = np.cross(up, forward)
                self.alignment = np.stack([forward, left, up])
                self.tracking_id = tracking_id
                self.clutch = None
                return self.response(request, "aligned", "Forward aligned to ROB +X; up is +Z. Release, then hold the left grip.")
            if tracking_id != self.tracking_id or self.alignment is None:
                self.alignment = self.clutch = None
                raise ValueError("Tracking origin changed; align forward again")
            now = self.clock()
            if action == "clutch":
                scale = command["translationScale"]
                if scale not in (.2, 1):
                    raise ValueError("Invalid translation scale")
                self.clutch = (controller, self.tool(), scale)
                self.previous_controller = controller
                self.last_input_time = now
                return self.response(request, "clutched", "Controller linked to the current ghost gripper without a jump")
            if self.clutch is None or now - self.last_input_time > .25:
                raise ValueError("Tracking interrupted; release and re-engage the grip")
            if (np.linalg.norm(controller.translation() - self.previous_controller.translation()) > .15
                    or (controller.rotation() @ self.previous_controller.rotation().inverse()).ToAngleAxis().angle() > .6):
                self.alignment = None
                raise ValueError("Tracking jumped; align forward again")
            self.last_input_time = now
            self.previous_controller = controller
            anchor, tool, scale = self.clutch
            rotation = self.alignment @ controller.rotation().matrix() @ anchor.rotation().matrix().T @ self.alignment.T @ tool.rotation().matrix()
            xyz = tool.translation() + scale * self.alignment @ (controller.translation() - anchor.translation())
            return self.solve(request, RigidTransform(RotationMatrix(rotation), xyz))
        except (ValueError, KeyError) as error:
            self.clutch = None
            return self.response(request, "paused", str(error))

    def solve(self, request, target):
        began = self.clock()
        before = self.q.copy()
        self.plant.SetPositions(self.context, before)
        ik = InverseKinematics(self.plant, self.context, with_joint_limits=True)
        variables, program = ik.q(), ik.prog()
        lower, upper = before.copy(), before.copy()
        limit = self.reference["provisionalCenteredLimitRadians"]
        lower[self.indices] = np.maximum(-limit, before[self.indices] - .15)
        upper[self.indices] = np.minimum(limit, before[self.indices] + .15)
        program.AddBoundingBoxConstraint(lower, upper, variables)
        ik.AddPositionConstraint(self.tip, np.zeros(3), self.plant.world_frame(),
                                 target.translation() - .0005, target.translation() + .0005)
        ik.AddOrientationConstraint(self.plant.world_frame(), target.rotation(), self.tip, RotationMatrix(), .015)
        program.AddQuadraticErrorCost(np.eye(len(before)), before, variables)
        program.SetInitialGuess(variables, before)
        program.SetSolverOption(SnoptSolver.id(), "Major iterations limit", 80)
        result = Solve(program)
        status, detail = "blocked", "Target is unreachable within this bounded step; ghost stays at its last solution"
        if result.is_success():
            candidate = result.GetSolution(variables)
            if (np.isfinite(candidate).all() and np.all(candidate >= lower - 1e-8)
                    and np.all(candidate <= upper + 1e-8)
                    and np.max(np.abs(candidate[self.fixed_indices] - self.q0[self.fixed_indices])) < 1e-8):
                self.q = candidate
                actual = self.tool()
                distance = np.linalg.norm(actual.translation() - target.translation())
                angle = (target.rotation().inverse() @ actual.rotation()).ToAngleAxis().angle()
                if distance <= .00087 and angle <= .01501:
                    status, detail = "solved", "Kinematically reachable. Cable travel and collision clearance remain unverified."
                else:
                    self.q = before
        elapsed = (self.clock() - began) * 1000
        # Slow results must not appear as current controller tracking.
        if elapsed > 250:
            self.q = before
            self.clutch = None
            status, detail = "paused", "Solver missed the preview deadline; release and re-engage"
        actual = self.tool()
        response = self.response(request, status, detail, target=pose_dict(target),
                                 positionErrorMeters=float(np.linalg.norm(actual.translation() - target.translation())),
                                 orientationErrorRadians=float((target.rotation().inverse() @ actual.rotation()).ToAngleAxis().angle()))
        response["solveMilliseconds"] = elapsed
        return response


def main():
    planner = ShadowPlanner()
    while True:
        line = sys.stdin.buffer.readline(MAX_BYTES + 2)
        if not line:
            return
        if len(line) > MAX_BYTES + 1 or not line.endswith(b"\n"):
            raise ValueError("Oversized or unterminated shadow frame")
        request = json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
        response = planner.handle(request)
        encoded = json.dumps(response, allow_nan=False, separators=(",", ":"))
        if len(encoded.encode()) > MAX_BYTES:
            raise ValueError("Oversized shadow response")
        print(encoded, flush=True)


if __name__ == "__main__":
    main()
