"""Synthetic metric tests for the actual offline QR/neck calibration worker."""

import copy
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "Cerebro/Resources/ShadowPlanner/qr_neck_calibration.py"
SPEC = importlib.util.spec_from_file_location("qr_neck_calibration", WORKER)
QR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QR)


def rotate(axis, degrees):
    vector = np.zeros(3)
    vector[axis] = math.radians(degrees)
    return cv2.Rodrigues(vector)[0]


def dataset():
    camera = np.array([[700., 0, 640], [0, 700., 360], [0, 0, 1]])
    optical = np.array([[0., 0, 1], [-1, 0, 0], [0, -1, 0]])
    neck_camera = QR.transform(optical @ rotate(0, -7), [.08, -.015, .10])
    base_target = QR.transform(np.array([[0., 1, 0], [-1, 0, 0], [0, 0, 1]]), [.65, .02, .78])
    views = []
    for index, (pan, tilt) in enumerate((p, t) for p in [-12, -6, 0, 6, 12] for t in [28, 35, 42]):
        base_neck = QR.transform(rotate(2, pan) @ rotate(1, tilt), [.05, 0, 1.08])
        target_camera = np.linalg.inv(base_neck @ neck_camera) @ base_target
        vector = cv2.Rodrigues(target_camera[:3, :3])[0]
        pixels = cv2.projectPoints(QR.object_corners(), vector, target_camera[:3, 3], camera, np.zeros(5))[0]
        views.append({"id": f"view-{index}", "cameraMatrix": [700., 700., 640., 360.],
                      "cornersPixels": pixels.reshape(4, 2).tolist(),
                      "baseToNeck": base_neck.reshape(-1).tolist(), "training": index < 12,
                      "imageSize": [1280, 720], "distortionCoefficients": [0., 0., 0., 0., 0.]})
    return {"schemaVersion": 1, "targetID": QR.TARGET_ID, "symbolSideMeters": .12,
            "poseSource": "synthetic_known_poses", "views": views}, neck_camera, base_target


