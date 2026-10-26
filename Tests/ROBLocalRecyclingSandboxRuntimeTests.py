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
hold_change = braced_declaration(source, '    @objc private func changeHoldAfterInitialEmptyLift()').replace('@objc ', '')
standing_run = braced_declaration(source, '    private func runStandingCanCampaign()')
resume = braced_declaration(source, '    public func resumeAuthorizedStandingCanCampaign(targetCanCount:').replace('public ', '')
selection = braced_declaration(source, '    public func tableViewSelectionDidChange(').replace('public ', '')
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
assert 'performUsingLocalRecyclingReceipt(command, target: String(Self.recyclingCount))' in prepare
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
enum ROBRecyclingBatchRequest {static let maximumCount=8}
enum UserDefaults {static let standard=FixtureDefaults()}
final class FixtureDefaults {
    var storedArm:String?
    func set(_ count:Int,forKey:String){Sandbox.recyclingCount=count}
    func set(_ arm:String,forKey:String){storedArm=arm}
    func string(forKey:String)->String?{storedArm}
}
final class FixtureTable {
    var onSelect:((Int)->Void)?
    func selectRowIndexes(_ rows:IndexSet,byExtendingSelection:Bool){onSelect?(rows.first!)}
}
/* HELPER */
final class ROBLeftArmTrial {
    static let shared = ROBLeftArmTrial()
    var localVisualTrialAssumedSpatialErrorMeters = 0.05
    var nominalEmptyCommissioningStepEnabled = false
    var oneDegreeEmptyCalibrationStepEnabled = false
    var holdAfterInitialEmptyLiftEnabled = false
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
    var standingCanCampaignMayHoldPayload = false
    var standingLocalCanCampaignState:NSDictionary?
    var cancellations=0,ticks=0
    func cancel(reason:String){cancellations+=1;localRecyclingApprovalState=nil;pendingLocalRecyclingApprovalScope=nil}
    func tick(){ticks+=1}
}
final class Sandbox {
    struct Toggle { enum State { case on, off }; var state:State = .off }
    struct Trial { var id:String }
    struct Field { var stringValue:String }
    static var recyclingCount = 4
    static let recyclingCountKey="isolated-fixture-count"
    static let recyclingArmKey="isolated-fixture-arm"
    static let trials=[Trial(id:"right-recycling"),Trial(id:"recycling")]
    let table=FixtureTable()
    var selectedTrial = Trial(id:"right-recycling")
    var fields = ["recyclingCount":Field(stringValue:"4"),"localVisualAllowanceMillimeters":Field(stringValue:"50")]
    var canEdit = true, observingLeftOperation = false, refreshes = 0,rebuilds=0
    var parameterMessage = "old"
    var nominalEmptyCommissioningStep = Toggle()
    var oneDegreeEmptyCalibrationStep = Toggle()
    var holdAfterInitialEmptyLift = Toggle()
    init(){table.onSelect={[weak self] row in self?.selectedTrial=Self.trials[row]}}
    func buildDetail(){rebuilds+=1;fields=["recyclingCount":Field(stringValue:String(Self.recyclingCount)),"localVisualAllowanceMillimeters":Field(stringValue:"50")]}
    func refresh(){refreshes += 1}
    /* PREPARE */
    /* NOMINAL_CHANGE */
    /* DEGREE_CHANGE */
    /* HOLD_CHANGE */
    /* STANDING_RUN */
    /* RESUME */
    /* SELECTION */
    func prepare(){prepareLocalRecyclingSessionJob()}
    func toggleNominal(){changeNominalEmptyCommissioningStep()}
    func toggleDegree(){changeOneDegreeEmptyCalibrationStep()}
    func toggleHold(){changeHoldAfterInitialEmptyLift()}
    func runStanding(){runStandingCanCampaign()}
}
@main enum Test {
    static func main() {
        let trial = ROBLeftArmTrial.shared
        for count in [1,4,5,8] {
            for (row,expected) in [("right-recycling","right_recycle_cans"),("recycling","left_recycle_cans")] {
                Sandbox.recyclingCount=count
                let ui=Sandbox();ui.fields["recyclingCount"] = .init(stringValue:String(count));ui.selectedTrial.id=row;ui.prepare()
                precondition(trial.calls.last!.0==expected && trial.calls.last!.1==String(count))
                precondition(ui.observingLeftOperation && ui.parameterMessage.isEmpty)
            }
        }
        for (row,saved,entered) in [("right-recycling",3,"4"),("recycling",4,"3"),
            ("recycling",4,"4.5"),("recycling",4,"nan"),("ghost",4,"4"),("recycling",0,"0"),("recycling",9,"9")] {
            let ui=Sandbox(); ui.selectedTrial.id=row; Sandbox.recyclingCount=saved
            ui.fields["recyclingCount"] = .init(stringValue:entered)
            let before=trial.calls.count;ui.prepare()
            precondition(trial.calls.count==before && ui.parameterMessage.contains("whole number"))
        }
        Sandbox.recyclingCount=4
        let holdOnly=Sandbox();holdOnly.holdAfterInitialEmptyLift.state = .on
        let holdBroker=ROBControllerArmApproval.shared,holdCancels=holdBroker.cancellations,holdTicks=holdBroker.ticks
        holdOnly.toggleHold()
        precondition(trial.holdAfterInitialEmptyLiftEnabled && !trial.nominalEmptyCommissioningStepEnabled && !trial.oneDegreeEmptyCalibrationStepEnabled)
        precondition(holdBroker.cancellations==holdCancels && holdBroker.ticks==holdTicks+1,"Lift-only context edit revoked standing authorization")
        holdOnly.prepare();precondition(trial.holdAfterInitialEmptyLiftEnabled)
        let leftHold=Sandbox();leftHold.selectedTrial.id="recycling";leftHold.holdAfterInitialEmptyLift.state = .on
        leftHold.prepare();precondition(!trial.holdAfterInitialEmptyLiftEnabled,"Right-only lift flag leaked into LEFT task")
        let mixedHold=Sandbox();mixedHold.holdAfterInitialEmptyLift.state = .on;mixedHold.oneDegreeEmptyCalibrationStep.state = .on
        let beforeMixedHold=trial.calls.count;mixedHold.prepare();precondition(trial.calls.count==beforeMixedHold && mixedHold.parameterMessage.contains("only one"))
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
        standingBroker.standingCanCampaignMayHoldPayload=true
        let beforeHeld=trial.calls.count;standing.runStanding()
        precondition(trial.calls.count==beforeHeld && standing.parameterMessage.contains("possible held object"))
        standingBroker.standingCanCampaignMayHoldPayload=false
        standingBroker.standingLocalCanCampaignState=["targetCanCount":3]
        let resumed=Sandbox();resumed.resumeAuthorizedStandingCanCampaign(targetCanCount:3)
        precondition(Sandbox.recyclingCount==3 && resumed.fields["recyclingCount"]?.stringValue=="3" && trial.calls.last?.1=="3",
            "Fresh voice resume did not bind the prior remaining count")
        standingBroker.standingCanCampaignMayHoldPayload=true
        let beforeResumeHeld=trial.calls.count;resumed.resumeAuthorizedStandingCanCampaign(targetCanCount:3)
        precondition(trial.calls.count==beforeResumeHeld && resumed.parameterMessage.contains("possible held object"),
            "A new voice authorization reset the possible-payload hold")
        standingBroker.standingCanCampaignMayHoldPayload=false
        let beforeMismatch=trial.calls.count;resumed.resumeAuthorizedStandingCanCampaign(targetCanCount:5)
        precondition(trial.calls.count==beforeMismatch && Sandbox.recyclingCount==3,"New authorization count was broadened by the UI hook")
        standingBroker.standingLocalCanCampaignActive=false;resumed.resumeAuthorizedStandingCanCampaign(targetCanCount:3)
        precondition(trial.calls.count==beforeMismatch,"Stop allowed a queued resume")
        standingBroker.standingLocalCanCampaignActive=true;Sandbox.recyclingCount=4
        for row in ["fixed-head-registration","neck-qr-calibration","preparation","ghost"] {
            for savedArm in [nil,"left","right","invalid"] as [String?] {
                UserDefaults.standard.storedArm=savedArm
                let ui=Sandbox();ui.selectedTrial.id=row;ui.fields=[:]
                let before=trial.calls.count;ui.resumeAuthorizedStandingCanCampaign(targetCanCount:3)
                let expected=savedArm=="left" ? "left_recycle_cans":"right_recycle_cans"
                precondition(trial.calls.count==before+1 && trial.calls.last!.0==expected && trial.calls.last!.1=="3" && ui.rebuilds>0,
                    "Resume from a non-can panel acknowledged without rebuilding and routing the can task")
                precondition(ui.fields["recyclingCount"]?.stringValue=="3" && ui.fields["localVisualAllowanceMillimeters"] != nil)
            }
        }
        for (current,saved,expected) in [("recycling","right","left_recycle_cans"),("right-recycling","left","right_recycle_cans")] {
            UserDefaults.standard.storedArm=saved
            let ui=Sandbox();ui.selectedTrial.id=current;ui.resumeAuthorizedStandingCanCampaign(targetCanCount:3)
            precondition(trial.calls.last?.0==expected && ui.rebuilds==0,"Resume replaced an explicitly selected recycling arm")
        }
        let remembered=Sandbox();remembered.selectedTrial.id="recycling"
        remembered.tableViewSelectionDidChange(Notification(name:Notification.Name("fixture selection")))
        precondition(UserDefaults.standard.storedArm=="left","Selected recycling side was not persisted")
        remembered.selectedTrial.id="ghost";remembered.tableViewSelectionDidChange(Notification(name:Notification.Name("fixture selection")))
        precondition(UserDefaults.standard.storedArm=="left","Inspecting another test replaced the saved recycling side")
        UserDefaults.standard.storedArm=nil;Sandbox.recyclingCount=4
        let standingStatus=ROBLocalRecyclingSandboxRouting.standingDescription(["state":"recovering","completedTransfers":1,
            "verifiedLandings":0,"targetCanCount":5,"detail":"Fresh CAN and camera revalidation","sourceMessage":"PRIVATE USER TEXT"])
        precondition(standingStatus.contains("recovering") && standingStatus.contains("Transfers reported 1/5") &&
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
        for count in [1,5,8] {
            let changed=scope.mutableCopy() as! NSMutableDictionary;changed["canCount"]=count
            precondition(ROBLocalRecyclingSandboxRouting.receiptFilesEnabled(trialID:"right-recycling",pendingScope:changed,operationRunning:false))
            precondition(ROBLocalRecyclingSandboxRouting.scopeDescription(pending:changed,imported:nil).contains("Job: \(count) empty Coke cans"))
        }
        for (key,value) in [("canCount",0 as Any),("canCount",9 as Any),("canCount",4.5 as Any),("command","right_wave" as Any),("arm","left" as Any)] {
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
        print("PASS local recycling sandbox: exact saved1...8 count/side routing, fresh remaining-count resume, payload/Stop guard, immutable pending file controls and private source text excluded")
        print("PASS live sandbox status: active phase precedes broker scope, common-mode progress fallback; selected RIGHT recording cannot open latest LEFT evidence")
    }
}
'''.replace('/* HELPER */', helper).replace('/* PREPARE */', prepare).replace('/* NOMINAL_CHANGE */', nominal_change).replace('/* DEGREE_CHANGE */', degree_change).replace('/* HOLD_CHANGE */', hold_change).replace('/* STANDING_RUN */', standing_run).replace('/* RESUME */', resume).replace('/* SELECTION */', selection)

with tempfile.TemporaryDirectory(prefix='rob-local-recycling-sandbox-', dir='/private/tmp') as folder:
    root = Path(folder); path = root / 'Fixture.swift'; path.write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(root / 'fixture')], check=True, timeout=45)
    subprocess.run([str(root / 'fixture')], check=True, timeout=10)
