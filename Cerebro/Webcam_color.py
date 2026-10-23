#!/usr/bin/env python3
"""Supervised Luxonis RGB-D service for Cerebro.

The service intentionally runs outside the Cerebro process.  It owns the
DepthAI device connection, aligns depth to the RGB stream, and sends framed
RGB-D messages to one local Unix-domain-socket client at a time.  Device and
SDK failures are reported and retried instead of terminating the service.
"""

import argparse
from collections import deque
from datetime import timedelta
import fcntl
import json
import math
import time
import os
import select
import signal
import socket
import stat
import struct
import threading


PROTOCOL_MAGIC = b"CDP1"
PROTOCOL_VERSION = 2
FRAME_SIZE = (640, 400)
FRAME_RATE = 30.0
DEVICE_RECONNECT_ATTEMPTS = 3
INITIAL_RETRY_DELAY_SECONDS = 0.5
MAX_RETRY_DELAY_SECONDS = 8.0
QUEUE_WAIT = timedelta(milliseconds=500)
SYNC_THRESHOLD = timedelta(milliseconds=20)
CLIENT_SEND_TIMEOUT_SECONDS = 5.0
IMU_DISABLED_AFTER_START_FAILURE = set()


def emit(line):
    print(line, flush=True)


def emit_error(message):
    # Status records are line-oriented, so keep SDK messages on one line.
    text = " ".join(str(message).split()) or "unknown error"
    emit("CEREBRO_DEPTHCAM_ERROR " + text)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Stream synchronized Luxonis RGB and aligned depth to Cerebro."
    )
    parser.add_argument(
        "--socket",
        required=True,
        dest="socket_path",
        help="Unix-domain socket path owned by this service.",
    )
    parser.add_argument(
        "--parent-pid",
        type=int,
        default=os.getppid(),
        help="Cerebro process ID; the helper exits if this process disappears.",
    )
    parser.add_argument(
        "--mxid",
        type=str,
        default=None,
        help="Serial number (MxId) of the specific Luxonis device to connect to.",
    )
    parser.add_argument(
        "--role",
        type=str,
        default="face",
        choices=["face", "belly"],
        help="The camera service role (face or belly).",
    )
    parser.add_argument(
        "--model-name",
        type=str,
        default="chess",
        help="The active custom spatial model project name (e.g. chess, monopoly).",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=1280,
        help="Main video stream width.",
    )
    parser.add_argument(
        "--height",
        type=int,
        default=720,
        help="Main video stream height.",
    )
    return parser.parse_args()


def normalized_socket_path(argument):
    # Make relative paths unambiguous without resolving macOS aliases such as
    # /tmp -> /private/tmp; the READY record must echo the caller's exact path.
    return os.path.abspath(os.path.expanduser(argument))


def remove_stale_socket(path):
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return

    if not stat.S_ISSOCK(metadata.st_mode):
        raise RuntimeError("socket path exists and is not a socket: " + path)
    os.unlink(path)


