#!/usr/bin/env python3
"""FACE normalization configuration/routing/provenance; no Device or Pipeline."""
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
spec = importlib.util.spec_from_file_location("rgb_normalization_worker_fixture", ROOT / "Cerebro/Webcam_color.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class Input:
    def __init__(self): self.size = self.blocking = None
    def setMaxSize(self, value): self.size = value
    def setBlocking(self, value): self.blocking = value


class Output:
    def __init__(self): self.targets = []
    def link(self, value): self.targets.append(value)


class Camera:
    def __init__(self): self.id, self.requests, self.output = 7, [], Output()
    def requestOutput(self, size, **kwargs):
        self.requests.append(dict(size=list(size), **kwargs))
        return self.output


class Manip:
    def __init__(self, node_id):
        self.id, self.initialConfig, self.inputImage, self.out = node_id, dai.ImageManipConfig(), Input(), Output()
    def setBackend(self, value): self.backend = value
    def setMaxOutputFrameSize(self, value): self.maximum = value


class Graph:
    def __init__(self): self.nodes = []
    def create(self, kind):
        assert kind is dai.node.ImageManip
        node = Manip(10 + len(self.nodes)); self.nodes.append(node); return node


def host_graph(camera, manip=None, size=(640, 400)):
    # Exact supported serialization keys; values are checked against the actual
    # SDK ImageManipConfig getter/text in the configuration tests below.
    request = camera.requests[0]
    nodes = [[camera.id, {"id": camera.id, "name": "Camera", "properties": {"outputRequests": [
        {"enableUndistortion": request["enableUndistortion"], "size": list(size), "fps": 30.0, "type": 9}]}}]]
    if manip is not None:
        nodes.append([manip.id, {"id": manip.id, "name": "ImageManip", "properties": {
            "backend": int(manip.backend), "initialConfig": {"base": {"undistort": True, "operations": [],
                "outputWidth": size[0], "outputHeight": size[1], "resizeMode": 1},
                "outputFrameType": 9, "reusePreviousImage": False, "skipCurrentImage": False},
            "outputFrameSize": manip.maximum, "numFramesPool": 4, "performanceMode": 0}}])
    return {"pipeline": {"nodes": nodes}}


@unittest.skipIf(dai is None, "Actual DepthAI SDK required; never open a device")
class RGBNormalizationTests(unittest.TestCase):
    def face(self, size=(640, 400)):
        camera, graph = Camera(), Graph()
        output, descriptor = worker.configure_rgb_output(graph, dai, camera, "face", size, 30.0)
        return camera, graph, output, descriptor

    def test_actual_sdk_configuration_and_single_source_wiring(self):
        for size in [(640, 400), (640, 480), (1280, 720)]:
            with self.subTest(size=size):
                camera, graph, output, descriptor = self.face(size)
                self.assertEqual(len(camera.requests), 1)
                self.assertIs(camera.requests[0]["enableUndistortion"], False)
                node = graph.nodes[0]
                self.assertIs(output, node.out)
                self.assertEqual(camera.output.targets, [node.inputImage])
                self.assertEqual((node.inputImage.size, node.inputImage.blocking), (2, False))
                self.assertEqual(node.backend, dai.node.ImageManip.Backend.CPU)
                self.assertTrue(node.initialConfig.getUndistort())
                self.assertEqual(node.maximum, size[0] * size[1] * 3)
                text = str(node.initialConfig)
                for token in [f"outputWidth: {size[0]}", f"outputHeight: {size[1]}", "resizeMode: 1", "outputFrameType: 9", "operations: [ ]"]:
                    self.assertIn(token, text)
                self.assertEqual(descriptor["cameraNodeID"], camera.id)
                self.assertEqual(descriptor["manipNodeID"], node.id)

    def test_belly_unchanged_camera_request_without_manip(self):
        camera, graph = Camera(), Graph()
        output, descriptor = worker.configure_rgb_output(graph, dai, camera, "belly", (640, 400), 30.0)
        self.assertIs(output, camera.output)
        self.assertEqual(graph.nodes, [])
        self.assertTrue(camera.requests[0]["enableUndistortion"])
        policy = worker.observed_rgb_normalization(host_graph(camera), descriptor, dai)
        self.assertEqual(policy["method"], "camera_request")
        self.assertNotIn("imageManipProperties", policy)
        self.assertFalse(policy["pixelWarpVerifiedByMetadata"])

    def test_nn_uses_normalized_stream_without_second_camera_or_second_warp(self):
        camera, graph, output, descriptor = self.face()
        self.assertIs(worker.configure_face_nn_input(graph, dai, output, (640, 400), (640, 400)), output)
        resized = worker.configure_face_nn_input(graph, dai, output, (640, 400), (640, 640))
        node = graph.nodes[-1]
        self.assertIs(resized, node.out)
        self.assertEqual(output.targets, [node.inputImage])
        self.assertFalse(node.initialConfig.getUndistort())
        self.assertEqual((node.inputImage.size, node.inputImage.blocking), (1, False))
        self.assertEqual(len(camera.requests), 1)
        self.assertIn("outputHeight: 640", str(node.initialConfig))

    def test_hash_binds_normalization_backend_and_full_host_config_not_node_ids(self):
        camera, graph, output, descriptor = self.face()
        actual = host_graph(camera, graph.nodes[0])
        a = worker.observed_rgb_normalization(actual, descriptor, dai)
        sha = lambda p: hashlib.sha256(worker.calibration_json_bytes(p)).hexdigest()
        # Reallocation/control serialization noise must not masquerade as optics.
        moved = copy.deepcopy(actual); moved_descriptor = copy.deepcopy(descriptor)
        for row in moved["pipeline"]["nodes"]:
            row[0] += 100; row[1]["id"] += 100
            if row[1]["name"] == "Camera": row[1]["properties"]["initialControl"] = {"unusedSDKBytes": [93, 12]}
        moved_descriptor["cameraNodeID"] += 100; moved_descriptor["manipNodeID"] += 100
        self.assertEqual(a, worker.observed_rgb_normalization(moved, moved_descriptor, dai))
        hw = copy.deepcopy(actual); hw_descriptor = copy.deepcopy(descriptor)
        hw["pipeline"]["nodes"][1][1]["properties"]["backend"] = int(dai.node.ImageManip.Backend.HW)
        hw_descriptor["backend"] = "HW"
        self.assertNotEqual(sha(a), sha(worker.observed_rgb_normalization(hw, hw_descriptor, dai)))
        self.assertFalse(a["resolvedBackendObserved"])
        self.assertIsNone(a["resolvedBackend"])
        props = {"useHomographyRectification": False, "disparityToDepthUseSpecTranslation": False,
                 "rectificationUseSpecTranslation": False, "depthAlignmentUseSpecTranslation": False}
        actual["pipeline"]["nodes"].append([20, {"properties": props}])
        config = dai.StereoDepthConfig(); config.setSubpixel(True)
        pipeline = SimpleNamespace(getAutoCalibrationMode=lambda: dai.Pipeline.AutoCalibrationMode.OFF,
                                   serializeToJson=lambda _: actual)
        policy = worker.runtime_stereo_policy(pipeline, SimpleNamespace(initialConfig=config), dai, True, descriptor)
        self.assertEqual(policy["rgbNormalization"], a)
        legacy = worker.runtime_stereo_policy(pipeline, SimpleNamespace(initialConfig=config), dai, True)
        self.assertNotEqual(sha(policy), sha(legacy))

    def test_missing_or_wrong_host_config_fails_closed(self):
        camera, graph, output, descriptor = self.face()
        original = host_graph(camera, graph.nodes[0])
        for mutate in [lambda g: g["pipeline"]["nodes"].pop(),
            lambda g: g["pipeline"]["nodes"][0][1]["properties"]["outputRequests"].append({"enableUndistortion": False}),
            lambda g: g["pipeline"]["nodes"][1][1]["properties"]["initialConfig"]["base"].update(undistort=False),
            lambda g: g["pipeline"]["nodes"][1][1]["properties"].update(backend=1),
            lambda g: g["pipeline"]["nodes"][1][1]["properties"]["initialConfig"]["base"].update(outputHeight=480)]:
            value = copy.deepcopy(original); mutate(value)
            with self.assertRaises(RuntimeError): worker.observed_rgb_normalization(value, descriptor, dai)

    def test_packet_keeps_native_geometry_bytes_and_labels_host_intent(self):
        camera, graph, output, descriptor = self.face()
        normalization = worker.observed_rgb_normalization(host_graph(camera, graph.nodes[0]), descriptor, dai)
        transform = dai.ImgTransformation(); transform.setSourceSize(640, 400); transform.setSize(640, 400)
        transform.setIntrinsicMatrix([[511., 0., 319.], [0., 512., 201.], [0., 0., 1.]])
        def frame(kind, value):
            f = dai.ImgFrame(); f.setWidth(640); f.setHeight(400); f.setType(kind); f.setSequenceNum(27)
            f.setTimestamp(timedelta(seconds=4)); f.setTimestampDevice(timedelta(seconds=3)); f.setTransformation(transform)
            f.setData(value); return f
        pixels = np.full((400, 640, 3), 117, np.uint8)
        rgb = frame(dai.ImgFrame.Type.RGB888i, pixels)
        depth = frame(dai.ImgFrame.Type.RAW16, np.full((400, 640), 700, np.uint16).view(np.uint8).ravel())
        mono = frame(dai.ImgFrame.Type.GRAY8, np.full((400, 640), 80, np.uint8))
        old = worker.frame_payload(rgb, depth, mono, mono, [999.] * 9)
        new = worker.frame_payload(rgb, depth, mono, mono, [999.] * 9, rgb_normalization=normalization)
        self.assertEqual(old[1:], new[1:])
        a, b = json.loads(old[0]), json.loads(new[0])
        self.assertEqual(a["rgb_intrinsics"], b["rgb_intrinsics"])
        self.assertEqual(b["rgb_intrinsics"], [511., 0., 319., 0., 512., 201., 0., 0., 1.])
        self.assertEqual(b["rgb_normalization"], normalization)
        self.assertIn("not_per_frame_pixel_proof", b["rgb_output_undistorted_semantics"])
        self.assertLess(len(new[0]), 64000)


if __name__ == "__main__": unittest.main()
