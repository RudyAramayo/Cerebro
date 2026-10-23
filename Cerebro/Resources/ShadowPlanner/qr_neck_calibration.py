"""Known-size QR pose and fixed neck/camera fit. No hardware or grant APIs.

Input uses canonical decoded QR corners, not arbitrary image-top-left ordering.
All returned transforms remain unverified, including a numerically good fit:
accepted neck commands alone do not establish measured physical neck geometry.
"""

import argparse
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np


TARGET_ID = "ROB:TABLE:001"
SIDE_METERS = 0.12
MAX_VIEWS = 128
MAX_REPROJECTION_PIXELS = 2.0


def numeric_array(value, shape, name):
    array = np.asarray(value, dtype=object)
    if array.shape != shape or any(type(x) not in (int, float) for x in array.flat):
        raise ValueError(f"{name} must have numeric shape {shape}")
    array = array.astype(np.float64)
    if not np.isfinite(array).all():
        raise ValueError(f"{name} contains a nonfinite number")
    return array


def rigid_matrix(value, name):
    transform = numeric_array(value, (16,), name).reshape(4, 4)
    rotation = transform[:3, :3]
    if (not np.allclose(transform[3], [0, 0, 0, 1], atol=1e-9, rtol=0)
            or not np.allclose(rotation.T @ rotation, np.eye(3), atol=1e-6, rtol=0)
            or abs(np.linalg.det(rotation) - 1) > 1e-6
            or np.linalg.norm(transform[:3, 3]) > 20):
        raise ValueError(f"{name} is not a bounded rigid transform")
    return transform


def transform(rotation, translation):
    result = np.eye(4)
    result[:3, :3] = rotation
    result[:3, 3] = np.asarray(translation).reshape(3)
    return result


def rotation_degrees(rotation):
    return math.degrees(math.acos(float(np.clip((np.trace(rotation) - 1) / 2, -1, 1))))


def object_corners():
    half = SIDE_METERS / 2
    # OpenCV IPPE_SQUARE order: TL, TR, BR, BL in the printed marker frame.
    return np.array([[-half, half, 0], [half, half, 0],
                     [half, -half, 0], [-half, -half, 0]], dtype=np.float64)


