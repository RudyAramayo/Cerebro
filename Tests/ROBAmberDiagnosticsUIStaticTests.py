#!/usr/bin/env python3
"""Static regression fixture for dual-arm Amber diagnostics controls."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "Cerebro" / "ROBAmberDiagnosticsWindowController.swift"
CLIENT_PATH = ROOT / "Cerebro" / "ROBAmberGatewayClient.swift"


def swift_function(source, signature):
    function_start = source.index(signature)
    body_start = source.index("{", function_start)
    depth = 0
    for index in range(body_start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[function_start : index + 1]
    raise AssertionError(f"Unterminated Swift function: {signature}")


def main():
    source = SOURCE_PATH.read_text(encoding="utf-8")
    client = CLIENT_PATH.read_text(encoding="utf-8")

    # Both gripper panels are built from the same arm-tagged implementation,
    # while calibration dispatch remains explicitly bound to that arm.
    assert "ROBAmberDiagnosticsArm.allCases.map(makeGripperPanel)" in source
    gripper_panel = swift_function(source, "private func makeGripperPanel(")
    assert '"Calibrate \\(arm.title)…"' in gripper_panel
    assert "button.tag = arm == .left ? 0 : 1" in gripper_panel
    assert 'setAccessibilityLabel("Calibrate \\(arm.rawValue) gripper")' in gripper_panel
    assert 'NSSlider(value: 10, minValue: 2, maxValue: 20' in gripper_panel
    assert 'actionButton("Hold…", action: #selector(holdGripper(_:)))' in gripper_panel
    assert 'actionButton("Stop N/A"' in gripper_panel

    calibrate = swift_function(source, "@objc private func calibrateGripper(")
    assert "diagnosticsArm(forTag: sender.tag)" in calibrate
    assert "Calibrate the robot's \\(arm.rawValue) gripper" in calibrate
    assert "\\(arm.amberCoreName), UDP \\(arm.amberUDPPort)" in calibrate
    assert calibrate.count("validateGripperInterlocks") == 2
    assert "alert.alertStyle = .critical" in calibrate
    assert "full travel" in calibrate
    assert "gateway.calibrateGripper(forArm: arm.amberGatewayArm)" in calibrate

    # UI sides are physical ROB sides. Only the Amber boundary uses the
    # historical vendor-core names; inbound state must use the inverse mapping.
    assert "private typealias ROBAmberDiagnosticsArm = ROBArmSide" in source
    assert "gateway.controlGripper(forArm: arm.amberGatewayArm" in source
    assert "gateway.queryGripperState(forArm: arm.amberGatewayArm)" in source
    assert "gateway.gripperSnapshot(forArm: arm.amberGatewayArm)" in source
    assert "ROBAmberDiagnosticsArm(amberGatewayArm: telemetry.arm)" in source
    assert "ROBAmberDiagnosticsArm(rawValue:" not in source
    assert "forArm: arm.rawValue" not in source.replace(
        "normalizedPoints(forArm: arm.rawValue)", "normalizedPoints(physicalArm)"
    )
    assert "captureCurrentAmberPose(forArm: arm.amberGatewayArm)" in source
    assert "robot_arm,core,udp_port" in source

    # The client, not just the local window, serializes calibration against all
    # other left/right gripper requests and invalidates ambiguous lost acks.
    assert 'operation == "gripper_calibrate"' in client
    assert 'type != "gripper_calibrate" || pendingGripperCommands.isEmpty' in client
    assert "gripperAcknowledgementTimeout" in client
    assert "acknowledgementDeadline" in client
    assert "Gripper acknowledgement timed out" in client

    # Left and right have independent plot objects, are both installed in the
    # layout, and receive their own 60-second histories on every refresh.
    assert ".left: ROBAmberDiagnosticsPlotSet()" in source
    assert ".right: ROBAmberDiagnosticsPlotSet()" in source
    assert "ROBAmberDiagnosticsArm.allCases.compactMap" in source
    refresh = swift_function(source, "private func refreshDisplay()")
    assert "for arm in ROBAmberDiagnosticsArm.allCases" in refresh
    assert "histories[arm]?.recent(seconds: 60)" in refresh
    assert "armPlots[arm]?.update(samples: samples)" in refresh
    assert "panel.heightAnchor.constraint(equalTo: plots.heightAnchor)" in source
    assert source.count("heightAnchor.constraint(greaterThanOrEqualToConstant: 88)") >= 4
    assert "title.size(withAttributes: titleAttributes).width + 18" in source
    assert "availableWidth / 6" in source
    assert "graphArmSelector" not in source
    assert "graphArmChanged" not in source
    assert 'calibrationState = "calibrating"' not in source
    assert 'calibrationState = "fault"' not in source

    # The Torso shortcut passes the chosen controller into the existing guarded
    # recovery flow. It must never start maintenance directly or reuse a stale
    # Diagnostics host, bypassing that window's motion interlocks.
    torso = (ROOT / "Cerebro/ROBTorsoControlsViewController.m").read_text()
    assert 'buttonWithTitle:@"Reconnect Amber Arms…"' in torso
    assert "[self setupAmberReconnectControl]" in torso
    assert "reconnectArmsWithHost:host" in torso
    assert "self.reconnectAmberArmsButton.enabled = !running" in torso
    reconnect = swift_function(source, "public func reconnectArms(host:")
    assert "showWindow(sender)" in reconnect
    assert "!stackMaintenance.isRunning, !stackRecoveryInProgress" in reconnect
    assert 'hostField.stringValue = trimmedHost.isEmpty ? "amber-master.local" : trimmedHost' in reconnect
    assert "restartCANCoreStack(sender)" in reconnect
    assert "stackMaintenance.restart(" not in reconnect

    restart = swift_function(source, "@objc private func restartCANCoreStack(")
    assert restart.count("!gestureExecutor.isExecuting") == 3
    assert restart.count("pendingManualCommandIDs.isEmpty") == 3
    assert restart.count("!hasActiveGripperCommand(refreshFromGateway: true)") == 3
    assert '== "RESTART"' in restart
    assert restart.index("authority.revoke()") < restart.index("tunnel.disconnect()")
    assert restart.index("tunnel.disconnect()") < restart.index("stackMaintenance.restart(")
    result = swift_function(source, "private func handleStackMaintenanceResult(")
    assert result.index("if result.success") < result.index("tunnel.connect(host: host)")
    assert "tunnel.connect" not in result.split("} else {", 1)[1]

    print("Amber diagnostics checks passed: dual-arm controls and guarded Torso reconnect")


if __name__ == "__main__":
    main()
