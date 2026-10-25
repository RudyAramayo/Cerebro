#!/usr/bin/env python3
"""Run actual local-job UI routing without AppKit windows, files or hardware."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Cerebro/ROBTestingSandboxWindowController.swift').read_text()
helper = braced_declaration(source, 'enum ROBLocalRecyclingSandboxRouting {')
prepare = braced_declaration(source, '    private func prepareLocalRecyclingSessionJob()')
route = braced_declaration(source, '    @objc private func performTrialAction(')
refresh = braced_declaration(source, '    @objc private func refresh()')
export = braced_declaration(source, '    private func exportLocalRecyclingApprovalTemplate()')
importer = braced_declaration(source, '    private func importLocalRecyclingApprovalReceipt()')
stop = braced_declaration(source, '    @objc private func stop()')

# Receipt file selection remains available while ordinary edits are disabled.
for command in ('local-recycling:export', 'local-recycling:import'):
    assert route.index(command) < route.index('guard canEdit'), command
assert route.index('local-recycling:prepare') < route.index('guard canEdit')
assert 'guard canEdit' in prepare
assert 'performUsingLocalRecyclingReceipt(command, target: "4")' in prepare
assert prepare.index('localVisualTrialAssumedSpatialErrorMeters = spatial') < prepare.index('performUsingLocalRecyclingReceipt')
assert 'ROBArmRoutineCoordinator' not in prepare
assert 'localReceiptFilesEnabled' in refresh and '? localReceiptFilesEnabled' in refresh
assert 'NSSavePanel()' in export and 'localRecyclingReceiptTemplate' in export
assert '.posixPermissions: 0o600' in export
assert 'NSOpenPanel()' in importer and 'panel.runModal() == .OK' in importer
assert 'importLocalRecyclingSessionApproval(fromReceiptURL: url)' in importer
assert 'receiveSpokenAuthorization' not in importer and '.receive(' not in importer
assert 'ROBControllerArmApproval.shared.cancel(reason:' in stop
assumption_edit = braced_declaration(source, '    public func controlTextDidChange(')
assert 'localRecyclingApprovalState != nil' in assumption_edit and 'approval.cancel(reason:' in assumption_edit
assert 'approval.tick()' in assumption_edit
for name in ('Cerebro/ROBAI.swift', 'Cerebro/ROBArmRoutineCoordinator.swift'):
    other = (ROOT / name).read_text()
    assert 'importLocalRecyclingSessionApproval' not in other
    assert 'performUsingLocalRecyclingReceipt' not in other
    assert 'localRecyclingReceiptTemplate' not in other

fixture = r'''
import Foundation
/* HELPER */
final class ROBLeftArmTrial {
    static let shared = ROBLeftArmTrial()
    var localVisualTrialAssumedSpatialErrorMeters = 0.05
    var calls:[(String,String)] = []
    func performUsingLocalRecyclingReceipt(_ command:String,target:String,completion:@escaping(NSDictionary)->Void) {
        calls.append((command,target)); completion(["status":"prepared"])
    }
}
final class Sandbox {
    struct Trial { var id:String }
    struct Field { var stringValue:String }
    static var recyclingCount = 4
    var selectedTrial = Trial(id:"right-recycling")
    var fields = ["recyclingCount":Field(stringValue:"4"),"localVisualAllowanceMillimeters":Field(stringValue:"50")]
    var canEdit = true, observingLeftOperation = false, refreshes = 0
    var parameterMessage = "old"
    func refresh(){refreshes += 1}
    /* PREPARE */
    func prepare(){prepareLocalRecyclingSessionJob()}
}
@main enum Test {
    static func main() {
        let trial = ROBLeftArmTrial.shared
        for (row,expected) in [("right-recycling","right_recycle_cans"),("recycling","left_recycle_cans")] {
            let ui=Sandbox(); ui.selectedTrial.id=row; ui.prepare()
            precondition(trial.calls.last!.0==expected && trial.calls.last!.1=="4")
            precondition(ui.observingLeftOperation && ui.parameterMessage.isEmpty)
        }
        for (row,saved,entered) in [("right-recycling",3,"4"),("recycling",4,"3"),
            ("recycling",4,"4.5"),("recycling",4,"nan"),("ghost",4,"4")] {
            let ui=Sandbox(); ui.selectedTrial.id=row; Sandbox.recyclingCount=saved
            ui.fields["recyclingCount"] = .init(stringValue:entered)
            let before=trial.calls.count;ui.prepare()
            precondition(trial.calls.count==before && ui.parameterMessage.contains("exactly four"))
        }
        Sandbox.recyclingCount=4
        let adjusted=Sandbox();adjusted.fields["localVisualAllowanceMillimeters"] = .init(stringValue:"35");adjusted.prepare()
        precondition(trial.localVisualTrialAssumedSpatialErrorMeters==0.035)
        for raw in ["24.9","150.1","nan","inf","invalid"] {
            let ui=Sandbox();ui.fields["localVisualAllowanceMillimeters"] = .init(stringValue:raw)
            let before=trial.calls.count;ui.prepare()
            precondition(trial.calls.count==before && ui.parameterMessage.contains("25 to 150"))
        }
        precondition(ROBLocalRecyclingSandboxRouting.spatialAllowanceMeters(25)==0.025 &&
            ROBLocalRecyclingSandboxRouting.spatialAllowanceMeters(150)==0.15)
        let frozen=Sandbox();frozen.canEdit=false;let before=trial.calls.count;frozen.prepare()
        precondition(trial.calls.count==before && !frozen.observingLeftOperation)
        let scope:NSDictionary=["command":"right_recycle_cans","arm":"right","canCount":4,
            "summary":"Immutable four-can scope","summarySHA256":"fixture hash","contextIdentity":"current context",
            "permitsUnmeasuredVisualCalibrationTrial":true]
        precondition(ROBLocalRecyclingSandboxRouting.receiptFilesEnabled(trialID:"right-recycling",pendingScope:scope,operationRunning:false))
        precondition(!ROBLocalRecyclingSandboxRouting.receiptFilesEnabled(trialID:"recycling",pendingScope:scope,operationRunning:false))
        precondition(!ROBLocalRecyclingSandboxRouting.receiptFilesEnabled(trialID:"right-recycling",pendingScope:scope,operationRunning:true))
        precondition(!ROBLocalRecyclingSandboxRouting.receiptFilesEnabled(trialID:"right-recycling",pendingScope:nil,operationRunning:false))
        for (key,value) in [("canCount",3 as Any),("canCount",4.5 as Any),("command","right_wave" as Any),("arm","left" as Any)] {
            let changed=scope.mutableCopy() as! NSMutableDictionary;changed[key]=value
            precondition(!ROBLocalRecyclingSandboxRouting.receiptFilesEnabled(trialID:"right-recycling",pendingScope:changed,operationRunning:false))
        }
        let pending=ROBLocalRecyclingSandboxRouting.scopeDescription(pending:scope,imported:nil)
        precondition(pending.contains("no grant") && pending.contains("right_recycle_cans") && pending.contains("Immutable four-can scope"))
        let imported=scope.mutableCopy() as! NSMutableDictionary
        imported["state"]="available";imported["source"]="explicit_local_OS_file_import";imported["receiptID"]="fixture receipt"
        imported["sourceMessage"]="PRIVATE SOURCE MUST NOT APPEAR";imported["additionalUserInstruction"]="PRIVATE ADDITIONAL MUST NOT APPEAR"
        let available=ROBLocalRecyclingSandboxRouting.scopeDescription(pending:nil,imported:imported)
        precondition(available.contains("available") && available.contains("fixture receipt") && !available.contains("PRIVATE"))
        imported["state"]="executing"
        precondition(ROBLocalRecyclingSandboxRouting.scopeDescription(pending:nil,imported:imported).contains("executing"))
        precondition(ROBLocalRecyclingSandboxRouting.scopeDescription(pending:nil,imported:nil).contains("no imported job"))
        print("PASS local recycling sandbox: exact saved four-can/side routing, immutable pending file controls, executing/mismatched scopes disabled, private source text excluded, dedicated local-only OS import/export and unconditional Stop revocation")
    }
}
'''.replace('/* HELPER */', helper).replace('/* PREPARE */', prepare)

with tempfile.TemporaryDirectory(prefix='rob-local-recycling-sandbox-', dir='/private/tmp') as folder:
    root = Path(folder); path = root / 'Fixture.swift'; path.write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(root / 'fixture')], check=True, timeout=45)
    subprocess.run([str(root / 'fixture')], check=True, timeout=10)
