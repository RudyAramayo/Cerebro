"""Real scan clearance, both controllers, and markerless observation boundaries."""
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid

os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["VECLIB_MAXIMUM_THREADS"] = "1"
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Cerebro/Resources/ShadowPlanner"))
from worker import ShadowPlanner
from markerless import MarkerlessEstimator, rank_and_uncertainty


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.p = ShadowPlanner()
        self.sequence = 0
        self.controller, self.session, self.shadow = (str(uuid.uuid4()) for _ in range(3))
        self.sample_ids = {"left": 0, "right": 0}
        self.origins = {s: str(uuid.uuid4()) for s in self.sample_ids}
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / "observation.json"
        self.p.observation_path = str(self.path)

    def tearDown(self): self.folder.cleanup()

    def send(self, action, arm="left", **fields):
        self.sequence += 1
        command = dict(action=action, arm=arm, shadowID=self.shadow, requestID=str(uuid.uuid4()), **fields)
        if action == "start": command.setdefault("visionRequired", True)
        else: command["modelID"] = self.p.reference["modelID"]
        return self.p.handle(dict(protocol="rob-shadow-ik/2", kind="request", controllerID=self.controller,
                                  sessionID=self.session, sequence=self.sequence,
                                  sentAtMilliseconds=int(time.time()*1000), command=command))

    def tracking(self, side, position=(0, 1, 0)):
        self.sample_ids[side] += 1
        return dict(trackingID=self.origins[side], sampleID=self.sample_ids[side], ageMilliseconds=0,
                    quality="tracked", pose=dict(position=list(position), quaternion=[0, 0, 0, 1]))

    def observation(self, changes=None):
        q = self.p.q0.copy()
        # Synthetic observed hanging pose lies inside the stated travel.
        q[self.p.arm_indices["right"][1]] -= .06
        if changes:
            for side, delta in changes.items(): q[self.p.arm_indices[side][1]] += delta
        return dict(schemaVersion=1, modelID=self.p.reference["modelID"], referenceID=self.p.reference["referenceID"],
                    source="markerless_rgbd", frame="base_link", camera="face", sequence=self.sequence + 1,
                    capturedAtMilliseconds=time.time()*1000, status="confirmed", detail="synthetic test observation",
                    arms={s: dict(status="confirmed", positions=q[self.p.arm_indices[s]].tolist(),
                                  standardDeviationRadians=[.01]*7, residualMeters=.002) for s in ("left", "right")})

    def publish(self, value): self.path.write_text(json.dumps(value))

    def test_live_mode_never_uses_scan_as_observation(self):
        self.send("start")
        result = self.send("nudge", delta=[.005, 0, 0])
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["observedFrames"], [])
        self.assertEqual(result["visionStatus"], "unavailable")
        np.testing.assert_array_equal(self.p.q, self.p.q0)

    def test_reference_scan_overlap_blocks_and_reports_links(self):
        start = self.send("start", visionRequired=False)
        self.assertEqual(start["collisionStatus"], "blocked")
        self.assertLess(start["clearanceMeters"], 0)
        result = self.send("nudge", delta=[.005, 0, 0])
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["collisionPair"], ["torso_link", "left_two_Link"])
        np.testing.assert_array_equal(self.p.q, self.p.q0)

    def test_swept_head_collision_with_clear_endpoints(self):
        guard = self.p.clearance
        # Isolate this particular pair to establish the between-endpoints
        # regression independently of the known torso segmentation conflict.
        guard.pairs = [("left_tool", "insta360_link")]
        before = self.p.q0.copy()
        before[self.p.arm_indices["left"]] = [.69815909, -1.2, -1.33688079, -1.39065102, .55204388, 1.27244558, -1.07359512]
        after = before.copy(); after[self.p.arm_indices["left"][1]] = .1333333333333333
        self.assertTrue(guard.check(before)["clear"])
        self.assertTrue(guard.check(after)["clear"])
        self.assertFalse(guard.transition(before, after)["clear"])

    def test_arm_arm_and_torso_pairs_are_present_adjacent_mounts_excluded(self):
        pairs = {frozenset(p) for p in self.p.clearance.pairs}
        for pair in [("left_tool", "right_tool"), ("left_four_Link", "torso_link"), ("right_tool", "oak_link")]:
            self.assertIn(frozenset(pair), pairs)
        self.assertNotIn(frozenset(("left_one_Link", "left_two_Link")), pairs)

    def test_visual_correction_is_not_a_command_and_stale_depth_stops(self):
        self.send("start")
        value = self.observation({"left": .12}); self.publish(value)
        response = self.send("refresh")
        self.assertEqual(response["status"], "paused")
        self.assertEqual(len(response["observedFrames"]), 16)
        self.assertFalse(response["hardwareOutputEnabled"])
        self.assertAlmostEqual(self.p.q[self.p.arm_indices["left"][1]], value["arms"]["left"]["positions"][1])
        before = self.p.q.copy()
        value["capturedAtMilliseconds"] -= 2000; self.publish(value)
        response = self.send("nudge", arm="right", delta=[.002, 0, 0])
        self.assertEqual(response["visionStatus"], "stale")
        self.assertEqual(response["observedFrames"], [])
        self.assertEqual(response["status"], "blocked")
        np.testing.assert_array_equal(before, self.p.q)

    def test_invalid_uncertainty_or_missing_other_arm_blocks(self):
        self.send("start")
        for field in ("sigma", "missing", "model"):
            value = self.observation()
            if field == "sigma": value["arms"]["right"]["standardDeviationRadians"] = [10]*7
            if field == "missing": value["arms"].pop("right")
            if field == "model": value["modelID"] = "0"*64
            self.publish(value)
            self.assertEqual(self.send("nudge", delta=[.002, 0, 0])["status"], "blocked")

    def test_small_visual_drift_accumulates_to_correction(self):
        self.send("start"); self.publish(self.observation()); self.send("refresh")
        initial = self.p.q.copy()
        for delta in (.02, .04, .06):
            self.publish(self.observation({"left": delta})); self.send("refresh")
        self.assertGreater(self.p.q[self.p.arm_indices["left"][1]] - initial[self.p.arm_indices["left"][1]], .05)

    def test_right_controller_origin_and_grip_are_independent(self):
        self.send("start", visionRequired=False)
        for side in ("left", "right"):
            self.assertEqual(self.send("align", arm=side, tracking=self.tracking(side))["status"], "aligned")
        result = self.send("clutch", arm="right", tracking=self.tracking("right"), translationScale=1)
        self.assertEqual(result["status"], "blocked")  # +120.417° is never silently clamped.
        self.assertGreater(result["positions"][1], np.deg2rad(120))
        self.publish(self.observation()); self.p.vision_required = True; self.send("refresh")
        for side in ("left", "right"):
            self.assertEqual(self.send("clutch", arm=side, tracking=self.tracking(side), translationScale=.2)["status"], "clutched")
        # Isolate controller mapping from the separately-tested geometry guard.
        self.p.clearance.transition = lambda a, b: dict(clear=True, distance=.1, pair=None, required=.025)
        self.p.select_arm("right"); target = self.p.tool().translation().copy()
        left_before = self.p.q[self.p.arm_indices["left"]].copy()
        result = self.send("pose", arm="right", tracking=self.tracking("right", (0, 1, -.01)))
        self.assertEqual(result["status"], "solved")
        np.testing.assert_allclose(np.array(result["target"]["position"]) - target, [.002, 0, 0], atol=1e-10)
        np.testing.assert_array_equal(left_before, self.p.q[self.p.arm_indices["left"]])
        self.send("release", arm="right")
        self.assertIsNotNone(self.p.arm_tracking["left"]["clutch"])


class MarkerlessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.p = ShadowPlanner()

    def test_data_rank_cannot_be_created_by_a_prior(self):
        jacobian = np.zeros((100, 7)); jacobian[:, :6] = np.random.default_rng(2).normal(size=(100, 6))
        observable, _ = rank_and_uncertainty(jacobian)
        self.assertFalse(observable)

    def test_real_scan_articulated_fit_recovers_both_sides_without_markers(self):
        for side in ("left", "right"):
            estimator = MarkerlessEstimator(self.p)
            names = [n for n in estimator.surfaces if n.startswith(side + "_") and self.p.clearance.is_arm(n)]
            q = self.p.q0.copy(); q[self.p.arm_indices[side][1]] += .06 if side == "left" else -.06
            points, _, _ = estimator.points(q, names)
            # This test isolates fitting with an ideal full-surface cloud; it
            # is not evidence of a real camera's view or registration accuracy.
            estimator.visible = lambda p, *_: np.ones(len(p), dtype=bool)
            for index in range(3):
                result = estimator.fit_arm(side, points, np.ones((20, 20)), np.array([100, 100, 10, 10]), np.eye(4), 0)
            self.assertEqual(result["status"], "confirmed")
            np.testing.assert_allclose(result["positions"], q[self.p.arm_indices[side]], atol=1e-4)

    def test_missing_wrist_evidence_cannot_confirm_seven_joints(self):
        estimator = MarkerlessEstimator(self.p)
        points, _, _ = estimator.points(self.p.q0, ["left_one_Link", "left_two_Link", "left_three_Link"])
        estimator.visible = lambda p, *_: np.ones(len(p), dtype=bool)
        result = estimator.fit_arm("left", points, np.ones((20, 20)), np.array([100, 100, 10, 10]), np.eye(4), 0)
        self.assertNotEqual(result["status"], "confirmed")

    def test_depth_contract_rejects_stale_replayed_missing_and_wrong_dimensions(self):
        estimator = MarkerlessEstimator(self.p)
        frame = dict(camera="face", streamID="test", sequence=1, timestampNanoseconds=100,
                     capturedAtMilliseconds=time.time()*1000, width=32, height=32, intrinsics=[50, 50, 16, 16],
                     depth=base64.b64encode(np.full((32, 32), 900, dtype="<u2").tobytes()).decode())
        cloud, _, _ = estimator.cloud(frame)
        self.assertGreater(len(cloud), 150)
        with self.assertRaises(ValueError): estimator.cloud(frame)
        for mutation in (dict(sequence=2, timestampNanoseconds=101, depth=""), dict(sequence=3, capturedAtMilliseconds=0)):
            with self.assertRaises(ValueError): estimator.cloud(dict(frame, **mutation))
        empty = dict(frame, sequence=4, timestampNanoseconds=104, depth=base64.b64encode(bytes(32*32*2)).decode())
        self.assertEqual(estimator.process(empty)["status"], "unavailable")

    def test_unregistered_camera_never_borrows_scan_pose_as_live(self):
        estimator = MarkerlessEstimator(self.p)
        estimator.visible = lambda p, *_: np.zeros(len(p), dtype=bool)
        with self.assertRaisesRegex(ValueError, "cannot see enough"):
            estimator.register_camera("face", np.ones((200, 3)), np.ones((20, 20)), np.array([100, 100, 10, 10]))


if __name__ == "__main__": unittest.main()
