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
    private enum Demand { case arm(Profile), velocity(Double, TimeInterval), stop }
    private let queue = DispatchQueue(label: "rob.torso.tic.usb", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Demand?
    private var draining = false
    private var generation: UInt64 = 0
    private var armed = false
    private var profile = Profile()
    private var lastStatusAt = 0.0
    private let execute: Executor
    var onState: ((Bool, String) -> Void)?

    init(execute: Executor? = nil) {
        self.execute = execute ?? Self.executeTic
    }

    func arm(profile: Profile) { enqueue(.arm(profile), interrupt: true) }
    func velocity(_ degreesPerSecond: Double, validUntil: TimeInterval) {
        enqueue(.velocity(degreesPerSecond, validUntil), interrupt: false)
    }
    func stop() { enqueue(.stop, interrupt: true) }

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
                    if armed {
                        // The preflight requires decelerate-to-hold. Safe start
                        // prevents a subsequent plain velocity packet resuming.
                        _ = try execute(["--enter-safe-start"])
                    }
                    armed = false
                    publish(false, "Torso stopped; holding torque while powered", token: token)
                case .arm(let requested):
                    if armed { _ = try execute(["--enter-safe-start"]) }
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
                    try Self.checkStatus(execute(["--status"]), starting: true)
                    guard current(token) else { continue }
                    // ticcmd applies target velocity before energizing/exiting
                    // safe start. Zero replaces any old target before arming.
                    armed = true // A partial or timed-out arm must also receive a stop.
                    _ = try execute(["--velocity", "0", "--max-speed", String(speed),
                                     "--starting-speed", "0", "--max-accel", String(acceleration),
                                     "--max-decel", String(acceleration), "--energize", "--exit-safe-start"])
                    guard current(token) else { continue }
                    try Self.checkStatus(execute(["--status"]), starting: false)
                    profile = requested; lastStatusAt = ProcessInfo.processInfo.systemUptime
                    publish(true, "Tic ready for camera-referenced velocity control", token: token)
                case .velocity(let degrees, let validUntil):
                    guard armed, current(token) else { continue }
                    guard ProcessInfo.processInfo.systemUptime <= validUntil,
                          let units = profile.velocityUnits(degrees), abs(degrees) <= profile.maximumDegreesPerSecond else {
                        throw Self.error("Torso demand expired or exceeded the armed speed limit")
                    }
                    _ = try execute(["--velocity", String(units)])
                    if current(token), ProcessInfo.processInfo.systemUptime - lastStatusAt >= 0.25 {
                        try Self.checkStatus(execute(["--status"]), starting: false)
                        lastStatusAt = ProcessInfo.processInfo.systemUptime
                    }
                }
            } catch {
                let message = error.localizedDescription
                // Best effort; the Tic's independent command watchdog remains
                // enabled even if USB is lost or this stop cannot be delivered.
                if armed { _ = try? execute(["--enter-safe-start"]) }
                armed = false
                lock.lock()
                if token == generation { pending = nil }
                lock.unlock()
                publish(false, message, token: token)
            }
        }
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
