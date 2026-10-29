import Foundation

/// Operator-observed calibration, not mechanical end stops or an encoder.
/// ROB-left is positive yaw and decreasing Tic counts. The slipring permits
/// full turns; the temporary debugging cables are handled separately below.
struct ROBTorsoCountCalibration {
    static let leftCount = -8_907.0
    static let rightCount = 9_091.0
    static let nominalCenter = 92.0
    static let countsPerTurn = 35_996.0
    var centerCount = nominalCenter
    func heading(count: Double) -> Double { (centerCount-count) * 360 / Self.countsPerTurn }
    func count(heading: Double) -> Double { centerCount-heading * Self.countsPerTurn / 360 }
    mutating func align(count: Double, observedHeading: Double) {
        guard count.isFinite, observedHeading.isFinite else { return }
        centerCount = count + observedHeading * Self.countsPerTurn / 360
    }
}

/// Angles come from the caller's selected observation source. Raw Tic counts
/// cannot establish physical base alignment. No hardware/UI dependency here.
struct ROBTorsoMotionPolicy {
    enum Mode { case hold, velocity, heading }
    struct Observation {
        let heading: Double
        let capturedAt: TimeInterval
        let uncertainty: Double
        let stream: String
        let sequence: UInt64
    }

    var maximumSpeed = 8.0
    var acceleration = 8.0
    var maximumControlInterval = 0.25
    // Operator-confirmed TIC ceiling; output angles use observed table counts,
    // without applying an unverified gearbox ratio a second time.
    static let maximumPulseRate = 3_000.0
    static let speedRange = 1.0...(maximumPulseRate * 360 / ROBTorsoCountCalibration.countsPerTurn)
    var debugCableMode = false
    private(set) var cableReferenceHeading: Double?
    private(set) var cableTrackingInterrupted = false
    var cableTravelDegrees: Double? {
        guard let reference = cableReferenceHeading, let current = unwrappedHeading else { return nil }
        return current-reference
    }
    let maximumObservationAge = 0.75
    private(set) var observation: Observation?
    private(set) var unwrappedHeading: Double?
    private(set) var targetHeading: Double?
    private(set) var velocity = 0.0
    private(set) var armed = false
    private(set) var mode = Mode.hold
    private(set) var status = "Waiting for a camera-confirmed torso angle"
    private var rate = 0.0
    private var previousTick: TimeInterval?
    private var stallStart: (time: TimeInterval, heading: Double, direction: Double, expected: Double)?

    static func wrap(_ angle: Double) -> Double {
        guard angle.isFinite else { return .nan }
        let value = (angle + 180).truncatingRemainder(dividingBy: 360)
        return (value < 0 ? value + 360 : value) - 180
    }

    func hasFreshObservation(at now: TimeInterval) -> Bool {
        guard let observation, now.isFinite else { return false }
        return (0 ... maximumObservationAge).contains(now - observation.capturedAt)
    }

    @discardableResult mutating func observe(_ value: Observation, now: TimeInterval) -> Bool {
        guard value.heading.isFinite, value.uncertainty.isFinite,
              (0 ... 2).contains(value.uncertainty), value.capturedAt.isFinite,
              (0 ... maximumObservationAge).contains(now - value.capturedAt),
              !value.stream.isEmpty, value.sequence > 0 else {
            invalidate("Camera angle is stale, ambiguous, or invalid")
            observation = nil
            return false
        }
        if let previous = observation, previous.stream == value.stream {
            guard value.sequence > previous.sequence, value.capturedAt > previous.capturedAt else {
                return false // A replay must never refresh the observation lease.
            }
        }
        let heading = Self.wrap(value.heading)
        if let previous = observation, let oldHeading = unwrappedHeading {
            let delta = Self.wrap(heading - previous.heading)
            let gap = value.capturedAt - previous.capturedAt
            let changedFrame = value.stream != previous.stream || gap > maximumObservationAge
            let unexpected = abs(delta) > max(8, maximumSpeed * max(0, gap) + 4)
            if changedFrame || (armed && unexpected) {
                invalidate(changedFrame ? "Camera reference changed; re-arm from the new estimate"
                           : "Torso moved differently from the request; camera estimate corrected, motion stopped")
                cableReferenceHeading = nil; cableTrackingInterrupted = true
            }
            unwrappedHeading = changedFrame ? heading : oldHeading + delta
        } else {
            unwrappedHeading = heading
            if !cableTrackingInterrupted { cableReferenceHeading = heading }
        }
        observation = Observation(heading: heading, capturedAt: value.capturedAt,
                                  uncertainty: value.uncertainty, stream: value.stream, sequence: value.sequence)
        if targetHeading == nil { targetHeading = unwrappedHeading }
        if !armed && status == "Waiting for a camera-confirmed torso angle" {
            status = "Camera reference ready; no homing required"
        }
        return true
    }

    @discardableResult mutating func arm(at now: TimeInterval) -> Bool {
        guard hasFreshObservation(at: now), let heading = unwrappedHeading else {
            invalidate("A fresh camera-confirmed torso angle is required")
            return false
        }
        armed = true; mode = .hold; velocity = 0; rate = 0
        targetHeading = heading; previousTick = now; stallStart = nil
        status = "Armed — ready at observed heading"
        return true
    }

