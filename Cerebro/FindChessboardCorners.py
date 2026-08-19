import sys
import json
import argparse
import cv2

def main():
    parser = argparse.ArgumentParser(description="Find chessboard corners in an image.")
    parser.add_argument("--image", required=True, help="Path to the image file.")
    parser.add_argument("--cols", type=int, required=True, help="Number of inner corners horizontally.")
    parser.add_argument("--rows", type=int, required=True, help="Number of inner corners vertically.")
    args = parser.parse_args()

    image = cv2.imread(args.image, cv2.IMREAD_GRAYSCALE)
    if image is None:
        print(json.dumps({"success": False, "error": "Could not read image."}))
        sys.exit(1)

    pattern_size = (args.cols, args.rows)
    found, corners = cv2.findChessboardCorners(image, pattern_size, None)

    if found:
        # Refine corner locations for sub-pixel accuracy
        criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)
        corners_refined = cv2.cornerSubPix(image, corners, (11, 11), (-1, -1), criteria)
        
        points = []
        for corner in corners_refined:
            x, y = corner.ravel()
            points.append({"x": float(x), "y": float(y)})
            
        print(json.dumps({"success": True, "corners": points}))
    else:
        print(json.dumps({"success": False, "error": "Chessboard corners not found."}))

if __name__ == "__main__":
    main()