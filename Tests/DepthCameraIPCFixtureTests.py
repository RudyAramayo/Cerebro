#!/usr/bin/env python3
"""Dependency-free fixture test for Cerebro's DepthAI IPC v2 producer."""

from datetime import timedelta
import importlib.util
import contextlib
import io
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


class FakeTransformation:
    def __init__(self, matrix):
        self.matrix = matrix

    def getIntrinsicMatrix(self):
        return self.matrix


class FakeTransformedRGBFrame(FakeRGBFrame):
    def __init__(self, matrix):
        self.transformation = FakeTransformation(matrix)

    def getTransformation(self):
        return self.transformation


class FakeFocusedRGBFrame(FakeTransformedRGBFrame):
    def __init__(self, matrix, lens_position):
        super().__init__(matrix)
        self.lens_position = lens_position

    def getLensPosition(self):
        return self.lens_position


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
    class CapturedFrame:
        def __init__(self, seconds): self.seconds = seconds
        def getTimestamp(self): return timedelta(seconds=self.seconds)
    captured = service.capture_time_milliseconds(
        [CapturedFrame(3.25), CapturedFrame(3.23)], timedelta(seconds=3.5), 1000.0)
    assert abs(captured - 999730.0) < 1e-6, "The older depth capture must determine freshness"
    assert service.capture_time_milliseconds(
        [CapturedFrame(4)], timedelta(seconds=3.5), 1000.0) is None
    class FakeInput:
        def setMaxSize(self, value): self.size = value
        def setBlocking(self, value): self.blocking = value
    node_input = FakeInput()
    service.configure_latest_input(node_input)
    assert node_input.size == 2 and node_input.blocking is False
    timing = service.frame_timing(CapturedFrame(3.25), CapturedFrame(3.23), timedelta(seconds=3.5))
    assert timing == {"rgb_age_ms": 250.0, "depth_age_ms": 270.0, "sync_skew_ms": 20.0}
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
        intrinsics = [100.0, 0.0, 1.0, 0.0, 101.0, 0.5, 0.0, 0.0, 1.0]
        service.send_frame(
            sender,
            FakeRGBFrame(),
            FakeDepthFrame(),
            left_source,
            right_source,
            intrinsics,
            captured_at_milliseconds=captured,
        )
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
            "captured_at_milliseconds": captured,
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
            "rgb_intrinsics": intrinsics,
            "rgb_intrinsics_source": "legacy_eeprom",
            "rgb_calibrated_lens_position": None,
            "rgb_frame_lens_position": None,
            "sidewalk_center_deviation": None,
            "sidewalk_confidence": None,
            "chess_pieces": [],
        }
        assert rgb == FakeRGBFrame.bytes
        assert depth == bytes((0x34, 0x12, 0xCD, 0xAB))
        assert left == bytes((7, 8))
        assert right == bytes((9, 10))
    finally:
        sender.close()
        receiver.close()

    # The Camera node's CROP/undistortion output need not have EEPROM K scaled
    # only to width/height. Publish its actual per-frame pixel transformation.
    cropped_matrix = [[125.0, 0.0, 0.75], [0.0, 126.0, 0.25], [0.0, 0.0, 1.0]]
    transformed_frame = FakeTransformedRGBFrame(cropped_matrix)
    cropped_intrinsics = [value for row in cropped_matrix for value in row]
    packet, rgb, depth, left, right = service.frame_payload(
        transformed_frame, FakeDepthFrame(), left_source, right_source, intrinsics
    )
    header = json.loads(packet)
    assert header["rgb_intrinsics"] == cropped_intrinsics != intrinsics
    assert header["rgb_intrinsics_source"] == "transformed_frame"
    assert rgb == FakeRGBFrame.bytes and depth == bytes((0x34, 0x12, 0xCD, 0xAB))
    assert left == bytes((7, 8)) and right == bytes((9, 10))
    next_matrix = [[130.0, 0.0, 0.8], [0.0, 131.0, 0.3], [0.0, 0.0, 1.0]]
    transformed_frame.transformation = FakeTransformation(next_matrix)
    next_values, source = service.rgb_frame_intrinsics(transformed_frame, [], 2, 1)
    assert next_values == [value for row in next_matrix for value in row]
    assert source == "transformed_frame", "K must be selected per frame, not cached"

    class FakeFocusControl:
        def __init__(self): self.positions = []
        def setManualFocus(self, value): self.positions.append(value)
    class FakeCamera:
        def __init__(self): self.initialControl = FakeFocusControl()
    class FakeCalibration:
        def __init__(self, value): self.value = value; self.read_sockets = []
        def getLensPosition(self, rgb_socket):
            self.read_sockets.append(rgb_socket)
            return self.value
    # Only the surveyed RGB socket value is applied, without editing EEPROM.
    # Boundaries are valid values; do not treat position zero as missing.
    for position in (0, 147, 255, 147.0):
        camera = FakeCamera(); calibration = FakeCalibration(position)
        selected = service.configure_rgb_calibrated_focus(camera, calibration, "rgb-socket")
        assert selected == int(position)
        assert camera.initialControl.positions == [int(position)]
        assert calibration.read_sockets == ["rgb-socket"]
    for calibration in (object(), FakeCalibration(None)):
        camera = FakeCamera()
        assert service.configure_rgb_calibrated_focus(camera, calibration, "rgb-socket") is None
        assert camera.initialControl.positions == [], "Missing focus must never be guessed"
    class MissingFocusCalibration:
        def getLensPosition(self, rgb_socket): raise RuntimeError("no lens calibration")
    camera = FakeCamera()
    with contextlib.redirect_stdout(io.StringIO()) as diagnostics:
        assert service.configure_rgb_calibrated_focus(camera, MissingFocusCalibration(), "rgb-socket") is None
    assert camera.initialControl.positions == [] and "focus calibration unavailable" in diagnostics.getvalue()

    for frame_position in (None, 0, 146, 255, 146.0):
        focused_frame = FakeFocusedRGBFrame(cropped_matrix, frame_position)
        packet, *_ = service.frame_payload(focused_frame, FakeDepthFrame(), left_source,
                                          right_source, intrinsics,
                                          rgb_calibrated_lens_position=147)
        focus_header = json.loads(packet)
        assert focus_header["rgb_calibrated_lens_position"] == 147
        assert focus_header["rgb_frame_lens_position"] == frame_position
        assert focus_header["rgb_intrinsics_source"] == "transformed_frame"
    # The actual frame position remains observable even when it differs from
    # the requested calibrated position; command acceptance is not proof.
    assert focus_header["rgb_frame_lens_position"] == 146
    for invalid_position in (-1, 256, 2.5, float("nan"), float("inf"), True, "147", []):
        try:
            service.configure_rgb_calibrated_focus(FakeCamera(), FakeCalibration(invalid_position), "rgb-socket")
        except RuntimeError as error:
            assert "invalid RGB calibrated lens position" in str(error)
        else:
            raise AssertionError("Invalid calibrated focus was applied")
        try:
            service.frame_payload(FakeFocusedRGBFrame(cropped_matrix, invalid_position),
                                  FakeDepthFrame(), left_source, right_source, intrinsics,
                                  rgb_calibrated_lens_position=147)
        except RuntimeError as error:
            assert "invalid RGB frame lens position" in str(error)
        else:
            raise AssertionError("Invalid frame focus metadata was published")
    try:
        service.frame_payload(FakeFocusedRGBFrame(cropped_matrix, 147), FakeDepthFrame(),
                              left_source, right_source, intrinsics,
                              rgb_calibrated_lens_position=256)
    except RuntimeError as error:
        assert "invalid RGB calibrated lens position" in str(error)
    else:
        raise AssertionError("Invalid calibrated focus metadata was published")

    # Missing metadata is a visible compatibility fallback; supplied invalid
    # metadata must never be replaced with the otherwise-valid nominal K.
    for unavailable in (None, object()):
        transformed_frame.transformation = unavailable
        values, source = service.rgb_frame_intrinsics(transformed_frame, intrinsics, 2, 1)
        assert values == intrinsics and source == "legacy_eeprom"
    malformed = [
        [[0.0] * 3 for _ in range(3)],
        [[1.0, 0.0, 0.5], [0.0, 1.0, 0.5]],
        [[1.0, 0.0], [0.0, 1.0], [0.0, 0.0]],
        [125.0, 0.0, 0.75, 0.0, 126.0, 0.25, 0.0, 0.0, 1.0],
        [[float("nan"), 0.0, 0.75], [0.0, 126.0, 0.25], [0.0, 0.0, 1.0]],
        [[125.0, 0.0, 0.75], [0.0, float("inf"), 0.25], [0.0, 0.0, 1.0]],
        [[-125.0, 0.0, 0.75], [0.0, 126.0, 0.25], [0.0, 0.0, 1.0]],
        [[125.0, 0.0, 2.0], [0.0, 126.0, 0.25], [0.0, 0.0, 1.0]],
        [[125.0, 0.0, 0.75], [0.0, 126.0, 1.0], [0.0, 0.0, 1.0]],
        [[125.0, 0.1, 0.75], [0.0, 126.0, 0.25], [0.0, 0.0, 1.0]],
        [[125.0, 0.0, 0.75], [0.1, 126.0, 0.25], [0.0, 0.0, 1.0]],
        [[125.0, 0.0, 0.75], [0.0, 126.0, 0.25], [0.1, 0.0, 1.0]],
        [[125.0, 0.0, 0.75], [0.0, 126.0, 0.25], [0.0, 0.0, 2.0]],
        [[True, 0.0, 0.75], [0.0, 126.0, 0.25], [0.0, 0.0, 1.0]],
        [["125", 0.0, 0.75], [0.0, 126.0, 0.25], [0.0, 0.0, 1.0]],
        None,
    ]
    for matrix in malformed:
        transformed_frame.transformation = FakeTransformation(matrix)
        try:
            service.frame_payload(transformed_frame, FakeDepthFrame(), left_source,
                                  right_source, intrinsics)
        except RuntimeError as error:
            assert "invalid RGB camera intrinsics" in str(error)
        else:
            raise AssertionError("Malformed transformed K was silently accepted")
    try:
        service.rgb_frame_intrinsics(FakeRGBFrame(), [0.0] * 9, 2, 1)
    except RuntimeError as error:
        assert "invalid RGB camera intrinsics" in str(error)
    else:
        raise AssertionError("Invalid legacy K was accepted")

    print("Depth camera IPC v2 fixture passed")


if __name__ == "__main__":
    main()
