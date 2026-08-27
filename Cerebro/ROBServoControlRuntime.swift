//
//  ROBServoControlRuntime.swift
//  Cerebro
//
//  Safety-mediated execution for operator camera positions, sequences, and
//  relative neck gestures.
//

import Foundation

@objcMembers public final class ROBServoControlRuntime: NSObject {
    public weak var serialBox: ROBSerialBox?
    public var statusDidChange: ((String) -> Void)?

    private var timer: Timer?
    private var generation = 0
    private static let maximumSafetyRetries = 8

    public var isRunning: Bool { timer != nil }

    public func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        publish("Stopped; the last accepted servo targets were retained.")
    }

    public func apply(cameraPosition: ROBServoCameraPosition) {
        guard let box = readySerialBox() else { return }
        guard box.isNeckCommandStateKnown,
              box.commandedNeckPanTarget != 0 else {
            publish("Camera position requires a known active neck. Run startup first.")
            return
        }
        stopWithoutStatus()
        let pan = cameraPosition.panTarget == 0
            ? box.commandedNeckPanTarget
            : cameraPosition.panTarget
        executePose(
            pan: pan,
            lower: cameraPosition.lowerTarget,
            upper: cameraPosition.upperTarget,
            label: "Camera position \(cameraPosition.name)",
            hold: 0,
            completion: { [weak self] in
                self?.publish("Camera position \(cameraPosition.name) applied.")
            }
        )
    }

    public func run(sequenceNamed sequenceName: String) {
        let phases = ROBServoControlStore.shared.sequencePhasesSnapshot()
            .filter { $0.sequenceName.caseInsensitiveCompare(sequenceName) == .orderedSame }
            .sorted { $0.phaseIndex < $1.phaseIndex }
        guard !phases.isEmpty else {
            publish("No phases exist for sequence \(sequenceName).")
            return
        }
        guard let box = readySerialBox() else { return }
        stopWithoutStatus()

        if sequenceName.caseInsensitiveCompare("startup") == .orderedSame {
            let disposition = box.startSafeNeckStartup()
            switch disposition {
            case .appliedCommand:
                publish("Startup sequence submitted through the safe three-phase executor.")
            case .heldForSafety:
                publish("Startup is already running.")
            case .rejected:
                publish(box.neckCommandSafetyStatus)
            @unknown default:
                publish("Startup returned an unknown safety disposition.")
            }
            return
        }

        let runGeneration = generation
        publish("Running \(sequenceName), \(phases.count) phase(s)…")
        run(phases: phases, index: 0, generation: runGeneration)
    }

    public func run(gesture: ROBServoRelativeGesture) {
        guard let box = readySerialBox() else { return }
        guard box.isNeckCommandStateKnown,
              box.commandedNeckPanTarget != 0,
              box.commandedLowerNeckTiltTarget != 0,
              box.commandedUpperNeckTiltTarget != 0 else {
            publish("Gesture requires a known active neck. Run startup first.")
            return
        }

        let base = Pose(
            pan: box.commandedNeckPanTarget,
            lower: box.commandedLowerNeckTiltTarget,
            upper: box.commandedUpperNeckTiltTarget
        )
        var poses: [Pose] = []
        for _ in 0 ..< gesture.repetitions {
            poses.append(offset(base, axis: gesture.servo, delta: gesture.delta))
            poses.append(offset(base, axis: gesture.servo, delta: -gesture.delta))
        }
        guard poses.allSatisfy({ $0.targetsAreInMaestroRange }) else {
            publish("Gesture \(gesture.name) would exceed the Maestro target range.")
            return
        }

        stopWithoutStatus()
        let runGeneration = generation
        publish("Playing \(gesture.name) relative to the current neck pose…")
        run(
            gesturePoses: poses,
            index: 0,
            interval: gesture.intervalSeconds,
            name: gesture.name,
            generation: runGeneration
        )
    }

    private func run(
        phases: [ROBServoSequencePhase],
        index: Int,
        generation runGeneration: Int
    ) {
        guard generation == runGeneration else { return }
        guard phases.indices.contains(index) else {
            timer = nil
            publish("Sequence \(phases.first?.sequenceName ?? "") complete.")
            return
        }
        let phase = phases[index]
        executePose(
            pan: phase.panTarget,
            lower: phase.lowerTarget,
            upper: phase.upperTarget,
            label: "\(phase.sequenceName) phase \(phase.phaseIndex)",
            hold: phase.holdSeconds,
            generation: runGeneration,
            completion: { [weak self] in
                self?.run(phases: phases, index: index + 1, generation: runGeneration)
            }
        )
    }

    private func run(
        gesturePoses: [Pose],
        index: Int,
        interval: TimeInterval,
        name: String,
        generation runGeneration: Int
    ) {
        guard generation == runGeneration else { return }
        guard gesturePoses.indices.contains(index) else {
            timer = nil
            publish("Gesture \(name) complete at its final -delta extreme.")
            return
        }
        let pose = gesturePoses[index]
        executePose(
            pan: pose.pan,
            lower: pose.lower,
            upper: pose.upper,
            label: "Gesture \(name)",
            hold: interval,
            generation: runGeneration,
            completion: { [weak self] in
                self?.run(
                    gesturePoses: gesturePoses,
                    index: index + 1,
                    interval: interval,
                    name: name,
                    generation: runGeneration
                )
            }
        )
    }

    private func executePose(
        pan: Int,
        lower: Int,
        upper: Int,
        label: String,
        hold: TimeInterval,
        generation runGeneration: Int? = nil,
        safetyRetryCount: Int = 0,
        completion: @escaping () -> Void
    ) {
        let expectedGeneration = runGeneration ?? generation
        guard generation == expectedGeneration, let box = readySerialBox() else { return }
        let disposition = box.requestOperatorNeckPosePanTarget(
            pan,
            lowerTarget: lower,
            upperTarget: upper
        )
        switch disposition {
        case .rejected:
            timer = nil
            publish("\(label) rejected: \(box.neckCommandSafetyStatus)")
        case .heldForSafety:
            guard safetyRetryCount < Self.maximumSafetyRetries else {
                timer = nil
                publish("\(label) stopped after repeated safety holds: \(box.neckCommandSafetyStatus)")
                return
            }
            publish("\(label) is waiting for the safety window to settle…")
            schedule(afterReadyTimeFrom: box, minimumDelay: 0.1) { [weak self] in
                self?.executePose(
                    pan: pan, lower: lower, upper: upper, label: label,
                    hold: hold, generation: expectedGeneration,
                    safetyRetryCount: safetyRetryCount + 1,
                    completion: completion
                )
            }
        case .appliedCommand:
            guard box.commandedNeckPanTarget == pan,
                  box.commandedLowerNeckTiltTarget == lower,
                  box.commandedUpperNeckTiltTarget == upper else {
                timer = nil
                publish("\(label) was limited by the active neck safety window: \(box.neckCommandSafetyStatus)")
                return
            }
            publish("\(label) accepted; waiting for conservative servo timing…")
            schedule(afterReadyTimeFrom: box, minimumDelay: max(0.05, hold)) {
                completion()
            }
        @unknown default:
            timer = nil
            publish("\(label) returned an unknown safety disposition.")
        }
    }

    private func schedule(
        afterReadyTimeFrom box: ROBSerialBox,
        minimumDelay: TimeInterval,
        action: @escaping () -> Void
    ) {
        timer?.invalidate()
        let now = ProcessInfo.processInfo.systemUptime
        let safetyDelay = max(0, box.neckCommandReadyAtUptime - now)
        let retryTimer = Timer(
            timeInterval: safetyDelay + minimumDelay,
            repeats: false
        ) { [weak self] _ in
            self?.timer = nil
            action()
        }
        timer = retryTimer
        // Button/table mouse tracking switches the main run loop out of its
        // default mode. Common mode keeps the one-press sequence advancing
        // while the Servo Control window remains interactive.
        RunLoop.main.add(retryTimer, forMode: .common)
    }

    private func readySerialBox() -> ROBSerialBox? {
        guard Thread.isMainThread else {
            publish("Servo Control can issue commands only on the main thread.")
            return nil
        }
        guard let serialBox else {
            publish("Servo Control is not attached to ROB's serial service.")
            return nil
        }
        return serialBox
    }

    private func stopWithoutStatus() {
        generation += 1
        timer?.invalidate()
        timer = nil
    }

    private func publish(_ status: String) {
        statusDidChange?(status)
    }

    private struct Pose {
        var pan: Int
        var lower: Int
        var upper: Int

        var targetsAreInMaestroRange: Bool {
            (1 ... 16_383).contains(pan)
                && (1 ... 16_383).contains(lower)
                && (1 ... 16_383).contains(upper)
        }
    }

    private func offset(_ pose: Pose, axis: String, delta: Int) -> Pose {
        var result = pose
        switch axis.lowercased() {
        case "pan": result.pan += delta
        case "lower": result.lower += delta
        default: result.upper += delta
        }
        return result
    }
}
