#!/usr/bin/env python3
"""Supervised Luxonis RGB-D service for Cerebro.

The service intentionally runs outside the Cerebro process.  It owns the
DepthAI device connection, aligns depth to the RGB stream, and sends framed
RGB-D messages to one local Unix-domain-socket client at a time.  Device and
SDK failures are reported and retried instead of terminating the service.
"""

import argparse
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


def frame_payload(
    rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
    sidewalk_deviation=None, sidewalk_confidence=None, chess_pieces=None
):
    rgb_width = int(rgb_frame.getWidth())
    rgb_height = int(rgb_frame.getHeight())
    depth_width = int(depth_frame.getWidth())
    depth_height = int(depth_frame.getHeight())

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
        "rgb_intrinsics": rgb_intrinsics,
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
    sidewalk_deviation=None, sidewalk_confidence=None, chess_pieces=None
):
    header, rgb_bytes, depth_bytes, left_bytes, right_bytes = frame_payload(
        rgb_frame, depth_frame, left_frame, right_frame, rgb_intrinsics,
        sidewalk_deviation, sidewalk_confidence, chess_pieces
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
    # ImageAlign below resamples depth into the selected RGB coordinate space.
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

        with dai.Pipeline(device) as pipeline:
            rgb_socket = color_camera_socket(device, dai)
            rgb_camera = pipeline.create(dai.node.Camera).build(rgb_socket)
            rgb_output = rgb_camera.requestOutput(
                frame_size,
                type=dai.ImgFrame.Type.RGB888i,
                resizeMode=dai.ImgResizeMode.CROP,
                fps=FRAME_RATE,
                enableUndistortion=True,
            )

            # OAK-D Pro is an RVC2 device. DepthAI's automatic v3 Depth node
            # does not always infer its OV9282 stereo pair, so wire the two
            # physical mono sensors explicitly and align their result to RGB.
            left_camera = pipeline.create(dai.node.Camera).build(dai.CameraBoardSocket.CAM_B)
            right_camera = pipeline.create(dai.node.Camera).build(dai.CameraBoardSocket.CAM_C)
            left_output = left_camera.requestOutput(
                mono_size, type=dai.ImgFrame.Type.GRAY8, fps=FRAME_RATE,
                enableUndistortion=False,
            )
            right_output = right_camera.requestOutput(
                mono_size, type=dai.ImgFrame.Type.GRAY8, fps=FRAME_RATE,
                enableUndistortion=False,
            )
            stereo = pipeline.create(dai.node.StereoDepth)
            stereo.setDefaultProfilePreset(dai.node.StereoDepth.PresetMode.ROBOTICS)
            stereo.setLeftRightCheck(True)
            stereo.setSubpixel(True)
            left_output.link(stereo.left)
            right_output.link(stereo.right)

            align = pipeline.create(dai.node.ImageAlign)
            stereo.depth.link(align.input)
            rgb_output.link(align.inputAlignTo)

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
            rgb_output.link(sync.inputs["rgb"])
            align.outputAligned.link(sync.inputs["depth"])
            stereo.rectifiedLeft.link(sync.inputs["left"])
            stereo.rectifiedRight.link(sync.inputs["right"])
            queue = sync.out.createOutputQueue(maxSize=1, blocking=False)
            
            if nn_model is not None:
                nn_queue = nn_model.out.createOutputQueue(maxSize=1, blocking=False)

            pipeline.start()
            calibration = device.readCalibration2()
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

                send_frame(
                    client, rgb_frame, depth_frame, left_frame, right_frame,
                    rgb_intrinsics, latest_sidewalk_deviation, latest_sidewalk_confidence,
                    latest_chess_pieces
                )

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