def pose_for_view(view):
    if not isinstance(view, dict):
        raise ValueError("Each view must be an object")
    identifier = view.get("id")
    if not isinstance(identifier, str) or not (1 <= len(identifier) <= 128):
        raise ValueError("Each view needs a bounded string id")
    if type(view.get("training")) is not bool:
        raise ValueError(f"{identifier}: training must be boolean")
    center_depth = view.get("centerDepthMeters")
    if center_depth is not None and (type(center_depth) not in (int, float)
                                     or not math.isfinite(center_depth)
                                     or not 0.05 <= center_depth <= 10):
        raise ValueError(f"{identifier}: centerDepthMeters must be a finite depth from 0.05 to 10 meters")
    parameters = numeric_array(view.get("cameraMatrix"), (4,), "cameraMatrix")
    fx, fy, cx, cy = parameters
    if not (1 <= fx <= 100_000 and 1 <= fy <= 100_000 and 0 <= cx <= 20_000 and 0 <= cy <= 20_000):
        raise ValueError(f"{identifier}: invalid intrinsics")
    camera = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)
    corners = numeric_array(view.get("cornersPixels"), (4, 2), "cornersPixels")
    if np.min(corners) < 0 or np.max(corners) > 40_000:
        raise ValueError(f"{identifier}: corner outside supported image bounds")
    size = view.get("imageSize")
    if size is not None:
        width, height = numeric_array(size, (2,), "imageSize")
        if (not (16 <= width <= 20_000 and 16 <= height <= 20_000)
                or cx >= width or cy >= height
                or np.any(corners[:, 0] >= width) or np.any(corners[:, 1] >= height)):
            raise ValueError(f"{identifier}: corners or principal point outside image")
    edges = np.roll(corners, -1, axis=0) - corners
    cross = edges[:, 0] * np.roll(edges[:, 1], -1) - edges[:, 1] * np.roll(edges[:, 0], -1)
    area = 0.5 * np.sum(corners[:, 0] * np.roll(corners[:, 1], -1)
                        - corners[:, 1] * np.roll(corners[:, 0], -1))
    if area < 25 or np.any(cross <= 1e-6) or np.min(np.linalg.norm(edges, axis=1)) < 3:
        raise ValueError(f"{identifier}: corners must form a non-mirrored convex QR boundary")
    distortion = view.get("distortionCoefficients")
    if distortion is None:
        distortion = np.zeros(5)
    else:
        if not isinstance(distortion, list) or len(distortion) not in (4, 5, 8, 12, 14):
            raise ValueError(f"{identifier}: unsupported distortion coefficients")
        distortion = numeric_array(distortion, (len(distortion),), "distortionCoefficients")
    base_to_neck = rigid_matrix(view.get("baseToNeck"), "baseToNeck")
    try:
        result = cv2.solvePnPGeneric(object_corners(), corners, camera, distortion,
                                    flags=cv2.SOLVEPNP_IPPE_SQUARE)
    except cv2.error as error:
        raise ValueError(f"{identifier}: square pose failed") from error
    candidates = []
    for vector, translation in zip(result[1], result[2]):
        if not np.isfinite(vector).all() or not np.isfinite(translation).all():
            continue
        rotation, _ = cv2.Rodrigues(vector)
        pose = transform(rotation, translation)
        points = (rotation @ object_corners().T).T + pose[:3, 3]
        if (np.min(points[:, 2]) < 0.05 or np.max(points[:, 2]) > 10
                or float(rotation[:, 2] @ pose[:3, 3]) >= 0):
            continue
        projected, _ = cv2.projectPoints(object_corners(), vector, translation, camera, distortion)
        rms = float(np.sqrt(np.mean(np.sum((projected.reshape(4, 2) - corners) ** 2, axis=1))))
        if np.isfinite(rms):
            candidates.append((rms, pose))
    if not candidates:
        raise ValueError(f"{identifier}: no finite front-facing positive-depth square pose")
    candidates.sort(key=lambda item: item[0])
    rms, best = candidates[0]
    if rms > MAX_REPROJECTION_PIXELS:
        raise ValueError(f"{identifier}: reprojection RMS {rms:.3f}px exceeds {MAX_REPROJECTION_PIXELS}px")
    ambiguous = False
    alternatives = []
    for other_rms, other in candidates[1:]:
        separation = float(np.linalg.norm(other[:3, 3] - best[:3, 3]))
        angle = rotation_degrees(best[:3, :3].T @ other[:3, :3])
        alternatives.append({"reprojectionRMSEPixels": other_rms,
                             "translationDifferenceMeters": separation,
                             "rotationDifferenceDegrees": angle})
        if other_rms - rms <= max(0.05, 0.1 * rms) and (separation > 0.001 or angle > 0.1):
            ambiguous = True
    depth_residual = float(best[2, 3] - center_depth) if center_depth is not None else None
    depth_warning = center_depth is not None and abs(depth_residual) > max(0.03, 0.05 * center_depth)
    return {"id": identifier, "training": view["training"],
            "baseToNeck": base_to_neck, "targetToCamera": best,
            "reprojectionRMSEPixels": rms, "poseAmbiguous": ambiguous,
            "alternativePoses": alternatives,
            "pnpCenterDepthMeters": float(best[2, 3]), "centerDepthMeters": center_depth,
            "centerDepthResidualMeters": depth_residual,
            "centerDepthAgreementWarning": bool(depth_warning),
            "zeroDistortionAssumed": view.get("distortionCoefficients") is None}


