import AppKit

enum ROBArmRoutineError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let detail) = self { return detail }; return nil }
}

/// One owner for startup, prepare/grab/hold and gentle relax. Both arms move
/// together with bounded, distance-based segment timing. Camera/telemetry monitoring and the
/// gateway watchdog continue independently of language-model latency.
@objcMembers final class ROBArmRoutineCoordinator: NSObject {
    static let shared = ROBArmRoutineCoordinator()
    private(set) var isRunning = false
    private(set) var status = "Arms idle"
    private(set) var inspectionPanDegrees = 0.0
    var ownsPhysicalMotion: Bool { (isRunning && activeCommand != "teach") || ROBShowMotionCoordinator.shared.isRunning }
    var cameraDemand: ((Bool) -> Void)?
    var prepareView: (() -> Bool)?
    var viewIsStationary: (() -> Bool)?
    var viewStatus: (() -> String)?

    private let gateway = ROBAmberGatewayClient.shared
    private let vision = ROBArmRoutineVision.shared
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var owner: UUID?
    private var generation: UInt64 = 0
    private var referencedGeneration: UInt64 = 0
    private var acknowledgements: [UInt64: Bool] = [:]
    private var expected: Set<UInt64> = []
    private var renewalIDs: Set<UInt64> = []
    private var renewalSentAt: [UInt64: Double] = [:]
    private var leased: Set<String> = []
    private var lastRenewal = 0.0
    private var deadline = 0.0
    private var failure: String?
    private var superviseCamera = false
    private var supervisedRoute = false
    private var moving = false
    private var completion: ((NSDictionary) -> Void)?
    private var startupTicket: UUID?
    private var activeCommand = ""
    private var activeRendition: ROBArmRendition?
    private let arms = ["left", "right"] // gateway keys; physical sides convert at the boundary

