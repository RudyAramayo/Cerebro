import Foundation
import Darwin

/// One USB owner, one current demand, and no queued motion history. The UI must
/// explicitly arm again after any fault. This class never homes or assigns a
/// synthetic Tic position; velocity control works with a camera-established zero.
final class ROBTicVelocityTransport {
    struct Profile {
        var pulsesPerTurn = 36_800.0 // Existing ROB gearing; validate on the robot.
        var maximumDegreesPerSecond = 8.0
        var accelerationDegreesPerSecondSquared = 8.0

        func velocityUnits(_ degrees: Double) -> Int32? {
            guard degrees.isFinite, pulsesPerTurn.isFinite, (1 ... 10_000_000).contains(pulsesPerTurn),
                  abs(degrees) <= 20 else { return nil }
            let value = degrees * pulsesPerTurn / 360 * 10_000
            guard abs(value) <= 500_000_000 else { return nil }
            return Int32(value.rounded())
        }
        var accelerationUnits: Int32? {
            guard accelerationDegreesPerSecondSquared.isFinite,
                  (0.1 ... 30).contains(accelerationDegreesPerSecondSquared),
                  let scaled = velocityUnits(accelerationDegreesPerSecondSquared / 100) else { return nil }
            return max(100, scaled)
        }
    }

