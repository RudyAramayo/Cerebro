#!/usr/bin/env python3
"""Regression checks for Cerebro's momentary local tread controls."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "Cerebro" / "ROBKeyboardControlsViewController.m"
STORYBOARD = ROOT / "Cerebro" / "Base.lproj" / "Main.storyboard"


class KeyboardTreadRampTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = CONTROLLER.read_text()
        cls.storyboard = STORYBOARD.read_text()

    def test_all_four_tread_buttons_report_press_and_release(self) -> None:
        for identifier in ("2qg-8N-K1f", "Mna-cO-FNS", "VL9-5k-YtA", "xT8-H2-5BM"):
            button = re.search(
                rf'<button[^>]+id="{re.escape(identifier)}"[^>]*>',
                self.storyboard,
            )
            self.assertIsNotNone(button)
            self.assertIn('customClass="ROBMomentaryTreadButton"', button.group(0))
        self.assertIn("self.treadPressed = YES", self.source)
        self.assertIn("self.treadPressed = NO", self.source)

    def test_motion_uses_the_selected_time_based_ramp(self) -> None:
        self.assertIn("kROBLocalTreadRampInterval = 0.03", self.source)
        self.assertIn("advanceToLeft:self.targetLeftTreadCommand", self.source)
        self.assertIn("mode:ROBTreadMotionRamp.selectedMode now:NSProcessInfo.processInfo.systemUptime", self.source)
        self.assertIn("@selector(updateLocalTreadRamp)", self.source)
        self.assertIn('property="localTreadSpeedSlider"', self.storyboard)
        self.assertIn("self.localTreadSpeedSlider.doubleValue / 100", self.source)
        self.assertNotIn("serialBox speedSliderAction", self.source)

    def test_release_brakes_only_after_ramping_to_zero(self) -> None:
        ramp_method = self.source.split("- (void)updateLocalTreadRamp", 1)[1]
        stop_branch = ramp_method.split("- (void)stopLocalTreadsImmediately", 1)[0]
        self.assertIn("self.localTreadRamp.isStopped", stop_branch)
        self.assertIn(
            'sendBaseCommand:@"~+0001,+0000,+0001,+0000,+0000,+0000,+0000"',
            stop_branch,
        )

    def test_arrow_keys_have_explicit_key_up_handling(self) -> None:
        self.assertIn("NSEventMaskKeyDown | NSEventMaskKeyUp", self.source)
        self.assertIn("event.type == NSEventTypeKeyUp", self.source)
        self.assertIn("removeObject:keyCode", self.source)
        self.assertIn("event.isARepeat) return nil", self.source)
        self.assertIn("event.keyCode == 53", self.source)


if __name__ == "__main__":
    unittest.main()
