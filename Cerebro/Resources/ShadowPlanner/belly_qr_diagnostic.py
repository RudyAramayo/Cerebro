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


class DetectionFailure(ValueError):
    def __init__(self, message, diagnostics):
        super().__init__(message)
        self.diagnostics = diagnostics


def _same_quad(a, b):
    a, b = np.asarray(a), np.asarray(b)
    edge = min(np.linalg.norm(np.roll(a, -1, axis=0)-a, axis=1))
    return float(np.linalg.norm(a.mean(axis=0)-b.mean(axis=0))) < max(6., .35*edge)


def _pattern_attempt(gray, corners, target):
    try:
        refined, quality = REFINE.refine_image(gray, corners, target)
        return {"targetID": target, "accepted": True, "correlation": quality["correlation"],
                "cornersPixels": refined.tolist(), "quality": quality}
    except ValueError as error:
        # Retain candidate evidence without accepting it. These original-image
        # scores explain under-resolved printed modules; no metric is relaxed.
        scores = []
        for rotation in range(4):
            try:
                _, quality = REFINE._refine_orientation(gray, np.roll(corners, -rotation, axis=0), target)
                scores.append(quality["correlation"])
            except ValueError:
                pass
        return {"targetID": target, "accepted": False,
                "correlation": max(scores) if scores else None, "reason": str(error)}


def _identify_undecoded(gray, corners):
    attempts = [_pattern_attempt(gray, corners, target) for target in IDS]
    ranked = sorted(attempts, key=lambda row: row["correlation"] or -1., reverse=True)
    best, runner = ranked
    margin = None if best["correlation"] is None or runner["correlation"] is None else best["correlation"]-runner["correlation"]
    accepted = best["accepted"] and (margin is not None and margin >= REFINE.MINIMUM_ORIENTATION_MARGIN)
    return ({"payload": best["targetID"], "cornersPixels": best["cornersPixels"],
             "identitySource": "strict_exact_printed_pattern"} if accepted else None,
            {"cornersPixels": np.asarray(corners).tolist(), "patternAttempts": attempts,
             "crossPayloadCorrelationMargin": margin, "strictIdentityAccepted": bool(accepted)})