def relative_motions(views):
    motions = []
    for i in range(len(views)):
        for j in range(i + 1, len(views)):
            a = np.linalg.inv(views[j]["baseToNeck"]) @ views[i]["baseToNeck"]
            b = views[j]["targetToCamera"] @ np.linalg.inv(views[i]["targetToCamera"])
            alpha = cv2.Rodrigues(a[:3, :3])[0].reshape(3)
            beta = cv2.Rodrigues(b[:3, :3])[0].reshape(3)
            if min(np.linalg.norm(alpha), np.linalg.norm(beta)) > math.radians(0.05):
                motions.append((a, b, alpha, beta))
    if len(motions) < 2:
        raise ValueError("Insufficient rotational neck motion; capture both pan and tilt")
    singular = None
    for axis, label in ((2, "neck"), (3, "QR camera")):
        values = np.linalg.svd(np.stack([motion[axis] for motion in motions]), compute_uv=False)
        if len(values) < 2 or values[1] <= values[0] * 1e-3:
            raise ValueError(f"The {label} rotations are parallel or poorly excited; capture pan and tilt")
        if axis == 2:
            singular = values
    return motions, singular


def hand_eye(views):
    motions, singular = relative_motions(views)
    if hasattr(cv2, "calibrateHandEye"):
        rotation, translation = cv2.calibrateHandEye(
            [v["baseToNeck"][:3, :3] for v in views],
            [v["baseToNeck"][:3, 3] for v in views],
            [v["targetToCamera"][:3, :3] for v in views],
            [v["targetToCamera"][:3, 3] for v in views], method=cv2.CALIB_HAND_EYE_PARK)
        result = transform(rotation, translation)
        solver = "OpenCV calibrateHandEye/PARK"
    else:
        # Park-style log-rotation alignment: log(R_A) = R_X log(R_B).
        covariance = sum(np.outer(alpha, beta) for _, _, alpha, beta in motions)
        u, _, vt = np.linalg.svd(covariance)
        rotation = u @ np.diag([1, 1, np.linalg.det(u @ vt)]) @ vt
        left = np.vstack([a[:3, :3] - np.eye(3) for a, _, _, _ in motions])
        right = np.concatenate([rotation @ b[:3, 3] - a[:3, 3] for a, b, _, _ in motions])
        translation, _, rank, values = np.linalg.lstsq(left, right, rcond=None)
        if rank < 3 or values[-1] <= values[0] * 1e-4:
            raise ValueError("Neck motion cannot constrain the camera translation")
        result = transform(rotation, translation)
        solver = "Park-style log-rotation SVD plus translation least squares"
    rigid_matrix(result.reshape(-1).tolist(), "fitted neckToCamera")
    return result, solver, singular.tolist()


def mean_transform(transforms):
    u, _, vt = np.linalg.svd(sum(t[:3, :3] for t in transforms))
    rotation = u @ np.diag([1, 1, np.linalg.det(u @ vt)]) @ vt
    return transform(rotation, np.mean([t[:3, 3] for t in transforms], axis=0))


