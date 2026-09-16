import Foundation

struct ROBControlTiming: Sendable {
    var lastMilliseconds: Double?
    var peakMilliseconds: Double = 0
    var samples: UInt64 = 0

    mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lastMilliseconds = milliseconds
        peakMilliseconds = max(peakMilliseconds, milliseconds)
        samples += 1
    }
}

struct ROBControlInputPreview: Sendable {
    let controller: String
    let sequence: String
    let left: CGPoint
    let right: CGPoint
    let brake: Bool
    let speed: Double
    let receivedUptime: TimeInterval
    // Informational only: controller and robot wall clocks may differ.
    let senderClockAgeMilliseconds: Double?
}

struct ROBControlLatencySnapshot: Sendable {
    var mainQueue = ROBControlTiming()
    var commandHandler = ROBControlTiming()
    var serialWrite = ROBControlTiming()
    var serialWriteSucceeded: Bool?
    var input: ROBControlInputPreview?
    var receivedInputs: UInt64 = 0
}

/// Observes the control path only. No transport sends, robot commands or I/O.
/// Shared measurements are protected by a short lock; UI reads cached values.
@objc(ROBControlLatencyDiagnostics)
final class ROBControlLatencyDiagnostics: NSObject, @unchecked Sendable {
    @objc static let shared = ROBControlLatencyDiagnostics()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.orbitusrobotics.control-latency", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pendingMainProbe: TimeInterval?
    private var state = ROBControlLatencySnapshot()

    @objc func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.enqueueMainProbe() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    private func enqueueMainProbe() {
        let queuedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // At most one queued probe, including during a multi-second UI stall.
        guard pendingMainProbe == nil else { lock.unlock(); return }
        pendingMainProbe = queuedAt
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = (ProcessInfo.processInfo.systemUptime - queuedAt) * 1_000
            self.lock.lock()
            self.state.mainQueue.record(elapsed)
            self.pendingMainProbe = nil
            self.lock.unlock()
        }
    }

    @objc(recordCommandHandlerMilliseconds:)
    func recordCommandHandler(milliseconds: Double) {
        lock.lock()
        state.commandHandler.record(milliseconds)
        lock.unlock()
    }

    @objc(recordSerialWriteMilliseconds:succeeded:)
    func recordSerialWrite(milliseconds: Double, succeeded: Bool) {
        lock.lock()
        state.serialWrite.record(milliseconds)
        state.serialWriteSucceeded = succeeded
        lock.unlock()
    }

    @objc(recordController:sequence:left:right:brake:speed:sentAtMilliseconds:)
    func recordController(
        _ controller: String, sequence: String, left: CGPoint, right: CGPoint,
        brake: Bool, speed: Double, sentAtMilliseconds: Double
    ) {
        let preview = ROBControlInputPreview(
            controller: String(controller.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(80)),
            sequence: String(sequence.prefix(32)), left: left, right: right,
            brake: brake, speed: speed, receivedUptime: ProcessInfo.processInfo.systemUptime,
            senderClockAgeMilliseconds: sentAtMilliseconds > 0
                ? Date().timeIntervalSince1970 * 1_000 - sentAtMilliseconds : nil
        )
        lock.lock()
        state.input = preview
        state.receivedInputs += 1
        lock.unlock()
    }

    func snapshot() -> ROBControlLatencySnapshot {
        lock.lock()
        defer { lock.unlock() }
        var result = state
        if let pendingMainProbe {
            result.mainQueue.peakMilliseconds = max(
                result.mainQueue.peakMilliseconds,
                (ProcessInfo.processInfo.systemUptime - pendingMainProbe) * 1_000
            )
        }
        return result
    }

    @objc func resetPeaks() {
        lock.lock()
        state.mainQueue.peakMilliseconds = state.mainQueue.lastMilliseconds ?? 0
        state.commandHandler.peakMilliseconds = state.commandHandler.lastMilliseconds ?? 0
        state.serialWrite.peakMilliseconds = state.serialWrite.lastMilliseconds ?? 0
        lock.unlock()
    }
}
