#!/usr/bin/env python3

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "Cerebro" / "ROBPythonSettingsWindowController.m").read_text()
MAIN_HEADER = (ROOT / "Cerebro" / "ROBMainViewController.h").read_text()
MAIN = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text()
TRANSPORT = (
    ROOT
    / "Cerebro"
    / "AutoNet"
    / "AutoNetShared"
    / "AutoNetDataTransferProtocol.swift"
).read_text()


assert 'accessibilityIdentifier = @"ROB.Controllers.DeviceList"' in SETTINGS
assert '@"Pair ROBController…"' in SETTINGS
assert '@"Pair RPLidar…"' in SETTINGS
assert '@"Delete Pairing…"' in SETTINGS
assert "device.deviceName" in SETTINGS
assert "device.deviceID" in SETTINGS
assert "device.issuedAt" in SETTINGS
assert "device.revokedAt" in SETTINGS
assert '@"Full robot control"' in SETTINGS
assert '@"Lidar telemetry only"' in SETTINGS
assert "active pairings" in SETTINGS and "removed credential" in SETTINGS

assert "[mainViewController revokePairedControlDevice:device error:&error]" in SETTINGS
assert "revokePairedControlDevice:(ROBControlPairedDevice *)device" in MAIN_HEADER
assert "revokePairedControlDevice:(ROBControlPairedDevice *)device" in MAIN
assert "stopBaseMotionAndDropHeartbeat" in MAIN
assert "switchToMasterControllerID:@\"Brain\"" in MAIN

assert "public let issuedAt: Date" in TRANSPORT
assert "public let revokedAt: Date?" in TRANSPORT
assert "robControlPairedDevicesDidChange" in TRANSPORT
assert TRANSPORT.count("post(name: .robControlPairedDevicesDidChange") == 2

print("ROB paired control devices UI static fixtures passed")
