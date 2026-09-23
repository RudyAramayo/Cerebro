import AppKit
import CryptoKit

/// Rehearsal is a real controller-approved operation, never an authorization
/// shortcut. Only these immutable command-space paths are executable. Receipts
/// distinguish neck targets from measured arm completion and collision proof.
@objcMembers final class ROBShowMotionCoordinator: NSObject {
    static let shared = ROBShowMotionCoordinator()
    static let changed = Notification.Name("ROBShowMotionDidChange")
    static let scanID = "show.neck-scan.v1"
    static let greetingID = "show.look-and-greet.v1"
    static let greetingSummary = "Greet v1: neck upright +/-10deg, center; arms forward, calibrate/open both empty grippers, small greeting; end front"
    private(set) var isRunning = false
    private(set) var status = "Rehearse a bounded look, then an arm greeting with your controller."
    private(set) var lastReceiptPath = ""
    var cameraDemand: ((Bool) -> Void)?
    var prepare: (() -> Bool)?
    var readNeck: (() -> NSDictionary)?
    var commandNeck: ((Int, Int, Int) -> Int)?
    var releaseNeck: (() -> Void)?
    private var task: Task<Void, Never>?
    private var evidenceTimer: Timer?
    private var owner: UUID?
    private var samples: [[String: Any]] = []
    private var started = 0.0
    private var gatewayGeneration: UInt64 = 0
    private var completion: ((NSDictionary) -> Void)?
    private var activePath = ""
    private var completedComponents: [String] = []
    private var fingerprint = ""
    private let gateway = ROBAmberGatewayClient.shared
    private let vision = ROBArmRoutineVision.shared
    // Existing reviewed upright posture. Ten-degree pans are strictly inside
    // its saved limits; degree values are command-space, not shaft feedback.
    private var neckTargets: [Int] = []
    private let recordKey = "ROBShowMotionRehearsalReceiptsV1"
    private let defaults: UserDefaults
    private let receiptDirectory: URL?
    private var windowController: ROBShowRehearsalWindowController?

    override convenience init() { self.init(defaults: .standard, receiptDirectory: nil) }
    @nonobjc init(defaults: UserDefaults, receiptDirectory: URL?) {
        self.defaults = defaults; self.receiptDirectory = receiptDirectory
        super.init()
    }

    func showControls(_ sender: Any?) {
        restoreCompletedLook()
        if windowController == nil { windowController = ROBShowRehearsalWindowController(coordinator: self) }
        windowController?.showWindow(sender)
        windowController?.window?.makeKeyAndOrderFront(sender)
    }

    var cameraStatus: String { vision.readinessDescription }

    func capabilitySnapshot() -> NSDictionary {
        restoreCompletedLook()
        let recorded = defaults.dictionary(forKey: recordKey) ?? [:]
        let current = configurationFingerprint()
        let paths: [[String: Any]] = [Self.scanID, Self.greetingID].map { id in
            let rehearsed = (recorded[id] as? String) == current
            return ["id": id, "available_to_model": rehearsed,
                    "validation": rehearsed ? "command_path_rehearsed" : "needs_controller_rehearsal",
                    "start": "both arms measured hanging; neck active; base and torso stopped",
                    "neck_feedback": "commanded targets and ramp timing; no shaft feedback",
                    "clearance": "current camera veto and operator supervision; not general collision certification"]
        }
        return ["running": isRunning, "detail": status, "paths": paths,
                "receipt": lastReceiptPath, "camera": vision.healthSnapshot(),
                "torso": "Needs a verified torso/base camera reference and polarity trial",
                "body_lean": "Needs measured actuator position and clearance limits",
                "arbitrary_reach": "Needs camera-to-arm registration and physical collision validation"]
    }

