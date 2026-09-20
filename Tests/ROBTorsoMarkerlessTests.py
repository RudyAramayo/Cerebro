"""Torso fit tests use synthetic full surfaces, not real camera accuracy claims."""
import base64
import math
import os
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["VECLIB_MAXIMUM_THREADS"] = "1"
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Cerebro/Resources/ShadowPlanner"))
from worker import ShadowPlanner
from torso_markerless import TorsoEstimator, angle_difference, least_squares, numerical_jacobian


class TorsoTests(unittest.TestCase):
    def setUp(self):
        self.p = ShadowPlanner()
        self.e = TorsoEstimator(self.p)

    def fixture(self, yaw=1.3, lean=.4):
        q = self.p.q0.copy()
        q[self.e.yaw_index] = yaw; q[self.e.lean_index] = lean
        points, _, labels = self.e.points(q, self.e.names)
        camera = self.p.plant.CalcRelativeTransform(self.p.context, self.p.plant.world_frame(),
            self.p.plant.GetFrameByName("oak_optical_frame", self.p.model)).GetAsMatrix4()
        cloud = (points - camera[:3, 3]) @ camera[:3, :3]
        # Full-surface fitting isolates articulation and camera registration.
        # Visibility rejection is separately checked with the real projection.
        self.e.visible = lambda points, *args: np.ones(len(points), dtype=bool)
        return cloud, labels, camera

    def fit(self, cloud):
        return self.e.fit_body("face", cloud, np.ones((20, 20)), [100, 100, 10, 10])

    def test_global_acquisition_without_home_or_commanded_yaw(self):
        yaw = math.radians(143)
        cloud, _, _ = self.fixture(yaw=yaw)
        result = self.fit(cloud)
        self.assertLess(abs(angle_difference(result["yawRadians"], yaw)), math.radians(.5))
        self.assertEqual(result["status"], "settling")
        for _ in range(4): result = self.fit(cloud)
        self.assertEqual(result["status"], "confirmed")
        self.assertLess(abs(angle_difference(result["yawRadians"], yaw)), .002)
        self.assertLess(abs(result["leanRadians"] - .4), .002)

    def test_analytic_camera_and_joint_derivatives_match_numerical_motion(self):
        cloud, _, camera = self.fixture()
        self.e.prior_body["face"] = (1.3, .4); self.e.cameras["face"] = camera
        checked = []
        def validate(function, initial, **kwargs):
            if not checked:
                point = initial.copy(); point[3:6] = [.004, -.003, .002]
                analytic = kwargs["jac"](point)
                numerical = numerical_jacobian(function, point, step=1e-7)
                np.testing.assert_allclose(analytic, numerical, atol=1e-6)
                checked.append(True)
            return least_squares(function, initial, **kwargs)
        with patch("torso_markerless.least_squares", side_effect=validate): self.fit(cloud)
        self.assertTrue(checked)

    def test_camera_pose_error_is_fitted_separately_from_torso_yaw(self):
        cloud, _, camera = self.fixture()
        self.e.prior_body["face"] = (1.2, .38)
        camera[:3, 3] += [.008, -.005, .005]
        self.e.cameras["face"] = camera
        result = self.fit(cloud)
        self.assertLess(abs(result["yawRadians"] - 1.3), .002)
        self.assertLess(result["residualMeters"], .001)

    def test_base_only_and_torso_only_are_not_a_joint_observation(self):
        cloud, labels, camera = self.fixture()
        self.e.prior_body["face"] = (1.3, .4); self.e.cameras["face"] = camera
        for names in [["base_link", "left_track_link", "right_track_link"], ["torso_link"]]:
            with self.assertRaisesRegex(ValueError, "unconfirmed"):
                self.fit(cloud[np.isin(labels, names)])

    def test_real_projection_rejects_an_occluded_body(self):
        cloud, _, camera = self.fixture()
        points = cloud @ camera[:3, :3].T + camera[:3, 3]
        self.assertFalse(TorsoEstimator.visible(points, camera, np.zeros((240, 320)), [180, 180, 160, 120]).any())

    def frame(self, sequence=1):
        return dict(camera="face", streamID="synthetic", sequence=sequence, timestampNanoseconds=sequence,
                    capturedAtMilliseconds=time.time() * 1000, width=20, height=20,
                    intrinsics=[20, 20, 10, 10], depth=base64.b64encode(np.full((20, 20), 900, dtype="<u2").tobytes()).decode())

    def test_replayed_stale_and_unseen_depth_never_confirm(self):
        frame = self.frame(); self.e.cloud(frame)
        self.assertEqual(self.e.process(frame)["status"], "unavailable")
        frame = self.frame(2); frame["capturedAtMilliseconds"] -= 2000
        self.assertEqual(self.e.process(frame)["status"], "stale")
        frame = self.frame(3); frame["depth"] = base64.b64encode(bytes(800)).decode()
        result = self.e.process(frame)
        self.assertEqual(result["status"], "unavailable")
        self.assertNotIn("torso", result)

    def test_compute_budget_failure_never_becomes_confirmation(self):
        cloud, _, camera = self.fixture()
        self.e.prior_body["face"] = (1.3, .4); self.e.cameras["face"] = camera
        self.e.deadline = time.monotonic() - 1
        with self.assertRaisesRegex(ValueError, "computation budget"):
            self.fit(cloud)


if __name__ == "__main__": unittest.main()
