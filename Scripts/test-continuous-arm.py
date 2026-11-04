#!/usr/bin/env python3
"""Build/test the offline trajectory owner. No robot connection or installation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PIN = "7de6b1035e1cad509251b31b3287d10fbcda6baf"


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=180, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ruckig-source", required=True, type=Path)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--sanitizer", choices=["none", "address,undefined", "thread"], default="none")
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--trace", type=Path, help="Optional private CSV of simulated J6 motion")
    args = parser.parse_args()
    source = args.ruckig_source.resolve()
    revision = run(["git", "-C", str(source), "rev-parse", "HEAD"]).strip()
    dirty = run(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"])
    if revision != PIN or dirty:
        raise RuntimeError("Requires an unmodified Ruckig v0.9.2 checkout at " + PIN)
    build = args.build_dir.resolve()
    run(["cmake", "-S", str(ROOT / "Tools/ContinuousArm"), "-B", str(build),
         f"-DROB_RUCKIG_SOURCE={source}",
         "-DCMAKE_BUILD_TYPE=" + ("Release" if args.sanitizer == "none" else "Debug"),
         "-DROB_SANITIZE=" + ("" if args.sanitizer == "none" else args.sanitizer)])
    run(["cmake", "--build", str(build), "-j", "4"])
    command = [str(build / "continuous_arm_tests")]
    if args.trace:
        args.trace.parent.mkdir(parents=True, exist_ok=True)
        command.append(str(args.trace.resolve()))
    records = [json.loads(line) for line in run(command).splitlines() if line.strip()]
    legacy = [json.loads(line) for line in run([str(build / "legacy_handoff_reproduction")]).splitlines() if line.strip()]
    codec = [json.loads(line) for line in run([str(build / "amber_wire_codec_tests")]).splitlines() if line.strip()]
    boundary = [json.loads(line) for line in run([str(build / "arm_driver_boundary_tests")]).splitlines() if line.strip()]
    receive_clock = [json.loads(line) for line in run([str(build / "receive_clock_tests")]).splitlines() if line.strip()]
    session = [json.loads(line) for line in run([str(build / "arm_session_tests")]).splitlines() if line.strip()]
    rehearsal_binary = build / "rob-amber-rehearse"
    rehearsal = [json.loads(line) for line in run([str(rehearsal_binary), "--run"]).splitlines() if line.strip()]
    run([sys.executable, '-B', str(ROOT / 'Tests/ROBAmberCommissioningPreflightTests.py')])
    linux_executable = build / "amber_linux_transport_tests"
    linux_transport = ([json.loads(line) for line in run([str(linux_executable)]).splitlines() if line.strip()]
                       if sys.platform.startswith("linux") else None)
    source_files = ["Tools/ContinuousArm/ContinuousArmController.hpp",
                    "Tools/ContinuousArm/ContinuousArmController.cpp",
                    "Tests/ROBContinuousArmControllerTests.cpp",
                    "Tools/ContinuousArm/AmberWireCodec.hpp",
                    "Tools/ContinuousArm/AmberWireCodec.cpp",
                    "Tools/ContinuousArm/ArmDriverBoundary.hpp",
                    "Tools/ContinuousArm/ArmDriverBoundary.cpp",
                    "Tools/ContinuousArm/ArmSession.hpp",
                    "Tools/ContinuousArm/ArmSession.cpp",
                    "Tests/ROBArmSessionTests.cpp",
                    "Tools/ContinuousArm/ReceiveClock.hpp",
                    "Tools/ContinuousArm/ReceiveClock.cpp",
                    "Tools/ContinuousArm/SocketCanTransport.hpp",
                    "Tools/ContinuousArm/SocketCanTransport.cpp",
                    "Tools/ContinuousArm/AmberControllerMain.cpp",
                    "Tools/ContinuousArm/AmberRehearsalMain.cpp",
                    "Tools/ContinuousArm/CMakeLists.txt",
                    "Tests/ROBAmberWireCodecTests.cpp",
                    "Tests/ROBArmDriverBoundaryTests.cpp",
                    "Tests/ROBReceiveClockTests.cpp",
                    "Tests/ROBAmberLinuxTransportTests.cpp",
                    "Scripts/test-amber-linux-isolation.py",
                    "Scripts/test-amber-runtime.py",
                    "Scripts/test-continuous-arm.py"]
    source_files += ['Scripts/amber-commissioning-preflight.py', 'Tests/ROBAmberCommissioningPreflightTests.py',
                     'Scripts/package-amber-controller.py', 'Tools/ContinuousArm/DEPLOYMENT.md']
    report = {"hardware_io": False, "installed": False, "ruckig_version": "0.9.2",
              "ruckig_commit": revision, "sanitizer": args.sanitizer,
              "source_sha256": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in source_files},
              "tests": records, "legacy_comparison": legacy, "wire_codec_tests": codec, "driver_boundary_tests": boundary,
              "receive_clock_tests": receive_clock, "session_tests": session, "linux_transport_no_io_tests": linux_transport,
              "rehearsal_tests": rehearsal, "rehearsal_binary_sha256": hashlib.sha256(rehearsal_binary.read_bytes()).hexdigest(),
              "preflight_tests": {"passed": 7, "failed": 0, "hardware_io": False}}
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"sanitizer": args.sanitizer, **records[-1]}))
    print(json.dumps(next(x for x in records if "metrics" in x)))
    print(json.dumps({"sanitizer": args.sanitizer, "wire_codec": codec[-1]}))
    print(json.dumps(next(x for x in codec if "metrics" in x)))
    print(json.dumps({"sanitizer": args.sanitizer, "driver_boundary": boundary[-1]}))
    print(json.dumps(next(x for x in boundary if "metrics" in x)))
    print(json.dumps({"sanitizer": args.sanitizer, "receive_clock": receive_clock[-1]}))
    print(json.dumps({"sanitizer": args.sanitizer, "session": session[-1]}))
    print(json.dumps({"sanitizer": args.sanitizer, "rehearsal": rehearsal[-1]}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
