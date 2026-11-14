#!/usr/bin/env python3
"""Read-only synchronized-frame evidence, without a camera or SDK dependency."""
from datetime import timedelta
import json
from types import SimpleNamespace
import unittest

from DepthCameraIPCFixtureTests import (FakeDepthFrame, FakeMonoFrame, FakeRGBFrame,
                                       load_service)

try:
    import depthai as SDK
except ImportError:
    SDK = None


METER = object()


def rigid(x=0):
    return [[1., 0, 0, x], [0, 1., 0, 0], [0, 0, 1., 0], [0, 0, 0, 1.]]


class Extrinsics:
    toCameraSocket = "CameraBoardSocket.CAM_A"
    lengthUnit = "LengthUnit.CENTIMETER"

    def __init__(self, x):
        self.x = x
        self.calls = []

    def getTransformationMatrix(self, spec, unit):
        self.calls.append((spec, unit))
        assert spec is False and unit is METER
        return rigid(self.x)


class Transformation:
    def __init__(self, fx, x):
        self.k = [[fx, 0, 1.], [0, fx+1, .5], [0, 0, 1.]]
        self.extrinsics = Extrinsics(x)
        self.pair_calls = []

    def isValid(self): return True
    def getSize(self): return (2, 1)
    def getSourceSize(self): return (4, 2)
    def getIntrinsicMatrix(self): return self.k
    def getSourceIntrinsicMatrix(self):
        return [[self.k[0][0]*2, 0, 2.], [0, self.k[1][1]*2, 1.], [0, 0, 1.]]
    def getTransformationMatrix(self): return [[.5, 0, 0], [0, .5, 0], [0, 0, 1.]]
    def getDistortionCoefficients(self): return [.12, -.03, .001]
    def getDistortionModel(self): return "CameraModel.Perspective"
    def getExtrinsics(self): return self.extrinsics
    def getExtrinsicsTransformationMatrixTo(self, target, spec, unit):
        self.pair_calls.append((target, spec, unit))
        assert spec is False and unit is METER
        return rigid(self.extrinsics.x - target.extrinsics.x)


class Mono(FakeMonoFrame):
    def __init__(self, fx, x, sequence, values):
        super().__init__(values)
        self.transformation = Transformation(fx, x)
        self.sequence = sequence
    def getTransformation(self): return self.transformation
    def getSequenceNum(self): return self.sequence
    def getTimestamp(self): return timedelta(seconds=3, microseconds=249_000+self.sequence)
    def getTimestampDevice(self): return timedelta(seconds=2, microseconds=249_000+self.sequence)


class RGB(FakeRGBFrame):
    def getExposureTime(self): return timedelta(microseconds=12345)
    def getSensitivity(self): return 640
    def getColorTemperature(self): return 4700


class StereoFrameEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = load_service(name="stereo_frame_evidence_fixture")

    def setUp(self):
        self.left = Mono(10., .030, 141, (7, 8))
        self.right = Mono(13., -.045, 143, (9, 10))

    def evidence(self, meter=METER):
        return self.service.rectified_stereo_frame_evidence(self.left, self.right, meter)

    def test_own_geometry_timestamps_calibrated_meter_units_and_wire_bytes(self):
        packet, rgb, depth, left, right = self.service.frame_payload(
            RGB(), FakeDepthFrame(), self.left, self.right,
            [100., 0, 1., 0, 101., .5, 0, 0, 1.], stereo_length_unit_meter=METER)
        header = json.loads(packet)
        self.assertLess(len(packet), 65_536)
        self.assertEqual((rgb, depth, left, right),
                         (FakeRGBFrame.bytes, bytes((0x34, 0x12, 0xCD, 0xAB)), b"\x07\x08", b"\x09\x0a"))
        self.assertEqual(header["rgb_intrinsics"][0], 100.)
        l, r = header["rectified_left_geometry"], header["rectified_right_geometry"]
        self.assertEqual((l["intrinsics"][0], r["intrinsics"][0]), (10., 13.))
        self.assertEqual(l["sourceIntrinsics"][0], 20.)
        self.assertEqual(l["sourceSize"], [4, 2])
        self.assertEqual(l["imageTransform"], [.5, 0, 0, 0, .5, 0, 0, 0, 1.])
        self.assertEqual(l["sourceDistortionCoefficients"], [.12, -.03, .001])
        self.assertEqual((l["sequence"], r["sequence"]), (141, 143))
        self.assertEqual(l["timestampNanoseconds"], 3_249_141_000)
        self.assertEqual(r["timestampDeviceNanoseconds"], 2_249_143_000)
        self.assertTrue(l["transformationValid"])
        self.assertEqual(l["evidenceErrors"], [])
        ex = l["extrinsicsToCommon"]
        self.assertEqual((ex["sourceLengthUnit"], ex["lengthUnit"]), ("LengthUnit.CENTIMETER", "meter"))
        self.assertEqual(ex["matrix"][3], .030)
        self.assertEqual(ex["evidenceErrors"], [])
        self.assertEqual(self.left.transformation.extrinsics.calls, [(False, METER)])
        pair = header["rectified_left_source_to_right_source"]
        self.assertEqual((pair["from"], pair["to"]), ("left_source_optical", "right_source_optical"))
        self.assertAlmostEqual(pair["matrix"][3], .075)
        self.assertEqual(pair["translationUnit"], "meter")
        self.assertEqual(self.left.transformation.pair_calls, [(self.right.transformation, False, METER)])
        self.assertEqual(header["rgb_frame_exposure_microseconds"], 12345.)
        self.assertEqual(header["rgb_frame_iso"], 640)
        self.assertEqual(header["rgb_frame_color_temperature_kelvin"], 4700)
        self.assertEqual(header["rgb_frame_observation_errors"], [])

    def test_unsupported_optional_getters_keep_packet_and_do_not_borrow_rgb_K(self):
        packet, *_ = self.service.frame_payload(FakeRGBFrame(), FakeDepthFrame(),
            FakeMonoFrame((1, 2)), FakeMonoFrame((3, 4)), [100., 0, 1., 0, 101., .5, 0, 0, 1.])
        header = json.loads(packet)
        self.assertIsNone(header["rectified_left_geometry"]["intrinsics"])
        self.assertIsNone(header["rectified_right_geometry"]["sourceIntrinsics"])
        self.assertIn("getTransformation: getter unavailable", header["rectified_left_geometry"]["evidenceErrors"])
        self.assertIsNone(header["rectified_left_source_to_right_source"]["matrix"])
        self.assertIsNone(header["rgb_frame_exposure_microseconds"])
        self.assertIsNone(header["rgb_frame_iso"])
        self.assertEqual(len(header["rgb_frame_observation_errors"]), 3)

    def test_no_explicit_meter_unit_never_uses_sdk_centimeter_default(self):
        evidence = self.evidence(meter=None)
        self.assertEqual(self.left.transformation.extrinsics.calls, [])
        self.assertEqual(self.left.transformation.pair_calls, [])
        ex = evidence["rectified_left_geometry"]["extrinsicsToCommon"]
        self.assertIsNone(ex["matrix"])
        self.assertIn("explicit SDK meter unit unavailable", ex["evidenceErrors"][0])
        self.assertIsNone(evidence["rectified_left_source_to_right_source"]["matrix"])

    def test_nonfinite_throwing_or_invalid_observations_are_explicit_and_nonfatal(self):
        transform = self.left.transformation
        transform.getIntrinsicMatrix = lambda: [[float("nan"), 0, 1], [0, 11, .5], [0, 0, 1]]
        transform.getTransformationMatrix = lambda: [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        transform.getDistortionCoefficients = lambda: [float("inf")]
        transform.extrinsics.getTransformationMatrix = lambda *args: [[2, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
        transform.getExtrinsicsTransformationMatrixTo = lambda *args: (_ for _ in ()).throw(RuntimeError("SDK no shared camera"))
        evidence = self.evidence()
        l = evidence["rectified_left_geometry"]
        for key in ("intrinsics", "imageTransform", "sourceDistortionCoefficients"):
            self.assertIsNone(l[key])
        self.assertEqual(l["sourceIntrinsics"][0], 20.)
        self.assertIsNone(l["extrinsicsToCommon"]["matrix"])
        self.assertIn("orthonormal", l["extrinsicsToCommon"]["evidenceErrors"][0])
        self.assertIn("SDK no shared camera", evidence["rectified_left_source_to_right_source"]["evidenceErrors"][0])
        json.dumps(evidence, allow_nan=False)
        rgb = SimpleNamespace(getExposureTime=lambda: float("nan"), getSensitivity=lambda: float("inf"), getColorTemperature=lambda: True)
        readback = self.service.rgb_frame_readback(rgb)
        self.assertEqual(len(readback["rgb_frame_observation_errors"]), 3)
        self.assertTrue(all(readback[key] is None for key in ("rgb_frame_exposure_microseconds", "rgb_frame_iso", "rgb_frame_color_temperature_kelvin")))
        json.dumps(readback, allow_nan=False)

    def test_invalidity_and_inconsistent_crop_are_reported_without_replacing_actual_values(self):
        self.left.transformation.isValid = lambda: False
        self.left.transformation.getSize = lambda: (4, 2)
        self.left.transformation.getTransformationMatrix = lambda: [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        l = self.evidence()["rectified_left_geometry"]
        self.assertFalse(l["transformationValid"])
        self.assertEqual(l["transformationSize"], [4, 2])
        self.assertEqual(l["intrinsics"][0], 10.)
        self.assertTrue(any("SDK reports an invalid" in e for e in l["evidenceErrors"]))
        self.assertTrue(any("dimensions differ" in e for e in l["evidenceErrors"]))
        self.assertTrue(any("disagrees" in e for e in l["evidenceErrors"]))

    def test_large_optional_sdk_errors_stay_inside_ipc_header_budget(self):
        def unavailable(*args):
            raise RuntimeError("fixture SDK unavailable " * 50_000)
        class BrokenTransformation:
            def __getattr__(self, name): return unavailable
        self.left.getTransformation = lambda: BrokenTransformation()
        self.right.getTransformation = lambda: BrokenTransformation()
        rgb = RGB()
        rgb.getExposureTime = rgb.getSensitivity = rgb.getColorTemperature = unavailable
        packet, *_ = self.service.frame_payload(rgb, FakeDepthFrame(), self.left, self.right,
            [100., 0, 1., 0, 101., .5, 0, 0, 1.], stereo_length_unit_meter=METER)
        self.assertLess(len(packet), 65_536)
        header = json.loads(packet)
        errors = (header["rgb_frame_observation_errors"]
                  + header["rectified_left_geometry"]["evidenceErrors"]
                  + header["rectified_right_geometry"]["evidenceErrors"]
                  + header["rectified_left_source_to_right_source"]["evidenceErrors"])
        self.assertGreater(len(errors), 10)
        self.assertTrue(all(len(error) <= 400 for error in errors))


@unittest.skipUnless(SDK is not None, "Optional installed DepthAI SDK; no camera required")
class ActualSDKFrameEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = load_service(name="actual_sdk_stereo_frame_evidence_fixture")

    @staticmethod
    def frame(focal, x, sequence, common_socket):
        # These are in-memory message objects. Never construct Device/Pipeline.
        transform = SDK.ImgTransformation()
        transform.setSourceSize(640, 400)
        transform.setSize(640, 400)
        transform.setIntrinsicMatrix([[focal, 0, 320], [0, focal+1, 200], [0, 0, 1]])
        extrinsics = SDK.Extrinsics()
        extrinsics.toCameraSocket = common_socket
        extrinsics.setTransformationMatrix(rigid(x), SDK.LengthUnit.METER)
        transform.setExtrinsics(extrinsics)
        frame = SDK.ImgFrame()
        frame.setWidth(640)
        frame.setHeight(400)
        frame.setType(SDK.ImgFrame.Type.GRAY8)
        frame.setTransformation(transform)
        frame.setSequenceNum(sequence)
        frame.setTimestamp(timedelta(seconds=3, microseconds=sequence))
        frame.setTimestampDevice(timedelta(seconds=2, microseconds=sequence))
        return frame

    def test_actual_sdk_getter_shapes_and_explicit_metric_extrinsics(self):
        left = self.frame(500., .030, 141, SDK.CameraBoardSocket.CAM_A)
        right = self.frame(510., -.045, 143, SDK.CameraBoardSocket.CAM_A)
        evidence = self.service.rectified_stereo_frame_evidence(left, right, SDK.LengthUnit.METER)
        l, r = evidence["rectified_left_geometry"], evidence["rectified_right_geometry"]
        self.assertEqual((l["intrinsics"][0], r["intrinsics"][0]), (500., 510.))
        self.assertEqual(l["timestampDeviceNanoseconds"], 2_000_141_000)
        self.assertEqual(l["evidenceErrors"], [])
        self.assertEqual(l["extrinsicsToCommon"]["evidenceErrors"], [])
        self.assertAlmostEqual(l["extrinsicsToCommon"]["matrix"][3], .030, places=7)
        pair = evidence["rectified_left_source_to_right_source"]
        self.assertEqual(pair["evidenceErrors"], [])
        # Actual SDK convention is inverse(rightToCommon) * leftToCommon.
        self.assertAlmostEqual(pair["matrix"][3], .075, places=7)
        json.dumps(evidence, allow_nan=False)

    def test_actual_sdk_unavailable_common_frame_and_zero_readbacks_are_nonfatal(self):
        left = self.frame(500., .030, 141, SDK.CameraBoardSocket.CAM_A)
        right = self.frame(510., -.045, 143, SDK.CameraBoardSocket.CAM_D)
        evidence = self.service.rectified_stereo_frame_evidence(left, right, SDK.LengthUnit.METER)
        pair = evidence["rectified_left_source_to_right_source"]
        self.assertIsNone(pair["matrix"])
        self.assertTrue(pair["evidenceErrors"])
        unavailable = self.service.rectified_stereo_frame_evidence(left, right, None)
        self.assertIsNone(unavailable["rectified_left_geometry"]["extrinsicsToCommon"]["matrix"])
        readback = self.service.rgb_frame_readback(SDK.ImgFrame())
        self.assertIsNone(readback["rgb_frame_exposure_microseconds"])
        self.assertIsNone(readback["rgb_frame_iso"])
        self.assertIsNone(readback["rgb_frame_color_temperature_kelvin"])
        self.assertEqual(len(readback["rgb_frame_observation_errors"]), 3)
        json.dumps([evidence, unavailable, readback], allow_nan=False)


if __name__ == "__main__":
    unittest.main()
