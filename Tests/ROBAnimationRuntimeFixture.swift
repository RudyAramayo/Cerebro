import Cocoa

// Inert adapters: the production store, three-table editor and playback
// coordinator are compiled unchanged. No robot services or serial IO exist.
enum ROBArmSide: String { case left, right
    init?(amberGatewayArm: String) { self = amberGatewayArm == "left" ? .right : .left }
}
final class ROBAmberArmMotionArbiter {
    static let shared = ROBAmberArmMotionArbiter(); var owners: [ROBArmSide:UUID] = [:]
    func reserve(_ side: ROBArmSide, owner: UUID) -> Bool { if owners[side] != nil && owners[side] != owner { return false }; owners[side] = owner; return true }
    func release(_ side: ROBArmSide, owner: UUID) { if owners[side] == owner { owners[side] = nil } }
    func isReserved(_ side: ROBArmSide, owner: UUID) -> Bool { owners[side] == owner }
}
enum ROBArmRoutinePlan { static let tolerance = 0.025; static let minimumLeasedTrajectorySeconds = 0.65 }
enum ROBArmTargetExecutionContext { static let maximumAverageSpeedRadiansPerSecond = 0.20 }
enum ROBLeftArmTrial { static let currentLimitKey = "ROBAnimationFixtureCurrentLimit" }
extension Notification.Name { static let ROBAmberGatewayCommandDidComplete = Notification.Name("FixtureGatewayResult") }
final class ROBControllerArmApproval {
    static let shared = ROBControllerArmApproval()
    func takeLocalPanelControl() { NotificationCenter.default.post(name: Notification.Name("ROBLocalManualControlRequested"), object: self) }
}
struct Sample {
    var sequence: UInt64
    var positionsRadians: [NSNumber]
    var statuses = Array(repeating: NSNumber(value: 2), count: 7)
    var currents = Array(repeating: NSNumber(value: 0), count: 7)
    var effectiveSampleAgeMilliseconds = 0.0
    var effectiveGripperFeedbackAgeMilliseconds = 0.0
}
final class ROBAmberGatewayClient {
    static let shared = ROBAmberGatewayClient()
    var stale = false; var reject = false; var ready = true; var generation: UInt64 = 1
    var count: UInt64 = 0; var sends: [(String,[Double],Double)] = []; var holds: [String] = []
    var q = ["left": Array(repeating: 0.0, count: 7), "right": Array(repeating: 0.0, count: 7)]
    func connectionSnapshot() -> [String:Any] { ["sessionGeneration": NSNumber(value: generation)] }
    func isReady() -> Bool { ready }
    func telemetry(forArm arm: String) -> Sample? { count += 1; return Sample(sequence: count, positionsRadians: q[arm]!.map(NSNumber.init(value:)), effectiveSampleAgeMilliseconds: stale ? 1000 : 0) }
    func modes(forArm arm: String) -> [NSNumber] { Array(repeating: NSNumber(value: 2), count: 7) }
    func enterPositionMode(forArm arm: String) -> UInt64 { count += 1; return count }
    func renewLease(forArm arm: String, leaseMilliseconds: UInt32) -> UInt64 { 1 }
    func priorityHold(forArm arm: String) -> UInt64 { holds.append(arm); return 1 }
    func sendLocalAnimationStep(arm: String, expectedSessionGeneration: UInt64) -> UInt64 {
        guard let step = ROBAnimationPlayback.shared.approvedStep(arm: arm, generation: expectedSessionGeneration) else { return 0 }
        count += 1; let id = count
        sends.append((arm, step.values, step.seconds)); if !reject { q[arm] = step.values }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .ROBAmberGatewayCommandDidComplete, object: self, userInfo: ["commandID": NSNumber(value: id), "accepted": !self.reject, "error": self.reject ? "fixture rejection" : ""]) }
        return id
    }
}
@objcMembers final class ROBSerialBox: NSObject {
    var animationNeckReady = true
    var animationMaestroReady = true; var animationLACTReady = true; var neckCommandReadyAtUptime = 0.0
    var maestro: [String:NSNumber] = ["maestro.0":6000,"maestro.1":6011,"maestro.2":6906,"maestro.4":6000]
    var lact: [Double] = []; var servoWrites = 0
    func animationMaestroSnapshot() -> [String:NSNumber] { maestro }
    func applyAnimationMaestroValues(_ values: [String:NSNumber]) -> Bool { maestro.merge(values) { _,new in new }; servoWrites += 1; return true }
    func applyAnimationLACTPercent(_ percent: Double) -> Bool { lact.append(percent); return true }
    func endAnimationOutputs() { lact.append(0) }
}
final class ROBTorsoControlCenter {
    static let shared = ROBTorsoControlCenter()
    var usesHardware = true; var isArmed = true; var status = "test"; var heading = 0.0; var targets: [Double] = []
    var acceptTurn = true
    func startAnimationTurn(to heading: Double) -> Bool { guard acceptTurn else { return false }; self.heading = heading; targets.append(heading); return true }
    func animationTargetReached(_ heading: Double) -> Bool { self.heading == heading }
    func stop() { }
}

