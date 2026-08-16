#!/usr/bin/env python3
"""Static regression fixture for complete multi-line conversation bubbles."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "Cerebro" / "ROBMainViewController.mm"


def objective_c_method(source, signature, start=0):
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


def main():
    source = SOURCE_PATH.read_text(encoding="utf-8")
    bubble_class_start = source.index("@implementation ROBConversationBubbleView")
    bubble_initializer = objective_c_method(
        source, "- (instancetype)initWithFrame:", bubble_class_start
    )
    row_renderer = objective_c_method(source, "viewForTableColumn:")
    resize_handler = objective_c_method(source, "- (void)tableViewColumnDidResize:")

    assert "maximumNumberOfLines = 0;" in bubble_initializer
    assert "lineBreakMode = NSLineBreakByWordWrapping;" in bubble_initializer
    assert ".cell.wraps = YES;" in bubble_initializer
    assert ".cell.scrollable = NO;" in bubble_initializer

    # A per-line baseline offset changes AppKit's line-fragment height. The
    # table measures plain 14-point text, so such an offset clips the final
    # wrapped lines when the bubble masks its contents to rounded corners.
    assert "NSBaselineOffsetAttributeName" not in row_renderer

    # Width changes alter wrapping and must invalidate every cached row height.
    assert "noteHeightOfRowsWithIndexesChanged" in resize_handler
    print("Conversation bubbles preserve complete wrapped response text")


if __name__ == "__main__":
    main()
