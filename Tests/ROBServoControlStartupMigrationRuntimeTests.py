#!/usr/bin/env python3
"""Run the real servo store with an in-memory preferences substitute only."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Cerebro/ROBServoControlConfiguration.swift"

FIXTURE = r'''
// This executable links no serial, UI, camera or arm service. All preference
// reads/writes stay inside this dictionary; live UserDefaults is never opened.
private final class FixtureDefaults {
    static let standard = FixtureDefaults()
    var bytes: Data?
    var writes = 0
    func data(forKey key: String) -> Data? {
        precondition(key == "ROBServoControlConfigurationV1")
        return bytes
    }
    func set(_ data: Data, forKey key: String) {
        precondition(key == "ROBServoControlConfigurationV1")
        bytes = data; writes += 1
    }
    func seed(_ payload: [String:Any]?) throws {
        bytes = try payload.map { try JSONSerialization.data(withJSONObject:$0, options:[.sortedKeys]) }
        writes = 0
    }
}

// Same-file private access constructs a fresh real store for each isolated
// load. Production initialization, validation and persistence are unmodified.
extension ROBServoControlStore {
    fileprivate static func fixtureStore() -> ROBServoControlStore { ROBServoControlStore() }
}

@main private enum StartupMigrationFixture {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message:String) {
        checks += 1
        precondition(condition(), message)
    }
    static func object(_ bytes:Data) throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
    }
    static func canonical(_ value:Any) throws -> Data {
        try JSONSerialization.data(withJSONObject:value, options:[.sortedKeys])
    }
    static func equal(_ a:Any, _ b:Any) -> Bool { try! canonical(a) == canonical(b) }
    static func startup(_ value:[String:Any]) -> [[String:Any]] {
        (value["sequencePhases"] as! [[String:Any]]).filter { $0["sequenceName"] as? String == "startup" }
            .sorted { ($0["phaseIndex"] as! Int) < ($1["phaseIndex"] as! Int) }
    }
    static func replacingStartup(_ value:[String:Any], _ change:(inout [[String:Any]])->Void) -> [String:Any] {
        var result=value, phases=startup(value)
        change(&phases)
        result["sequencePhases"]=phases
        return result
    }
    static func load(_ payload:[String:Any]?) throws -> (ROBServoControlStore,[String:Any],Int) {
        try FixtureDefaults.standard.seed(payload)
        let store=ROBServoControlStore.fixtureStore()
        return (store,try object(FixtureDefaults.standard.bytes!),FixtureDefaults.standard.writes)
    }
    static func main() throws {
        let (defaults,base,defaultWrites)=try load(nil)
        let phases=defaults.sequencePhasesSnapshot()
        require(defaultWrites == 1 && base["version"] as? Int == 4,"Factory defaults were not persisted as schema4")
        require(phases.count == 3 && phases.map(\.phaseIndex) == [1,2,3],"Factory startup order changed")
        require(phases.map(\.panTarget) == [0,5799,5799],"Startup changed its minimal forward pan")
        require(phases.allSatisfy { $0.lowerTarget == 6011 && $0.upperTarget == 6906 },"Factory startup still finishes in deep lean")
        require(phases[2].phaseName == "Hold upright" && phases[2].cameraPositionName == "upright","Final phase describes the wrong pose")
        let lean=defaults.cameraPosition(named:"lean_forward")!
        require(lean.lowerTarget == 7014 && lean.upperTarget == 7698 && lean.panTarget == 0,"Named lean_forward preset was overwritten")

        // Exact live legacy configuration values, including its persisted
        // .5/.5/0 holds. Preserve generated identifiers and all other records.
        var legacy=replacingStartup(base) { p in
            p[0]["holdSeconds"]=0.5;p[1]["holdSeconds"]=0.5
            p[2]["phaseName"]="Lean forward";p[2]["cameraPositionName"]="lean_forward"
            p[2]["lowerTarget"]=7014;p[2]["upperTarget"]=7698
        }
        legacy["version"]=3
        let (migrated,after,writes)=try load(legacy)
        let oldPhases=startup(legacy),newPhases=startup(after)
        require(writes == 1 && after["version"] as? Int == 4,"Exact legacy startup did not migrate once")
        require(equal(after["cameraPositions"]!,legacy["cameraPositions"]!),"Migration changed named camera positions")
        require(equal(after["gestures"]!,legacy["gestures"]!),"Migration changed unrelated gestures")
        require(equal(newPhases[0],oldPhases[0]) && equal(newPhases[1],oldPhases[1]),"Migration changed initial clearance/centering phases")
        var expectedFinal=oldPhases[2]
        expectedFinal["phaseName"]="Hold upright";expectedFinal["cameraPositionName"]="upright"
        expectedFinal["lowerTarget"]=6011;expectedFinal["upperTarget"]=6906
        require(equal(newPhases[2],expectedFinal),"Migration changed more than final pose and truthful label/reference")
        require(migrated.startupPhase(at:2)!.identifier == oldPhases[2]["identifier"] as! String,"Migration replaced phase identity")
        let (_,roundtrip,roundtripWrites)=try load(after)
        require(roundtripWrites == 0 && (equal(roundtrip,after)),"Migrated schema4 configuration rewrites or changes on reload")

        // An extra unrelated sequence is preserved even when the exact
        // automatic startup migrates. Nothing runs during any load.
        var withOther=legacy
        var other=oldPhases[2]
        other["identifier"]="fixture-other-phase";other["sequenceName"]="demo"
        other["phaseIndex"]=1;other["phaseName"]="Operator demo"
        withOther["sequencePhases"]=oldPhases+[other]
        let (_,otherAfter,_)=try load(withOther)
        let retained=(otherAfter["sequencePhases"] as! [[String:Any]]).first { $0["identifier"] as? String == "fixture-other-phase" }!
        require(equal(retained,other),"Migration changed another sequence")

        var variants:[(String,[String:Any])] = []
        func add(_ name:String,_ edit:(inout [[String:Any]])->Void) {
            variants.append((name,replacingStartup(legacy,edit)))
        }
        add("zero first hold") { $0[0]["holdSeconds"]=0.0 }
        add("zero second hold") { $0[1]["holdSeconds"]=0.0 }
        add("edited final hold") { $0[2]["holdSeconds"]=0.25 }
        add("edited final lower") { $0[2]["lowerTarget"]=6645 }
        add("edited final upper") { $0[2]["upperTarget"]=7300 }
        add("edited center pan") { $0[1]["panTarget"]=5800;$0[2]["panTarget"]=5800 }
        add("edited upright upper") { $0[0]["upperTarget"]=6907;$0[1]["upperTarget"]=6907 }
        add("edited first label") { $0[0]["phaseName"]="My clearance" }
        add("edited final label") { $0[2]["phaseName"]="My rest" }
        add("edited final preset") { $0[2]["cameraPositionName"]="upright" }
        var schema4Legacy=legacy;schema4Legacy["version"]=4
        variants.append(("current schema is operator authority",schema4Legacy))
        for (name,value) in variants {
            let (_,unchanged,_)=try load(value)
            require(equal(startup(unchanged),startup(value)),"Custom startup was modified: \(name)")
            require(equal(unchanged["cameraPositions"]!,value["cameraPositions"]!),"Custom preset changed: \(name)")
            require(equal(unchanged["gestures"]!,value["gestures"]!),"Custom gesture changed: \(name)")
            let (_,again,againWrites)=try load(unchanged)
            require(againWrites == 0 && (equal(again,unchanged)),"Custom roundtrip changed: \(name)")
        }

        // Do not broaden the exact match after the older camera-mount
        // migration turns version1's6073 into6906.
        var version1=replacingStartup(legacy) { $0[0]["upperTarget"]=6073;$0[1]["upperTarget"]=6073 }
        version1["version"]=1
        let (_,oldAfter,_)=try load(version1)
        require(startup(oldAfter)[0]["upperTarget"] as? Int == 6906,"Existing version1 mounting migration stopped")
        require(equal(startup(oldAfter)[2],startup(version1)[2]),"Automatic migration matched only after unrelated tuple mutation")

        defaults.restoreDefaults()
        require(defaults.startupPhase(at:2)!.lowerTarget == 6011 && defaults.startupPhase(at:2)!.upperTarget == 6906,"Restore defaults reinstated deep automatic lean")
        require(defaults.cameraPosition(named:"lean_forward")!.lowerTarget == 7014,"Restore defaults erased named lean preset")
        print("PASS \(checks) actual-store startup default/migration/custom/roundtrip checks; in-memory preferences only; no actuators or motion authority")
    }
}
'''


def main() -> None:
    source = SOURCE.read_text()
    assert source.count("UserDefaults.standard") == 2
    # Preserve the real production load/validate/persist code while ensuring
    # this executable cannot read or write any actual preference domain.
    source = source.replace("UserDefaults.standard", "FixtureDefaults.standard")
    with tempfile.TemporaryDirectory(prefix="rob-servo-startup-") as temporary:
        path = Path(temporary)
        combined = path / "Fixture.swift"
        combined.write_text(source + "\n" + FIXTURE)
        executable = path / "fixture"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-O",
            "-whole-module-optimization", "-parse-as-library", "-emit-executable",
            "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
            str(combined), "-o", str(executable),
        ], check=True, cwd=path)
        subprocess.run([str(executable)], check=True, cwd=path)


if __name__ == "__main__":
    main()
