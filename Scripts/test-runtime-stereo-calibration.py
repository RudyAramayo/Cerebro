#!/usr/bin/env python3
"""CPU-only runtime calibration tests. Never construct Device or Pipeline."""
import sys
sys.dont_write_bytecode = True
import contextlib
from datetime import timedelta
import hashlib
import importlib.util
import io
import json
import math
import pathlib
import tempfile
import unittest
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runtime_stereo_worker_fixture", ROOT / "Cerebro/Webcam_color.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
try:
    import depthai as dai
except ImportError:
    dai = None


def rotation_z(angle):
    return [[math.cos(angle), -math.sin(angle), 0.], [math.sin(angle), math.cos(angle), 0.], [0., 0., 1.]]


def synthetic_calibrations():
    """Invented optics/identity; no robot EEPROM or room capture is embedded."""
    handler = dai.CalibrationHandler()
    identity = rotation_z(0)
    for socket in (dai.CameraBoardSocket.CAM_A, dai.CameraBoardSocket.CAM_B, dai.CameraBoardSocket.CAM_C):
        handler.setCameraIntrinsics(socket, [[500., 0., 320.], [0., 501., 200.], [0., 0., 1.]], 640, 400)
        handler.setDistortionCoefficients(socket, [0.] * 14)
    handler.setLensPosition(dai.CameraBoardSocket.CAM_A, 124)
    handler.setCameraExtrinsics(dai.CameraBoardSocket.CAM_B, dai.CameraBoardSocket.CAM_C, identity, [-7.5, 0., 0.], [-7.5, 0., 0.])
    handler.setCameraExtrinsics(dai.CameraBoardSocket.CAM_C, dai.CameraBoardSocket.CAM_A, identity, [3.75, 0., 0.], [3.75, 0., 0.])
    handler.setStereoLeft(dai.CameraBoardSocket.CAM_B, identity)
    handler.setStereoRight(dai.CameraBoardSocket.CAM_C, identity)
    factory = handler.eepromToJson()
    clone = dai.CalibrationHandler.fromJson(factory, validateExtrinsics=True)
    r2, raw = rotation_z(.001), rotation_z(.002)
    clone.setCameraExtrinsics(dai.CameraBoardSocket.CAM_B, dai.CameraBoardSocket.CAM_C, raw,
        [-7.55 * math.cos(.001), 7.55 * math.sin(.001), 0.], [-7.5, 0., 0.])
    clone.setStereoLeft(dai.CameraBoardSocket.CAM_B, rotation_z(.003))
    clone.setStereoRight(dai.CameraBoardSocket.CAM_C, r2)
    return handler, factory, clone.eepromToJson()


class FakeDevice:
    def __init__(self, factory):
        self.factory = factory
        self.effective = factory
        self.calls = []
        self.closed = False
        self.restore_failure = False

    def getMxId(self): return "CPU-FIXTURE-DEVICE"
    def getPlatform(self): return dai.Platform.RVC2
    def getCalibration(self):
        self.calls.append("read_effective")
        if self.closed: raise RuntimeError("device already closed")
        return self.effective
    def setCalibration(self, value):
        self.calls.append("restore")
        if self.closed or self.restore_failure: raise RuntimeError("synthetic restore failure")
        self.effective = value
    def readCalibration2(self):
        self.calls.append("read_EEPROM")
        return self.factory


class FakePipeline:
    def __init__(self, device, partial_apply_failure=False):
        self.device = device
        self.partial_apply_failure = partial_apply_failure
        self.policies = {"useHomographyRectification": False, "disparityToDepthUseSpecTranslation": False,
                         "rectificationUseSpecTranslation": False, "depthAlignmentUseSpecTranslation": False}
    def __enter__(self): return self
    def __exit__(self, *_): self.device.calls.append("close"); self.device.closed = True
    def setCalibrationData(self, value):
        self.device.calls.append("apply")
        self.device.effective = value
        if self.partial_apply_failure: raise RuntimeError("synthetic partial apply")
    def getAutoCalibrationMode(self): return dai.Pipeline.AutoCalibrationMode.OFF
    def serializeToJson(self, _): return {"pipeline": {"nodes": [[7, {"properties": self.policies}]]}}


