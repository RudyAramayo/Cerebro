#!/usr/bin/env python3
"""Static regression checks for adaptive Base Arduino console colors."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CONSOLE_SOURCE = (ROOT / "Cerebro" / "ROBBaseSerialConsoleWindowController.m").read_text(
    encoding="utf-8"
)
SERIAL_SOURCE = (ROOT / "Cerebro" / "ROBSerialBox.m").read_text(encoding="utf-8")


def objective_c_method(source: str, signature: str, start: int = 0) -> str:
    method_start = source.index(signature, start)
    body_start = source.index("{", method_start)
    depth = 0
    for index in range(body_start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[method_start : index + 1]
    raise AssertionError(f"Unterminated Objective-C method: {signature}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def semantic_assignment(source: str, target: str, color: str) -> bool:
    value = rf"(?:NSColor\.{color}|\[NSColor\s+{color}\])"
    return re.search(rf"{re.escape(target)}\s*=\s*{value}\s*;", source) is not None


def main() -> None:
    serial_implementation = SERIAL_SOURCE.index("@implementation ROBSerialBox")
    append_output = objective_c_method(
        SERIAL_SOURCE, "- (void)appendToIncomingText_base:", serial_implementation
    )

    require(
        semantic_assignment(
            CONSOLE_SOURCE, "self.baseOutputTextView.textColor", "labelColor"
        ),
        "Base Arduino output no longer uses the adaptive label text color",
    )
    require(
        semantic_assignment(
            CONSOLE_SOURCE,
            "self.baseOutputTextView.backgroundColor",
            "textBackgroundColor",
        ),
        "Base Arduino output no longer uses the system text background color",
    )
    require(
        "self.baseOutputTextView.drawsBackground = YES;" in CONSOLE_SOURCE,
        "Base Arduino output must draw its semantic background",
    )
    require(
        semantic_assignment(
            CONSOLE_SOURCE,
            "scrollView.backgroundColor",
            "textBackgroundColor",
        ),
        "The Base Arduino scroll view no longer follows the text background color",
    )

    label_color = r"(?:NSColor\.labelColor|\[NSColor\s+labelColor\])"
    require(
        re.search(
            rf"NSForegroundColorAttributeName\s*:\s*{label_color}", append_output
        )
        is not None,
        "Appended Base Arduino output no longer carries an adaptive label color",
    )
    require(
        "initWithString:" in append_output and "attributes:" in append_output,
        "Base Arduino serial chunks no longer apply their semantic attributes",
    )

    relevant_appearance_code = "\n".join(
        line
        for line in CONSOLE_SOURCE.splitlines()
        if "baseOutputTextView" in line or "scrollView" in line
    ) + append_output
    for forbidden in (
        "colorWithCalibratedRed:",
        "colorWithDeviceRed:",
        "colorWithSRGBRed:",
        "blackColor",
        "whiteColor",
    ):
        require(
            forbidden not in relevant_appearance_code,
            f"Base Arduino output uses a non-adaptive color: {forbidden}",
        )

    print("Base Arduino console output uses adaptive system text colors")


if __name__ == "__main__":
    main()
