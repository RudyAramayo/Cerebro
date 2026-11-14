#!/usr/bin/env python3
"""Teach rectangular board games from reviewed Cerebro captures. Never sends motion."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import time
import uuid
from PIL import Image, ImageDraw


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")
    temporary.replace(path)


def read_project(root):
    project = json.loads((root / "game.json").read_text())
    if (project.get("schemaVersion") != 1 or not 2 <= project["rows"] <= 16
            or not 2 <= project["columns"] <= 16):
        raise ValueError("Unsupported game project.")
    return project


def cells(project):
    for row in range(project["rows"]):
        for column in range(project["columns"]):
            name = (chr(97 + column) + str(8 - row) if project["preset"] == "chess"
                    else f"r{row + 1}c{column + 1}")
            yield name, row, column


def homography(corners):
    if (len(corners) != 4 or any(len(p) != 2 or any(
            not isinstance(v, (float, int)) or not math.isfinite(v) or not 0 <= v <= 1 for v in p) for p in corners)):
        raise ValueError("Four normalized image corners are required.")
    turns = []
    for i in range(4):
        a, b, c = corners[i], corners[(i + 1) % 4], corners[(i + 2) % 4]
        turns.append((b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]))
    area = abs(sum(corners[i][0] * corners[(i + 1) % 4][1] -
                   corners[(i + 1) % 4][0] * corners[i][1] for i in range(4))) / 2
    if area < .025 or not (all(v > .0001 for v in turns) or all(v < -.0001 for v in turns)):
        raise ValueError("Corners must form a convex board in semantic top-left, top-right, bottom-right, bottom-left order.")
    matrix = []
    for (u, v), (x, y) in zip(((0, 0), (1, 0), (1, 1), (0, 1)), corners):
        matrix.extend(([u, v, 1, 0, 0, 0, -u*x, -v*x, x], [0, 0, 0, u, v, 1, -u*y, -v*y, y]))
    for k in range(8):
        pivot = max(range(k, 8), key=lambda i: abs(matrix[i][k]))
        if abs(matrix[pivot][k]) < 1e-10:
            raise ValueError("Degenerate board.")
        matrix[k], matrix[pivot] = matrix[pivot], matrix[k]
        scale = matrix[k][k]
        matrix[k] = [value / scale for value in matrix[k]]
        for i in range(8):
            if i != k:
                factor = matrix[i][k]
                matrix[i] = [a - factor*b for a, b in zip(matrix[i], matrix[k])]
    h = [row[-1] for row in matrix]
    if any(h[6]*u + h[7]*v + 1 <= 1e-6 for u, v in ((0, 0), (1, 0), (1, 1), (0, 1))):
        raise ValueError("Unusable perspective.")
    return h


def prepare(root, capture):
    project = read_project(root)
    calibration = json.loads((root / "board.json").read_text())
    h = homography(calibration["corners"])
    metadata = json.loads((capture / "frame.json").read_text())
    source = capture / "rgb.jpg"
    if source.stat().st_size > 40_000_000:
        raise ValueError("Image is too large.")
    image = Image.open(source)
    if image.width > 4096 or image.height > 4096 or image.width < 64 or image.height < 64:
        raise ValueError("Image dimensions are outside the supported range.")
    if [image.width, image.height] != [metadata["width"], metadata["height"]]:
        raise ValueError("Image dimensions disagree with capture metadata.")
    width, height = project["columns"] * 64, project["rows"] * 64
    coefficients = (h[0]*image.width/width, h[1]*image.width/height, h[2]*image.width,
                    h[3]*image.height/width, h[4]*image.height/height, h[5]*image.height,
                    h[6]/width, h[7]/height)
    board = image.convert("RGB").transform((width, height), Image.Transform.PERSPECTIVE, coefficients, Image.Resampling.BILINEAR)
    descriptors = {}
    for name, row, col in cells(project):
        crop = board.crop((col*64+8, row*64+8, col*64+56, row*64+56)).resize((10, 10), Image.Resampling.BILINEAR)
        descriptors[name] = [v/255 for pixel in crop.getdata() for v in pixel]
    return project, calibration, metadata, board, descriptors


def distance(a, b):
    return sum(abs(x-y) for x, y in zip(a, b)) / len(a)


def current_records(root, project):
    # Later review of the same source frame supersedes its earlier labels.
    records = {}
    for name in project["records"][-1500:]:
        uuid.UUID(name)
        folder = root / "records" / name
        record = json.loads((folder / "record.json").read_text())
        if hashlib.sha256((folder / "source.jpg").read_bytes()).hexdigest() != record["sourceSHA256"]:
            raise ValueError("A reviewed source image has changed.")
        expected = {name for name, _, _ in cells(project)}
        if set(record["labels"]) != expected or any(label not in project["classes"] for label in record["labels"].values()):
            raise ValueError("Saved labels disagree with this game.")
        if set(record["descriptors"]) != expected or any(
                len(values) != 300 or any(not isinstance(v, (int, float)) or not math.isfinite(v) or not 0 <= v <= 1 for v in values)
                for values in record["descriptors"].values()):
            raise ValueError("Saved appearance data is invalid.")
        if record["verification"] == "operator_confirmed":
            records[record["frameID"]] = record
    return list(records.values())


def create(root, name, rows, columns, classes, preset, rules):
    if root.exists():
        raise ValueError("Choose a new project directory; existing work is preserved.")
    if preset == "chess":
        rows = columns = 8
        classes = ["empty"] + [f"{color}_{piece}" for color in ("white", "black")
                              for piece in ("pawn", "knight", "bishop", "rook", "queen", "king")]
    if not 2 <= rows <= 16 or not 2 <= columns <= 16 or not 1 <= len(classes) <= 128:
        raise ValueError("Use a 2…16 by 2…16 board and 1…128 classes.")
    if len(set(classes)) != len(classes) or any(not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", label) for label in classes):
        raise ValueError("Classes must be unique lowercase identifiers.")
    project = {"schemaVersion": 1, "id": str(uuid.uuid4()), "name": name, "preset": preset,
               "rows": rows, "columns": columns, "classes": classes, "records": [],
               "rulesStatus": "provided_not_executable", "recognition": "reviewed_appearance_examples",
               "motionAuthority": "none"}
    root.mkdir(parents=True)
    (root / "records").mkdir()
    (root / "analysis").mkdir()
    write_json(root / "game.json", project)
    (root / "rules.md").write_text(rules or "Rules have not been taught yet. Do not infer legal moves from appearance alone.\n")
    labels = {cell: "unknown" for cell, _, _ in cells(project)}
    if preset == "chess":
        names = ["rook", "knight", "bishop", "queen", "king", "bishop", "knight", "rook"]
        for cell, row, col in cells(project):
            labels[cell] = (f"black_{names[col]}" if row == 0 else "black_pawn" if row == 1
                            else "white_pawn" if row == 6 else f"white_{names[col]}" if row == 7 else "empty")
    write_json(root / "labels-to-review.json", labels)
    return project


def teach(root, capture, labels, confirmed, note):
    if not confirmed:
        raise ValueError("Labels require explicit operator confirmation. Analysis output is never learned automatically.")
    project, calibration, metadata, board, descriptors = prepare(root, capture)
    expected = {name for name, _, _ in cells(project)}
    if set(labels) != expected or not all(value in project["classes"] for value in labels.values()):
        raise ValueError("Review every square and use only declared piece classes.")
    source_hash = hashlib.sha256((capture / "rgb.jpg").read_bytes()).hexdigest()
    for prior in current_records(root, project):
        if prior["frameID"] == metadata["frameID"] and prior["sourceSHA256"] != source_hash:
            raise ValueError("An existing frame ID cannot be assigned different image pixels.")
    record_id = str(uuid.uuid4())
    record_dir = root / "records" / record_id
    record_dir.mkdir()
    shutil.copy2(capture / "rgb.jpg", record_dir / "source.jpg")
    shutil.copy2(capture / "frame.json", record_dir / "frame.json")
    if metadata.get("hasAlignedDepth"):
        depth = capture / "depth-u16le-mm.raw"
        if depth.stat().st_size != metadata["depth"]["width"] * metadata["depth"]["height"] * 2:
            raise ValueError("Depth payload size mismatch.")
        shutil.copy2(depth, record_dir / depth.name)
    board.save(record_dir / "board.png")
    record = {"id": record_id, "frameID": metadata["frameID"], "reviewedAt": time.time(),
              "verification": "operator_confirmed", "labelKind": "square_occupancy",
              "calibration": calibration, "labels": labels, "descriptors": descriptors,
              "sourceSHA256": hashlib.sha256((record_dir / "source.jpg").read_bytes()).hexdigest(),
              "transitionNote": note}
    write_json(record_dir / "record.json", record)
    project["records"].append(record_id)
    write_json(root / "game.json", project)
    return {"record": str(record_dir), "reviewedFrames": len(current_records(root, project)),
            "detail": "Saved reviewed examples. No neural weights or robot commands were generated."}


def analyze(root, capture):
    project, calibration, metadata, board, descriptors = prepare(root, capture)
    records = current_records(root, project)[-80:]
    memory = {}
    cell_positions = {name: (row, col) for name, row, col in cells(project)}
    for record in records:
        for square, label in record["labels"].items():
            row, col = cell_positions[square]
            key = label, (row+col) % 2
            memory.setdefault(key, [])
            feature = record["descriptors"][square]
            if len(memory[key]) < 24 and not any(distance(feature, existing) < .008 for existing in memory[key]):
                memory[key].append(feature)
    observations = {}
    for name, row, col in cells(project):
        ranked = []
        for label in project["classes"]:
            examples = memory.get((label, (row+col) % 2), [])
            if examples:
                ranked.append({"label": label, "distance": min(distance(descriptors[name], example) for example in examples)})
        ranked.sort(key=lambda item: item["distance"])
        accepted = bool(ranked and ranked[0]["distance"] < .10 and
                        (len(ranked) == 1 or ranked[1]["distance"] - ranked[0]["distance"] > .015))
        observations[name] = {"suggestedLabel": ranked[0]["label"] if accepted else None,
                              "alternatives": ranked[:3], "verified": False}
    last = records[-1] if records and records[-1]["calibration"]["revision"] == calibration["revision"] else None
    changed = [name for name in descriptors if distance(descriptors[name], last["descriptors"][name]) >= .045] if last else []
    result = {"schemaVersion": 1, "frameID": metadata["frameID"], "gameID": project["id"],
              "calibrationRevision": calibration["revision"], "observations": observations, "changedSquares": changed,
              "rulesStatus": project["rulesStatus"], "automaticMoveAccepted": False,
              "detail": "Similarity scores are not probabilities. Unknowns require review; depth is archived for height analysis in Cerebro."}
    result_dir = root / "analysis" / str(uuid.uuid4())
    result_dir.mkdir()
    board.save(result_dir / "board.png")
    overlay = board.copy()
    draw = ImageDraw.Draw(overlay)
    for name, row, col in cells(project):
        color = "orange" if name in changed else "cyan"
        draw.rectangle((col*64, row*64, (col+1)*64-1, (row+1)*64-1), outline=color, width=1)
        label = observations[name]["suggestedLabel"]
        draw.text((col*64+2, row*64+2), name + (" ?" if label is None else " ✓"), fill=color, stroke_fill="black", stroke_width=1)
    overlay.save(result_dir / "review.png")
    write_json(result_dir / "analysis.json", result)
    return {"analysis": str(result_dir), "changedSquares": changed,
            "unknownSquares": sum(value["suggestedLabel"] is None for value in observations.values())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    new = commands.add_parser("new")
    new.add_argument("--name", required=True)
    new.add_argument("--preset", choices=("chess", "custom"), default="custom")
    new.add_argument("--rows", type=int, default=8)
    new.add_argument("--columns", type=int, default=8)
    new.add_argument("--classes", nargs="+", default=["empty", "piece"])
    new.add_argument("--rules", type=Path)
    calibrate = commands.add_parser("calibrate")
    calibrate.add_argument("--corners", required=True, help='JSON [[x,y],…], normalized; semantic a8,h8,h1,a1 for chess.')
    observe = commands.add_parser("analyze")
    observe.add_argument("--capture", type=Path, required=True)
    teach_parser = commands.add_parser("teach")
    teach_parser.add_argument("--capture", type=Path, required=True)
    teach_parser.add_argument("--labels", type=Path, required=True)
    teach_parser.add_argument("--confirmed", action="store_true")
    teach_parser.add_argument("--note", default="")
    commands.add_parser("status")
    args = parser.parse_args()
    root = args.project.expanduser().resolve()
    if args.command == "new":
        result = create(root, args.name, args.rows, args.columns, args.classes, args.preset,
                        args.rules.read_text() if args.rules else "")
    elif args.command == "calibrate":
        read_project(root)
        corners = json.loads(args.corners)
        homography(corners)
        result = {"revision": str(uuid.uuid4()), "corners": corners, "imageOrigin": "top_left",
                  "physicalRobotCalibration": False}
        write_json(root / "board.json", result)
    elif args.command == "teach":
        result = teach(root, args.capture.resolve(), json.loads(args.labels.read_text()), args.confirmed, args.note)
    elif args.command == "analyze":
        result = analyze(root, args.capture.resolve())
    else:
        result = read_project(root)
        result["reviewedFrames"] = len(current_records(root, result))
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
