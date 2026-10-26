#!/usr/bin/env python3
"""Actual SDK config/packet regression; never construct Device or Pipeline."""
import sys
sys.dont_write_bytecode = True
import ast
import copy
from datetime import timedelta
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

try:
    import depthai as dai
    import numpy as np
except ImportError:
    dai = None

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("strict_planning_worker_fixture", ROOT / "Cerebro/Webcam_color.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class Stereo:
    def __init__(self): self.initialConfig = dai.StereoDepthConfig()
    def setSubpixel(self, value): self.initialConfig.setSubpixel(value)
    def setExtendedDisparity(self, value): self.initialConfig.setExtendedDisparity(value)


def host_properties(stereo):
    config, post = stereo.initialConfig, stereo.initialConfig.postProcessing
    return {"useHomographyRectification": False, "disparityToDepthUseSpecTranslation": False,
        "rectificationUseSpecTranslation": False, "depthAlignmentUseSpecTranslation": False,
        "initialConfig": {"algorithmControl": {"enableLeftRightCheck": config.getLeftRightCheck()},
            "postProcessing": {"median": int(config.getMedianFilter()),
                "spatialFilter": {"enable": post.spatialFilter.enable, "holeFillingRadius": post.spatialFilter.holeFillingRadius},
                "temporalFilter": {"enable": post.temporalFilter.enable},
                "holeFilling": {"enable": post.holeFilling.enable},
                "adaptiveMedianFilter": {"enable": post.adaptiveMedianFilter.enable},
                "decimationFilter": {"decimationFactor": post.decimationFilter.decimationFactor}}}}


@unittest.skipIf(dai is None, "DepthAI SDK required for native CPU config coverage")
class StrictPlanningDepthTests(unittest.TestCase):
    def configured(self, mode="near_field"):
        stereo = Stereo()
        config = stereo.initialConfig
        # Start with the documented ROBOTICS settings that caused filled and
        # edge-spread occupancy; no node/device is required to exercise setters.
        config.setMedianFilter(dai.MedianFilter.KERNEL_7x7)
        config.postProcessing.spatialFilter.enable = True
        config.postProcessing.spatialFilter.holeFillingRadius = 2
        config.postProcessing.spatialFilter.delta = 20
        config.postProcessing.holeFilling.enable = True
        config.postProcessing.adaptiveMedianFilter.enable = True
        config.postProcessing.decimationFilter.decimationFactor = 2
        config.postProcessing.temporalFilter.enable = False
        config.setLeftRightCheck(True)
        config.setLeftRightCheckThreshold(10)
        config.setConfidenceThreshold(15)
        worker.configure_stereo_mode(stereo, mode)
        worker.configure_strict_planning_depth(stereo, dai)
        return stereo

    def test_native_sdk_setters_disable_fill_and_preserve_both_stereo_modes(self):
        for mode, extended, subpixel in [("near_field", True, False), ("standard", False, True)]:
            with self.subTest(mode=mode):
                stereo = self.configured(mode)
                result = worker.strict_planning_depth_configuration(stereo, dai, host_properties(stereo))
                self.assertEqual(result["kind"], "lr_checked_no_fill_no_median_no_decimation")
                self.assertTrue(result["hostConfigurationChecked"])
                self.assertTrue(result["leftRightCheckEnabled"])
                self.assertFalse(result["spatialFilterEnabled"])
                self.assertEqual(result["spatialHoleFillingRadius"], 0)
                self.assertFalse(result["holeFillingEnabled"])
                self.assertFalse(result["adaptiveMedianFilterEnabled"])
                self.assertFalse(result["temporalFilterEnabled"])
                self.assertEqual(result["medianFilter"], 0)
                self.assertEqual(result["decimationFactor"], 1)
                self.assertEqual(stereo.initialConfig.getLeftRightCheckThreshold(), 10)
                self.assertEqual(stereo.initialConfig.getConfidenceThreshold(), 15)
                self.assertEqual(stereo.initialConfig.getExtendedDisparity(), extended)
                self.assertEqual(stereo.initialConfig.getSubpixel(), subpixel)
                self.assertIn("not_per_pixel_validity", result["source"])

    def test_each_native_config_drift_fails_closed(self):
        mutations = [
            lambda c: c.setLeftRightCheck(False), lambda c: c.setMedianFilter(dai.MedianFilter.KERNEL_3x3),
            lambda c: setattr(c.postProcessing.spatialFilter, "enable", True),
            lambda c: setattr(c.postProcessing.spatialFilter, "holeFillingRadius", 1),
            lambda c: setattr(c.postProcessing.temporalFilter, "enable", True),
            lambda c: setattr(c.postProcessing.holeFilling, "enable", True),
            lambda c: setattr(c.postProcessing.adaptiveMedianFilter, "enable", True),
            lambda c: setattr(c.postProcessing.decimationFilter, "decimationFactor", 2)]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                stereo = self.configured(); mutate(stereo.initialConfig)
                with self.assertRaisesRegex(RuntimeError, "SDK planning-depth readback"):
                    worker.strict_planning_depth_configuration(stereo, dai)

    def test_each_serialized_host_drift_and_missing_field_fails_closed(self):
        mutations = [
            lambda p: p["algorithmControl"].update(enableLeftRightCheck=False),
            lambda p: p["postProcessing"].update(median=7),
            lambda p: p["postProcessing"]["spatialFilter"].update(enable=True),
            lambda p: p["postProcessing"]["spatialFilter"].update(holeFillingRadius=2),
            lambda p: p["postProcessing"]["temporalFilter"].update(enable=True),
            lambda p: p["postProcessing"]["holeFilling"].update(enable=True),
            lambda p: p["postProcessing"]["adaptiveMedianFilter"].update(enable=True),
            lambda p: p["postProcessing"]["decimationFilter"].update(decimationFactor=2),
            lambda p: p["postProcessing"].pop("holeFilling"),
            lambda p: p["postProcessing"]["spatialFilter"].update(enable=0)]
        stereo = self.configured()
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                props = host_properties(stereo); mutate(props["initialConfig"])
                with self.assertRaises(RuntimeError):
                    worker.strict_planning_depth_configuration(stereo, dai, props)

    def test_runtime_policy_binds_actual_strict_host_settings(self):
        stereo = self.configured()
        properties = host_properties(stereo)
        pipeline = SimpleNamespace(getAutoCalibrationMode=lambda: dai.Pipeline.AutoCalibrationMode.OFF,
            serializeToJson=lambda _: {"pipeline": {"nodes": [[7, {"properties": properties}]]}})
        policy = worker.runtime_stereo_policy(pipeline, stereo, dai, True)
        self.assertTrue(policy["planningDepth"]["hostConfigurationChecked"])
        strict_hash = hashlib.sha256(worker.calibration_json_bytes(policy)).hexdigest()
        self.assertNotEqual(strict_hash, hashlib.sha256(worker.calibration_json_bytes(
            {k: v for k, v in policy.items() if k != "planningDepth"})).hexdigest())
        properties["initialConfig"]["postProcessing"]["median"] = 7
        with self.assertRaisesRegex(RuntimeError, "serialized HOST"):
            worker.runtime_stereo_policy(pipeline, stereo, dai, True)

    def test_shared_startup_applies_after_preset_and_mode_before_alignment_start(self):
        tree = ast.parse((ROOT / "Cerebro/Webcam_color.py").read_text())
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)]
        helper = [n for n in calls if isinstance(n.func, ast.Name) and n.func.id == "configure_strict_planning_depth"]
        self.assertEqual(len(helper), 1)
        preset = [n for n in calls if isinstance(n.func, ast.Attribute) and n.func.attr == "setDefaultProfilePreset"]
        mode = [n for n in calls if isinstance(n.func, ast.Name) and n.func.id == "configure_stereo_mode"]
        alignment = [n for n in calls if isinstance(n.func, ast.Name) and n.func.id == "configure_rgb_depth_alignment"]
        start = [n for n in calls if isinstance(n.func, ast.Attribute) and n.func.attr == "start"]
        self.assertLess(preset[0].lineno, mode[0].lineno)
        self.assertLess(mode[0].lineno, helper[0].lineno)
        self.assertLess(helper[0].lineno, alignment[0].lineno)
        self.assertLess(helper[0].lineno, min(n.lineno for n in start))
        # No extra validity/disparity pipeline, camera request, or IR side effect
        # is introduced by configuring/reading this CPU-only SDK config object.
        for name in ("configure_strict_planning_depth", "strict_planning_depth_configuration"):
            fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name)
            self.assertFalse(any(isinstance(n, ast.Attribute) and ("ir" in n.attr.lower() or n.attr in ("create", "link", "start")) for n in ast.walk(fn)))

    def test_packet_retains_original_invalid_zero_and_foreground_background(self):
        width, height = 16, 16
        transform = dai.ImgTransformation(); transform.setSourceSize(width,height); transform.setSize(width,height)
        transform.setIntrinsicMatrix([[100.,0.,8.],[0.,100.,8.],[0.,0.,1.]])
        def frame(kind, values):
            f=dai.ImgFrame(); f.setWidth(width); f.setHeight(height); f.setType(kind)
            f.setSequenceNum(29); f.setTimestamp(timedelta(seconds=4)); f.setTimestampDevice(timedelta(seconds=3))
            f.setTransformation(transform); f.setData(values); return f
        raw=np.zeros((height,width),np.uint16)
        raw[:,1:4]=350; raw[:,12:15]=1300
        rgb=frame(dai.ImgFrame.Type.RGB888i,np.zeros((height,width,3),np.uint8))
        depth=frame(dai.ImgFrame.Type.RAW16,raw.view(np.uint8).ravel())
        mono=frame(dai.ImgFrame.Type.GRAY8,np.zeros((height,width),np.uint8))
        header,_,depth_bytes,_,_=worker.frame_payload(rgb,depth,mono,mono,[100.,0.,8.,0.,100.,8.,0.,0.,1.])
        self.assertEqual(depth_bytes,raw.astype("<u2").tobytes())
        self.assertEqual(json.loads(header)["sequence"],29)
        self.assertEqual(np.frombuffer(depth_bytes,dtype="<u2").reshape(height,width)[8,8],0)


if __name__ == "__main__": unittest.main()
