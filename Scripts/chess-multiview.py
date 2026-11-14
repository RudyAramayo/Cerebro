#!/usr/bin/env python3
"""Bring Cerebro's existing face/belly RGB-D recordings into a chess study.

Offline, local files only. No camera configuration, actuator or network client.
Host recorder receipt times associate views; they are not exposure timestamps.
"""
import argparse
import base64
from bisect import bisect_left
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import tempfile
import uuid

from PIL import Image


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def read_json(path):
    if path.stat().st_size > 15_000_000:
        raise ValueError("JSON metadata is too large.")
    return json.loads(path.read_text())


def local_file(root, relative, limit=40_000_000):
    """Recording metadata may only refer to regular files inside its recording."""
    p = Path(relative)
    if p.is_absolute() or not p.parts or any(x in (".", "..") for x in p.parts):
        raise ValueError("Expected a relative recording path.")
    path = root.resolve() / p
    if path.resolve() != path.absolute() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError("Missing, linked or oversized recording file.")
    return path


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def frames(recording, role):
    path = local_file(recording, f"cameras/{role}/frames.jsonl", 15_000_000)
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not 1 <= len(rows) <= 300:
        raise ValueError("Use a short recording with 1…300 frames per camera.")
    seen = set()
    for row in rows:
        name = row.get("keyframe_id", "")
        if not re.fullmatch(role + r"-[0-9]{1,20}", name) or name in seen:
            raise ValueError("Invalid or repeated camera frame ID.")
        seen.add(name)
        if not finite(row.get("received_at_uptime")) or row["received_at_uptime"] <= 0:
            raise ValueError("Missing host receipt time; device clocks cannot substitute.")
    return sorted(rows, key=lambda r: r["received_at_uptime"])


def pair_frames(face, belly, max_skew):
    """Chronological nearest available match; never reuse a belly frame."""
    if not finite(max_skew) or not 0 < max_skew <= .5:
        raise ValueError("Maximum host receipt skew must be between 0 and 500 ms.")
    times = [row["received_at_uptime"] for row in belly]
    pairs, first = [], 0
    for main in face:
        t = main["received_at_uptime"]
        at = bisect_left(times, t, lo=first)
        candidates = [i for i in (at - 1, at) if first <= i < len(belly)]
        if not candidates:
            continue
        i = min(candidates, key=lambda n: abs(times[n] - t))
        delta = abs(times[i] - t)
        if delta <= max_skew:
            pairs.append({"id": f"pair-{len(pairs) + 1:04d}", "face": main["keyframe_id"],
                          "belly": belly[i]["keyframe_id"], "hostReceiptSkewSeconds": delta})
            first = i + 1
    return pairs