@main struct AnimationRuntimeTests {
    static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ text: String) { precondition(value(), text); checks += 1 }
        func run(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rob-animation-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ROBAnimationStore(url: root.appendingPathComponent("library.json"))
        var document = store.document
        let a = ROBAnimationPose(name: "same name", values: ["arm.right.j2":0.02])
        let b = ROBAnimationPose(name: "same name", values: ["arm.left.j3":0.03])
        document.poses = [a,b]
        let one = ROBAnimationSequence(name: "One")
        let two = ROBAnimationSequence(name: "Two", clips: [.init(pose:a,transition:1), .init(pose:b,transition:1)], completionGreeting: ROBAnimationGreeting())
        document.sequences = [one,two]
        try store.replace(document, expectedRevision: 0)
        let studio = ROBAnimationStudio(store: store)
        let library = NSTableView(), clips = NSTableView(), sequences = NSTableView()
        for table in [library,clips,sequences] { table.addTableColumn(NSTableColumn(identifier: .init("test"))) }
        let serial = ROBSerialBox()
        var spoken: [String] = [], speechCompletions: [(Bool) -> Void] = []
        var speechCancels = 0
        ROBAnimationPlayback.shared.configureSpeech({ text, completion in
            expect(serial.lact.last == 0, "Timed LACT output must be stopped before speech")
            spoken.append(text); speechCompletions.append(completion)
        }, cancel: { speechCancels += 1 })
        studio.connect(library: library, clips: clips, sequences: sequences, poseName: NSTextField(string:""), sequenceName:NSTextField(string:""), serial:serial,
            capture:{ ["arm.right.j2":0.05] }, enabled:{ ["arm.right.j2"] })
        expect(studio.numberOfRows(in: library) == 2 && studio.numberOfRows(in: clips) == 0 && studio.numberOfRows(in: sequences) == 2, "Three tables read independent datasets")
        studio.addSelectedPose()
        expect(store.document.sequences[0].clips.isEmpty, "No selection must not default to row zero")
        library.selectRowIndexes(IndexSet(integer:1), byExtendingSelection:false)
        studio.addSelectedPose()
        expect(store.document.sequences[0].clips[0].pose.values == b.values, "Add uses selected pose ID")
        expect(store.document.sequences[1].clips.count == 2, "Add cannot corrupt another sequence")
        sequences.selectRowIndexes(IndexSet(integer:1), byExtendingSelection:false)
        expect(studio.numberOfRows(in: clips) == 2, "Middle table follows selected sequence")
        library.selectRowIndexes(IndexSet(integer:0), byExtendingSelection:false)
        _ = studio.perform(NSSelectorFromString("deletePose"))
        expect(store.document.poses.count == 1 && store.document.poses[0].id == b.id, "Delete targets UUID even when names collide")
        expect(store.document.sequences[0].clips[0].pose.name == "same name", "Deleting library pose preserves clips")
        expect(studio.tableView(library, viewFor:nil, row:-1) == nil && studio.tableView(library, viewFor:nil, row:99) == nil, "Stale cells are empty")
        let before = ROBAmberGatewayClient.shared.sends.count
        studio.previewSelectedSequence(); run(0.15)
        expect(ROBAmberGatewayClient.shared.sends.count == before && serial.servoWrites == 0, "Preview must never actuate")
        expect(spoken.isEmpty, "Import and preview must never speak a completion greeting")
        _ = studio.perform(NSSelectorFromString("stopAll"))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let window = NSApp.windows.first { $0.title == "ROB Animation Studio" }!
        let popup = descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Finish: Japanese greeting") }!
        expect(popup.indexOfSelectedItem == 1, "Selected sequence displays its saved completion greeting")
        popup.selectItem(at: 0); _ = studio.perform(NSSelectorFromString("greetingChanged"))
        expect(store.document.sequences[1].completionGreeting == nil && store.document.sequences[0].completionGreeting == nil, "Greeting edit affects only the selected sequence UUID")
        popup.selectItem(at: 1); _ = studio.perform(NSSelectorFromString("greetingChanged"))
        expect(store.document.sequences[1].completionGreeting != nil && store.document.sequences[0].completionGreeting == nil, "Enabling greeting leaves the other dataset alone")
        var clipPreview: [String:Double] = [:]
        let previewObserver = NotificationCenter.default.addObserver(forName: ROBAnimationStudio.previewChanged, object: studio, queue: nil) { note in
            clipPreview = note.userInfo?["values"] as? [String:Double] ?? [:]
        }
        clips.selectRowIndexes(IndexSet(integer:1), byExtendingSelection:false)
        expect(clipPreview["arm.right.j2"] == a.values["arm.right.j2"] && clipPreview["arm.left.j3"] == b.values["arm.left.j3"], "Selected sparse clip inherits preceding sequence poses instead of current controls")
        NotificationCenter.default.removeObserver(previewObserver)
        library.selectRowIndexes(IndexSet(integer:0), byExtendingSelection:false)
        let leanField = descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Ghost lean degrees" }!
        leanField.stringValue = "12"
        studio.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: leanField))
        _ = studio.perform(NSSelectorFromString("updateSelected"))
        expect(store.document.poses[0].previewLeanDegrees == 12 && store.document.poses[0].values == b.values, "Ghost lean editor saves visual metadata without adding a motor target")
        leanField.stringValue = "46"
        studio.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: leanField))
        _ = studio.perform(NSSelectorFromString("updateSelected"))
        expect(store.document.poses[0].previewLeanDegrees == 12, "Invalid illustrative angle cannot replace the saved pose")
        _ = studio.perform(NSSelectorFromString("discardDraft"))
        if CommandLine.arguments.contains("--show") || Bundle.main.bundleIdentifier == "com.orbitusrobotics.AnimationPreviewFixture" {
            studio.show(); NSApp.activate(ignoringOtherApps: true); NSApp.run(); return
        }
        let engine = ROBAnimationPlayback.shared, gateway = ROBAmberGatewayClient.shared
        let p1 = ROBAnimationPose(name:"right only",values:["arm.right.j2":0.02])
        let p2 = ROBAnimationPose(name:"left and body",values:["arm.left.j3":0.03,"maestro.4":6200,"lact.speed":20,"torso.heading":5])
        let sequence = ROBAnimationSequence(name:"runtime", clips:[.init(pose:p1,transition:0.8), .init(pose:p2,transition:0.8)])
        engine.start(sequence:sequence, serial:serial); run(2.6)
        expect(!engine.isRunning && engine.status.contains("complete"), "Playback completes all clips")
        expect(gateway.sends.count == 2, "Each sparse arm clip dispatches only its included arm")
        expect(gateway.q["left"]![1] == 0.02 && gateway.q["right"]![2] == 0.03, "Correct physical-arm mapping and endpoint")
        expect(gateway.q["left"]![0] == 0 && gateway.q["right"]![0] == 0, "Omitted joints remain measured hold")
        expect(serial.maestro["maestro.4"] == 6200 && serial.lact.last == 0, "Servo endpoint and LACT stop")
        expect(ROBTorsoControlCenter.shared.targets == [5], "Torso track delegates to controller")
        let trackingSequence = ROBAnimationSequence(name: "menu tracking", clips: [.init(pose: .init(name:"smooth",values:["arm.right.j2":0.10]), transition:3.2)])
        let beforeTracking = gateway.sends.count
        engine.start(sequence:trackingSequence, serial:serial); run(0.12)
        let trackingDeadline = Date().addingTimeInterval(1.0)
        while Date() < trackingDeadline { RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02)) }
        expect(engine.isRunning && gateway.sends.count >= beforeTracking+2, "Menu/slider tracking must not starve sequence control: \(engine.status), sends \(gateway.sends.count-beforeTracking)")
        engine.stop(reason:"Tracking fixture ended")
        ROBTorsoControlCenter.shared.acceptTurn = false
        let servoCount = serial.servoWrites
        engine.start(sequence: .init(name:"blocked torso",clips:[.init(pose:p2,transition:0.8)]), serial:serial); run(0.15)
        expect(!engine.isRunning && serial.servoWrites == servoCount, "Failed torso preflight stops the clip before other channel dispatch")
        ROBTorsoControlCenter.shared.acceptTurn = true
        gateway.stale = true; let count = gateway.sends.count
        engine.start(sequence:sequence, serial:serial); run(0.1)
        expect(!engine.isRunning && gateway.sends.count == count, "Stale feedback cannot start playback")
        gateway.stale = false; gateway.reject = true
        engine.start(sequence:sequence, serial:serial); run(0.2)
        expect(!engine.isRunning && engine.status.contains("rejected"), "Rejected acknowledgement stops sequence")
        gateway.reject = false
        engine.start(sequence:sequence, serial:serial); run(0.1)
        ROBControllerArmApproval.shared.takeLocalPanelControl()
        expect(!engine.isRunning, "Manual takeover stops remaining clips")
        let stops = gateway.holds.count; run(1)
        expect(gateway.holds.count == stops, "Stopped sequence never replays")
        engine.start(sequence:sequence, serial:serial); run(0.1)
        gateway.generation += 1; run(0.1)
        expect(!engine.isRunning && engine.status.contains("connection changed"), "Reconnect invalidates playback")
        let bowSequence = ROBAnimationSequence(name: "Bow and greet", clips: [
            .init(pose: .init(name: "bow", values: ["arm.right.j2":0.02,"lact.speed":40], previewLeanDegrees:12), transition:0.8),
            .init(pose: .init(name: "upright", values: ["lact.speed":0], previewLeanDegrees:0), transition:0.2)
        ], completionGreeting: ROBAnimationGreeting())
        engine.start(sequence:bowSequence, serial:serial); run(1.8)
        expect(engine.isRunning && spoken == [ROBAnimationGreeting().text()], "One local-time greeting follows completed motion")
        expect(!ROBAmberArmMotionArbiter.shared.owners.isEmpty, "Arm ownership remains during speech")
        speechCompletions.last!(true); run(0.1)
        expect(!engine.isRunning && engine.status.contains("greeting complete") && speechCancels == 0, "Successful speech completes without canceling unrelated speech")
        run(0.1); expect(spoken.count == 1, "Greeting is spoken exactly once")
        engine.start(sequence:bowSequence, serial:serial); run(0.1); engine.stop(reason:"fixture stop"); run(1.5)
        expect(spoken.count == 1, "Stop during motion never reaches speech")
        engine.start(sequence:bowSequence, serial:serial); run(1.8)
        let oldCompletion = speechCompletions.last!
        ROBControllerArmApproval.shared.takeLocalPanelControl()
        expect(!engine.isRunning && speechCancels == 1 && serial.lact.last == 0, "Manual takeover cancels speech and motor outputs")
        engine.start(sequence:bowSequence, serial:serial); run(1.8)
        oldCompletion(true); run(0.1)
        expect(engine.isRunning, "Old speech completion cannot finish a new playback session")
        gateway.generation += 1; run(0.1)
        expect(!engine.isRunning && speechCancels == 2, "Reconnect during speech cancels the greeting and retains no motion session")
        speechCompletions.last!(true); run(0.1)
        expect(!engine.isRunning && ROBAmberArmMotionArbiter.shared.owners.isEmpty, "Late completion cannot replay or reclaim the arms")
        print("Animation UI/playback: \(checks) checks passed; all hardware adapters inert")
    }
}
