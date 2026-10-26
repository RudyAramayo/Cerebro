#!/usr/bin/env python3
"""Exercise actual empty-hand observation UI handlers with inert file panels.

No AppKit window, private receipt, robot, camera or actuator is opened.
"""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT/'Cerebro/ROBTestingSandboxWindowController.swift').read_text()
enabled = braced_declaration(source, '    private var emptyHandObservationFilesEnabled: Bool')
exporter = braced_declaration(source, '    private func exportEmptyHandObservationTemplate()')
importer = braced_declaration(source, '    private func importEmptyHandObservation()')
route = braced_declaration(source, '    @objc private func performTrialAction(')
refresh = braced_declaration(source, '    @objc private func refresh()')
for command, handler in [('empty-observation-export','exportEmptyHandObservationTemplate()'),
                         ('empty-observation-import','importEmptyHandObservation()')]:
    assert source.count('command: "local-recycling:'+command+'"') == 2
    assert '"local-recycling:'+command+'"' in refresh
    assert route.index('"local-recycling:'+command+'"') < route.index('guard canEdit')
    assert handler in route
assert 'Record an actual observation that both grippers are empty; this does not approve or start motion.' in source
assert 'canEdit' in enabled and 'canImportLocalCanCampaignEmptyObservation' in enabled
for handler in (exporter, importer):
    assert handler.count('guard emptyHandObservationFilesEnabled') == 2
    assert 'panel.runModal() == .OK, let url = panel.url' in handler
    assert 'startAccessingSecurityScopedResource' in handler
    assert not any(x in handler for x in ['runStandingCanCampaign', 'prepareLocalRecyclingSessionJob',
        'performUsingLocalRecyclingReceipt', 'receiveSpokenAuthorization', 'prepareStationaryEmptyGrippers',
        'perform(', 'gateway.', 'localCanCampaignActive ='])
assert 'NSSavePanel()' in exporter and 'exportLocalCanCampaignEmptyObservationTemplate(to: url)' in exporter
assert 'NSOpenPanel()' in importer and 'importLocalCanCampaignEmptyObservation(fromReceiptURL: url)' in importer
assert 'canChooseDirectories = false' in importer and 'allowsMultipleSelection = false' in importer

fixture = r'''
import Foundation
enum Type {case json}
enum Modal {case OK,cancel}
enum PanelState {
 static var response=Modal.OK,url:URL?=URL(fileURLWithPath:"/private/tmp/isolated-observation.json")
 static var calls=0,onModal:(()->Void)?
 static func reset(){response = .OK;url=URL(fileURLWithPath:"/private/tmp/isolated-observation.json");calls=0;onModal=nil}
}
class NSSavePanel {
 var allowedContentTypes:[Type]=[],nameFieldStringValue="",title="",message=""
 var url:URL? {PanelState.url}
 func runModal()->Modal {PanelState.calls+=1;PanelState.onModal?();return PanelState.response}
}
final class NSOpenPanel:NSSavePanel {var canChooseDirectories=true,allowsMultipleSelection=true}
enum Rejection:Error {case invalid}
final class ROBControllerArmApproval {
 static let shared=ROBControllerArmApproval()
 var canImportLocalCanCampaignEmptyObservation=true,throwsOnImport=false,throwsOnExport=false
 var exports:[URL]=[],imports:[URL]=[],payloadUncertain=true
 func exportLocalCanCampaignEmptyObservationTemplate(to url:URL)throws {
  if throwsOnExport {throw Rejection.invalid};exports.append(url)
 }
 func importLocalCanCampaignEmptyObservation(fromReceiptURL url:URL)throws {
  if throwsOnImport {throw Rejection.invalid};imports.append(url);payloadUncertain=false
 }
 func reset(){canImportLocalCanCampaignEmptyObservation=true;throwsOnImport=false;throwsOnExport=false;exports=[];imports=[];payloadUncertain=true}
}
final class Sandbox {
 struct Trial {var id="right-recycling"}
 var selectedTrial=Trial(),canEdit=true,parameterMessage="",refreshes=0
 func refresh(){refreshes+=1}
 __ENABLED__
 __EXPORT__
 __IMPORT__
 func export(){exportEmptyHandObservationTemplate()}
 func importObservation(){importEmptyHandObservation()}
 var available:Bool {emptyHandObservationFilesEnabled}
}
@main enum Test {
 static func main() {
  let broker=ROBControllerArmApproval.shared
  func reset(){PanelState.reset();broker.reset()}
  for row in ["right-recycling","recycling"] {
   reset();let ui=Sandbox();ui.selectedTrial.id=row
   precondition(ui.available);ui.export()
   precondition(broker.exports==[PanelState.url!] && broker.imports.isEmpty && broker.payloadUncertain)
   precondition(ui.parameterMessage.contains("No motion was approved or started"))
   ui.importObservation()
   precondition(broker.imports==[PanelState.url!] && !broker.payloadUncertain)
   precondition(ui.parameterMessage.contains("did not approve, resume or start arm motion"))
  }
  for state in ["operation","terminal","wrong_row"] {
   reset();let ui=Sandbox()
   if state=="operation" {ui.canEdit=false}
   if state=="terminal" {broker.canImportLocalCanCampaignEmptyObservation=false}
   if state=="wrong_row" {ui.selectedTrial.id="ghost"}
   ui.export();ui.importObservation()
   precondition(!ui.available && PanelState.calls==0 && broker.exports.isEmpty && broker.imports.isEmpty && broker.payloadUncertain)
  }
  for outcome in ["cancel","no_url"] {
   reset();let ui=Sandbox()
   if outcome=="cancel" {PanelState.response = .cancel} else {PanelState.url=nil}
   ui.export();ui.importObservation()
   precondition(broker.exports.isEmpty && broker.imports.isEmpty && broker.payloadUncertain)
  }
  for action in ["export","import"] {
   for change in ["operation","campaign"] {
    reset();let ui=Sandbox()
    PanelState.onModal={if change=="operation" {ui.canEdit=false} else {broker.canImportLocalCanCampaignEmptyObservation=false}}
    if action=="export" {ui.export()} else {ui.importObservation()}
    precondition(broker.exports.isEmpty && broker.imports.isEmpty && broker.payloadUncertain && ui.parameterMessage.contains("changed while choosing the file"))
   }
  }
  reset();let badImport=Sandbox();broker.throwsOnImport=true;badImport.importObservation()
  precondition(broker.imports.isEmpty && broker.payloadUncertain && !badImport.parameterMessage.isEmpty)
  reset();let badExport=Sandbox();broker.throwsOnExport=true;badExport.export()
  precondition(broker.exports.isEmpty && broker.payloadUncertain && !badExport.parameterMessage.isEmpty)
  print("PASS empty-hand observation Sandbox: both recycling rows, native-selected URL routing, no automatic Run/approval/arm/jaw call, no active-job/terminal/non-can access, modal cancellation/source-change rechecks and invalid receipt preserves payload hold")
 }
}
'''.replace('__ENABLED__',enabled).replace('__EXPORT__',exporter).replace('__IMPORT__',importer)
with tempfile.TemporaryDirectory(prefix='rob-empty-observation-sandbox-',dir='/private/tmp') as directory:
    d=Path(directory);p=d/'Fixture.swift';p.write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(p),'-o',str(d/'fixture')],check=True,timeout=45)
    subprocess.run([str(d/'fixture')],check=True,timeout=10)
