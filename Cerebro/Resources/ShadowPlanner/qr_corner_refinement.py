"""Offline exact-pattern QR corner refinement; no camera, motor or registration IO.

Templates are the actual 21-module version-1/Q patterns in ROB's printable
120 mm sheets, rather than a fresh encoder's possibly different mask choice.
Input captures and source JPEGs are immutable. Refined copies remain unverified.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re

import cv2
import numpy as np


# 1 denotes a printed black module. These rows match the vector PDF generator.
_PATTERNS = {
    "ROB:TABLE:001": ("9b25e1eef940e2cfde7a15c7b3ca4057b5757dd5e10332e3208c0552e561c11f", """
111111100011001111111
100000100010001000001
101110101001101011101
101110100011001011101
101110101011101011101
100000101011001000001
111111101010101111111
000000000010000000000
010010101011110110100
011011000010111001100
010110110100000111010
001111001101100101010
000000101001111001000
000000001001011011111
111111100000100100111
100000100011101100001
101110101000011000101
101110100100111010011
101110100010100111000
100000101111100110101
111111100111011001111
"""),
    "ROB:FLOOR:L01": ("23babcc6738e353dfa379260cb95d73c9e224537c2adb20173b554881f818863", """
111111100001101111111
100000100111001000001
101110100010001011101
101110101101001011101
101110100110101011101
100000101100001000001
111111101010101111111
000000001111000000000
011000100100001101000
010100011010010111011
000110111010010011101
111111000101000110010
001001101001010100000
000000001000100011000
111111100011111001000
100000100001101000101
101110100111011011001
101110100010000001100
101110101110011101011
100000101100100010001
111111100000011111011
"""),
    "ROB:FLOOR:R01": ("56e91647e549e73698561020484ffb6a456aac649a8f0a5f3a4a58ce1601632a", """
111111101010001111111
100000100110001000001
101110101111001011101
101110101101101011101
101110100101001011101
100000101010001000001
111111101010101111111
000000001110000000000
010101111001011101101
111001010110100000001
100110101011000010101
001100001100000010001
011101110000000001010
000000001000100100000
111111101111100101011
100000101111011101111
101110100100111100001
101110101110011101111
101110100011001000001
100000101111100101001
111111100000000011000
"""),
    "ROB:WALL:R01": ("3873f1bda89c3513065974494fdedf4e3f57dbf0e128808ed71d3b95566505d8", """
