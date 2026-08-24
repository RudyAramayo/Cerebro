from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class AmberReferenceGateStaticTests(unittest.TestCase):
    def test_gateway_session_generation_is_exposed_and_rotated(self):
        source = (ROOT / "Cerebro/ROBAmberGatewayClient.swift").read_text()
        self.assertIn("authenticatedSessionGeneration &+= 1", source)
        self.assertIn('"sessionGeneration": NSNumber(value: authenticatedSessionGeneration)', source)
        self.assertIn("authenticatedSessionGeneration == expectedSessionGeneration", source)
        self.assertNotIn("public func sendLeasedTrajectory(", source)
        self.assertNotIn("public func sendTrajectory(", source)

    def test_session_offset_is_memory_only_and_camera_vetoed(self):
        source = (ROOT / "Cerebro/ROBAmberArmReference.swift").read_text()
        self.assertIn("private var sessions: [String: ROBAmberArmReferenceSession]", source)
        self.assertNotIn("UserDefaults.standard.set(session", source)
        self.assertIn("allRequiredProducersAreFresh()", source)
        self.assertIn("errors.count >= 3", source)
        self.assertIn("generation == session.gatewaySessionGeneration", source)

    def test_live_gesture_dispatch_and_completion_use_model_mapping(self):
        source = (ROOT / "Cerebro/KeyframeAnimationManager.swift").read_text()
        self.assertIn("ROBAmberApprovedGestureCatalog.v2", source)
        self.assertIn("sendReferencedLeasedTrajectory(", source)
        self.assertIn("modelPositionsRadians: target.positionsRadians", source)
        self.assertGreaterEqual(source.count("modelPositions(\n"), 3)
        self.assertIn("reference gate closed during motion", source)

    def test_vision_bridge_uses_the_same_reference_boundary(self):
        source = (ROOT / "Cerebro/ROBArmControllerBridge.swift").read_text()
        self.assertIn("sendReferencedLeasedTrajectory(", source)
        self.assertIn("measuredModelPositions", source)
        self.assertIn("physical arm reference gate closed during motion", source)
        self.assertIn("modelVelocities(", source)

    def test_wake_up_ui_requires_typed_local_reference_confirmation(self):
        source = (ROOT / "Cerebro/ROBWakeUpCalibrationWindowController.swift").read_text()
        self.assertIn('"Type REFERENCE \\(arm.uppercased())"', source)
        self.assertIn('== "REFERENCE \\(arm.uppercased())"', source)
        self.assertIn("operatorConfirmedPark: true", source)
        self.assertIn("zero commands sent", source)


if __name__ == "__main__":
    unittest.main()
