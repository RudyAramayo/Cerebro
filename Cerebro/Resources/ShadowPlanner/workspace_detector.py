#!/usr/bin/env python3
"""Offline object boxes from OWLv2. This process has no robot/control interfaces."""
import argparse
import base64
import io
import json
import os
from pathlib import Path
import sys
import time
from types import SimpleNamespace

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")

QUERIES = [
    ("can", "a red Coca-Cola soda can"),
    ("can", "an aluminum beverage can"),
    ("orangeBucket", "an orange plastic bucket"),
    ("orangeBucket", "an open orange bucket"),
    # Shape recognition is less brittle than a color-qualified text embedding.
    # Native pixels still have to support the requested red/orange appearance.
    ("orangeBucket", "a bucket"),
    ("other", "a coffee mug"),
    ("other", "a water bottle"),
    ("other", "a computer keyboard"),
    ("other", "a stapler"),
]


def has_bucket_color(image, box):
    import numpy as np
    crop = image.crop((int(box[0]*image.width), int(box[1]*image.height),
                       int(box[2]*image.width), int(box[3]*image.height)))
    if crop.width < 2 or crop.height < 2:
        return False
    pixels = np.asarray(crop.resize((48, 48)), dtype=np.float32)
    red, green, blue = pixels[:,:,0], pixels[:,:,1], pixels[:,:,2]
    # Accept red/orange under indoor lighting, while rejecting neutral/blue
    # containers. This is appearance evidence, never a release/rim estimate.
    orange = (red >= 50) & (red > green*1.25) & (red > blue*1.5)
    return float(orange.mean()) >= 0.18


class Detector:
    def __init__(self, model_directory, device="auto"):
        import torch
        from transformers import Owlv2Processor, Owlv2ForObjectDetection
        self.torch = torch
        self.device = "mps" if device == "auto" and torch.backends.mps.is_available() else ("cpu" if device == "auto" else device)
        self.processor = Owlv2Processor.from_pretrained(model_directory, local_files_only=True, use_fast=False)
        self.model = Owlv2ForObjectDetection.from_pretrained(model_directory, local_files_only=True, use_safetensors=True).eval().to(self.device)
        # The query vocabulary never changes during this worker's lifetime.
        # Cache only its text features; every image still runs the full vision
        # encoder and box/class heads with the original thresholds.
        self.text_inputs = self.processor(text=[[query for _, query in QUERIES]], return_tensors="pt").to(self.device)
        with torch.inference_mode():
            features = self.model.owlv2.get_text_features(**self.text_inputs)
            self.query_embeds = (features / torch.linalg.norm(features, ord=2, dim=-1, keepdim=True)).unsqueeze(0)
            self.query_mask = (self.text_inputs["input_ids"][:, 0] > 0).unsqueeze(0)

    def predict(self, image_inputs, *, cached_text=True):
        """Same OWLv2 box/class calculation; uncached branch is a parity oracle."""
        if not cached_text:
            return self.model(**image_inputs, **self.text_inputs)
        feature_map, _ = self.model.image_embedder(image_inputs["pixel_values"])
        image_features = feature_map.reshape(feature_map.shape[0], -1, feature_map.shape[-1])
        logits, _ = self.model.class_predictor(image_features, self.query_embeds, self.query_mask)
        boxes = self.model.box_predictor(image_features, feature_map)
        return SimpleNamespace(logits=logits, pred_boxes=boxes)

    def detect(self, jpeg, *, cached_text=True):
        from PIL import Image
        image = Image.open(io.BytesIO(jpeg)).convert("RGB")
        if image.width * image.height > 4_000_000:
            raise ValueError("Camera image exceeds detector bound")
        started = time.monotonic()
        inputs = self.processor(images=image, return_tensors="pt").to(self.device)
        prepared = time.monotonic()
        with self.torch.inference_mode():
            outputs = self.predict(inputs, cached_text=cached_text)
        result = self.processor.post_process_object_detection(outputs, threshold=0.08, target_sizes=self.torch.tensor([[image.height, image.width]], device=self.device))[0]
        candidates = []
        for box, score, label in zip(result["boxes"].cpu().tolist(), result["scores"].cpu().tolist(), result["labels"].cpu().tolist()):
            target, query = QUERIES[label]
            normalized = [max(0, min(1, value / (image.width if index % 2 == 0 else image.height))) for index, value in enumerate(box)]
            if target == "orangeBucket" and not has_bucket_color(image, normalized):
                continue
            candidates.append({"target": target, "query": query, "score": score, "box": normalized})
        return {"provider": "owlv2", "model": "google/owlv2-base-patch16-ensemble", "device": self.device,
                "width": image.width, "height": image.height, "inference_ms": (time.monotonic()-started)*1000,
                "preprocess_ms": (prepared-started)*1000, "text_features_cached":cached_text,
                "network_required":False,
                "candidates": sorted(candidates, key=lambda candidate: candidate["score"], reverse=True)[:32]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", type=Path, required=True)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--device", choices=["auto", "cpu", "mps"], default="auto")
    args = parser.parse_args()
    detector = Detector(str(args.model_directory), args.device)
    if args.image:
        print(json.dumps(detector.detect(args.image.read_bytes()), allow_nan=False))
        return
    print(json.dumps({"ready": True, "provider": "owlv2", "device": detector.device}), flush=True)
    for line in sys.stdin:
        request = None
        try:
            if len(line) > 4_000_000:
                raise ValueError("Camera request exceeds detector bound")
            request = json.loads(line)
            result = detector.detect(base64.b64decode(request["jpeg"], validate=True))
            result["id"] = request["id"]
            print(json.dumps(result, allow_nan=False), flush=True)
        except Exception as error:
            print(json.dumps({"id": request.get("id") if isinstance(locals().get("request"), dict) else None,
                              "error": type(error).__name__ + ": " + str(error)[:300]}), flush=True)


if __name__ == "__main__":
    main()
