"""Markerless torso yaw relative to the base, with camera pose and lean fitted.

No motor counts, home switch, commanded angle, or arm pose can confirm yaw.
The fixed scan frames are acquisition hypotheses only. This worker is separate
from arm shadow estimation so a moving body cannot silently change its frame.
"""
import json
import math
import sys
import time

import numpy as np
from scipy.optimize import least_squares
from scipy.spatial import cKDTree
from scipy.spatial.transform import Rotation

from markerless import MarkerlessEstimator, numerical_jacobian, rank_and_uncertainty


def angle_difference(a, b):
    return (a - b + math.pi) % (2 * math.pi) - math.pi


def rotation_left_jacobian(vector):
    x, y, z = vector
    cross = np.array([[0, -z, y], [z, 0, -x], [-y, x, 0]])
    angle = np.linalg.norm(vector)
    a, b = ((.5, 1 / 6) if angle < 1e-5 else
            ((1 - math.cos(angle)) / angle**2, (angle - math.sin(angle)) / angle**3))
    return np.eye(3) + a * cross + b * cross @ cross


class TorsoEstimator(MarkerlessEstimator):
    names = ["base_link", "left_track_link", "right_track_link", "lean_link", "rplidar_link", "torso_link"]

    def __init__(self, planner):
        super().__init__(planner)
        self.yaw_index = planner.joints["torso_yaw"].position_start()
        self.lean_index = planner.joints["body_lean"].position_start()
        self.prior_body = {}
        self.body_stable = {}
        self.streams = {}

    def fit_body(self, role, cloud, depth, intrinsics):
        tree = cKDTree(cloud)
        frame = "oak_optical_frame" if role == "face" else "belly_oak_optical_frame"
        previous = self.prior_body.get(role)
        yaw_seeds = ([previous[0], previous[0] + math.pi] if previous is not None
                     else np.linspace(-math.pi, math.pi, 8, endpoint=False))
        candidates = []
        for yaw in yaw_seeds:
            self.check_deadline()
            q = self.seed.copy(); q[self.yaw_index] = yaw
            if previous is not None: q[self.lean_index] = previous[1]
            self.p.plant.SetPositions(self.p.context, q)
            camera_seed = (self.cameras[role] if previous is not None and yaw == previous[0]
                           else self.p.plant.CalcRelativeTransform(self.p.context, self.p.plant.world_frame(),
                                self.p.plant.GetFrameByName(frame, self.p.model)).GetAsMatrix4())
            points, _, labels = self.points(q, self.names)
            mask = self.visible(points, camera_seed, depth, intrinsics)
            if np.sum(mask) < 100: continue

            cached = {}

            def evaluate(x):
                self.check_deadline()
                if "x" in cached and np.array_equal(x, cached["x"]):
                    return cached["values"]
                configuration = q.copy()
                configuration[self.yaw_index] = x[6]
                configuration[self.lean_index] = x[7]
                pts, normals, point_labels = self.points(configuration, self.names)
                camera = camera_seed.copy()
                camera[:3, :3] = Rotation.from_rotvec(x[3:6]).as_matrix() @ camera_seed[:3, :3]
                camera[:3, 3] += x[:3]
                local = (pts - camera[:3, 3]) @ camera[:3, :3]
                distances, closest = tree.query(local)
                values = pts, normals, point_labels, camera, local, distances, closest
                cached.update(x=x.copy(), values=values)
                return values

            def residual(x):
                *_, local, _, closest = evaluate(x)
                return np.clip(cloud[closest[mask]] - local[mask], -.1, .1).ravel()

            def jacobian(x):
                pts, _, point_labels, camera, local, _, closest = evaluate(x)
                rotation = camera[:3, :3]
                result = np.empty((len(pts), 3, 8))
                result[:, :, :3] = rotation.T
                left = rotation_left_jacobian(x[3:6])
                for i in range(3):
                    result[:, :, i + 3] = np.cross(left[:, i], pts - camera[:3, 3]) @ rotation
                for i, name, descendants in [(6, "torso_yaw", ["torso_link"]),
                        (7, "body_lean", ["lean_link", "rplidar_link", "torso_link"])]:
                    joint = self.p.joints[name]
                    transform = self.p.plant.CalcRelativeTransform(self.p.context, self.p.plant.world_frame(), joint.frame_on_child())
                    axis = transform.rotation().matrix() @ joint.revolute_axis()
                    result[:, :, i] = -np.cross(axis, pts - transform.translation()) @ rotation
                    result[~np.isin(point_labels, descendants), :, i] = 0
                result[np.abs(cloud[closest] - local) >= .1] = 0
                return result[mask].reshape(-1, 8)

            lean_min = self.p.plant.GetPositionLowerLimits()[self.lean_index]
            lean_max = self.p.plant.GetPositionUpperLimits()[self.lean_index]
            lower = [-.15] * 3 + [-.5] * 3 + [yaw - .8, lean_min]
            upper = [.15] * 3 + [.5] * 3 + [yaw + .8, lean_max]
            initial = np.array([0.] * 6 + [yaw, q[self.lean_index]])
            fit = least_squares(residual, np.clip(initial, np.array(lower) + 1e-8, np.array(upper) - 1e-8),
                                jac=jacobian, bounds=(lower, upper), loss="soft_l1", f_scale=.008, max_nfev=32)
            points, normals, labels, camera, local, distance, closest = evaluate(fit.x)
            visible = self.visible(points, camera, depth, intrinsics)
            inliers = visible & (distance < .018)
            base = np.isin(labels, ["base_link", "left_track_link", "right_track_link"])
            torso = labels == "torso_link"
            if (np.sum(inliers & base) < 35 or np.sum(inliers & torso) < 35
                    or np.sum(inliers) / max(1, np.sum(visible)) < .5):
                continue

            def normal_residual(x):
                _, ns, _, cam, loc, _, ids = evaluate(x)
                delta = (cloud[ids] - loc) @ cam[:3, :3].T
                return np.sum(delta[inliers] * ns[inliers], axis=1)

            error = float(np.sqrt(np.mean(distance[inliers] ** 2)))
            observed, sigma = rank_and_uncertainty(numerical_jacobian(normal_residual, fit.x), noise=max(.004, error))
            if (not observed or error > .012 or max(sigma[:3]) > .01 or max(sigma[3:6]) > .05
                    or sigma[6] > math.radians(2) or sigma[7] > math.radians(2)):
                continue
            candidates.append(dict(yaw=float(fit.x[6]), lean=float(fit.x[7]), uncertainty=float(sigma[6]),
                                   residual=error, camera=camera))
        if not candidates:
            raise ValueError("Torso yaw unconfirmed: need visible, distinctive base and torso surfaces")
        candidates.sort(key=lambda c: c["residual"])
        best = candidates[0]
        if any(abs(angle_difference(c["yaw"], best["yaw"])) > math.radians(8)
               and c["residual"] <= best["residual"] * 1.2 + .001 for c in candidates[1:]):
            raise ValueError("Torso yaw ambiguous: multiple rotations fit the camera equally well")
        consistent = (previous is not None and abs(angle_difference(best["yaw"], previous[0])) < math.radians(6)
                      and abs(best["lean"] - previous[1]) < math.radians(3))
        self.body_stable[role] = self.body_stable.get(role, 0) + 1 if consistent else 1
        self.prior_body[role] = (best["yaw"], best["lean"])
        self.cameras[role] = best["camera"]
        return dict(status="confirmed" if self.body_stable[role] >= 3 else "settling",
                    yawRadians=angle_difference(best["yaw"], 0), leanRadians=best["lean"],
                    standardDeviationRadians=best["uncertainty"], residualMeters=best["residual"])

    def process(self, frame):
        began = time.monotonic()
        role = frame.get("camera", "unknown")
        if self.streams.get(role) != frame.get("streamID"):
            self.prior_body.pop(role, None); self.cameras.pop(role, None); self.body_stable[role] = 0
            self.streams[role] = frame.get("streamID")
        # Initial global acquisition may only produce a search seed. Stale
        # acquisition results are never exposed as live position confirmation.
        self.deadline = began + (2.5 if role not in self.prior_body else .65)
        result = dict(schemaVersion=1, source="markerless_rgbd", frame="base_link",
                      modelID=self.p.reference["modelID"], referenceID=self.p.reference["referenceID"],
                      camera=role, streamID=frame.get("streamID", ""), sequence=frame.get("sequence", 0),
                      capturedAtMilliseconds=frame.get("capturedAtMilliseconds", 0),
                      status="unavailable", detail="Torso angle unavailable")
        try:
            cloud, depth, intrinsics = self.cloud(frame)
            result["torso"] = self.fit_body(role, cloud, depth, intrinsics)
            result["status"] = result["torso"]["status"]
            result["detail"] = "Camera-confirmed torso yaw" if result["status"] == "confirmed" else "Checking visual agreement"
        except (ValueError, RuntimeError, np.linalg.LinAlgError) as error:
            self.body_stable[role] = 0
            result.update(status="unavailable", detail=str(error)[:400])
        result["processingMilliseconds"] = (time.monotonic() - began) * 1000
        if time.time() * 1000 - result["capturedAtMilliseconds"] > 750:
            self.body_stable[role] = 0
            result.pop("torso", None)
            result.update(status="stale", detail="Torso observation expired during fitting")
        return result


def main():
    from worker import ShadowPlanner
    estimator = TorsoEstimator(ShadowPlanner())
    for line in iter(lambda: sys.stdin.buffer.readline(2_000_001), b""):
        if len(line) > 2_000_000 or not line.endswith(b"\n"):
            raise ValueError("Oversized depth frame")
        frame = json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
        print(json.dumps(estimator.process(frame), allow_nan=False, separators=(",", ":")), flush=True)


if __name__ == "__main__": main()
