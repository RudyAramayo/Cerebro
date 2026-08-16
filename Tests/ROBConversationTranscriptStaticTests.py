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
    bubble_layout = objective_c_method(source, "- (void)layout", bubble_class_start)
    row_height = objective_c_method(source, "heightOfRow:")
    row_renderer = objective_c_method(source, "viewForTableColumn:")
    resize_handler = objective_c_method(source, "- (void)tableViewColumnDidResize:")

    assert "maximumNumberOfLines = 0;" in bubble_initializer
    assert "lineBreakMode = NSLineBreakByWordWrapping;" in bubble_initializer
    assert ".cell.wraps = YES;" in bubble_initializer
    assert ".cell.scrollable = NO;" in bubble_initializer
    assert "[self.bubbleBackgroundView setAccessibilityElement:NO];" in bubble_initializer

    # A real inner content frame, rather than paragraph indents, keeps every
    # hard and soft-wrapped line equally inset. Moving the entire selectable
    # field down eight points is five points beyond the former -3pt baseline.
    assert "ROBConversationBubbleHorizontalTextInset = 16.0;" in source
    assert "ROBConversationBubbleTextDownshift = 8.0;" in source
    assert "[self.bubbleBackgroundView addSubview:self.bubbleLabel];" in bubble_initializer
    assert "self.bubbleBackgroundView.frame = bubbleFrame;" in bubble_layout
    assert "NSInsetRect(self.bubbleBackgroundView.bounds" in bubble_layout
    assert "self.bubbleBackgroundView.isFlipped" in bubble_layout
    assert "? ROBConversationBubbleTextDownshift" in bubble_layout
    assert ": -ROBConversationBubbleTextDownshift" in bubble_layout
    assert "ROBConversationBubbleHorizontalTextInset * 2" in row_height
    assert "firstLineHeadIndent" not in row_renderer
    assert "headIndent" not in row_renderer
    assert "NSBaselineOffsetAttributeName" not in row_renderer

    # Width changes alter wrapping and must invalidate every cached row height.
    assert "noteHeightOfRowsWithIndexesChanged" in resize_handler
    print("Conversation bubbles use equal insets and lower wrapped text without clipping")


if __name__ == "__main__":
    main()