def copy_frame(recording, out, role, row):
    name = row["keyframe_id"]
    rgb = local_file(recording, row["rgb_file"])
    if not row["rgb_file"].startswith(f"cameras/{role}/rgb/"):
        raise ValueError("RGB camera role mismatch.")
    with Image.open(rgb) as image:
        width, height = image.size
        if not (64 <= width <= 4096 and 64 <= height <= 4096):
            raise ValueError("Unsupported image dimensions.")
        if [width, height] != [row["rgb_width"], row["rgb_height"]]:
            raise ValueError("RGB dimensions disagree with the recorder.")
        image.verify()
    folder = out / "frames" / name
    folder.mkdir(parents=True)
    shutil.copy2(rgb, folder / "rgb.jpg")
    checksums = {"rgb.jpg": digest(rgb.read_bytes())}
    intrinsics = row.get("intrinsics")
    if intrinsics is not None and (set(intrinsics) != {"fx", "fy", "cx", "cy"}
            or not all(finite(v) for v in intrinsics.values())
            or intrinsics["fx"] <= 0 or intrinsics["fy"] <= 0):
        raise ValueError("Invalid camera intrinsics.")
    has_depth = bool(row.get("aligned_depth_file"))
    if has_depth:
        depth = local_file(recording, row["aligned_depth_file"])
        if (not row["aligned_depth_file"].startswith(f"cameras/{role}/depth/")
                or [row["aligned_depth_width"], row["aligned_depth_height"]] != [width, height]
                or row.get("aligned_depth_encoding") != "uint16-little-endian-millimeters-zero-invalid"
                or depth.stat().st_size != width * height * 2):
            raise ValueError("Aligned depth role, shape, encoding or size mismatch.")
        shutil.copy2(depth, folder / "depth-u16le-mm.raw")
        checksums["depth-u16le-mm.raw"] = digest(depth.read_bytes())
    # Preserve the camera's own calibration, but do not trust old robot extrinsics.
    if row.get("calibration_id"):
        calibration_id = row["calibration_id"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,200}", calibration_id):
            raise ValueError("Invalid calibration identifier.")
        relative = f"cameras/{role}/calibrations/{calibration_id.replace('.', '_')}.json"
        calibration = local_file(recording, relative, 1_000_000)
        shutil.copy2(calibration, folder / "recorded-calibration.json")
        checksums["recorded-calibration.json"] = digest(calibration.read_bytes())
    write_json(folder / "recorder-frame.json", row)
    checksums["recorder-frame.json"] = digest((folder / "recorder-frame.json").read_bytes())
    result = {"id": name, "cameraRole": role, "width": width, "height": height,
              "receivedAt": row["received_at"], "hostReceivedUptime": row["received_at_uptime"],
              "sourceSequence": row["source_sequence"],
              "deviceTimestampNanoseconds": row["source_timestamp_nanoseconds"],
              "hasAlignedDepth": has_depth, "intrinsics": intrinsics, "hashes": checksums,
              "robotExtrinsicsValidated": False, "squareLocalization": "not_calibrated",
              "labelStatus": "unreviewed"}
    return result


def load_session(path):
    data = read_json(path / "multiview.json")
    if data.get("schemaVersion") != 1 or data.get("motionAuthority") != "none":
        raise ValueError("Unsupported multi-view session.")
    for name, frame in data["frames"].items():
        if not re.fullmatch(r"(face|belly)-[0-9]{1,20}", name):
            raise ValueError("Invalid saved frame ID.")
        for file, expected in frame["hashes"].items():
            if digest(local_file(path, f"frames/{name}/{file}").read_bytes()) != expected:
                raise ValueError("A saved RGB-D or metadata file has changed.")
    return data


def import_recording(project, recording, max_skew=.25):
    if read_json(project / "game.json").get("preset") != "chess":
        raise ValueError("Choose an existing chess project.")
    manifest = read_json(local_file(recording, "manifest.json"))
    if (manifest.get("schema") != "com.orbitusrobotics.cerebro.training-session"
            or manifest.get("schema_version") != 1 or manifest.get("state") != "complete"
            or not all(manifest.get("camera_roles", {}).get(role) for role in ("face", "belly"))):
        raise ValueError("Stop a Face + Belly Training Session before importing it.")
    streams = {role: frames(recording, role) for role in ("face", "belly")}
    pairs = pair_frames(streams["face"], streams["belly"], max_skew)
    if not pairs:
        raise ValueError("No face/belly frames are close enough in host receipt time.")
    parent = project / "multiview"
    parent.mkdir(mode=0o700, exist_ok=True)
    identity = str(uuid.uuid4())
    temporary = Path(tempfile.mkdtemp(prefix=".import-", dir=parent))
    try:
        imported = {row["keyframe_id"]: copy_frame(recording, temporary, role, row)
                    for role, rows in streams.items() for row in rows}
        data = {"schemaVersion": 1, "id": identity, "recording": manifest,
                "importedAt": datetime.now(timezone.utc).isoformat(), "frames": imported,
                "pairs": pairs, "pairing": "nearest_host_recorder_receipt",
                "maxHostReceiptSkewSeconds": max_skew, "hardwareSynchronized": False,
                "exposureSkewKnown": False, "crossCameraCalibrationValidated": False,
                "automaticRecognitionVerified": False, "motionAuthority": "none"}
        write_json(temporary / "multiview.json", data)
        (temporary / "reviews").mkdir()
        (temporary / "annotations").mkdir()
        render_report(temporary)
        target = parent / identity
        temporary.rename(target)
    except BaseException:
        shutil.rmtree(temporary)
        raise
    return {"session": str(target), "pairs": len(pairs), "frames": len(imported),
            "review": str(target / "review.html"), "labelStatus": "unreviewed"}