@unittest.skipIf(dai is None, "DepthAI required for actual CPU CalibrationHandler clone coverage")
class RuntimeStereoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="runtime-stereo-CPU-")
        self.directory = pathlib.Path(self.temp.name)
        self.factory_handler, self.factory, self.requested = synthetic_calibrations()
        worker.RUNTIME_STEREO_PROFILE_CACHE.clear()
        self.mode = dai.StereoDepthConfig(); self.mode.setSubpixel(True)
        self.stereo = SimpleNamespace(initialConfig=self.mode)
        self.logs = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.logs); self.redirect.__enter__()
        self.loaded = self.make_profile()

    def tearDown(self):
        self.redirect.__exit__(None, None, None)
        self.temp.cleanup()

    def write(self, name, value):
        path = self.directory / name
        path.write_bytes(worker.calibration_json_bytes(value))
        return str(path), hashlib.sha256(path.read_bytes()).hexdigest()

    def make_profile(self):
        requested_path, requested_hash = self.write("requested.json", self.requested)
        proof_path, proof_hash = self.write("commissioning.json", {"armMotionAuthority": False,
            "limitations": "synthetic CPU fixture, not a metric or registration proof"})
        profile = {"schemaVersion": 1, "kind": "runtime_stereo_calibration_profile", "cameraRole": "face",
            "actualDeviceMXID": "CPU-FIXTURE-DEVICE", "platform": "RVC2", "sdkVersion": "3.8.0",
            "factoryEEPROMSHA256": hashlib.sha256(worker.calibration_json_bytes(self.factory)).hexdigest(),
            "requestedCalibrationPath": requested_path, "requestedCalibrationSHA256": requested_hash,
            "requestedCalibrationSemanticSHA256": worker.calibration_semantic_sha256(self.requested),
            "candidateSHA256": "a" * 64, "validationEvidencePath": proof_path, "validationEvidenceSHA256": proof_hash}
        path, sha = self.write("profile.json", profile)
        self.pointer_path, _ = self.write("face-active.json", {"schemaVersion": 1,
            "kind": "runtime_stereo_calibration_activation", "cameraRole": "face", "profilePath": path, "profileSHA256": sha})
        return worker.load_runtime_stereo_profile("face", self.pointer_path)

    def test_actual_sdk_clone_preserves_every_unrelated_field_and_units(self):
        clone, changes = worker.clone_runtime_calibration(self.factory, self.requested, dai)
        self.assertLessEqual(len(changes), 30)
        before, after = map(worker.calibration_semantic_value, (self.factory, clone.eepromToJson()))
        for socket in ("0", "2"):
            self.assertEqual(before["cameraData"][socket], after["cameraData"][socket])
        self.assertEqual(after, worker.calibration_semantic_value(self.requested))
        meter = clone.getCameraExtrinsics(dai.CameraBoardSocket.CAM_B, dai.CameraBoardSocket.CAM_C, False, dai.LengthUnit.METER)
        self.assertAlmostEqual(meter[0][3], -7.55 * math.cos(.001) / 100, places=7)
        self.assertEqual(after["cameraData"]["1"]["extrinsics"]["specTranslation"], {"x": -7.5, "y": 0., "z": 0.})

    def test_rejects_intrinsic_spec_anchor_board_and_invalid_rotations(self):
        for kind in ("K", "spec", "anchor", "board", "nonproper", "range", "inconsistent_rectification"):
            bad = json.loads(json.dumps(self.requested)); rows = {k: v for k, v in bad["cameraData"]}
            if kind == "K": rows[1]["intrinsicMatrix"][0][0] += 1
            elif kind == "spec": rows[1]["extrinsics"]["specTranslation"]["x"] += .1
            elif kind == "anchor": rows[2]["extrinsics"]["translation"]["x"] += .1
            elif kind == "board": bad["boardName"] = "modified"
            elif kind == "nonproper": rows[1]["extrinsics"]["rotationMatrix"][0][0] = -1
            elif kind == "range": rows[1]["extrinsics"]["translation"]["x"] -= 1
            else: bad["stereoRectificationData"]["rectifiedRotationRight"] = rotation_z(.02)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                worker.clone_runtime_calibration(self.factory, bad, dai)

    def test_activation_is_frozen_until_worker_restart(self):
        pathlib.Path(self.pointer_path).write_text("invalid")
        self.assertIs(worker.load_runtime_stereo_profile("face", self.pointer_path), self.loaded)
        worker.RUNTIME_STEREO_PROFILE_CACHE.clear()
        self.assertEqual(worker.load_runtime_stereo_profile("face", self.pointer_path)["status"], "invalid")

    def test_bad_pinned_profile_or_evidence_uses_factory(self):
        for file in ("profile.json", "commissioning.json", "requested.json"):
            with self.subTest(file=file):
                old = (self.directory/file).read_bytes(); (self.directory/file).write_bytes(old+b" ")
                worker.RUNTIME_STEREO_PROFILE_CACHE.clear()
                self.assertEqual(worker.load_runtime_stereo_profile("face", self.pointer_path)["status"], "invalid")
                (self.directory/file).write_bytes(old)
        worker.RUNTIME_STEREO_PROFILE_CACHE.clear()
        self.assertEqual(worker.load_runtime_stereo_profile("face", str(self.directory/"absent"))["status"], "missing")

    def test_applied_identity_and_restore_before_pipeline_close(self):
        device = FakeDevice(self.factory_handler)
        with FakePipeline(device) as pipeline:
            with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, self.loaded) as state:
                provenance = worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
                self.assertEqual(provenance["profileSHA256"], self.loaded["profileSHA256"])
                self.assertEqual(provenance["candidateSHA256"], "a"*64)
                self.assertEqual(provenance["effectiveRuntimeCalibrationSHA256"], worker.calibration_semantic_sha256(self.requested))
                self.assertFalse(device.closed)
        self.assertLess(device.calls.index("restore"), device.calls.index("close"))
        self.assertEqual(worker.calibration_semantic_value(device.effective.eepromToJson()), worker.calibration_semantic_value(self.factory))

    def test_wrong_device_falls_back_before_apply_with_factory_provenance(self):
        device = FakeDevice(self.factory_handler); device.getMxId = lambda: "OTHER-DEVICE"
        with FakePipeline(device) as pipeline:
            with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, self.loaded) as state:
                self.assertFalse(state["attempted"])
                provenance = worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
                self.assertIsNone(provenance["candidateSHA256"]); self.assertIsNone(provenance["profileSHA256"])
                self.assertEqual(provenance["actualDeviceMXID"], "OTHER-DEVICE")
        self.assertNotIn("apply", device.calls); self.assertNotIn("restore", device.calls)
        self.assertIn("FACTORY", self.logs.getvalue())

    def test_partial_apply_failure_restores_and_never_yields(self):
        device = FakeDevice(self.factory_handler)
        with self.assertRaisesRegex(RuntimeError, "partial apply"):
            with FakePipeline(device, partial_apply_failure=True) as pipeline:
                with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, self.loaded):
                    self.fail("partially failed apply yielded a streaming context")
        self.assertLess(device.calls.index("restore"), device.calls.index("close"))

    def test_foreign_prior_runtime_is_preserved_and_not_labelled_factory(self):
        device = FakeDevice(self.factory_handler)
        device.effective = dai.CalibrationHandler.fromJson(self.requested, validateExtrinsics=True)
        with FakePipeline(device) as pipeline:
            with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, self.loaded) as state:
                self.assertFalse(state["attempted"])
                provenance = worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
                self.assertEqual(state["calibrationSource"], "OBSERVED_EXISTING_RUNTIME")
                self.assertIsNone(provenance["profileSHA256"])
                self.assertEqual(provenance["effectiveRuntimeCalibrationSHA256"], worker.calibration_semantic_sha256(self.requested))
        self.assertNotIn("restore", device.calls)
        self.assertNotIn("apply", device.calls)

    def test_readback_mismatch_aborts_and_restores(self):
        device = FakeDevice(self.factory_handler)
        with self.assertRaisesRegex(RuntimeError, "readback differs"):
            with FakePipeline(device) as pipeline:
                with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, self.loaded) as state:
                    device.effective = self.factory_handler
                    worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
        self.assertIn("restore", device.calls)

    def test_restore_failure_is_not_success_and_still_checks_eeprom(self):
        device = FakeDevice(self.factory_handler)
        with self.assertRaisesRegex(RuntimeError, "restoration failed"):
            with FakePipeline(device) as pipeline:
                with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, self.loaded):
                    device.restore_failure = True
        self.assertIn("read_EEPROM", device.calls)
        self.assertLess(device.calls.index("restore"), device.calls.index("close"))

    def test_factory_metadata_and_policy_change_identity(self):
        device = FakeDevice(self.factory_handler)
        loaded = {"profile": None, "status": "missing", "detail": "no profile; factory"}
        with FakePipeline(device) as pipeline:
            with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, loaded) as state:
                first = worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
                self.assertIsNone(first["profileSHA256"])
                pipeline.policies["rectificationUseSpecTranslation"] = None
                second = worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
                self.assertNotEqual(worker.runtime_calibration_identity(first), worker.runtime_calibration_identity(second))
                expected = "\n".join(["runtime-camera-calibration-v1", first["actualDeviceMXID"], "face", "3.8.0",
                    first["factoryEEPROMSHA256"], first["effectiveRuntimeCalibrationSHA256"], first["stereoPolicySHA256"], "-", "-"])
                self.assertEqual(worker.runtime_calibration_identity(first), hashlib.sha256(expected.encode()).hexdigest())
                bad = dict(first); bad["candidateSHA256"] = "b" * 64
                with self.assertRaises(ValueError): worker.runtime_calibration_identity(bad)

    def test_required_host_policy_and_auto_off_cannot_be_inferred(self):
        device = FakeDevice(self.factory_handler)
        with self.assertRaisesRegex(RuntimeError, "policies were not confirmed"):
            with FakePipeline(device) as pipeline:
                with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, self.loaded) as state:
                    pipeline.policies["rectificationUseSpecTranslation"] = None
                    worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
        self.assertIn("restore", device.calls)
        pipeline = FakePipeline(FakeDevice(self.factory_handler)); pipeline.getAutoCalibrationMode = lambda: None
        with self.assertRaisesRegex(RuntimeError, "OFF"):
            worker.runtime_stereo_policy(pipeline, self.stereo, dai, False)

    def test_packet_identity_and_payloads_without_per_frame_device_queries(self):
        device = FakeDevice(self.factory_handler)
        loaded = {"profile": None, "status": "missing", "detail": "factory"}
        with FakePipeline(device) as pipeline:
            with worker.runtime_stereo_calibration_session(device, pipeline, dai, "face", self.factory_handler, loaded) as state:
                provenance = worker.finalize_runtime_calibration(state, device, pipeline, self.stereo, dai, "face")
                calls = list(device.calls)
                rgb = SimpleNamespace(getWidth=lambda: 2, getHeight=lambda: 1,
                    getData=lambda: bytes(range(6)), getSequenceNum=lambda: 42,
                    getTimestamp=lambda: timedelta(seconds=1))
                array = SimpleNamespace(size=2, astype=lambda *a, **kw: array,
                    tobytes=lambda **kw: bytes((1, 0, 2, 0)))
                depth = SimpleNamespace(getWidth=lambda: 2, getHeight=lambda: 1, getFrame=lambda: array)
                mono = SimpleNamespace(getWidth=lambda: 2, getHeight=lambda: 1, getData=lambda: bytes((7, 8)))
                encoded, rgb_bytes, depth_bytes, *_ = worker.frame_payload(rgb, depth, mono, mono,
                    [100., 0., 1., 0., 101., .5, 0., 0., 1.], runtime_calibration=provenance)
                header = json.loads(encoded)
                self.assertEqual(header["runtime_calibration"], provenance)
                self.assertEqual(header["runtime_calibration_identity"], worker.runtime_calibration_identity(provenance))
                self.assertEqual(rgb_bytes, bytes(range(6))); self.assertEqual(depth_bytes, bytes((1, 0, 2, 0)))
                self.assertEqual(device.calls, calls)
                bad = dict(provenance); bad["schemaVersion"] = True
                with self.assertRaises(ValueError):
                    worker.frame_payload(rgb, depth, mono, mono, [100., 0., 1., 0., 101., .5, 0., 0., 1.], runtime_calibration=bad)


if __name__ == "__main__":
    unittest.main()
