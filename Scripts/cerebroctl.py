#!/usr/bin/env python3
"""Same-user Cerebro RPC. Never retries a command; pixels stay in local files."""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
import tempfile
import time
import uuid

DIRECTORY = Path.home() / "Library/Application Support/Cerebro/LocalControl"
READ_ONLY = {"status", "camera.frame", "animation.list", "mission.status", "mission.plan"}


def request(operation, parameters=None, *, socket_path=None, session=None, request_id=None, timeout=8):
    path = str(socket_path or DIRECTORY / "control.sock")
    if operation not in READ_ONLY and operation != "stop" and session is None:
        state = request("status", socket_path=path, timeout=timeout)
        if not state.get("ok"):
            raise RuntimeError(state.get("error", "Unable to read Cerebro session"))
        session = state["session"]
    message = {"version": 1, "id": request_id or str(uuid.uuid4()), "operation": operation,
               "parameters": parameters or {}, "sent_at_ms": time.time() * 1000}
    if session is not None:
        message["session"] = session
    payload = json.dumps(message, allow_nan=False, separators=(",", ":")).encode() + b"\n"
    if len(payload) > 32769:
        raise ValueError("Request exceeds 32 KiB")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(path)
        connection.sendall(payload)
        chunks = bytearray()
        while len(chunks) <= 16_000_000:
            part = connection.recv(65536)
            if not part:
                raise RuntimeError("Reply lost; command state is uncertain. Query status; do not replay.")
            chunks.extend(part)
            if b"\n" in chunks:
                line, _, tail = chunks.partition(b"\n")
                if tail:
                    raise RuntimeError("Unexpected extra reply data")
                result = json.loads(line)
                if str(result.get("id", "")).lower() != message["id"].lower():
                    raise RuntimeError("Reply ID mismatch")
                return result
        raise RuntimeError("Response exceeds 16 MB")


def save_frame(response, output=None):
    result = dict(response["result"])
    if output is None:
        root = DIRECTORY / "Frames"
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        folder = Path(tempfile.mkdtemp(prefix="snapshot-", dir=root))
    else:
        folder = Path(output).expanduser()
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    def write(name, data):
        target = folder / name
        descriptor, temporary = tempfile.mkstemp(prefix=".frame-", dir=folder)
        with os.fdopen(descriptor, "wb") as file:
            file.write(data)
        os.replace(temporary, target)
        return str(target.resolve())
    result["rgb_file"] = write("rgb.jpg", base64.b64decode(result.pop("jpeg_base64"), validate=True))
    if "depth" in result:
        result["depth"] = dict(result["depth"])
        raw = base64.b64decode(result["depth"].pop("base64"), validate=True)
        if len(raw) != result["depth"]["width"] * result["depth"]["height"] * 2:
            raise ValueError("Depth raster size mismatch")
        result["depth"]["file"] = write("depth-u16le.raw", raw)
    result["metadata_file"] = str((folder / "metadata.json").resolve())
    write("metadata.json", (json.dumps(result, indent=2, allow_nan=False) + "\n").encode())
    return dict(response, result=result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", help="status, camera.demand, camera.frame, runtime.profile, mission.start, mission.status, mission.plan, mission.confirm_empty, motion.move, arm.mode, gripper.command, animation.list, animation.play, torso.turn, stop")
    parser.add_argument("--params", default="{}", help="JSON object, or - to read JSON from stdin")
    parser.add_argument("--socket", type=Path)
    parser.add_argument("--output", type=Path, help="Camera snapshot directory; defaults to a private local capture folder")
    args = parser.parse_args()
    import sys
    try:
        parameters = json.loads(sys.stdin.read() if args.params == "-" else args.params)
        if not isinstance(parameters, dict):
            raise ValueError("Parameters must be a JSON object")
        response = request(args.operation, parameters, socket_path=args.socket)
        if args.operation == "camera.frame" and response.get("ok"):
            response = save_frame(response, args.output)
        print(json.dumps(response, indent=2, allow_nan=False))
        return 0 if response.get("ok") else 1
    except (OSError, ValueError, RuntimeError) as error:
        print(json.dumps({"ok": False, "error": str(error), "command_retried": False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
