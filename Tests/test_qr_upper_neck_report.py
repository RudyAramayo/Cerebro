"""Metric upper-neck diagnostics and repeatability tests; no robot transport."""
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
WORKER = ROOT / "Cerebro/Resources/ShadowPlanner/qr_upper_neck_report.py"
SPEC = importlib.util.spec_from_file_location("qr_upper_neck_report", WORKER)
UPPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPPER)
QR = UPPER.QR


def rx(degrees):
    return cv2.Rodrigues(np.array([math.radians(degrees), 0., 0.]))[0]


def dataset():
    camera = np.array([[700., 0, 640], [0, 700., 360], [0, 0, 1.]])
    target = QR.transform(rx(140), [0., .04, .9])
    views = []
    for step, angle in enumerate([0., 2.5, 5., 2.5, 0.]):
        raw = QR.transform(rx(angle), [0., 0., 0.])
        pose = np.linalg.inv(raw) @ target
        pixels = cv2.projectPoints(QR.object_corners(), cv2.Rodrigues(pose[:3, :3])[0], pose[:3, 3], camera, np.zeros(5))[0].reshape(4, 2)
        center = cv2.projectPoints(np.zeros((1, 3)), cv2.Rodrigues(pose[:3, :3])[0], pose[:3, 3], camera, np.zeros(5))[0].reshape(2)
        for sample in range(3):
            index = step*3+sample
            views.append({"id": f"upper-{step}-{sample}", "stepIndex": step, "training": True,
                          "targetID": "ROB:TABLE:001", "cameraMatrix": [700., 700., 640., 360.],
                          "imageSize": [1280, 720], "cornersPixels": pixels.tolist(), "centerPixel": center.tolist(),
                          "baseToNeck": raw.reshape(-1).tolist(), "rawCameraToBase": raw.reshape(-1).tolist(),
                          "centerDepthMeters": float(pose[2, 3]), "neckPanDegrees": 0., "lowerTarget": 6011,
                          "neckUpperTarget": 6000+round(angle*30), "requestedUpperTarget": 6000+round(angle*30),
                          "requestedPanDegrees": 0., "sequence": index+1, "capturedAtMilliseconds": 1000.+index*100,
                          "protractorPitchDegrees": angle})
    return {"schemaVersion": 1, "targetID": "ROB:TABLE:001", "symbolSideMeters": .12,
            "captureMode": "upper_neck_forward_reverse", "views": views}