    func capabilitySnapshot() -> NSDictionary {
        ["status": isRunning ? "running" : "idle", "detail": status,
         "commands": ["status", "prepare", "grab", "hold", "relax", "wave", "teach", "replay", "stop"],
         "gateway_ready": gateway.isReady(), "camera": "main face RGB-D",
         "camera_ready": vision.fresh, "camera_detail": vision.readinessDescription,
         "motion_owner": "local coordinator; paired arms and bounded segments",
         "corridor_revision": ROBArmRendition.revision,
         "route_supervision": "One explicit controller approval covers the taught route despite incomplete camera visibility. Operator watches clearance; live camera, hand/person veto, motor feedback and Stop remain active. Calibration and closing require a stationary camera assessment; every preparation automatically requests both calibrated jaws open under live camera and operator supervision.",
         "limits": "Fixed hanging/front corridor only. Teach/replay maps symmetric relative lift order; no general human joint copying, arbitrary reach or full-environment collision guarantee. Empty jaws required for greetings/replay.",
         "preparation": "Every prepare/startup/grab/hold opens both calibrated grippers at the stationary front pose. Current gateway calibration acceptance is reused, including manual diagnostics calibration. Opening is not measured jaw feedback.",
         "gripper_completion": "command acceptance and visual observations; force and secure grasp unverified"]
    }

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
            object: gateway, queue: .main) { [weak self] note in
                guard let self, let id = (note.userInfo?["commandID"] as? NSNumber)?.uint64Value else { return }
                let accepted = note.userInfo?["accepted"] as? Bool == true
                if self.renewalIDs.remove(id) != nil {
                    self.renewalSentAt.removeValue(forKey: id)
                    if !accepted { self.abort("The arm motion lease could not be renewed.") }
                } else if self.expected.contains(id) {
                    self.acknowledgements[id] = accepted
                    if !accepted { self.abort(note.userInfo?["error"] as? String ?? "An arm command was rejected.") }
                }
            }
    }

    /// Narrow local fallback for addressed speech and the chat composer. A
    /// discussion about grabbing, a negation, or 'hold on' is not a command.
    static func commandForText(_ text: String) -> String? {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "\\b(?:not|don't|don’t|stop|wait|never|unless|until|if|explain|quote|say)\\b", options: .regularExpression) == nil,
              !value.contains("\""), !value.contains("‘"), !value.contains("'") else { return nil }
        let prefix = "^(?:(?:rob|robbie|robot)[, ]+)?(?:(?:please|can you|could you|would you|i want you to) )?(?:please )?"
        if value.range(of: prefix + "wave(?: (?:at|to) .+)?[.!?]*$", options: .regularExpression) != nil { return "wave" }
        if value.range(of: prefix + "(?:copy (?:me|my (?:pose|movement))|learn (?:this|my) (?:pose|movement)|record (?:this|my) (?:pose|movement))[.!?]*$", options: .regularExpression) != nil { return "teach" }
        if value.range(of: prefix + "(?:replay|repeat|imitate) (?:that|the|my|last|this) (?:pose|movement)[.!?]*$", options: .regularExpression) != nil { return "replay" }
        if value.range(of: prefix + "relax(?: (?:your |the )?arms)?[.!?]*$", options: .regularExpression) != nil { return "relax" }
        if value.range(of: prefix + "(?:prepare to (?:grab|hold)|bring (?:your |the )?arms (?:in |to the )?front)[.!?]*$", options: .regularExpression) != nil { return "prepare" }
        if value.range(of: prefix + "(?:grab|pick up|hold) (?:this|that|something|the|a|an|my)\\b.*$", options: .regularExpression) != nil {
            return value.contains("hold ") ? "hold" : "grab"
        }
        return nil
    }

    func wakeIfEnabled() {
        precondition(Thread.isMainThread)
        guard UserDefaults.standard.bool(forKey: ROBArmRoutinePlan.startupDefaultsKey),
              startupTicket == nil, !isRunning else { return }
        let ticket = UUID()
        startupTicket = ticket
        // Let cameras, serial discovery and the stored SSH tunnel recover once.
        // There is no indefinite retry or delayed surprise activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            guard self.startupTicket == ticket else { return }
            self.startupTicket = nil
            guard UserDefaults.standard.bool(forKey: ROBArmRoutinePlan.startupDefaultsKey) else { return }
            self.performCommand("startup", target: "") { _ in }
        }
    }

    func performCommand(_ command: String, target: String, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard !ROBShowMotionCoordinator.shared.isRunning else {
            completion(["status": "busy", "detail": "The show rehearsal owns motion. Use Stop + hold first."]); return
        }
        if command == "teach" { recordDemonstration(name: target, completion: completion); return }
        guard ["startup", "prepare", "grab", "hold", "relax", "wave", "replay"].contains(command) else {
            completion(["status": "rejected", "detail": "Unknown arm routine."]); return
        }
        if command == "relax" { cancel(reason: "Relax requested; waiting for controller approval") }
        guard !ROBControllerArmApproval.shared.isPending else {
            completion(["status": "busy", "detail": ROBControllerArmApproval.shared.status]); return
        }
        let rendition = command == "wave" ? ROBArmRendition.greeting
            : command == "replay" ? ROBArmImitationStore.shared.find(target.isEmpty ? "last" : target) : nil
        if command == "replay" && rendition == nil {
            completion(["status": "blocked", "detail": "Record a body demonstration first, or select a clip_id returned by robot_capabilities."]); return
        }
        let inspectionPan = ROBArmRoutinePlan.inspectionPanDegrees()
        var summary: String
        if let rendition {
            summary = "\(rendition.name): move both arms along the taught route, then replay \(rendition.waypoints.count) bounded front-corridor steps. Grippers stay unchanged; confirm they are empty. Both arms end in front."
        } else if command == "relax" { summary = "Return both arms gently to hanging, then deactivate position mode." }
        else { summary = "\(command.capitalized): bring both arms forward, calibrate both empty grippers if needed, and \(command == "grab" || command == "hold" ? "attempt a camera-checked grip of \(String(target.prefix(160)))" : "request both grippers open"). Both grippers open during preparation, including after an earlier grip; support any held object and clear the jaws." }
        if inspectionPan != 0 {
            summary += " Inspection camera pans 10° \(inspectionPan < 0 ? "right" : "left")."
        }
        summary += " " + ROBControllerArmApproval.supervisedRouteNotice
        setStatus("Awaiting Vision Pro or iPhone approval: \(summary)")
        ROBControllerArmApproval.shared.request(operation: rendition == nil ? command : "gesture", arm: "both", summary: summary,
            execute: { [weak self] done in
                guard let self else { done(["status": "cancelled", "detail": "Arm runtime closed."]); return }
                self.performAuthorizedCommand(command, target: target, rendition: rendition,
                    inspectionPanDegrees: inspectionPan, completion: done)
            }, cancel: { [weak self] in self?.cancelAuthorized(reason: "Controller cancelled or disconnected") },
            completion: { [weak self] result in
                if self?.isRunning != true { self?.setStatus(result["detail"] as? String ?? "Arm operation ended") }
                completion(result)
            })
    }

    /// Continue only the exact, already-approved combined greeting. No public
    /// model tool can use this entry to skip the controller's one-shot grant.
    func continueApprovedGreeting(completion: @escaping (NSDictionary) -> Void) {
        guard ROBShowMotionCoordinator.shared.isRunning,
              ROBControllerArmApproval.shared.authorizesMotionPath(ROBShowMotionCoordinator.greetingSummary) else {
            completion(["status": "blocked", "detail": "The combined greeting has no active controller approval."]); return
        }
        performAuthorizedCommand("wave", target: "", rendition: .greeting, completion: completion)
    }

    /// Camera-only capture. Nothing in this path enters a motor mode or sends a
    /// target. Replay is a separate controller-approved operation.
    private func recordDemonstration(name: String, completion: @escaping (NSDictionary) -> Void) {
        guard !isRunning, !ROBControllerArmApproval.shared.isPending,
              !ROBAmberGestureExecutor.shared.isExecuting else {
            completion(["status": "busy", "detail": "Finish the current arm operation before teaching."]); return
        }
        isRunning = true; activeCommand = "teach"; self.completion = completion; failure = nil
        activeRendition = nil; generation = 0; superviseCamera = false; moving = false
        deadline = ProcessInfo.processInfo.systemUptime + 15
        vision.setActive(true, teaching: true); cameraDemand?(true)
        setStatus("Camera-only teaching: show both shoulders, hips and wrists; slowly raise and lower your arms for five seconds.")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.wait(seconds: 7, reason: "One clear body pose did not arrive in the forward camera.") {
                    guard let sample = self.vision.demonstrationSample else { return false }
                    return (0...700).contains(Date().timeIntervalSince1970 * 1000 - sample.capturedAt)
                }
                var builder = ROBArmDemonstrationBuilder(), lastSequence: UInt64 = 0
                var lastSeen = ProcessInfo.processInfo.systemUptime
                let end = lastSeen + 5
                while ProcessInfo.processInfo.systemUptime < end {
                    try self.check()
                    if let sample = self.vision.demonstrationSample, sample.sequence != lastSequence {
                        guard builder.append(sample, now: Date().timeIntervalSince1970 * 1000) else {
                            throw ROBArmRoutineError.blocked("Body tracking became stale or discontinuous; no rendition was saved.")
                        }
                        lastSequence = sample.sequence; lastSeen = ProcessInfo.processInfo.systemUptime
                    }
                    guard ProcessInfo.processInfo.systemUptime - lastSeen <= 0.8 else {
                        throw ROBArmRoutineError.blocked("The demonstrated body left view; no rendition was saved.")
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard let clip = builder.rendition(name: name.isEmpty ? "Camera demonstration" : name),
                      ROBArmImitationStore.shared.save(clip) else {
                    throw ROBArmRoutineError.blocked("The body demonstration did not provide enough stable poses.")
                }
                self.finish(["status": "recorded", "clip_id": clip.id,
                    "detail": "Recorded a symmetric front-corridor rendition. No motors moved. Replay needs controller approval and current camera clearance.",
                    "nominal_replay_motion_seconds": clip.nominalMotionSeconds, "operation_timeout_seconds": 90], hold: false)
            } catch {
                self.finish(["status": "blocked", "detail": self.failure ?? error.localizedDescription], hold: false)
            }
        }
    }

    private func performAuthorizedCommand(_ command: String, target: String, rendition: ROBArmRendition? = nil,
                                          inspectionPanDegrees: Double = 0, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard ["startup", "prepare", "grab", "hold", "relax", "wave", "replay"].contains(command) else {
            completion(["status": "rejected", "detail": "Unknown arm routine."]); return
        }
        if isRunning {
            if command == "relax" && activeCommand != "relax" {
                // Stop the old trajectory first; wait for its task to release
                // reservations before planning from the new measured pose.
                cancelAuthorized(reason: "Relax requested")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let until = ProcessInfo.processInfo.systemUptime + 3
                    while self.isRunning && ProcessInfo.processInfo.systemUptime < until {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if self.isRunning { completion(["status": "blocked", "detail": "The previous arm operation has not stopped."]) }
                    else { self.performAuthorizedCommand(command, target: target, rendition: rendition,
                        inspectionPanDegrees: inspectionPanDegrees, completion: completion) }
                }
            } else { completion(["status": "busy", "detail": status]) }
            return
        }
        let id = UUID()
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: id) else {
            completion(["status": "blocked", "detail": "Another controller owns the left arm."]); return
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: id) else {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: id)
            completion(["status": "blocked", "detail": "Another controller owns the right arm."]); return
        }
        startupTicket = nil
        activeRendition = rendition
        self.inspectionPanDegrees = inspectionPanDegrees
        supervisedRoute = ROBControllerArmApproval.shared.authorizesSupervisedArmRoute()
        owner = id; isRunning = true; activeCommand = command; failure = nil; self.completion = completion
        deadline = ProcessInfo.processInfo.systemUptime + 90
        superviseCamera = false; moving = false; generation = 0
        vision.setActive(true); cameraDemand?(true)
        setStatus(command == "relax" ? "Returning arms gently to hanging" : "Checking cameras and arm feedback")
        if !gateway.isReady() { ROBAmberGatewayTunnel.shared.connect() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.monitor() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.execute(command, target: target)
                self.finish(result, hold: false)
            } catch {
                self.finish(["status": "blocked", "detail": self.failure ?? error.localizedDescription,
                             "camera": self.vision.healthSnapshot()], hold: true)
            }
        }
    }

    func cancel(reason: String) {
        ROBControllerArmApproval.shared.cancel(reason: reason)
        cancelAuthorized(reason: reason)
    }

    private func cancelAuthorized(reason: String) {
        precondition(Thread.isMainThread)
        startupTicket = nil
        guard isRunning else { return }
        abort(reason)
    }

    private func abort(_ detail: String) {
        guard isRunning, failure == nil else { return }
        failure = detail; task?.cancel()
        if activeCommand != "teach" { for arm in arms { _ = gateway.priorityHold(forArm: arm) } }
        leased.removeAll(); moving = false
        setStatus(detail)
    }

    private func setStatus(_ detail: String) {
        status = detail
        NotificationCenter.default.post(name: Notification.Name("ROBArmRoutineDidChange"), object: self)
    }

    private func check() throws {
        try Task.checkCancellation()
        if let failure { throw ROBArmRoutineError.blocked(failure) }
        if supervisedRoute && !ROBControllerArmApproval.shared.authorizesSupervisedArmRoute() {
            throw ROBArmRoutineError.blocked("Controller supervision ended; an arm hold was requested.")
        }
        if activeCommand != "teach", generation == 0, !gateway.isReady(),
           let connectionFailure = ROBAmberGatewayTunnel.shared.failureDetail {
            throw ROBArmRoutineError.blocked(connectionFailure)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ROBArmRoutineError.blocked("Arm operation exceeded its deadline.") }
        if superviseCamera {
            guard vision.fresh, viewIsStationary?() == true else {
                throw ROBArmRoutineError.blocked(cameraFailureDetail)
            }
            if moving && !vision.handsClear { throw ROBArmRoutineError.blocked("Person or hand clearance was lost.") }
        }
    }

    private var cameraFailureDetail: String {
        if !vision.fresh { return "Main-camera feedback lost. \(vision.readinessDescription)." }
        return "Inspection view changed. \(viewStatus?() ?? "The neck or torso moved.")"
    }

    @MainActor private func wait(seconds: Double, reason: String = "Timed out waiting for command acknowledgement or measured arrival.", until condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try check()
            guard ProcessInfo.processInfo.systemUptime < until else { throw ROBArmRoutineError.blocked(reason) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check()
    }

    private func send(_ id: UInt64) throws -> UInt64 {
        precondition(Thread.isMainThread)
        try check()
        guard id != 0 else { throw ROBArmRoutineError.blocked("The gateway refused an arm or gripper command.") }
        expected.insert(id); return id
    }

    @MainActor private func accepted(_ ids: [UInt64]) async throws {
        try await wait(seconds: 3) { ids.allSatisfy { acknowledgements[$0] == true } }
        for id in ids { expected.remove(id); acknowledgements.removeValue(forKey: id) }
    }

    private func measured(_ arm: String) throws -> [Double] {
        guard let sample = gateway.telemetry(forArm: arm), sample.sequence > 0,
              sample.effectiveSampleAgeMilliseconds <= 250,
              sample.effectiveGripperFeedbackAgeMilliseconds <= 250,
              sample.positionsRadians.count == 7 else { throw ROBArmRoutineError.blocked("Fresh per-motor feedback is missing on \(arm == "left" ? "ROB-right" : "ROB-left").") }
        return sample.positionsRadians.map(\.doubleValue)
    }

    private func verifyFrontBeforeGripperMotion() throws {
        try check()
        for arm in arms {
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            let statuses = gateway.telemetry(forArm: arm)?.statuses.map(\.intValue) ?? []
            guard modes.count == 7, modes.allSatisfy({ $0 == 2 }),
                  statuses.count == 7, statuses.allSatisfy({ $0 == 2 }),
                  ROBArmRoutinePlan.near(try measured(arm), ROBArmRoutinePlan.target(index: 6, physicalLeft: arm == "right")!) else {
                throw ROBArmRoutineError.blocked("Both measured arms must remain in front and in position mode before gripper motion.")
            }
        }
    }

    @MainActor private func inspect(target: String, calibration: Bool = false, grippers: Bool = true) async throws -> ROBArmRoutineObservation {
        moving = false
        let observation = try await vision.observe(target: target, grippers: grippers) { [weak self] detail in
            self?.setStatus(detail)
        }
        try check()
        if grippers {
            if let reason = observation.gripperInspectionBlockReason { throw ROBArmRoutineError.blocked(reason) }
        } else if let reason = observation.motionBlockReason { throw ROBArmRoutineError.blocked(reason) }
        guard vision.handsClear else {
            throw ROBArmRoutineError.blocked("The live camera detector cannot confirm person and hand clearance. Keep hands away from the arms and grippers.")
        }
        if calibration && !observation.permitsCalibration {
            throw ROBArmRoutineError.blocked("Both grippers must be visible and empty in front, with hands clear, before calibration.")
        }
        return observation
    }

    @MainActor private func execute(_ command: String, target: String) async throws -> NSDictionary {
        try await wait(seconds: 12, reason: "The arm gateway did not connect. Check Amber Arm Diagnostics for the connection error.") { gateway.isReady() }
        let connectedGeneration = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        guard connectedGeneration > 0 else { throw ROBArmRoutineError.blocked("The arm gateway session is not authenticated.") }
        try await accepted(arms.map { try send(gateway.queryMode(forArm: $0)) })
        // A ready/ack packet can precede the first telemetry packet. Wait while
        // still non-actuating, then enable continuous freshness supervision.
        try await wait(seconds: 3, reason: "Fresh feedback from all arm and gripper motors did not arrive.") { arms.allSatisfy { (try? measured($0)) != nil } }
        guard gateway.isReady(),
              (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == connectedGeneration else {
            throw ROBArmRoutineError.blocked("The gateway session changed during arm preflight.")
        }
        generation = connectedGeneration
        var routes: [String: [Int]] = [:]
        for arm in arms {
            let q = try measured(arm)
            guard let route = ROBArmRoutinePlan.route(from: q, physicalLeft: arm == "right", hanging: command == "relax") else {
                throw ROBArmRoutineError.blocked("An arm is outside the taught hanging/front route. No direct move to zero was sent.")
            }
            routes[arm] = route
        }
        // Already hanging: deactivate without energizing, camera motion or jaw motion.
        if command == "relax", routes.values.allSatisfy(\.isEmpty), arms.allSatisfy({ arm in
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            return modes.count == 7 && modes.allSatisfy { $0 == 0 }
        }) {
            try await deactivateAtHanging()
            return ["status": "completed", "detail": "Both arms are measured at hanging zero and inactive."]
        }
        setStatus("Positioning the camera for arm inspection")
        try await wait(seconds: 12, reason: "The neck could not settle at the arm inspection view.") { prepareView?() == true }
        setStatus("Waiting for the main RGB-D inspection camera")
        do {
            try await wait(seconds: 10) { vision.fresh && viewIsStationary?() == true }
        } catch {
            try check()
            throw ROBArmRoutineError.blocked("Inspection cameras are not ready. \(vision.readinessDescription).")
        }
        superviseCamera = true
        let atHanging = arms.allSatisfy { arm in
            (try? measured(arm)).map { ROBArmRoutinePlan.near($0, Array(repeating: 0, count: 7)) } == true
        }
        if supervisedRoute {
            try check()
            guard vision.handsClear else { throw ROBArmRoutineError.blocked("A person or hand is too close to the arms. Clear the route before supervised movement.") }
            if referencedGeneration != generation {
                guard atHanging else {
                    throw ROBArmRoutineError.blocked("A new arm session must start at measured hanging zero with the operator confirming the physical pose. No unverified datum was accepted.")
                }
                referencedGeneration = generation
            }
            setStatus("Controller-approved taught route; operator watching clearance")
        } else {
            setStatus("Inspecting the complete arm path in the main camera")
            let observation = try await inspect(target: target, grippers: false)
            guard !atHanging || observation.hanging else {
                referencedGeneration = 0
                throw ROBArmRoutineError.blocked("Encoder zero does not match visually hanging arms; the session datum is invalid.")
            }
            if referencedGeneration != generation {
                guard observation.hanging, atHanging else {
                    throw ROBArmRoutineError.blocked("A new controller session needs camera-observed hanging arms at encoder zero. The B1 calibration was preserved.")
                }
                referencedGeneration = generation
            }
        }
        if command == "relax", routes.values.allSatisfy(\.isEmpty) {
            try await deactivateAtHanging()
            return ["status": "completed", "detail": "Both arms are at measured hanging zero and inactive."]
        }
        for arm in arms {
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            guard modes.count == 7, modes.allSatisfy({ $0 == 0 }) || modes.allSatisfy({ $0 == 1 }) || modes.allSatisfy({ $0 == 2 }) else {
                throw ROBArmRoutineError.blocked("Arm modes are mixed or unsupported.")
            }
            if !modes.allSatisfy({ $0 == 2 }) {
                try await accepted([try send(gateway.enterPositionMode(forArm: arm))])
            }
        }
        // Mode acknowledgements and streamed CAN telemetry arrive separately.
        // Require a new matching sample after the acknowledgements before the
        // first waypoint, rather than treating a pre-entry sample as a fault.
        let modeSequences = Dictionary(uniqueKeysWithValues: arms.map {
            ($0, gateway.telemetry(forArm: $0)?.sequence ?? 0)
        })
        try await wait(seconds: 2, reason: "Fresh position-mode feedback did not arrive for both arms; no waypoint was sent.") {
            arms.allSatisfy { arm in
                guard let sample = gateway.telemetry(forArm: arm),
                      sample.sequence > modeSequences[arm]!,
                      sample.effectiveSampleAgeMilliseconds <= 250,
                      sample.statuses.count == 7,
                      sample.statuses.allSatisfy({ $0.intValue == 2 }) else { return false }
                let modes = gateway.modes(forArm: arm)
                return modes.count == 7 && modes.allSatisfy({ $0.intValue == 2 })
            }
        }
        try await moveRoutes(routes, detail: command == "relax" ? "Lowering both arms toward hanging" : "Bringing both arms into the camera view")
        if command == "relax" {
            try await deactivateAtHanging()
            return ["status": "completed", "detail": "Both arms reached hanging zero gently and are inactive."]
        }
        if let rendition = activeRendition, supervisedRoute {
            guard rendition.isValid else { throw ROBArmRoutineError.blocked("The taught rendition is invalid.") }
            try await moveRoutes(Dictionary(uniqueKeysWithValues: arms.map { ($0, rendition.waypoints) }),
                                 detail: "Replaying taught gesture under controller supervision")
            return ["status": "completed", "measured": true, "clip_id": rendition.id,
                "detail": "Both arms completed the taught gesture and reached the front pose under controller supervision. Grippers were unchanged; camera clearance was not certified."]
        }
        // The gateway owns calibration acceptance for this authenticated session.
        // Diagnostics may already have calibrated the jaws; a private routine
        // cache must not cause another full-travel calibration around an object.
        try verifyFrontBeforeGripperMotion()
        setStatus("Checking current gripper calibration")
        for arm in arms {
            try await accepted([try send(gateway.queryGripperState(forArm: arm))])
        }
        let uncalibrated = arms.filter {
            gateway.gripperSnapshot(forArm: $0)["calibrationState"] as? String != "command_accepted_unverified"
        }
        if !uncalibrated.isEmpty {
            _ = try await inspect(target: target, calibration: true)
            // Serial acknowledgements: the vendor globally serializes gripper commands.
            for arm in uncalibrated {
                moving = true
                try verifyFrontBeforeGripperMotion()
                setStatus("Calibrating \(arm == "left" ? "right" : "left") gripper in front")
                try await accepted([try send(gateway.calibrateGripper(forArm: arm))])
                let settledAt = ProcessInfo.processInfo.systemUptime + 2
                try await wait(seconds: 3) { ProcessInfo.processInfo.systemUptime >= settledAt }
                moving = false
            }
        }
        // Opening is preparation, not a side effect of first-time calibration.
        // The complete controller approval covers release of both jaws, including
        // support of any held object. Live camera/hand and motor checks stay on;
        // an MLX jaw label is not required to dispatch this supervised opening.
        for arm in arms {
            moving = true
            try verifyFrontBeforeGripperMotion()
            setStatus("Opening \(arm == "left" ? "right" : "left") gripper for the object")
            try await accepted([try send(gateway.controlGripper(forArm: arm, action: "release", force: 10))])
        }
        let openedAt = ProcessInfo.processInfo.systemUptime + 1.5
        try await wait(seconds: 3) { ProcessInfo.processInfo.systemUptime >= openedAt }
        moving = false
        if command == "prepare" || command == "startup" {
            return ["status": "completed", "gripper_calibration": "accepted_unverified",
                    "gripper_release": "accepted_unverified", "jaw_opening_verified": false,
                    "detail": "Both arms are measured in front and both gripper release commands were accepted. The jaws were commanded open for the object; jaw opening and force are not measured."]
        }
        let ready = try await inspect(target: target)
        guard ready.armsInFront, ready.leftJawOpen, ready.rightJawOpen else {
            throw ROBArmRoutineError.blocked("Gripper commands were accepted, but the cameras cannot verify both jaws opened.")
        }
        if let rendition = activeRendition {
            guard rendition.isValid, ready.permitsCalibration else {
                throw ROBArmRoutineError.blocked("Rendition requires both empty grippers and a visible clear corridor.")
            }
            try await moveRoutes(Dictionary(uniqueKeysWithValues: arms.map { ($0, rendition.waypoints) }),
                                 detail: "Replaying bounded front-arm rendition")
            return ["status": "completed", "measured": true, "clip_id": rendition.id,
                "detail": "Both arms reached the final front pose of the bounded rendition. This reproduces the order of relative lifts within the taught corridor, not the demonstrator's full joint pose or speed."]
        }
        if command == "grab" || command == "hold" {
            guard let arm = ready.graspArm else {
                return ["status": "ready_for_object", "detail": "Arms are in front and both grippers are open. The requested object is not clearly between one gripper's jaws. Reaching outside this pose needs camera-to-arm calibration.", "gripper_calibration": "accepted_unverified"]
            }
            moving = true
            try verifyFrontBeforeGripperMotion()
            try await accepted([try send(gateway.controlGripper(forArm: arm, action: "hold", force: 10))])
            let closedAt = ProcessInfo.processInfo.systemUptime + 1.5
            try await wait(seconds: 3) { ProcessInfo.processInfo.systemUptime >= closedAt }
            moving = false
            let after = try await inspect(target: target)
            let retained = arm == "left" ? after.rightJawClosedOnObject : after.leftJawClosedOnObject
            return ["status": "grip_attempted", "detail": retained
                ? "The close command was accepted and the camera sees the object between closed jaws. Grip force and a secure grasp are unverified."
                : "The close command was accepted, but the camera could not verify that the object was retained. The arms are holding position.",
                "visual_object_retained": retained, "physical_arm": arm == "left" ? "right" : "left"]
        }
        return ["status": "completed", "detail": "Both arms are measured in front; both gripper calibrations were accepted and both open jaws were observed. Absolute seven-joint camera calibration is unchanged.", "gripper_calibration": "accepted_unverified"]
    }

    @MainActor private func moveRoutes(_ initialRoutes: [String: [Int]], detail: String) async throws {
        var routes = initialRoutes
        while routes.values.contains(where: { !$0.isEmpty }) {
            moving = true
            try check()
            var targets: [String: [Double]] = [:], ids: [UInt64] = []
            let duration = try routes.compactMap { arm, route -> Double? in
                guard let index = route.first, let target = ROBArmRoutinePlan.target(index: index, physicalLeft: arm == "right") else { return nil }
                return ROBArmRoutinePlan.duration(from: try measured(arm), to: target)
            }.max() ?? ROBArmRoutinePlan.segmentSeconds
            moving = true
            for arm in arms where routes[arm]?.isEmpty == false {
                let index = routes[arm]!.removeFirst()
                guard let q = ROBArmRoutinePlan.target(index: index, physicalLeft: arm == "right") else { throw ROBArmRoutineError.blocked("Invalid route waypoint.") }
                targets[arm] = q
                let id = try send(gateway.sendRoutineWaypoint(arm: arm, index: index, duration: duration, expectedSessionGeneration: generation))
                ids.append(id)
            }
            setStatus(detail)
            let sentAt = ProcessInfo.processInfo.systemUptime
            try await accepted(ids)
            leased.formUnion(targets.keys)
            lastRenewal = ProcessInfo.processInfo.systemUptime
            var settlers = Dictionary(uniqueKeysWithValues: targets.keys.map { ($0, ROBArmRoutineSettler()) })
            var arrived: Set<String> = []
            try await wait(seconds: duration + 3) {
                for (arm, q) in targets {
                    guard let sample = gateway.telemetry(forArm: arm) else { continue }
                    if settlers[arm]!.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                        target: q, now: ProcessInfo.processInfo.systemUptime) { arrived.insert(arm) }
                    else { arrived.remove(arm) }
                }
                return arrived.count == targets.count && ProcessInfo.processInfo.systemUptime - sentAt >= duration
            }
            moving = false
        }
    }

    @MainActor private func deactivateAtHanging() async throws {
        var settlers = Dictionary(uniqueKeysWithValues: arms.map { ($0, ROBArmRoutineSettler()) })
        try await wait(seconds: 2) {
            arms.allSatisfy { arm in
                guard let sample = gateway.telemetry(forArm: arm), sample.effectiveSampleAgeMilliseconds <= 250 else { return false }
                return settlers[arm]!.observe(sequence: sample.sequence,
                    positions: sample.positionsRadians.map(\.doubleValue), target: Array(repeating: 0, count: 7),
                    now: ProcessInfo.processInfo.systemUptime)
            }
        }
        for arm in arms {
            guard ROBArmRoutinePlan.near(try measured(arm), Array(repeating: 0, count: 7)) else {
                throw ROBArmRoutineError.blocked("Hanging arrival is not verified; torque remains on.")
            }
        }
        moving = false; leased.removeAll()
        try await accepted(arms.map { try send(gateway.deactivateArm($0)) })
        try await wait(seconds: 2) {
            arms.allSatisfy { arm in
                let modes = gateway.modes(forArm: arm).map(\.intValue)
                return modes.count == 7 && modes.allSatisfy { $0 == 0 }
            }
        }
    }

    private func monitor() {
        precondition(Thread.isMainThread)
        guard isRunning, failure == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now > deadline { abort("Arm routine exceeded its 90-second deadline."); return }
        if generation > 0 {
            guard gateway.isReady(), (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation else {
                referencedGeneration = 0
                abort("The gateway session changed; the arm routine was stopped."); return
            }
            for arm in arms {
                if (try? measured(arm)) == nil {
                    referencedGeneration = 0
                    abort("Motor feedback went stale; an arm hold was requested."); return
                }
                if moving {
                    let modes = gateway.modes(forArm: arm).map(\.intValue)
                    let statuses = gateway.telemetry(forArm: arm)?.statuses.map(\.intValue) ?? []
                    guard modes.count == 7, modes.allSatisfy({ $0 == 2 }),
                          statuses.count == 7, statuses.allSatisfy({ $0 == 2 }) else {
                        referencedGeneration = 0
                        abort("An arm left position mode or reported a motor fault."); return
                    }
                }
            }
        }
        if superviseCamera && (!vision.fresh || viewIsStationary?() != true) { abort(cameraFailureDetail); return }
        if moving && !vision.handsClear { abort("Person or hand clearance was lost; an arm hold was requested."); return }
        if !leased.isEmpty, now - lastRenewal >= 0.4 {
            if renewalSentAt.values.contains(where: { now - $0 > 1 }) { abort("An arm lease acknowledgement timed out."); return }
            lastRenewal = now
            for arm in leased {
                let id = gateway.renewLease(forArm: arm, leaseMilliseconds: 1500)
                if id == 0 { abort("The gateway refused lease renewal."); return }
                renewalIDs.insert(id)
                renewalSentAt[id] = now
            }
        }
    }

    private func finish(_ result: NSDictionary, hold: Bool) {
        precondition(Thread.isMainThread)
        timer?.invalidate(); timer = nil
        // End trajectory leases with a measured hold, including a successful
        // front pose. Relax has already verified torque off and needs no hold.
        for arm in arms where hold || leased.contains(arm) { _ = gateway.priorityHold(forArm: arm) }
        leased.removeAll(); renewalIDs.removeAll(); renewalSentAt.removeAll(); expected.removeAll(); acknowledgements.removeAll()
        vision.setActive(false); cameraDemand?(false)
        if let owner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        }
        owner = nil; activeRendition = nil; isRunning = false; task = nil; moving = false; superviseCamera = false; supervisedRoute = false
        setStatus(result["detail"] as? String ?? "Arm routine ended")
        let callback = completion; completion = nil; callback?(result)
    }
}
