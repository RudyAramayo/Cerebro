#!/usr/bin/env python3
"""Run the production two-arm read-only mode refresh against inert feedback.

Only queryMode, modes and telemetry exist on the fixture gateway. Its virtual
wait loop never sleeps or connects to hardware, and no user preferences change.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    index = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[start:index]


FIXTURE = r'''
import Foundation

enum ROBArmRoutineError:LocalizedError {
    case blocked(String)
    var errorDescription:String? {if case .blocked(let text)=self{return text};return nil}
}
struct Sample {
    var effectiveSampleAgeMilliseconds=1.0,effectiveGripperFeedbackAgeMilliseconds=1.0
    var positionsRadians=(0..<7).map{NSNumber(value:Double($0)*0.01)}
    var statuses=Array(repeating:NSNumber(value:0),count:7)
}
@MainActor final class Gateway {
    var cache:[String:[NSNumber]]=[:]
    var samples:[String:Sample]=["left":.init(),"right":.init()]
    var queryValues:[String:[NSNumber]]=["left":Array(repeating:0,count:7),"right":Array(repeating:0,count:7)]
    var deniedSide:String?,afterQuery:((String)->Void)?
    var queries:[String]=[]
    // No activation, deactivation, position, hold, reset or jaw API exists.
    func queryMode(forArm side:String)->UInt64 {
        queries.append(side)
        if deniedSide==side {return 0}
        cache[side]=queryValues[side] ?? []
        afterQuery?(side)
        return UInt64(queries.count)
    }
    func modes(forArm side:String)->[NSNumber] {cache[side] ?? []}
    func telemetry(forArm side:String)->Sample? {samples[side]}
}
@MainActor final class Harness {
    let gateway=Gateway()
    var stopped=false,continued=false,acceptedCalls=0,waitCalls=0,ticks=0
    var tick:(()->Void)?
    func check()throws {
        if stopped {throw ROBArmRoutineError.blocked("Stop active")}
    }
    func accepted(_ dispatch:()->UInt64)async throws {
        try check();acceptedCalls+=1
        guard dispatch()>0 else {throw ROBArmRoutineError.blocked("Read-only query denied")}
        try check()
    }
    func wait(_ seconds:Double,until condition:()->Bool)async throws {
        precondition(seconds==2);waitCalls+=1
        var elapsed=0.0
        while true {
            try check()
            if condition() {return}
            guard elapsed<seconds else {throw ROBArmRoutineError.blocked("Read-only feedback timed out")}
            ticks+=1;elapsed+=0.02;tick?()
        }
    }
    __ACTUAL_METHOD__
    func run()async throws {try await synchronizeSceneArmModes();continued=true}
}

@main enum SceneModeRefreshFixtures {
    @MainActor static func rejected(_ h:Harness,contains:String)async {
        do {try await h.run();preconditionFailure("Invalid scene feedback continued")}
        catch {precondition(error.localizedDescription.contains(contains),error.localizedDescription)}
        precondition(!h.continued)
    }
    @MainActor static func main()async throws {
        let missing=Harness()
        precondition(missing.gateway.cache.isEmpty)
        try await missing.run()
        precondition(missing.continued && missing.gateway.queries==["left","right"])
        precondition(missing.gateway.cache.keys.sorted()==["left","right"] && missing.ticks==0)

        for selected in ["left","right"] {
            let opposite=Harness();opposite.gateway.cache[selected]=Array(repeating:0,count:7)
            try await opposite.run()
            precondition(opposite.continued && opposite.gateway.queries==["left","right"])
            precondition(opposite.gateway.cache.keys.sorted()==["left","right"])
        }
        for mode in [0,1,2] {
            let held=Harness()
            for side in ["left","right"] {
                held.gateway.samples[side]!.statuses=Array(repeating:NSNumber(value:mode),count:7)
                held.gateway.queryValues[side]=Array(repeating:NSNumber(value:mode),count:7)
            }
            try await held.run()
            precondition(held.continued && held.gateway.queries==["left","right"] && held.ticks==0)
        }

        let delayed=Harness()
        delayed.gateway.queryValues["right"]=Array(repeating:2,count:7)
        delayed.tick={if delayed.ticks==3 {delayed.gateway.samples["right"]!.statuses=Array(repeating:2,count:7)}}
        try await delayed.run()
        precondition(delayed.continued && delayed.ticks==3 && delayed.gateway.queries==["left","right"])

        for side in ["left","right"] {
            for condition in ["missing","stale","gripper_stale","age_nan","gripper_nan","gripper_infinite",
                              "short_positions","nan_position","infinite_position","short_status",
                              "invalid_status","negative_status","mixed_status","cache_mismatch","empty_cache"] {
                let bad=Harness()
                switch condition {
                case "missing":bad.gateway.samples[side]=nil
                case "stale":bad.gateway.samples[side]!.effectiveSampleAgeMilliseconds=251
                case "gripper_stale":bad.gateway.samples[side]!.effectiveGripperFeedbackAgeMilliseconds=251
                case "age_nan":bad.gateway.samples[side]!.effectiveSampleAgeMilliseconds = .nan
                case "gripper_nan":bad.gateway.samples[side]!.effectiveGripperFeedbackAgeMilliseconds = .nan
                case "gripper_infinite":bad.gateway.samples[side]!.effectiveGripperFeedbackAgeMilliseconds = .infinity
                case "short_positions":bad.gateway.samples[side]!.positionsRadians.removeLast()
                case "nan_position":bad.gateway.samples[side]!.positionsRadians[3]=NSNumber(value:Double.nan)
                case "infinite_position":bad.gateway.samples[side]!.positionsRadians[0]=NSNumber(value:Double.infinity)
                case "short_status":bad.gateway.samples[side]!.statuses.removeLast()
                case "invalid_status":bad.gateway.samples[side]!.statuses=Array(repeating:3,count:7)
                case "negative_status":bad.gateway.samples[side]!.statuses=Array(repeating:-1,count:7)
                case "mixed_status":bad.gateway.samples[side]!.statuses[5]=2
                case "cache_mismatch":bad.gateway.queryValues[side]=Array(repeating:1,count:7)
                case "empty_cache":bad.gateway.queryValues[side]=[]
                default:preconditionFailure()
                }
                await rejected(bad,contains:"timed out")
                precondition(bad.gateway.queries==["left","right"] && bad.waitCalls==1 && bad.ticks>0,
                    "The opposite arm's bad feedback escaped validation: \(side) / \(condition)")
            }
        }

        for denied in ["left","right"] {
            let denial=Harness();denial.gateway.deniedSide=denied
            await rejected(denial,contains:"query denied")
            precondition(denial.gateway.queries==(denied=="left" ? ["left"]:["left","right"]))
            precondition(denial.waitCalls==0)
        }
        let initialStop=Harness();initialStop.stopped=true
        await rejected(initialStop,contains:"Stop active")
        precondition(initialStop.gateway.queries.isEmpty && initialStop.waitCalls==0)
        let queryStop=Harness();queryStop.gateway.afterQuery={_ in queryStop.stopped=true}
        await rejected(queryStop,contains:"Stop active")
        precondition(queryStop.gateway.queries==["left"] && queryStop.waitCalls==0)
        let waitStop=Harness();waitStop.gateway.queryValues["right"]=Array(repeating:1,count:7)
        waitStop.tick={waitStop.stopped=true}
        await rejected(waitStop,contains:"Stop active")
        precondition(waitStop.gateway.queries==["left","right"] && waitStop.ticks==1)

        print("PASS actual scene arm-mode refresh: both read-only queries populate missing/opposite caches; delayed consistent feedback accepted; both-arm stale/gripper/status/q/cache failures and denied/Stop paths reject before continuing; no actuator APIs")
    }
}
'''


def main():
    source = (ROOT / "Cerebro/ROBLeftArmTrial.swift").read_text()
    helper = block(source, "@MainActor private func synchronizeSceneArmModes()")
    prepare = block(source, "@MainActor private func prepareRightRecyclingSceneHolds(")
    authorization = block(prepare, 'guard physicalSide == "right"')
    call = "try await synchronizeSceneArmModes()"
    assert prepare.index(authorization) + len(authorization) < prepare.index(call)
    assert prepare.index(call) < prepare.index("var baselines:") < prepare.index('for side in ["left","right"]')
    gateway_calls = set(re.findall(r"gateway\.([A-Za-z0-9_]+)\(", helper))
    assert gateway_calls == {"queryMode", "modes", "telemetry"}, gateway_calls
    actual = FIXTURE.replace("__ACTUAL_METHOD__", helper)
    with tempfile.TemporaryDirectory(prefix="rob-scene-mode-refresh-") as folder:
        folder = Path(folder)
        swift = folder / "Fixture.swift"
        binary = folder / "fixture"
        swift.write_text(actual)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                        str(swift), "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
