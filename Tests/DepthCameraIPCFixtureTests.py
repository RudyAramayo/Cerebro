#!/usr/bin/env python3
"""Dependency-free fixture test for Cerebro's DepthAI IPC v2 producer."""

from datetime import timedelta
import ast
import importlib.util
import contextlib
import io
import hashlib
import json
from pathlib import Path
import socket
import struct
import tempfile
import sys


ROOT = Path(__file__).resolve().parents[1]
SERVICE_PATH = ROOT / "Cerebro" / "Webcam_color.py"


def load_service(path=SERVICE_PATH, name="cerebro_depth_camera_service"):
    spec = importlib.util.spec_from_file_location(name, path)
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


class FakeSourceTransformation(FakeTransformation):
    def __init__(self, matrix, source_size, source_intrinsics, image_transform):
        super().__init__(matrix)
        self.source_size = source_size
        self.source_intrinsics = source_intrinsics
        self.image_transform = image_transform

    def getSourceSize(self): return self.source_size
    def getSourceIntrinsicMatrix(self): return self.source_intrinsics
    def getMatrix(self): return self.image_transform


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


def running_worker_provenance_fixture():
    original = SERVICE_PATH.read_bytes()
    changed = original.replace(b"RGB_OUTPUT_UNDISTORTED = True", b"RGB_OUTPUT_UNDISTORTED = False", 1)
    assert changed != original
    # Inspect the actual call sites, without constructing an SDK or device.
    calls = [node for node in ast.walk(ast.parse(original)) if isinstance(node, ast.Call)
             and isinstance(node.func, ast.Attribute) and node.func.attr == "requestOutput"
             and isinstance(node.func.value, ast.Name) and node.func.value.id == "rgb_camera"]
    assert calls and all(any(keyword.arg == "enableUndistortion" and isinstance(keyword.value, ast.Name)
                            and keyword.value.id == "RGB_OUTPUT_UNDISTORTED" for keyword in call.keywords) for call in calls)
    with tempfile.TemporaryDirectory(prefix="cerebro-worker-provenance-") as directory:
        path = Path(directory) / "worker.py"
        path.write_bytes(original)
        old_code = compile(original, str(path), "exec", dont_inherit=True, optimize=sys.flags.optimize)
        old_worker = load_service(path, "old_running_camera_worker")
        old_sha = old_worker.RUNNING_SERVICE_SOURCE_SHA256
        path.write_bytes(changed)  # An app replacement while the old worker lives.
        packet, *_ = old_worker.frame_payload(FakeRGBFrame(), FakeDepthFrame(), FakeMonoFrame((7,8)),
            FakeMonoFrame((9,10)), [100.,0.,1.,0.,101.,0.5,0.,0.,1.])
        header = json.loads(packet)
        assert header["running_service_source_sha256"] == old_sha == hashlib.sha256(original).hexdigest()
        assert header["rgb_output_undistorted"] is True
        try:
            exec(old_code, {"__file__":str(path), "__name__":"startup_swap_fixture"})
        except RuntimeError as error:
            assert "source changed" in str(error)
        else:
            raise AssertionError("Old executable code stamped a replacement file's hash during startup")
        replacement = load_service(path, "replacement_camera_worker")
        packet, *_ = replacement.frame_payload(FakeRGBFrame(), FakeDepthFrame(), FakeMonoFrame((7,8)),
            FakeMonoFrame((9,10)), [100.,0.,1.,0.,101.,0.5,0.,0.,1.])
        header = json.loads(packet)
        assert header["running_service_source_sha256"] == hashlib.sha256(changed).hexdigest() != old_sha
        assert header["rgb_output_undistorted"] is False