111111101011101111111
100000101111001000001
101110101100101011101
101110101111101011101
101110101001001011101
100000100011101000001
111111101010101111111
000000001000100000000
011010110000101011111
001001000010110100001
101111110101101010111
011011000000110011000
011001111010100111010
000000001111110000010
111111101110101101011
100000100011110010011
101110101001001110011
101110100000001011110
101110101010100010001
100000101100001111111
111111100110101101101
"""),
}
MODULE_PIXELS = 12
QUIET_MODULES = 4
MINIMUM_CORRELATION = 0.94
MINIMUM_ORIENTATION_MARGIN = 0.02


def symbol(target_id):
    if target_id not in _PATTERNS:
        raise ValueError("Unsupported exact QR pattern")
    rows = _PATTERNS[target_id][1].strip().splitlines()
    if len(rows) != 21 or any(len(row) != 21 or set(row)-set("01") for row in rows):
        raise ValueError("Invalid bundled QR pattern")
    return np.array([[0 if char == "1" else 255 for char in row] for row in rows], dtype=np.uint8)


def template(target_id):
    image = cv2.resize(np.pad(symbol(target_id), QUIET_MODULES, constant_values=255),
                       (29*MODULE_PIXELS, 29*MODULE_PIXELS), interpolation=cv2.INTER_NEAREST)
    # Pixel coordinates denote pixel centers. The physical black/white boundary
    # lies half a pixel before the first black pixel, not at its center.
    a = QUIET_MODULES*MODULE_PIXELS-0.5
    b = a+21*MODULE_PIXELS
    corners = np.array([[a, a], [b, a], [b, b], [a, b]], dtype=np.float32)
    return image, corners


def corners_array(value, width, height):
    corners = np.asarray(value, dtype=np.float64)
    if corners.shape != (4, 2) or not np.isfinite(corners).all():
        raise ValueError("Expected four finite QR corners")
    if np.any(corners < 0) or np.any(corners[:, 0] >= width) or np.any(corners[:, 1] >= height):
        raise ValueError("QR corner is outside the source image")
    edges = np.roll(corners, -1, axis=0)-corners
    crosses = edges[:, 0]*np.roll(edges[:, 1], -1)-edges[:, 1]*np.roll(edges[:, 0], -1)
    if not np.all(crosses > 1) or min(np.linalg.norm(edges, axis=1)) < 12:
        raise ValueError("QR corners are reversed, degenerate or too small")
    return corners


def projective_center(corners):
    unit = np.array([[0., 0.], [1., 0.], [1., 1.], [0., 1.]], dtype=np.float32)
    h = cv2.getPerspectiveTransform(unit, np.asarray(corners, dtype=np.float32))
    return cv2.perspectiveTransform(np.array([[[.5, .5]]], dtype=np.float64), h)[0, 0]


def _refine_orientation(gray, initial, target_id):
    """Fit one cyclic correspondence; displacement uses that correspondence."""
    height, width = gray.shape
    reference, canonical = template(target_id)
    h = cv2.getPerspectiveTransform(canonical, initial.astype(np.float32))
    observed = cv2.warpPerspective(gray.astype(np.float32)/255, h, reference.shape[::-1],
                                  flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP)
    reference_float = cv2.GaussianBlur(reference.astype(np.float32)/255, (5, 5), 1.5)
    try:
        correlation, warp = cv2.findTransformECC(
            reference_float, observed, np.eye(3, dtype=np.float32), cv2.MOTION_HOMOGRAPHY,
            (cv2.TERM_CRITERIA_COUNT | cv2.TERM_CRITERIA_EPS, 100, 1e-6), None, 5)
    except cv2.error as exc:
        raise ValueError("Exact-pattern homography did not converge") from exc
    if not np.isfinite(warp).all() or not np.isfinite(correlation):
        raise ValueError("Exact-pattern homography produced invalid geometry or correlation")
    refined = cv2.perspectiveTransform(canonical[None], h@warp)[0].astype(np.float64)
    refined = corners_array(refined, width, height)
    displacement = np.linalg.norm(refined-initial, axis=1)
    edge = min(np.linalg.norm(np.roll(initial, -1, axis=0)-initial, axis=1))
    if max(displacement) > max(4., .06*edge):
        raise ValueError("Refinement moved too far from the observed QR corners")
    aligned = cv2.warpPerspective(gray.astype(np.float32), h@warp, reference.shape[::-1],
                                 flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP)
    cell_center = (np.arange(21)+.5)*MODULE_PIXELS+QUIET_MODULES*MODULE_PIXELS-.5
    xx, yy = np.meshgrid(cell_center, cell_center)
    samples = cv2.remap(aligned, xx.astype(np.float32), yy.astype(np.float32), cv2.INTER_LINEAR)
    pattern = symbol(target_id)
    contrast = float(np.median(samples[pattern == 255])-np.median(samples[pattern == 0]))
    if contrast < 20:
        raise ValueError("Printed module contrast is too low for measured refinement")
    return refined, {"correlation": float(correlation), "moduleContrastGrayLevels": contrast,
                     "cornerDisplacementPixels": displacement.tolist(),
                     "cornerDisplacementRMSEPixels": float(np.sqrt(np.mean(displacement**2)))}


def refine_image(gray, initial_corners, target_id):
    """Resolve printed orientation rather than assuming image-top-left is TL.

    A clockwise detector quadrilateral may start at any image corner. Try only
    its four cyclic permutations: reversing its winding is never permitted.
    Exact module content selects canonical printed TL/TR/BR/BL correspondence.
    """
    if not isinstance(gray, np.ndarray) or gray.ndim != 2 or gray.dtype != np.uint8:
        raise ValueError("Expected an unsigned 8-bit grayscale source image")
    height, width = gray.shape
    initial = corners_array(initial_corners, width, height)
    candidates, attempts = [], []
    for rotation in range(4):
        ordered = np.roll(initial, -rotation, axis=0)
        try:
            refined, quality = _refine_orientation(gray, ordered, target_id)
            candidates.append((quality["correlation"], rotation, refined, quality))
            attempts.append({"rotationSteps": rotation, "correlation": quality["correlation"],
                             "status": "geometrically_valid"})
        except ValueError as exc:
            attempts.append({"rotationSteps": rotation, "status": "rejected", "reason": str(exc)})
    if not candidates:
        raise ValueError("No cyclic corner orientation matched the exact printed QR pattern")
    candidates.sort(key=lambda item: item[0], reverse=True)
    best, rotation, refined, quality = candidates[0]
    runner = candidates[1][0] if len(candidates) > 1 else None
    if best < MINIMUM_CORRELATION:
        raise ValueError("Source image does not sufficiently match the exact printed QR pattern")
    if runner is not None and best-runner < MINIMUM_ORIENTATION_MARGIN:
        raise ValueError("Printed QR corner orientation is ambiguous; original corners retained")
    quality = {**quality, "rotationSteps": rotation, "bestCorrelation": best,
               "runnerUpCorrelation": runner,
               "runnerUpCorrelationScope": "geometrically valid cyclic correspondences only; null if none",
               "rotationStepsMeaning": "Roll the original clockwise detector array left by this many entries to obtain canonical printed corners.",
               "orientationCorrelationMargin": best-runner if runner is not None else None,
               "orientationCandidates": attempts,
               "cornerOrder": "canonical_printed_topLeft_topRight_bottomRight_bottomLeft"}
    return refined, quality


def refine_capture(input_path, output_path):
    input_path, output_path = Path(input_path), Path(output_path)
    if input_path.resolve() == output_path.resolve():
        raise ValueError("Write a new diagnostic copy; never replace the source capture")
    source = input_path.read_bytes()
    document = json.loads(source)
    if (not isinstance(document, dict) or type(document.get("schemaVersion")) is not int
            or document["schemaVersion"] != 1 or document.get("symbolSideMeters") != .12):
        raise ValueError("Expected a version-1 measured 120 mm capture")
    if "cornerRefinement" in document:
        raise ValueError("Refinement must start from the original capture, not a refined copy")
    target_id = document.get("targetID")
    pattern = symbol(target_id)
    views = document.get("views")
    if (not isinstance(views, list) or not 1 <= len(views) <= 128
            or not all(isinstance(view, dict) for view in views)):
        raise ValueError("Expected 1 to 128 captured views")
    accepted = 0
    for view in views:
        identifier = view.get("id")
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", identifier):
            raise ValueError("Unsafe source image identifier")
        if view.get("targetID", target_id) != target_id:
            raise ValueError("Mixed target identities are not permitted")
        image = cv2.imread(str(input_path.parent/(identifier+".jpg")), cv2.IMREAD_GRAYSCALE)
        if image is None:
            raise ValueError("A source JPEG is unavailable")
        if view.get("imageSize") != [image.shape[1], image.shape[0]]:
            raise ValueError("Source JPEG and recorded image size disagree")
        original = corners_array(view.get("cornersPixels"), image.shape[1], image.shape[0])
        try:
            refined, quality = refine_image(image, original, target_id)
        except ValueError as exc:
            view["cornerRefinement"] = {"status": "rejected_raw_retained", "reason": str(exc)}
            continue
        view["rawCornersPixelsBeforeRefinement"] = original.tolist()
        view["rawCornersNormalizedBeforeRefinement"] = view.get("cornersNormalized")
        view["rawCenterPixelBeforeRefinement"] = view.get("centerPixel")
        view["cornersPixels"] = refined.tolist()
        view["cornersNormalized"] = [[float(x/image.shape[1]), float(1-y/image.shape[0])] for x, y in refined]
        view["centerPixel"] = projective_center(refined).tolist()
        view["cornerRefinement"] = {"status": "accepted_diagnostic", **quality,
                                     "sourceImageSHA256": hashlib.sha256((input_path.parent/(identifier+".jpg")).read_bytes()).hexdigest()}
        accepted += 1
    document["registrationVerified"] = False
    document["cornerRefinement"] = {
        "status": "diagnostic_only", "method": "exact_printed_modules_ECC_homography", "methodVersion": 2,
        "sourceCaptureSHA256": hashlib.sha256(source).hexdigest(),
        "acceptedViews": accepted, "rejectedViews": len(views)-accepted,
        "templateModuleSHA256": hashlib.sha256(pattern.tobytes()).hexdigest(),
        "templateReferencePDFSHA256": _PATTERNS[target_id][0],
        "templateVersion": 1, "templateErrorCorrection": "Q", "templateModuleCount": 21,
        "minimumCorrelation": MINIMUM_CORRELATION,
        "minimumOrientationCorrelationMargin": MINIMUM_ORIENTATION_MARGIN,
        "orientationPolicy": "Test four cyclic clockwise detector-corner permutations against exact printed modules; reject ambiguous correspondence. Output follows canonical printed TL/TR/BR/BL, regardless of page rotation in the image.",
        "physicalBoundaryConvention": "Pixel centers are integer coordinates; module edges lie at half-pixels in the rasterized template.",
        "limitations": ["Image-template agreement is not measured camera or servo calibration.",
                        "Rejected views retain their original corners; filter by per-view refinement status for comparisons.",
                        "All depth, raw-model estimates and neck records remain original observations; center-depth/estimatedMarkerCenterBase refer to the original sampling location.",
                        "No intrinsic matrix, neck zero/gain, URDF or registration is changed."]}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(document, indent=2)+"\n")
    return document


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_capture", type=Path)
    parser.add_argument("output_capture", type=Path)
    args = parser.parse_args()
    try:
        result = refine_capture(args.input_capture, args.output_capture)
        print(json.dumps(result["cornerRefinement"], indent=2))
    except (ValueError, OSError, json.JSONDecodeError) as error:
        parser.exit(1, str(error)+"\n")
