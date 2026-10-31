"""Inert transport tests. These tests never connect to Cerebro or robot hardware."""
import base64
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"Scripts"))
import cerebro_prepare as prep


BASE = {f"arm.{a}.j{j}":0.0 for a in ("left", "right") for j in range(1, 8)}
PLAN = {"baseline":BASE, "values":{"arm.left.j2":.1, "arm.right.j2":-.1}, "seconds":.65}
REGIONS = {"can":[0,0,4,4]}


class Fake:
    def __init__(self, failure=None):
        self.failure = failure
        self.calls = []
        self.operation = "idle"
        self.started = None
        self.stopped = False
        self.overlapped = 0
        self.frames = 0

    def __call__(self, op, params=None, **kwargs):
        self.calls.append(op)
        running = self.started is not None and time.monotonic()-self.started < .4 and not self.stopped
        result = {}
        if op == "motion.move":
            self.operation = kwargs["request_id"]
            self.started = time.monotonic()
            if self.failure == "lost_reply":
                raise RuntimeError("Reply lost")
            result = {"operation_id":self.operation}
        elif op == "stop":
            self.stopped = True
        elif op == "status":
            result = {"motion":{"running":running, "id":self.operation,
                                "detail":"Running" if running else "Sequence complete; robot holding."},
                      "mission":{"active":False}, "operations":["camera.depth"],
                      "gateway":{"exclusiveControllerSession":True, "sessionGeneration":1},
                      "neck":{"known":True,"pan":6000,"lower":6000,"upper":6000},
                      "torso":{"has_software_reference":True,"count":0,"front_count":0},
                      "navigation":{"pose_fresh":True,"x_m":0,"y_m":0,"yaw_radians":0},
                      "arms":{a:{"available":True,"age_ms":10,"modes":[2]*7,"q_radians":[0.]*7}
                              for a in ("left","right")}}
            if self.started:
                progress = min(1, (time.monotonic()-self.started)/.4)
                result["arms"]["left"]["q_radians"][1] = .1*progress
                result["arms"]["right"]["q_radians"][1] = -.1*progress
                if self.failure == "feedback":
                    result["arms"]["right"]["age_ms"] = 1300
                elif self.failure == "reversal":
                    result["arms"]["right"]["q_radians"][1] = .3
                elif self.failure == "takeover":
                    result["motion"]["id"] = "manual-owner"
                elif self.failure == "body":
                    result["torso"]["count"] = 500
                elif self.failure == "slam":
                    result["navigation"]["x_m"] = 1
                elif self.failure == "native_stop":
                    result["motion"] = {"id":self.operation,"running":False,"detail":"Stopped: current guard"}
            elif self.failure == "busy":
                result["motion"]["running"] = True
        elif op in ("camera.frame", "camera.depth"):
            self.frames += 1
            if self.failure == "encoder_busy" and self.frames in (1, 3):
                return {"ok":False,"session":"app-1","error":"Snapshot encoder busy; no camera frame queued"}
            self.overlapped += int(running)
            result = {"width":4,"height":4,"depth":{"format":"uint16_little_endian_millimeters",
                      "width":4,"height":4,"base64":base64.b64encode(struct.pack("<16H", *([1000]*16))).decode()},
                      "intrinsics":{"fx":10,"fy":10,"cx":1.5,"cy":1.5},
                      "captured_at_ms":time.time()*1000,"age_ms":0,"stream_id":"camera-1",
                      "timestamp_kind":"sensor_capture","jpeg_base64":base64.b64encode(b"test-jpeg").decode()}
            if self.started and self.failure == "stream":
                result["stream_id"] = "camera-2"
            if self.started and self.failure == "old_exposure":
                result["captured_at_ms"] -= 10000
            if op == "camera.depth":
                result.pop("jpeg_base64")
        else:
            raise AssertionError(op)
        return {"ok":True,"session":"app-1","result":result}


