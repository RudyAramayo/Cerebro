#!/usr/bin/env python3
"""Static regressions for removing disabled legacy code without deleting RHAPI docs."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATHS = (
    ROOT / "Cerebro" / "ROBSpeechBox.m",
    ROOT / "Cerebro" / "ROBMainViewController.mm",
    ROOT / "Cerebro" / "ROBSerialBox.m",
    ROOT / "Cerebro" / "ROBTorsoControlsViewController.m",
    ROOT / "Cerebro" / "CameraViewController.swift",
    ROOT / "Cerebro" / "TaskControllers" / "AudioInputTaskController.h",
    ROOT / "Cerebro" / "TaskControllers" / "AudioInputTaskController.m",
    ROOT / "Cerebro" / "TaskControllers" / "JoinWifiTaskController.m",
    ROOT / "Cerebro" / "TaskControllers" / "RealSenseTaskController.m",
    ROOT / "Cerebro" / "TaskControllers" / "ReSpeakerTaskController.m",
    ROOT / "Cerebro" / "TaskControllers" / "SimpleUserTrackerTaskController.m",
)
SERIAL_SOURCE_PATH = ROOT / "Cerebro" / "ROBSerialBox.m"
RHAPI_MARKER = b"ORBITUSROBOTICS RHAPIv1.0"
RHAPI_BLOCK_SHA256 = "90404a94b6302d41194351986242c55e8e3b29985d2df42847e53970c6bcd10c"

# These expressions deliberately recognize statements and declarations rather
# than banning comments that happen to mention a class, method, or setting.
EXECUTABLE_COMMENT_PATTERNS = (
    (
        "Objective-C declaration",
        re.compile(
            r"^(?:[-+]\s*\([^)]*\)\s*[A-Za-z_]|"
            r"@(?:property|interface|implementation|synthesize|dynamic)\b)"
        ),
    ),
    (
        "disabled compiler directive",
        re.compile(r"^#\s*(?:if|ifdef|ifndef|else|elif|endif|define|import|include|pragma)\b"),
    ),
    (
        "control-flow statement",
        re.compile(
            r"^(?:if\s*\(|else(?:\s+if\s*\(|\s*\{)|for\s*\(|while\s*\(|"
            r"switch\s*\(|guard\s+|return(?:\s|;|$)|throw\s+|defer\s*\{|do\s*\{)"
        ),
    ),
    (
        "Swift declaration",
        re.compile(r"^(?:let|var)\s+[A-Za-z_]\w*(?:\s*:\s*[^=]+)?\s*="),
    ),
    (
        "C/Objective-C declaration",
        re.compile(
            r"^(?:(?:const|static|unsigned|signed)\s+)*"
            r"(?:BOOL|bool|char|short|int|long|float|double|NSInteger|NSUInteger|"
            r"CGFloat|NSTimeInterval|speed_t|[A-Z][A-Za-z0-9_]*(?:\s*<[^>]+>)?)"
            r"(?:\s+\*?\s*|\s*\*\s*)[A-Za-z_]\w*\s*(?:=|;)"
        ),
    ),
    (
        "Objective-C message statement",
        re.compile(r"^\[[^\n]+\]\s*;"),
    ),
    (
        "property assignment",
        re.compile(
            r"^(?:self|[A-Za-z_]\w*)(?:\.|->)[A-Za-z_]\w*\s*"
            r"(?:=|\+=|-=|\*=|/=)"
        ),
    ),
    (
        "function call",
        re.compile(
            r"^(?:(?:[A-Za-z_]\w*\.)+[A-Za-z_]\w*[!?]?|"
            r"dispatch_(?:async|after|once)|NSLog|printf|print|assert|precondition)\s*\("
        ),
    ),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def rhapi_documentation_range(source: bytes) -> tuple[int, int]:
    marker = source.find(RHAPI_MARKER)
    require(marker >= 0, "ROBSerialBox lost the ORBITUSROBOTICS RHAPIv1.0 documentation")
    start = source.rfind(b"/*", 0, marker)
    end_marker = source.find(b"*/", marker)
    require(start >= 0 and end_marker >= 0, "The RHAPI documentation comment is incomplete")
    return start, end_marker + len(b"*/")


def require_unchanged_rhapi_documentation() -> tuple[int, int]:
    source = SERIAL_SOURCE_PATH.read_bytes()
    start, end = rhapi_documentation_range(source)
    block = source[start:end]
    require(
        hashlib.sha256(block).hexdigest() == RHAPI_BLOCK_SHA256,
        "The ORBITUSROBOTICS RHAPIv1.0 protocol documentation was removed or changed",
    )
    for protocol_example in (
        b"INPUT: FULL BRAKE Command String",
        b"Turn Right",
        b"Turn Left",
        b"OUTPUT: ir sensor array in cm",
        b"Yaw, Pitch, Roll:",
    ):
        require(
            protocol_example in block,
            f"RHAPI documentation lost {protocol_example.decode('utf-8')}",
        )
    return start, end


def leading_comment_payloads(source: str):
    """Yield only full-line comments, where deliberately disabled code lives."""

    in_block_comment = False
    for line_number, line in enumerate(source.splitlines(), start=1):
        remaining = line.lstrip()
        while True:
            if in_block_comment:
                end = remaining.find("*/")
                if end < 0:
                    yield line_number, remaining.lstrip("* ")
                    break
                yield line_number, remaining[:end].lstrip("* ")
                remaining = remaining[end + 2 :].lstrip()
                in_block_comment = False
                if not remaining:
                    break
                continue

            if remaining.startswith("//"):
                yield line_number, remaining[2:].lstrip()
                break
            if remaining.startswith("/*"):
                in_block_comment = True
                remaining = remaining[2:]
                continue
            break


def executable_comments(path: Path, source: str) -> list[str]:
    findings: list[str] = []
    for line_number, payload in leading_comment_payloads(source):
        for description, pattern in EXECUTABLE_COMMENT_PATTERNS:
            if pattern.search(payload):
                findings.append(
                    f"{path.relative_to(ROOT)}:{line_number}: {description}: {payload.strip()}"
                )
                break
    return findings


def require_focused_matchers() -> None:
    explanatory_comments = (
        "ROBController publishes at 5 Hz. Three missed snapshots expire authority.",
        "Values below -999 bypass joystick processing so the brake bits remain set.",
        "The observations are `VNInstanceMaskObservation` objects.",
        "This method calls startRecognizer only after microphone authorization.",
        "Yaw, Pitch, Roll: 175.03, -12.40, -46.15",
    )
    executable_examples = (
        "[self startCapture];",
        "self.task = [self.speechRecognizer recognitionTaskWithRequest:request];",
        "let context = CIContext(options: nil)",
        "if (self.audioEngine.isRunning) {",
    )
    for comment in explanatory_comments:
        require(
            not any(pattern.search(comment) for _, pattern in EXECUTABLE_COMMENT_PATTERNS),
            f"Comment matcher became too broad for explanatory prose: {comment}",
        )
    for comment in executable_examples:
        require(
            any(pattern.search(comment) for _, pattern in EXECUTABLE_COMMENT_PATTERNS),
            f"Comment matcher stopped recognizing disabled code: {comment}",
        )


def main() -> None:
    require_focused_matchers()
    rhapi_start, rhapi_end = require_unchanged_rhapi_documentation()
    findings: list[str] = []

    for path in SOURCE_PATHS:
        require(path.is_file(), f"Missing active implementation file: {path.relative_to(ROOT)}")
        source_bytes = path.read_bytes()
        if path == SERIAL_SOURCE_PATH:
            # RHAPI is protocol documentation, not disabled implementation. Keep
            # line numbering stable while excluding only that exact protected block.
            source_bytes = (
                source_bytes[:rhapi_start]
                + b"\n" * source_bytes[rhapi_start:rhapi_end].count(b"\n")
                + source_bytes[rhapi_end:]
            )
        source = source_bytes.decode("utf-8")
        require(
            re.search(r"^\s*#\s*if\s+(?:0|false)\b", source, re.MULTILINE) is None,
            f"{path.relative_to(ROOT)} still contains a disabled preprocessor block",
        )
        findings.extend(executable_comments(path, source))

    require(
        not findings,
        "Active legacy implementation files still contain commented-out executable code:\n"
        + "\n".join(findings),
    )
    print("Legacy commented code is absent and RHAPIv1.0 documentation is intact")


if __name__ == "__main__":
    main()