def acquire_service_lock(socket_path):
    lock_path = socket_path + ".lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    
    # Try up to 5 times with a 0.5s delay to handle startup races with old shutting-down instances
    for attempt in range(6):
        descriptor = os.open(lock_path, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return descriptor
        except BlockingIOError as error:
            os.close(descriptor)
            if attempt < 5:
                import time
                time.sleep(0.5)
                continue
            raise RuntimeError("another DepthAI service already owns this socket") from error
        except BaseException:
            os.close(descriptor)
            raise


def release_service_lock(descriptor):
    if descriptor is None:
        return
    try:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def create_server(path):
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        raise RuntimeError("socket directory does not exist: " + parent)

    remove_stale_socket(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    identity = None
    try:
        server.bind(path)
        owned = os.lstat(path)
        identity = (owned.st_dev, owned.st_ino)
        os.chmod(path, 0o600)
        server.listen(1)
        server.settimeout(1.0)
        return server, identity
    except BaseException:
        server.close()
        if identity is not None:
            remove_owned_socket(path, identity)
        raise


def remove_owned_socket(path, identity):
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return
    if (
        stat.S_ISSOCK(metadata.st_mode)
        and (metadata.st_dev, metadata.st_ino) == identity
    ):
        os.unlink(path)


def load_depthai():
    import depthai as dai

    if str(getattr(dai, "__version__", "")) != "3.8.0":
        raise RuntimeError(
            "DepthAI 3.8.0 is required; found "
            + str(getattr(dai, "__version__", "unknown"))
        )
    return dai


def color_camera_socket(device, dai):
    for feature in device.getConnectedCameraFeatures():
        if dai.CameraSensorType.COLOR in feature.supportedTypes:
            return feature.socket
    raise RuntimeError("connected Luxonis device has no color camera")


def timestamp_nanoseconds(frame):
    timestamp = frame.getTimestamp()
    return (
        timestamp.days * 86_400_000_000_000
        + timestamp.seconds * 1_000_000_000
        + timestamp.microseconds * 1_000
    )


def capture_time_milliseconds(frames, clock_now, wall_seconds):
    # getTimestamp() is synchronized to the SDK's host Clock. Convert in this
    # process instead of assuming Swift uptime has the same clock epoch.
    oldest = min(frame.getTimestamp() for frame in frames)
    age_seconds = (clock_now - oldest).total_seconds()
    if not math.isfinite(age_seconds) or age_seconds < 0:
        return None
    return (wall_seconds - age_seconds) * 1000


def configure_latest_input(node_input, size=2):
    # Bound every processing input, not only the final host output queue.
    # DepthAI 3.8 Node.Input uses setMaxSize (not the v2 setQueueSize).
    node_input.setMaxSize(size)
    node_input.setBlocking(False)


def configure_rgb_depth_alignment(pipeline, dai, platform, stereo, rgb_output):
    """Use the SDK's documented alignment path for each device platform.

    RVC2/RVC3 align in StereoDepth; RVC4 uses ImageAlign. This selects pixel
    correspondence only: it never changes focal length, baseline or depth scale.
    """
    stereo_platforms = [getattr(dai.Platform, name, None) for name in ("RVC2", "RVC3")]
    if platform is not None and platform in [value for value in stereo_platforms if value is not None]:
        configure_latest_input(stereo.inputAlignTo)
        rgb_output.link(stereo.inputAlignTo)
        return stereo.depth, "stereo_input_align_to"
    if platform == getattr(dai.Platform, "RVC4", None) and platform is not None:
        align = pipeline.create(dai.node.ImageAlign)
        configure_latest_input(align.input)
        configure_latest_input(align.inputAlignTo)
        stereo.depth.link(align.input)
        rgb_output.link(align.inputAlignTo)
        return align.outputAligned, "image_align"
    raise RuntimeError("unsupported depth alignment platform: " + str(platform))


def validated_imu_rotation(values):
    try:
        if len(values) != 9 or any(isinstance(value, (bool, str, bytes)) for value in values):
            raise ValueError("expected nine numeric rotation values")
        r = [float(value) for value in values]
        if not all(math.isfinite(value) and abs(value) <= 1.01 for value in r):
            raise ValueError("rotation must be finite and bounded")
        for row in range(3):
            for other in range(3):
                dot = sum(r[row*3+k]*r[other*3+k] for k in range(3))
                if abs(dot-(1 if row == other else 0)) > .01:
                    raise ValueError("rotation must be orthonormal")
        determinant = r[0]*(r[4]*r[8]-r[5]*r[7])-r[1]*(r[3]*r[8]-r[5]*r[6])+r[2]*(r[3]*r[7]-r[4]*r[6])
        if abs(determinant-1) > .01:
            raise ValueError("rotation must have determinant +1")
        return r
    except (TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid IMU rotation: " + str(error)) from error


def validated_imu_telemetry(value):
    """Validate optional diagnostic sensor evidence, never actuator authority."""
    if value is None:
        return None
    try:
        if not isinstance(value, dict) or not isinstance(value["sensor"], str) or not value["sensor"].startswith("BNO08"):
            raise ValueError("expected a supported sensor label")
        if value["gravity_source"] != "stationary_accelerometer_mean" or value["axes"] != "sensor_native":
            raise ValueError("unknown vector semantics")
        for key in ("gravity_mps2", "acceleration_mps2", "gyro_rad_s", "gravity_std_mps2"):
            vector = value[key]
            if len(vector) != 3 or any(isinstance(item, (bool, str, bytes)) for item in vector):
                raise ValueError("expected three numeric vector values")
            if not all(math.isfinite(float(item)) and abs(float(item)) <= 100 for item in vector):
                raise ValueError("vector is nonfinite or outside sensor bounds")
        if any(item < 0 for item in value["gravity_std_mps2"]):
            raise ValueError("standard deviation must be nonnegative")
        for key in ("sample_count", "latest_timestamp_ns", "reference_timestamp_ns"):
            if isinstance(value[key], bool) or not isinstance(value[key], int):
                raise ValueError("count and timestamps must be integers")
        if not 1 <= value["sample_count"] <= 1000:
            raise ValueError("sample count is outside bounds")
        if not 0 <= value["latest_timestamp_ns"] <= value["reference_timestamp_ns"] <= 2**63-1:
            raise ValueError("timestamps must share the ordered RGB host-clock domain")
        for key, maximum in (("window_milliseconds", 1000), ("age_milliseconds", 250)):
            number = value[key]
            if isinstance(number, (bool, str, bytes)) or not math.isfinite(float(number)) or not 0 <= number <= maximum:
                raise ValueError("sample timing is outside bounds")
        expected_age = (value["reference_timestamp_ns"]-value["latest_timestamp_ns"])/1_000_000
        if abs(value["age_milliseconds"]-expected_age) > .001:
            raise ValueError("sample age disagrees with timestamps")
        if not isinstance(value["stationary"], bool):
            raise ValueError("stationary quality must be Boolean")
        validated_imu_rotation(value["imu_to_rgb_rotation"])
        return value
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid IMU telemetry: " + str(error)) from error


class IMUDiagnosticWindow:
    """Half-second raw sensor window in DepthAI's synchronized host clock.

    The accelerometer mean is proper acceleration in native sensor axes. Its
    sign relative to gravity is intentionally not inferred. Only stationary
    observations can be interpreted as a gravity-direction diagnostic.
    """
    def __init__(self, sensor, imu_to_rgb_rotation):
        self.sensor = sensor
        self.rotation = validated_imu_rotation(imu_to_rgb_rotation)
        self.acceleration = deque(maxlen=200)
        self.gyro = deque(maxlen=200)
        self.failed = False

    def ingest(self, message):
        for packet in message.packets:
            for name, samples in (("acceleroMeter", self.acceleration), ("gyroscope", self.gyro)):
                report = getattr(packet, name)
                timestamp = timestamp_nanoseconds(report)
                if timestamp <= 0 or (samples and timestamp <= samples[-1][0]):
                    continue
                raw = [report.x, report.y, report.z]
                if any(isinstance(value, (bool, str, bytes)) for value in raw):
                    raise RuntimeError("invalid IMU report vector")
                vector = [float(value) for value in raw]
                if not all(math.isfinite(value) and abs(value) <= 100 for value in vector):
                    raise RuntimeError("invalid IMU report vector")
                samples.append((timestamp, vector))

    def snapshot(self, reference_timestamp_ns):
        beginning = reference_timestamp_ns-500_000_000
        acceleration = [(stamp, vector) for stamp, vector in self.acceleration if beginning <= stamp <= reference_timestamp_ns]
        gyro = [(stamp, vector) for stamp, vector in self.gyro if beginning <= stamp <= reference_timestamp_ns]
        if not acceleration or not gyro:
            return None
        latest = min(acceleration[-1][0], gyro[-1][0])
        age = (reference_timestamp_ns-latest)/1_000_000
        if age > 250:
            return None
        count = len(acceleration)
        mean = [math.fsum(vector[axis] for _, vector in acceleration)/count for axis in range(3)]
        deviation = [math.sqrt(math.fsum((vector[axis]-mean[axis])**2 for _, vector in acceleration)/count) for axis in range(3)]
        gyro_mean = [math.fsum(vector[axis] for _, vector in gyro)/len(gyro) for axis in range(3)]
        maximum_gyro_norm = max(math.sqrt(sum(item*item for item in vector)) for _, vector in gyro)
        magnitude = math.sqrt(sum(item*item for item in mean))
        window = (acceleration[-1][0]-acceleration[0][0])/1_000_000
        def covered(samples):
            return len(samples) >= 10 and all(second[0]-first[0] <= 50_000_000 for first, second in zip(samples, samples[1:]))
        stationary = covered(acceleration) and covered(gyro) and window >= 100 and 8 <= magnitude <= 12 and max(deviation) <= .15 and maximum_gyro_norm < .03
        return validated_imu_telemetry({"sensor": self.sensor, "gravity_source": "stationary_accelerometer_mean",
            "axes": "sensor_native", "gravity_mps2": mean, "acceleration_mps2": mean,
            "gyro_rad_s": gyro_mean, "sample_count": count, "window_milliseconds": window,
            "latest_timestamp_ns": latest, "reference_timestamp_ns": reference_timestamp_ns,
            "age_milliseconds": age, "gravity_std_mps2": deviation,
            "imu_to_rgb_rotation": self.rotation, "stationary": stationary})


def configure_optional_imu(pipeline, dai, device, calibration, rgb_socket, disabled=False):
    """Feature-gated BNO08x raw telemetry; unavailable IMU leaves RGB-D intact."""
    node = None
    try:
        if disabled:
            emit("CEREBRO_DEPTHCAM_IMU unavailable=disabled_after_pipeline_start_failure")
            return None, None
        get_sensor = getattr(device, "getConnectedIMU", None)
        sensor = str(get_sensor()) if callable(get_sensor) else "unavailable"
        if not sensor.startswith("BNO08"):
            emit("CEREBRO_DEPTHCAM_IMU unavailable=unsupported_sensor sensor=" + sensor)
            return None, None
        extrinsics = calibration.getImuToCameraExtrinsics(rgb_socket)
        if len(extrinsics) != 4 or any(len(row) != 4 for row in extrinsics):
            raise RuntimeError("missing factory IMU-to-RGB rotation")
        window = IMUDiagnosticWindow(sensor, [extrinsics[row][column] for row in range(3) for column in range(3)])
        sensors = [dai.IMUSensor.ACCELEROMETER_RAW, dai.IMUSensor.GYROSCOPE_RAW]
        node = pipeline.create(dai.node.IMU)
        node.enableIMUSensor(sensors, 100)
        node.setBatchReportThreshold(5)
        node.setMaxBatchReports(20)
        queue = node.out.createOutputQueue(maxSize=20, blocking=False)
        emit("CEREBRO_DEPTHCAM_IMU sensor={} rate_hz=100 source=stationary_accelerometer_mean axes=sensor_native".format(sensor))
        return queue, window
    except Exception as error:
        if node is not None:
            try:
                pipeline.remove(node)
            except Exception as removal_error:
                emit_error("Unable to remove unavailable optional IMU: " + str(removal_error))
        emit("CEREBRO_DEPTHCAM_IMU unavailable=initialization_failed reason=" + " ".join(str(error).split()))
        return None, None


def read_optional_imu(queue, window, rgb_frame):
    if queue is None or window is None or window.failed:
        return None
    try:
        for _ in range(20):
            message = queue.tryGet()
            if message is None:
                break
            window.ingest(message)
        return window.snapshot(timestamp_nanoseconds(rgb_frame))
    except Exception as error:
        window.failed = True
        emit_error("Optional IMU telemetry unavailable; RGB-D continues: " + str(error))
        return None


def frame_timing(rgb, depth, clock_now):
    return {
        "rgb_age_ms": round((clock_now - rgb.getTimestamp()).total_seconds() * 1000, 1),
        "depth_age_ms": round((clock_now - depth.getTimestamp()).total_seconds() * 1000, 1),
        "sync_skew_ms": round(abs((rgb.getTimestamp() - depth.getTimestamp()).total_seconds()) * 1000, 1),
    }


def validated_pinhole_intrinsics(matrix, width, height, flattened=False):
    """Validate K for the exact pixels being published, then flatten row-major."""
    try:
        if width <= 0 or height <= 0:
            raise ValueError("nonpositive frame dimensions")
        if flattened:
            if len(matrix) != 9:
                raise ValueError("expected nine intrinsic values")
            values = list(matrix)
        else:
            if len(matrix) != 3 or any(len(row) != 3 for row in matrix):
                raise ValueError("expected a 3x3 intrinsic matrix")
            values = [value for row in matrix for value in row]
        if any(isinstance(value, (bool, str, bytes)) for value in values):
            raise ValueError("intrinsics must be numeric")
        values = [float(value) for value in values]
        if not all(math.isfinite(value) for value in values):
            raise ValueError("intrinsics must be finite")
        if not (values[0] > 0 and values[4] > 0
                and 0 <= values[2] < width and 0 <= values[5] < height):
            raise ValueError("invalid focal lengths or principal point")
        if (any(abs(values[index]) > 1e-6 for index in (1, 3, 6, 7))
                or abs(values[8] - 1) > 1e-6):
            raise ValueError("intrinsics are not a pinhole camera matrix")
    except (TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid RGB camera intrinsics: " + str(error)) from error
    return values


def rgb_frame_intrinsics(rgb_frame, nominal_intrinsics, width, height):
    """Prefer per-frame K, which includes the Camera node's crop/resize transform.

    Older frames without transformation metadata may use EEPROM-derived K, but
    that fallback is explicitly identified on the wire. Present-but-invalid
    metadata is an error, never a reason to publish the nominal calibration.
    """
    get_transform = getattr(rgb_frame, "getTransformation", None)
    if get_transform is not None:
        if not callable(get_transform):
            raise RuntimeError("invalid RGB frame transformation accessor")
        transform = get_transform()
        if transform is not None:
            get_matrix = getattr(transform, "getIntrinsicMatrix", None)
            if get_matrix is not None:
                if not callable(get_matrix):
                    raise RuntimeError("invalid RGB frame intrinsic accessor")
                matrix = get_matrix()
                return (validated_pinhole_intrinsics(matrix, width, height),
                        "transformed_frame")
    return (validated_pinhole_intrinsics(nominal_intrinsics, width, height,
                                         flattened=True),
            "legacy_eeprom")


def rgb_frame_source_geometry(rgb_frame, published_intrinsics):
    """Optional source/crop evidence, without guessing absent SDK metadata."""
    get_transform = getattr(rgb_frame, "getTransformation", None)
    if get_transform is None:
        return None, None, None
    if not callable(get_transform):
        raise RuntimeError("invalid RGB frame transformation accessor")
    transform = get_transform()
    if transform is None:
        return None, None, None
    unavailable = object()

    def optional(name):
        getter = getattr(transform, name, None)
        if getter is None:
            return unavailable
        if not callable(getter):
            raise RuntimeError("invalid RGB source geometry accessor: " + name)
        return getter()

    def matrix_values(value, name):
        try:
            if len(value) != 3 or any(len(row) != 3 for row in value):
                raise ValueError("expected a 3x3 matrix")
            values = [item for row in value for item in row]
            if any(isinstance(item, (bool, str, bytes)) for item in values):
                raise ValueError("matrix must be numeric")
            values = [float(item) for item in values]
            if not all(math.isfinite(item) and abs(item) <= 1_000_000 for item in values):
                raise ValueError("matrix must be finite and bounded")
            return values
        except (TypeError, ValueError, OverflowError) as error:
            raise RuntimeError("invalid RGB " + name + ": " + str(error)) from error

    source_size = optional("getSourceSize")
    if source_size is not unavailable:
        try:
            if len(source_size) != 2:
                raise ValueError("expected width and height")
            if any(isinstance(item, (bool, str, bytes)) for item in source_size):
                raise ValueError("dimensions must be numeric")
            numbers = [float(item) for item in source_size]
            if not all(math.isfinite(item) and item.is_integer() and 1 <= item <= 8192 for item in numbers):
                raise ValueError("source dimensions must be integers from 1 to 8192")
            source_size = [int(item) for item in numbers]
        except (TypeError, ValueError, OverflowError) as error:
            raise RuntimeError("invalid RGB source size: " + str(error)) from error
    else:
        source_size = None
    source_matrix = optional("getSourceIntrinsicMatrix")
    source_intrinsics = None
    if source_matrix is not unavailable:
        source_intrinsics = matrix_values(source_matrix, "source intrinsics")
        size = source_size if source_size is not None else [8192, 8192]
        source_intrinsics = validated_pinhole_intrinsics(source_intrinsics, *size, flattened=True)
    image_matrix = optional("getMatrix")
    image_transform = None
    if image_matrix is not unavailable:
        image_transform = matrix_values(image_matrix, "image transform")
        a, b, c, d, e, f, g, h, i = image_transform
        determinant = a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
        if not math.isfinite(determinant) or abs(determinant) <= 1e-12:
            raise RuntimeError("invalid RGB image transform: singular matrix")
    if source_intrinsics is not None and image_transform is not None:
        product = [sum(image_transform[row*3+k]*source_intrinsics[k*3+column] for k in range(3))
                   for row in range(3) for column in range(3)]
        if not all(math.isclose(actual, expected, rel_tol=1e-5, abs_tol=1e-3)
                   for actual, expected in zip(product, published_intrinsics)):
            raise RuntimeError("invalid RGB source geometry: transform times source K disagrees with frame K")
    return source_size, source_intrinsics, image_transform


def validated_lens_position(value, name):
    """Return an optional integer lens position without rounding or guessing."""
    if value is None:
        return None
    try:
        if isinstance(value, (bool, str, bytes)):
            raise ValueError("lens position must be numeric")
        numeric = float(value)
        if not math.isfinite(numeric) or not numeric.is_integer() or not 0 <= numeric <= 255:
            raise ValueError("lens position must be an integer from 0 to 255")
        return int(numeric)
    except (TypeError, ValueError, OverflowError) as error:
        raise RuntimeError("invalid " + name + " lens position: " + str(error)) from error


def configure_rgb_calibrated_focus(rgb_camera, calibration, rgb_socket):
    """Match RGB focus to the EEPROM calibration used for depth alignment.

    Luxonis's aligned RGB/depth example fixes focus to this surveyed setting.
    Missing calibration remains explicitly unavailable; EEPROM is never edited.
    """
    get_position = getattr(calibration, "getLensPosition", None)
    if get_position is None:
        return None
    if not callable(get_position):
        raise RuntimeError("invalid RGB calibrated lens-position accessor")
    try:
        value = get_position(rgb_socket)
    except Exception as error:
        emit_error("RGB focus calibration unavailable; leaving focus unchanged: " + str(error))
        return None
    position = validated_lens_position(value, "RGB calibrated")
    if position is not None:
        rgb_camera.initialControl.setManualFocus(position)
    return position


def rgb_frame_lens_position(rgb_frame):
    get_position = getattr(rgb_frame, "getLensPosition", None)
    if get_position is None:
        return None
    if not callable(get_position):
        raise RuntimeError("invalid RGB frame lens-position accessor")
    return validated_lens_position(get_position(), "RGB frame")


def frame_payload(
    rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
    sidewalk_deviation=None, sidewalk_confidence=None, chess_pieces=None,
    captured_at_milliseconds=None, rgb_calibrated_lens_position=None,
    depth_alignment_method=None, imu_telemetry=None
):
    rgb_width = int(rgb_frame.getWidth())
    rgb_height = int(rgb_frame.getHeight())
    depth_width = int(depth_frame.getWidth())
    depth_height = int(depth_frame.getHeight())
    frame_intrinsics, intrinsics_source = rgb_frame_intrinsics(
        rgb_frame, rgb_intrinsics, rgb_width, rgb_height
    )
    source_size, source_intrinsics, image_transform = rgb_frame_source_geometry(
        rgb_frame, frame_intrinsics
    )
    if depth_alignment_method not in (None, "stereo_input_align_to", "image_align"):
        raise RuntimeError("invalid depth alignment method")
    imu_telemetry = validated_imu_telemetry(imu_telemetry)
    calibrated_lens_position = validated_lens_position(
        rgb_calibrated_lens_position, "RGB calibrated"
    )
    frame_lens_position = rgb_frame_lens_position(rgb_frame)

    rgb_bytes = memoryview(rgb_frame.getData()).tobytes()
    expected_rgb_length = rgb_width * rgb_height * 3
    if len(rgb_bytes) != expected_rgb_length:
        raise RuntimeError(
            "unexpected RGB byte count: expected {}, received {}".format(
                expected_rgb_length, len(rgb_bytes)
            )
        )

    # RAW16 arrives as native uint16 values.  Converting through NumPy's
    # explicit little-endian dtype keeps the wire contract portable.
    depth_native = depth_frame.getFrame()
    if depth_native.size != depth_width * depth_height:
        raise RuntimeError(
            "unexpected depth sample count: expected {}, received {}".format(
                depth_width * depth_height, depth_native.size
            )
        )
    depth_bytes = depth_native.astype("<u2", copy=False).tobytes(order="C")

    left_bytes = memoryview(left_frame.getData()).tobytes()
    right_bytes = memoryview(right_frame.getData()).tobytes()
    mono_width = int(left_frame.getWidth())
    mono_height = int(left_frame.getHeight())
    expected_mono_length = mono_width * mono_height
    if (len(left_bytes) != expected_mono_length or
            len(right_bytes) != expected_mono_length or
            int(right_frame.getWidth()) != mono_width or
            int(right_frame.getHeight()) != mono_height):
        raise RuntimeError("unexpected rectified stereo frame dimensions")

    header = {
        "protocol_version": PROTOCOL_VERSION,
        "sequence": int(rgb_frame.getSequenceNum()),
        "timestamp_ns": timestamp_nanoseconds(rgb_frame),
        "captured_at_milliseconds": captured_at_milliseconds,
        "rgb_width": rgb_width,
        "rgb_height": rgb_height,
        "rgb_format": "RGB888",
        "rgb_length": len(rgb_bytes),
        "depth_width": depth_width,
        "depth_height": depth_height,
        "depth_format": "DEPTH16LE",
        "depth_unit": "millimeter",
        "depth_length": len(depth_bytes),
        "stereo_width": mono_width,
        "stereo_height": mono_height,
        "stereo_format": "GRAY8",
        "left_length": len(left_bytes),
        "right_length": len(right_bytes),
        "rgb_intrinsics": frame_intrinsics,
        "rgb_intrinsics_source": intrinsics_source,
        "depth_alignment_method": depth_alignment_method,
        "rgb_source_size": source_size,
        "rgb_source_intrinsics": source_intrinsics,
        "rgb_image_transform": image_transform,
        "imu": imu_telemetry,
        "rgb_calibrated_lens_position": calibrated_lens_position,
        "rgb_frame_lens_position": frame_lens_position,
        "sidewalk_center_deviation": sidewalk_deviation,
        "sidewalk_confidence": sidewalk_confidence,
        "chess_pieces": chess_pieces or [],
    }
    header_bytes = json.dumps(
        header, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    return header_bytes, rgb_bytes, depth_bytes, left_bytes, right_bytes


def send_frame(
    client, rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
    sidewalk_deviation=None, sidewalk_confidence=None, chess_pieces=None,
    captured_at_milliseconds=None, rgb_calibrated_lens_position=None,
    depth_alignment_method=None, imu_telemetry=None
):
    header, rgb_bytes, depth_bytes, left_bytes, right_bytes = frame_payload(
        rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
        sidewalk_deviation, sidewalk_confidence, chess_pieces, captured_at_milliseconds,
        rgb_calibrated_lens_position, depth_alignment_method, imu_telemetry
    )
    client.sendall(PROTOCOL_MAGIC + struct.pack(">I", len(header)) + header)
    client.sendall(rgb_bytes)
    client.sendall(depth_bytes)
    client.sendall(left_bytes)
    client.sendall(right_bytes)


FACE_MODEL_MANIFEST_VERSION = 1
FACE_MODEL_PARSER_TYPE = "depthai_yolo_spatial_v1"
FACE_DETECTION_TTL_SECONDS = 0.75
FACE_MODEL_MANIFEST_KEYS = {
    "manifest_version",
    "model_stem",
    "parser_type",
    "labels",
    "num_classes",
    "input_width",
    "input_height",
    "coordinate_size",
    "confidence_threshold",
    "iou_threshold",
}


def load_face_model_manifest(blob_path):
    manifest_path = os.path.splitext(blob_path)[0] + ".json"
    if not os.path.isfile(manifest_path):
        emit_error("Face model manifest not found; disabling NN: " + manifest_path)
        return None

    try:
        with open(manifest_path, "r", encoding="utf-8") as stream:
            manifest = json.load(stream)
        if not isinstance(manifest, dict) or set(manifest) != FACE_MODEL_MANIFEST_KEYS:
            raise ValueError("manifest keys do not match schema version 1")
        if manifest["manifest_version"] != FACE_MODEL_MANIFEST_VERSION:
            raise ValueError("unsupported manifest version")
        expected_stem = os.path.splitext(os.path.basename(blob_path))[0]
        if manifest["model_stem"] != expected_stem:
            raise ValueError("model_stem does not match blob filename")
        if manifest["parser_type"] != FACE_MODEL_PARSER_TYPE:
            raise ValueError("unsupported parser_type")

        labels = manifest["labels"]
        if not isinstance(labels, list) or not labels:
            raise ValueError("labels must be a nonempty array")
        if any(
            not isinstance(label, str) or not label or label != label.strip()
            for label in labels
        ):
            raise ValueError("labels must contain nonempty trimmed strings")
        if len(set(labels)) != len(labels):
            raise ValueError("labels must be unique")
        if type(manifest["num_classes"]) is not int or manifest["num_classes"] != len(labels):
            raise ValueError("num_classes must equal labels length")

        for key in ("input_width", "input_height"):
            value = manifest[key]
            if type(value) is not int or value <= 0 or value > 4096:
                raise ValueError(f"{key} must be an integer from 1 through 4096")
        if manifest["coordinate_size"] != 4:
            raise ValueError("coordinate_size must be 4")
        for key in ("confidence_threshold", "iou_threshold"):
            value = manifest[key]
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError(f"{key} must be finite")
            if value < 0.0 or value > 1.0:
                raise ValueError(f"{key} must be between 0 and 1")
        return manifest
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        emit_error("Invalid face model manifest; disabling NN: " + str(error))
        return None


def stream_camera(client, stop_event, mxid=None, role="face", model_name="chess", width=1280, height=720):
    frame_size = (width, height)
    # Footage capture may request a color size above the OV9282 stereo
    # sensors' native output. Keep stereo at a supported aspect-matched size;
    # Platform-specific alignment resamples depth into the selected RGB pixels.
    mono_size = (min(width, 1280), min(height, 720))
    dai = load_depthai()
    device = None

    def reconnection_callback(status):
        emit_error("device reconnect status " + str(status))

    try:
        if mxid:
            device = dai.Device(dai.DeviceInfo(mxid))
        else:
            device = dai.Device()
        device.setMaxReconnectionAttempts(
            DEVICE_RECONNECT_ATTEMPTS, reconnection_callback
        )
        usb_speed = device.getUsbSpeed()
        # RGB + depth + two rectified mono streams exceed the observed USB 2
        # throughput at 640x400/30. Reduce capture rate before queues accumulate;
        # USB 3 retains 30 fps. Keep depth and original capture timestamps.
        frame_rate = 10.0 if usb_speed == dai.UsbSpeed.HIGH else FRAME_RATE
        calibration = device.readCalibration2()

        with dai.Pipeline(device) as pipeline:
            rgb_socket = color_camera_socket(device, dai)
            rgb_camera = pipeline.create(dai.node.Camera).build(rgb_socket)
            calibrated_lens_position = configure_rgb_calibrated_focus(
                rgb_camera, calibration, rgb_socket
            )
            emit("CEREBRO_DEPTHCAM_RGB_FOCUS source={} lens_position={}".format(
                "eeprom" if calibrated_lens_position is not None else "unavailable",
                calibrated_lens_position,
            ))
            rgb_output = rgb_camera.requestOutput(
                frame_size,
                type=dai.ImgFrame.Type.RGB888i,
                resizeMode=dai.ImgResizeMode.CROP,
                fps=frame_rate,
                enableUndistortion=True,
            )

            # OAK-D Pro is an RVC2 device. DepthAI's automatic v3 Depth node
            # does not always infer its OV9282 stereo pair, so wire the two
            # physical mono sensors explicitly and align their result to RGB.
            left_camera = pipeline.create(dai.node.Camera).build(dai.CameraBoardSocket.CAM_B)
            right_camera = pipeline.create(dai.node.Camera).build(dai.CameraBoardSocket.CAM_C)
            left_output = left_camera.requestOutput(
                mono_size, type=dai.ImgFrame.Type.GRAY8, fps=frame_rate,
                enableUndistortion=False,
            )
            right_output = right_camera.requestOutput(
                mono_size, type=dai.ImgFrame.Type.GRAY8, fps=frame_rate,
                enableUndistortion=False,
            )
            stereo = pipeline.create(dai.node.StereoDepth)
            stereo.setDefaultProfilePreset(dai.node.StereoDepth.PresetMode.ROBOTICS)
            stereo.setLeftRightCheck(True)
            stereo.setSubpixel(True)
            configure_latest_input(stereo.left)
            configure_latest_input(stereo.right)
            left_output.link(stereo.left)
            right_output.link(stereo.right)

            aligned_depth_output, alignment_method = configure_rgb_depth_alignment(
                pipeline, dai, device.getPlatform(), stereo, rgb_output
            )
            emit("CEREBRO_DEPTHCAM_ALIGNMENT method={} platform={}".format(
                alignment_method, device.getPlatform()
            ))
            imu_retry_key = (role, mxid or "automatic")
            imu_queue, imu_window = configure_optional_imu(pipeline, dai, device, calibration, rgb_socket,
                disabled=imu_retry_key in IMU_DISABLED_AFTER_START_FAILURE)

            nn_model = None
            nn_queue = None
            face_model_labels = []
            script_dir = os.path.dirname(os.path.abspath(__file__))

            if role == "belly":
                # The bundled road model has no sidewalk class. Navigation stays
                # fail-closed until a purpose-built sidewalk contract is added.
                pass
            elif role == "face":
                # Dynamic Custom Spatial model (e.g. yolov8_chess_6shave.blob, yolov8_monopoly_6shave.blob)
                blob_name = f"yolov8_{model_name.lower()}_6shave.blob"
                blob_path = os.path.join(script_dir, "Models", blob_name)
                if not os.path.exists(blob_path):
                    blob_path = os.path.join(script_dir, "..", "Models", blob_name)

                if not os.path.exists(blob_path):
                    emit_error("Face model blob not found; disabling NN: " + blob_path)
                    manifest = None
                else:
                    manifest = load_face_model_manifest(blob_path)

                if manifest is not None:
                    try:
                        nn_model = pipeline.create(dai.node.YoloSpatialDetectionNetwork)
                        nn_model.setBlobPath(blob_path)
                        nn_model.setConfidenceThreshold(manifest["confidence_threshold"])
                        nn_model.setNumClasses(manifest["num_classes"])
                        nn_model.setCoordinateSize(manifest["coordinate_size"])
                        nn_model.setIouThreshold(manifest["iou_threshold"])
                        nn_input_stream = rgb_camera.requestOutput(
                            (manifest["input_width"], manifest["input_height"]),
                            type=dai.ImgFrame.Type.RGB888i,
                            resizeMode=dai.ImgResizeMode.CROP,
                            fps=5.0,
                            enableUndistortion=True,
                        )
                        nn_input_stream.link(nn_model.input)
                        stereo.depth.link(nn_model.inputDepth)
                        face_model_labels = manifest["labels"]
                    except Exception as error:
                        emit_error("Failed to initialize manifested face spatial neural network: " + str(error))
                        nn_model = None
                        face_model_labels = []

            sync = pipeline.create(dai.node.Sync)
            sync.setSyncThreshold(SYNC_THRESHOLD)
            sync.setSyncAttempts(3)
            # Leave a short timestamp-matching window while bounding history.
            for name in ("rgb", "depth", "left", "right"):
                configure_latest_input(sync.inputs[name], size=4)
            rgb_output.link(sync.inputs["rgb"])
            aligned_depth_output.link(sync.inputs["depth"])
            stereo.rectifiedLeft.link(sync.inputs["left"])
            stereo.rectifiedRight.link(sync.inputs["right"])
            queue = sync.out.createOutputQueue(maxSize=1, blocking=False)
            
            if nn_model is not None:
                configure_latest_input(nn_model.input, size=1)
                configure_latest_input(nn_model.inputDepth, size=1)
                nn_queue = nn_model.out.createOutputQueue(maxSize=1, blocking=False)

            try:
                pipeline.start()
            except Exception:
                # The helper's existing retry opens a fresh pipeline. Sacrifice
                # optional IMU telemetry after a startup failure so it cannot
                # prevent subsequent RGB-D recovery in this process.
                if imu_window is not None:
                    IMU_DISABLED_AFTER_START_FAILURE.add(imu_retry_key)
                    emit_error("Pipeline startup failed with optional IMU; retrying RGB-D without IMU telemetry")
                raise
            intrinsic_matrix = calibration.getCameraIntrinsics(
                rgb_socket, frame_size[0], frame_size[1]
            )
            rgb_intrinsics = [
                float(value) for row in intrinsic_matrix for value in row
            ]
            if len(rgb_intrinsics) != 9:
                raise RuntimeError("DepthAI returned invalid RGB camera intrinsics")
            emit("CEREBRO_DEPTHCAM_STREAMING")

            latest_sidewalk_deviation = None
            latest_sidewalk_confidence = None
            latest_chess_pieces = []
            latest_chess_pieces_updated_at = None
            last_timing_at = 0.0

            while not stop_event.is_set() and pipeline.isRunning():
                group = queue.get(QUEUE_WAIT)
                if group is None:
                    continue
                if not isinstance(group, dai.MessageGroup):
                    raise RuntimeError("DepthAI sync returned an invalid message")

                rgb_frame = group["rgb"]
                depth_frame = group["depth"]
                left_frame = group["left"]
                right_frame = group["right"]
                if not isinstance(rgb_frame, dai.ImgFrame) or not isinstance(
                    depth_frame, dai.ImgFrame
                ):
                    raise RuntimeError("DepthAI sync group is missing RGB or depth")

                # Process latest on-device neural network sidewalk segmentation/YOLO if available
                if nn_queue is not None:
                    try:
                        nn_msg = nn_queue.tryGet()
                        if nn_msg is not None:
                            if role == "belly":
                                # road-segmentation-adas-0001 has road, curb, and
                                # mark classes, but no sidewalk class. Fail closed
                                # until a real sidewalk model and confidence
                                # contract are available.
                                latest_sidewalk_deviation = None
                                latest_sidewalk_confidence = None
                            elif role == "face":
                                detections = getattr(nn_msg, "detections", None)
                                if detections is None:
                                    raise RuntimeError("SpatialImgDetections is missing detections")
                                latest_chess_pieces = []
                                for det in detections:
                                    label_index = int(det.label)
                                    if label_index < 0 or label_index >= len(face_model_labels):
                                        raise RuntimeError("Detection label is outside manifested labels")
                                    latest_chess_pieces.append({
                                        "type": face_model_labels[label_index],
                                        "x": float(det.spatialCoordinates.x / 1000.0),
                                        "y": float(det.spatialCoordinates.y / 1000.0),
                                        "z": float(det.spatialCoordinates.z / 1000.0)
                                    })
                                latest_chess_pieces_updated_at = time.monotonic()
                    except Exception as error:
                        emit_error("Failed to post-process on-device NeuralNetwork output: " + str(error))
                        latest_chess_pieces = []
                        latest_chess_pieces_updated_at = None
                elif role == "face":
                    # Board corners do not identify chess pieces. Without a
                    # compatible detection model, publish no piece detections.
                    latest_chess_pieces = []
                    latest_chess_pieces_updated_at = None

                if (
                    role == "face"
                    and latest_chess_pieces_updated_at is not None
                    and time.monotonic() - latest_chess_pieces_updated_at
                    > FACE_DETECTION_TTL_SECONDS
                ):
                    latest_chess_pieces = []
                    latest_chess_pieces_updated_at = None

                send_started = time.monotonic()
                clock_now = dai.Clock.now()
                timing = frame_timing(rgb_frame, depth_frame, clock_now)
                send_frame(
                    client, rgb_frame, depth_frame, left_frame, right_frame,
                    rgb_intrinsics, latest_sidewalk_deviation, latest_sidewalk_confidence,
                    latest_chess_pieces,
                    captured_at_milliseconds=capture_time_milliseconds(
                        [rgb_frame, depth_frame], clock_now, time.time()),
                    rgb_calibrated_lens_position=calibrated_lens_position,
                    depth_alignment_method=alignment_method,
                    imu_telemetry=read_optional_imu(imu_queue, imu_window, rgb_frame),
                )
                send_finished = time.monotonic()
                if send_finished - last_timing_at >= 5:
                    last_timing_at = send_finished
                    timing.update(role=role, width=width, height=height, usb_speed=str(usb_speed), fps=frame_rate,
                                  send_ms=round((send_finished - send_started) * 1000, 1))
                    emit("CEREBRO_DEPTHCAM_TIMING " + json.dumps(timing, separators=(",", ":")))

            if not stop_event.is_set():
                raise RuntimeError("DepthAI pipeline stopped unexpectedly")
    finally:
        if device is not None:
            try:
                device.close()
            except Exception as error:
                emit_error("unable to close DepthAI device: " + str(error))


def accept_client(server, stop_event):
    while not stop_event.is_set():
        try:
            client, _ = server.accept()
            client.settimeout(CLIENT_SEND_TIMEOUT_SECONDS)
            return client
        except socket.timeout:
            continue
    return None


def client_is_connected(client):
    try:
        readable, _, _ = select.select([client], [], [], 0)
        if not readable:
            return True
        return client.recv(1, socket.MSG_PEEK) != b""
    except (BlockingIOError, InterruptedError, socket.timeout):
        return True
    except OSError:
        return False


def serve(server, stop_event, mxid=None, role="face", model_name="chess", width=1280, height=720):
    while not stop_event.is_set():
        client = accept_client(server, stop_event)
        if client is None:
            return

        with client:
            retry_delay = INITIAL_RETRY_DELAY_SECONDS
            while not stop_event.is_set():
                try:
                    stream_camera(client, stop_event, mxid, role, model_name, width, height)
                    break
                except (BrokenPipeError, ConnectionResetError, socket.timeout) as error:
                    emit_error("camera client disconnected: " + str(error))
                    break
                except Exception as error:
                    emit_error(error)
                    if stop_event.wait(retry_delay):
                        return
                    if not client_is_connected(client):
                        break
                    retry_delay = min(retry_delay * 2.0, MAX_RETRY_DELAY_SECONDS)


def monitor_parent_process(parent_pid, stop_event):
    if parent_pid <= 1:
        emit_error("invalid Cerebro parent process ID")
        os._exit(2)

    # Secondary background thread to block on sys.stdin.read(1) for instant parent exit detection (even if parent becomes a macOS zombie)
    def monitor_stdin():
        import sys
        try:
            char = sys.stdin.read(1)
            if char == "":
                emit_error("Cerebro parent process stdin reached EOF (parent dead); stopping DepthAI service")
                os._exit(0)
        except Exception:
            os._exit(0)

    stdin_thread = threading.Thread(target=monitor_stdin, name="CerebroStdinMonitor", daemon=True)
    stdin_thread.start()

    while not stop_event.wait(1.0):
        parent_changed = os.getppid() != parent_pid
        try:
            os.kill(parent_pid, 0)
            parent_missing = False
        except ProcessLookupError:
            parent_missing = True
        except PermissionError:
            parent_missing = False

        if parent_changed or parent_missing:
            # This thread must be able to end a helper whose main thread is
            # blocked inside a native SDK call. The process is orphaned, so
            # normal socket cleanup is unnecessary; descriptors and the OAK
            # device close when the kernel exits the process.
            emit_error("Cerebro parent process exited; stopping DepthAI service")
            os._exit(0)


def main():
    args = parse_arguments()
    socket_path = normalized_socket_path(args.socket_path)
    stop_event = threading.Event()

    def request_stop(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    server = None
    identity = None
    service_lock = None
    try:
        service_lock = acquire_service_lock(socket_path)
        server, identity = create_server(socket_path)
        parent_monitor = threading.Thread(
            target=monitor_parent_process,
            args=(args.parent_pid, stop_event),
            name="CerebroParentMonitor",
            daemon=True,
        )
        parent_monitor.start()
        emit("CEREBRO_DEPTHCAM_READY " + socket_path)
        serve(server, stop_event, args.mxid, args.role, args.model_name, args.width, args.height)
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as error:
        emit_error(error)
        return 1
    finally:
        if server is not None:
            server.close()
        if identity is not None:
            remove_owned_socket(socket_path, identity)
        release_service_lock(service_lock)


if __name__ == "__main__":
    raise SystemExit(main())