class PreparationTests(unittest.TestCase):
    def run_fake(self, fake):
        with tempfile.TemporaryDirectory() as tmp:
            return prep.prepare(copy.deepcopy(PLAN), REGIONS, Path(tmp)/"run", request=fake,
                                maximum_age_ms=1200, frame_interval=.25, final_timeout=.5)

    def test_depth_calculation_overlaps_one_paired_motion(self):
        fake = Fake()
        result = self.run_fake(fake)
        self.assertGreater(fake.overlapped, 0)
        self.assertIn("camera.depth", fake.calls)
        self.assertIn("camera.frame", fake.calls)
        self.assertEqual(fake.calls.count("motion.move"), 1)
        self.assertNotIn("stop", fake.calls)
        self.assertTrue(result["motion_complete"])
        self.assertFalse(result["next_motion_dispatched"])
        self.assertEqual(result["final_observation"]["regions"]["can"]["optical_xyz_m"], [0,0,1])

    def test_lost_reply_stops_exact_operation_without_replay(self):
        fake = Fake("lost_reply")
        with self.assertRaisesRegex(RuntimeError, "Reply lost"):
            self.run_fake(fake)
        self.assertEqual(fake.calls.count("motion.move"), 1)
        self.assertTrue(fake.stopped)

    def test_faults_stop_our_motion_without_next_target(self):
        for reason in ("feedback", "reversal", "body", "stream"):
            with self.subTest(reason=reason):
                fake = Fake(reason)
                with self.assertRaises(RuntimeError):
                    self.run_fake(fake)
                self.assertEqual(fake.calls.count("motion.move"), 1)
                self.assertTrue(fake.stopped)

    def test_takeover_is_not_overwritten_by_stop(self):
        fake = Fake("takeover")
        with self.assertRaisesRegex(RuntimeError, "ownership"):
            self.run_fake(fake)
        self.assertFalse(fake.stopped)

    def test_slam_update_does_not_invalidate_optical_depth(self):
        fake = Fake("slam")
        result = self.run_fake(fake)
        self.assertTrue(result["motion_complete"])
        self.assertNotEqual(result["context"]["pose"], result["final_context"]["pose"])
        self.assertFalse(result["final_observation"]["robot_registration_verified"])
        self.assertFalse(fake.stopped)

    def test_shared_encoder_retries_only_observation(self):
        fake = Fake("encoder_busy")
        self.assertTrue(self.run_fake(fake)["motion_complete"])
        self.assertEqual(fake.calls.count("motion.move"), 1)
        self.assertFalse(fake.stopped)

    def test_busy_does_not_dispatch(self):
        fake = Fake("busy")
        with self.assertRaisesRegex(RuntimeError, "already active"):
            self.run_fake(fake)
        self.assertNotIn("motion.move", fake.calls)

    def test_native_failure_is_not_arrival(self):
        fake = Fake("native_stop")
        with self.assertRaisesRegex(RuntimeError, "current guard"):
            self.run_fake(fake)
        self.assertEqual(fake.calls.count("motion.move"), 1)

    def test_post_arrival_requires_new_exposure(self):
        with self.assertRaisesRegex(RuntimeError, "observation timed out"):
            self.run_fake(Fake("old_exposure"))

    def test_invalid_depth_does_not_fabricate_range(self):
        frame = Fake()("camera.frame")["result"]
        frame["depth"]["base64"] = base64.b64encode(bytes(32)).decode()
        region = prep.depth_regions(frame, REGIONS)["can"]
        self.assertIn("unavailable", region)
        self.assertNotIn("optical_xyz_m", region)

    def test_gripper_feedback_is_checked_when_exposed(self):
        state=Fake()("status")["result"]
        for age in (None, 1500, float('nan')):
            state["arms"]["right"]["gripper_age_ms"]=age
            with self.assertRaisesRegex(RuntimeError, 'gripper CAN'):
                prep.arm_check(state, PLAN, 1200)

    def test_nonarm_and_nonfinite_targets_are_rejected(self):
        for values in ({"lact.speed":40}, {"arm.left.j1":float("nan")}, {}):
            with self.assertRaises(RuntimeError):
                prep.validate_plan(dict(PLAN, values=values))

    def test_full_disk_does_not_prevent_stop(self):
        fake = Fake()
        original = Path.open
        def failing_open(path, mode='r', *args, **kwargs):
            if path.name == 'events.jsonl' and fake.started is not None:
                raise OSError('No space left on device')
            return original(path, mode, *args, **kwargs)
        with patch.object(Path, 'open', failing_open):
            with self.assertRaisesRegex(OSError, 'No space'):
                self.run_fake(fake)
        self.assertTrue(fake.stopped)


if __name__ == "__main__":
    unittest.main()
