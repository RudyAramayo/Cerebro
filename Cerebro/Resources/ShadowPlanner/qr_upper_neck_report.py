"""Offline fixed-target upper-neck diagnostics; no actuator or registration APIs.

QR-derived angles depend on camera intrinsics. Plane inclination uses the raw
model frame, not independently measured gravity. Neither is servo calibration.
"""

import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import sys

import cv2
import numpy as np

_SPEC = importlib.util.spec_from_file_location("qr_neck_pose_worker", Path(__file__).with_name("qr_neck_calibration.py"))
QR = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(QR)
TARGET_IDS = {"ROB:TABLE:001", "ROB:FLOOR:L01", "ROB:FLOOR:R01", "ROB:WALL:R01"}


def number(value, name):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f"{name} must be a finite number")
    return float(value)


def plane_for_view(view, folder, correction=None):
    """Fit only the eroded QR interior; absent depth never becomes a plane."""
    if folder is None:
        return None
    identifier = view["id"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", identifier):
        raise ValueError("Unsafe depth sample id")
    path = Path(folder) / f"{identifier}.depth-u16le"
    if not path.is_file():
        return None
    size = QR.numeric_array(view.get("imageSize"), (2,), "imageSize")
    if any(v != int(v) for v in size) or not all(16 <= v <= 4096 for v in size):
        raise ValueError("Invalid aligned depth dimensions")
    width, height = map(int, size)
    if path.stat().st_size != width * height * 2:
        raise ValueError(f"{identifier}: depth sample size mismatch")
    depth = np.frombuffer(path.read_bytes(), dtype="<u2").reshape(height, width)
    mask = np.zeros((height, width), dtype=np.uint8)
    cv2.fillConvexPoly(mask, np.rint(view["cornersPixels"]).astype(np.int32), 1)
    mask = cv2.erode(mask, np.ones((7, 7), np.uint8))
    yy, xx = np.where((mask != 0) & (depth >= 150) & (depth <= 5000))
    if len(xx) < 40:
        return None
    stride = max(1, int(math.ceil(len(xx) / 2000)))
    xx, yy = xx[::stride], yy[::stride]
    z = depth[yy, xx].astype(np.float64) / 1000
    fx, fy, cx, cy = view["cameraMatrix"]
    points = np.column_stack(((xx-cx)*z/fx, (yy-cy)*z/fy, z))
    selected = np.ones(len(points), dtype=bool)
    for _ in range(4):
        active = points[selected]
        if len(active) < 40:
            return None
        center = np.mean(active, axis=0)
        _, singular, vt = np.linalg.svd(active-center, full_matrices=False)
        if singular[1] < 0.005:
            return None
        normal = vt[-1]
        residuals = np.einsum("ij,j->i", points-center, normal)
        scale = 1.4826 * np.median(np.abs(residuals[selected]-np.median(residuals[selected])))
        selected = np.abs(residuals) <= max(0.003, 3*scale)
    active = points[selected]
    if len(active) < 40:
        return None
    center = np.mean(active, axis=0)
    _, _, vt = np.linalg.svd(active-center, full_matrices=False)
    normal = vt[-1]
    if normal[2] > 0:
        normal = -normal
    raw = QR.rigid_matrix(view.get("rawCameraToBase"), "rawCameraToBase")
    base_normal = raw[:3, :3] @ normal
    if base_normal[2] < 0:
        base_normal = -base_normal
    result = {"sampleCount": len(points), "inlierCount": int(selected.sum()),
              "orthogonalRMSEMeters": float(np.sqrt(np.mean(np.einsum("ij,j->i", active-center, normal)**2))),
              "normalOptical": normal.tolist(), "normalRawBase": base_normal.tolist(),
              "inclinationFromRawBaseHorizontalDegrees": math.degrees(math.acos(float(np.clip(base_normal[2], -1, 1)))),
              "riseAlongRawBaseXDegrees": math.degrees(math.atan2(-base_normal[0], base_normal[2])),
              "riseAlongRawBaseYDegrees": math.degrees(math.atan2(-base_normal[1], base_normal[2]))}
    if correction is not None:
        if not isinstance(correction, dict):
            raise ValueError("displayDepthCorrection must be an object")
        pitch = number(correction.get("downwardPitchDegrees"), "downwardPitchDegrees")
        if not -90 <= pitch <= 90:
            raise ValueError("Invalid display correction pitch")
        rotation = cv2.Rodrigues(np.array([-math.radians(pitch), 0., 0.]))[0]
        corrected = raw[:3, :3] @ rotation @ normal
        if corrected[2] < 0:
            corrected = -corrected
        result["normalDisplayBase"] = corrected.tolist()
        result["riseAlongDisplayBaseXDegrees"] = math.degrees(math.atan2(-corrected[0], corrected[2]))
        result["riseAlongDisplayBaseYDegrees"] = math.degrees(math.atan2(-corrected[1], corrected[2]))
        result["inclinationFromDisplayBaseHorizontalDegrees"] = math.degrees(math.acos(float(np.clip(corrected[2], -1, 1))))
    return result



MINIMUM_SCALE_SPAN_TARGET_UNITS = 100
NOMINAL_DEGREES_PER_TARGET_UNIT_PRIOR = 0.03


def angle_scale_candidates(holds):
    """Train only first visits; repeats never tune a fitted coefficient."""
    first = {}
    for index, hold in enumerate(holds):
        first.setdefault(hold["upperTarget"], index)
    training_indices = set(first.values())

    def candidate(values, minimum_returns=2):
        selected = [i for i in sorted(training_indices) if values[i] is not None]
        targets = {holds[i]["upperTarget"] for i in selected}
        validation = [i for i in range(len(holds)) if i not in training_indices
                      and holds[i]["upperTarget"] in targets and values[i] is not None]
        span = max(targets)-min(targets) if targets else 0
        result = {"status": "unavailable", "candidateURDFReady": False,
                  "uniqueTrainingTargetCount": len(targets), "targetSpanUnits": span,
                  "minimumUniqueTrainingTargets": 3, "minimumReturnHolds": minimum_returns,
                  "minimumSpanTargetUnits": MINIMUM_SCALE_SPAN_TARGET_UNITS,
                  "trainingHoldIndices": selected, "heldOutReturnHoldIndices": validation,
                  "nominalDegreesPerTargetUnitPrior": NOMINAL_DEGREES_PER_TARGET_UNIT_PRIOR,
                  "nominalPriorIsMeasured": False, "zeroAndMountOffsetIdentifiable": False}
        if len(targets) < 3 or span < MINIMUM_SCALE_SPAN_TARGET_UNITS or len(validation) < minimum_returns:
            result["reason"] = "Need three distinct first-visit levels spanning at least 100 target units and sufficient return holds."
            return result
        reference = holds[selected[0]]["upperTarget"]
        x = np.array([hold["upperTarget"]-reference for hold in holds], dtype=np.float64)
        y = np.array([value if value is not None else 0. for value in values], dtype=np.float64)
        matrix = np.column_stack((np.ones(len(holds)), x))
        coefficients = np.linalg.lstsq(matrix[selected], y[selected], rcond=None)[0]
        predicted = matrix @ coefficients
        residual = y-predicted
        result.update(status="candidate_unverified", referenceUpperTarget=reference,
                      diagnosticAngleAtReferenceDegrees=float(coefficients[0]),
                      degreesPerTargetUnit=float(coefficients[1]),
                      gainRelativeToNominalPrior=float(coefficients[1]/NOMINAL_DEGREES_PER_TARGET_UNIT_PRIOR),
                      trainingRMSEDegrees=float(np.sqrt(np.mean(residual[selected]**2))),
                      heldOutReturnRMSEDegrees=float(np.sqrt(np.mean(residual[validation]**2))) if validation else None,
                      heldOutReturnResidualsDegrees=residual[validation].tolist(),
                      heldOutValidationAvailable=bool(validation))
        return result

    qr_values = [hold["qrInferredCameraPitchChangeDegrees"] for hold in holds]
    depth_values = []
    for hold in holds:
        angles = [math.degrees(math.atan2(-plane["normalOptical"][1], -plane["normalOptical"][2]))
                  for plane in hold["planes"] if plane["inlierCount"] >= 40
                  and plane["orthogonalRMSEMeters"] <= .005]
        depth_values.append(float(np.median(angles)) if angles else None)
    result = {"status": "diagnostic_only", "candidateURDFReady": False,
              "zeroAndMountOffsetIdentifiable": False,
              "qrPitch": candidate(qr_values), "depthPlanePitch": candidate(depth_values),
              "limitations": ["Only first visits train the line; return visits are held out.",
                              "The 0.03 degree/target value is a nominal comparison prior, not measured calibration.",
                              "QR and depth angles share intrinsics; agreement is not independent validation.",
                              "A single upper-neck sweep cannot identify camera mount offset separately from servo zero.",
                              "No gain, zero offset, URDF or registration change is applied."]}
    manual_values = [hold["protractorPitchDegrees"] for hold in holds]
    references = {hold["protractorReference"] for hold in holds if hold["protractorPitchDegrees"] is not None}
    if references and None not in references and len(references) == 1:
        result["protractorPitch"] = candidate(manual_values, minimum_returns=0)
        result["protractorPitch"]["reference"] = next(iter(references))
        if result["protractorPitch"]["status"] == "candidate_unverified" and result["qrPitch"]["status"] == "candidate_unverified":
            result["qrMinusProtractorDegreesPerTargetUnit"] = (result["qrPitch"]["degreesPerTargetUnit"]
                                                               - result["protractorPitch"]["degreesPerTargetUnit"])
    else:
        result["protractorPitch"] = {"status": "unavailable", "candidateURDFReady": False,
                                      "reason": "Need at least three measured first-visit targets using one stated protractor reference."}
    return result


def report(document, capture_dir=None):
    if not isinstance(document, dict) or type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
        raise ValueError("Expected schemaVersion 1 object")
    if document.get("targetID") not in TARGET_IDS or document.get("symbolSideMeters") != .12:
        raise ValueError("Expected a supported measured 120 mm ROB target")
    views = document.get("views")
    if not isinstance(views, list) or not 1 <= len(views) <= 128 or not all(isinstance(v, dict) for v in views):
        raise ValueError("Expected 1 to 128 views")
    baseline_pan = number(views[0].get("neckPanDegrees"), "neckPanDegrees")
    baseline_lower = views[0].get("lowerTarget")
    if type(baseline_lower) is not int or not 1 <= baseline_lower <= 16383:
        raise ValueError("Invalid lowerTarget")
    readings = document.get("protractorReadings", [])
    if not isinstance(readings, list) or len(readings) > 256:
        raise ValueError("protractorReadings must be a bounded list")
    manual = []
    for reading in readings:
        if not isinstance(reading, dict) or type(reading.get("stepIndex")) not in (str, int):
            raise ValueError("Each protractor reading needs a stepIndex")
        pitch = number(reading.get("pitchDegrees"), "pitchDegrees")
        reference = reading.get("reference")
        if not -180 <= pitch <= 180 or not isinstance(reference, str) or not 1 <= len(reference) <= 256:
            raise ValueError("Each protractor reading needs bounded pitch and reference")
        manual.append({"stepIndex": reading["stepIndex"], "pitchDegrees": pitch, "reference": reference})
    groups = []
    identifiers = set()
    previous_time = previous_sequence = None
    for view in views:
        if not isinstance(view, dict):
            raise ValueError("Each view must be an object")
        if view.get("targetID", document["targetID"]) != document["targetID"]:
            raise ValueError("Mixed QR target identities")
        if view.get("lowerTarget") != baseline_lower or abs(number(view.get("neckPanDegrees"), "neckPanDegrees")-baseline_pan) > .05:
            raise ValueError("Upper-neck diagnostics require fixed lower target and pan")
        upper = view.get("neckUpperTarget")
        if type(upper) is not int or not 1 <= upper <= 16383:
            raise ValueError("Invalid neckUpperTarget")
        if "requestedLowerTarget" in view and view["requestedLowerTarget"] != baseline_lower:
            raise ValueError("Accepted lower target differs from requested lower target")
        if "requestedUpperTarget" in view and view["requestedUpperTarget"] != upper:
            raise ValueError("Accepted upper target differs from requested upper target")
        if "requestedPanDegrees" in view and abs(number(view["requestedPanDegrees"], "requestedPanDegrees")-baseline_pan) > .05:
            raise ValueError("Accepted pan differs from requested pan")
        identifier = view.get("id")
        if not isinstance(identifier, str) or identifier in identifiers:
            raise ValueError("Unique string view ids are required")
        identifiers.add(identifier)
        timestamp = number(view.get("capturedAtMilliseconds"), "capturedAtMilliseconds")
        sequence = view.get("sequence")
        if timestamp <= 0 or type(sequence) is not int or sequence <= 0:
            raise ValueError("Invalid capture timestamp or sequence")
        if previous_time is not None and (timestamp <= previous_time or sequence <= previous_sequence):
            raise ValueError("Capture timestamps and sequences must advance")
        previous_time, previous_sequence = timestamp, sequence
        pose = QR.pose_for_view(view)
        if pose["poseAmbiguous"]:
            raise ValueError(f"{identifier}: ambiguous planar QR pose")
        step = view.get("stepIndex", identifier.rsplit("-", 1)[0])
        if type(step) not in (str, int):
            raise ValueError("Invalid stepIndex")
        if not groups or groups[-1]["key"] != step:
            if any(g["key"] == step for g in groups):
                raise ValueError("A step must contain contiguous captured samples")
            groups.append({"key": step, "upper": upper, "items": []})
        if groups[-1]["upper"] != upper:
            raise ValueError("Upper target changed within one hold")
        plane = plane_for_view(view, capture_dir, document.get("displayDepthCorrection"))
        groups[-1]["items"].append((view, pose, plane))
    holds = []
    rotations = []
    for group in groups:
        items = group["items"]
        representative = QR.mean_transform([pose["targetToCamera"] for _, pose, _ in items])
        rotations.append(representative[:3, :3])
        centers = np.array([v.get("centerPixel", np.mean(v["cornersPixels"], axis=0)) for v, _, _ in items])
        depths = [pose["centerDepthMeters"] for _, pose, _ in items if pose["centerDepthMeters"] is not None]
        hold = {"stepIndex": group["key"], "upperTarget": group["upper"], "sampleCount": len(items),
                "viewIDs": [v["id"] for v, _, _ in items], "medianCenterPixel": np.median(centers, axis=0).tolist(),
                "centerPixelMaximumScatter": float(np.max(np.linalg.norm(centers-np.median(centers, axis=0), axis=1))),
                "medianCenterDepthMeters": float(np.median(depths)) if depths else None,
                "medianPoseCenterDepthResidualMeters": float(np.median([pose["centerDepthResidualMeters"] for _, pose, _ in items if pose["centerDepthResidualMeters"] is not None])) if depths else None,
                "targetNormalOptical": representative[:3, 2].tolist(),
                "planes": [{"viewID": v["id"], **plane} for v, _, plane in items if plane is not None]}
        angles = [number(v["protractorPitchDegrees"], "protractorPitchDegrees") for v, _, _ in items if v.get("protractorPitchDegrees") is not None]
        matching = [r for r in manual if r["stepIndex"] == group["key"]]
        references = {r["reference"] for r in matching}
        if len(references) > 1:
            raise ValueError("One hold has inconsistent protractor references")
        if matching:
            angles = [r["pitchDegrees"] for r in matching]
        hold["protractorPitchDegrees"] = float(np.median(angles)) if angles else None
        hold["protractorReference"] = matching[0]["reference"] if matching else None
        holds.append(hold)
    for index, (hold, rotation) in enumerate(zip(holds, rotations)):
        relative = rotation @ rotations[0].T
        hold["qrRelativeCameraRotationDegrees"] = QR.rotation_degrees(relative)
        hold["qrRelativeOpticalXRotationDegrees"] = math.degrees(float(cv2.Rodrigues(relative)[0][0, 0]))
        hold["qrInferredCameraPitchChangeDegrees"] = -hold["qrRelativeOpticalXRotationDegrees"]
        if hold["protractorPitchDegrees"] is not None and holds[0]["protractorPitchDegrees"] is not None and hold["protractorReference"] == holds[0]["protractorReference"]:
            hold["protractorPitchChangeDegrees"] = hold["protractorPitchDegrees"]-holds[0]["protractorPitchDegrees"]
            hold["qrVersusProtractorPitchChangeDifferenceDegrees"] = hold["qrInferredCameraPitchChangeDegrees"]-hold["protractorPitchChangeDegrees"]
        else:
            hold["protractorPitchChangeDegrees"] = None
            hold["qrVersusProtractorPitchChangeDifferenceDegrees"] = None
        hold["qrNormalChangeDegrees"] = math.degrees(math.acos(float(np.clip(rotation[:, 2] @ rotations[0][:, 2], -1, 1))))
        hold["centerMotionFromPreviousPixels"] = float(np.linalg.norm(np.array(hold["medianCenterPixel"])-holds[index-1]["medianCenterPixel"])) if index else 0.
    if any(not any(h["stepIndex"] == r["stepIndex"] for h in holds) for r in manual):
        raise ValueError("Protractor reading refers to an uncaptured step")
    repeats = []
    for upper in sorted({hold["upperTarget"] for hold in holds}):
        indices = [i for i, hold in enumerate(holds) if hold["upperTarget"] == upper]
        if len(indices) < 2:
            continue
        pairs = [(i, j) for position, i in enumerate(indices) for j in indices[position+1:]]
        pixel = max(float(np.linalg.norm(np.array(holds[i]["medianCenterPixel"])-holds[j]["medianCenterPixel"])) for i, j in pairs)
        angular = max(QR.rotation_degrees(rotations[i] @ rotations[j].T) for i, j in pairs)
        depth = [abs(holds[i]["medianCenterDepthMeters"]-holds[j]["medianCenterDepthMeters"]) for i, j in pairs if holds[i]["medianCenterDepthMeters"] is not None and holds[j]["medianCenterDepthMeters"] is not None]
        repeats.append({"upperTarget": upper, "holdIndices": indices, "maximumCenterDifferencePixels": pixel,
                        "maximumQRRotationDifferenceDegrees": angular, "maximumDepthDifferenceMeters": max(depth) if depth else None})
    return {"schemaVersion": 1, "status": "upper_neck_diagnostic_unverified", "registrationVerified": False,
            "targetID": document["targetID"], "panDegrees": baseline_pan, "lowerTarget": baseline_lower,
            "captureKind": document.get("captureKind"), "angleScaleCandidates": angle_scale_candidates(holds), "holdCount": len(holds), "sampleCount": len(views), "holds": holds, "repeatedTargets": repeats,
            "warnings": ["QR-derived angles depend on RGB intrinsics, corner correspondence and fixed target placement.",
                         "Inferred pitch assumes the upper-neck rotation is about optical X; camera pitch is positive nose-up. Protractor changes require the same reference as the first hold.",
                         "Accepted servo targets are not measured shaft feedback; no servo gain or registration was applied.",
                         "Plane inclination uses the raw model/base or explicitly recorded display correction, not measured gravity.",
                         "Depth is fitted only within the QR interior; this does not flatten or certify the full table or floor."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        data = args.input.read_bytes()
        if len(data) > 2_000_000:
            raise ValueError("Capture file exceeds 2 MB")
        document = json.loads(data, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"Invalid JSON number {value}")))
        result = report(document, args.input.parent)
        status = 0
    except (ValueError, TypeError, KeyError, OSError, cv2.error, np.linalg.LinAlgError) as error:
        result = {"schemaVersion": 1, "status": "rejected", "registrationVerified": False, "error": str(error)}
        print(str(error), file=sys.stderr)
        status = 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False)+"\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
