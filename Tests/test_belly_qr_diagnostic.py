"""Exercise saved actual-pattern images, metric pair geometry and native depth."""
import copy
import importlib.util
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

    def test_printed_patterns_decode_to_the_actual_new_payloads(self):
        for target in WORKER.IDS:
            image, _ = WORKER.REFINE.template(target)
            payload, _, _ = cv2.QRCodeDetector().detectAndDecode(image)
            self.assertEqual(payload, target)

    def test_metric_pair_pose_and_native_depth_without_world_assumptions(self):
        document, R, t = fixture(self.directory)
        result = WORKER.diagnose(document, self.directory)
        self.assertEqual(result["status"], "diagnostic_complete", result["rejectedFrames"])
        self.assertEqual(result["consistentPairFrameCount"], 3)
        self.assertTrue(result["rawDepthAgreementAcrossConsistentFrames"])
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