def get_pair(data, name):
    match = next((p for p in data["pairs"] if p["id"] == name), None)
    if match is None:
        raise ValueError("Unknown frame pair.")
    return match


def fen_context(fen):
    names = dict(zip("kqrbnp", ("king", "queen", "rook", "bishop", "knight", "pawn")))
    ranks = fen.split()[0].split("/")
    if len(ranks) != 8:
        raise ValueError("Invalid reference FEN.")
    labels = {}
    for rank, row in zip(range(8, 0, -1), ranks):
        pieces = []
        for p in row:
            if p in "12345678":
                pieces.extend(["empty"] * int(p))
            elif p.lower() in names:
                pieces.append(("white_" if p.isupper() else "black_") + names[p.lower()])
            else:
                raise ValueError("Invalid reference piece.")
        if len(pieces) != 8:
            raise ValueError("Invalid reference rank.")
        labels.update({f"{file}{rank}": label for file, label in zip("abcdefgh", pieces)})
    return labels


def review_pair(path, pair_id, native, record_id, confirmed, note):
    if not confirmed:
        raise ValueError("Inspect both images and confirm the main view matches the saved position.")
    data = load_session(path)
    pair = get_pair(data, pair_id)
    manifest = read_json(native / "session.json")
    record = next((r for r in manifest["records"] if r["id"].lower() == record_id.lower()), None)
    if record is None or record.get("labelKind") != "operator_verified_square_occupancy":
        raise ValueError("Choose a reviewed native Chess Study position.")
    uuid.UUID(record["id"])
    source = local_file(native, record["id"] + "/source.jpg")
    if digest(source.read_bytes()) != record["sourceSHA256"]:
        raise ValueError("The native reference image has changed.")
    if record["labels"] != fen_context(record["fen"]):
        raise ValueError("Native reference labels disagree with its FEN.")
    # Later captures are not relabeled as if they were the original teaching frame.
    review = {"id": str(uuid.uuid4()), "pairID": pair_id, "pair": pair,
              "reviewedAt": datetime.now(timezone.utc).isoformat(),
              "nativeSessionID": manifest["sessionID"], "nativeRecordID": record["id"],
              "nativeSourceSHA256": record["sourceSHA256"], "nativeCapturedAt": record["capturedAt"],
              "fen": record["fen"], "positionContext": record["labels"],
              "verification": "operator_reviewed_same_position_in_later_images", "note": note,
              "stationarySceneConfirmed": True, "temporalSuitability": "stationary_board",
              "bellySquareLabelsTransferred": False, "automaticRecognitionVerified": False}
    write_json(path / "reviews" / (review["id"] + ".json"), review)
    render_report(path)
    return review


