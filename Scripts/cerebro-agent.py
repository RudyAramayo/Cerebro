#!/usr/bin/env python3
"""Same-user Cerebro interface; envelopes expire, paths are fixed, no shell eval."""
import argparse
import json
import os
from pathlib import Path
import stat
import sys
import time
import uuid

ROOT = Path.home() / "Library/Application Support/Cerebro/AgentBridge"


def request(command, arguments=None, timeout=6):
    inbox, outbox = ROOT / "inbox", ROOT / "outbox"
    for directory in (ROOT, inbox, outbox):
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or directory.resolve() != directory):
            raise RuntimeError("Cerebro's local bridge must be a private directory owned by this user.")
    request_id = str(uuid.uuid4()).upper()
    body = {"version": 1, "id": request_id, "expiresAt": time.time() + timeout,
            "command": command, "arguments": arguments or {}}
    temporary = inbox / (request_id + ".tmp")
    final = inbox / (request_id + ".json")
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(body, stream)
    temporary.rename(final)
    response = outbox / (request_id + ".json")
    deadline = time.monotonic() + timeout + 2
    while time.monotonic() < deadline:
        if response.exists():
            info = response.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 100_000:
                raise RuntimeError("Invalid local response file.")
            result = json.loads(response.read_text())
            if result.get("id") != request_id:
                raise RuntimeError("Response ID mismatch.")
            if not result.get("ok"):
                raise RuntimeError(json.dumps(result.get("result", {})))
            return result["result"]
        time.sleep(0.1)
    raise RuntimeError("Cerebro did not reply before the deadline. The queued command expires automatically.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("status", "capture", "stop"):
        sub.add_parser(command)
    for command in ("observe", "camera-hold"):
        sub.add_parser(command).add_argument("active", choices=("on", "off"))
    nudge = sub.add_parser("camera-nudge")
    nudge.add_argument("axis", choices=("upper", "pan"))
    nudge.add_argument("delta", type=int, help="Relative Maestro units, -100…100; not degrees.")
    harvest = sub.add_parser("harvest")
    harvest.add_argument("--count", type=int, default=6)
    harvest.add_argument("--interval", type=float, default=2)
    args = parser.parse_args()
    if args.command == "camera-nudge":
        if not 1 <= abs(args.delta) <= 100:
            parser.error("delta must be a nonzero integer from -100 to 100")
        status = request("status")
        expected = status.get("neck", {})
        arguments = {"axis": args.axis, "delta": str(args.delta)}
        for key in ("pan", "lower", "upper"):
            if not isinstance(expected.get(key), int) or expected[key] <= 0:
                raise RuntimeError("The current neck command is unknown or off.")
            arguments[key] = str(expected[key])
        result = request("camera-nudge", arguments)
    elif args.command == "harvest":
        if not 1 <= args.count <= 60 or not 1 <= args.interval <= 30:
            parser.error("harvest supports 1…60 frames at intervals of 1…30 seconds")
        result = []
        for index in range(args.count):
            capture = request("capture")
            result.append(capture)
            print(json.dumps({"index": index + 1, **capture}), flush=True)
            if index + 1 < args.count:
                time.sleep(args.interval)
        return
    else:
        arguments = {"active": str(args.active == "on").lower()} if args.command in ("observe", "camera-hold") else {}
        result = request(args.command, arguments)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