def main():
    service = load_service()
    assert service.RUNNING_SERVICE_SOURCE_SHA256 == hashlib.sha256(SERVICE_PATH.read_bytes()).hexdigest()
    assert service.RGB_OUTPUT_UNDISTORTED is True
    running_worker_provenance_fixture()
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
    class FakeOutput:
        def __init__(self): self.links = []
        def link(self, node_input): self.links.append(node_input)
    class FakeStereo:
        def __init__(self): self.depth = FakeOutput(); self.inputAlignTo = FakeInput(); self.output_size = None
        def setOutputSize(self, width, height): self.output_size = (width, height)
    class FakeAlign:
        def __init__(self):
            self.input = FakeInput(); self.inputAlignTo = FakeInput(); self.outputAligned = FakeOutput()
            self.output_size = None
        def setOutputSize(self, width, height): self.output_size = (width, height)
    class FakePipeline:
        def __init__(self): self.created = []
        def create(self, kind):
            assert kind is FakeAlign
            node = FakeAlign(); self.created.append(node); return node
    class FakePlatform:
        RVC2 = "rvc2"; RVC3 = "rvc3"; RVC4 = "rvc4"
    class FakeNodes: ImageAlign = FakeAlign
    class FakeDai: Platform = FakePlatform; node = FakeNodes
    for size in [(640, 400), (1280, 800), (1920, 1080)]:
        for platform in (FakePlatform.RVC2, FakePlatform.RVC3):
            pipeline, stereo, rgb = FakePipeline(), FakeStereo(), FakeOutput()
            output, method = service.configure_rgb_depth_alignment(pipeline, FakeDai, platform, stereo, rgb, size)
            assert output is stereo.depth and method == "stereo_input_align_to"
            assert stereo.output_size == size, "Geometric alignment did not request matching SDK depth dimensions"
            assert rgb.links == [stereo.inputAlignTo] and not stereo.depth.links
            assert not pipeline.created, "Older platforms must not create an external alignment node"
            assert stereo.inputAlignTo.size == 2 and stereo.inputAlignTo.blocking is False
        pipeline, stereo, rgb = FakePipeline(), FakeStereo(), FakeOutput()
        output, method = service.configure_rgb_depth_alignment(pipeline, FakeDai, FakePlatform.RVC4, stereo, rgb, size)
        assert len(pipeline.created) == 1
        align = pipeline.created[0]
        assert output is align.outputAligned and method == "image_align"
        assert align.output_size == size and stereo.output_size is None
        assert stereo.depth.links == [align.input] and rgb.links == [align.inputAlignTo]
        assert align.input.size == align.inputAlignTo.size == 2
        assert align.input.blocking is align.inputAlignTo.blocking is False
    for requested, expected in [((640, 400), (640, 400)), ((1280, 720), (1280, 720)),
                                ((1280, 800), (1280, 800)), ((1920, 1080), (1280, 720)),
                                ((1920, 1200), (1280, 800)), ((3840, 2160), (1280, 720))]:
        actual = service.stereo_capture_size(requested)
        assert actual == expected
        assert actual[0] <= 1280 and actual[1] <= 800 and actual[0] % 16 == actual[1] % 2 == 0
        assert actual[0] * requested[1] == actual[1] * requested[0], "Mono geometry changed aspect ratio"
        assert service.capture_frame_rate_for_bandwidth(False, requested, actual) == service.FRAME_RATE
    assert service.capture_frame_rate_for_bandwidth(True, (640, 400), (640, 400)) == 10.0
    assert service.capture_frame_rate_for_bandwidth(True, (1280, 800), (1280, 800)) == 2.5
    assert 2 <= service.capture_frame_rate_for_bandwidth(True, (1920, 1080), (1280, 720)) < 2.5
    for dimensions in [(0, 400), (-16, 400), (True, 400), (640.0, 400), (640, 401)]:
        try:
            service.stereo_capture_size(dimensions)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid/unrepresentable mono aspect admitted: " + str(dimensions))
    for platform in (None, "unknown"):
        try:
            service.configure_rgb_depth_alignment(FakePipeline(), FakeDai, platform, FakeStereo(), FakeOutput())
        except RuntimeError as error:
            assert "unsupported depth alignment platform" in str(error)
        else:
            raise AssertionError("Unknown device platform silently selected an alignment path")
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
            "running_service_source_sha256": service.RUNNING_SERVICE_SOURCE_SHA256,
            "rgb_output_undistorted": service.RGB_OUTPUT_UNDISTORTED,
            "depth_alignment_method": None,
            "rgb_source_size": None,
            "rgb_source_intrinsics": None,
            "rgb_image_transform": None,
            "imu": None,
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

    # Source/crop evidence is optional on old SDKs. Present geometry is checked
    # against the exact published K rather than an unrelated EEPROM crop.
    source_matrix = [[1250.0, 0.0, 7.5], [0.0, 1260.0, 2.5], [0.0, 0.0, 1.0]]
    transform_matrix = [[.1, 0.0, 0.0], [0.0, .1, 0.0], [0.0, 0.0, 1.0]]
    geometry_frame = FakeTransformedRGBFrame(cropped_matrix)
    geometry_frame.transformation = FakeSourceTransformation(cropped_matrix, [20, 10], source_matrix, transform_matrix)
    packet, *_ = service.frame_payload(geometry_frame, FakeDepthFrame(), left_source, right_source, intrinsics,
                                      depth_alignment_method="stereo_input_align_to")
    geometry_header = json.loads(packet)
    assert geometry_header["rgb_source_size"] == [20, 10]
    assert geometry_header["rgb_source_intrinsics"] == [item for row in source_matrix for item in row]
    assert geometry_header["rgb_image_transform"] == [item for row in transform_matrix for item in row]
    assert geometry_header["depth_alignment_method"] == "stereo_input_align_to"
    class FrameSink:
        def __init__(self): self.bytes = bytearray()
        def sendall(self, chunk): self.bytes.extend(chunk)
    sink = FrameSink()
    service.send_frame(sink, geometry_frame, FakeDepthFrame(), left_source, right_source, intrinsics,
                       depth_alignment_method="image_align")
    wire_header_length = struct.unpack(">I", sink.bytes[4:8])[0]
    wire_header = json.loads(sink.bytes[8:8+wire_header_length])
    assert wire_header["depth_alignment_method"] == "image_align"
    assert wire_header["rgb_source_size"] == [20, 10]
    assert sink.bytes[:4] == service.PROTOCOL_MAGIC
    # These are the actual measured RVC2 source/crop numbers. T @ K_source
    # explains the 488.826 frame focal length; the old 573.692 value is a
    # different framing, not an interchangeable replacement.
    actual_source = [[1032.6455078125, 0, 675.2777099609375],
                     [0, 1032.6455078125, 515.993896484375], [0, 0, 1]]
    actual_transform = [[.47337278723716736, 0, 0],
                        [0, .47337278723716736, -39.52662658691406], [0, 0, 1]]
    actual_frame = [[488.8262939453125, 0, 319.6580810546875],
                    [0, 488.8262939453125, 204.7308349609375], [0, 0, 1]]
    measured = FakeTransformedRGBFrame(actual_frame)
    measured.transformation = FakeSourceTransformation(actual_frame, [1352, 1012], actual_source, actual_transform)
    size, source_values, transform_values = service.rgb_frame_source_geometry(
        measured, [item for row in actual_frame for item in row])
    assert size == [1352, 1012]
    product = [sum(transform_values[row*3+k]*source_values[k*3+col] for k in range(3))
               for row in range(3) for col in range(3)]
    assert max(abs(a-b) for a, b in zip(product, [item for row in actual_frame for item in row])) < .00002
    assert service.rgb_frame_source_geometry(FakeRGBFrame(), intrinsics) == (None, None, None)
    assert service.rgb_frame_source_geometry(FakeTransformedRGBFrame(cropped_matrix), cropped_intrinsics) == (None, None, None)
    for bad_size in (None, [], [20], [20, 10, 1], [0, 10], [8193, 10], [20.5, 10], [True, 10], ["20", 10], [float("nan"), 10]):
        geometry_frame.transformation = FakeSourceTransformation(cropped_matrix, bad_size, source_matrix, transform_matrix)
        try:
            service.frame_payload(geometry_frame, FakeDepthFrame(), left_source, right_source, intrinsics)
        except RuntimeError as error:
            assert "invalid RGB source size" in str(error)
        else:
            raise AssertionError("Malformed present source dimensions were accepted")
    for component, bad_value in (("source", None), ("source", [[1, 0], [0, 1]]),
                                 ("source", [[1e7, 0, 7.5], [0, 1260, 2.5], [0, 0, 1]]),
                                 ("source", [[float("nan"), 0, 7.5], [0, 1260, 2.5], [0, 0, 1]]),
                                 ("transform", None), ("transform", [[0, 0, 0]]*3),
                                 ("transform", [[.1, 0, True], [0, .1, 0], [0, 0, 1]]),
                                 ("transform", [[.1, 0, float("inf")], [0, .1, 0], [0, 0, 1]]),
                                 ("transform", [[.2, 0, 0], [0, .1, 0], [0, 0, 1]])):
        geometry_frame.transformation = FakeSourceTransformation(cropped_matrix, [20, 10],
            bad_value if component == "source" else source_matrix,
            bad_value if component == "transform" else transform_matrix)
        try:
            service.frame_payload(geometry_frame, FakeDepthFrame(), left_source, right_source, intrinsics)
        except RuntimeError as error:
            assert "invalid RGB" in str(error)
        else:
            raise AssertionError("Malformed or inconsistent source geometry was accepted")
    for alignment_method in ("image_align", "stereo_input_align_to"):
        packet, *_ = service.frame_payload(FakeRGBFrame(), FakeDepthFrame(), left_source, right_source,
                                          intrinsics, depth_alignment_method=alignment_method)
        assert json.loads(packet)["depth_alignment_method"] == alignment_method
    try:
        service.frame_payload(FakeRGBFrame(), FakeDepthFrame(), left_source, right_source,
                              intrinsics, depth_alignment_method="unknown")
    except RuntimeError as error:
        assert "invalid depth alignment method" in str(error)
    else:
        raise AssertionError("Unknown alignment provenance was published")

    # Independent inertial evidence is feature gated and optional. Raw proper
    # acceleration retains its magnitude/sign; it is never normalized to 9.81
    # or silently described as fused orientation or actuator authorization.
    rotation = [1., 0., 0., 0., -1., 0., 0., 0., -1.]
    class SensorReport:
        def __init__(self, seconds, vector): self.seconds = seconds; self.x, self.y, self.z = vector
        def getTimestamp(self): return timedelta(seconds=self.seconds)
    class SensorPacket:
        def __init__(self, seconds, acceleration=(0., 6.7, 6.8), gyro=(.001, -.002, .003)):
            self.acceleroMeter = SensorReport(seconds, acceleration)
            self.gyroscope = SensorReport(seconds, gyro)
    class SensorMessage:
        def __init__(self, packets): self.packets = packets
    class SensorQueue:
        def __init__(self, messages=()): self.messages = list(messages); self.reads = 0
        def tryGet(self):
            self.reads += 1
            return self.messages.pop(0) if self.messages else None
    class SensorRGB(FakeRGBFrame):
        def getTimestamp(self): return timedelta(seconds=10.6)
    steady = service.IMUDiagnosticWindow("BNO086", rotation)
    steady.ingest(SensorMessage([SensorPacket(10+i*.01) for i in range(60)]))
    observation = steady.snapshot(10_600_000_000)
    assert observation["stationary"] is True
    assert observation["gravity_source"] == "stationary_accelerometer_mean"
    assert observation["axes"] == "sensor_native"
    assert abs(observation["gravity_mps2"][1]-6.7) < 1e-10
    assert abs(sum(x*x for x in observation["gravity_mps2"])**.5-9.546203434) < 1e-8
    assert observation["gravity_mps2"] == observation["acceleration_mps2"]
    assert observation["imu_to_rgb_rotation"] == rotation
    assert observation["sample_count"] == 50 and observation["window_milliseconds"] == 490
    assert observation["age_milliseconds"] == 10
    # Future and repeated packets cannot replace the RGB-time-aligned window.
    steady.ingest(SensorMessage([SensorPacket(10.59), SensorPacket(10.1), SensorPacket(11.)]))
    assert steady.snapshot(10_600_000_000) == observation
    assert steady.snapshot(11_000_000_000)["stationary"] is False
    assert steady.snapshot(12_000_000_000) is None
    for moving_packets in ([SensorPacket(10+i*.01, gyro=(.1, 0., 0.)) for i in range(60)],
                           [SensorPacket(10+i*.01, acceleration=(0., 6.7+(.4 if i%2 else -.4), 6.8)) for i in range(60)]):
        moving = service.IMUDiagnosticWindow("BNO086", rotation)
        moving.ingest(SensorMessage(moving_packets))
        assert moving.snapshot(10_600_000_000)["stationary"] is False
    assert service.read_optional_imu(None, None, SensorRGB()) is None
    faulted = service.IMUDiagnosticWindow("BNO086", rotation)
    fault_queue = SensorQueue([SensorMessage([SensorPacket(10.5, acceleration=(float("nan"), 0., 9.8))])])
    with contextlib.redirect_stdout(io.StringIO()) as diagnostics:
        assert service.read_optional_imu(fault_queue, faulted, SensorRGB()) is None
        assert service.read_optional_imu(fault_queue, faulted, SensorRGB()) is None
    assert faulted.failed and fault_queue.reads == 1
    assert diagnostics.getvalue().count("RGB-D continues") == 1
    queue = SensorQueue([SensorMessage([SensorPacket(10+i*.01) for i in range(60)])])
    from_queue = service.read_optional_imu(queue, service.IMUDiagnosticWindow("BNO086", rotation), SensorRGB())
    assert from_queue == observation
    packet, *_ = service.frame_payload(FakeRGBFrame(), FakeDepthFrame(), left_source, right_source,
                                      intrinsics, imu_telemetry=observation)
    assert json.loads(packet)["imu"] == observation
    sink = FrameSink()
    service.send_frame(sink, FakeRGBFrame(), FakeDepthFrame(), left_source, right_source,
                       intrinsics, imu_telemetry=observation)
    length = struct.unpack(">I", sink.bytes[4:8])[0]
    assert json.loads(sink.bytes[8:8+length])["imu"] == observation
    for key, bad in (("gravity_mps2", [float("nan"), 0, 9.8]), ("gyro_rad_s", [0, 0]),
                     ("sample_count", 0), ("sample_count", True), ("window_milliseconds", 1001),
                     ("latest_timestamp_ns", -1), ("reference_timestamp_ns", 1),
                     ("age_milliseconds", 251), ("age_milliseconds", 11),
                     ("gravity_std_mps2", [-1, 0, 0]), ("stationary", "yes"),
                     ("axes", "world"), ("gravity_source", "fused_attitude"),
                     ("imu_to_rgb_rotation", [1, 0, 0, 0, 1, 0, 0, 0, -1])):
        malformed_imu = dict(observation); malformed_imu[key] = bad
        try:
            service.frame_payload(FakeRGBFrame(), FakeDepthFrame(), left_source, right_source,
                                  intrinsics, imu_telemetry=malformed_imu)
        except RuntimeError as error:
            assert "invalid IMU" in str(error)
        else:
            raise AssertionError("Malformed IMU evidence reached the wire")
    class SensorDevice:
        def __init__(self, sensor): self.sensor = sensor
        def getConnectedIMU(self): return self.sensor
    class SensorCalibration:
        def getImuToCameraExtrinsics(self, socket):
            assert socket == "rgb"
            return [[1, 0, 0, 3.7948], [0, -1, 0, .079], [0, 0, -1, -.2], [0, 0, 0, 1]]
    class SensorOutput:
        def createOutputQueue(self, maxSize, blocking):
            assert maxSize == 20 and blocking is False
            return SensorQueue()
    class SensorNode:
        def __init__(self): self.out = SensorOutput()
        def enableIMUSensor(self, sensors, rate): self.sensors = sensors; self.rate = rate
        def setBatchReportThreshold(self, value): self.threshold = value
        def setMaxBatchReports(self, value): self.batch = value
    class SensorPipeline:
        def __init__(self): self.created = []; self.removed = []
        def create(self, kind):
            assert kind is SensorNode
            node = SensorNode(); self.created.append(node); return node
        def remove(self, node): self.removed.append(node)
    class SensorKinds: ACCELEROMETER_RAW = "raw_acceleration"; GYROSCOPE_RAW = "raw_gyro"
    class SensorNodes: IMU = SensorNode
    class SensorDai: node = SensorNodes; IMUSensor = SensorKinds
    pipeline = SensorPipeline()
    with contextlib.redirect_stdout(io.StringIO()):
        queue, window = service.configure_optional_imu(pipeline, SensorDai, SensorDevice("BNO086"), SensorCalibration(), "rgb")
    assert queue is not None and window is not None and len(pipeline.created) == 1
    assert pipeline.created[0].sensors == ["raw_acceleration", "raw_gyro"]
    assert pipeline.created[0].rate == 100 and pipeline.created[0].threshold == 5 and pipeline.created[0].batch == 20
    for device in (SensorDevice("BMI270"), object()):
        pipeline = SensorPipeline()
        with contextlib.redirect_stdout(io.StringIO()):
            assert service.configure_optional_imu(pipeline, SensorDai, device, SensorCalibration(), "rgb") == (None, None)
        assert not pipeline.created
    pipeline = SensorPipeline()
    with contextlib.redirect_stdout(io.StringIO()):
        assert service.configure_optional_imu(pipeline, SensorDai, SensorDevice("BNO086"), object(), "rgb") == (None, None)
        assert service.configure_optional_imu(pipeline, SensorDai, SensorDevice("BNO086"), SensorCalibration(), "rgb", disabled=True) == (None, None)
    assert not pipeline.created
    class FailingSensorNode(SensorNode):
        def enableIMUSensor(self, sensors, rate): raise RuntimeError("sensor firmware unavailable")
    class FailingSensorPipeline(SensorPipeline):
        def create(self, kind):
            assert kind is SensorNode
            node = FailingSensorNode(); self.created.append(node); return node
    pipeline = FailingSensorPipeline()
    with contextlib.redirect_stdout(io.StringIO()) as diagnostics:
        assert service.configure_optional_imu(pipeline, SensorDai, SensorDevice("BNO086"), SensorCalibration(), "rgb") == (None, None)
    assert pipeline.removed == pipeline.created and len(pipeline.removed) == 1
    assert "initialization_failed" in diagnostics.getvalue()

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
