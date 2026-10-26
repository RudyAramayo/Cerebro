#!/usr/bin/env python3
"""Exercise actual terminal-lift and batch control flow with passive seams."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

root = Path(__file__).resolve().parents[1]
source = (root / "Cerebro/ROBLeftArmTrial.swift").read_text()
batch = braced_declaration(source, '@MainActor private func execute(_ command: String) async throws -> NSDictionary {')
batch = batch.replace('@MainActor private func', 'func', 1)
move = braced_declaration(source, '@MainActor private func move(_ proposal: ROBLeftGestureProposal) async throws {')
terminal = braced_declaration(move, 'if proposal.kind=="recycling_grasp_hold" {')
batch_request = braced_declaration((root / 'Cerebro/ROBWorkspaceSearchPlan.swift').read_text(), 'enum ROBRecyclingBatchRequest {')
fixture = r'''
import Foundation
/* BATCH_REQUEST */
enum ROBArmRoutineError:Error {case blocked(String)}
enum ROBGhostMotionError:Error {case blocked(String)}
enum Verdict:String {case supported,inconclusive}
struct Evidence {var verdict:Verdict;let reason="synthetic raw evidence"}
enum Jaw {case grip,release}
struct Step {var stage:String?="Verification lift";var jawAction:Jaw?=nil}
struct Proposal {var kind="recycling_grasp_hold";var steps=[Step()]}
struct Sample {let positionsRadians=[NSNumber](repeating:0,count:7)}
@MainActor enum ROBRecyclingVisualInspection {
    struct Context {}
    static var verdict=Verdict.supported,verificationCalls=0
    static func verifyAfterLift(context:Context,model:String,gatewayArm:String,check:() throws->Void)async throws->Evidence {
        try check();verificationCalls+=1;return Evidence(verdict:verdict)
    }
}
@MainActor final class Fixture {
    var requestedCanCount=4,physicalSide="right",calls=0
    var localReceiptCommand:String?,localReceiptEvidence:NSDictionary?
    var activeHoldAfterInitialEmptyLift=false,oneDegreeEmptyCalibrationStepEnabled=false,nominalEmptyCommissioningStepEnabled=false
    var localReceiptHeldNeckIdentity:String?,recyclingCan:String?,lastVisualGraspEvidence:Evidence?
    var movingTargetReplansRemaining=0,recyclingGripDispatched=false,sceneCapturedForThisTask=false
    var collisionMap:String?,collisionModel:String?,collisionReviewProposal:String?
    var result:NSDictionary=["status":"partial_held","motion_completed":false,"transfer_completed":false,"grasp_visually_supported":true]
    var holdCalls=0,savedEvidence=0
    let model="fixture",arm="left"
    func check()throws {}
    func update(_ message:String) {}
    func executeSingle(_ command:String)async throws->NSDictionary {calls+=1;return result}
    func executeOneDegreeEmptyCalibration()async throws->NSDictionary {preconditionFailure("Unconfigured calibration seam reached")}
    func executeNominalEmptyCommissioning()async throws->NSDictionary {preconditionFailure("Unconfigured commissioning seam reached")}
    func measured()throws->Sample {Sample()}
    func holdTaskPosition(_ q:[Double])async throws {holdCalls+=1}
    func writeVisualGraspEvidence(_ e:Evidence)throws {savedEvidence+=1}
    /* BATCH */
    func terminal(proposal:Proposal=Proposal(),visual:String?="explicit-trial",carrying:Bool=true,
        visualContext:ROBRecyclingVisualInspection.Context?=ROBRecyclingVisualInspection.Context())async throws {
        /* TERMINAL */
    }
}
@main enum Test {
    @MainActor static func main()async throws {
        let partial=Fixture(),r=try await partial.execute("left_recycle_can")
        precondition(partial.calls==1 && r["batch_completed"] as? Int==0 && r["transfer_completed"] as? Bool==false)
        let unsupported=Fixture();unsupported.result=["status":"blocked","motion_completed":true,"grasp_visually_supported":false]
        let unsupportedResult=try await unsupported.execute("left_recycle_can")
        precondition(unsupportedResult["batch_completed"] as? Int==0 && unsupported.calls==1)
        let full=Fixture();full.result=["status":"accepted_unverified","motion_completed":true,"grasp_visually_supported":true]
        let done=try await full.execute("left_recycle_can")
        precondition(full.calls==4 && done["batch_completed"] as? Int==4)
        let supported=Fixture();try await supported.terminal()
        precondition(supported.holdCalls==1 && supported.savedEvidence==1 && ROBRecyclingVisualInspection.verificationCalls==1)
        ROBRecyclingVisualInspection.verdict = .inconclusive
        let unclear=Fixture()
        do {try await unclear.terminal();preconditionFailure("Inconclusive lift was accepted")}catch{}
        precondition(unclear.holdCalls==1 && unclear.savedEvidence==1 && unclear.lastVisualGraspEvidence?.verdict == .inconclusive)
        let before=ROBRecyclingVisualInspection.verificationCalls
        for invalid in [Proposal(steps:[Step(stage:"Carry")]),Proposal(steps:[Step(jawAction:.release)])] {
            do {try await Fixture().terminal(proposal:invalid);preconditionFailure("Nonterminal/release accepted")}catch{}
        }
        do {try await Fixture().terminal(visual:nil);preconditionFailure("No explicit trial accepted")}catch{}
        do {try await Fixture().terminal(carrying:false);preconditionFailure("No held-object state accepted")}catch{}
        do {try await Fixture().terminal(visualContext:nil);preconditionFailure("No preclose baseline accepted")}catch{}
        precondition(ROBRecyclingVisualInspection.verificationCalls==before)
        print("PASS actual terminal-lift/batch flow: verify after final lift, supported and inconclusive both hold, no release/carry, partial/unsupported stops at0transfers; complete4-transfer behavior unchanged")
    }
}
'''.replace('/* BATCH_REQUEST */', batch_request).replace('/* BATCH */', batch).replace('/* TERMINAL */', terminal)
with tempfile.TemporaryDirectory(prefix='rob-grasp-hold-flow-', dir='/private/tmp') as folder:
    path = Path(folder) / 'Fixture.swift'
    path.write_text(fixture)
    binary = Path(folder) / 'fixture'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=10)
