#!/usr/bin/env python3
"""Exercise the actual fixed-head preview guard without a UI or robot transport."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Cerebro/ROBRecyclingVisualInspection.swift").read_text()
start = source.index("    static func fixedHeadContextIsCurrent(")
opening = source.index("{", start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
method = source[start:end]
fixture = r'''
import Foundation
import CryptoKit
struct Frame { var capturedAt:Double; var cameraGeneration:UUID }
struct Scope:Equatable { var identity:String; var gatewaySessionGeneration:UInt64 }
struct Observation { var fixedHeadScope:Scope?; var registrationID:String? }
struct ROBWorkspaceCollisionSnapshot {
    var cameraGeneration:UUID;var modelID:String;var geometryID:String;var mappingID:String
    var sessionGeneration:UInt64;var observations:[Observation];var registrationID:String?
}
final class ROBGhostRobotModel {
    var modelID="model",geometryID="geometry",selectedMappingID="right-mapping"
    static func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
}
struct Registration {
    var id:String;var scope:Scope
    func matches(_ candidate:Scope)->Bool {scope==candidate}
}
@MainActor final class ROBArmRoutineVision {
    static let shared=ROBArmRoutineVision()
    var frame:Frame?
    func snapshot()->[String:Frame] {frame.map{["face":$0]} ?? [:]}
}
@MainActor final class ROBFixedHeadCalibrationWindowController {
    static let shared=ROBFixedHeadCalibrationWindowController()
    var currentScope=Scope(identity:"headpose-A/bodyepoch-A",gatewaySessionGeneration:42)
    var currentRegistration:Registration?
    var shouldThrow=false
    enum Failure:Error {case unavailable}
    func registration(model:ROBGhostRobotModel,frame:Frame)throws->Registration? {
        if shouldThrow {throw Failure.unavailable};return currentRegistration
    }
    func scope(model:ROBGhostRobotModel,frame:Frame)throws->Scope {
        if shouldThrow {throw Failure.unavailable};return currentScope
    }
}
@MainActor enum ActualGuard {
/* ACTUAL_METHOD */
}
@main enum Fixtures {
    @MainActor static func main() {
        let model=ROBGhostRobotModel(),camera=UUID()
        let controller=ROBFixedHeadCalibrationWindowController.shared
        let vision=ROBArmRoutineVision.shared
        let scope=controller.currentScope
        let registration=Registration(id:"actual-measured-profile",scope:scope)
        let observation=Observation(fixedHeadScope:scope,registrationID:registration.id)
        let valid=ROBWorkspaceCollisionSnapshot(cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,
            mappingID:model.selectedMappingID,sessionGeneration:42,observations:[observation,observation],
            registrationID:"fixed-head-map-"+ROBGhostRobotModel.hash(Data(registration.id.utf8)))
        var map=valid
        func reset() {
            map=valid;vision.frame=Frame(capturedAt:Date().timeIntervalSince1970*1000,cameraGeneration:camera)
            controller.currentScope=scope;controller.currentRegistration=registration;controller.shouldThrow=false
        }
        func rejects(_ reason:String) {
            precondition(!ActualGuard.fixedHeadContextIsCurrent(model:model,map:map),"Admitted \(reason)")
        }
        reset();precondition(ActualGuard.fixedHeadContextIsCurrent(model:model,map:map))
        reset();vision.frame=nil;rejects("missing frame")
        reset();vision.frame!.capturedAt-=801;rejects("stale frame")
        reset();vision.frame!.cameraGeneration=UUID();rejects("camera change")
        reset();map.modelID="other";rejects("model change")
        reset();map.geometryID="other";rejects("geometry change")
        reset();map.mappingID="left-mapping";rejects("physical-side change")
        reset();map.sessionGeneration=43;rejects("gateway restart")
        reset();map.observations=[];rejects("no registered observations")
        reset();map.observations[0].fixedHeadScope=nil;rejects("partially unregistered map")
        reset();map.observations[0].registrationID="other-profile";rejects("mixed profile map")
        reset();map.observations[0].fixedHeadScope=Scope(identity:"other-neckpose",gatewaySessionGeneration:42);rejects("mixed head poses")
        reset();map.registrationID=registration.id;rejects("individual ID substituted for composite map ID")
        reset();map.registrationID="fixed-head-map-wrong";rejects("changed composite ID")
        reset();map.registrationID=nil;rejects("body motion invalidated registration")
        reset();controller.currentScope.identity="headpose-B/bodyepoch-A";rejects("head motion after preview")
        reset();controller.currentScope.identity="headpose-A/bodyepoch-B";rejects("body motion after preview")
        reset();controller.currentRegistration=nil;rejects("registration removed")
        reset();controller.currentRegistration!.id="different-profile";rejects("registration replaced")
        reset();controller.shouldThrow=true;rejects("unavailable live scope")
        print("Fixed-head preview guard runtime passed: fresh exact context accepted; head/body/camera/session/model/mapping/profile/map changes and missing evidence reject")
    }
}
'''.replace("/* ACTUAL_METHOD */", method)
with tempfile.TemporaryDirectory(prefix="rob-preview-context-", dir="/private/tmp") as directory:
    path = Path(directory)
    swift = path / "PreviewContext.swift"
    binary = path / "preview-context"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
