import Foundation

/// Clock-injected duty-cycle policy. Only Cerebro owns timers and actuator state.
struct ROBBubbleSafety {
    static let relayDelay = 0.5
    // Reserve a relay-release delay and a 100 ms scheduler margin within the manual's 120 s.
    static let workBudget = 119.4
    static let cooldown = 60.0
    private(set) var armed = false
    private(set) var spin = false
    private(set) var blower = false
    private(set) var mode = "manual"
    private(set) var used = 0.0
    private(set) var detail = "Disarmed"
    private var lastTick: Double?
    private var spinReadyAt = Double.infinity
    private var cycleStartedAt = 0.0
    private var releasedAt: Double?
    private var forcedCooldownUntil = 0.0
    private var cooling = false
    private var leaseUntil = 0.0

    func ready(at now: Double) -> Bool { spin && now >= spinReadyAt }
    func remaining() -> Double { max(0, Self.workBudget - used) }
    func cooldownRemaining(at now: Double) -> Double {
        max(0, max(forcedCooldownUntil, cooling ? (releasedAt ?? now) + Self.cooldown : 0) - now)
    }
    mutating func forceCooldown(at now: Double) {
        stop(at: now)
        forcedCooldownUntil = now + Self.relayDelay + Self.cooldown
        detail = "Live outputs enabled: cooling before authorization"
    }
    mutating func heartbeat(at now: Double) {
        // A heartbeat arriving after expiry cannot revive an old authorization.
        tick(at: now)
        if armed { leaseUntil = now + 2 }
    }
    func shutdownDeadline(at now: Double) -> Double? {
        guard armed, spin || blower else { return nil }
        return min(leaseUntil, now + remaining())
    }
    mutating func authorize(at now: Double) {
        tick(at: now)
        guard cooldownRemaining(at: now) == 0 else { detail = "Cooling; authorization is locked"; return }
        armed = true; leaseUntil = now + 2; detail = "Authorized by this controller session"
    }
    mutating func stop(at now: Double) {
        account(at: now)
        setOutputs(spin: false, blower: false, at: now)
        armed = false; mode = "manual"; detail = "Stopped and disarmed"
    }
    mutating func command(_ operation: ROBBubbleOperation, at now: Double) {
        tick(at: now)
        if operation == .stop || operation == .stow { stop(at: now); return }
        guard armed, cooldownRemaining(at: now) == 0 else { detail = "Authorize before running motors"; return }
        switch operation {
        case .spinOn:
            mode = "manual"; setOutputs(spin: true, blower: blower, at: now)
        case .spinOff:
            mode = "manual"; setOutputs(spin: false, blower: false, at: now)
        case .blowerOn:
            guard ready(at: now) else { detail = "Wait 0.5 s for the spin relay before starting the blower"; return }
            mode = "manual"; setOutputs(spin: true, blower: true, at: now)
        case .blowerOff:
            mode = "manual"; setOutputs(spin: spin, blower: false, at: now)
        case .pulse, .continuous:
            guard mode != operation.rawValue else { return } // Repeated requests cannot restart a pulse.
            mode = operation.rawValue; cycleStartedAt = now
            setOutputs(spin: true, blower: false, at: now)
        default: return
        }
        detail = "\(mode.capitalized) • relay commands have 0.5 s settling time"
    }
    mutating func tick(at now: Double) {
        account(at: now)
        if let releasedAt, now >= releasedAt + Self.cooldown {
            used = 0; cooling = false; self.releasedAt = nil
        }
        if armed && now >= leaseUntil { stop(at: now); detail = "Controller heartbeat lost; motors stopped" }
        if armed && used >= Self.workBudget {
            cooling = true; stop(at: now); detail = "Working limit reached; cool for 60 seconds"
        }
        guard armed, mode == "pulse" || mode == "continuous" else { return }
        if mode == "continuous" {
            setOutputs(spin: true, blower: ready(at: now), at: now)
        } else {
            // 0.5 s spin lead, 3 s blower command, then both off for 5 s.
            let phase = (now - cycleStartedAt).truncatingRemainder(dividingBy: 8.5)
            setOutputs(spin: phase < 3.5, blower: phase >= 0.5 && phase < 3.5 && ready(at: now), at: now)
        }
    }
    private mutating func account(at now: Double) {
        defer { lastTick = now }
        guard let lastTick, now >= lastTick else { return }
        if spin || blower { used += now - lastTick }
        else if let releasedAt { used += max(0, min(now, releasedAt) - lastTick) }
    }
    private mutating func setOutputs(spin newSpin: Bool, blower newBlower: Bool, at now: Double) {
        if newSpin && !spin { spinReadyAt = now + Self.relayDelay }
        if (spin || blower) && !(newSpin || newBlower) { releasedAt = now + Self.relayDelay }
        if newSpin || newBlower { releasedAt = nil }
        spin = newSpin; blower = newBlower && newSpin
    }
}

