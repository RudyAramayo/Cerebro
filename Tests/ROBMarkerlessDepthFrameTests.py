"""Exercise production depth parsing with camera runtime provenance, without hardware."""
import base64
import copy
import hashlib
import os
from pathlib import Path
import sys
import time
from types import SimpleNamespace
import unittest

os.environ["OPENBLAS_NUM_THREADS"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Cerebro/Resources/ShadowPlanner"))
import numpy as np
from markerless import MarkerlessEstimator


class DepthFrameTests(unittest.TestCase):
    def setUp(self):
        self.e = MarkerlessEstimator(SimpleNamespace(clearance=SimpleNamespace(surfaces=[]), q0=np.zeros(0)))

    def frame(self, sequence=1, runtime=True):
        frame = dict(camera="face", streamID="capture-one", sequence=sequence, timestampNanoseconds=sequence,
                     capturedAtMilliseconds=time.time() * 1000, width=20, height=20,
                     intrinsics=[20, 20, 10, 10],
                     depth=base64.b64encode(np.full((20, 20), 900, dtype="<u2").tobytes()).decode())
        if runtime:
            frame["runtimeCalibration"] = dict(schemaVersion=1, actualDeviceMXID="FRAME-FIXTURE", cameraRole="face",
                sdkVersion="3.8.0", factoryEEPROMSHA256="a" * 64, effectiveRuntimeCalibrationSHA256="b" * 64,
                stereoPolicySHA256="c" * 64, candidateSHA256=None, profileSHA256=None)
            self.sign(frame)
        return frame

    @staticmethod
    def sign(frame):
        runtime = frame["runtimeCalibration"]
        ordered = [runtime[key] or "-" for key in ("actualDeviceMXID", "cameraRole", "sdkVersion",
            "factoryEEPROMSHA256", "effectiveRuntimeCalibrationSHA256", "stereoPolicySHA256", "candidateSHA256", "profileSHA256")]
        frame["runtimeCalibrationIdentity"] = hashlib.sha256("\n".join(["runtime-camera-calibration-v1"] + ordered).encode()).hexdigest()

    def test_optional_provenance_preserves_depth_and_original_capture(self):
        for runtime in (False, True):
            frame = self.frame(runtime=runtime)
            frame["streamID"] = str(runtime)
            original = copy.deepcopy(frame)
            cloud, depth, intrinsics = self.e.cloud(frame)
            self.assertEqual(frame, original)
            self.assertEqual(cloud.shape, (324, 3))
            np.testing.assert_allclose(depth, .9)
            np.testing.assert_equal(intrinsics, [20, 20, 10, 10])

    def test_incomplete_unknown_or_corrupt_provenance_rejected(self):
        variants = []
        for key in ("runtimeCalibration", "runtimeCalibrationIdentity", "depth"):
            frame = self.frame(); del frame[key]; variants.append(frame)
        frame = self.frame(); frame["commandedYaw"] = 1.5; variants.append(frame)
        for value in (None, {}, "invalid"):
            frame = self.frame(); frame["runtimeCalibration"] = value; variants.append(frame)
        for key, value in (("cameraRole", "belly"), ("schemaVersion", True), ("sdkVersion", "bad\nvalue"),
                           ("factoryEEPROMSHA256", "invalid"), ("candidateSHA256", "d" * 64)):
            frame = self.frame(); frame["runtimeCalibration"][key] = value; variants.append(frame)
        frame = self.frame(); frame["runtimeCalibrationIdentity"] = "0" * 64; variants.append(frame)
        for frame in variants:
            with self.subTest(frame=frame), self.assertRaises(ValueError):
                self.e.cloud(frame)

    def test_calibration_change_requires_new_stream_and_replay_still_rejected(self):
        first = self.frame(); self.e.cloud(first)
        with self.assertRaisesRegex(ValueError, "Repeated"):
            self.e.cloud(first)
        changed = self.frame(2)
        changed["runtimeCalibration"]["stereoPolicySHA256"] = "d" * 64
        self.sign(changed)
        with self.assertRaisesRegex(ValueError, "new capture stream"):
            self.e.cloud(changed)
        changed["streamID"] = "capture-two"
        self.e.cloud(changed)
        legacy = self.frame(3, runtime=False)
        with self.assertRaisesRegex(ValueError, "new capture stream"):
            self.e.cloud(legacy)

    def test_provenance_does_not_freshen_old_pixels_or_fill_missing_depth(self):
        frame = self.frame(); frame["capturedAtMilliseconds"] -= 2000
        with self.assertRaisesRegex(ValueError, "Stale"):
            self.e.cloud(frame)
        frame = self.frame(); frame["depth"] = base64.b64encode(bytes(800)).decode()
        with self.assertRaisesRegex(ValueError, "Insufficient"):
            self.e.cloud(frame)


if __name__ == "__main__":
    unittest.main()
