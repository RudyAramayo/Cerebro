"""Offline two-target BELLY RGB-D diagnostics; no actuator or profile writes.

The actual printed B01/B02 symbols are 120 mm squares, 400 mm center-to-center,
with parallel printed TOP edges. Their board frame is target-relative: it is
never assumed to be ROB's torso, world floor, neck reference or arm frame.
Native Vision seeds may be supplied; otherwise OpenCV decodes saved images.
Exact printed-module refinement verifies every accepted seed independently.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path

import cv2
import numpy as np

cv2.setNumThreads(1)
HERE = Path(__file__).resolve().parent
IDS = ("ROB:BELLY:B01", "ROB:BELLY:B02")


def _module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REFINE = _module("belly_only_corner_refinement", "qr_corner_refinement.py")
DEPTH = _module("belly_only_raw_depth_diagnostic", "qr_depth_registration.py")
PATTERNS_PATH = HERE / "belly_qr_patterns.json"
PATTERNS = json.loads(PATTERNS_PATH.read_text())["targets"]
# This module owns its private refiner instance. No neck target catalog, fit,
# active camera profile or shared world reference is modified.
for _target in IDS:
    _entry = PATTERNS[_target]
    REFINE._PATTERNS[_target] = (_entry["pdfSHA256"], "\n".join(_entry["blackModuleRows"]))


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _finite(value, shape, label):
    result = np.asarray(value, dtype=float)
    if result.shape != shape or not np.isfinite(result).all():
        raise ValueError(label + " has invalid dimensions or nonfinite values")
    return result


def _source(base, name, expected, maximum):
    if not isinstance(name, str) or not name:
        raise ValueError("Missing saved source path")
    path = (base / name).resolve()
    if not path.is_relative_to(base.resolve()) or not path.is_file():
        raise ValueError("Saved source is outside this capture directory")
    if path.stat().st_size > maximum or not isinstance(expected, str) or digest(path) != expected:
        raise ValueError("Saved source size/hash does not match immutable capture")
    return path


def _angle(a, b):
    relative = np.einsum("ji,jk->ik", a, b)
    return math.degrees(math.acos(float(np.clip((np.trace(relative)-1)/2, -1, 1))))


def _stats(values):
    a = np.asarray(values, dtype=float)
    if not len(a) or not np.isfinite(a).all():
        raise ValueError("No finite diagnostic samples")
    return {"count": int(len(a)), "medianSignedMeters": float(np.median(a)),
            "RMSEMeters": float(np.sqrt(np.mean(a*a))),
            "p95AbsoluteMeters": float(np.percentile(np.abs(a), 95)),
            "maximumAbsoluteMeters": float(np.max(np.abs(a)))}


def _poses(objects, pixels, K, square=False):
    solved = cv2.solvePnPGeneric(objects, pixels, K, np.zeros(5),
                                flags=cv2.SOLVEPNP_IPPE_SQUARE if square else cv2.SOLVEPNP_IPPE)
    candidates = []
    for rv, tv in zip(solved[1], solved[2]):
        R = cv2.Rodrigues(rv)[0]
        t = tv.reshape(3)
        optical = np.einsum("ij,kj->ki", R, objects)+t
        if not np.isfinite(optical).all() or optical[:, 2].min() <= .05 or float(np.dot(R[:, 2], t)) >= 0:
            continue
        projected = cv2.projectPoints(objects, rv, tv, K, np.zeros(5))[0].reshape(-1, 2)
        rms = float(np.sqrt(np.mean(np.sum((projected-pixels)**2, axis=1))))
        T = np.eye(4); T[:3, :3] = R; T[:3, 3] = t
        candidates.append((rms, T))
    candidates.sort(key=lambda entry: entry[0])
    if not candidates:
        raise ValueError("No front-facing positive-depth QR pose")
    best_error, best = candidates[0]
    alternatives = [{"cornerRMSEPixels": error,
                     "translationDifferenceMeters": float(np.linalg.norm(T[:3, 3]-best[:3, 3])),
                     "rotationDifferenceDegrees": _angle(best[:3, :3], T[:3, :3])}
                    for error, T in candidates[1:]]
    ambiguous = any(row["cornerRMSEPixels"]-best_error <= max(.05, .1*best_error) and
                    (row["translationDifferenceMeters"] > .001 or row["rotationDifferenceDegrees"] > .1)
                    for row in alternatives)
    return best, {"cornerRMSEPixels": best_error, "poseAmbiguous": ambiguous,
                  "alternatives": alternatives}


def _detections(frame, gray):
    if "detections" in frame:
        if not isinstance(frame["detections"], list):
            raise ValueError("Invalid native detector seeds")
        return frame["detections"], "native_seeds_verified_by_exact_printed_pattern"
    result, payloads, corners, _ = cv2.QRCodeDetector().detectAndDecodeMulti(gray)
    if not result:
        return [], "opencv_saved_image_decode"
    return [{"payload": payload, "cornersPixels": points.tolist()}
            for payload, points in zip(payloads, corners)], "opencv_saved_image_decode"


def _depth_report(frame, corners, target, base, image_path, depth_path):
    observation = {"width": frame["width"], "height": frame["height"],
                   "cameraMatrix": frame["intrinsics"], "cornersPixels": corners.tolist(),
                   "markerSizeMeters": .12, "zeroDistortionAssumed": True,
                   "sourceImagePath": str(image_path), "sourceImageSHA256": digest(image_path),
                   "depthPath": str(depth_path), "depthSHA256": digest(depth_path)}
    sampled = DEPTH.sample_observation(observation, base, inset_fraction=.15, sample_step=1)
    z_error = sampled["raw"]-sampled["true"]
    normal_error = z_error*DEPTH._mv(sampled["rays"], sampled["normal"])
    xyz = sampled["rays"]*sampled["raw"][:, None]
    _, _, vt = np.linalg.svd(xyz-xyz.mean(axis=0), full_matrices=False)
    n = vt[-1]
    normal_angle = math.degrees(math.acos(float(np.clip(abs(np.dot(n, sampled["normal"])), -1, 1))))
    optical_stats, plane_stats = _stats(z_error), _stats(normal_error)
    coverage = len(z_error)/sampled["interiorPixelCount"]
    return {"targetID": target, "region": "15-percent inset; all valid native returns retained",
            "interiorPixelCount": sampled["interiorPixelCount"], "validFraction": coverage,
            "rawOpticalZMinusPnPPlaneIntersection": optical_stats,
            "signedPointToPnPPlane": plane_stats, "rawPlaneNormalDifferenceDegrees": normal_angle,
            "withinDiagnosticLimits": bool(coverage >= .5 and optical_stats["RMSEMeters"] <= .010 and
                optical_stats["p95AbsoluteMeters"] <= .030 and normal_angle <= 3),
            "correctionFittedOrApplied": False}


def _frame(frame, base, spacing):
    if frame.get("rgbOutputUndistorted") is not True:
        raise ValueError("Undistorted RGB pixel metadata is missing/false; zero distortion cannot be assumed")
    if frame.get("sourceCameraRole") != "belly":
        raise ValueError("This source frame is not from the belly camera")
    if not isinstance(frame.get("depthAlignmentMethod"), str) or not frame["depthAlignmentMethod"]:
        raise ValueError("Native depth alignment provenance is missing")
    width, height = frame["width"], frame["height"]
    if type(width) is not int or type(height) is not int or not (16 <= width <= 1920 and 16 <= height <= 1200):
        raise ValueError("Unsupported saved RGB-D dimensions")
    k = _finite(frame["intrinsics"], (4,), "Recorded intrinsics")
    if min(k[:2]) <= 0 or not (0 <= k[2] < width and 0 <= k[3] < height):
        raise ValueError("Recorded intrinsics are outside this source image")
    image_path = _source(base, frame["imagePath"], frame.get("imageSHA256", frame.get("sourceImageSHA256")), 16_000_000)
    depth_path = _source(base, frame["depthPath"], frame["depthSHA256"], 5_000_000)
    if depth_path.stat().st_size != width*height*2:
        raise ValueError("Native UInt16 depth dimensions do not match")
    gray = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
    if gray is None or gray.shape != (height, width):
        raise ValueError("Saved RGB/depth image dimensions differ")
    detections, detector = _detections(frame, gray)
    K = np.array([[k[0], 0, k[2]], [0, k[1], k[3]], [0, 0, 1.]])
    objects = DEPTH.object_corners(.12)
    rows, poses, refined = [], [], []
    for target in IDS:
        matches = [row for row in detections if row.get("payload") == target]
        if len(matches) != 1:
            raise ValueError(target+" must appear exactly once, fully visible")
        corners, quality = REFINE.refine_image(gray, np.asarray(matches[0]["cornersPixels"]), target)
        pose, diagnostic = _poses(objects, corners, K, square=True)
        poses.append(pose); refined.append(corners)
        rows.append({"targetID": target, "cornersPixels": corners.tolist(), "patternQuality": quality,
                     "individualPnP": diagnostic, "targetToCameraColumnMajor": pose.T.reshape(-1).tolist(),
                     "rawDepth": _depth_report(frame, corners, target, base, image_path, depth_path)})
    delta = np.einsum("ji,j->i", poses[0][:3, :3], poses[1][:3, 3]-poses[0][:3, 3])
    separation = float(np.linalg.norm(poses[1][:3, 3]-poses[0][:3, 3]))
    rotation_error = _angle(poses[0][:3, :3], poses[1][:3, :3])
    board_objects = np.concatenate([objects+[-spacing/2, 0, 0], objects+[spacing/2, 0, 0]])
    board, board_diagnostic = _poses(board_objects, np.concatenate(refined), K)
    pair_error = float(np.linalg.norm(delta-[spacing, 0, 0]))
    checks = {"jointCornerRMSEWithin0_8Pixels": board_diagnostic["cornerRMSEPixels"] <= .8,
              "jointPoseUnambiguous": not board_diagnostic["poseAmbiguous"],
              "individualPairTranslationWithin15mm": pair_error <= .015,
              "individualPrintedAxesWithin3Degrees": rotation_error <= 3}
    return {"sequence": frame["sequence"], "capturedAtMilliseconds": frame["capturedAtMilliseconds"],
            "imageSHA256": digest(image_path), "depthSHA256": digest(depth_path),
            "detector": detector, "cameraServiceSourceSHA256": frame.get("cameraServiceSourceSHA256"),
            "depthAlignmentMethod": frame.get("depthAlignmentMethod"), "sequenceSource": frame.get("sequenceSource", "unspecified"),
            "targets": rows, "individualCenterSeparationMeters": separation,
            "b02CenterInB01CoordinatesMeters": delta.tolist(), "expectedSeparationMeters": spacing,
            "pairTranslationErrorMeters": pair_error, "pairRotationErrorDegrees": rotation_error,
            "boardToCameraColumnMajor": board.T.reshape(-1).tolist(),
            "boardNormalOptical": board[:3, 2].tolist(), "jointPnP": board_diagnostic,
            "geometryChecks": checks, "geometryConsistent": all(checks.values()),
            "rawDepthAgreement": all(row["rawDepth"]["withinDiagnosticLimits"] for row in rows)}


def diagnose(document, base_directory):
    if document.get("schemaVersion") != 1 or document.get("kind") not in ("belly_qr_capture", "belly_two_target_capture") or document.get("cameraRole") != "belly":
        raise ValueError("Expected a dedicated schema1 belly QR capture; face/neck captures are not interchangeable")
    layout = document.get("layout", {})
    size = document.get("markerSizeMeters", layout.get("symbolSideMeters"))
    spacing = document.get("centerSpacingMeters", layout.get("centerSeparationMeters"))
    if size != .12 or spacing != .4:
        raise ValueError("This diagnostic requires actual120mm symbols and400mm center spacing")
    if layout.get("b01IsPrintedLeft") is not True or layout.get("parallelPrintedTop") is not True:
        raise ValueError("Record B01 at printed-left, B02 at printed-right and parallel TOP edges")
    frames = document.get("frames")
    if not isinstance(frames, list) or not (1 <= len(frames) <= 32):
        raise ValueError("Capture between1 and32 actual belly RGB-D frames")
    base = Path(base_directory)
    accepted, rejected = [], []
    previous_sequence, previous_time = 0, 0.
    for index, frame in enumerate(frames):
        try:
            if not isinstance(frame, dict):
                raise ValueError("Invalid saved frame metadata")
            stream = document.get("captureStreamID")
            if not isinstance(stream, str) or not stream:
                raise ValueError("Native belly capture-stream identity is missing")
            frame_stream = frame.get("captureStreamID", frame.get("sourceCaptureStreamID", stream))
            if frame_stream != stream:
                raise ValueError("Belly capture stream changed within this diagnostic")
            sequence, captured = frame["sequence"], frame["capturedAtMilliseconds"]
            if (type(sequence) is not int or sequence <= previous_sequence or
                type(captured) not in (int, float) or not math.isfinite(captured) or captured <= previous_time):
                raise ValueError("Saved capture sequence/time did not advance")
            previous_sequence, previous_time = sequence, captured
            accepted.append(_frame(frame, base, spacing))
        except (ValueError, KeyError, cv2.error) as error:
            rejected.append({"frameIndex": index, "reason": str(error)})
    consistent = [row for row in accepted if row["geometryConsistent"]]
    poses = [np.array(row["boardToCameraColumnMajor"]).reshape(4, 4).T for row in consistent]
    translation_spread, rotation_spread = 0., 0.
    for a in poses:
        for b in poses:
            translation_spread = max(translation_spread, float(np.linalg.norm(a[:3, 3]-b[:3, 3])))
            rotation_spread = max(rotation_spread, _angle(a[:3, :3], b[:3, :3]))
    return {"schemaVersion": 1, "kind": "belly_two_target_rgbd_diagnostic", "cameraRole": "belly",
            "status": "diagnostic_complete" if len(consistent) >= 3 else "diagnostic_incomplete",
            "captureSessionID": document.get("captureSessionID"), "captureStreamID": document.get("captureStreamID"),
            "registrationVerified": False, "calibrationApplied": False, "armMotionAuthority": False,
            "boardFrame": "Origin halfway between symbols; +X B01toB02, +Y printedTOP, +Z outofsheet; not torso/world",
            "symbolSideMeters": size, "centerSpacingMeters": spacing, "acceptedFrameCount": len(accepted),
            "consistentPairFrameCount": len(consistent), "rejectedFrames": rejected, "frames": accepted,
            "maximumPairwiseBoardTranslationDifferenceMeters": translation_spread if poses else None,
            "maximumPairwiseBoardRotationDifferenceDegrees": rotation_spread if poses else None,
            "repeatabilityIsAbsoluteAccuracy": False,
            "rawDepthAgreementAcrossConsistentFrames": bool(consistent) and all(row["rawDepthAgreement"] for row in consistent),
            "printedPatternCatalogSHA256": digest(PATTERNS_PATH),
            "printedPDFSHA256": {target: PATTERNS[target]["pdfSHA256"] for target in IDS},
            "limitations": ["Conditional on actual printed symbol size, center spacing and parallel placement.",
                "No assumed robot/world plane, neck fit, camera profile, correction fit or actuator registration.",
                "Repeated fixed-view samples measure repeatability; raw depth remains uncorrected."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    document = json.loads(args.input.read_text())
    result = diagnose(document, args.input.parent)
    result["inputSHA256"] = digest(args.input)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False)+"\n")
    print(json.dumps({key: result[key] for key in ("status", "acceptedFrameCount", "consistentPairFrameCount", "rawDepthAgreementAcrossConsistentFrames", "rejectedFrames")}))


if __name__ == "__main__":
    main()