    func checkCameras() {
        guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
              !ROBControllerArmApproval.shared.isPending else { return }
        isRunning = true; activePath = "camera-check"; samples = []; completedComponents = []
        started = ProcessInfo.processInfo.systemUptime
        vision.setActive(true); cameraDemand?(true)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.sample() }
        evidenceTimer = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for _ in 0..<25 {
                    try Task.checkCancellation()
                    self.setStatus(self.vision.readinessDescription)
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                self.finish(["status": self.vision.fresh ? "completed" : "blocked",
                             "detail": "Camera check: \(self.vision.readinessDescription)",
                             "camera": self.vision.healthSnapshot()])
            } catch { self.finish(["status": "cancelled", "detail": "Camera check stopped."]) }
        }
    }

    func performPath(_ id: String, rehearsal: Bool, completion: @escaping (NSDictionary) -> Void) {
        guard [Self.scanID, Self.greetingID].contains(id) else {
            completion(["status": "rejected", "detail": "Unknown show path."]); return
        }
        guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
              !ROBAmberGestureExecutor.shared.isExecuting, !ROBControllerArmApproval.shared.isPending else {
            completion(["status": "busy", "detail": "Finish or stop the current operation first."]); return
        }
        let expectedFingerprint = configurationFingerprint()
        guard let targets = makeNeckTargets() else {
            completion(["status": "blocked", "detail": "The saved upright posture, pan scale or left/right limits do not match this bounded rehearsal path."]); return
        }
        if !rehearsal {
            restoreCompletedLook()
            let records = defaults.dictionary(forKey: recordKey) ?? [:]
            guard records[id] as? String == expectedFingerprint else {
                completion(["status": "blocked", "detail": "Rehearse this exact path with the controller after the current calibration change."]); return
            }
        }
        let summary = id == Self.greetingID ? Self.greetingSummary
            : "Neck scan v1: upright, left 10deg, center, right 10deg, center; arms hanging, base and torso stopped"
        setStatus("Waiting for controller approval: \(summary)")
        ROBControllerArmApproval.shared.requestMotionPath(name: summary, execute: { [weak self] done in
            guard let self else { done(["status": "cancelled"]); return }
            guard self.configurationFingerprint() == expectedFingerprint else {
                done(["status": "blocked", "detail": "Neck calibration changed while awaiting approval."]); return
            }
            self.start(id: id, fingerprint: expectedFingerprint, targets: targets, completion: done)
        }, cancel: { [weak self] in self?.cancelExecution() }, completion: { [weak self] result in
            self?.setStatus(result["detail"] as? String ?? "Rehearsal ended")
            completion(result)
        })
    }

    private func start(id: String, fingerprint: String, targets: [Int], completion: @escaping (NSDictionary) -> Void) {
        let owner = UUID()
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: owner) else {
            completion(["status": "blocked", "detail": "An arm is already owned."]); return
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: owner) else {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            completion(["status": "blocked", "detail": "An arm is already owned."]); return
        }
        self.owner = owner; self.completion = completion; self.fingerprint = fingerprint
        neckTargets = targets
        isRunning = true; activePath = id; samples = []; gatewayGeneration = 0; completedComponents = []
        started = ProcessInfo.processInfo.systemUptime
        vision.setActive(true); cameraDemand?(true)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.sample() }
        evidenceTimer = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard self.prepare?() == true else { throw Failure("Another body controller is active.") }
                if !self.gateway.isReady() { ROBAmberGatewayTunnel.shared.connect() }
                try await self.wait(seconds: 12, detail: "Arm gateway unavailable") { self.gateway.isReady() }
                self.gatewayGeneration = (self.gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
                for arm in ["left", "right"] { _ = self.gateway.queryMode(forArm: arm) }
                try await self.wait(seconds: 3, detail: "Fresh hanging-arm feedback is required") { self.hangingArms() }
                try await self.wait(seconds: 8, detail: "Main camera unavailable") { self.vision.fresh }
                for (index, pan) in self.neckTargets.enumerated() {
                    let center = self.neckTargets[0]
                    self.setStatus("Neck rehearsal \(index + 1)/5: \(pan == center ? "center" : pan > center ? "left 10 degrees" : "right 10 degrees")")
                    try await self.neckStep(pan)
                }
                self.completedComponents = [Self.scanID]
                var result: NSDictionary = ["status": "completed", "detail": "Neck scan commands completed; physical shaft position and clearance remain operator-observed.", "neck_measured": false]
                if id == Self.greetingID {
                    self.releaseArms()
                    self.setStatus("Look completed; checking the arm path for the greeting")
                    result = await withCheckedContinuation { continuation in
                        ROBArmRoutineCoordinator.shared.continueApprovedGreeting { continuation.resume(returning: $0) }
                    }
                    try Task.checkCancellation()
                }
                var final = result as? [String: Any] ?? [:]
                final["neck_measured"] = false
                final["path_id"] = id
                final["validation"] = "command_path_only; neck physical arrival unverified"
                if final["status"] as? String == "completed" { self.completedComponents.append(id) }
                self.finish(final as NSDictionary)
            } catch {
                self.finish(["status": "blocked", "detail": error.localizedDescription,
                             "camera": self.vision.healthSnapshot(), "neck": self.readNeck?() ?? [:]])
            }
        }
    }

    private struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    private func hangingArms() -> Bool {
        ["left", "right"].allSatisfy { arm in
            guard let sample = gateway.telemetry(forArm: arm), sample.effectiveSampleAgeMilliseconds <= 250,
                  sample.positionsRadians.count == 7,
                  sample.positionsRadians.allSatisfy({ abs($0.doubleValue) <= 0.08 }) else { return false }
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            return modes.count == 7 && (modes.allSatisfy { $0 == 0 } || modes.allSatisfy { $0 == 2 })
        }
    }

    @MainActor private func wait(seconds: Double, detail: String, condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            if !gateway.isReady(), let error = ROBAmberGatewayTunnel.shared.failureDetail { throw Failure(error) }
            guard ProcessInfo.processInfo.systemUptime < until else {
                throw Failure("\(detail). \(vision.readinessDescription).")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
    }

    @MainActor private func neckStep(_ pan: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var submitted = false
        var applied = false
        var settledAt: Double?
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline, now - started < 50 else { throw Failure("Neck target did not settle before the deadline.") }
            guard gateway.isReady(),
                  (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == gatewayGeneration,
                  hangingArms(), !ROBTorsoControlCenter.shared.isArmed else { throw Failure("Arm feedback, hanging pose, or body ownership changed.") }
            guard vision.fresh else { throw Failure("Main-camera feedback lost. \(vision.readinessDescription).") }
            guard vision.handsClear else { throw Failure("A person or hand is too close for the neck rehearsal.") }
            guard configurationFingerprint() == fingerprint else { throw Failure("The motion configuration changed during rehearsal.") }
            guard let neck = readNeck?(), neck["known"] as? Bool == true,
                  let readyAt = neck["ready_at"] as? Double else { throw Failure("A known active neck is required.") }
            let matches = neck["pan"] as? Int == pan && neck["lower"] as? Int == 6011 && neck["upper"] as? Int == 6906
            if applied && (!matches || neck["source"] as? String != "Torso servo control") {
                throw Failure("Another neck command interrupted rehearsal.")
            }
            if submitted && matches && now >= readyAt {
                if settledAt == nil { settledAt = now }
                if now - settledAt! >= 0.2 { sample(); return }
            } else if now >= readyAt {
                guard !submitted || neck["source"] as? String == "Torso servo control" else {
                    throw Failure("Another neck command interrupted rehearsal.")
                }
                guard let disposition = commandNeck?(pan, 6011, 6906), disposition != 0 else {
                    throw Failure("Neck safety gateway rejected the rehearsal target. \(neck["detail"] ?? "")")
                }
                submitted = true
                applied = disposition == 1
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func stop() {
        ROBControllerArmApproval.shared.cancel(reason: "Show rehearsal stopped by operator")
        cancelExecution()
    }

    private func cancelExecution() {
        task?.cancel()
        if ROBArmRoutineCoordinator.shared.isRunning {
            ROBArmRoutineCoordinator.shared.cancel(reason: "Show rehearsal stopped")
        }
        if activePath != "camera-check" { releaseNeck?() }
    }

    private func sample() {
        guard samples.count < 600 else { return }
        var arms: [String: Any] = [:]
        for arm in ["left", "right"] {
            if let feedback = gateway.telemetry(forArm: arm) {
                let age = feedback.effectiveSampleAgeMilliseconds
                arms[arm] = ["positions": feedback.positionsRadians, "modes": gateway.modes(forArm: arm),
                             "age_ms": age.isFinite ? age as Any : NSNull()]
            }
        }
        samples.append(["elapsed_s": ProcessInfo.processInfo.systemUptime - started,
                        "camera": vision.healthSnapshot(), "neck": readNeck?() ?? [:], "arms": arms])
    }

    private func releaseArms() {
        if let owner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        }
        owner = nil
    }

    private func finish(_ result: NSDictionary) {
        evidenceTimer?.invalidate(); evidenceTimer = nil
        let receipt: [String: Any] = ["path_id": activePath, "configuration": fingerprint,
            "at": ISO8601DateFormatter().string(from: Date()), "result": result,
            "completed_components": Array(Set(completedComponents)).sorted(),
            "evidence": "Command-space neck samples; no shaft measurement or collision certification", "samples": samples]
        do {
            let folder = try receiptDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Cerebro/ShowRehearsals")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
            lastReceiptPath = file.path
            if !completedComponents.isEmpty {
                var records = defaults.dictionary(forKey: recordKey) ?? [:]
                for id in completedComponents { records[id] = fingerprint }
                defaults.set(records, forKey: recordKey)
            }
        } catch { lastReceiptPath = "Receipt could not be saved: \(error.localizedDescription)" }
        if activePath != "camera-check" { releaseNeck?() }
        releaseArms(); vision.setActive(false); cameraDemand?(false)
        isRunning = false; task = nil
        setStatus(result["detail"] as? String ?? "Rehearsal ended")
        let done = completion; completion = nil; done?(result)
    }

    private func configurationFingerprint() -> String {
        let neck = readNeck?() ?? [:]
        let config: [String: Any] = ["neck": defaults.dictionary(forKey: "ROBNeckSafetyConfigurationV3") ?? [:],
            "arm_corridor": ROBArmRendition.revision, "path_revision": 1, "targets": makeNeckTargets() ?? [],
            "saved_left": neck["saved_left"] ?? 0, "saved_right": neck["saved_right"] ?? 0,
            "speed": defaults.integer(forKey: "ROBMaestroServoSpeedLimit"),
            "acceleration": defaults.integer(forKey: "ROBMaestroServoAccelerationLimit")]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeNeckTargets() -> [Int]? {
        let config = defaults.dictionary(forKey: "ROBNeckSafetyConfigurationV3") ?? [:]
        let scale = (config["panTargetsPerDegree"] as? NSNumber)?.doubleValue ?? (100.0 / 3.0)
        guard scale.isFinite, abs(scale - 100.0 / 3.0) < 0.05,
              let neck = readNeck?(), neck["saved_upright_valid"] as? Bool == true,
              let center = neck["saved_center"] as? Int,
              let left = neck["saved_left"] as? Int, let right = neck["saved_right"] as? Int,
              (4000...8000).contains(center), right >= 4000, left <= 8000,
              center - 333 >= right, center + 333 <= left else { return nil }
        return [center, center + 333, center, center - 333, center]
    }

    /// The first installed rehearsal build wrote its final path marker only
    /// after every neck step and the arm continuation returned. Recover that
    /// completed look even when the subsequent arm inspection was blocked.
    /// This restores execution evidence, never a controller authorization.
    private func restoreCompletedLook() {
        guard !isRunning, makeNeckTargets() != nil else { return }
        let current = configurationFingerprint()
        var records = defaults.dictionary(forKey: recordKey) ?? [:]
        guard records[Self.scanID] as? String != current else { return }
        guard let folder = receiptDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Cerebro/ShowRehearsals"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let recent = files.filter { $0.pathExtension == "json" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.prefix(50)
        for file in recent {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 2_000_000,
                  let data = try? Data(contentsOf: file),
                  let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  receipt["configuration"] as? String == current,
                  receipt["path_id"] as? String == Self.greetingID,
                  let result = receipt["result"] as? [String: Any],
                  result["path_id"] as? String == Self.greetingID,
                  result["validation"] as? String == "command_path_only; neck physical arrival unverified",
                  result["neck_measured"] as? Bool == false,
                  ["completed", "blocked"].contains(result["status"] as? String ?? "") else { continue }
            records[Self.scanID] = current
            defaults.set(records, forKey: recordKey)
            lastReceiptPath = file.path
            setStatus("Look command path rehearsed; the combined arm greeting still needs its own successful result.")
            return
        }
    }

    private func setStatus(_ value: String) {
        status = value
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

private final class ROBShowRehearsalWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: ROBShowMotionCoordinator
    private let state = NSTextField(wrappingLabelWithString: "")
    private let camera = NSTextField(wrappingLabelWithString: "")
    private let receipt = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(coordinator: ROBShowMotionCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Motion Rehearsal"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
        let title = NSTextField(labelWithString: "Look toward the audience, then greet")
        title.font = .boldSystemFont(ofSize: 20)
        let description = NSTextField(wrappingLabelWithString:
            "Start with both arms hanging and the neck active. The look path uses the upright neck preset, looks 10° left and right, and returns to center. The combined greeting then checks the arm view, brings both arms forward, calibrates both empty grippers, and makes a small paired greeting. Arms finish in front. Your iPhone or Vision Pro approves the complete path once.")
        let limits = NSTextField(wrappingLabelWithString:
            "Stay clear during the trial and watch cables and clearance. Neck readouts report commanded targets; they do not measure shaft position. Each receipt records camera health and command results. Torso, body lean and arbitrary reaching need separate measured trials.")
        let buttons = NSStackView(views: [NSButton(title: "Check cameras (no movement)", target: self, action: #selector(checkCamera)),
            NSButton(title: "Rehearse look", target: self, action: #selector(scan)),
            NSButton(title: "Rehearse look + greet", target: self, action: #selector(greet)),
            NSButton(title: "Stop + hold", target: self, action: #selector(stop))])
        buttons.spacing = 12
        receipt.font = .systemFont(ofSize: 11); receipt.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, description, limits, buttons, state, camera, receipt])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)])
        for label in [description, limits, state, camera, receipt] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    private func refresh() {
        state.stringValue = coordinator.status
        camera.stringValue = coordinator.isRunning ? coordinator.cameraStatus : ""
        receipt.stringValue = coordinator.lastReceiptPath.isEmpty ? "" : "Receipt: \(coordinator.lastReceiptPath)"
    }
    @objc private func checkCamera() { coordinator.checkCameras() }
    @objc private func scan() { coordinator.performPath(ROBShowMotionCoordinator.scanID, rehearsal: true) { _ in } }
    @objc private func greet() { coordinator.performPath(ROBShowMotionCoordinator.greetingID, rehearsal: true) { _ in } }
    @objc private func stop() { coordinator.stop(); _ = ROBAmberGestureExecutor.shared.requestPriorityHold() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}
