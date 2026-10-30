#!/usr/bin/env python3
"""Bounded, observation-only overnight sampling; never sends a motor command."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

spec = importlib.util.spec_from_file_location("cerebroctl", Path(__file__).with_name("cerebroctl.py"))
rpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rpc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hours", type=float, default=10)
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--camera-profile", choices=["existing", "front", "both"], default="both")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--socket", type=Path, help="Override the local socket for an isolated fixture")
    args = parser.parse_args()
    if not 0 < args.hours <= 12 or not 10 <= args.interval <= 60:
        parser.error("Use at most 12 hours and a 10–60 second interval")
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    deadline = time.monotonic() + args.hours * 3600
    with os.fdopen(fd, "a", buffering=1) as output:
        while time.monotonic() < deadline:
            began = time.monotonic()
            sample = {"recorded_at_ms": time.time() * 1000, "profile": args.camera_profile,
                      "motor_commands": False, "power_watts": None,
                      "power_note": "CPU/RSS and camera throughput are measured; electrical watts require a power sensor."}
            try:
                if args.camera_profile != "existing":
                    sample["camera_demand"] = rpc.request("camera.demand", {"front": True,
                        "panorama": args.camera_profile == "both", "seconds": min(120, args.interval * 2 + 10)},
                        socket_path=args.socket)
                sample["cerebro"] = rpc.request("status", socket_path=args.socket)
            except (OSError, RuntimeError, ValueError) as error:
                sample["error"] = str(error)
            try:
                rows = subprocess.run(["ps", "-Ao", "pid,ppid,pcpu,rss,comm"], text=True, capture_output=True, timeout=5).stdout.splitlines()
                sample["processes"] = [row.strip() for row in rows if any(name in row.lower() for name in
                    ["cerebro", "ffmpeg", "python", "rplidar", "windowserver"])]
            except (OSError, subprocess.TimeoutExpired) as error:
                sample["process_error"] = str(error)
            sample["sample_ms"] = (time.monotonic() - began) * 1000
            output.write(json.dumps(sample, allow_nan=False) + "\n")
            time.sleep(max(0, min(args.interval - (time.monotonic() - began), deadline-time.monotonic())))


if __name__ == "__main__":
    main()