def _detections(frame, gray):
    detections = []
    if "detections" in frame:
        if not isinstance(frame["detections"], list):
            raise ValueError("Invalid native detector seeds")
        detections = list(frame["detections"])
    if all(any(row.get("payload") == target for row in detections) for target in IDS):
        return detections, "native_seeds_verified_by_exact_printed_pattern", {}
    height, width = gray.shape
    diagnostics = {"methods": [], "undecodedCandidates": [],
                   "minimumExactPatternCorrelation": REFINE.MINIMUM_CORRELATION}
    quads = []
    aruco = getattr(cv2, "QRCodeDetectorAruco", cv2.QRCodeDetector)
    variants = [(aruco, "aruco_or_standard_full_2x", 0, 2., False),
                (cv2.QRCodeDetector, "standard_full_2x", 0, 2., False),
                (aruco, "aruco_or_standard_lower_2x", height//2, 2., False),
                (aruco, "aruco_or_standard_lower_clahe_3x", height//2, 3., True)]
    for factory, method, offset_y, scale, equalize in variants:
        source = gray[offset_y:]
        scaled = cv2.resize(source, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
        if equalize:
            scaled = cv2.createCLAHE(clipLimit=2., tileGridSize=(4, 4)).apply(scaled)
        _, payloads, corners, _ = factory().detectAndDecodeMulti(scaled)
        diagnostics["methods"].append(method)
        if corners is None:
            continue
        for payload, points in zip(payloads, corners):
            # Inverse resize pixel-center mapping, then undo the crop offset.
            original = (np.asarray(points, dtype=float)+.5)/scale-.5+[0, offset_y]
            if payload in IDS:
                same = [row for row in detections if _same_quad(row["cornersPixels"], original)]
                if not same:
                    detections.append({"payload": payload, "cornersPixels": original.tolist(), "identitySource": method})
            elif not any(_same_quad(original, quad) for quad in quads):
                quads.append(original)
        if len(quads) >= 2 or all(any(row.get("payload") == target for row in detections) for target in IDS):
            break
    for corners in quads[:16]:
        if any(_same_quad(row["cornersPixels"], corners) for row in detections):
            continue
        identified, evidence = _identify_undecoded(gray, corners)
        diagnostics["undecodedCandidates"].append(evidence)
        if identified is not None:
            detections.append(identified)
    return detections, "native_and_bounded_multiscale_exact_pattern", diagnostics


def _depth_pixel_geometry(frame):
    """Corroborate SDK pixel-ray metadata; never infer it from image size."""
    required = ("depthIntrinsics", "depthIntrinsicsSource", "depthSourceSize",
                "depthSourceIntrinsics", "depthImageTransform", "depthRGBGeometryCorrespondence",
                "rgbTransformationSize", "depthTransformationSize")
    missing = [name for name in required if frame.get(name) is None]
    report = {"status": "missing_evidence" if missing else "unchecked",
              "pixelCorrespondenceSupported": False, "missingEvidence": missing,
              "dimensionsAloneEstablishCorrespondence": False,
              "metadataOnlyNotMetricDepthValidation": True,
              "reportedSDKCorrespondence": frame.get("depthRGBGeometryCorrespondence")}
    if missing:
        return report
    try:
        width, height = frame["width"], frame["height"]
        def matrix(value, label):
            return _finite(value, (9,), label).reshape(3, 3)
        def pinhole(value, label):
            K = matrix(value, label)
            if min(K[0, 0], K[1, 1]) <= 0 or not np.allclose(K[2], [0, 0, 1], atol=1e-8, rtol=0):
                raise ValueError(label + " is not a finite pinhole matrix")
            return K
        if not isinstance(frame["depthIntrinsicsSource"], str) or not frame["depthIntrinsicsSource"]:
            raise ValueError("Actual depth intrinsic source is missing")
        depth_K = pinhole(frame["depthIntrinsics"], "Depth output intrinsics")
        source_K = pinhole(frame["depthSourceIntrinsics"], "Depth source intrinsics")
        transform = matrix(frame["depthImageTransform"], "Depth image transform")
        size = frame["depthSourceSize"]
        if not isinstance(size, list) or len(size) != 2 or any(type(v) is not int or not 1 <= v <= 8192 for v in size):
            raise ValueError("Actual depth source dimensions are invalid")
        if abs(float(np.linalg.det(transform))) < 1e-12:
            raise ValueError("Depth image transform is singular")
        if not (0 <= depth_K[0, 2] < width and 0 <= depth_K[1, 2] < height):
            raise ValueError("Depth principal point lies outside its output image")
        def reconstructed_K(transform, source):
            K = np.einsum("ij,jk->ik", transform, source)
            if not np.isfinite(K).all() or abs(K[2, 2]) < 1e-12:
                raise ValueError("Source/crop geometry does not reconstruct finite output intrinsics")
            return K/K[2, 2]
        reconstructed = reconstructed_K(transform, source_K)
        source_error = float(np.max(np.abs(reconstructed-depth_K)))
        fx, fy, cx, cy = _finite(frame["intrinsics"], (4,), "RGB output intrinsics")
        rgb_K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1.]])
        rgb_source_error = None
        if frame.get("rgbSourceIntrinsics") is not None and frame.get("rgbImageTransform") is not None:
            rgb_reconstructed = reconstructed_K(matrix(frame["rgbImageTransform"], "RGB image transform"),
                                              pinhole(frame["rgbSourceIntrinsics"], "RGB source intrinsics"))
            rgb_source_error = float(np.max(np.abs(rgb_reconstructed-rgb_K)))
        intrinsic_error = float(np.max(np.abs(depth_K-rgb_K)))
        observed = frame["depthRGBGeometryCorrespondence"]
        if not isinstance(observed, dict):
            raise ValueError("SDK correspondence observation is not an object")
        sdk_checks = {"reportedMatched": observed.get("status") == "matched",
                      "dimensionsMatch": observed.get("dimensionsMatch") is True,
                      "intrinsicsMatch": observed.get("intrinsicsMatch") is True,
                      "sdkAlignedToRGB": observed.get("sdkAlignedToRGB") is True,
                      "depthTransformationValid": observed.get("depthTransformationValid") is True,
                      "rgbTransformationValid": observed.get("rgbTransformationValid") is True}
        numeric_checks = {"outputIntrinsicDifferenceWithin0_001Pixels": intrinsic_error <= .001,
                          "depthSourceCropReconstructsOutputWithin0_001Pixels": source_error <= .001,
                          "RGBSourceCropConsistentWhenPresent": rgb_source_error is None or rgb_source_error <= .001,
                          "RGBTransformationSizeMatchesPixels": frame["rgbTransformationSize"] == [width, height],
                          "depthTransformationSizeMatchesPixels": frame["depthTransformationSize"] == [width, height]}
        supported = all(sdk_checks.values()) and all(numeric_checks.values())
        report.update({"status": "supported_sdk_metadata" if supported else "mismatched_evidence",
            "pixelCorrespondenceSupported": supported, "SDKChecks": sdk_checks, "numericChecks": numeric_checks,
            "maximumOutputIntrinsicDifferencePixels": intrinsic_error,
            "maximumDepthSourceCropDifferencePixels": source_error,
            "maximumRGBSourceCropDifferencePixels": rgb_source_error,
            "depthIntrinsics": depth_K.reshape(-1).tolist(), "depthSourceSize": size,
            "depthSourceIntrinsics": source_K.reshape(-1).tolist(),
            "depthImageTransform": transform.reshape(-1).tolist(),
            "rgbTransformationSize": frame["rgbTransformationSize"], "depthTransformationSize": frame["depthTransformationSize"],
            "rgbSourceDistortionCoefficients": frame.get("rgbSourceDistortionCoefficients"),
            "depthSourceDistortionCoefficients": frame.get("depthSourceDistortionCoefficients"),
            "rgbSourceDistortionModel": frame.get("rgbSourceDistortionModel"),
            "depthSourceDistortionModel": frame.get("depthSourceDistortionModel"),
            "sourceDistortionCoefficientsDescribeSourceSensorNotOutputWarp": True})
    except (ValueError, TypeError, KeyError, FloatingPointError) as error:
        report.update({"status": "invalid_evidence", "reason": str(error)})
    return report


def _depth_report(frame, corners, target, base, image_path, depth_path, pixel_geometry):
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
    residuals_within_limits = bool(coverage >= .5 and optical_stats["RMSEMeters"] <= .010 and
                                   optical_stats["p95AbsoluteMeters"] <= .030 and normal_angle <= 3)
    return {"targetID": target, "region": "15-percent inset; all valid native returns retained",
            "interiorPixelCount": sampled["interiorPixelCount"], "validFraction": coverage,
            "rawOpticalZMinusPnPPlaneIntersection": optical_stats,
            "signedPointToPnPPlane": plane_stats, "rawPlaneNormalDifferenceDegrees": normal_angle,
            "numericResidualsWithinDiagnosticLimits": residuals_within_limits,
            "comparisonAssumesUnverifiedSharedPixelRays": not pixel_geometry["pixelCorrespondenceSupported"],
            "pixelCorrespondenceSupported": pixel_geometry["pixelCorrespondenceSupported"],
            "withinDiagnosticLimits": bool(pixel_geometry["pixelCorrespondenceSupported"] and residuals_within_limits),
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
    detections, detector, detector_diagnostics = _detections(frame, gray)
    pixel_geometry = _depth_pixel_geometry(frame)
    K = np.array([[k[0], 0, k[2]], [0, k[1], k[3]], [0, 0, 1.]])
    objects = DEPTH.object_corners(.12)
    rows, poses, refined = [], [], []
    for target in IDS:
        matches = [row for row in detections if row.get("payload") == target]
        if len(matches) != 1:
            raise DetectionFailure(target+" must have exactly one strict printed-pattern match; "
                "candidate finder quads are retained separately", detector_diagnostics)
        corners, quality = REFINE.refine_image(gray, np.asarray(matches[0]["cornersPixels"]), target)
        pose, diagnostic = _poses(objects, corners, K, square=True)
        poses.append(pose); refined.append(corners)
        rows.append({"targetID": target, "cornersPixels": corners.tolist(), "patternQuality": quality,
                     "individualPnP": diagnostic, "targetToCameraColumnMajor": pose.T.reshape(-1).tolist(),
                     "rawDepth": _depth_report(frame, corners, target, base, image_path, depth_path, pixel_geometry)})
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
            "detector": detector, "detectorDiagnostics": detector_diagnostics,
            "cameraServiceSourceSHA256": frame.get("cameraServiceSourceSHA256"),
            "depthAlignmentMethod": frame.get("depthAlignmentMethod"), "depthRGBGeometry": pixel_geometry,
            "sequenceSource": frame.get("sequenceSource", "unspecified"),
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
            rejected.append({"frameIndex": index, "reason": str(error),
                             **({"detectorDiagnostics": error.diagnostics} if isinstance(error, DetectionFailure) else {})})
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
    summary = {key: result[key] for key in ("status", "acceptedFrameCount", "consistentPairFrameCount", "rawDepthAgreementAcrossConsistentFrames")}
    summary["rejectedFrames"] = [{"frameIndex": row["frameIndex"], "reason": row["reason"]} for row in result["rejectedFrames"]]
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