    mutating func requestRate(_ normalized: Double) {
        guard armed, normalized.isFinite else { return }
        rate = min(1, max(-1, normalized)); mode = rate == 0 ? .hold : .velocity
        status = mode == .hold ? "Slowing to a stop" : "Turning at requested speed"
    }

    mutating func requestHeading(_ heading: Double) {
        guard armed, heading.isFinite, let current = unwrappedHeading else { return }
        // With the debugging tether, choose the equivalent heading near the
        // tracked starting turn, so repeated requests unwind instead of ratchet.
        // Untethered operation retains the shortest circular route, without stops.
        let reference = debugCableMode ? cableReferenceHeading ?? current : current
        targetHeading = reference + Self.wrap(heading - Self.wrap(reference))
        mode = .heading; status = "Turning to heading with a ramped stop"
    }

    @discardableResult mutating func requestUnwind() -> Bool {
        guard armed, debugCableMode, let reference = cableReferenceHeading else { return false }
        targetHeading = reference; mode = .heading
        status = "Reversing the tracked debug turn to its starting orientation"
        return true
    }

    mutating func hold() {
        mode = .hold; rate = 0; stallStart = nil
        if armed { status = "Slowing to a stop" }
    }

    mutating func invalidate(_ reason: String) {
        armed = false; mode = .hold; velocity = 0; rate = 0
        previousTick = nil; stallStart = nil; status = reason
    }

    mutating func resetObservation() {
        if observation != nil { cableReferenceHeading = nil; cableTrackingInterrupted = true }
        invalidate("Waiting for a camera-confirmed torso angle")
        observation = nil; unwrappedHeading = nil; targetHeading = nil
    }

    mutating func loseObservation(_ reason: String) {
        invalidate(reason); observation = nil
    }

    /// Cruise until braking distance, without a long low-speed taper. Acceleration
    /// remains bounded and reversals pass through zero; stale evidence stops.
    mutating func tick(at now: TimeInterval, measuredPositionVelocity: Double? = nil,
                       positionReached: Bool = false) -> Double {
        guard armed else { return 0 }
        guard maximumSpeed.isFinite, Self.speedRange.contains(maximumSpeed),
              acceleration.isFinite, (0.1 ... 30).contains(acceleration),
              hasFreshObservation(at: now), let current = unwrappedHeading else {
            invalidate("Visual confirmation lost or motion profile invalid; torso stopped")
            return 0
        }
        let dt = now - (previousTick ?? now)
        guard maximumControlInterval.isFinite, (0.05...0.5).contains(maximumControlInterval),
              dt >= 0, dt <= maximumControlInterval else {
            invalidate("Control timing expired; torso stopped")
            return 0
        }
        previousTick = now
        if mode == .heading, let measuredPositionVelocity {
            guard measuredPositionVelocity.isFinite else {
                invalidate("TIC velocity feedback is invalid; torso stopped"); return 0
            }
            // TIC's onboard position planner owns acceleration and braking.
            // The host only supervises freshness/deadlines and exact arrival.
            velocity = measuredPositionVelocity
            if positionReached {
                velocity = 0; mode = .hold; stallStart = nil
                status = "At requested TIC target; controller stopped"
            } else { status = "TIC moving to target position" }
            return velocity
        }
        var desired = 0.0
        if mode == .velocity { desired = rate * maximumSpeed }
        if mode == .heading, let target = targetHeading {
            let error = target - current
            let tolerance = max(0.75, 2 * (observation?.uncertainty ?? 2))
            let distance = max(0, abs(error) - tolerance)
            desired = (error < 0 ? -1 : 1) * min(maximumSpeed, sqrt(2 * acceleration * distance))
            if distance == 0 && abs(velocity) < 0.05 {
                mode = .hold; status = "At requested heading within camera uncertainty"
            }
        }
        if velocity * desired < 0 { desired = 0 }
        velocity += min(acceleration * dt, max(-acceleration * dt, desired - velocity))
        velocity = min(maximumSpeed, max(-maximumSpeed, velocity))
        if abs(velocity) >= 0.1 && mode != .hold {
            let direction = velocity < 0 ? -1.0 : 1.0
            let sigma = observation?.uncertainty ?? 2
            if var start = stallStart, start.direction == direction {
                start.expected += abs(velocity) * dt
                let progress = (current - start.heading) * direction
                if progress < -max(2, 4 * sigma) {
                    invalidate("Camera observed the opposite turn direction; check motor polarity before re-arming")
                    return 0
                }
                if progress >= max(1.5, 2 * sigma) {
                    stallStart = (now, current, direction, 0)
                } else if now - start.time >= 1 && start.expected >= max(4, 4 * sigma) {
                    invalidate("Requested torso turn was not visually observed; check for obstruction or missed steps")
                    return 0
                } else { stallStart = start }
            } else { stallStart = (now, current, direction, 0) }
        } else { stallStart = nil }
        return velocity
    }
}
