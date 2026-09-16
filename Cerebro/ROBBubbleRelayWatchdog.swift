import Foundation

/// OFF-only deadline on its own queue. UI stalls cannot extend a live relay lease.
/// The Maestro still needs an appropriate hardware timeout for process/power loss.
final class ROBBubbleRelayWatchdog {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var deadline: Double?
    private var cutoff: (() -> Void)?
    private var tripped = false
    var didTrip: Bool { lock.lock(); defer { lock.unlock() }; return tripped }

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.orbitusrobotics.bubbles.relay-watchdog", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func update(deadline: Double?, cutoff: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !tripped else { return }
        self.deadline = deadline; self.cutoff = cutoff
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        deadline = nil; cutoff = nil; tripped = false
    }
    func performIfUntripped(_ action: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !tripped else { return false }
        return action()
    }
    private func check() {
        lock.lock(); defer { lock.unlock() }
        guard !tripped, let deadline, ProcessInfo.processInfo.systemUptime >= deadline else { return }
        tripped = true; self.deadline = nil
        // The serial box serializes complete packets. Hold this lock through OFF
        // so fresh authorization cannot race ahead of a delayed cutoff.
        cutoff?()
    }
}
