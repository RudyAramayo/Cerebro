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
nominal_change = braced_declaration(source, '    @objc private func changeNominalEmptyCommissioningStep()').replace('@objc ', '')
degree_change = braced_declaration(source, '    @objc private func changeOneDegreeEmptyCalibrationStep()').replace('@objc ', '')
standing_run = braced_declaration(source, '    private func runStandingCanCampaign()')
standing_import = braced_declaration(source, '    private func importStandingCanCampaign()')
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
assert prepare.index('nominalEmptyCommissioningStepEnabled = nominalEmptyCommissioningStep.state == .on') < prepare.index('performUsingLocalRecyclingReceipt')
assert 'sandbox-nominal-empty-commissioning-step' in source
assert 'Current robot occupancy is assumed from the model; calibration error and nearby unobserved space remain unverified.' in source
assert 'No grip, carry, release or automatic return. Zero cans are transferred.' in source
assert 'nominalEmptyCommissioningStep.isEnabled = canEdit' in refresh
assert prepare.index('oneDegreeEmptyCalibrationStepEnabled = oneDegreeEmptyCalibrationStep.state == .on') < prepare.index('performUsingLocalRecyclingReceipt')
assert 'sandbox-one-degree-empty-calibration-step' in source
assert 'Contact could push the table or lift ROB.' in source
assert 'contact predictions are diagnostic only' in source
assert 'oneDegreeEmptyCalibrationStep.isEnabled = canEdit' in refresh
assert 'NSOpenPanel()' in standing_import and 'importLocalCanCampaignAuthorization(fromReceiptURL: url)' in standing_import
assert 'standingLocalCanCampaignState' in refresh and 'standingDescription(' in refresh
assert 'nominalEmptyCommissioningStepEnabled = false' in standing_run and 'oneDegreeEmptyCalibrationStepEnabled = false' in standing_run
assert 'prepareLocalRecyclingSessionJob()' in standing_run
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
assert 'Notification.Name("ROBArmRoutineDidChange")' in source
assert 'RunLoop.main.add(timer, forMode: .common)' in source
assert 'ROBLeftArmTrial.shared.isRunning || ROBControllerArmApproval.shared.isPending { self.refresh() }' in source
assert 'activityStatus(trialRunning: left.isRunning' in refresh
recording = braced_declaration(source, '    @objc private func showRecording()')
assert 'latestRecordingURL(trialID: selectedTrial.id' in recording
for name in ('Cerebro/ROBAI.swift', 'Cerebro/ROBArmRoutineCoordinator.swift'):
    other = (ROOT / name).read_text()
    assert 'importLocalRecyclingSessionApproval' not in other
    assert 'performUsingLocalRecyclingReceipt' not in other
    assert 'localRecyclingReceiptTemplate' not in other
    assert 'importLocalCanCampaignAuthorization' not in other