struct ROBBubbleCalibration: Codable {
    // The storyboard labels do not match the historical IBOutlet names.
    var tiltChannel = 6 // arm_R_Shoulder_Pan
    var panChannel = 7 // arm_R_Shoulder_Tilt
    var spinChannel = 8 // Red / arm_R_Elbow_Tilt (confirmed by operator)
    var blowerChannel = 9 // Blue / arm_R_Wrist_Pan (confirmed by operator)
    var spinOn = 8000
    var spinOff = 4000
    var blowerOn = 8000
    var blowerOff = 4000
    var stowTilt = 8000
    var stowPan = 4000
    var panNeutral = 6000.0
    var tiltNeutral = 6000.0
    var panUnitsPerDegree = 22.222222
    var tiltUnitsPerDegree = -22.222222
    // Optical camera coordinates: +x right, +y down, +z forward.
    // Mount origin in that frame, meters, measured at the saved neck reference pose.
    var mountX = 0.0
    var mountY = 0.0
    var mountZ = 0.0
    var yawDegrees = 0.0
    var pitchDegrees = 0.0
    var rollDegrees = 0.0
    var neckReference: [Int] = []
    var wiringConfirmed = false
    var geometryConfirmed = false

    var valid: Bool {
        let channels = [tiltChannel, panChannel, spinChannel, blowerChannel]
        let targets = [spinOn, spinOff, blowerOn, blowerOff, stowTilt, stowPan]
        let numbers = [panNeutral, tiltNeutral, panUnitsPerDegree, tiltUnitsPerDegree,
                       mountX, mountY, mountZ, yawDegrees, pitchDegrees, rollDegrees]
        return tiltChannel == 6 && panChannel == 7 && spinChannel == 8 && blowerChannel == 9 && Set(channels).count == 4
            && channels.allSatisfy { (4 ... 17).contains($0) }
            && targets.allSatisfy { (4000 ... 8000).contains($0) }
            && spinOn != spinOff && blowerOn != blowerOff
            && spinOff == 4000 && blowerOff == 4000
            && numbers.allSatisfy(\.isFinite)
            && (4000 ... 8000).contains(panNeutral) && (4000 ... 8000).contains(tiltNeutral)
            && (1 ... 100).contains(abs(panUnitsPerDegree))
            && (1 ... 100).contains(abs(tiltUnitsPerDegree))
            && [mountX, mountY, mountZ].allSatisfy { abs($0) <= 2 }
            && [yawDegrees, pitchDegrees, rollDegrees].allSatisfy { abs($0) <= 180 }
            && (!geometryConfirmed || (neckReference.count == 3 && neckReference.allSatisfy { (1 ... 16383).contains($0) }))
    }

    func solve(u: Double, v: Double, width: Int, height: Int, depthMeters z: Double,
               fx: Double, fy: Double, cx: Double, cy: Double) -> (pan: Int, tilt: Int, description: String)? {
        guard valid, [u, v, z, fx, fy, cx, cy].allSatisfy(\.isFinite),
              (0 ... 1).contains(u), (0 ... 1).contains(v), width > 1, height > 1,
              (0.3 ... 8).contains(z), fx > 0, fy > 0,
              cx >= 0, cy >= 0, cx < Double(width), cy < Double(height) else { return nil }
        // Deproject the selected RGB pixel, translate to shoulder origin, then
        // apply the measured camera-to-mount rotation (roll, pitch, yaw).
        let x = (u * Double(width - 1) - cx) * z / fx - mountX
        let y = (v * Double(height - 1) - cy) * z / fy - mountY
        let zz = z - mountZ
        let r = rollDegrees * .pi / 180, p = pitchDegrees * .pi / 180, q = yawDegrees * .pi / 180
        let rx = cos(r) * x - sin(r) * y, ry = sin(r) * x + cos(r) * y
        let py = cos(p) * ry - sin(p) * zz, pz = sin(p) * ry + cos(p) * zz
        let mx = cos(q) * rx + sin(q) * pz, mz = -sin(q) * rx + cos(q) * pz
        guard mz > 0.1 else { return nil }
        let yaw = atan2(mx, mz) * 180 / .pi
        let elevation = atan2(-py, hypot(mx, mz)) * 180 / .pi
        let pan = panNeutral + yaw * panUnitsPerDegree
        let tilt = tiltNeutral + elevation * tiltUnitsPerDegree
        // Reject an unreachable target; clamping would claim to aim at the wrong point.
        guard (4000 ... 8000).contains(pan), (4000 ... 8000).contains(tilt) else { return nil }
        return (Int(pan.rounded()), Int(tilt.rounded()),
                String(format: "Depth %.2f m • pan %+.1f° • elevation %+.1f°", z, yaw, elevation))
    }
}
