"""Exercise saved actual-pattern images, metric pair geometry and native depth."""
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("belly_diagnostic_test",
    ROOT / "Cerebro/Resources/ShadowPlanner/belly_qr_diagnostic.py")
WORKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKER)


def fixture(directory, spacing=.4, depth_bias=.0):
    width, height = 1280, 800
    fx = fy = 1000.; cx = 640.; cy = 400.
    K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1.]])
    R = cv2.Rodrigues(np.array([.35, -.15, .06]))[0] @ np.diag([1., -1., -1.])
    t = np.array([.02, .02, 1.05])
    rv = cv2.Rodrigues(R)[0]
    yy, xx = np.mgrid[:height, :width]
    rays = np.stack(((xx-cx)/fx, (yy-cy)/fy, np.ones_like(xx)), axis=-1)
    n = R[:, 2]
    z = float(np.dot(n, t)) / np.einsum("ijk,k->ij", rays, n)
    native = np.clip(np.round((z+depth_bias)*1000), 0, 65535).astype("<u2")
    gray = np.full((height, width), 255, np.uint8)
    seeds = []
    for target, side in zip(WORKER.IDS, [-1, 1]):
        objects = WORKER.DEPTH.object_corners(.12)+[side*spacing/2, 0, 0]
        corners = cv2.projectPoints(objects, rv, t, K, np.zeros(5))[0].reshape(4, 2)
        template, template_corners = WORKER.REFINE.template(target)
        homography = cv2.getPerspectiveTransform(template_corners, corners.astype(np.float32))
        projected = cv2.warpPerspective(template, homography, (width, height),
                                        flags=cv2.INTER_LINEAR, borderValue=255)
        gray = np.minimum(gray, projected)
        seeds.append({"payload": target, "cornersPixels": (corners+[.25, -.2]).tolist()})
    frames = []
    for index in range(3):
        image_path = directory / f"frame-{index}.png"
        depth_path = directory / f"frame-{index}.depth-u16le"
        cv2.imwrite(str(image_path), gray); native.tofile(depth_path)
        frames.append({"imagePath": image_path.name, "imageSHA256": WORKER.digest(image_path),
            "depthPath": depth_path.name, "depthSHA256": WORKER.digest(depth_path),
            "width": width, "height": height, "intrinsics": [fx, fy, cx, cy],
            "sequence": index+1, "capturedAtMilliseconds": 1_000_000.+index*500,
            "sequenceSource": "synthetic-test-camera", "sourceCameraRole": "belly",
            "rgbOutputUndistorted": True, "depthAlignmentMethod": "synthetic_aligned_native",
            "depthIntrinsics": K.reshape(-1).tolist(), "depthIntrinsicsSource": "synthetic_sdk_depth_transformation",
            "depthSourceSize": [width, height], "depthSourceIntrinsics": K.reshape(-1).tolist(),
            "depthImageTransform": np.eye(3).reshape(-1).tolist(),
            "rgbSourceIntrinsics": K.reshape(-1).tolist(), "rgbImageTransform": np.eye(3).reshape(-1).tolist(),
            "rgbTransformationSize": [width, height], "depthTransformationSize": [width, height],
            "rgbSourceDistortionCoefficients": [.1, -.2, .003, .004],
            "depthSourceDistortionCoefficients": [.05, -.1, .001, .002],
            "rgbSourceDistortionModel": "perspective", "depthSourceDistortionModel": "perspective",
            "depthRGBGeometryCorrespondence": {"status": "matched", "dimensionsMatch": True,
                "intrinsicsMatch": True, "maximumIntrinsicDifferencePixels": 0., "sdkAlignedToRGB": True,
                "sdkEqualTransformationToRGB": True, "depthTransformationValid": True, "rgbTransformationValid": True},
            "detections": copy.deepcopy(seeds)})
    return {"schemaVersion": 1, "kind": "belly_qr_capture", "cameraRole": "belly",
        "captureSessionID": "synthetic-test-only", "captureStreamID": "synthetic-test-stream",
        "markerSizeMeters": .12, "centerSpacingMeters": .4,
        "layout": {"b01IsPrintedLeft": True, "parallelPrintedTop": True}, "frames": frames}, R, t


class BellyQRDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_cli_writes_full_report_and_compact_rejection_summary(self):
        document, _, _ = fixture(self.directory)
        for frame in document["frames"]:
            frame["rgbOutputUndistorted"] = False
        source = self.directory / "capture-input.json"
        output = self.directory / "diagnostic.json"
        source.write_text(json.dumps(document))
        command = [sys.executable, "-B", str(ROOT / "Cerebro/Resources/ShadowPlanner/belly_qr_diagnostic.py"),
                   "--input", str(source), "--output", str(output)]
        completed = subprocess.run(command, env=dict(os.environ, PYTHONNOUSERSITE="1"),
                                   capture_output=True, text=True, timeout=20)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        summary = json.loads(completed.stdout)
        self.assertEqual(summary["status"], "diagnostic_incomplete")
        self.assertEqual(summary["acceptedFrameCount"], 0)
        self.assertEqual(len(summary["rejectedFrames"]), 3)
        self.assertTrue(all(set(row) == {"frameIndex", "reason"} for row in summary["rejectedFrames"]))
        report = json.loads(output.read_text())
        self.assertEqual(report["inputSHA256"], WORKER.digest(source))
        self.assertFalse(report["registrationVerified"])
        self.assertFalse(report["armMotionAuthority"])

    def test_printed_patterns_decode_to_the_actual_new_payloads(self):
        for target in WORKER.IDS:
            image, _ = WORKER.REFINE.template(target)
            payload, _, _ = cv2.QRCodeDetector().detectAndDecode(image)
            self.assertEqual(payload, target)

    def test_same_dimensions_without_depth_projection_evidence_stays_unverified(self):
        document, _, _ = fixture(self.directory)
        for frame in document["frames"]:
            del frame["depthRGBGeometryCorrespondence"]
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["consistentPairFrameCount"], 3)
        self.assertFalse(result["rawDepthAgreementAcrossConsistentFrames"])
        for row in result["frames"]:
            self.assertEqual(row["depthRGBGeometry"]["status"], "missing_evidence")
            self.assertFalse(row["depthRGBGeometry"]["pixelCorrespondenceSupported"])
            for target in row["targets"]:
                self.assertTrue(target["rawDepth"]["numericResidualsWithinDiagnosticLimits"])
                self.assertFalse(target["rawDepth"]["withinDiagnosticLimits"])

    def test_sdk_mismatch_and_numeric_crop_mismatch_cannot_claim_correspondence(self):
        document, _, _ = fixture(self.directory)
        first, second, third = document["frames"]
        first["depthRGBGeometryCorrespondence"]["sdkAlignedToRGB"] = False
        first["depthRGBGeometryCorrespondence"]["status"] = "mismatched"
        second["depthImageTransform"][2] = 5.
        third["depthTransformationSize"][1] -= 80
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["consistentPairFrameCount"], 3)
        self.assertFalse(result["rawDepthAgreementAcrossConsistentFrames"])
        rows = result["frames"]
        self.assertFalse(rows[0]["depthRGBGeometry"]["SDKChecks"]["sdkAlignedToRGB"])
        self.assertAlmostEqual(rows[1]["depthRGBGeometry"]["maximumDepthSourceCropDifferencePixels"], 5.)
        self.assertFalse(rows[2]["depthRGBGeometry"]["numericChecks"]["depthTransformationSizeMatchesPixels"])

    def test_invalid_source_crop_is_explicit_and_json_remains_finite(self):
        document, _, _ = fixture(self.directory)
        frame = document["frames"][0]
        frame["depthImageTransform"] = [1., 0., 0., 0., 1., 0., 1/640, 0., -1.]
        report = WORKER._depth_pixel_geometry(frame)
        self.assertEqual(report["status"], "invalid_evidence")
        self.assertFalse(report["pixelCorrespondenceSupported"])
        json.dumps(report, allow_nan=False)

    def test_empty_and_partial_native_seeds_use_backmapped_multiscale_fallback(self):
        document, _, t = fixture(self.directory)
        document["frames"] = document["frames"][:1]
        native = copy.deepcopy(document["frames"][0]["detections"])
        for seeds in [[], native[:1]]:
            document["frames"][0]["detections"] = seeds
            result = WORKER.diagnose(document, self.directory)
            self.assertEqual(result["acceptedFrameCount"], 1, result["rejectedFrames"])
            row = result["frames"][0]
            self.assertEqual({target["targetID"] for target in row["targets"]}, set(WORKER.IDS))
            pose = np.array(row["boardToCameraColumnMajor"]).reshape(4, 4).T
            np.testing.assert_allclose(pose[:3, 3], t, atol=.002)
            self.assertTrue(row["detectorDiagnostics"]["methods"])

    def test_undecoded_geometry_requires_strict_actual_pattern_identity(self):
        document, _, _ = fixture(self.directory)
        frame = document["frames"][0]
        gray = cv2.imread(str(self.directory/frame["imagePath"]), cv2.IMREAD_GRAYSCALE)
        for seed in frame["detections"]:
            identified, diagnostic = WORKER._identify_undecoded(gray, np.asarray(seed["cornersPixels"]))
            self.assertIsNotNone(identified, diagnostic)
            self.assertEqual(identified["payload"], seed["payload"])
            self.assertGreaterEqual(diagnostic["crossPayloadCorrelationMargin"], WORKER.REFINE.MINIMUM_ORIENTATION_MARGIN)
            accepted = next(row for row in diagnostic["patternAttempts"] if row["targetID"] == seed["payload"])
            self.assertGreaterEqual(accepted["correlation"], WORKER.REFINE.MINIMUM_CORRELATION)

    def test_metric_pair_pose_and_native_depth_without_world_assumptions(self):
        document, R, t = fixture(self.directory)
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["status"], "diagnostic_complete", result["rejectedFrames"])
        self.assertEqual(result["consistentPairFrameCount"], 3)
        self.assertTrue(result["rawDepthAgreementAcrossConsistentFrames"])
        self.assertTrue(all(row["depthRGBGeometry"]["pixelCorrespondenceSupported"] for row in result["frames"]))
        self.assertTrue(all(row["depthRGBGeometry"]["sourceDistortionCoefficientsDescribeSourceSensorNotOutputWarp"] for row in result["frames"]))
        for row in result["frames"]:
            self.assertLess(row["pairTranslationErrorMeters"], .002)
            self.assertLess(row["pairRotationErrorDegrees"], .5)
            pose = np.array(row["boardToCameraColumnMajor"]).reshape(4, 4).T
            np.testing.assert_allclose(pose[:3, 3], t, atol=.001)
            self.assertLess(WORKER._angle(pose[:3, :3], R), .2)
            self.assertLess(row["jointPnP"]["cornerRMSEPixels"], .2)
        self.assertFalse(result["registrationVerified"])
        self.assertFalse(result["calibrationApplied"])
        self.assertFalse(result["armMotionAuthority"])

    def test_unknown_distortion_rejects_rather_than_assuming_zero(self):
        document, _, _ = fixture(self.directory)
        for frame in document["frames"]: del frame["rgbOutputUndistorted"]
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["acceptedFrameCount"], 0)
        self.assertEqual(result["status"], "diagnostic_incomplete")
        self.assertTrue(all("zero distortion cannot be assumed" in row["reason"] for row in result["rejectedFrames"]))

    def test_raw_depth_bias_reported_without_changing_rgb_pose(self):
        document, _, t = fixture(self.directory, depth_bias=.04)
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["consistentPairFrameCount"], 3)
        self.assertFalse(result["rawDepthAgreementAcrossConsistentFrames"])
        for row in result["frames"]:
            pose = np.array(row["boardToCameraColumnMajor"]).reshape(4, 4).T
            np.testing.assert_allclose(pose[:3, 3], t, atol=.001)
            for target in row["targets"]:
                residual = target["rawDepth"]["rawOpticalZMinusPnPPlaneIntersection"]
                self.assertAlmostEqual(residual["medianSignedMeters"], .04, delta=.002)
                self.assertFalse(target["rawDepth"]["correctionFittedOrApplied"])

    def test_wrong_physical_spacing_does_not_get_certified_by_joint_fit(self):
        document, _, _ = fixture(self.directory, spacing=.45)
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["acceptedFrameCount"], 3)
        self.assertEqual(result["consistentPairFrameCount"], 0)
        self.assertTrue(all(row["pairTranslationErrorMeters"] > .04 for row in result["frames"]))

    def test_swapped_seed_payloads_rejected_by_actual_printed_modules(self):
        document, _, _ = fixture(self.directory)
        for frame in document["frames"]:
            frame["detections"][0]["payload"], frame["detections"][1]["payload"] = WORKER.IDS[::-1]
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["acceptedFrameCount"], 0)
        self.assertEqual(len(result["rejectedFrames"]), 3)

    def test_hash_tampering_and_cross_camera_inputs_rejected(self):
        document, _, _ = fixture(self.directory)
        document["frames"][0]["depthSHA256"] = "0"*64
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(len(result["rejectedFrames"]), 1)
        self.assertIn("hash", result["rejectedFrames"][0]["reason"])
        document["cameraRole"] = "face"
        with self.assertRaisesRegex(ValueError, "face/neck"):
            WORKER.diagnose(document, self.directory)

    def test_missing_native_sequence_clock_or_stream_is_explicitly_rejected(self):
        document, _, _ = fixture(self.directory)
        document["frames"][0]["capturedAtMilliseconds"] = None
        document["frames"][1]["sequence"] = None
        document["frames"][2]["captureStreamID"] = "another-camera-stream"
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["acceptedFrameCount"], 0)
        self.assertEqual(len(result["rejectedFrames"]), 3)
        del document["captureStreamID"]
        result = WORKER.diagnose(document, self.directory)
        self.assertTrue(all("identity is missing" in row["reason"] for row in result["rejectedFrames"]))


if __name__ == "__main__":
    unittest.main()
