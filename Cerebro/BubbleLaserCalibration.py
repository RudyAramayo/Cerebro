"""OpenCV observation of a cutting-mat grid and a red aiming dot. No hardware I/O.

Pixels use the original image's top-left origin. Mat coordinates are millimetres
from the operator-marked top-left intersection, never robot coordinates.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def _image(image):
    if (image is None or image.dtype != np.uint8 or image.ndim != 3
            or image.shape[2] != 3 or min(image.shape[:2]) < 16
            or image.shape[0] * image.shape[1] > 16_000_000):
        raise ValueError("Use a BGR uint8 image between 16 pixels and 16 megapixels.")


def grid(image, cols, rows, spacing_mm, quad=None):
    """The four marked *intersections* span cols-1 by rows-1 squares."""
    _image(image)
    if not 2 <= cols <= 30 or not 2 <= rows <= 30 or not 1 <= spacing_mm <= 200:
        raise ValueError("Use 2–30 intersections per axis and 1–200 mm spacing.")
    height, width = image.shape[:2]
    board_points = np.array([(c, r) for r in range(rows) for c in range(cols)], np.float32)
    if quad is None:
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        found, corners = cv2.findChessboardCornersSB(gray, (cols, rows), flags=cv2.CALIB_CB_NORMALIZE_IMAGE)
        if not found:
            return {"found": False, "detail": "Mark four intersections for a line grid, or show the complete checkerboard."}
        corners = corners.reshape(-1, 2)
        # Keep image-top-left ordering for the initial view; the saved image and
        # full corner array retain the evidence. The operator must keep the mat
        # fixed and the same physical origin visible across head-pose passes.
        if float(corners[0].sum()) > float(corners[-1].sum()):
            corners = corners[::-1].copy()
        method = "checkerboard"
    else:
        quad = np.asarray(quad, np.float32)
        if (quad.shape != (4, 2) or not np.isfinite(quad).all()
                or np.any(quad < 0) or np.any(quad[:, 0] >= width)
                or np.any(quad[:, 1] >= height)):
            raise ValueError("Mark four in-image intersections: top-left, top-right, bottom-right, bottom-left.")
        contour = quad.reshape(-1, 1, 2)
        if not cv2.isContourConvex(contour) or cv2.contourArea(contour, oriented=True) < 100:
            raise ValueError("Grid corners must form a clockwise, non-crossing rectangle in the image.")
        h = cv2.getPerspectiveTransform(np.array([[0, 0], [cols-1, 0], [cols-1, rows-1], [0, rows-1]], np.float32), quad)
        corners = cv2.perspectiveTransform(board_points.reshape(-1, 1, 2), h).reshape(-1, 2)
        method = "marked_line_grid"
    h, _ = cv2.findHomography(corners, board_points * spacing_mm, 0)
    if h is None or not np.isfinite(h).all() or np.linalg.cond(h) > 1e10:
        raise ValueError("The grid is too oblique or degenerate; choose a clearer rectangular patch.")
    outline = corners[[0, cols-1, cols*rows-1, cols*(rows-1)]]
    return {"found": True, "method": method, "cols": cols, "rows": rows,
            "spacingMM": float(spacing_mm), "corners": corners.tolist(),
            "outline": outline.tolist(), "imageToMat": h.tolist()}


def detect_red_dot(image, background=None, board=None):
    _image(image)
    height, width = image.shape[:2]
    b, g, r = [x.astype(np.float32) for x in cv2.split(image)]
    excess = r - np.maximum(g, b)
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    red = (cv2.inRange(hsv, (0, 65, 125), (12, 255, 255))
           | cv2.inRange(hsv, (168, 65, 125), (179, 255, 255)))
    red[excess < 30] = 0
    max_diameter = max(10, min(70, min(width, height) * 0.09))
    region = np.full((height, width), 255, np.uint8)
    if board and board.get("found"):
        region[:] = 0
        cv2.fillConvexPoly(region, np.rint(board["outline"]).astype(np.int32), 255)
        # Leave room for the whole dot at the four calibration corners. Cutting
        # its halo at the polygon edge would bias the centroid inward.
        padding = int(np.ceil(max_diameter / 2)) + 2
        region = cv2.dilate(region, np.ones((padding * 2 + 1, padding * 2 + 1), np.uint8))
    delta = None
    if background is not None:
        _image(background)
        if background.shape != image.shape:
            raise ValueError("Laser-off and laser-on images must have the same dimensions.")
        bb, bg, br = [x.astype(np.float32) for x in cv2.split(background)]
        delta = excess - (br - np.maximum(bb, bg))
        # Reject scene/board motion instead of interpreting newly exposed red
        # printing as a laser. A global exposure shift is removed first.
        gray_delta = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY).astype(np.float32) - cv2.cvtColor(background, cv2.COLOR_BGR2GRAY)
        inside = region > 0
        gray_delta -= np.median(gray_delta[inside])
        changed = (np.abs(gray_delta) > 25) & inside
        if np.count_nonzero(changed) / max(1, np.count_nonzero(inside)) > 0.035:
            return {"status": "reference_changed", "candidates": [], "usedBackground": True,
                    "detail": "The mat, camera, or lighting changed. Capture a fresh laser-off reference."}, red & region
        red[(delta < 22) | (r - br < 12)] = 0
    red &= region
    # Closing retains a tiny spot and joins its red halo around a white-hot core.
    mask = cv2.morphologyEx(red, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    candidates = []
    for contour in contours:
        area = cv2.contourArea(contour)
        x, y, w, h = cv2.boundingRect(contour)
        perimeter = cv2.arcLength(contour, True)
        circularity = 4 * np.pi * area / max(perimeter * perimeter, 1)
        if not (2 <= area <= np.pi * (max_diameter / 2) ** 2 and max(w, h) <= max_diameter
                and max(w, h) / max(1, min(w, h)) < 2.8 and circularity > 0.35):
            continue
        # Work only in this small component's bounds: full-frame allocations for
        # every speck of red printing would stall a high-resolution mat image.
        filled = np.zeros((h, w), np.uint8)
        cv2.drawContours(filled, [contour - [x, y]], -1, 255, cv2.FILLED)
        local_excess = excess[y:y+h, x:x+w]
        evidence = (red[y:y+h, x:x+w] > 0) & (filled > 0)
        if not np.any(evidence):
            continue
        # Include white-core intensity, but require the surrounding red evidence.
        weight = (np.maximum(local_excess, 0) + np.maximum(r[y:y+h, x:x+w] - 160, 0) * 0.4) * (filled > 0)
        total = float(weight.sum())
        if total <= 0:
            continue
        ys, xs = np.nonzero(weight)
        weights = weight[ys, xs]
        cx, cy = float(np.sum(xs * weights) / total) + x, float(np.sum(ys * weights) / total) + y
        candidate = {"x": cx, "y": cy, "u": cx / (width - 1), "v": cy / (height - 1),
                     "areaPixels": float(area), "circularity": float(circularity),
                     "score": float(np.mean(local_excess[evidence]))}
        if board and board.get("found"):
            point = cv2.perspectiveTransform(np.array([[[cx, cy]]], np.float32), np.array(board["imageToMat"]))[0, 0]
            candidate["matXMM"], candidate["matYMM"] = map(float, point)
        candidates.append(candidate)
    candidates.sort(key=lambda item: item["score"], reverse=True)
    status = "found" if len(candidates) == 1 else "ambiguous" if candidates else "not_found"
    detail = {"found": "One red spot found." if background is not None else "Red candidate found; capture a laser-off reference to distinguish red markings.",
              "ambiguous": "Multiple red spots; remove reflections or narrow the marked grid patch.",
              "not_found": "No isolated red laser spot found inside the grid."}[status]
    result = {"status": status, "candidates": candidates[:20], "usedBackground": background is not None, "detail": detail}
    if status == "found":
        result["point"] = candidates[0]
    return result, mask


def analyze(image, cols=9, rows=6, spacing_mm=25.4, quad=None, background=None):
    board = grid(image, cols, rows, spacing_mm, quad)
    laser, mask = detect_red_dot(image, background, board)
    return {"schemaVersion": 1, "width": image.shape[1], "height": image.shape[0],
            "coordinateConvention": "image_x_right_y_down; mat_x_right_y_down_millimeters",
            "board": board, "laser": laser}, mask


def annotate(image, result):
    output = image.copy()
    board = result["board"]
    if board.get("found"):
        for index, (x, y) in enumerate(board["corners"]):
            xy = (round(x), round(y))
            cv2.circle(output, xy, 3, (255, 180, 0), 1, cv2.LINE_AA)
            if index in (0, board["cols"]-1, board["cols"] * (board["rows"]-1)):
                cv2.putText(output, f'R{index // board["cols"]+1} C{index % board["cols"]+1}',
                            (xy[0]+6, xy[1]-6), cv2.FONT_HERSHEY_SIMPLEX, .45, (255, 180, 0), 1, cv2.LINE_AA)
    for point in result["laser"]["candidates"]:
        cv2.circle(output, (round(point["x"]), round(point["y"])), 12,
                   (0, 255, 0) if result["laser"]["status"] == "found" else (0, 180, 255), 2, cv2.LINE_AA)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--background", help="Laser-off image at the same head pose")
    parser.add_argument("--cols", type=int, default=9, help="Intersection columns, not square count")
    parser.add_argument("--rows", type=int, default=6, help="Intersection rows, not square count")
    parser.add_argument("--spacing-mm", type=float, default=25.4)
    parser.add_argument("--quad", help="JSON pixel pairs: top-left, top-right, bottom-right, bottom-left intersections")
    parser.add_argument("--output", help="JSON result path")
    parser.add_argument("--annotated", help="Annotated PNG path")
    parser.add_argument("--mask", help="Red-evidence mask PNG path")
    args = parser.parse_args()
    try:
        image = cv2.imread(args.image)
        background = cv2.imread(args.background) if args.background else None
        if args.background and background is None:
            raise ValueError("Could not read the laser-off reference.")
        result, mask = analyze(image, args.cols, args.rows, args.spacing_mm,
                               json.loads(args.quad) if args.quad else None, background)
        if args.annotated and not cv2.imwrite(args.annotated, annotate(image, result)):
            raise ValueError("Could not save annotated image.")
        if args.mask and not cv2.imwrite(args.mask, mask):
            raise ValueError("Could not save mask.")
    except (ValueError, cv2.error) as error:
        result = {"schemaVersion": 1, "error": str(error)}
    output = json.dumps(result, allow_nan=False)
    if args.output:
        Path(args.output).write_text(output + "\n")
    else:
        print(output)
    return 1 if "error" in result else 0


if __name__ == "__main__":
    raise SystemExit(main())
