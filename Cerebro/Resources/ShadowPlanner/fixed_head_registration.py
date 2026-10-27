"""Fixed-pose CAD/RGB-D registration acquisition; no actuator API.

Training uses spatial robot-surface patches in the first frame. Validation uses
withheld patches in two or more later frames. The optical-to-robot prior is an
optimizer seed only. Output is measured correspondences, not a trusted Boolean;
Swift recomputes the rigid fit, held-out errors and local-volume error allowance.
A CAD-surface result remains conditional on declared CAD/reference uncertainty.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import time

import numpy as np
from scipy.optimize import least_squares
from scipy.spatial import cKDTree
from scipy.spatial.transform import Rotation


def digest(data):
    return hashlib.sha256(data).hexdigest()


def balanced_surface_patch_indices(indices, labels, limit):
    """Cap existing spatial patches without losing a sparsely visible link.

    Link order in the CAD must not let a broad base surface crowd out the
    torso before registration. Allocation changes only sampling: it adds no
    references and never moves a withheld patch into the training set.
    """
    if len(indices) <= limit:
        return indices.copy()
    groups = [indices[labels[indices] == name] for name in np.unique(labels[indices])]
    proportional = indices[np.linspace(0, len(indices) - 1, limit, dtype=int)]
    # Keep the established sampling when it already retains the ten patches
    # per reference needed by acquisition. Rebalance only a crowded-out part.
    minimum = min(10, limit // len(groups))
    if all(np.count_nonzero(np.isin(proportional, group)) >= min(minimum, len(group))
           for group in groups):
        return proportional
    counts = [0] * len(groups)
    remaining = limit
    while remaining:
        for i, group in enumerate(groups):
            if counts[i] < len(group):
                counts[i] += 1
                remaining -= 1
                if not remaining:
                    break
    selected = [group[np.linspace(0, len(group) - 1, count, dtype=int)]
                for group, count in zip(groups, counts) if count]
    return np.sort(np.concatenate(selected))


def finite_array(value, shape, name):
    result = np.asarray(value, dtype=float)
    if result.shape != shape or not np.isfinite(result).all():
        raise ValueError(f"{name} must be finite with shape {shape}")
    return result


def rigid_valid(matrix):
    return (matrix.shape == (4, 4) and np.isfinite(matrix).all()
            and np.max(np.abs(matrix[3] - [0, 0, 0, 1])) < 1e-7
            and np.max(np.abs(matrix[:3, :3].T @ matrix[:3, :3] - np.eye(3))) < 1e-6
            and abs(np.linalg.det(matrix[:3, :3]) - 1) < 1e-6)


def read_capture(frame, root):
    width, height = frame.get("width"), frame.get("height")
    if (not isinstance(width, int) or not isinstance(height, int)
            or not 16 <= width <= 1920 or not 16 <= height <= 1080):
        raise ValueError("Depth dimensions are invalid")
    k = finite_array(frame["intrinsics"], (4,), "aligned intrinsics")
    if k[0] <= 0 or k[1] <= 0 or not 0 <= k[2] < width or not 0 <= k[3] < height:
        raise ValueError("Aligned intrinsics do not match the raw depth image")
    path = Path(frame["depthPath"])
    if not path.is_absolute():
        path = root / path
    raw = path.read_bytes()
    if len(raw) != width * height * 2:
        raise ValueError("Depth byte count does not match its declared dimensions")
    depth_hash = digest(raw)
    if frame.get("captureSHA256") not in (None, depth_hash):
        raise ValueError("Raw depth hash does not match captureSHA256")
    z = np.frombuffer(raw, dtype="<u2").reshape(height, width).astype(float) / 1000
    valid = (z >= .10) & (z <= 3)
    for axis in (0, 1):
        valid &= np.abs(z - np.roll(z, 1, axis)) <= .02
        valid &= np.abs(z - np.roll(z, -1, axis)) <= .02
    valid[[0, -1], :] = False
    valid[:, [0, -1]] = False
    v, u = np.indices(z.shape)
    # Keep native optical coordinates; no manual display pitch/translation is
    # applied to the measured point cloud. Only the seed may contain that prior.
    cloud = np.column_stack(((u[valid] - k[2]) * z[valid] / k[0],
                             (v[valid] - k[3]) * z[valid] / k[1], z[valid]))
    if len(cloud) < 100:
        raise ValueError("Insufficient consistent raw aligned depth pixels")
    if len(cloud) > 100_000:
        cloud = cloud[np.linspace(0, len(cloud) - 1, 100_000, dtype=int)]
    sequence, timestamp = frame.get("sequence"), frame.get("capturedAtMilliseconds")
    if not isinstance(sequence, int) or sequence <= 0 or not isinstance(timestamp, (int, float)) or not math.isfinite(timestamp) or timestamp <= 0:
        raise ValueError("A capture needs advancing sequence and original capture time")
    return dict(cloud=cloud, tree=cKDTree(cloud), depth=z, intrinsics=k,
                hash=depth_hash, sequence=sequence, timestamp=timestamp)


def proper_fit(source, target):
    sc, tc = source.mean(axis=0), target.mean(axis=0)
    u, _, vt = np.linalg.svd((source - sc).T @ (target - tc))
    rotation = vt.T @ np.diag([1, 1, np.linalg.det(vt.T @ u.T)]) @ u.T
    result = np.eye(4)
    result[:3, :3] = rotation
    result[:3, 3] = tc - rotation @ sc
    return result


def stationary_gravity_initializer(frames, prior):
    """Improve a fitting seed, never the measured points or fit admission.

    Gravity supplies two rotation constraints. The horizontal image-right
    heading and translation remain prior values. A level model base is an
    initialization assumption, not an independently measured world reference.
    Missing, moving, stale or inconsistent IMU data preserves the legacy seed.
    """
    fallback = dict(source="neck_prior_initializer_only", applied=False)
    if not rigid_valid(prior) or not isinstance(frames, list) or len(frames) < 3:
        return prior.copy(), fallback
    directions, evidence, sensors = [], [], []
    for frame in frames:
        imu = frame.get("imu")
        if not isinstance(imu, dict):
            return prior.copy(), fallback
        try:
            gravity = finite_array(imu["gravity_mps2"], (3,), "gravity")
            deviation = finite_array(imu["gravity_std_mps2"], (3,), "gravity deviation")
            gyro = finite_array(imu["gyro_rad_s"], (3,), "gyro")
            rotation = finite_array(imu["imu_to_rgb_rotation"], (9,), "IMU-to-RGB").reshape((3, 3))
            count, window, age = imu["sample_count"], imu["window_milliseconds"], imu["age_milliseconds"]
            latest, reference = imu["latest_timestamp_ns"], imu["reference_timestamp_ns"]
            if (not isinstance(imu.get("sensor"), str) or not 1 <= len(imu["sensor"]) <= 128
                    or imu.get("stationary") is not True or imu.get("axes") != "sensor_native"
                    or imu.get("gravity_source") != "stationary_accelerometer_mean"
                    or not isinstance(count, int) or isinstance(count, bool) or not 10 <= count <= 1000
                    or not isinstance(window, (int, float)) or not 100 <= window <= 1000
                    or not isinstance(age, (int, float)) or not 0 <= age <= 100
                    or not isinstance(latest, int) or not isinstance(reference, int)
                    or latest <= 0 or reference < latest or abs((reference-latest)/1e6-age) > .02
                    or not 7 <= np.linalg.norm(gravity) <= 12
                    or np.any(deviation < 0) or np.max(deviation) > .10
                    or np.linalg.norm(gyro) > .03
                    or np.max(np.abs(rotation.T @ rotation-np.eye(3))) > 1e-6
                    or abs(np.linalg.det(rotation)-1) > 1e-6):
                return prior.copy(), fallback
            value = rotation @ gravity
            sensors.append(imu["sensor"])
            directions.append(value / np.linalg.norm(value))
            evidence.append(dict(sequence=frame["sequence"], latestTimestampNs=latest,
                                 referenceTimestampNs=reference, ageMilliseconds=age,
                                 sampleCount=count, gravityRGBUnit=directions[-1].tolist()))
        except (KeyError, TypeError, ValueError):
            return prior.copy(), fallback
    if len(set(sensors)) != 1 or len({row["latestTimestampNs"] for row in evidence}) != len(evidence):
        return prior.copy(), fallback
    gravity = np.mean(directions, axis=0)
    if np.linalg.norm(gravity) < .99:
        return prior.copy(), fallback
    gravity /= np.linalg.norm(gravity)
    spread = np.degrees(np.arccos(np.clip(np.asarray(directions) @ gravity, -1, 1)))
    if np.max(spread) > 1:
        return prior.copy(), fallback
    up = np.array([0., 0., 1.])
    world_right = prior[:3, 0]-up*(prior[:3, 0] @ up)
    camera_right = np.array([1., 0., 0.])-gravity*gravity[0]
    if min(np.linalg.norm(world_right), np.linalg.norm(camera_right)) < .1:
        return prior.copy(), fallback
    world_right /= np.linalg.norm(world_right)
    camera_right /= np.linalg.norm(camera_right)
    world_basis = np.column_stack((world_right, np.cross(up, world_right), up))
    camera_basis = np.column_stack((camera_right, np.cross(gravity, camera_right), gravity))
    seed = prior.copy()
    seed[:3, :3] = world_basis @ camera_basis.T
    correction = float(Rotation.from_matrix(seed[:3, :3] @ prior[:3, :3].T).magnitude())
    if not rigid_valid(seed) or correction > math.radians(20):
        return prior.copy(), fallback
    return seed, dict(source="stationary_imu_level_base_initializer_only", applied=True,
        rotationChangeDegrees=math.degrees(correction), maximumGravitySpreadDegrees=float(np.max(spread)),
        translationUnchanged=True, horizontalImageRightHeadingUnchanged=True, frames=evidence,
        limitations=["Model base Z is assumed vertical for initialization only.",
                     "Gravity does not measure camera translation or heading.",
                     "Original CAD, raw depth, ambiguity and independent validation checks remain required."])


def register(document, root, planner=None, monotonic=time.monotonic):
    if document.get("schemaVersion") != 1:
        raise ValueError("Unsupported capture schema")
    frames = document.get("frames")
    if not isinstance(frames, list) or not 3 <= len(frames) <= 8:
        raise ValueError("Capture at least three held-pose raw RGB-D frames")
    scope = document["scope"]
    for key in ("modelID", "geometryID", "mappingID", "cameraGeneration", "displayCorrectionIdentity", "intrinsicsIdentity"):
        if not isinstance(scope.get(key), str) or not scope[key] or len(scope[key]) > 512:
            raise ValueError(f"Missing fixed-pose identity: {key}")
    if (not isinstance(scope.get("gatewaySessionGeneration"), int) or scope["gatewaySessionGeneration"] <= 0
            or any(not isinstance(scope.get(key), int) or not 3000 <= scope[key] <= 10000
                   for key in ("panTarget", "lowerTarget", "upperTarget"))):
        raise ValueError("Current exact raw neck targets and gateway session are required")
    prior = finite_array(document["initialCameraToRobotColumnMajor"], (16,), "optical-to-robot seed").reshape((4, 4), order="F")
    if not rigid_valid(prior):
        raise ValueError("Initial camera transform is not a proper rigid transform")
    reference_error = document.get("referenceUncertaintyMeters")
    if not isinstance(reference_error, (float, int)) or not .001 <= reference_error <= .04:
        raise ValueError("Declare the physical CAD/reference error allowance in meters (1–40 mm)")
    captures = [read_capture(frame, root) for frame in frames]
    if (len({f["hash"] for f in captures}) != len(captures)
            or any(b["sequence"] <= a["sequence"] or b["timestamp"] <= a["timestamp"] for a, b in zip(captures, captures[1:]))
            or any(not np.array_equal(f["intrinsics"], captures[0]["intrinsics"]) or f["depth"].shape != captures[0]["depth"].shape for f in captures)):
        raise ValueError("Frames must be distinct, advancing and share exact aligned framing/intrinsics")
    original_prior = prior.copy()
    prior, initializer = stationary_gravity_initializer(frames, prior)
    if planner is None:
        from worker import ShadowPlanner
        planner = ShadowPlanner()
    if scope["modelID"] != planner.reference["modelID"]:
        raise ValueError("Captured registration model does not match the pinned robot CAD model")
    from markerless import MarkerlessEstimator, numerical_jacobian, rank_and_uncertainty
    # Passive fixed-head acquisition may inspect more saved CAD rows. All
    # spatial-patch, independent-frame and observability gates below are intact.
    estimator = MarkerlessEstimator(planner, surface_samples_per_link=640)
    # Base-fixed and torso surfaces only. Unknown arm FK/commands are never
    # used to position registration references or manufacture a jaw pose.
    names = ["base_link", "left_track_link", "right_track_link", "torso_link", "lean_link", "rplidar_link"]
    points, normals, labels = estimator.points(planner.q0, names)
    first = captures[0]
    visible = estimator.visible(points, prior, first["depth"], first["intrinsics"])
    points, normals, labels = points[visible], normals[visible], labels[visible]
    if len(points) < 100:
        raise ValueError(f"This held view does not show enough known base and torso surfaces: {len(points)} candidate CAD samples, 100 required. Point the camera toward ROB's rigid body")
    # Whole spatial patches, not random adjacent pixels, are withheld. One
    # reference per 3cm cell reduces correlated surface samples.
    cells = np.floor(points / .03).astype(np.int64)
    _, indices = np.unique(cells, axis=0, return_index=True)
    indices.sort()
    points, normals, labels, cells = points[indices], normals[indices], labels[indices], cells[indices]
    patch = (cells[:, 0] * 73856093 ^ cells[:, 1] * 19349663 ^ cells[:, 2] * 83492791) % 3
    train = np.flatnonzero(patch != 0)
    held = np.flatnonzero(patch == 0)
    train = balanced_surface_patch_indices(train, labels, 100)
    if len(held):
        held = held[cKDTree(points[train]).query(points[held])[0] >= .02]
    held = balanced_surface_patch_indices(held, labels, 50)
    if len(train) < 40 or len(held) < 15:
        raise ValueError(f"Known robot surfaces need more spatially separated fit and held-out patches: {len(train)} fit / {len(held)} held-out, 40 / 15 required")
    if (sum(labels[train] == "torso_link") < 10
            or sum(np.isin(labels[train], ["base_link", "left_track_link", "right_track_link"])) < 10):
        raise ValueError("Independent registration needs visible torso and base-fixed surfaces")
    deadline = monotonic() + 150

    def transform(x):
        value = prior.copy()
        value[:3, :3] = Rotation.from_rotvec(x[3:]).as_matrix() @ prior[:3, :3]
        value[:3, 3] += x[:3]
        return value

    def residual(x):
        if monotonic() > deadline:
            raise ValueError("Registration exceeded its fixed calculation budget")
        camera = transform(x)
        local = (points[train] - camera[:3, 3]) @ camera[:3, :3]
        distance, ids = first["tree"].query(local)
        delta = (first["cloud"][ids] - local) @ camera[:3, :3].T
        normal_error = np.sum(delta * normals[train], axis=1)
        return np.where(distance <= .08, normal_error, np.minimum(distance, .20))

    starts = [np.zeros(6)]
    for axis in (0, 1, 2):
        for sign in (-1, 1):
            value = np.zeros(6)
            value[axis] = sign * .04
            starts.append(value)
    fits = [least_squares(residual, start, bounds=([-.20] * 3 + [-.45] * 3, [.20] * 3 + [.45] * 3),
                          loss="soft_l1", f_scale=.008, max_nfev=100) for start in starts]
    fits.sort(key=lambda fit: float(np.sum(np.minimum(residual(fit.x) ** 2, .04 ** 2))))
    best = fits[0]
    camera = transform(best.x)
    local_training = (points[train] - camera[:3, 3]) @ camera[:3, :3]
    training_distance = first["tree"].query(local_training)[0]
    inliers = (training_distance <= .04) & (np.abs(residual(best.x)) <= .02)
    torso_inliers = int(sum(labels[train][inliers] == "torso_link"))
    base_inliers = int(sum(np.isin(labels[train][inliers], ["base_link", "left_track_link", "right_track_link"])))
    if (np.mean(inliers) < .60 or sum(inliers) < 30
            or torso_inliers < 8 or base_inliers < 8):
        raise ValueError(f"Too little base/torso CAD is independently observed after fitting: {sum(inliers)}/{len(train)} fit patches ({np.mean(inliers):.0%}; 60% required), {torso_inliers} torso / {base_inliers} base (8 each required)")
    error = float(np.sqrt(np.mean(residual(best.x)[inliers] ** 2)))
    observed, sigma = rank_and_uncertainty(numerical_jacobian(lambda x:residual(x)[inliers], best.x), noise=max(.004, error))
    if not observed or error > .02 or max(sigma[:3]) > .015 or max(sigma[3:]) > .04:
        raise ValueError("CAD/depth frame is underconstrained or inconsistent: more distinct rigid body surfaces are needed")
    near = [fit for fit in fits if np.sum(np.minimum(residual(fit.x) ** 2, .04 ** 2)) <= np.sum(np.minimum(residual(best.x) ** 2, .04 ** 2)) * 1.1 + 1e-8]
    if any(np.linalg.norm(transform(fit.x)[:3, 3] - camera[:3, 3]) > .02
           or Rotation.from_matrix(transform(fit.x)[:3, :3] @ camera[:3, :3].T).magnitude() > .03 for fit in near):
        raise ValueError("Alternative camera starts disagree: registration is ambiguous")
    if np.any(np.abs(best.x[:3]) > .199) or np.any(np.abs(best.x[3:]) > .449):
        raise ValueError("Registration reached an initialization search bound")
    samples = []
    validation_by_frame = []
    # Avoid pseudoreplication: output at most 100 fitted patches from frame0,
    # and <=50 held-out patches total on later, genuinely distinct captures.
    for frame_index, capture in enumerate(captures):
        chosen = train if frame_index == 0 else held[(np.arange(len(held)) % (len(captures) - 1)) == frame_index - 1]
        local = (points[chosen] - camera[:3, 3]) @ camera[:3, :3]
        distance, ids = capture["tree"].query(local)
        usable = distance <= .015
        if frame_index and (sum(usable) < 3 or np.mean(usable) < .60
                or float(np.sqrt(np.mean(distance[usable]**2))) > .012):
            raise ValueError(f"Later validation frame does not independently confirm enough withheld robot patches: sequence {capture['sequence']}, {sum(usable)}/{len(chosen)} within 15 mm (3 and 60% required)")
        values = []
        for index, nearest, gap in zip(chosen[usable], ids[usable], distance[usable]):
            raw = capture["cloud"][nearest]
            robot = points[index]
            # NN tangential position is not exact surveyed vertex identity;
            # retain its observed 3-D mismatch in the measurement allowance.
            camera_error = max(.004, float(gap), float(max(sigma[:3])))
            if camera_error + reference_error >= .05:
                continue
            samples.append(dict(landmarkID=f"{labels[index]}:patch-{index}",captureID=capture["hash"],
                frameSequence=capture["sequence"],capturedAtMilliseconds=capture["timestamp"],evidenceSHA256=capture["hash"],
                referenceSource="cad_surface_rgbd",cameraMeters=raw.tolist(),robotMeters=robot.tolist(),
                cameraUncertaintyMeters=camera_error,referenceUncertaintyMeters=float(reference_error),validationOnly=frame_index > 0))
            values.append(float(gap))
        if frame_index:
            validation_by_frame.append(dict(sequence=capture["sequence"],patches=len(values),
                rmseMeters=float(np.sqrt(np.mean(np.square(values)))) if values else None,
                maximumMeters=max(values) if values else None))
    if sum(not s["validationOnly"] for s in samples) < 20 or sum(s["validationOnly"] for s in samples) < 6:
        raise ValueError("Too few independently observed fit/validation surface patches survived")
    output=dict(schemaVersion=1,scope=scope,validRobotVolume=document["validRobotVolume"],samples=samples)
    train_samples=[s for s in samples if not s["validationOnly"]]
    rebuilt=proper_fit(np.asarray([s["cameraMeters"] for s in train_samples]),np.asarray([s["robotMeters"] for s in train_samples]))
    report=dict(schemaVersion=1,status="measured_correspondences_ready_for_independent_swift_validation",
        registrationVerified=False,source="fixed_head_cad_rgbd",trainingFrameCount=1,heldOutFrameCount=len(captures)-1,
        fitPatchCount=len(train_samples),heldOutPatchCount=len(samples)-len(train_samples),
        pointNormalRMSEMeters=error,translationStandardDeviationMeters=sigma[:3].tolist(),
        rotationStandardDeviationRadians=sigma[3:].tolist(),alternateStarts=len(fits),nearBestStarts=len(near),
        heldOutFrames=validation_by_frame,referenceUncertaintyMeters=reference_error,
        initializer=initializer,
        originalSeedCameraToRobotColumnMajor=original_prior.flatten(order="F").tolist(),
        seedCameraToRobotColumnMajor=prior.flatten(order="F").tolist(),
        candidateCameraToRobotColumnMajor=rebuilt.flatten(order="F").tolist(),
        limitations=["CAD/reference uncertainty is an explicit supplied allowance, not inferred from low fit residual.",
                     "A fixed-head optical transform does not calibrate neck angles or arm encoder zeros.",
                     "Current input scope, robot volume and independent Swift validation must all pass before map admission.",
                     "Correspondences use actual raw depth; the manual display correction only initializes optimization."])
    return output,report


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--input",required=True,type=Path)
    parser.add_argument("--output",required=True,type=Path)
    args=parser.parse_args()
    report_path=args.output.with_suffix(".report.json")
    try:
        if args.input.stat().st_size > 2_000_000:
            raise ValueError("Capture manifest exceeds 2 MB")
        document=json.loads(args.input.read_text(),parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
        output,report=register(document,args.input.parent)
        args.output.write_text(json.dumps(output,indent=2,allow_nan=False)+"\n")
        report_path.write_text(json.dumps(report,indent=2,allow_nan=False)+"\n")
        print(json.dumps({k:report[k] for k in ("status","fitPatchCount","heldOutPatchCount","pointNormalRMSEMeters")},allow_nan=False))
    except Exception as error:
        report=dict(schemaVersion=1,status="rejected",registrationVerified=False,error=str(error))
        report_path.write_text(json.dumps(report,indent=2,allow_nan=False)+"\n")
        print(json.dumps(report,allow_nan=False))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