class UpperNeckReportTests(unittest.TestCase):
    def test_recovers_relative_angle_and_repeated_target_agreement(self):
        result = UPPER.report(dataset())
        self.assertFalse(result["registrationVerified"])
        self.assertEqual(result["holdCount"], 5)
        self.assertEqual(result["sampleCount"], 15)
        np.testing.assert_allclose([h["qrRelativeCameraRotationDegrees"] for h in result["holds"]], [0, 2.5, 5, 2.5, 0], atol=1e-5)
        np.testing.assert_allclose([h["qrRelativeOpticalXRotationDegrees"] for h in result["holds"]], [0, -2.5, -5, -2.5, 0], atol=1e-5)
        for repeated in result["repeatedTargets"]:
            self.assertLess(repeated["maximumCenterDifferencePixels"], 1e-9)
            self.assertLess(repeated["maximumQRRotationDifferenceDegrees"], 1e-4)
            self.assertLess(repeated["maximumDepthDifferenceMeters"], 1e-9)
        self.assertEqual(result["holds"][2]["protractorPitchDegrees"], 5.)
        self.assertEqual(result["holds"][0]["planes"], [])

    def test_reports_repeat_error_instead_of_adjusting_it(self):
        document = dataset()
        for view in document["views"][-3:]:
            view["cornersPixels"] = (np.array(view["cornersPixels"])+[4., 0.]).tolist()
            view["centerPixel"][0] += 4.
            view["centerDepthMeters"] += .012
        result = UPPER.report(document)
        repeated = next(x for x in result["repeatedTargets"] if x["upperTarget"] == 6000)
        self.assertAlmostEqual(repeated["maximumCenterDifferencePixels"], 4.)
        self.assertAlmostEqual(repeated["maximumDepthDifferenceMeters"], .012)
        self.assertFalse(result["registrationVerified"])

    def test_depth_plane_is_metric_local_and_keeps_model_inclination(self):
        document = dataset()
        view = document["views"][0]
        pose = QR.pose_for_view(view)["targetToCamera"]
        n, t = pose[:3, 2], pose[:3, 3]
        yy, xx = np.indices((720, 1280))
        rays = np.stack(((xx-640)/700, (yy-360)/700, np.ones_like(xx)), axis=-1)
        z = float(n @ t)/np.einsum("ijk,k->ij", rays, n)
        valid = (z >= .15) & (z <= 5)
        depth = np.where(valid, np.rint(np.clip(z, .15, 5)*1000), 0).astype("<u2")
        # Simulate distant outliers and holes without altering the plane fit.
        depth[::17, ::17] = 0
        depth[::19, ::19] = 2200
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            depth.tofile(folder/f"{view['id']}.depth-u16le")
            plane = UPPER.plane_for_view(view, folder)
            self.assertGreater(plane["inlierCount"], 40)
            self.assertLess(plane["orthogonalRMSEMeters"], .001)
            self.assertAlmostEqual(plane["inclinationFromRawBaseHorizontalDegrees"], 40., delta=.15)
            corrected = UPPER.plane_for_view(view, folder, {"downwardPitchDegrees": 15.})
            self.assertAlmostEqual(corrected["inclinationFromDisplayBaseHorizontalDegrees"], 55., delta=.15)
            self.assertNotIn("registrationVerified", plane)
            (folder/f"{view['id']}.depth-u16le").write_bytes(b'broken')
            with self.assertRaisesRegex(ValueError, "size mismatch"):
                UPPER.plane_for_view(view, folder)

    def test_rejects_mixed_axes_stale_sequences_and_wrong_targets(self):
        mutations = [
            lambda d: d["views"][4].update(neckPanDegrees=1.),
            lambda d: d["views"][4].update(lowerTarget=6020),
            lambda d: d["views"][4].update(requestedUpperTarget=6999),
            lambda d: d["views"][4].update(requestedPanDegrees=1.),
            lambda d: d["views"][4].update(sequence=1),
            lambda d: d["views"][4].update(capturedAtMilliseconds=1.),
            lambda d: d["views"][4].update(targetID="ROB:WALL:R01"),
            lambda d: d["views"][4].update(protractorPitchDegrees=float("nan")),
            lambda d: d["views"][4].update(neckUpperTarget=True),
            lambda d: d.update(targetID="other"),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(dataset()); mutate(changed)
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                UPPER.report(changed)

    def test_top_level_protractor_readings_compare_deltas_without_fitting(self):
        document = dataset()
        for view in document["views"]:
            view.pop("protractorPitchDegrees")
        document["protractorReadings"] = [{"stepIndex": i, "pitchDegrees": 8.+angle, "reference": "same level camera bracket"}
                                           for i, angle in enumerate([0., 2.5, 5., 2.5, 0.])]
        result = UPPER.report(document)
        manual_scale = result["angleScaleCandidates"]["protractorPitch"]
        self.assertEqual(manual_scale["status"], "candidate_unverified")
        self.assertAlmostEqual(manual_scale["degreesPerTargetUnit"], 1/30)
        self.assertAlmostEqual(result["angleScaleCandidates"]["qrMinusProtractorDegreesPerTargetUnit"], 0., delta=1e-6)
        for hold in result["holds"]:
            self.assertAlmostEqual(hold["qrVersusProtractorPitchChangeDifferenceDegrees"], 0., delta=1e-5)
        document["protractorReadings"][-1]["reference"] = "different edge"
        self.assertIsNone(UPPER.report(document)["holds"][-1]["protractorPitchChangeDegrees"])
        document["protractorReadings"][-1]["stepIndex"] = 99
        with self.assertRaisesRegex(ValueError, "uncaptured"):
            UPPER.report(document)

    def test_scale_first_visits_fit_known_slope_and_keep_returns_independent(self):
        source = dataset()
        before = UPPER.report(source)["angleScaleCandidates"]["qrPitch"]
        self.assertEqual(before["status"], "candidate_unverified")
        self.assertEqual(before["trainingHoldIndices"], [0, 1, 2])
        self.assertEqual(before["heldOutReturnHoldIndices"], [3, 4])
        self.assertAlmostEqual(before["degreesPerTargetUnit"], 1/30, delta=1e-6)
        self.assertFalse(before["candidateURDFReady"])
        self.assertFalse(before["nominalPriorIsMeasured"])
        changed = copy.deepcopy(source)
        target = QR.transform(rx(140), [0., .04, .9])
        camera = np.array([[700., 0, 640], [0, 700., 360], [0, 0, 1.]])
        for view in changed["views"][9:]:
            actual_angle = (view["neckUpperTarget"]-6000)/30+1.
            pose = np.linalg.inv(QR.transform(rx(actual_angle), [0., 0., 0.])) @ target
            view["cornersPixels"] = cv2.projectPoints(QR.object_corners(), cv2.Rodrigues(pose[:3, :3])[0],
                                                     pose[:3, 3], camera, np.zeros(5))[0].reshape(4, 2).tolist()
        after = UPPER.report(changed)["angleScaleCandidates"]["qrPitch"]
        self.assertEqual(before["degreesPerTargetUnit"], after["degreesPerTargetUnit"])
        self.assertEqual(before["diagnosticAngleAtReferenceDegrees"], after["diagnosticAngleAtReferenceDegrees"])
        self.assertGreater(after["heldOutReturnRMSEDegrees"], before["heldOutReturnRMSEDegrees"]+.1)

    def test_scale_requires_levels_span_and_independent_returns(self):
        source = dataset()
        source["views"] = source["views"][:9]
        candidate = UPPER.report(source)["angleScaleCandidates"]["qrPitch"]
        self.assertEqual(candidate["status"], "unavailable")
        self.assertEqual(candidate["uniqueTrainingTargetCount"], 3)
        self.assertEqual(candidate["heldOutReturnHoldIndices"], [])
        source = dataset()
        for view in source["views"]:
            view["neckUpperTarget"] = 6000+(view["neckUpperTarget"]-6000)//10
            view["requestedUpperTarget"] = view["neckUpperTarget"]
        candidate = UPPER.report(source)["angleScaleCandidates"]["qrPitch"]
        self.assertEqual(candidate["status"], "unavailable")
        self.assertLess(candidate["targetSpanUnits"], candidate["minimumSpanTargetUnits"])

    def test_cli_rejects_invalid_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary); source = folder/'capture.json'; out = folder/'report.json'
            source.write_text('{"schemaVersion":NaN}')
            process = subprocess.run([sys.executable, str(WORKER), str(source), str(out)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 2)
            self.assertEqual(json.loads(out.read_text())["status"], "rejected")


if __name__ == "__main__":
    unittest.main()
