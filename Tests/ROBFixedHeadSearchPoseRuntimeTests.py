#!/usr/bin/env python3
"""Run production fixed-view search guards with clocks and transports isolated."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Cerebro/ROBArmRoutineVision.swift").read_text()


def method(marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


current_view = method("private func registeredCurrentView(").replace("private func", "func", 1)
ready = method("func isViewReady(")
move = method("func moveView(")
fixture = r'''
import Foundation

enum ProcessInfo {
    @MainActor static let processInfo = Clock()
    @MainActor final class Clock { var systemUptime = 100.0 }
}
enum Task {
    @MainActor static func sleep(nanoseconds:UInt64) async throws {
        ProcessInfo.processInfo.systemUptime += Double(nanoseconds) / 1_000_000_000
    }
}
struct Scope:Equatable {
    var pan=6000,lowerTarget=6495,upperTarget=5698
    var model="robot",geometry="hulls",mapping="physical-right"
    var camera="camera-A",gateway=42,body="body-A",intrinsics="native-K",correction="correction-A"
}
struct Registration { var id="measured-profile-A" }
struct Frame { var capturedAt:Double }
struct ROBWorkspaceView:Equatable { let panDegrees:Double;let upperTarget:Int }
struct ROBGhostRobotModel {}
@MainActor final class ROBArmRoutineVision {
    static let shared=ROBArmRoutineVision()
    var frame:Frame?=Frame(capturedAt:Date().timeIntervalSince1970*1000)
    func snapshot()->[String:Frame] { frame.map { ["face":$0] } ?? [:] }
}
@MainActor final class ROBFixedHeadCalibrationWindowController {
    static let shared=ROBFixedHeadCalibrationWindowController()
    var readNeck:(()->NSDictionary)? = { ["pan_degrees":0.0] }
}
@MainActor final class HeldSearch {
    func requireSceneProjectionIdentity()throws {}
    typealias Context=(registration:Registration,scope:Scope)
    let model=ROBGhostRobotModel()
    let vision=ROBArmRoutineVision.shared
    var current:Context?=(Registration(),Scope())
    var fixedRegisteredView:ROBWorkspaceView?=ROBWorkspaceView(panDegrees:0,upperTarget:5698)
    var fixedContext:Context?=(Registration(),Scope())
    var prepareCalls=0,readyCalls=0,checkCalls=0
    var evidence:[[String:Any]]=[]
    var progress:(String)->Void={_ in}
    var canUseView:((Double,Int)->Bool)?={_,_ in true}
    lazy var prepareView:((Double,Int)->Bool)?={ [unowned self] _,_ in self.prepareCalls+=1;return true }
    lazy var viewReady:((Double,Int)->Bool)?={ [unowned self] _,_ in self.readyCalls+=1;return true }
    func check() throws { checkCalls+=1 }
    func registeredCameraContext(frame:Frame,model:ROBGhostRobotModel)->Context? { current }
    /* CURRENT_VIEW */
    /* READY */
    /* MOVE */
}
@main enum Fixtures {
    @MainActor static func main() async throws {
        let search=HeldSearch(),view=ROBWorkspaceView(panDegrees:0,upperTarget:5698)
        let original=search.current!
        precondition(original.scope.lowerTarget==6495)
        precondition(search.registeredCurrentView(model:search.model)==view,"Rejected registered lower6495")
        precondition(search.isViewReady(view),"Held lower6495 was not ready")
        let heldMoved=try await search.moveView(view)
        precondition(heldMoved,"Held lower6495 search could not settle")
        precondition(search.prepareCalls==0 && search.readyCalls==0,"Fixed search invoked legacy neck callbacks")
        precondition(search.checkCalls>1,"Fixed search skipped ongoing operation checks")

        func reset() {
            search.current=original
            search.vision.frame=Frame(capturedAt:Date().timeIntervalSince1970*1000)
        }
        func rejects(_ reason:String) {
            precondition(!search.isViewReady(view),"Fixed search admitted \(reason)")
        }
        let mutations:[(String,(inout Scope)->Void)]=[
            ("pan",{$0.pan+=1}),("lower",{$0.lowerTarget+=1}),("upper",{$0.upperTarget+=1}),
            ("model",{$0.model="other"}),("geometry",{$0.geometry="other"}),
            ("mapping",{$0.mapping="physical-left"}),("camera",{$0.camera="camera-B"}),
            ("gateway",{$0.gateway+=1}),("body",{$0.body="body-B"}),
            ("intrinsics",{$0.intrinsics="other-K"}),("correction",{$0.correction="other"})]
        for (name,mutation) in mutations { reset();mutation(&search.current!.scope);rejects(name) }
        reset();search.current!.registration.id="other-profile";rejects("replacement profile")
        reset();search.current=nil;rejects("missing registration")
        reset();search.vision.frame=nil;rejects("missing frame")
        reset();search.vision.frame!.capturedAt-=701;rejects("stale frame")
        precondition(search.registeredCurrentView(model:search.model)==nil,"Stale view accepted")
        reset();search.vision.frame!.capturedAt+=100;rejects("future frame")
        reset();precondition(!search.isViewReady(ROBWorkspaceView(panDegrees:15,upperTarget:5698)),"Changed requested pan accepted")
        precondition(!search.isViewReady(ROBWorkspaceView(panDegrees:0,upperTarget:5300)),"Changed requested tilt accepted")

        reset();search.current!.scope.lowerTarget=6011
        let before=search.prepareCalls
        let changedMoved=try await search.moveView(view)
        precondition(!changedMoved,"Changed held scope silently recovered")
        precondition(search.prepareCalls==before && search.readyCalls==0,"Scope loss invoked legacy recovery")

        // Legacy, unregistered search still uses its established callbacks.
        reset();search.fixedContext=nil;search.fixedRegisteredView=nil
        let legacyMoved=try await search.moveView(view)
        precondition(legacyMoved,"Legacy search no longer prepares views")
        precondition(search.prepareCalls>before && search.readyCalls>0)
        print("Fixed-head search runtime passed: lower6495 retained without legacy commands; changed scopes, profiles, frames and views reject; legacy path preserved")
    }
}
'''.replace("/* CURRENT_VIEW */", current_view).replace("/* READY */", ready).replace("/* MOVE */", move)

with tempfile.TemporaryDirectory(prefix="rob-fixed-search-", dir="/private/tmp") as directory:
    path = Path(directory)
    swift = path / "FixedSearch.swift"
    binary = path / "fixed-search"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
