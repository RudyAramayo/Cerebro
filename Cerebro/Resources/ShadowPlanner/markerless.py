"""Markerless RGB-D articulated surface fitting; never consumes commanded q.

The approved scan is a hypothesis. Depth evidence, visibility, alternative
fits, and the data-only surface Jacobian decide what can be observed. Priors
and scan seeds never contribute to the observability test.
"""
import base64
import json
import math
import sys
import time

import numpy as np
from scipy.optimize import least_squares
from scipy.spatial import cKDTree
from scipy.spatial.transform import Rotation


def rank_and_uncertainty(jacobian, noise=.004):
    """Account for correlated neighboring depth pixels, not iid superprecision."""
    if jacobian.ndim != 2 or not np.isfinite(jacobian).all():
        return False, None
    _, singular, vt = np.linalg.svd(jacobian, full_matrices=False)
    if len(singular) != jacobian.shape[1] or singular[-1] < 1e-4 or singular[0] / singular[-1] > 150:
        return False, None
    sigma = noise * math.sqrt(max(1, len(jacobian) / 60))
    deviation = np.sqrt(np.diag((vt.T / singular**2) @ vt)) * sigma
    return bool(np.isfinite(deviation).all()), deviation


def numerical_jacobian(function, x, step=1e-4):
    return np.column_stack([(function(x + np.eye(len(x))[i] * step) - function(x - np.eye(len(x))[i] * step)) / (2 * step)
                            for i in range(len(x))])


