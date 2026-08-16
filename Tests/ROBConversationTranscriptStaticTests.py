#!/usr/bin/env python3
"""Static regression fixture for aligned, complete conversation bubbles."""

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
    row_height = objective_c_method(source, "heightOfRow:")
    row_renderer = objective_c_method(source, "viewForTableColumn:")
    resize_handler = objective_c_method(source, "- (void)tableViewColumnDidResize:")

    assert "maximumNumberOfLines = 0;" in bubble_initializer
    assert "lineBreakMode = NSLineBreakByWordWrapping;" in bubble_initializer
    assert ".cell.wraps = YES;" in bubble_initializer
    assert ".cell.scrollable = NO;" in bubble_initializer

    # Lower the glyphs without moving the bubble. The same attributed-text
    # geometry must be used for row measurement so wrapped final lines retain
    # enough height inside the rounded mask.
    assert "ROBConversationBubbleTextBaselineOffset = -3.0;" in source
    baseline_attribute = (
        "NSBaselineOffsetAttributeName: "
        "@(ROBConversationBubbleTextBaselineOffset)"
    )
    assert baseline_attribute in row_height
    assert baseline_attribute in row_renderer

    # Width changes alter wrapping and must invalidate every cached row height.
    assert "noteHeightOfRowsWithIndexesChanged" in resize_handler
    print("Conversation bubbles lower text without clipping wrapped responses")


if __name__ == "__main__":
    main()
