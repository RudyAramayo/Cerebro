#!/usr/bin/env python3
"""Convert official AdaFace IR-18 checkpoints into validated Core ML packages."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
from PIL import Image
import torch


MODELS = {
    "vggface2": {
        "display_name": "AdaFace R18 — VGGFace2",
        "model_id": "adaface-ir18-vggface2-v1",
        "checkpoint": "adaface_ir18_vgg2.ckpt",
        "package": "AdaFace-R18-VGGFace2.mlpackage",
        "compiled": "AdaFace-R18-VGGFace2.mlmodelc",
        "official_url": "https://drive.google.com/uc?id=1k7onoJusC0xjqfjB-hNNaxz9u6eEzFdv",
    },
    "webface4m": {
        "display_name": "AdaFace R18 — WebFace4M",
        "model_id": "adaface-ir18-webface4m-v1",
        "checkpoint": "adaface_ir18_webface4m.ckpt",
        "package": "AdaFace-R18-WebFace4M.mlpackage",
        "compiled": "AdaFace-R18-WebFace4M.mlmodelc",
        "official_url": "https://drive.google.com/uc?id=1J17_QW1Oq00EhSWObISnhWEYr2NNrg2y",
    },
}


class EmbeddingOnly(torch.nn.Module):
    def __init__(self, backbone: torch.nn.Module):
        super().__init__()
        self.backbone = backbone

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        embedding, _ = self.backbone(image)
        return embedding


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_backbone(source_root: Path, checkpoint_path: Path) -> torch.nn.Module:
    sys.path.insert(0, str(source_root))
    import net  # type: ignore

    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    state = {
        key.removeprefix("model."): value
        for key, value in checkpoint["state_dict"].items()
        if key.startswith("model.")
    }
    backbone = net.build_model("ir_18")
    backbone.load_state_dict(state, strict=True)
    return EmbeddingOnly(backbone.eval()).eval()


def convert(model: torch.nn.Module, package_path: Path) -> None:
    torch.manual_seed(7)
    example = torch.rand(1, 3, 112, 112) * 2 - 1
    traced = torch.jit.trace(model, example)
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.ImageType(
            name="face",
            shape=(1, 3, 112, 112),
            color_layout=ct.colorlayout.BGR,
            scale=2.0 / 255.0,
            bias=[-1.0, -1.0, -1.0],
        )],
        outputs=[ct.TensorType(name="embedding")],
    )
    if package_path.exists():
        shutil.rmtree(package_path)
    converted.save(package_path)


def validate(model: torch.nn.Module, package_path: Path) -> float:
    rng = np.random.default_rng(23)
    pixels = rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)
    image = Image.fromarray(pixels)
    bgr = pixels[:, :, ::-1].copy()
    tensor = torch.from_numpy(bgr).permute(2, 0, 1).unsqueeze(0).float()
    tensor = tensor * (2.0 / 255.0) - 1.0
    with torch.no_grad():
        expected = model(tensor).numpy().reshape(-1)
    actual = np.asarray(ct.models.MLModel(str(package_path)).predict({"face": image})["embedding"]).reshape(-1)
    cosine = float(np.dot(expected, actual) / (np.linalg.norm(expected) * np.linalg.norm(actual)))
    if cosine < 0.999:
        raise RuntimeError(f"Core ML validation failed (cosine={cosine:.7f})")
    return cosine


def compile_package(package_path: Path, destination: Path, compiled_name: str) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(package_path), str(destination)],
        check=True,
    )
    generated = destination / (package_path.stem + ".mlmodelc")
    target = destination / compiled_name
    if generated != target:
        if target.exists():
            shutil.rmtree(target)
        generated.rename(target)
    return target


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True, help="Official AdaFace checkout containing net.py")
    parser.add_argument("--checkpoint-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--model", choices=[*MODELS, "all"], default="all")
    args = parser.parse_args()

    selected = MODELS if args.model == "all" else {args.model: MODELS[args.model]}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output_dir / "adaface-models.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"models": {}}

    for key, details in selected.items():
        checkpoint = args.checkpoint_dir / details["checkpoint"]
        if not checkpoint.exists():
            print(f"SKIP {details['display_name']}: checkpoint not found at {checkpoint}")
            continue
        print(f"Loading {details['display_name']} from {checkpoint}")
        model = load_backbone(args.source_root, checkpoint)
        package = args.output_dir / details["package"]
        convert(model, package)
        cosine = validate(model, package)
        compiled = compile_package(package, args.output_dir, details["compiled"])
        manifest["models"][details["model_id"]] = {
            "displayName": details["display_name"],
            "checkpointSHA256": sha256(checkpoint),
            "checkpointSource": details["official_url"],
            "coreMLPackage": str(package),
            "compiledModel": str(compiled),
            "input": "112x112 BGR, pixel * (2/255) - 1",
            "output": "512-dimensional L2-normalized embedding",
            "validationCosine": cosine,
        }
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"Installed {compiled} (validation cosine {cosine:.7f})")


if __name__ == "__main__":
    main()