class MarkerlessEstimator:
    def __init__(self, planner):
        self.p = planner
        self.surfaces = {}
        for s in planner.clearance.surfaces:
            count = len(s["points"])
            ids = np.linspace(0, count - 1, min(count, 160), dtype=int)
            self.surfaces[s["link"]] = (np.array(s["points"])[ids], np.array(s["normals"])[ids])
        self.seed = planner.q0.copy()
        self.cameras = {}
        self.stable = {"left": 0, "right": 0}
        self.prior = {}
        self.last_frames = {}
        self.deadline = None

    def check_deadline(self):
        if self.deadline is not None and time.monotonic() > self.deadline:
            raise ValueError("Markerless fit exceeded its computation budget; pose unconfirmed")

    def cloud(self, frame):
        if set(frame) != {"camera", "streamID", "sequence", "timestampNanoseconds", "capturedAtMilliseconds", "width", "height", "intrinsics", "depth"}:
            raise ValueError("Invalid depth frame fields")
        w, h = frame["width"], frame["height"]
        if frame["camera"] not in ("face", "belly") or not isinstance(w, int) or not isinstance(h, int) or not (16 <= w <= 512 and 16 <= h <= 512):
            raise ValueError("Invalid camera or dimensions")
        age = time.time() * 1000 - frame["capturedAtMilliseconds"]
        if not 0 <= age <= 400:
            raise ValueError("Stale camera frame")
        key = (frame["camera"], frame["streamID"])
        previous = self.last_frames.get(key, (0, 0))
        if (not isinstance(frame["sequence"], int) or frame["sequence"] <= previous[0]
                or not isinstance(frame["timestampNanoseconds"], int) or frame["timestampNanoseconds"] <= previous[1]):
            raise ValueError("Repeated or reordered camera frame")
        self.last_frames[key] = (frame["sequence"], frame["timestampNanoseconds"])
        if len(self.last_frames) > 8:
            self.last_frames = {key: self.last_frames[key]}
        data = base64.b64decode(frame["depth"], validate=True)
        if len(data) != w * h * 2:
            raise ValueError("Depth size mismatch")
        z = np.frombuffer(data, dtype="<u2").reshape(h, w).astype(float) / 1000
        intrinsics = np.asarray(frame["intrinsics"], float)
        if intrinsics.shape != (4,) or not np.isfinite(intrinsics).all():
            raise ValueError("Invalid intrinsics")
        fx, fy, cx, cy = intrinsics
        if fx <= 0 or fy <= 0 or not (0 <= cx < w and 0 <= cy < h):
            raise ValueError("Invalid intrinsics")
        v, u = np.indices(z.shape)
        valid = (z >= .15) & (z <= 3)
        # Depth discontinuities are unreliable correspondences at arm edges.
        for axis in (0, 1):
            valid &= np.abs(z - np.roll(z, 1, axis)) < .03
            valid &= np.abs(z - np.roll(z, -1, axis)) < .03
        valid[[0, -1], :] = False; valid[:, [0, -1]] = False
        cloud = np.column_stack(((u[valid] - cx) * z[valid] / fx, (v[valid] - cy) * z[valid] / fy, z[valid]))
        if len(cloud) < 150:
            raise ValueError("Insufficient aligned depth")
        return cloud, z, intrinsics

    def points(self, q, names):
        self.p.plant.SetPositions(self.p.context, q)
        points, normals, labels = [], [], []
        for name in names:
            surface, normal = self.surfaces[name]
            transform = self.p.plant.CalcRelativeTransform(self.p.context, self.p.plant.world_frame(), self.p.plant.GetFrameByName(name, self.p.model))
            points.append((transform @ surface.T).T)
            normals.append(normal @ transform.rotation().matrix().T)
            labels.extend([name] * len(surface))
        return np.vstack(points), np.vstack(normals), np.array(labels)

    @staticmethod
    def visible(points, camera, depth, intrinsics):
        local = (points - camera[:3, 3]) @ camera[:3, :3]
        positive = local[:, 2] > .15
        fx, fy, cx, cy = intrinsics
        z = np.maximum(.01, local[:, 2])
        u = np.rint(fx * local[:, 0] / z + cx).astype(int)
        v = np.rint(fy * local[:, 1] / z + cy).astype(int)
        valid = positive & (u >= 0) & (u < depth.shape[1]) & (v >= 0) & (v < depth.shape[0])
        sampled = depth[np.clip(v, 0, depth.shape[0] - 1), np.clip(u, 0, depth.shape[1] - 1)]
        # A nearer observed surface occludes the model; missing pixels supply no evidence.
        return valid & (sampled >= .15) & (sampled >= local[:, 2] - .04)

    def register_camera(self, role, cloud, depth, intrinsics):
        frame = "oak_optical_frame" if role == "face" else "belly_oak_optical_frame"
        self.p.plant.SetPositions(self.p.context, self.seed)
        initial = self.cameras.get(role, self.p.plant.CalcRelativeTransform(
            self.p.context, self.p.plant.world_frame(), self.p.plant.GetFrameByName(frame, self.p.model)).GetAsMatrix4())
        names = ["base_link", "left_track_link", "right_track_link", "torso_link", "lean_link", "rplidar_link"]
        points, normals, labels = self.points(self.seed, names)
        seen = self.visible(points, initial, depth, intrinsics)
        points, normals, labels = points[seen], normals[seen], labels[seen]
        tree = cKDTree(cloud)
        if len(points) < 100:
            raise ValueError("Camera cannot see enough of ROB's base and torso to register the scan")
        def transform(x):
            value = initial.copy()
            value[:3, :3] = Rotation.from_rotvec(x[3:]).as_matrix() @ initial[:3, :3]
            value[:3, 3] += x[:3]
            return value
        def residual(x, selection=None):
            self.check_deadline()
            camera = transform(x)
            local = (points - camera[:3, 3]) @ camera[:3, :3]
            distance, ids = tree.query(local)
            delta = (cloud[ids] - local) @ camera[:3, :3].T
            values = np.sum(delta * normals, axis=1)
            # A distant match must not masquerade as a zero normal residual.
            values = np.where(distance <= .06, values, np.minimum(distance, .15))
            return values if selection is None else values[selection]
        fit = least_squares(residual, np.zeros(6), bounds=([-.08]*3 + [-.2]*3, [.08]*3 + [.2]*3),
                            loss="soft_l1", f_scale=.008, max_nfev=25)
        camera = transform(fit.x)
        distance, _ = tree.query((points - camera[:3, 3]) @ camera[:3, :3])
        inliers = distance < .02
        # Both a base-fixed surface and torso are needed. Arms alone cannot
        # distinguish camera movement from joint movement (a gauge ambiguity).
        base_count = np.sum(inliers & np.isin(labels, ["base_link", "left_track_link", "right_track_link"]))
        torso_count = np.sum(inliers & (labels == "torso_link"))
        if base_count < 35 or torso_count < 35 or np.mean(inliers) < .45:
            raise ValueError("Markerless registration needs visible base and torso surfaces; camera pose is unconfirmed")
        error = float(np.sqrt(np.mean(residual(fit.x, inliers)**2)))
        observed, sigma = rank_and_uncertainty(numerical_jacobian(lambda x: residual(x, inliers), fit.x))
        if not observed or error > .01 or max(sigma[:3]) > .008 or max(sigma[3:]) > .04:
            raise ValueError("Camera-to-ROB registration is ambiguous or disagrees with the scan")
        self.cameras[role] = camera
        return camera, error

    def fit_arm(self, side, cloud, depth, intrinsics, camera, registration_error):
        indices = self.p.arm_indices[side]
        names = [n for n in self.surfaces if n.startswith(side + "_") and self.p.clearance.is_arm(n)]
        tree = cKDTree(cloud @ camera[:3, :3].T + camera[:3, 3])
        initial = self.seed[indices].copy()
        lower = self.p.plant.GetPositionLowerLimits()[indices]
        upper = self.p.plant.GetPositionUpperLimits()[indices]
        def surface(x):
            q = self.seed.copy(); q[indices] = x
            return self.points(q, names)
        def point_jacobian(points, labels):
            columns = []
            for index in range(7):
                joint = self.p.joints[f"{side}_joint{index + 1}"]
                transform = self.p.plant.CalcRelativeTransform(self.p.context, self.p.plant.world_frame(), joint.frame_on_child())
                axis = transform.rotation().matrix() @ joint.revolute_axis()
                column = np.cross(axis, points - transform.translation())
                column[~np.isin(labels, names[index:])] = 0
                columns.append(column)
            return np.stack(columns, axis=2)
        def fit_from(seed):
            points, _, _ = surface(seed)
            mask = self.visible(points, camera, depth, intrinsics)
            if np.sum(mask) < 120:
                return None
            cached = {}
            def evaluate(x):
                self.check_deadline()
                if "x" in cached and np.array_equal(x, cached["x"]):
                    return cached["residual"], cached["jacobian"]
                points, normals, labels = surface(x)
                distance, ids = tree.query(points[mask])
                delta = tree.data[ids] - points[mask]
                # Vector distance drives ICP; robust loss tolerates outliers.
                jacobian = -point_jacobian(points, labels)[mask]
                jacobian[np.abs(delta) > .10] = 0
                cached.update(x=x.copy(), residual=np.clip(delta, -.10, .10).ravel(), jacobian=jacobian.reshape(-1, 7))
                return cached["residual"], cached["jacobian"]
            fit = least_squares(lambda x: evaluate(x)[0], np.clip(seed, lower + 1e-9, upper - 1e-9),
                                jac=lambda x: evaluate(x)[1], bounds=(lower, upper),
                                loss="soft_l1", f_scale=.01, max_nfev=22, ftol=1e-5)
            points, normals, labels = surface(fit.x)
            visible = self.visible(points, camera, depth, intrinsics)
            distances, ids = tree.query(points)
            inliers = visible & (distances < .018)
            coverage = {n: float(np.sum(inliers & (labels == n)) / max(1, np.sum(visible & (labels == n)))) for n in names}
            counts = {n: int(np.sum(inliers & (labels == n))) for n in names}
            if min(counts.values()) < 20 or min(coverage.values()) < .4:
                return None
            error = float(np.sqrt(np.mean(distances[inliers] ** 2)))
            def normal_residual(x):
                pts, ns, _ = surface(x)
                _, closest = tree.query(pts[inliers])
                return np.sum((tree.data[closest] - pts[inliers]) * ns[inliers], axis=1)
            jacobian = numerical_jacobian(normal_residual, fit.x)
            observable, sigma = rank_and_uncertainty(jacobian, noise=max(.004, registration_error, error))
            return dict(q=fit.x, error=error, observable=observable and max(sigma if sigma is not None else [math.inf]) < math.radians(5),
                        sigma=None if sigma is None else sigma.tolist(), coverage=coverage)
        # Local correction plus genuinely different hanging hypotheses. Similar
        # scores at distinct angles are ambiguous, not a reason to trust the seed.
        seeds = [initial]
        for sign in (-1, 1):
            alternate = initial.copy(); alternate[1] += sign * .5; alternate[3] -= sign * .5
            seeds.append(np.clip(alternate, lower + 1e-9, upper - 1e-9))
        fits = [result for seed in seeds if (result := fit_from(seed)) is not None]
        if not fits:
            return dict(status="unobserved", detail="Arm surfaces are occluded, outside the view, or do not match the scan")
        fits.sort(key=lambda f: f["error"])
        best = fits[0]
        ambiguous = any(f["error"] <= best["error"] * 1.2 + .001 and max(abs(f["q"] - best["q"])) > math.radians(8) for f in fits[1:])
        if not best["observable"] or ambiguous or best["error"] > .012:
            return dict(status="ambiguous", detail="Depth cannot distinguish all seven joint rotations; ghost held",
                        candidatePositions=best["q"].tolist(), residualMeters=best["error"])
        prior = self.prior.get(side)
        self.stable[side] = self.stable[side] + 1 if prior is not None and max(abs(prior - best["q"])) < math.radians(5) else 1
        self.prior[side] = best["q"].copy()
        # Never update the search seed from a partial or ambiguous estimate.
        self.seed[indices] = best["q"]
        return dict(status="confirmed" if self.stable[side] >= 3 else "settling",
                    detail="Markerless scan/depth agreement" if self.stable[side] >= 3 else "Checking temporal agreement",
                    positions=best["q"].tolist(), standardDeviationRadians=best["sigma"],
                    residualMeters=best["error"], visibleCoverage=best["coverage"])

    def process(self, frame):
        began = time.monotonic()
        self.deadline = began + .65
        result = dict(schemaVersion=1, modelID=self.p.reference["modelID"], referenceID=self.p.reference["referenceID"],
                      source="markerless_rgbd", capturedAtMilliseconds=frame.get("capturedAtMilliseconds", 0),
                      camera=frame.get("camera", "unknown"), sequence=frame.get("sequence", 0),
                      streamID=frame.get("streamID", ""),
                      timestampNanoseconds=frame.get("timestampNanoseconds", 0),
                      frame="base_link", arms={}, status="unavailable", detail="No usable depth")
        try:
            cloud, depth, intrinsics = self.cloud(frame)
            camera, registration_error = self.register_camera(frame["camera"], cloud, depth, intrinsics)
            result.update(cameraRegistrationRMS=registration_error, status="partial", detail="Visible surfaces fitted to the approved scan")
            # Preserve the actual camera registration with each observation.
            # Calibration replay must distinguish head/camera motion from an
            # arm's encoder offset, and frame sequence alone resets on reconnect.
            result.update(cameraToRobot=camera.tolist(), cameraIntrinsics=intrinsics.tolist(),
                          depthImageSize=[int(depth.shape[1]), int(depth.shape[0])])
            for side in ("left", "right"):
                arm = self.fit_arm(side, cloud, depth, intrinsics, camera, registration_error)
                result["arms"][side] = arm
                if arm["status"] != "confirmed":
                    if arm["status"] != "settling": self.stable[side] = 0
            if all(a["status"] == "confirmed" for a in result["arms"].values()):
                result["status"] = "confirmed"
                result["detail"] = "Both arms agree with markerless depth observations"
            else:
                result["detail"] = "; ".join(("R-11" if side == "left" else "L-10") + ": " + arm["detail"]
                                             for side, arm in result["arms"].items())
        except (ValueError, RuntimeError, np.linalg.LinAlgError) as error:
            self.stable = {"left": 0, "right": 0}
            result.update(status="unavailable", detail=str(error)[:400])
        result["processingMilliseconds"] = (time.monotonic() - began) * 1000
        if time.time() * 1000 - result["capturedAtMilliseconds"] > 750:
            self.stable = {"left": 0, "right": 0}
            result.update(status="stale", arms={}, detail="Visual fit exceeded the freshness deadline")
        return result


def main():
    from worker import ShadowPlanner
    estimator = MarkerlessEstimator(ShadowPlanner())
    while True:
        line = sys.stdin.buffer.readline(2_000_001)
        if not line: return
        if len(line) > 2_000_000 or not line.endswith(b"\n"):
            raise ValueError("Oversized depth frame")
        frame = json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
        print(json.dumps(estimator.process(frame), allow_nan=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
