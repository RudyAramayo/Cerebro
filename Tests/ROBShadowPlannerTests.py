"""Actual Drake shadow solves and tracking failures; no hardware endpoint exists."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
import uuid

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "Cerebro/Resources/ShadowPlanner/worker.py"
spec = importlib.util.spec_from_file_location("shadow_worker", WORKER)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class Clock:
    value = 1700000000.
    def now(self):
        return self.value


class ShadowPlannerTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.engine = worker.ShadowPlanner(monotonic=self.clock.now, wall=self.clock.now)
        self.session = str(uuid.uuid4())
        self.controller = str(uuid.uuid4())
        self.shadow = str(uuid.uuid4())
        self.tracking_id = str(uuid.uuid4())
        self.sequence = self.sample_id = 0
        self.reference = self.send("start")

    def request(self, action, **fields):
        self.sequence += 1
        command = dict(action=action, shadowID=self.shadow, requestID=str(uuid.uuid4()), **fields)
        if action != "start":
            command["modelID"] = self.engine.reference["modelID"]
        return dict(protocol=worker.PROTOCOL, kind="request", controllerID=self.controller,
                    sessionID=self.session, sequence=self.sequence,
                    sentAtMilliseconds=int(self.clock.now() * 1000), command=command)

    def send(self, action, **fields):
        return self.engine.handle(self.request(action, **fields))

    def sample(self, position=(0, 0, 0), quaternion=(0, 0, 0, 1), **fields):
        self.sample_id += 1
        value = dict(trackingID=self.tracking_id, sampleID=self.sample_id,
                     quality="tracked", ageMilliseconds=0,
                     pose=dict(position=list(position), quaternion=list(quaternion)))
        value.update(fields)
        return value

    def align_and_clutch(self, scale=1):
        self.assertEqual(self.send("align", tracking=self.sample())["status"], "aligned")
        self.assertEqual(self.send("clutch", tracking=self.sample(), translationScale=scale)["status"], "clutched")

    def assert_fixed(self, result):
        before = {f["name"]: f["pose"] for f in self.reference["referenceFrames"]}
        for frame in result["ghostFrames"]:
            if not frame["name"].startswith("left_") or frame["name"].startswith(("left_track", "left_flipper", "left_sprocket")):
                np.testing.assert_allclose(frame["pose"]["position"], before[frame["name"]]["position"], atol=1e-9)
                np.testing.assert_allclose(frame["pose"]["quaternion"], before[frame["name"]]["quaternion"], atol=1e-9)
        self.assertFalse(result["hardwareOutputEnabled"])
        self.assertEqual(result["referenceSource"], "approved_scan_estimate")
        self.assertEqual(result["collisionStatus"], "not_checked")

    def test_reference_is_not_silently_clamped(self):
        self.assertEqual(self.reference["status"], "ready")
        self.assertGreater(self.engine.q0[self.engine.joints["right_joint2"].position_start()], np.deg2rad(120))
        self.assertLess(abs(self.reference["positions"][1]), np.deg2rad(120))
        self.assert_fixed(self.reference)

    def test_clutch_and_reclutch_do_not_jump(self):
        self.align_and_clutch()
        before = self.engine.q.copy()
        self.send("release")
        response = self.send("clutch", tracking=self.sample((1, 2, 3)), translationScale=.2)
        np.testing.assert_array_equal(before, self.engine.q)
        self.assertEqual(response["status"], "clutched")
        result = self.send("pose", tracking=self.sample((1, 2, 3)))
        self.assertEqual(result["status"], "solved")
        self.assertLess(result["positionErrorMeters"], 1e-8)

    def test_room_forward_maps_to_rob_forward_with_precision(self):
        self.align_and_clutch(scale=.2)
        start = self.engine.tool().translation().copy()
        result = self.send("pose", tracking=self.sample((0, 0, -.01)))
        self.assertEqual(result["status"], "solved")
        np.testing.assert_allclose(np.array(result["target"]["position"]) - start, [.002, 0, 0], atol=1e-10)
        self.assertLess(result["positionErrorMeters"], .00087)
        self.assert_fixed(result)

    def test_wrist_orientation_is_requested_in_robot_axes(self):
        self.align_and_clutch()
        q = [0, np.sin(.015), 0, np.cos(.015)]
        result = self.send("pose", tracking=self.sample(quaternion=q))
        self.assertEqual(result["status"], "solved")
        self.assertLess(result["orientationErrorRadians"], .01501)
        self.assert_fixed(result)

    def test_stale_low_accuracy_and_replayed_samples_pause(self):
        for fields in (dict(ageMilliseconds=151), dict(quality="low_accuracy"), dict(sampleID=1)):
            self.align_and_clutch()
            before = self.engine.q.copy()
            result = self.send("pose", tracking=self.sample(**fields))
            self.assertEqual(result["status"], "paused")
            np.testing.assert_array_equal(before, self.engine.q)
            self.assertEqual(self.send("pose", tracking=self.sample())["status"], "paused")

    def test_gap_and_tracking_jump_require_reclutch_or_alignment(self):
        self.align_and_clutch()
        self.clock.value += .3
        self.assertEqual(self.send("pose", tracking=self.sample())["status"], "paused")
        self.align_and_clutch()
        result = self.send("pose", tracking=self.sample((1, 0, 0)))
        self.assertEqual(result["status"], "paused")
        self.assertIsNone(self.engine.alignment)

    def test_tracking_restart_accepts_new_alignment_but_not_old_origin(self):
        self.align_and_clutch()
        self.tracking_id = str(uuid.uuid4()); self.sample_id = 0
        self.assertEqual(self.send("pose", tracking=self.sample())["status"], "paused")
        self.assertEqual(self.send("align", tracking=self.sample())["status"], "aligned")

    def test_wrong_model_and_session_cannot_move_ghost(self):
        self.align_and_clutch()
        before = self.engine.q.copy()
        request = self.request("pose", tracking=self.sample((0, 0, -.005)))
        request["command"]["modelID"] = "0" * 64
        self.assertEqual(self.engine.handle(request)["status"], "paused")
        self.session = str(uuid.uuid4())
        self.assertEqual(self.send("pose", tracking=self.sample())["status"], "paused")
        np.testing.assert_array_equal(before, self.engine.q)

    def test_xyz_steps_and_unreachable_target(self):
        for axis in range(3):
            for sign in (-1, 1):
                delta = [0., 0., 0.]; delta[axis] = sign * .005
                before_step = self.engine.q.copy()
                result = self.send("nudge", delta=delta)
                # At the nearly fully hanging reference, a downward 5 mm
                # target exceeds provisional J2 travel. Do not widen the limit.
                self.assertEqual(result["status"], "blocked" if (axis, sign) == (2, -1) else "solved")
                if result["status"] == "blocked":
                    np.testing.assert_array_equal(before_step, self.engine.q)
                self.assert_fixed(result)
                self.assertLessEqual(max(abs(x) for x in result["positions"]), np.deg2rad(120) + 1e-8)
        before = self.engine.q.copy()
        target = worker.RigidTransform(self.engine.tool().rotation(), [20, 0, 0])
        result = self.engine.solve(self.request("nudge", delta=[.005, 0, 0]), target)
        self.assertEqual(result["status"], "blocked")
        np.testing.assert_array_equal(before, self.engine.q)

    def test_stdio_protocol_uses_real_drake_and_no_driver(self):
        request = self.request("start")
        request["sentAtMilliseconds"] = int(worker.time.time() * 1000)
        completed = subprocess.run([sys.executable, "-B", str(WORKER)], input=json.dumps(request) + "\n",
                                   capture_output=True, text=True, timeout=10, check=True)
        response = json.loads(completed.stdout)
        self.assertEqual(response["requestID"], request["command"]["requestID"])
        self.assertEqual(response["status"], "ready")
        self.assert_fixed(response)


if __name__ == "__main__":
    unittest.main()
