import Foundation

/// Speech timing is independent of the 250 ms motion admission limit. Brief
/// telemetry gaps do not chatter; a sustained fault speaks once per episode.
struct ROBArmFeedbackAlertPolicy {
    struct Sample {
        let controllerAge: Double
        let jointAges: [Double]
        let gripperAge: Double

        var issue: String? {
            func stale(_ age: Double) -> Bool { !age.isFinite || age < 0 || age > 250 }
            if stale(controllerAge) { return "controller telemetry is missing" }
            guard jointAges.count == 7 else { return "joint telemetry is incomplete" }
            let missing = jointAges.enumerated().filter { stale($0.element) }.map { String($0.offset + 1) }
            var parts: [String] = []
            if !missing.isEmpty { parts.append("joint" + (missing.count == 1 ? " " : "s ") + missing.joined(separator: ", ")) }
            if stale(gripperAge) { parts.append("the gripper") }
            return parts.isEmpty ? nil : parts.joined(separator: " and ") + " not responding"
        }
    }
    struct Announcement {
        let text: String
        let isFault: Bool
    }
    private struct Episode {
        var badSince: Double?
        var recoveredSince: Double?
        var announced = false
    }
    private var episodes: [String: Episode] = [:]
    private var wasConnected = false
    private var readySince: Double?
    private var gatewayEpisode = Episode()

    mutating func update(now: Double, ready: Bool, intentionalDisconnect: Bool = false,
                         samples: [String: Sample]) -> [Announcement] {
        guard now.isFinite else { return [] }
        if intentionalDisconnect { self = Self(); return [] }
        guard ready else {
            readySince = nil
            gatewayEpisode.recoveredSince = nil
            guard wasConnected else { return [] }
            if gatewayEpisode.badSince == nil { gatewayEpisode.badSince = now }
            if !gatewayEpisode.announced, now - gatewayEpisode.badSince! >= 1 {
                gatewayEpisode.announced = true
                return [.init(text: "Arm gateway connection lost. Both arm positions are unverified.", isFault: true)]
            }
            return []
        }
        wasConnected = true
        gatewayEpisode.badSince = nil
        if readySince == nil { readySince = now }
        // Allow the initial ready packet to be followed by actual motor samples.
        guard now - readySince! >= 3 else { return [] }
        var result: [Announcement] = []
        if gatewayEpisode.announced {
            let healthy = ["left", "right"].allSatisfy { samples[$0]?.issue == nil && samples[$0] != nil }
            if healthy {
                if gatewayEpisode.recoveredSince == nil { gatewayEpisode.recoveredSince = now }
                if now - gatewayEpisode.recoveredSince! >= 1 {
                    gatewayEpisode = Episode()
                    result.append(.init(text: "Arm gateway feedback restored. Check both arms before moving.", isFault: false))
                }
            } else { gatewayEpisode.recoveredSince = nil }
        }
        for gatewayArm in ["left", "right"] {
            // Amber's legacy keys are opposite the robot's physical sides.
            let physical = gatewayArm == "left" ? "Right" : "Left"
            var episode = episodes[gatewayArm] ?? Episode()
            let issue = samples[gatewayArm]?.issue ?? (samples[gatewayArm] == nil ? "controller telemetry is missing" : nil)
            if let issue {
                episode.recoveredSince = nil
                if episode.badSince == nil { episode.badSince = now }
                if !episode.announced, now - episode.badSince! >= 1 {
                    episode.announced = true
                    result.append(.init(text: "\(physical) arm feedback lost: \(issue). Check the \(physical.lowercased()) arm before restarting it.", isFault: true))
                }
            } else {
                episode.badSince = nil
                if episode.announced {
                    if episode.recoveredSince == nil { episode.recoveredSince = now }
                    if now - episode.recoveredSince! >= 1 {
                        episode = Episode()
                        result.append(.init(text: "\(physical) arm feedback restored. Check the arm before moving.", isFault: false))
                    }
                }
            }
            episodes[gatewayArm] = episode
        }
        return result
    }
}

#if !ARM_FEEDBACK_ALERT_FIXTURE
/// Runs even when no routine, controller approval or diagnostics window is open.
/// It reports health only; it never resets a core, activates or moves an arm.
@objcMembers final class ROBArmFeedbackAlerts: NSObject {
    static let shared = ROBArmFeedbackAlerts()
    var announce: ((String, Bool) -> Void)?
    private var timer: Timer?
    private var policy = ROBArmFeedbackAlertPolicy()

    func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate(); timer = nil; announce = nil
        policy = ROBArmFeedbackAlertPolicy()
    }

    func testSpeech() {
        announce?("Speech test. Right arm feedback lost. This is only a voice test; no hardware fault is being reported.", false)
    }

    private func poll() {
        guard let announce else { return }
        let gateway = ROBAmberGatewayClient.shared
        let connection = gateway.connectionSnapshot()
        let state = (connection["state"] as? NSNumber)?.intValue
        let now = ProcessInfo.processInfo.systemUptime
        var samples: [String: ROBArmFeedbackAlertPolicy.Sample] = [:]
        for arm in ["left", "right"] {
            guard let sample = gateway.telemetry(forArm: arm), sample.sequence > 0 else { continue }
            let elapsed = max(0, now - sample.receivedAtUptime) * 1_000
            samples[arm] = .init(controllerAge: sample.controllerSampleAgeMilliseconds + elapsed,
                jointAges: sample.jointFeedbackAgeMilliseconds.map { $0.doubleValue + elapsed },
                gripperAge: sample.gripperFeedbackAgeMilliseconds + elapsed)
        }
        let alerts = policy.update(now: now, ready: state == ROBAmberGatewayState.ready.rawValue,
            intentionalDisconnect: state == ROBAmberGatewayState.disconnected.rawValue && connection["detail"] as? String == "Disconnected",
            samples: samples)
        // Batch simultaneous arm failures so the second alert cannot cut off the first.
        if !alerts.isEmpty { announce(alerts.map(\.text).joined(separator: " "), alerts.contains(where: \.isFault)) }
    }
}
#endif
