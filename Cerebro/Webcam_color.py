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
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return descriptor
    except BlockingIOError as error:
        os.close(descriptor)
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


def frame_payload(rgb_frame, depth_frame, left_frame, right_frame):
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
    }
    header_bytes = json.dumps(
        header, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    return header_bytes, rgb_bytes, depth_bytes, left_bytes, right_bytes


def send_frame(client, rgb_frame, depth_frame, left_frame, right_frame):
    header, rgb_bytes, depth_bytes, left_bytes, right_bytes = frame_payload(
        rgb_frame, depth_frame, left_frame, right_frame
    )
    client.sendall(PROTOCOL_MAGIC + struct.pack(">I", len(header)) + header)
    client.sendall(rgb_bytes)
    client.sendall(depth_bytes)
    client.sendall(left_bytes)
    client.sendall(right_bytes)


def stream_camera(client, stop_event):
    dai = load_depthai()
    device = None

    def reconnection_callback(status):
        emit_error("device reconnect status " + str(status))

    try:
        device = dai.Device()
        device.setMaxReconnectionAttempts(
            DEVICE_RECONNECT_ATTEMPTS, reconnection_callback
        )

        with dai.Pipeline(device) as pipeline:
            rgb_camera = pipeline.create(dai.node.Camera).build(
                color_camera_socket(device, dai)
            )
            rgb_output = rgb_camera.requestOutput(
                FRAME_SIZE,
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
                FRAME_SIZE, type=dai.ImgFrame.Type.GRAY8, fps=FRAME_RATE,
                enableUndistortion=False,
            )
            right_output = right_camera.requestOutput(
                FRAME_SIZE, type=dai.ImgFrame.Type.GRAY8, fps=FRAME_RATE,
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

            sync = pipeline.create(dai.node.Sync)
            sync.setSyncThreshold(SYNC_THRESHOLD)
            sync.setSyncAttempts(3)
            rgb_output.link(sync.inputs["rgb"])
            align.outputAligned.link(sync.inputs["depth"])
            stereo.rectifiedLeft.link(sync.inputs["left"])
            stereo.rectifiedRight.link(sync.inputs["right"])
            queue = sync.out.createOutputQueue(maxSize=1, blocking=False)

            pipeline.start()
            emit("CEREBRO_DEPTHCAM_STREAMING")

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
                send_frame(client, rgb_frame, depth_frame, left_frame, right_frame)

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


def serve(server, stop_event):
    while not stop_event.is_set():
        client = accept_client(server, stop_event)
        if client is None:
            return

        with client:
            retry_delay = INITIAL_RETRY_DELAY_SECONDS
            while not stop_event.is_set():
                try:
                    stream_camera(client, stop_event)
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
        serve(server, stop_event)
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
