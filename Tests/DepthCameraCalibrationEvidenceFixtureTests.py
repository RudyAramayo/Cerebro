#!/usr/bin/env python3
"""Read-only calibration export fixtures; no SDK/device or app-bundle imports."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from DepthCameraIPCFixtureTests import load_service


class Calibration:
    def __init__(self):
        self.calls = []
        self.mutation_attempts = []
        self.export = {"boardName": "fixture", "cameraData": {"b": {"distortionCoeff": [.1, -.02]}},
                       "stereoUseSpecTranslation": False}

    def __getattr__(self, name):
        if name.startswith(("set", "flash", "write")):
            self.mutation_attempts.append(name)
            raise AssertionError("Diagnostic attempted device calibration mutation")
        raise AttributeError(name)

    def eepromToJson(self): return self.export
    def getEepromData(self):
        return SimpleNamespace(boardName="fixture", boardRev="R1", productName="fake", deviceName="fake",
                               stereoEnableDistortionCorrection=True, stereoUseSpecTranslation=False)
    def getDefaultIntrinsics(self, socket): return ([[500., 0, 320], [0, 501., 200], [0, 0, 1.]], 640, 400)
    def getCameraIntrinsics(self, socket, width, height, keepAspectRatio):
        self.calls.append(("intrinsics", socket, width, height, keepAspectRatio))
        return [[500., 0, width/2], [0, 501., height/2], [0, 0, 1.]]
    def getDistortionCoefficients(self, socket): return [.1, -.02, .001, -.002, .003]
    def getDistortionModel(self, socket): return "CameraModel.Perspective"
    def getLensPosition(self, socket): return 0
    def getFov(self, socket, use_spec):
        self.calls.append(("fov", socket, use_spec)); return 73. if use_spec else 71.
    def getBaselineDistance(self, source, destination, use_spec, unit):
        assert unit == "explicit-meter"; self.calls.append(("baseline", source, destination, use_spec, unit))
        return .077 if use_spec else .075
    def getCameraTranslationVector(self, source, destination, use_spec, unit):
        assert unit == "explicit-meter"; return [-.077 if use_spec else -.075, .001, .002]
    def getCameraExtrinsics(self, source, destination, use_spec, unit):
        assert unit == "explicit-meter"
        return [[1., 0, 0, -.077 if use_spec else -.075], [0, 1., 0, .001], [0, 0, 1., .002], [0, 0, 0, 1.]]
    def getStereoLeftCameraId(self): return "b"
    def getStereoRightCameraId(self): return "c"
    def getStereoLeftRectificationRotation(self): return [[1., 0, 0], [0, 1., 0], [0, 0, 1.]]
    def getStereoRightRectificationRotation(self): return self.getStereoLeftRectificationRotation()


class Device:
    def getMxId(self): return "ACTUAL-DEVICE"
    def getConnectedCameraFeatures(self):
        return [SimpleNamespace(socket="a", supportedTypes=["COLOR"])]


class CalibrationEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rob-calibration-export-")
        self.directory = Path(self.temporary.name)/"DepthCamera"
        self.service = load_service(name="calibration_evidence_fixture")
        self.calibration = Calibration()
        self.sdk = SimpleNamespace(__version__="3.8.0", CameraBoardSocket=SimpleNamespace(CAM_A="a", CAM_B="b", CAM_C="c"),
            CameraSensorType=SimpleNamespace(COLOR="COLOR"), LengthUnit=SimpleNamespace(METER="explicit-meter"))
        self.patch = patch.object(self.service, "ir_status_directory", return_value=str(self.directory))
        self.patch.start()

    def tearDown(self):
        self.patch.stop(); self.temporary.cleanup()

    def capture(self, **kwargs):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = self.service.write_calibration_evidence(Device(), self.calibration, self.sdk,
                kwargs.pop("role", "face"), (640, 400), (640, 400), **kwargs)
        return result, stdout.getvalue()

    def test_full_export_exact_units_source_association_and_immutable_history(self):
        first, log = self.capture(requested_mxid="REQUESTED-DIFFERENT", requested_stereo_mode="near_field")
        path = Path(first["evidencePath"]); original = path.read_bytes(); evidence = json.loads(original)
        self.assertEqual(evidence["eepromExport"]["value"], self.calibration.export)
        self.assertEqual(evidence["actualDeviceMXID"], "ACTUAL-DEVICE")
        self.assertEqual(evidence["requestedDeviceMXID"], "REQUESTED-DIFFERENT")
        self.assertEqual(evidence["cameraServiceSourceSHA256"], self.service.RUNNING_SERVICE_SOURCE_SHA256)
        self.assertEqual(evidence["processID"], os.getpid())
        self.assertEqual(first["evidenceSHA256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(evidence["requestedPipeline"]["rectificationPolicy"], "explicit_mesh")
        for key in ("disparityToDepthUseSpecTranslation", "depthAlignmentUseSpecTranslation", "rectificationUseSpecTranslation"):
            self.assertEqual(evidence["requestedPipeline"][key], "UNSET")
        self.assertFalse(evidence["requestedPipeline"]["resolvedStrategyObserved"])
        self.assertFalse(evidence["calibrationWrittenToDevice"] or evidence["metricAccuracyVerified"] or evidence["registrationVerified"])
        for pair in evidence["cameraPairs"]:
            self.assertEqual(pair["translationUnit"], "meter")
            self.assertEqual(pair["calibrated"]["baselineDistance"]["value"], .075)
            self.assertEqual(pair["specification"]["baselineDistance"]["value"], .077)
            self.assertFalse(pair["calibrated"]["useSpecTranslation"])
            self.assertEqual(pair["calibrated"]["translationVector"]["value"], [-.075, .001, .002])
        for camera in evidence["cameras"]:
            self.assertEqual(camera["sourceDistortionCoefficients"]["value"], [.1, -.02, .001, -.002, .003])
            self.assertEqual(camera["calibratedFovDegrees"]["value"], 71.)
            self.assertEqual(camera["specificationFovDegrees"]["value"], 73.)
        second, _ = self.capture()
        self.assertNotEqual(first["evidencePath"], second["evidencePath"])
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(json.loads((self.directory/"face-calibration-latest.json").read_text()), second)
        self.assertTrue(all((p.stat().st_mode & 0o777) == 0o600 for p in self.directory.rglob("*.json")))
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse(self.calibration.mutation_attempts)
        self.assertIn("eeprom_export=observed", log)

    def test_missing_and_failed_sdk_fields_are_explicit_without_fabricating_values(self):
        self.calibration.eepromToJson = None
        self.calibration.getFov = lambda *args: (_ for _ in ()).throw(RuntimeError("missing calibration"))
        self.sdk.LengthUnit = SimpleNamespace()
        pointer, _ = self.capture(role="belly")
        evidence = json.loads(Path(pointer["evidencePath"]).read_text())
        self.assertEqual(evidence["eepromExport"]["status"], "unavailable")
        self.assertEqual(evidence["cameras"][1]["calibratedFovDegrees"]["status"], "error")
        self.assertNotIn("value", evidence["cameras"][1]["calibratedFovDegrees"])
        self.assertTrue(all(pair["status"] == "unavailable" for pair in evidence["cameraPairs"]))

    def test_atomic_pointer_failure_is_nonfatal_and_preserves_previous_evidence(self):
        previous, _ = self.capture()
        with patch.object(self.service.os, "replace", side_effect=OSError("read only fixture")):
            result, log = self.capture()
        self.assertIsNone(result)
        self.assertIn("Calibration evidence could not be saved", log)
        self.assertEqual(json.loads((self.directory/"face-calibration-latest.json").read_text()), previous)
        self.assertFalse(list(self.directory.glob(".face-calibration-latest-*")))


if __name__ == "__main__":
    unittest.main()
