import sys
import json
import argparse
import math
import cv2

def main():
    parser = argparse.ArgumentParser(description="Find chessboard corners in an image.")
    parser.add_argument("--image", required=True, help="Path to the image file.")
    parser.add_argument("--cols", type=int, required=True, help="Number of inner corners horizontally.")
    parser.add_argument("--rows", type=int, required=True, help="Number of inner corners vertically.")
    args = parser.parse_args()

    if args.cols <= 1 or args.rows <= 1:
        print(json.dumps({
            "success": False,
            "error": "Chessboard dimensions must both be greater than one."
        }))
        return

    image = cv2.imread(args.image, cv2.IMREAD_GRAYSCALE)
    if image is None:
        print(json.dumps({"success": False, "error": "Could not read image."}))
        sys.exit(1)

    # Try multiple image pre-processing pipelines to handle low contrast & marble textures
    pipelines = [("Raw Grayscale", image)]
    
    try:
        equalized = cv2.equalizeHist(image)
        pipelines.append(("Equalized", equalized))
    except:
        pass
        
    try:
        blurred = cv2.GaussianBlur(image, (3, 3), 0)
        clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
        enhanced = clahe.apply(blurred)
        pipelines.append(("CLAHE + Blur", enhanced))
    except:
        pass

    # Calibration geometry is defined by the caller. Never substitute a
    # rotated or similarly sized grid because that changes corner identities.
    requested_pattern = (args.cols, args.rows)
    found = False
    corners = None
    best_image = None
    
    for label, img in pipelines:
        found, corners = cv2.findChessboardCorners(img, requested_pattern, None)
        if found:
            best_image = img
            break

    if found and corners is not None and best_image is not None:
        # Refine corner locations for sub-pixel accuracy
        criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)
        corners_refined = cv2.cornerSubPix(best_image, corners, (11, 11), (-1, -1), criteria)

        expected_count = args.cols * args.rows
        if corners_refined is None or len(corners_refined) != expected_count:
            actual_count = 0 if corners_refined is None else len(corners_refined)
            print(json.dumps({
                "success": False,
                "error": "Expected {} corners for exact pattern {}x{}, found {}.".format(
                    expected_count, args.cols, args.rows, actual_count
                )
            }))
            return
        
        points = []
        for corner in corners_refined:
            x, y = corner.ravel()
            if not math.isfinite(float(x)) or not math.isfinite(float(y)):
                print(json.dumps({
                    "success": False,
                    "error": "Corner detector returned a non-finite coordinate."
                }))
                return
            points.append({"x": float(x), "y": float(y)})
            
        print(json.dumps({
            "success": True, 
            "corners": points,
            "cols": args.cols,
            "rows": args.rows
        }))
    else:
        print(json.dumps({
            "success": False, 
            "error": "Exact requested chessboard pattern {}x{} was not found.".format(
                args.cols, args.rows
            )
        }))

if __name__ == "__main__":
    main()