def annotate_piece(path, review_id, role, square, box, visibility, confirmed, note):
    if not confirmed:
        raise ValueError("Piece crops need a visually reviewed identity and bounding box.")
    uuid.UUID(review_id)
    data = load_session(path)
    review = read_json(local_file(path, f"reviews/{review_id}.json"))
    label = review["positionContext"].get(square)
    if role not in ("face", "belly") or label in (None, "empty"):
        raise ValueError("Choose a camera and an occupied square in the reviewed position.")
    if visibility not in ("clear", "partial"):
        raise ValueError("An occluded object cannot provide a complete silhouette.")
    frame_id = get_pair(data, review["pairID"])[role]
    frame = data["frames"][frame_id]
    if (len(box) != 4 or not all(isinstance(v, int) and not isinstance(v, bool) for v in box)
            or not 0 <= box[0] < box[2] <= frame["width"]
            or not 0 <= box[1] < box[3] <= frame["height"]
            or min(box[2] - box[0], box[3] - box[1]) < 8):
        raise ValueError("Use a nonempty pixel bounding box within this camera image.")
    identity = str(uuid.uuid4())
    folder = path / "annotations" / identity
    folder.mkdir()
    with Image.open(path / "frames" / frame_id / "rgb.jpg") as image:
        image.crop(box).save(folder / "crop.png")
    annotation = {"id": identity, "reviewID": review_id, "pairID": review["pairID"],
                  "frameID": frame_id, "cameraRole": role, "squareContext": square,
                  "label": label, "boxPixels": box, "visibility": visibility,
                  "verification": "operator_reviewed_crop", "note": note,
                  "sourceSHA256": frame["hashes"]["rgb.jpg"],
                  "cropSHA256": digest((folder / "crop.png").read_bytes()),
                  "pixelBoxHeight": box[3] - box[1], "heightMillimeters": None,
                  "heightStatus": "needs_board_plane_and_depth_validation",
                  "motionAuthority": "none"}
    write_json(folder / "annotation.json", annotation)
    render_report(path)
    return annotation


def render_report(path):
    data = load_session(path)
    reviews = [read_json(p) for p in sorted((path / "reviews").glob("*.json"))]
    annotations = [read_json(p) for p in sorted((path / "annotations").glob("*/annotation.json"))]
    if sum((path / "frames" / name / "rgb.jpg").stat().st_size for name in data["frames"]) > 32_000_000:
        raise ValueError("The portable review page needs a shorter clip (at most 32 MB of RGB images).")
    images = {name: "data:image/jpeg;base64," + base64.b64encode(
        (path / "frames" / name / "rgb.jpg").read_bytes()).decode() for name in data["frames"]}
    payload = json.dumps({"session": data, "reviews": reviews, "annotations": annotations,
                          "images": images}, allow_nan=False).replace("<", "\\u003c")
    template = Path(__file__).resolve().parents[1] / "Tools/ChessStudy/multiview-review.html"
    (path / "review.html").write_text(template.read_text().replace("__ROB_DATA__", payload))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    imp = commands.add_parser("import")
    imp.add_argument("--project", type=Path, required=True)
    imp.add_argument("--recording", type=Path, required=True)
    imp.add_argument("--max-skew-ms", type=float, default=250)
    review = commands.add_parser("review")
    review.add_argument("--session", type=Path, required=True)
    review.add_argument("--pair", required=True)
    review.add_argument("--native-session", type=Path, required=True)
    review.add_argument("--record-id", required=True)
    review.add_argument("--confirmed", action="store_true")
    review.add_argument("--note", default="")
    annotation = commands.add_parser("annotate")
    annotation.add_argument("--session", type=Path, required=True)
    annotation.add_argument("--review-id", required=True)
    annotation.add_argument("--camera", choices=("face", "belly"), default="belly")
    annotation.add_argument("--square", required=True)
    annotation.add_argument("--box", type=int, nargs=4, required=True, metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"))
    annotation.add_argument("--visibility", choices=("clear", "partial"), required=True)
    annotation.add_argument("--confirmed", action="store_true")
    annotation.add_argument("--note", default="")
    report = commands.add_parser("report")
    report.add_argument("--session", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "import":
        result = import_recording(args.project.expanduser().resolve(), args.recording.expanduser().resolve(), args.max_skew_ms / 1000)
    elif args.command == "review":
        result = review_pair(args.session.resolve(), args.pair, args.native_session.resolve(), args.record_id, args.confirmed, args.note)
    elif args.command == "annotate":
        result = annotate_piece(args.session.resolve(), args.review_id, args.camera, args.square, args.box, args.visibility, args.confirmed, args.note)
    else:
        render_report(args.session.resolve())
        result = {"review": str(args.session.resolve() / "review.html")}
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(str(error))
