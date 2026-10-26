#!/usr/bin/env python3
"""Run the real inspection/verifier with synthetic pixels and passive seams."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
inspection = ROOT / 'Cerebro/ROBRecyclingVisualInspection.swift'
scene = braced_declaration((ROOT / 'Tests/ROBVisualGraspVerifierFixtureTests.swift').read_text(), 'private struct Scene {').replace('private struct Scene {', 'struct Scene {', 1)
trial = braced_declaration((ROOT / 'Cerebro/ROBWorkspaceCollisionPlan.swift').read_text(), 'struct ROBWorkspaceVisualCalibrationTrial:')
fixture = r'''
import Foundation
import CryptoKit
import simd
import CoreImage
/* SCENE */
/* TRIAL */
enum ROBGhostMotionError:Error {case blocked(String)}
struct Runtime {var identity=String(repeating:"a",count:64)}
struct Correspondence {var status="matched"}
struct CameraIntrinsics {
    var fx=100.0,fy=100.0,cx=160.0,cy=120.0
    var rgbOutputUndistorted:Bool?=true
    var runtimeCalibration:Runtime?=Runtime()
    var cameraServiceSourceSHA256:String?=String(repeating:"c",count:64)
    var depthRGBGeometryCorrespondence:Correspondence?=Correspondence()
    var sourceSize:[Int]?=[320,240],sourceIntrinsics:[Double]?=[100,0,160,0,100,120,0,0,1]
    var imageTransform:[Double]?=[1,0,0,0,1,0,0,0,1],rgbSourceDistortionCoefficients:[Double]?=[0,0,0,0,0]
    var rgbSourceDistortionModel:String?="Perspective",depthIntrinsics:[Double]?=[100,0,160,0,100,120,0,0,1]
    var depthImageTransform:[Double]?=[1,0,0,0,1,0,0,0,1],depthSourceDistortionCoefficients:[Double]?=[0,0,0,0,0]
    var depthSourceDistortionModel:String?="Perspective",frameLensPosition:Int?=124,calibratedLensPosition:Int?=124
    var stereoMode:String?="standard",stereoExtendedDisparity:Bool?=false,stereoSubpixel:Bool?=true
    func isValid(forWidth:Int,height:Int)->Bool {forWidth==320 && height==240}
}
struct Depth {let width=320,height=240;func distanceMillimeters(x:Int,y:Int)->UInt16?{750}}
struct ROBWorkspaceView {let panDegrees:Double;let upperTarget:Int}
typealias Detection=ROBWorkspaceDetection
struct ROBWorkspaceObservation {var cans:[Detection]?=[Detection()];var can=Detection()}
struct ROBWorkspaceDetection {
    var visible=true;var confidence=0.99;var box=[0.4,0.4,0.6,0.7];var aim=[0.5,0.55];var depthPoint=[0.5,0.55];var confidenceThreshold=0.5
    var visuallyUsable:Bool {visible}
}
struct ROBWorkspaceCanSections {
    let middle:[Double]
    var diameterMeters:Double {0.066}
    struct ShapePriorEvidence {var valid=true}
    var shapePriorEvidence:ShapePriorEvidence?=nil
    static var displacement=0.0
    static var validDepth=true
    static func measure(detection:ROBWorkspaceDetection,width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double,
        depth:(Int,Int)->UInt16?,view:ROBWorkspaceView,model:ROBGhostRobotModel,cameraToRobot:simd_double4x4)->Self? {
        guard validDepth,depth(0,0)==750,width==320,height==240 else{return nil}
        return .init(middle:[displacement,0,0.75])
    }
}
struct ROBWorkspaceLocatedObject {
    let sequence:UInt64=1
    let capturedAt:Double
    let view=ROBWorkspaceView(panDegrees:0,upperTarget:6160)
    var registrationID:String?=nil
    var sections:ROBWorkspaceCanSections?=nil
    var point:SIMD3<Double> {[0,0,0.75]}
}
@MainActor final class ROBWorkspaceSearch {
    static let shared=ROBWorkspaceSearch()
    var validPrior=true,priorCalls=0,priorDisplacement=0.0
    func localCanShapePrior(detection:ROBWorkspaceDetection,allCanDetections:[ROBWorkspaceDetection],
        frame:ROBArmRoutineVision.Frame,view:ROBWorkspaceView,model:ROBGhostRobotModel,cameraToRobot:simd_double4x4)
        ->(sections:ROBWorkspaceCanSections?,diagnostics:[String:Any]) {
        priorCalls+=1
        guard validPrior,!allCanDetections.isEmpty else{return(nil,[:])}
        return(.init(middle:[priorDisplacement,0,0.75],shapePriorEvidence:.init()),["geometry_assumed":true])
    }
}
struct Observation {
    let sequence:UInt64=1
    let capturedAtMilliseconds:Double
    var recordedPanDegrees:Double?=0,recordedUpperTarget:Int?=6160,recordedLowerTarget:Int?=6011
    var cameraToRobotColumnMajor:[Double]=(0..<4).flatMap{c in(0..<4).map{r in c==r ?1.0:0.0}}
    var fixedHeadScope:ROBFixedHeadRegistrationScope?=nil,registrationID:String?=nil
}
struct ROBWorkspaceCollisionSnapshot {
    let cameraGeneration:UUID,sessionGeneration:UInt64=1
    let modelID="model",geometryID="geometry",mappingID="mapping"
    var observations:[Observation]
    var registrationID:String?=nil
}
struct ROBFixedHeadRegistrationScope:Codable,Equatable {
    let cameraGeneration:UUID
    var gatewaySessionGeneration:UInt64=1,panTarget=6015,lowerTarget=6011,upperTarget=6160
}
struct Volume {func contains(_ p:SIMD3<Double>)->Bool {true}}
struct ROBFixedHeadRegistration {
    let id="measured-fixture",cameraToRobot=matrix_identity_double4x4,validRobotVolume=Volume()
    func matches(_ s:ROBFixedHeadRegistrationScope)->Bool {true}
}
final class ROBGhostRobotModel {
    let physicalSide="left",modelID="model",geometryID="geometry",selectedMappingID="mapping"
    static func hash(_ d:Data)->String {SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
    func positions(vendorLeft:[Double])->[Double] {vendorLeft}
    func toolPosition(_ q:[Double])->SIMD3<Double>? {[q[0],q[1],q[2]]}
}
@MainActor final class ROBControllerArmApproval {
    static let shared=ROBControllerArmApproval()
    var evidence:NSDictionary?=nil,authorized=true
    var activeLocalRecyclingApprovalEvidence:NSDictionary? {evidence}
    func authorizesLocalRecyclingVisualCalibrationTrial(summary:String,arm:String)->Bool {authorized && arm=="left"}
}
@MainActor final class ROBFixedHeadCalibrationWindowController {
    static let shared=ROBFixedHeadCalibrationWindowController()
    var scopeValue=ROBFixedHeadRegistrationScope(cameraGeneration:Scene().camera)
    var registrationValue:ROBFixedHeadRegistration?=nil,registrationCalls=0
    var neck:NSDictionary=["known":true,"stationary":true,"pan":6015,"lower":6011,"upper":6160,"pan_degrees":0.0,"ready_at":0.0]
    var readNeck:(()->NSDictionary)? {{self.neck}}
    func scope(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame)throws->ROBFixedHeadRegistrationScope {scopeValue}
    func registration(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame)throws->ROBFixedHeadRegistration? {registrationCalls+=1;return registrationValue}
}
@MainActor enum ROBNeckRGBPoseDisplay {
    static var pid=String(repeating:"b",count:64)
    static var matrix=matrix_identity_double4x4
    static var sourceAccepted=true
    static func estimatedProjectionAcceptsSource(model:ROBGhostRobotModel,cameraGeneration:UUID,runtimeCalibrationIdentity:String?,cameraServiceSourceSHA256:String?)->Bool {sourceAccepted}
    static func estimatedCameraProjectionIdentity(model:ROBGhostRobotModel)->String? {pid}
    static func provisionalCameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4? {matrix}
}
@MainActor enum ROBWorkspaceCollisionPlan {
    static var validMap=true
    static func jointBounds(model:ROBGhostRobotModel)->[ClosedRange<Double>] {Array(repeating:-3...3,count:7)}
    static func validateVisualCalibrationTrialMap(_ map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,generation:UInt64,
        sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial)throws->Bool {
        guard validMap,trial.valid,map.registrationID==nil,map.cameraGeneration==cameraGeneration,
            trial.cameraGeneration==cameraGeneration,generation==1,nowMilliseconds<=trial.expiresAtMilliseconds else {throw ROBGhostMotionError.blocked("scope")}
        return true
    }
}
typealias ROBAmberGatewayTelemetry=Feedback
struct Feedback {var sampleAgeAtReceiptMilliseconds=0.0;var effectiveSampleAgeMilliseconds=0.0;var effectiveGripperFeedbackAgeMilliseconds=0.0;var positionsRadians:[NSNumber];var statuses=[NSNumber](repeating:2,count:7)}
@MainActor final class ROBAmberGatewayClient {
    static let shared=ROBAmberGatewayClient()
    var feedback=Feedback(positionsRadians:[-0.0035,0.1638,0.7,0,0,0,0].map(NSNumber.init(value:)))
    func telemetry(forArm:String)->Feedback? {feedback}
}
@MainActor final class ROBArmRoutineVision {
    struct Frame {let sequence:UInt64,capturedAt:Double,cameraGeneration:UUID;var intrinsics:CameraIntrinsics?=CameraIntrinsics();var depth:Depth?=Depth();var handsClear=true
        var image:CIImage {CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5)).cropped(to:CGRect(x:0,y:0,width:320,height:240))}}

    static let shared=ROBArmRoutineVision()
    var scene=Scene(),counter:UInt64=2,lift=false,canMoves=true,observation=ROBWorkspaceObservation()
    var intrinsics=CameraIntrinsics()
    func snapshot()->[String:Frame] {
        if lift {counter+=1}
        return ["face":Frame(sequence:counter,capturedAt:Date().timeIntervalSince1970*1000,cameraGeneration:scene.camera,intrinsics:intrinsics)]
    }
    func observeWorkspace()async throws->(ROBWorkspaceObservation,Frame) {
        (observation,Frame(sequence:1,capturedAt:Date().timeIntervalSince1970*1000-50,cameraGeneration:scene.camera,intrinsics:intrinsics))
    }
    func makeGripperVisualServoFrame(frame:Frame,scopeIdentity:String,jointPositions:[Double],jointCapturedAtMilliseconds:Double,
        poseHeldDuringCapture:Bool,openingCommandAtMilliseconds:Double?=nil,nowMilliseconds:Double=Date().timeIntervalSince1970*1000)throws->ROBGripperVisualServo.Frame {
        var f=ROBGripperVisualServo.Frame(width:320,height:240,rgb:Data(repeating:128,count:320*240*3),depthMillimeters:Array(repeating:750,count:320*240),
            fx:100,fy:100,cx:160,cy:120,sequence:frame.sequence,capturedAtMilliseconds:frame.capturedAt,scopeIdentity:scopeIdentity,
            jointPositions:jointPositions,jointCapturedAtMilliseconds:jointCapturedAtMilliseconds,poseHeldDuringCapture:poseHeldDuringCapture)
        f.openingCommandAtMilliseconds=openingCommandAtMilliseconds;return f
    }
    func makeVisualGraspSample(frame:Frame,fixedViewIdentity:String,targetIdentity:String,
        measuredToolCenter:ROBVisualGraspVerifier.Point,measuredToolDepthMeters:Double,
        toolFeedbackCapturedAtMilliseconds:Double,allowReferenceImage:Bool=false)throws->ROBVisualGraspVerifier.Sample {
        let moved=lift && canMoves
        let s=scene.sample(sequence:frame.sequence,time:frame.capturedAt,canDX:moved ?12:0,canDY:moved ? -8:0,
            canDepthDelta:moved ? -0.025:0,camera:frame.cameraGeneration,view:fixedViewIdentity,identity:targetIdentity)
        return .init(sequence:s.sequence,capturedAtMilliseconds:s.capturedAtMilliseconds,synchronizedRGBDepth:true,
            cameraGeneration:s.cameraGeneration,fixedViewIdentity:s.fixedViewIdentity,targetIdentity:s.targetIdentity,width:s.width,height:s.height,
            gray:s.gray,depthMeters:s.depthMeters,measuredToolCenter:measuredToolCenter,measuredToolDepthMeters:measuredToolDepthMeters,
            toolFeedbackCapturedAtMilliseconds:toolFeedbackCapturedAtMilliseconds,handsClear:true)
    }
}
@main enum Test {
    @MainActor static func main()async throws {
        let model=ROBGhostRobotModel(),v=ROBArmRoutineVision.shared,c=ROBFixedHeadCalibrationWindowController.shared,b=ROBControllerArmApproval.shared
        let hash=String(repeating:"d",count:64),now=Date().timeIntervalSince1970*1000
        c.scopeValue = .init(cameraGeneration:v.scene.camera)
        let map=ROBWorkspaceCollisionSnapshot(cameraGeneration:v.scene.camera,observations:[Observation(capturedAtMilliseconds:now)])
        let trial=ROBWorkspaceVisualCalibrationTrial(receiptID:"synthetic",receiptSHA256:hash,appSessionID:"app",command:"left_recycle_cans",canCount:4,
            summarySHA256:hash,authorizationContextIdentity:"context",sessionGeneration:1,sceneID:UUID(),cameraGeneration:v.scene.camera,
            modelID:"model",geometryID:"geometry",mappingID:"mapping",mapFingerprint:hash,bodyMotionIdentity:"body",
            estimatedCameraProjectionIdentity:ROBNeckRGBPoseDisplay.pid,observationPoseIdentity:hash,currentPoseIdentity:hash,baseline:[Double](repeating:0,count:7),
            issuedAtMilliseconds:now-1000,expiresAtMilliseconds:now+60_000,assumedSpatialErrorMeters:0.05)
        b.evidence=["summary":"Synthetic four-can job","receiptID":"synthetic","receiptSHA256":hash,"appSessionID":"app",
            "command":"left_recycle_cans","summarySHA256":hash,"contextIdentity":"context","canCount":4,"executingUntilMilliseconds":now+60_000,"pendingID":"pending"]
        let originalEvidence=b.evidence
        let can=ROBWorkspaceLocatedObject(capturedAt:now)
        func begin()async throws->ROBRecyclingVisualInspection.Context {
            try await ROBRecyclingVisualInspection.beginVisualCalibrationTrial(model:model,can:can,map:map,trial:trial,gatewayArm:"right",check:{})
        }
        for count in [1,5,8,0,9] {
            let encoder=JSONEncoder(),decoder=JSONDecoder()
            var object=try JSONSerialization.jsonObject(with:encoder.encode(trial))as![String:Any];object["canCount"]=count
            let scoped=try decoder.decode(ROBWorkspaceVisualCalibrationTrial.self,from:JSONSerialization.data(withJSONObject:object))
            let receipt=originalEvidence!.mutableCopy()as!NSMutableDictionary;receipt["canCount"]=count;b.evidence=receipt
            do {
                _=try await ROBRecyclingVisualInspection.beginVisualCalibrationTrial(model:model,can:can,map:map,trial:scoped,gatewayArm:"right",check:{})
                precondition((1...8).contains(count),"Out-of-range inspection count accepted")
            }catch {precondition(!(1...8).contains(count),"Bounded matching count rejected: \(count): \(error)")}
        }
        b.evidence=originalEvidence
        let mismatched=originalEvidence!.mutableCopy()as!NSMutableDictionary;mismatched["canCount"]=5;b.evidence=mismatched
        do {_=try await begin();preconditionFailure("Changed exact job count admitted") }catch{}
        b.evidence=originalEvidence
        let first=try await begin()
        if case .registered = first.projection {preconditionFailure("Estimated inspection manufactured registration")}
        precondition(c.registrationCalls==0 && map.registrationID==nil)
        // Synthetic box/jaw co-motion without an independent pre-approach
        // appearance reference cannot manufacture positive lift evidence.
        func servoFrame(_ seq:UInt64,_ dx:Int,_ dy:Int)->ROBGripperVisualServo.Frame {
            let raw=v.scene.sample(sequence:seq,time:Date().timeIntervalSince1970*1000,canDX:dx,canDY:dy)
            return .init(width:raw.width,height:raw.height,rgb:Data(raw.gray.flatMap{[$0,$0,$0]}),
                depthMillimeters:raw.depthMeters.map{UInt16($0*1000)},fx:100,fy:100,cx:80,cy:60,
                sequence:seq,capturedAtMilliseconds:raw.capturedAtMilliseconds,scopeIdentity:"synthetic-servo",jointPositions:Array(repeating:0,count:7),
                jointCapturedAtMilliseconds:raw.capturedAtMilliseconds,poseHeldDuringCapture:true)
        }
        func servoSample(_ seq:UInt64,_ canDX:Int,_ canDY:Int,_ jawDX:Int,_ jawDY:Int)->ROBRecyclingVisualInspection.ServoObservation {
            let frame=servoFrame(seq,canDX,canDY)
            let jaw=ROBGripperVisualServo.JawObservation(centerPixels:[80+Double(jawDX),66+Double(jawDY)],
                tipsPixels:[[64+Double(jawDX),75+Double(jawDY)],[96+Double(jawDX),75+Double(jawDY)]],openingPixels:32,openingMeters:0.08,
                confidence:0.99,evidenceKind:"synthetic_fixture_observed_pixels_not_hardware",sequence:seq,
                capturedAtMilliseconds:frame.capturedAtMilliseconds,scopeIdentity:frame.scopeIdentity)
            let decision=ROBGripperVisualServo.Decision(status:"observedOnly",reason:"Synthetic pixel observation only",observation:jaw,
                canMiddlePixels:[80+Double(canDX),66+Double(canDY)],pixelError:[0,0],jointTarget:nil,readyToGrip:false,diagnostics:[:])
            let source:String
            if case .visualTrial(let projection)=first.projection {source=projection.frameContractIdentity} else {source="fixture"}
            return .init(frame:frame,decision:decision,canBox:[0.4,0.4,0.6,0.7],handsClear:true,
                cameraGeneration:v.scene.camera,sourceIdentity:source)
        }
        let servoBase=ROBRecyclingVisualInspection.ServoBaseline(projection:first.projection,scope:first.scope,
            targetIdentity:first.targetIdentity,viewIdentity:first.viewIdentity)
        let servoContext=ROBRecyclingVisualInspection.ServoContext(baseline:servoBase,can:can,model:model,box:[0.4,0.4,0.6,0.7])
        let beforeServo=servoSample(100,0,0,0,0)
        var servoSeq:UInt64=100
        let provisional=try await ROBRecyclingVisualInspection.verifyIncrementalServoLift(context:servoContext,beforeLift:beforeServo,model:model,
            heldSinceMilliseconds:0,observe:{servoSeq+=1;return servoSample(servoSeq,12,-8,12,-8)},check:{})
        precondition(provisional.verdict == .unknown && !provisional.possessionMeasured)
        precondition(servoContext.nativeObservedSupport == nil,"UNKNOWN must never mint native attachment support")
        precondition(provisional.reason.contains("No independent pre-approach can appearance"),"Box co-motion must not confirm grasp or carry without independent appearance")
        let missContext=ROBRecyclingVisualInspection.ServoContext(baseline:servoBase,can:can,model:model,box:[0.4,0.4,0.6,0.7])
        let missed=try await ROBRecyclingVisualInspection.verifyIncrementalServoLift(context:missContext,beforeLift:beforeServo,model:model,
            heldSinceMilliseconds:0,observe:{servoSeq+=1;return servoSample(servoSeq,0,0,12,-8)},check:{})
        precondition(missContext.nativeObservedSupport == nil)
        precondition(missed.verdict == .unknown && !missContext.provisionalCoMotion,
            "A missing appearance reference remains unknown even when synthetic boxes disagree")
        print("PASS actual incremental lift inspection: synthetic box/jaw motion without independent pre-approach appearance remains UNKNOWN; no possession or transfer claim")
        func lift() {
            v.lift=true
            let z=0.675,x=((0.5+12.0/160)*319-160)*z/100,y=((0.6-8.0/120)*239-120)*z/100
            ROBAmberGatewayClient.shared.feedback.positionsRadians=[x,y,z,0,0,0,0].map(NSNumber.init(value:))
        }
        lift()
        let supported=try await ROBRecyclingVisualInspection.verifyAfterLift(context:first,model:model,gatewayArm:"right",check:{})
        precondition(supported.verdict == .supported && supported.samples>=3 && !supported.possessionMeasured)
        precondition(supported.reason.contains("estimated-camera projection") && supported.fixedViewIdentity.contains("unmeasured-visual-trial"))
        v.lift=false;ROBAmberGatewayClient.shared.feedback.positionsRadians=[-0.0035,0.1638,0.7,0,0,0,0].map(NSNumber.init(value:))
        let original=try await begin()
        for mutation in ["profile","runtime","source","refinementSource","head","stationary","hold","feedback","receipt","pending","map","depth","lens","K","gateway"] {
            switch mutation {
            case "profile":ROBNeckRGBPoseDisplay.pid=String(repeating:"e",count:64)
            case "runtime":v.intrinsics.runtimeCalibration?.identity=String(repeating:"e",count:64)
            case "source":v.intrinsics.cameraServiceSourceSHA256=String(repeating:"e",count:64)
            case "refinementSource":ROBNeckRGBPoseDisplay.sourceAccepted=false
            case "head":c.scopeValue.upperTarget=6200
            case "stationary":c.neck=["known":true,"stationary":false,"pan":6015,"lower":6011,"upper":6160,"pan_degrees":0.0,"ready_at":0.0]
            case "hold":ROBAmberGatewayClient.shared.feedback.statuses[0]=1
            case "feedback":ROBAmberGatewayClient.shared.feedback.effectiveSampleAgeMilliseconds=151
            case "receipt":b.authorized=false
            case "pending":
                let changed=b.evidence!.mutableCopy() as! NSMutableDictionary;changed["pendingID"]="other";b.evidence=changed
            case "map":ROBWorkspaceCollisionPlan.validMap=false
            case "depth":v.intrinsics.depthRGBGeometryCorrespondence?.status="mismatched"
            case "lens":v.intrinsics.frameLensPosition=125
            case "K":v.intrinsics.fx=101
            default:break
            }
            v.counter+=1
            do {_=try await ROBRecyclingVisualInspection.verifyAfterLift(context:original,model:model,gatewayArm:mutation=="gateway" ? "left":"right",check:{});preconditionFailure("Unsafe inspection accepted: "+mutation)}catch{}
            ROBNeckRGBPoseDisplay.pid=trial.estimatedCameraProjectionIdentity;v.intrinsics=CameraIntrinsics();c.scopeValue.upperTarget=6160
            ROBNeckRGBPoseDisplay.sourceAccepted=true
            ROBAmberGatewayClient.shared.feedback.statuses=[NSNumber](repeating:2,count:7);ROBAmberGatewayClient.shared.feedback.effectiveSampleAgeMilliseconds=0
            b.authorized=true;b.evidence=originalEvidence;ROBWorkspaceCollisionPlan.validMap=true
            c.neck=["known":true,"stationary":true,"pan":6015,"lower":6011,"upper":6160,"pan_degrees":0.0,"ready_at":0.0]
        }
        for failure in ["ambiguous","displaced","missingDepth"] {
            if failure=="ambiguous" {v.observation.cans=[Detection(),Detection()]}
            if failure=="displaced" {ROBWorkspaceCanSections.displacement=0.013}
            if failure=="missingDepth" {ROBWorkspaceCanSections.validDepth=false}
            do {_=try await begin();preconditionFailure("Unsafe closure admitted: "+failure)}catch{}
            v.observation=ROBWorkspaceObservation();ROBWorkspaceCanSections.displacement=0;ROBWorkspaceCanSections.validDepth=true
        }
        var otherView=map;otherView.observations[0].recordedUpperTarget=6200
        do {_=try await ROBRecyclingVisualInspection.beginVisualCalibrationTrial(model:model,can:can,map:otherView,trial:trial,gatewayArm:"right",check:{});preconditionFailure("Another source can view accepted")}catch{}
        var priorCan=can;priorCan.sections = .init(middle:[0,0,0.75],shapePriorEvidence:.init())
        func beginPrior()async throws->ROBRecyclingVisualInspection.Context {
            try await ROBRecyclingVisualInspection.beginVisualCalibrationTrial(model:model,can:priorCan,map:map,trial:trial,gatewayArm:"right",check:{})
        }
        ROBWorkspaceCanSections.validDepth=false
        let priorContext=try await beginPrior()
        precondition(priorContext.assumedCanGeometry && ROBWorkspaceSearch.shared.priorCalls>0 && c.registrationCalls==0)
        for failure in ["table_or_silhouette","moved12mm","receipt"] {
            if failure=="table_or_silhouette" {ROBWorkspaceSearch.shared.validPrior=false}
            if failure=="moved12mm" {ROBWorkspaceSearch.shared.priorDisplacement=0.013}
            if failure=="receipt" {b.authorized=false}
            do {_=try await beginPrior();preconditionFailure("Unsafe assumed prior closure admitted: "+failure)}catch{}
            ROBWorkspaceSearch.shared.validPrior=true;ROBWorkspaceSearch.shared.priorDisplacement=0;b.authorized=true
        }
        lift()
        let priorEvidence=try await ROBRecyclingVisualInspection.verifyAfterLift(context:priorContext,model:model,gatewayArm:"right",check:{})
        precondition(priorEvidence.reason.contains("explicit local shape prior") && !priorEvidence.possessionMeasured)
        v.lift=false;ROBAmberGatewayClient.shared.feedback.positionsRadians=[-0.0035,0.1638,0.7,0,0,0,0].map(NSNumber.init(value:))
        ROBWorkspaceCanSections.validDepth=true
        // Registered API still resolves an actual registration and needs no
        // local receipt or estimated PID/normalization metadata contract.
        c.registrationValue=ROBFixedHeadRegistration();b.authorized=false
        var registeredCan=can;registeredCan.registrationID="measured-fixture"
        var wronglyRegisteredPrior=registeredCan;wronglyRegisteredPrior.sections=priorCan.sections
        do {_=try await ROBRecyclingVisualInspection.begin(model:model,can:wronglyRegisteredPrior,gatewayArm:"right",check:{});preconditionFailure("Ordinary measured inspection accepted an assumed geometry object")}catch{}
        let registered=try await ROBRecyclingVisualInspection.begin(model:model,can:registeredCan,gatewayArm:"right",check:{})
        if case .visualTrial = registered.projection {preconditionFailure("Measured API changed authority")}
        precondition(c.registrationCalls>0)
        lift()
        let measured=try await ROBRecyclingVisualInspection.verifyAfterLift(context:registered,model:model,gatewayArm:"right",check:{})
        precondition(measured.verdict == .supported && !measured.reason.contains("estimated-camera"))
        print("PASS visual-trial inspection: real verifier co-motion on3advancing frames, no fake registration, exact raw-view/source/runtime/profile/receipt/map hold,150msfeedback/status2, unique target/depth/12mmveto, explicit estimated labels; registered entry unchanged")
    }
}
'''.replace('/* SCENE */', scene).replace('/* TRIAL */', trial)

with tempfile.TemporaryDirectory(prefix='rob-visual-trial-inspection-', dir='/private/tmp') as folder:
    root=Path(folder); path=root/'Fixture.swift';path.write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(ROOT/'Cerebro/ROBVisualGraspVerifier.swift'),str(ROOT/'Cerebro/ROBGripperVisualServo.swift'),str(inspection),str(path),'-o',str(root/'fixture')],check=True,timeout=60)
    subprocess.run([str(root/'fixture')],check=True,timeout=15)