fixture = r'''
import Foundation
/* HELPER */
final class ROBLeftArmTrial {
    static let shared = ROBLeftArmTrial()
    var localVisualTrialAssumedSpatialErrorMeters = 0.05
    var nominalEmptyCommissioningStepEnabled = false
    var oneDegreeEmptyCalibrationStepEnabled = false
    var isRunning = false
    var completionResult:NSDictionary = ["status":"prepared"]
    var calls:[(String,String)] = []
    func performUsingLocalRecyclingReceipt(_ command:String,target:String,completion:@escaping(NSDictionary)->Void) {
        calls.append((command,target)); completion(completionResult)
    }
}
final class ROBControllerArmApproval {
    static let shared=ROBControllerArmApproval()
    var localRecyclingApprovalState:NSDictionary?,pendingLocalRecyclingApprovalScope:NSDictionary?
    var isPending = false
    var standingLocalCanCampaignActive = false
    var cancellations=0,ticks=0
    func cancel(reason:String){cancellations+=1;localRecyclingApprovalState=nil;pendingLocalRecyclingApprovalScope=nil}
    func tick(){ticks+=1}
}
final class Sandbox {
    struct Toggle { enum State { case on, off }; var state:State = .off }
    struct Trial { var id:String }
    struct Field { var stringValue:String }
    static var recyclingCount = 4
    var selectedTrial = Trial(id:"right-recycling")
    var fields = ["recyclingCount":Field(stringValue:"4"),"localVisualAllowanceMillimeters":Field(stringValue:"50")]
    var canEdit = true, observingLeftOperation = false, refreshes = 0
    var parameterMessage = "old"
    var nominalEmptyCommissioningStep = Toggle()
    var oneDegreeEmptyCalibrationStep = Toggle()
    func refresh(){refreshes += 1}
    /* PREPARE */
    /* NOMINAL_CHANGE */
    /* DEGREE_CHANGE */
    /* STANDING_RUN */
    func prepare(){prepareLocalRecyclingSessionJob()}
    func toggleNominal(){changeNominalEmptyCommissioningStep()}
    func toggleDegree(){changeOneDegreeEmptyCalibrationStep()}
    func runStanding(){runStandingCanCampaign()}
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
        let commissioning=Sandbox(); commissioning.nominalEmptyCommissioningStep.state = .on; commissioning.prepare()
        precondition(trial.nominalEmptyCommissioningStepEnabled,"Explicit local checkbox was not frozen before preparation")
        let ordinary=Sandbox(); ordinary.prepare()
        precondition(!trial.nominalEmptyCommissioningStepEnabled,"New ordinary UI state inherited the commissioning option")
        for status in ["blocked","rejected","busy","failed"] {
            let noReceipt=Sandbox();trial.completionResult=["status":status,"detail":"Fresh enrolled RGB-D is required"]
            noReceipt.prepare()
            precondition(noReceipt.parameterMessage=="Fresh enrolled RGB-D is required" && !noReceipt.observingLeftOperation,
                "A rejected preparation stayed stuck on the old awaiting-receipt phase")
        }
        for (running,pending) in [(true,false),(false,true),(true,true)] {
            trial.isRunning=running;ROBControllerArmApproval.shared.isPending=pending
            let live=Sandbox();trial.completionResult=["status":"busy","detail":"Late preparation detail"]
            live.prepare();precondition(live.parameterMessage.isEmpty && live.observingLeftOperation,
                "A late callback overwrote a live task or pending receipt phase")
        }
        trial.isRunning=false;ROBControllerArmApproval.shared.isPending=false;trial.completionResult=["status":"prepared"]
        let standing=Sandbox();let standingBroker=ROBControllerArmApproval.shared
        let beforeStanding=trial.calls.count;standing.runStanding()
        precondition(trial.calls.count==beforeStanding && standing.parameterMessage.contains("No active standing"))
        standingBroker.standingLocalCanCampaignActive=true
        standing.nominalEmptyCommissioningStep.state = .on;standing.oneDegreeEmptyCalibrationStep.state = .on
        standing.runStanding()
        precondition(trial.calls.count==beforeStanding+1 && !trial.nominalEmptyCommissioningStepEnabled &&
            !trial.oneDegreeEmptyCalibrationStepEnabled,"Standing Run inherited an old tiny calibration mode")
        let standingStatus=ROBLocalRecyclingSandboxRouting.standingDescription(["state":"recovering","completedTransfers":1,
            "verifiedLandings":0,"detail":"Fresh CAN and camera revalidation","sourceMessage":"PRIVATE USER TEXT"])
        precondition(standingStatus.contains("recovering") && standingStatus.contains("Transfers reported 1/4") &&
            standingStatus.contains("camera-verified 0") && !standingStatus.contains("PRIVATE"))
        let degree=Sandbox();degree.oneDegreeEmptyCalibrationStep.state = .on;degree.prepare()
        precondition(trial.oneDegreeEmptyCalibrationStepEnabled && !trial.nominalEmptyCommissioningStepEnabled)
        let both=Sandbox();both.oneDegreeEmptyCalibrationStep.state = .on;both.nominalEmptyCommissioningStep.state = .on
        let beforeBoth=trial.calls.count;both.prepare();precondition(trial.calls.count==beforeBoth && both.parameterMessage.contains("only one"))
        let switcher=Sandbox(),approval=ROBControllerArmApproval.shared
        approval.pendingLocalRecyclingApprovalScope=["prepared":true]
        switcher.nominalEmptyCommissioningStep.state = .on;switcher.toggleNominal()
        precondition(trial.nominalEmptyCommissioningStepEnabled && !trial.oneDegreeEmptyCalibrationStepEnabled && approval.cancellations==1)
        approval.localRecyclingApprovalState=["imported":true]
        switcher.oneDegreeEmptyCalibrationStep.state = .on;switcher.toggleDegree()
        precondition(trial.oneDegreeEmptyCalibrationStepEnabled && !trial.nominalEmptyCommissioningStepEnabled &&
            switcher.nominalEmptyCommissioningStep.state == .off && approval.cancellations==2)
        switcher.canEdit=false;switcher.nominalEmptyCommissioningStep.state = .on;switcher.toggleNominal()
        precondition(trial.oneDegreeEmptyCalibrationStepEnabled && !trial.nominalEmptyCommissioningStepEnabled,
            "Disabled settings changed an active prepared experiment")
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
        imported["nominalEmptyCommissioningStepEnabled"]=true
        let commissioningDescription=ROBLocalRecyclingSandboxRouting.scopeDescription(pending:nil,imported:imported)
        precondition(commissioningDescription.contains("one slow empty-arm outward step") &&
            commissioningDescription.contains("Zero transfers") && commissioningDescription.contains("unverified") &&
            commissioningDescription.contains("Current robot occupancy is assumed from the model") &&
            !commissioningDescription.contains("PRIVATE"),"The exact commissioning scope/risk must remain visible without private source text")
        imported["nominalEmptyCommissioningStepEnabled"]=false;imported["oneDegreeEmptyCalibrationStepEnabled"]=true
        let degreeDescription=ROBLocalRecyclingSandboxRouting.scopeDescription(pending:nil,imported:imported)
        precondition(degreeDescription.contains("J2 −0.02 rad, 4 seconds") && degreeDescription.contains("Collision clearance unverified") &&
            degreeDescription.contains("contact predictions diagnostic only") && degreeDescription.contains("lift ROB") &&
            degreeDescription.contains("Zero transfers") && !degreeDescription.contains("PRIVATE"))
        precondition(ROBLocalRecyclingSandboxRouting.scopeDescription(pending:nil,imported:nil).contains("no imported job"))
        let live=ROBLocalRecyclingSandboxRouting.activityStatus(trialRunning:true,trialStatus:"Searching: third camera view",
            approvalPending:true,approvalStatus:"Authorized immutable scope",localReceiptState:imported)!
        precondition(live.contains("receipt executing") && live.contains("Searching: third camera view") && !live.contains("Authorized immutable"))
        precondition(ROBLocalRecyclingSandboxRouting.activityStatus(trialRunning:true,trialStatus:"Checking actual arm clearance",
            approvalPending:true,approvalStatus:"old broker state",localReceiptState:nil)=="Checking actual arm clearance")
        precondition(ROBLocalRecyclingSandboxRouting.activityStatus(trialRunning:false,trialStatus:"old phase",
            approvalPending:true,approvalStatus:"Waiting for receipt",localReceiptState:nil)=="Waiting for receipt")
        precondition(ROBLocalRecyclingSandboxRouting.activityStatus(trialRunning:false,trialStatus:"old phase",
            approvalPending:false,approvalStatus:"old approval",localReceiptState:nil)==nil)
        let support=FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-arm-recording-"+UUID().uuidString)
        let right=support.appendingPathComponent("Cerebro/RightArmTrials")
        try! FileManager.default.createDirectory(at:right,withIntermediateDirectories:true)
        defer{try?FileManager.default.removeItem(at:support)}
        let old=right.appendingPathComponent("right_recycle_can-old.csv"),new=right.appendingPathComponent("right_recycle_can-new.csv")
        let other=support.appendingPathComponent("left_recycle_can-latest.csv")
        for (url,time) in [(old,100.0),(new,200.0),(other,300.0)] {
            try! Data("synthetic recording".utf8).write(to:url)
            try! FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:time)],ofItemAtPath:url.path)
        }
        let selectedRight=ROBLocalRecyclingSandboxRouting.latestRecordingURL(trialID:"right-recycling",lastRecordingPath:other.path,
            applicationSupport:support)
        precondition(selectedRight?.standardizedFileURL.path==new.standardizedFileURL.path,"Right task opened the newer LEFT task recording")
        precondition(ROBLocalRecyclingSandboxRouting.latestRecordingURL(trialID:"right-estimated-calibration",lastRecordingPath:old.path,
            applicationSupport:support)?.standardizedFileURL.path==new.standardizedFileURL.path,"Right calibration did not find the newest matching recording")
        precondition(ROBLocalRecyclingSandboxRouting.latestRecordingURL(trialID:"recycling",lastRecordingPath:other.path,
            applicationSupport:support)?.standardizedFileURL.path==other.standardizedFileURL.path,"Selected left recycling must preserve its own recording")
        print("PASS local recycling sandbox: exact saved four-can/side routing, immutable pending file controls, executing/mismatched scopes disabled, private source text excluded, dedicated local-only OS import/export and unconditional Stop revocation")
        print("PASS live sandbox status: active phase precedes broker scope, common-mode progress fallback; selected RIGHT recording cannot open latest LEFT evidence")
    }
}
'''.replace('/* HELPER */', helper).replace('/* PREPARE */', prepare).replace('/* NOMINAL_CHANGE */', nominal_change).replace('/* DEGREE_CHANGE */', degree_change).replace('/* STANDING_RUN */', standing_run)

with tempfile.TemporaryDirectory(prefix='rob-local-recycling-sandbox-', dir='/private/tmp') as folder:
    root = Path(folder); path = root / 'Fixture.swift'; path.write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(root / 'fixture')], check=True, timeout=45)
    subprocess.run([str(root / 'fixture')], check=True, timeout=10)
