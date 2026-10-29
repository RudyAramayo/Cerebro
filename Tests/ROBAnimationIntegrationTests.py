#!/usr/bin/env python3
"""Check the native scene/transport boundary wiring accompanying runtime tests."""
from pathlib import Path
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]
controller = (ROOT/'Cerebro/ROBTorsoControlsViewController.m').read_text()
assert 'KeyframeAnimationManager' not in controller
assert 'removeNamedKeyframeWithName' not in controller
assert 'connectWithLibrary:self.keyframeTableView' in controller
assert 'playSelectedSequence:' in controller and 'previewSelectedSequence' in controller
root = ET.parse(ROOT/'Cerebro/Base.lproj/Main.storyboard').getroot()
for table in root.iter('tableView'):
    if table.get('id') in ['Gme-fa-zN2','wbu-ik-Rol','P7f-99-QGj']:
        assert not table.findall('connections/outlet'), 'Storyboard must not call the removed mutable table data source'
buttons = {node.find('buttonCell').get('title'): node for node in root.iter('button') if node.find('buttonCell') is not None}
assert buttons['Preview Sequence'].find('connections/action').get('selector') == 'playSelectedSequence:'
assert buttons['Preview Pose'].find('connections/action').get('selector') == 'playCurrentlySelectedKeyframeAnimation:'
ghost = (ROOT/'Cerebro/ROBGhostGestureEditor.swift').read_text()
preview = ghost[ghost.index('@objc private func animationPreviewChanged'):ghost.index('init(sceneView:')]
assert 'sendLocalAnimation' not in preview and 'request' not in preview and 'executeButton.isEnabled = false' in preview
assert 'positions["torso_yaw"] = heading * .pi / 180' in preview
serial = (ROOT/'Cerebro/ROBSerialBox.m').read_text()
route = serial[serial.index('- (BOOL)applyAnimationMaestroValues:'):serial.index('- (BOOL)applyAnimationLACTPercent:')]
assert '[ROBAnimationPlayback shared].isRunning' in route
for reserved in range(6, 10): assert f'@"maestro.{reserved}"' not in route
assert 'requestOperatorNeckPosePanTarget' in route
assert 'stopWithReason:@"Manual Maestro control took over"' in serial
print('Animation integration: native tables, storyboard, ghost, protected channels, manual takeover passed')
