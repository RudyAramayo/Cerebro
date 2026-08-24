#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
server = (ROOT / "Cerebro/AutoNet/AutoNetServer/AutoNetServer.swift").read_text()
protocol = (ROOT / "Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift").read_text()

claim = server.index("if administratorTerminalCoordinator.claimsProtocol(data)")
historical_parser = server.index("dataDelegate?.didReceiveData(data)", claim)
assert claim < historical_parser, "Terminal frames could reach historical command parsing"
assert "sendingConnection.authenticatedRole == .operatorController" in server
assert "authenticatedDeviceID == deviceID" in server
assert "authenticatedSessionUUID == sessionID" in server
assert "profile.role == .administrator" in server
assert "profile.enrollmentIsComplete" in server
assert "profile.trustedEnrollmentReference" in server
assert 'executableURL = URL(fileURLWithPath: "/bin/zsh")' in server
assert 'shell.arguments = ["-l", "-i"]' in server
assert "openpty(" in server and "TIOCSWINSZ" in server
assert "maximumTabs" in server and "maximumBufferedOutputBytes" in server
assert "administratorTerminalCoordinator.closeSessions(for: deviceID)" in server
assert 'Data("ROBTPTY1".utf8)' in protocol

print("ROB administrator terminal security static tests passed")
