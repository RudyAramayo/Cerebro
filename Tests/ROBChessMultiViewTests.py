#!/usr/bin/env python3
"""Exercise real recording imports, independent clocks and explicit image labels."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("multiview", ROOT / "Scripts/chess-multiview.py")
mv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mv)
START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"


class MultiViewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rob-chess-multiview-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "game"
        self.project.mkdir()
        mv.write_json(self.project / "game.json", {"preset": "chess"})
        self.recording = self.root / "recording"
        self.recording.mkdir()
        mv.write_json(self.recording / "manifest.json", {
            "schema": "com.orbitusrobotics.cerebro.training-session", "schema_version": 1,
            "state": "complete", "camera_roles": {"face": True, "belly": True}})
        self.rows = {}
        for role, times in {"face": [10., 11.], "belly": [10.08, 11.09, 15.]}.items():
            directory = self.recording / "cameras" / role
            (directory / "rgb").mkdir(parents=True)
            (directory / "depth").mkdir()
            rows = []
            for i, receipt in enumerate(times):
                key = f"{role}-{i + 1:012d}"
                relative = f"cameras/{role}"
                image = self.recording / relative / "rgb" / (key + ".jpg")
                Image.new("RGB", (64, 64), (130 + i, 150, 170)).save(image)
                depth = self.recording / relative / "depth" / (key + ".depth16")
                depth.write_bytes(struct.pack("<H", 700) * 64 * 64)
                rows.append({"keyframe_id": key, "source_sequence": i + 1,
                             # Deliberately unrelated device clocks.
                             "source_timestamp_nanoseconds": int((receipt + (900 if role == "belly" else 0)) * 1e9),
                             "received_at_uptime": receipt, "received_at": "2026-09-14T05:00:00Z",
                             "rgb_file": f"{relative}/rgb/{key}.jpg", "rgb_width": 64, "rgb_height": 64,
                             "aligned_depth_file": f"{relative}/depth/{key}.depth16",
                             "aligned_depth_width": 64, "aligned_depth_height": 64,
                             "aligned_depth_encoding": "uint16-little-endian-millimeters-zero-invalid",
                             "intrinsics": {"fx": 70, "fy": 70, "cx": 32, "cy": 32}})
            self.rows[role] = rows
        self.write_rows()

    def write_rows(self):
        for role, rows in self.rows.items():
            (self.recording / "cameras" / role / "frames.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows))

    def imported(self):
        return Path(mv.import_recording(self.project, self.recording)["session"])

    def native(self):
        path = self.root / "native"
        path.mkdir()
        record_id = str(uuid.uuid4())
        source = path / record_id / "source.jpg"
        source.parent.mkdir()
        Image.new("RGB", (64, 64), "white").save(source)
        record = {"id": record_id, "labelKind": "operator_verified_square_occupancy",
                  "sourceSHA256": mv.digest(source.read_bytes()), "capturedAt": "2026-09-14T04:00:00Z",
                  "fen": START, "labels": mv.fen_context(START)}
        mv.write_json(path / "session.json", {"sessionID": str(uuid.uuid4()), "records": [record]})
        return path, record_id

    def test_import_preserves_both_cameras_without_claiming_exposure_sync(self):
        path = self.imported()
        data = mv.load_session(path)
        self.assertEqual(len(data["pairs"]), 2)
        self.assertEqual(len(data["frames"]), 5)  # Unmatched evidence is retained.
        self.assertFalse(data["hardwareSynchronized"])
        self.assertFalse(data["exposureSkewKnown"])
        self.assertEqual(data["motionAuthority"], "none")
        self.assertAlmostEqual(data["pairs"][0]["hostReceiptSkewSeconds"], .08)
        self.assertTrue(all(f["labelStatus"] == "unreviewed" for f in data["frames"].values()))
        self.assertEqual((path / "frames/belly-000000000001/depth-u16le-mm.raw").stat().st_size, 8192)
        self.assertIn("Awaiting position review", (path / "review.html").read_text())

    def test_pairing_never_reuses_a_frame_and_rejects_stale_views(self):
        face = [{"keyframe_id": str(i), "received_at_uptime": t} for i, t in enumerate([1., 1.1, 4.])]
        belly = [{"keyframe_id": "b", "received_at_uptime": 1.05}]
        self.assertEqual(len(mv.pair_frames(face, belly, .25)), 1)
        self.assertEqual(mv.pair_frames(face, [{**belly[0], "received_at_uptime": 9}], .25), [])
        for invalid in [0, -1, .51, float("nan"), float("inf")]:
            with self.assertRaises(ValueError):
                mv.pair_frames(face, belly, invalid)

    def test_bad_depth_rolls_back_import(self):
        (self.recording / self.rows["belly"][0]["aligned_depth_file"]).write_bytes(b"bad")
        with self.assertRaises(ValueError):
            self.imported()
        self.assertEqual(list((self.project / "multiview").iterdir()), [])

    def test_live_recording_and_missing_host_time_are_rejected(self):
        manifest = mv.read_json(self.recording / "manifest.json")
        mv.write_json(self.recording / "manifest.json", {**manifest, "state": "recording"})
        with self.assertRaises(ValueError):
            self.imported()
        mv.write_json(self.recording / "manifest.json", manifest)
        del self.rows["belly"][0]["received_at_uptime"]
        self.write_rows()
        with self.assertRaises(ValueError):
            self.imported()

    def test_path_escape_symlink_and_cross_camera_source_are_rejected(self):
        for bad in ["../outside.jpg", "/tmp/outside.jpg", self.rows["face"][0]["rgb_file"]]:
            self.rows["belly"][0]["rgb_file"] = bad
            self.write_rows()
            with self.assertRaises(ValueError):
                self.imported()
        (self.recording / "linked").symlink_to(self.project, target_is_directory=True)
        with self.assertRaises(ValueError):
            mv.local_file(self.recording, "linked/game.json")

    def test_changed_depth_and_recorder_metadata_are_detected(self):
        for name in ["depth-u16le-mm.raw", "recorder-frame.json"]:
            path = self.imported()
            (path / "frames/belly-000000000001" / name).write_bytes(b"changed")
            with self.assertRaises(ValueError):
                mv.load_session(path)

    def test_review_and_crop_require_confirmation_and_preserve_ambiguity(self):
        path = self.imported()
        native, record_id = self.native()
        with self.assertRaises(ValueError):
            mv.review_pair(path, "pair-0001", native, record_id, False, "")
        review = mv.review_pair(path, "pair-0001", native, record_id, True, "Board stayed still.")
        self.assertTrue(review["stationarySceneConfirmed"])
        self.assertFalse(review["bellySquareLabelsTransferred"])
        with self.assertRaises(ValueError):
            mv.annotate_piece(path, review["id"], "belly", "d1", [10, 10, 40, 50], "clear", False, "")
        for square, box in [("e4", [10, 10, 40, 50]), ("d1", [10, 10, 70, 50])]:
            with self.assertRaises(ValueError):
                mv.annotate_piece(path, review["id"], "belly", square, box, "clear", True, "")
        annotation = mv.annotate_piece(path, review["id"], "belly", "d1", [10, 10, 40, 50], "partial", True, "Partly hidden.")
        self.assertEqual(annotation["label"], "white_queen")
        self.assertIsNone(annotation["heightMillimeters"])
        self.assertEqual(annotation["visibility"], "partial")
        self.assertEqual(mv.load_session(path)["frames"]["belly-000000000001"]["labelStatus"], "unreviewed")
        self.assertEqual(len(mv.read_json(native / "session.json")["records"]), 1)

    def test_native_reference_labels_must_match_position(self):
        path = self.imported()
        native, record_id = self.native()
        manifest = mv.read_json(native / "session.json")
        manifest["records"][0]["labels"]["d1"] = "white_bishop"
        mv.write_json(native / "session.json", manifest)
        with self.assertRaises(ValueError):
            mv.review_pair(path, "pair-0001", native, record_id, True, "")


if __name__ == "__main__":
    unittest.main()
