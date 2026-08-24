#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
server = (ROOT / "Cerebro/AutoNet/AutoNetServer/AutoNetServer.swift").read_text()
video = (ROOT / "Cerebro/ROBVideoServer.swift").read_text()
capture = (ROOT / "Cerebro/ROBRemoteDesktopCaptureService.swift").read_text()
protocol = (ROOT / "Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift").read_text()

claim = server.index("if remoteDesktopInputCoordinator.claimsProtocol(data)")
historical = server.index("dataDelegate?.didReceiveData(data)", claim)
assert claim < historical, "Desktop input could reach historical robot parsing"
assert "ROBAdministratorControllerAuthorization.isAuthorized(controllerID)" in server
assert "profile.role == .administrator" in server and "profile.enrollmentIsComplete" in server
assert "authenticatedDeviceID == deviceID" in server
assert "authenticatedSessionUUID == sessionID" in server
assert "AXIsProcessTrusted" in server and "CGPreflightScreenCaptureAccess" in server
assert "CGEvent(" in server and ".cghidEventTap" in server
assert "robControlLiveSessionDidEnd" in server and "releasePrimaryButton" in server
assert "ROBControlLiveSessionRegistry.isActiveOperator" in video
assert "ROBRemoteDesktopCaptureService.hasScreenCaptureAccess" in video
assert "supportedCodecs: [.jpeg, .h264]" in video
assert "desktopCapture.setActive" in video
assert "SCStream" in capture and "queueDepth = 2" in capture
assert 'Data("ROBDESK1".utf8)' in protocol

print("ROB remote desktop security static tests passed")
