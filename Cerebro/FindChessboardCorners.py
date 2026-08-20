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

    # Try candidates in order: first requested pattern, then its rotation, then standard fallbacks
    candidates = []
    # Add unique candidates
    for p in [(args.cols, args.rows), (args.rows, args.cols), (7, 7), (8, 5), (5, 8), (6, 6)]:
        if p not in candidates and p[0] > 1 and p[1] > 1:
            candidates.append(p)
            
    found = False
    corners = None
    successful_pattern = None
    best_image = None
    
    for label, img in pipelines:
        for pattern in candidates:
            found, corners = cv2.findChessboardCorners(img, pattern, None)
            if found:
                successful_pattern = pattern
                best_image = img
                break
        if found:
            break

    if found and successful_pattern is not None and best_image is not None:
        # Refine corner locations for sub-pixel accuracy
        criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)
        corners_refined = cv2.cornerSubPix(best_image, corners, (11, 11), (-1, -1), criteria)
        
        points = []
        for corner in corners_refined:
            x, y = corner.ravel()
            points.append({"x": float(x), "y": float(y)})
            
        print(json.dumps({
            "success": True, 
            "corners": points,
            "cols": successful_pattern[0],
            "rows": successful_pattern[1]
        }))
    else:
        print(json.dumps({
            "success": False, 
            "error": "Chessboard corners not found. Tried patterns: {}".format(candidates)
        }))

if __name__ == "__main__":
    main()