class QRNeckCalibrationTests(unittest.TestCase):
    def test_recovers_metric_extrinsics_and_independent_views(self):
        source, actual, target = dataset()
        result = QR.fit(source)
        fitted = np.array(result["neckToCamera"]).reshape(4, 4)
        np.testing.assert_allclose(fitted, actual, atol=1e-6, rtol=0)
        np.testing.assert_allclose(np.array(result["baseToTarget"]).reshape(4, 4), target, atol=1e-6, rtol=0)
        self.assertLess(result["trainingTranslationRMSEMeters"], 1e-6)
        self.assertLess(result["heldOutTranslationRMSEMeters"], 1e-6)
        self.assertLess(result["heldOutRotationRMSEDegrees"], 1e-4)
        self.assertFalse(result["registrationVerified"])
        self.assertIsNone(result["uncertaintyMeters"])
        self.assertEqual(result["status"], "fitted_unverified")

    def test_held_out_data_does_not_train_the_transform(self):
        source, actual, _ = dataset()
        source["views"][-1]["baseToNeck"][3] += .03
        result = QR.fit(source)
        np.testing.assert_allclose(np.array(result["neckToCamera"]).reshape(4, 4), actual, atol=1e-6, rtol=0)
        self.assertGreater(result["heldOutTranslationRMSEMeters"], .01)
        self.assertLess(result["trainingTranslationRMSEMeters"], 1e-6)

    def test_pose_only_can_record_first_view(self):
        source, _, _ = dataset()
        source["views"] = source["views"][:1]
        result = QR.fit(source, mode="poses")
        self.assertEqual(result["status"], "poses_unverified")
        self.assertFalse(result["registrationVerified"])
        self.assertEqual(len(result["views"][0]["targetToCamera"]), 16)
        self.assertEqual(result["depthCheckViewCount"], 0)
        self.assertIsNone(result["depthCenterResidualRMSEMeters"])

    def test_aligned_center_depth_is_diagnostic_and_does_not_train(self):
        source, actual, _ = dataset()
        for view in source["views"]:
            view["centerDepthMeters"] = QR.pose_for_view(view)["pnpCenterDepthMeters"]
        result = QR.fit(source)
        self.assertEqual(result["depthCheckViewCount"], 15)
        self.assertLess(result["depthCenterResidualRMSEMeters"], 1e-9)
        self.assertEqual(result["depthAgreementWarningViewIDs"], [])
        source["views"][-1]["centerDepthMeters"] += .12
        changed = QR.fit(source)
        self.assertEqual(changed["depthAgreementWarningViewIDs"], [source["views"][-1]["id"]])
        self.assertAlmostEqual(changed["views"][-1]["centerDepthResidualMeters"], -.12)
        self.assertGreater(changed["depthCenterResidualRMSEMeters"], .03)
        np.testing.assert_allclose(np.array(changed["neckToCamera"]).reshape(4, 4), actual, atol=1e-6, rtol=0)
        self.assertFalse(changed["registrationVerified"])
        self.assertTrue(any("diagnostic only" in warning for warning in changed["warnings"]))

        first_only = copy.deepcopy(source)
        first_only["views"] = first_only["views"][-1:]
        self.assertEqual(QR.fit(first_only, mode="poses")["depthCheckViewCount"], 1)

    def test_rejects_malformed_corner_pose_and_intrinsic_inputs(self):
        source, _, _ = dataset()
        mutations = [
            lambda d: d.update(targetID="other"),
            lambda d: d.update(symbolSideMeters=.12 * 1.1),
            lambda d: d["views"][0].update(training=1),
            lambda d: d["views"][0].update(cornersPixels=[[0, 0]] * 4),
            lambda d: d["views"][0].update(cornersPixels=list(reversed(d["views"][0]["cornersPixels"]))),
            lambda d: d["views"][0]["cameraMatrix"].__setitem__(0, float("nan")),
            lambda d: d["views"][0]["cameraMatrix"].__setitem__(0, "700"),
            lambda d: d["views"][0]["baseToNeck"].__setitem__(0, 2.),
            lambda d: d["views"][0]["baseToNeck"].__setitem__(15, 0.),
            lambda d: d["views"][0]["cornersPixels"][0].__setitem__(0, 9000.),
            lambda d: d["views"][0].update(id=d["views"][1]["id"]),
            lambda d: d["views"][0].update(distortionCoefficients=[0, 0, 0]),
            lambda d: d["views"][0].update(centerDepthMeters="0.8"),
            lambda d: d["views"][0].update(centerDepthMeters=True),
            lambda d: d["views"][0].update(centerDepthMeters=float("nan")),
            lambda d: d["views"][0].update(centerDepthMeters=-.1),
            lambda d: d["views"][0].update(centerDepthMeters=10.1),
            lambda d: [v.update(training=True) for v in d["views"]],
            lambda d: [v.update(training=False) for v in d["views"]],
        ]
        for mutation in mutations:
            changed = copy.deepcopy(source)
            mutation(changed)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                QR.fit(changed)

    def test_reprojection_error_rejects_a_distorted_quad(self):
        source, _, _ = dataset()
        source["views"][0]["cornersPixels"][0][0] += 25
        with self.assertRaisesRegex(ValueError, "reprojection"):
            QR.fit(source)

    def test_parallel_neck_rotations_cannot_be_fit(self):
        source, _, _ = dataset()
        baseline = source["views"][0]["baseToNeck"]
        for view in source["views"]:
            view["baseToNeck"] = list(baseline)
        with self.assertRaisesRegex(ValueError, "rotational neck motion"):
            QR.fit(source)

        # Distinct rotations around just one neck axis are also insufficient.
        for index, view in enumerate(source["views"]):
            view["baseToNeck"] = QR.transform(rotate(2, index * 2), [.05, 0, 1.08]).reshape(-1).tolist()
        with self.assertRaisesRegex(ValueError, "neck rotations are parallel"):
            QR.fit(source)

    def test_planar_ambiguity_is_retained_in_pose_evidence(self):
        source, _, _ = dataset()
        view = source["views"][0]
        camera = np.array([[700., 0, 640], [0, 700., 360], [0, 0, 1]])
        # Near-front view: both tilted square hypotheses look almost identical.
        rotation = rotate(0, 179.9)
        pixels = cv2.projectPoints(QR.object_corners(), cv2.Rodrigues(rotation)[0],
                                   np.array([0., 0., 1.2]), camera, np.zeros(5))[0]
        view["cornersPixels"] = pixels.reshape(4, 2).tolist()
        result = QR.pose_for_view(view)
        self.assertTrue(result["poseAmbiguous"])
        self.assertTrue(result["alternativePoses"])

    def test_cli_rejects_bad_json_without_registration_material(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            incoming, outgoing = folder / "input.json", folder / "output.json"
            incoming.write_text('{"schemaVersion": NaN}')
            process = subprocess.run([sys.executable, str(WORKER), str(incoming), str(outgoing)],
                                     capture_output=True, text=True)
            self.assertEqual(process.returncode, 2)
            result = json.loads(outgoing.read_text())
            self.assertEqual(result["status"], "rejected")
            self.assertFalse(result["registrationVerified"])


if __name__ == "__main__":
    unittest.main()
