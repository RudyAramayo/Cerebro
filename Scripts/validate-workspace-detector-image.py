#!/usr/bin/env python3
"""Replay a local camera frame and a target-free crop without robot access."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def iou(a, b):
    area = max(0, min(a[2],b[2])-max(a[0],b[0])) * max(0,min(a[3],b[3])-max(a[1],b[1]))
    return area / max(1e-9,(a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-area)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--expected-can-box", type=float, nargs=4)
    parser.add_argument("--expected-bucket-box", type=float, nargs=4)
    parser.add_argument("--negative-crop", type=int, nargs=4, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.expected_can_box and not args.expected_bucket_box:
        parser.error("Supply an expected can or bucket box")
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("workspace_detector", root / "Cerebro/Resources/ShadowPlanner/workspace_detector.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    model = Path.home() / "Library/Application Support/Cerebro/WorkspaceDetector/model"
    detector = module.Detector(str(model))
    image_bytes = args.image.read_bytes()
    positive = detector.detect(image_bytes)
    for target, expected in [("can", args.expected_can_box), ("orangeBucket", args.expected_bucket_box)]:
        if expected:
            candidates = [candidate for candidate in positive["candidates"] if candidate["target"] == target and candidate["score"] >= 0.35]
            assert candidates and max(iou(candidate["box"], expected) for candidate in candidates) >= 0.65, positive
    if args.expected_bucket_box:
        accepted = [candidate for candidate in positive["candidates"] if candidate["target"] == "orangeBucket" and candidate["score"] >= 0.35]
        assert all(iou(candidate["box"], args.expected_bucket_box) >= 0.65 for candidate in accepted), positive
    from PIL import Image
    import io
    crop = Image.open(io.BytesIO(image_bytes)).crop(tuple(args.negative_crop))
    data = io.BytesIO(); crop.save(data, format="JPEG", quality=95)
    negative = detector.detect(data.getvalue())
    assert not [candidate for candidate in negative["candidates"] if candidate["target"] in {"can","orangeBucket"} and candidate["score"] >= 0.35], negative
    args.output.write_text(json.dumps({"cameraImageSHA256":hashlib.sha256(image_bytes).hexdigest(),
        "expectedCanBox":args.expected_can_box,"expectedBucketBox":args.expected_bucket_box,
        "negativeCrop":args.negative_crop,"threshold":0.35,
        "positive":positive,"negative":negative,"result":"passed; one local scene and target-free crop only"},indent=2)+"\n")
    print("Camera replay: expected target box agrees; target-free crop has no accepted can or bucket. No robot access.")


if __name__ == "__main__":
    main()