def fit(document, mode="fit"):
    if not isinstance(document, dict) or type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
        raise ValueError("Expected schemaVersion 1 object")
    if document.get("targetID") != TARGET_ID or document.get("symbolSideMeters") != SIDE_METERS:
        raise ValueError("Expected the measured ROB:TABLE:001 120mm target")
    source = document.get("poseSource", "accepted_neck_commands")
    if not isinstance(source, str) or len(source) > 128:
        raise ValueError("Invalid poseSource")
    raw_views = document.get("views")
    if not isinstance(raw_views, list) or not (1 <= len(raw_views) <= MAX_VIEWS):
        raise ValueError(f"Expected 1 to {MAX_VIEWS} captured views")
    views = [pose_for_view(view) for view in raw_views]
    if len({view["id"] for view in views}) != len(views):
        raise ValueError("View ids must be unique")
    result = {"schemaVersion": 1, "status": "poses_unverified", "targetID": TARGET_ID,
              "symbolSideMeters": SIDE_METERS, "poseSource": source,
              "registrationVerified": False, "uncertaintyMeters": None,
              "views": [{key: (value.reshape(-1).tolist() if isinstance(value, np.ndarray) else value)
                         for key, value in view.items()} for view in views]}
    depth_residuals = [view["centerDepthResidualMeters"] for view in views
                       if view["centerDepthResidualMeters"] is not None]
    depth_warning_ids = [view["id"] for view in views if view["centerDepthAgreementWarning"]]
    result.update(depthCheckViewCount=len(depth_residuals),
                  depthCenterResidualRMSEMeters=float(np.sqrt(np.mean(np.square(depth_residuals)))) if depth_residuals else None,
                  depthAgreementWarningViewIDs=depth_warning_ids,
                  warnings=[])
    if not depth_residuals:
        result["warnings"].append("No aligned center-depth samples were supplied; QR pose alone does not validate voxel depth scale.")
    if depth_warning_ids:
        result["warnings"].append("QR center-depth disagreement exceeds the larger of 30mm or 5% of supplied depth in some views; diagnostic only.")
    if mode == "poses":
        return result
    training = [view for view in views if view["training"]]
    held_out = [view for view in views if not view["training"]]
    if len(training) < 3 or not held_out:
        raise ValueError("Fit requires at least 3 training views and independent held-out views")
    neck_to_camera, solver, excitation = hand_eye(training)
    base_targets = {v["id"]: v["baseToNeck"] @ neck_to_camera @ v["targetToCamera"] for v in views}
    base_to_target = mean_transform([base_targets[v["id"]] for v in training])
    for output in result["views"]:
        current = base_targets[output["id"]]
        output["baseToTarget"] = current.reshape(-1).tolist()
        output["translationDriftMeters"] = float(np.linalg.norm(current[:3, 3] - base_to_target[:3, 3]))
        output["rotationDriftDegrees"] = rotation_degrees(base_to_target[:3, :3].T @ current[:3, :3])
    result.update(status="fitted_unverified", solver=solver,
                  neckToCamera=neck_to_camera.reshape(-1).tolist(),
                  baseToTarget=base_to_target.reshape(-1).tolist(),
                  rotationExcitationSingularValues=excitation,
                  ambiguousViewIDs=[v["id"] for v in views if v["poseAmbiguous"]])
    result["warnings"].extend(["Fit scatter is not measured camera-to-arm registration uncertainty.",
                               "Commanded neck poses require independent physical/frame validation."])
    if result["ambiguousViewIDs"]:
        result["warnings"].append("Planar alternatives remain ambiguous in some views; lowest reprojection choice is not independent ambiguity resolution.")
    if any(v["zeroDistortionAssumed"] for v in views):
        result["warnings"].append("Missing distortion coefficients were treated as zero; verify rectified aligned-camera input.")
    for label, flag in (("training", True), ("heldOut", False)):
        selected = [v for v in result["views"] if v["training"] == flag]
        for key, output_key in (("translationDriftMeters", "TranslationRMSEMeters"),
                                ("rotationDriftDegrees", "RotationRMSEDegrees")):
            result[label + output_key] = float(np.sqrt(np.mean([v[key] ** 2 for v in selected])))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--mode", choices=("fit", "poses"), default="fit")
    args = parser.parse_args()
    try:
        data = args.input.read_bytes()
        if len(data) > 2_000_000:
            raise ValueError("Capture file exceeds 2 MB")
        document = json.loads(data, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"Invalid JSON number {value}")))
        result = fit(document, args.mode)
        status = 0
    except (ValueError, TypeError, KeyError, OSError, cv2.error, np.linalg.LinAlgError) as error:
        result = {"schemaVersion": 1, "status": "rejected", "registrationVerified": False, "error": str(error)}
        print(str(error), file=sys.stderr)
        status = 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
