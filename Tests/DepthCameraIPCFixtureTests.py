#!/usr/bin/env python3
"""Dependency-free fixture test for Cerebro's DepthAI IPC v2 producer."""

from datetime import timedelta
import importlib.util
import json
from pathlib import Path
import socket
import struct
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SERVICE_PATH = ROOT / "Cerebro" / "Webcam_color.py"


def load_service():
    spec = importlib.util.spec_from_file_location("cerebro_depth_camera_service", SERVICE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load the bundled depth camera service")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeRGBFrame:
    width = 2
    height = 1
    bytes = bytes((1, 2, 3, 4, 5, 6))

    def getWidth(self):
        return self.width

    def getHeight(self):
        return self.height

    def getData(self):
        return self.bytes

    def getSequenceNum(self):
        return 42

    def getTimestamp(self):
        return timedelta(seconds=3, microseconds=250_000)


class FakeDepthArray:
    size = 2

    def astype(self, dtype, copy=False):
        assert dtype == "<u2"
        assert copy is False
        return self

    def tobytes(self, order="C"):
        assert order == "C"
        return bytes((0x34, 0x12, 0xCD, 0xAB))


class FakeDepthFrame:
    def getWidth(self):
        return 2

    def getHeight(self):
        return 1

    def getFrame(self):
        return FakeDepthArray()


class FakeMonoFrame:
    def __init__(self, values):
        self.values = bytes(values)

    def getWidth(self):
        return 2

    def getHeight(self):
        return 1

    def getData(self):
        return self.values


def receive_exact(sock, length):
    output = bytearray()
    while len(output) < length:
        chunk = sock.recv(length - len(output))
        if not chunk:
            raise RuntimeError("IPC fixture ended early")
        output.extend(chunk)
    return bytes(output)


def main():
    service = load_service()
    with tempfile.TemporaryDirectory(prefix="cerebro-depthcam-lock-") as directory:
        lock_path = str(Path(directory) / "depth-camera.sock")
        first_lock = service.acquire_service_lock(lock_path)
        try:
            try:
                service.acquire_service_lock(lock_path)
            except RuntimeError as error:
                assert "already owns" in str(error)
            else:
                raise AssertionError("A second service acquired the same socket lock")
        finally:
            service.release_service_lock(first_lock)

    sender, receiver = socket.socketpair()
    try:
        left_source = FakeMonoFrame((7, 8))
        right_source = FakeMonoFrame((9, 10))
        service.send_frame(sender, FakeRGBFrame(), FakeDepthFrame(), left_source, right_source)
        prefix = receive_exact(receiver, 8)
        assert prefix[:4] == b"CDP1"
        header_length = struct.unpack(">I", prefix[4:])[0]
        header = json.loads(receive_exact(receiver, header_length))
        rgb = receive_exact(receiver, header["rgb_length"])
        depth = receive_exact(receiver, header["depth_length"])
        left = receive_exact(receiver, header["left_length"])
        right = receive_exact(receiver, header["right_length"])

        assert header == {
            "protocol_version": 2,
            "sequence": 42,
            "timestamp_ns": 3_250_000_000,
            "rgb_width": 2,
            "rgb_height": 1,
            "rgb_format": "RGB888",
            "rgb_length": 6,
            "depth_width": 2,
            "depth_height": 1,
            "depth_format": "DEPTH16LE",
            "depth_unit": "millimeter",
            "depth_length": 4,
            "stereo_width": 2,
            "stereo_height": 1,
            "stereo_format": "GRAY8",
            "left_length": 2,
            "right_length": 2,
        }
        assert rgb == FakeRGBFrame.bytes
        assert depth == bytes((0x34, 0x12, 0xCD, 0xAB))
        assert left == bytes((7, 8))
        assert right == bytes((9, 10))
    finally:
        sender.close()
        receiver.close()

    print("Depth camera IPC v2 fixture passed")


if __name__ == "__main__":
    main()