    typealias Executor = ([String]) throws -> String
    private enum Demand { case arm(Profile), velocity(Double, TimeInterval, Bool), stop }
    private struct Release {
        let id = UUID()
        let token: UInt64
        let readyWhenComplete: Bool
        let detail: String?
        let deadline: TimeInterval
    }
    private let queue = DispatchQueue(label: "rob.torso.tic.usb", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Demand?
    private var draining = false
    private var generation: UInt64 = 0
    private var armed = false
    private var driveActive = false
    private var motorMayBeEnergized = false
    private var release: Release?
    private var profile = Profile()
    private var lastStatusAt = 0.0
    private let execute: Executor
    var onState: ((Bool, String) -> Void)?

    init(execute: Executor? = nil) {
        self.execute = execute ?? Self.executeTic
    }

    func arm(profile: Profile) { enqueue(.arm(profile), interrupt: true) }
    func velocity(_ degreesPerSecond: Double, validUntil: TimeInterval, releaseWhenStopped: Bool = true) {
        enqueue(.velocity(degreesPerSecond, validUntil, releaseWhenStopped), interrupt: false)
    }
    func stop() { enqueue(.stop, interrupt: true) }

    /// Application termination must not exit before the USB queue finishes
    /// stopping and releasing the driver. Completion does not use main callbacks.
    func stopAndWait(timeout: TimeInterval = 5) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        stop()
        guard timeout.isFinite, (0 ... 10).contains(timeout) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if queue.sync(execute: { !armed && release == nil && !motorMayBeEnergized }) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func enqueue(_ demand: Demand, interrupt: Bool) {
        lock.lock()
        if interrupt { generation &+= 1 }
        // A speed update cannot replace a pending stop or explicit arm request.
        if case .velocity = demand {
            if let pending {
                switch pending {
                case .arm, .stop: lock.unlock(); return
                case .velocity: break
                }
            }
        }
        pending = demand
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    private func current(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    private func publish(_ ready: Bool, _ detail: String, token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(token) else { return }
            self.onState?(ready, detail)
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let demand = pending else { draining = false; lock.unlock(); return }
            pending = nil; let token = generation
            lock.unlock()
            do {
                switch demand {
                case .stop:
                    let ownedMotor = armed || motorMayBeEnergized || release != nil
                    armed = false
                    if ownedMotor {
                        try beginRelease(readyWhenComplete: false, detail: nil, token: token)
                    } else {
                        publish(false, "Torso disarmed; no motor output requested", token: token)
                    }
                case .arm(let requested):
                    armed = false
                    guard let speed = requested.velocityUnits(requested.maximumDegreesPerSecond), speed > 0,
                          let acceleration = requested.accelerationUnits else {
                        throw Self.error("Invalid torso motion profile")
                    }
                    let settingsFile = FileManager.default.temporaryDirectory
                        .appendingPathComponent("rob-tic-profile-\(UUID()).txt")
                    defer { try? FileManager.default.removeItem(at: settingsFile) }
                    _ = try execute(["--get-settings", settingsFile.path])
                    let settings = Self.fields(try String(contentsOf: settingsFile, encoding: .utf8))
                    guard settings["product"] == "36v4", settings["control_mode"] == "serial",
                          settings["step_mode"] == "1", settings["soft_error_response"] == "decel_to_hold",
                          settings["disable_safe_start"] == "false",
                          let timeout = Int(settings["command_timeout"] ?? ""), (100 ... 1000).contains(timeout) else {
                        throw Self.error("Tic settings differ from the verified full-step, safe-start and watchdog profile")
                    }
                    let status = try execute(["--status"])
                    motorMayBeEnergized = Self.fields(status)["Energized"] != "No"
                    try Self.checkStatus(status, starting: true)
                    guard current(token) else { continue }
                    // Set a zero target before applying limits. Arming grants
                    // authority, but leaves the geared torso motor unpowered.
                    _ = try execute(["--velocity", "0", "--max-speed", String(speed),
                                     "--starting-speed", "0", "--max-accel", String(acceleration),
                                     "--max-decel", String(acceleration), "--enter-safe-start"])
                    profile = requested
                    guard current(token) else { continue }
                    try beginRelease(readyWhenComplete: true, detail: nil, token: token)
                case .velocity(let degrees, let validUntil, let releaseWhenStopped):
                    guard armed, current(token) else { continue }
                    guard ProcessInfo.processInfo.systemUptime <= validUntil,
                          let units = profile.velocityUnits(degrees), abs(degrees) <= profile.maximumDegreesPerSecond else {
                        throw Self.error("Torso demand expired or exceeded the armed speed limit")
                    }
                    if units == 0, releaseWhenStopped {
                        if release == nil, driveActive {
                            try beginRelease(readyWhenComplete: true, detail: nil, token: token)
                        }
                        continue
                    }
                    // A transient zero during reversal need not wake an idle
                    // motor, or interrupt a power release already in progress.
                    if units == 0, !driveActive { continue }
                    if units != 0, !driveActive {
                        release = nil
                        try Self.checkStatus(execute(["--status"]), starting: true)
                        guard current(token) else { continue }
                        guard ProcessInfo.processInfo.systemUptime <= validUntil else {
                            throw Self.error("Torso demand expired before energizing")
                        }
                        // ticcmd sets velocity before energize/exit-safe-start,
                        // so explicitly clear any old target before powering up.
                        motorMayBeEnergized = true
                        _ = try execute(["--velocity", "0", "--energize", "--exit-safe-start"])
                        guard current(token) else { continue }
                        try Self.checkStatus(execute(["--status"]), starting: false)
                        driveActive = true
                        lastStatusAt = ProcessInfo.processInfo.systemUptime
                        publish(true, "Torso motor energized for movement", token: token)
                    }
                    guard current(token) else { continue }
                    guard ProcessInfo.processInfo.systemUptime <= validUntil else {
                        throw Self.error("Torso demand expired before movement")
                    }
                    _ = try execute(["--velocity", String(units)])
                    if current(token), ProcessInfo.processInfo.systemUptime - lastStatusAt >= 0.25 {
                        try Self.checkStatus(execute(["--status"]), starting: false)
                        lastStatusAt = ProcessInfo.processInfo.systemUptime
                    }
                }
            } catch {
                fail(error.localizedDescription, token: token)
            }
        }
    }

    private func fail(_ detail: String, token: UInt64) {
        let needsRelease = armed || motorMayBeEnergized || release != nil
        armed = false; driveActive = false
        lock.lock()
        if token == generation { pending = nil }
        lock.unlock()
        publish(false, detail, token: token)
        if needsRelease {
            do { try beginRelease(readyWhenComplete: false, detail: detail, token: token) }
            catch { releaseFailed(error.localizedDescription, prior: detail, token: token) }
        }
    }

    /// Runs on the USB queue, with scheduled polls so a pending Stop or newer
    /// demand can interrupt settling. Never infer physical rest from host demand.
    private func beginRelease(readyWhenComplete: Bool, detail: String?, token: UInt64) throws {
        driveActive = false
        let timeout = max(3, profile.maximumDegreesPerSecond / profile.accelerationDegreesPerSecondSquared + 2)
        let state = Release(token: token, readyWhenComplete: readyWhenComplete, detail: detail,
                            deadline: ProcessInfo.processInfo.systemUptime + timeout)
        release = state
        _ = try execute(["--velocity", "0", "--enter-safe-start"])
        pollRelease(id: state.id)
    }

    private func pollRelease(id: UUID) {
        guard let state = release, state.id == id, current(state.token) else { return }
        do {
            guard ProcessInfo.processInfo.systemUptime <= state.deadline else {
                throw Self.error("Timed out waiting for the torso motor to stop")
            }
            let status = try execute(["--status"])
            guard try Self.currentVelocity(status) == 0 else {
                // Status reads do not renew the Tic command watchdog. Keep
                // safe-start deceleration alive without restoring motion.
                _ = try execute(["--reset-command-timeout"])
                queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pollRelease(id: id) }
                return
            }
            _ = try execute(["--deenergize"])
            let offStatus = try execute(["--status"])
            guard Self.fields(offStatus)["Energized"] == "No",
                  try Self.currentVelocity(offStatus) == 0 else {
                throw Self.error("Tic did not confirm motor power off at rest")
            }
            motorMayBeEnergized = false
            release = nil
            guard current(state.token) else { return }
            if state.readyWhenComplete { try Self.checkStatus(offStatus, starting: true) }
            armed = state.readyWhenComplete
            let detail = state.detail.map { "\($0); motor de-energized after stopping" }
                ?? (armed ? "Torso armed and stationary; motor de-energized" : "Torso stopped; motor de-energized")
            publish(armed, detail, token: state.token)
        } catch {
            releaseFailed(error.localizedDescription, prior: state.detail, token: state.token)
        }
    }

    private func releaseFailed(_ detail: String, prior: String?, token: UInt64) {
        armed = false; driveActive = false; release = nil
        if motorMayBeEnergized { _ = try? execute(["--enter-safe-start"]) }
        let power = motorMayBeEnergized ? "motor power-off unconfirmed" : "motor de-energized"
        publish(false, "\(prior.map { "\($0); " } ?? "")\(detail); \(power); re-arm explicitly", token: token)
    }

    static func currentVelocity(_ text: String) throws -> Int32 {
        let values = fields(text)
        guard values["Name"]?.contains("Tic 36v4") == true,
              let value = values["Current velocity"].flatMap(Int32.init) else {
            throw error("Tic current velocity is unavailable; stopped state cannot be verified")
        }
        return value
    }

    static func fields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard !line.hasPrefix(" "), let separator = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<separator])] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    static func checkStatus(_ text: String, starting: Bool) throws {
        let values = fields(text)
        guard values["Name"]?.contains("Tic 36v4") == true, values["Homing active"] == "No",
              values["Step mode"] == "Full step",
              let voltageText = values["VIN voltage"]?.split(separator: " ").first,
              let voltage = Double(voltageText), voltage.isFinite, voltage >= 8, voltage <= 50 else {
            throw error("Tic status is unavailable or inconsistent with ROB's controller")
        }
        let section = text.components(separatedBy: "Errors currently stopping the motor:")
        guard section.count == 2 else { throw error("Tic error status could not be read") }
        let lines = section[1].components(separatedBy: "\n\n")[0]
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines == ["None"] || (!lines.isEmpty && lines.allSatisfy({ $0.hasPrefix("- ") })) else {
            throw error("Tic error status was truncated or malformed")
        }
        let errors = lines == ["None"] ? [] : lines.map { String($0.dropFirst(2)) }
        let expected = starting ? Set(["Command timeout", "Safe start violation", "Intentionally de-energized"]) : Set<String>()
        guard errors.allSatisfy({ expected.contains($0) }),
              starting || (values["Operation state"] == "Normal" && values["Energized"] == "Yes") else {
            throw error("Tic fault: \(errors.isEmpty ? values["Operation state"] ?? "unknown" : errors.joined(separator: ", ")); re-arm explicitly")
        }
        // Position uncertain is deliberately not a homing requirement. Camera
        // angle is authoritative; no application target uses Tic position.
    }

    private static func error(_ detail: String) -> NSError {
        NSError(domain: "ROBTorso", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    private static func executeTic(_ arguments: [String]) throws -> String {
        let defaults = UserDefaults.standard
        let executable = defaults.string(forKey: "ROBTiccmdExecutablePath")
            ?? "/Applications/Pololu Tic Stepper Motor Controller.app/Contents/MacOS/ticcmd"
        guard let serial = defaults.string(forKey: "ROB.Hardware.LastVerifiedTicSerialNumber"),
              !serial.isEmpty, serial.count <= 64,
              serial.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw error("A verified Tic serial number is required")
        }
        let process = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: NSString(string: executable).expandingTildeInPath)
        process.arguments = ["-d", serial] + arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 0.4) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw error("Tic USB command timed out; motion authority dropped")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 16_384 else { throw error("Oversized Tic response") }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw error("Tic unavailable: \(text.prefix(400)). Disconnect Tic Control Center before using Cerebro.")
        }
        return text
    }
}
