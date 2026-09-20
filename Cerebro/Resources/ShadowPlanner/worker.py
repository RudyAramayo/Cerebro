#!/usr/bin/env python3
"""Local stdio-only Drake shadow IK. No sockets, arm APIs or actuator imports.

All positions are MODEL coordinates. Scan, live observations and ghost poses
stay distinct. Every response permanently disables hardware.
"""
import hashlib
import json
import math
import os
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
sys.path.insert(0, str(Path(__file__).parent))
from clearance import ScanClearance

PROTOCOL = "rob-shadow-ik/2"
MAX_BYTES = 65536


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
        self.arm = "left"
        self.arm_indices = {side: [self.joints[f"{side}_joint{i}"].position_start() for i in range(1, 8)] for side in ("left", "right")}
        self.indices = self.arm_indices[self.arm]
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
        # Every solve pins all inactive positions explicitly. Joint Lock would
        # retain old positions when a visual correction changes the seed.
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
        self.arm_tracking = {}
        self.clearance = ScanClearance(self, directory, root)
        self.collision = self.clearance.check(self.q)
        self.vision_required = True
        self.observation_path = os.environ.get("ROB_SHADOW_OBSERVATION_PATH")
        self.visual = dict(status="unavailable", detail="Waiting for live markerless OAK-D observations", arms={})
        self.visual_age = None
        self.observed = {}
        self.applied_observations = {}
        self.observation_key = None
        self.corrected = False

    def select_arm(self, arm):
        if arm not in self.arm_indices:
            raise ValueError("Invalid arm")
        keys = ("tracking_id", "alignment", "clutch", "last_sample_id", "last_input_time", "previous_controller")
        self.arm_tracking[self.arm] = {key: getattr(self, key, None) for key in keys}
        self.arm = arm
        values = self.arm_tracking.get(arm, {})
        for key in keys:
            setattr(self, key, values.get(key, 0 if key in ("last_sample_id", "last_input_time") else None))
        self.indices = self.arm_indices[arm]
        self.fixed_indices = [i for i in range(len(self.q)) if i not in self.indices]
        self.tip = self.plant.GetFrameByName(arm + "_tool", self.model)

    def pause_all(self):
        self.clutch = None
        for state in self.arm_tracking.values():
            state["clutch"] = None

    def update_visual(self):
        self.corrected = False
        value = None
        if self.observation_path:
            try:
                path = Path(self.observation_path)
                if path.stat().st_size <= 32768:
                    value = json.loads(path.read_text(), parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite observation")))
            except (OSError, ValueError):
                pass
        self.visual_age = None
        if (not isinstance(value, dict) or value.get("schemaVersion") != 1
                or value.get("modelID") != self.reference["modelID"] or value.get("referenceID") != self.reference["referenceID"]
                or value.get("source") != "markerless_rgbd" or value.get("frame") != "base_link"):
            self.visual = dict(status="unavailable", detail="No current markerless depth fit for this model", arms={})
            if self.vision_required: self.pause_all()
            return
        if not isinstance(value.get("capturedAtMilliseconds"), (int, float)) or not isinstance(value.get("arms"), dict):
            self.visual = dict(status="unavailable", detail="Malformed markerless observation", arms={})
            self.pause_all()
            return
        age = self.wall() * 1000 - value.get("capturedAtMilliseconds", 0)
        if not math.isfinite(age) or not 0 <= age <= 750:
            self.visual = dict(status="stale", detail="Live depth observation expired; preview held", arms={})
            if self.vision_required: self.pause_all()
            return
        self.visual_age = age
        self.visual = value
        key = (value.get("camera"), value.get("sequence"), value["capturedAtMilliseconds"])
        for side in ("left", "right"):
            arm = value.get("arms", {}).get(side, {})
            if not isinstance(arm, dict):
                arm = {}; value["arms"][side] = arm
            try:
                positions = np.asarray(arm.get("positions", []), float)
                sigma = np.asarray(arm.get("standardDeviationRadians", []), float)
            except (ValueError, TypeError):
                positions = sigma = np.array([])
            residual = arm.get("residualMeters", 1)
            confirmed = (arm.get("status") == "confirmed" and value.get("status") in ("confirmed", "partial")
                         and positions.shape == (7,) and sigma.shape == (7,) and np.isfinite(positions).all()
                         and np.isfinite(sigma).all() and np.all(sigma >= 0) and max(sigma) < math.radians(5)
                         and isinstance(residual, (float, int)) and math.isfinite(residual) and 0 <= residual <= .012)
            if not confirmed:
                arm["status"] = "unobserved"
                if self.vision_required:
                    if self.arm == side: self.clutch = None
                    if side in self.arm_tracking: self.arm_tracking[side]["clutch"] = None
                continue
            indices = self.arm_indices[side]
            lower, upper = self.plant.GetPositionLowerLimits()[indices], self.plant.GetPositionUpperLimits()[indices]
            if np.any(positions < lower) or np.any(positions > upper):
                arm["status"] = "inconsistent"
                self.pause_all()
                continue
            changed = side not in self.applied_observations or max(abs(positions - self.applied_observations[side])) > math.radians(3)
            if self.vision_required and key != self.observation_key and changed:
                # Reconcile the model automatically, then require a new clutch.
                # An observation outside limits is displayed faithfully, not clamped.
                self.q[indices] = positions
                self.applied_observations[side] = positions.copy()
                self.corrected = True
                self.pause_all()
            self.observed[side] = positions
        self.observation_key = key
        if value.get("status") == "confirmed" and not all(value.get("arms", {}).get(s, {}).get("status") == "confirmed" for s in ("left", "right")):
            value["status"] = "partial"
            value["detail"] = "One or more joint estimates failed validation; preview held"

    def visual_ready(self, side):
        # Both arms must be known for live arm-arm clearance. Unseen cables and
        # unobserved environment remain outside this model check.
        return all(self.visual.get("arms", {}).get(s, {}).get("status") == "confirmed" for s in (side, "right" if side == "left" else "left")) and self.visual.get("status") == "confirmed"

    def motion_block(self):
        if self.vision_required and not self.visual_ready(self.arm):
            return "Live pose unconfirmed: " + self.visual.get("detail", "Both arms need fresh observable depth fits")
        if np.any(np.abs(self.q[self.indices]) > self.reference["provisionalCenteredLimitRadians"] + 1e-8):
            return self.arm + " arm reference exceeds centered ±120°; reconcile the measured pose before moving"
        return None

    def frame_poses(self, q):
        self.plant.SetPositions(self.context, q)
        return [dict(name=name, pose=pose_dict(self.plant.CalcRelativeTransform(
            self.context, self.plant.world_frame(), self.plant.GetFrameByName(name, self.model))))
                for name in self.frames]

    def tool(self):
        self.plant.SetPositions(self.context, self.q)
        return self.plant.CalcRelativeTransform(self.context, self.plant.world_frame(), self.tip)

    def response(self, request, status, detail, **extra):
        observed_q = self.q0.copy()
        observed_names = set()
        for side, positions in self.observed.items():
            if self.visual.get("arms", {}).get(side, {}).get("status") == "confirmed" and self.visual_age is not None:
                observed_q[self.arm_indices[side]] = positions
                observed_names.update(n for n in self.frames if n.startswith(side + "_") and self.clearance.is_arm(n))
        observed_frames = [f for f in self.frame_poses(observed_q) if f["name"] in observed_names]
        collision_fields = {}
        if self.collision.get("distance") is not None: collision_fields["clearanceMeters"] = self.collision["distance"]
        if self.collision.get("pair"): collision_fields["collisionPair"] = self.collision["pair"]
        if self.visual_age is not None: collision_fields["visualAgeMilliseconds"] = self.visual_age
        return dict(protocol=PROTOCOL, kind="response", controllerID=request["controllerID"],
                    sessionID=request["sessionID"], sequence=request["sequence"],
                    shadowID=request["command"]["shadowID"], requestID=request["command"]["requestID"], modelID=self.reference["modelID"],
                    referenceID=self.reference["referenceID"], status=status, detail=detail,
                    hardwareOutputEnabled=False, referenceSource="approved_scan_estimate",
                    arm=self.arm, collisionStatus="clear_model" if self.collision["clear"] else "blocked",
                    collisionDetail="25 mm rigid scan clearance. Adjacent mounts excluded; cables, payloads and environment unverified.",
                    visionStatus=self.visual.get("status", "unavailable"), visionDetail=self.visual.get("detail", "")[:600],
                    visionRequired=self.vision_required, observedFrames=observed_frames, frame="base_link",
                    referenceFrames=self.reference_frames, ghostFrames=self.frame_poses(self.q),
                    positions=self.q[self.indices].tolist(), solveMilliseconds=0, **collision_fields, **extra)

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
        allowed = {"action", "shadowID", "requestID", "modelID", "arm"}
        if action in ("align", "clutch", "pose"):
            allowed.add("tracking")
        if action == "clutch":
            allowed.add("translationScale")
        if action == "nudge":
            allowed.add("delta")
        if action == "start" or (action == "end" and "modelID" not in command):
            allowed.remove("modelID")
        if action == "start": allowed.add("visionRequired")
        if action not in ("start", "align", "clutch", "pose", "release", "nudge", "end", "refresh") or set(command) != allowed:
            raise ValueError("Invalid command fields")
        self.select_arm(command["arm"])
        age = self.wall() * 1000 - request["sentAtMilliseconds"]
        if not -100 <= age <= (5000 if action == "start" else 500):
            self.clutch = None
            return self.response(request, "paused", "Expired shadow request; release and re-engage")
        if self.owner is not None and request["sequence"] <= self.sequence:
            self.clutch = None
            return self.response(request, "paused", "Out-of-order shadow request")
        self.sequence = request["sequence"]
        if action == "start":
            if not isinstance(command["visionRequired"], bool): raise ValueError("Invalid observation mode")
            self.vision_required = command["visionRequired"]
            self.owner = owner
            self.q = self.q0.copy()
            self.alignment = self.clutch = self.tracking_id = None
            self.last_sample_id = 0
            self.arm_tracking = {}
            self.observed = {}; self.applied_observations = {}; self.observation_key = None
            self.update_visual()
            self.collision = self.clearance.check(self.q)
            return self.response(request, "ready", "Approved scan loaded. Select an arm and align its controller. Live mode waits for markerless confirmation of both arms.")
        if owner != self.owner or (action != "end" and command.get("modelID") != self.reference["modelID"]):
            self.clutch = None
            return self.response(request, "paused", "Preview session or model changed; start a new preview")
        try:
            self.update_visual()
            if action == "end":
                self.owner = self.alignment = self.clutch = None
                return self.response(request, "ended", "Shadow preview ended")
            if action == "release":
                self.clutch = None
                return self.response(request, "paused", "Ghost held. Release and re-engage this arm's grip to reposition your hand.")
            if action == "refresh":
                self.collision = self.clearance.check(self.q)
                return self.response(request, "paused" if self.corrected else "ready",
                                     "Visual correction applied; release and re-engage the grips" if self.corrected else self.visual.get("detail", "Markerless observation pending"))
            if action in ("clutch", "pose", "nudge"):
                reason = self.motion_block()
                if reason:
                    self.clutch = None
                    return self.response(request, "blocked", reason)
                if self.corrected and action == "pose":
                    return self.response(request, "paused", "Physical pose changed; visual correction applied. Release and re-engage.")
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
                return self.response(request, "aligned", "Forward aligned to ROB +X; up is +Z. Release, then hold this arm's grip.")
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
        reason = self.motion_block()
        if reason: return self.response(request, "blocked", reason)
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
                    and np.max(np.abs(candidate[self.fixed_indices] - before[self.fixed_indices])) < 1e-8):
                self.q = candidate
                actual = self.tool()
                distance = np.linalg.norm(actual.translation() - target.translation())
                angle = (target.rotation().inverse() @ actual.rotation()).ToAngleAxis().angle()
                if distance <= .00087 and angle <= .01501:
                    self.collision = self.clearance.transition(before, candidate)
                    if self.collision["clear"]:
                        status, detail = "solved", "Reachable with swept rigid-scan clearance. Cables, payload and environment remain unverified."
                    else:
                        self.q = before
                        detail = "Swept clearance blocked: " + " / ".join(self.collision.get("pair") or ["query budget exceeded"])
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
