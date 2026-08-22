import argparse
import json
from pathlib import Path
import re
import sys

import blobconverter
import yaml
from ultralytics import YOLO


IMAGE_EXTENSIONS = {
    ".bmp",
    ".dng",
    ".jpeg",
    ".jpg",
    ".mpo",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
}


class TrainingPipelineError(RuntimeError):
    pass


FACE_MODEL_MANIFEST_VERSION = 1
FACE_MODEL_PARSER_TYPE = "depthai_yolo_spatial_v1"


def safe_project_name(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", value):
        raise argparse.ArgumentTypeError(
            "project must contain only letters, numbers, underscores, and hyphens"
        )
    return value


def require_within(path, root, description):
    try:
        path.relative_to(root)
    except ValueError as error:
        raise TrainingPipelineError(
            f"{description} resolves outside the selected datasets root: {path}"
        ) from error


def resolve_split_directory(config, project_dir, datasets_root, split):
    value = config.get(split)
    if not isinstance(value, str) or not value.strip():
        raise TrainingPipelineError(f"data.yaml must define a nonempty '{split}' path")

    dataset_base_value = config.get("path", ".")
    if not isinstance(dataset_base_value, str) or not dataset_base_value.strip():
        raise TrainingPipelineError("data.yaml 'path' must be a nonempty string when present")

    dataset_base = Path(dataset_base_value).expanduser()
    if not dataset_base.is_absolute():
        dataset_base = project_dir / dataset_base
    dataset_base = dataset_base.resolve()
    require_within(dataset_base, datasets_root, "Dataset base")

    split_path = Path(value).expanduser()
    if not split_path.is_absolute():
        split_path = dataset_base / split_path
    split_path = split_path.resolve()
    require_within(split_path, project_dir, f"{split} image directory")
    return split_path


def contains_file_with_suffix(directory, suffixes):
    return any(
        path.is_file() and path.suffix.lower() in suffixes
        for path in directory.rglob("*")
    )


def validated_class_names(config):
    names = config.get("names")
    if isinstance(names, list):
        labels = names
    elif isinstance(names, dict):
        normalized = {}
        for key, value in names.items():
            if type(key) is int:
                index = key
            elif isinstance(key, str) and key.isdigit():
                index = int(key)
            else:
                raise TrainingPipelineError("data.yaml class indices must be integers")
            if index in normalized:
                raise TrainingPipelineError("data.yaml contains duplicate class indices")
            normalized[index] = value
        if set(normalized) != set(range(len(normalized))):
            raise TrainingPipelineError("data.yaml class indices must be contiguous from zero")
        labels = [normalized[index] for index in range(len(normalized))]
    else:
        raise TrainingPipelineError("data.yaml 'names' must be a list or indexed mapping")

    if not labels or any(
        not isinstance(label, str) or not label or label != label.strip()
        for label in labels
    ):
        raise TrainingPipelineError("data.yaml class names must be nonempty trimmed strings")
    if len(set(labels)) != len(labels):
        raise TrainingPipelineError("data.yaml class names must be unique")
    class_count = config.get("nc")
    if type(class_count) is not int or class_count != len(labels):
        raise TrainingPipelineError("data.yaml 'nc' must equal the number of class names")
    return labels


def validate_dataset(project_dir, datasets_root, yaml_path):
    try:
        with yaml_path.open("r", encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as error:
        raise TrainingPipelineError(f"Unable to read {yaml_path}: {error}") from error

    if not isinstance(config, dict):
        raise TrainingPipelineError("data.yaml must contain a mapping")
    class_names = validated_class_names(config)

    train_images = resolve_split_directory(
        config, project_dir, datasets_root, "train"
    )
    val_images = resolve_split_directory(config, project_dir, datasets_root, "val")
    if train_images == val_images:
        raise TrainingPipelineError(
            "Training and validation image directories must be distinct"
        )

    split_directories = {
        "train": (train_images, project_dir / "labels" / "train"),
        "val": (val_images, project_dir / "labels" / "val"),
    }
    for split, (image_dir, label_dir) in split_directories.items():
        if not image_dir.is_dir():
            raise TrainingPipelineError(
                f"Missing {split} image directory: {image_dir}"
            )
        if not contains_file_with_suffix(image_dir, IMAGE_EXTENSIONS):
            raise TrainingPipelineError(
                f"{split} image directory contains no supported images: {image_dir}"
            )
        if not label_dir.is_dir():
            raise TrainingPipelineError(
                f"Missing {split} label directory: {label_dir}"
            )
        if not contains_file_with_suffix(label_dir, {".txt"}):
            raise TrainingPipelineError(
                f"{split} label directory contains no label files: {label_dir}"
            )

    classes_path = project_dir / "classes.txt"
    if not classes_path.is_file() or not classes_path.read_text(encoding="utf-8").strip():
        raise TrainingPipelineError(f"Missing or empty class metadata: {classes_path}")
    classes_file_names = [
        line.strip()
        for line in classes_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if classes_file_names != class_names:
        raise TrainingPipelineError(
            "classes.txt entries must exactly match data.yaml class names and order"
        )
    return class_names


def run_training(args):
    datasets_root = args.datasets_root.expanduser().resolve()
    if not datasets_root.is_dir():
        raise TrainingPipelineError(f"Datasets root does not exist: {datasets_root}")

    project_dir = (datasets_root / args.project).resolve()
    require_within(project_dir, datasets_root, "Project directory")
    if not project_dir.is_dir():
        raise TrainingPipelineError(
            f"Project '{args.project}' dataset not found at {project_dir}"
        )

    yaml_path = project_dir / "data.yaml"
    if not yaml_path.is_file():
        raise TrainingPipelineError(f"Dataset configuration not found: {yaml_path}")
    class_names = validate_dataset(project_dir, datasets_root, yaml_path)

    print(f"--- Starting Automated Training for Project: {args.project} ---")

    model = YOLO("yolov8n.pt")
    print("1. Fine-tuning YOLOv8 model on new spatial data...")
    model.train(
        data=str(yaml_path),
        epochs=50,
        imgsz=640,
        device="mps",
        project=str(project_dir / "runs"),
        name="train",
        exist_ok=True,
    )

    best_weights = project_dir / "runs" / "train" / "weights" / "best.pt"
    if not best_weights.is_file():
        raise TrainingPipelineError("Training failed to produce best.pt weights")

    print("2. Exporting trained model to ONNX format...")
    onnx_path = Path(
        YOLO(str(best_weights)).export(format="onnx", imgsz=[400, 640], opset=12)
    ).resolve()
    if not onnx_path.is_file():
        raise TrainingPipelineError(f"ONNX export did not produce a file: {onnx_path}")

    print("3. Compiling ONNX to Myriad X .blob for OAK-D Pro hardware...")
    models_dir = Path(__file__).resolve().parent / "Models"
    models_dir.mkdir(parents=True, exist_ok=True)
    compiled_blob = Path(
        blobconverter.from_onnx(
            model=str(onnx_path),
            shaves=6,
            use_su_tool=False,
            optimizer_params=[
                "--mean_values=[0,0,0]",
                "--scale_values=[255,255,255]",
            ],
            output_dir=str(models_dir),
        )
    ).resolve()
    if not compiled_blob.is_file():
        raise TrainingPipelineError(
            f"Blob compilation did not produce a file: {compiled_blob}"
        )

    final_blob_path = models_dir / f"yolov8_{args.project.lower()}_6shave.blob"
    manifest_path = final_blob_path.with_suffix(".json")
    manifest_temp_path = manifest_path.with_suffix(".json.tmp")
    manifest = {
        "manifest_version": FACE_MODEL_MANIFEST_VERSION,
        "model_stem": final_blob_path.stem,
        "parser_type": FACE_MODEL_PARSER_TYPE,
        "labels": class_names,
        "num_classes": len(class_names),
        "input_width": 640,
        "input_height": 400,
        "coordinate_size": 4,
        "confidence_threshold": 0.65,
        "iou_threshold": 0.5,
    }
    manifest_temp_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    manifest_path.unlink(missing_ok=True)
    compiled_blob.replace(final_blob_path)
    manifest_temp_path.replace(manifest_path)
    print(f"\nSUCCESS! Deployed new upgraded spatial brain to: {final_blob_path}")


def main():
    repository_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description="Automated continuous spatial learning pipeline for Cerebro."
    )
    parser.add_argument(
        "--project",
        required=True,
        type=safe_project_name,
        help="Safe project directory name to train (for example, Chess or Monopoly)",
    )
    parser.add_argument(
        "--datasets-root",
        type=Path,
        default=repository_root / "Datasets",
        help="Directory containing project datasets (default: repository Datasets directory)",
    )
    args = parser.parse_args()

    try:
        run_training(args)
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
