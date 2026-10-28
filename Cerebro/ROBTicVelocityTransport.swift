import Foundation
import Darwin

/// Discovery and control must select the same utility. The optional native
/// build avoids launching the vendor's Intel-only GUI-bundled tool via Rosetta.
@objcMembers final class ROBTicCommandConfiguration: NSObject {
    static var executablePath: String {
        if let configured = UserDefaults.standard.string(forKey: "ROBTiccmdExecutablePath"), !configured.isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }
        let native = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cerebro/Tic/ticcmd").path
        return FileManager.default.isExecutableFile(atPath: native) ? native
            : "/Applications/Pololu Tic Stepper Motor Controller.app/Contents/MacOS/ticcmd"
    }
}

/// One USB owner, one current demand, and no queued motion history. The UI must
/// explicitly arm again after any fault. This class never homes or assigns a
/// synthetic Tic position; the caller selects camera or software-referenced counts.
final class ROBTicVelocityTransport {
    struct Profile {
        // Operator-observed quarter turns on2026-10-27: left-8907, right+9091,
        // both from the old count0. The midpoint+92 is diagnostic only:
        // missed steps invalidate counts as heading; never reset/home from it.
        static let observedLeftQuarterTurnCount = ROBTorsoCountCalibration.leftCount
        static let observedRightQuarterTurnCount = ROBTorsoCountCalibration.rightCount
        static let observedCenterCount = (observedLeftQuarterTurnCount+observedRightQuarterTurnCount)/2
        var pulsesPerTurn = 2*(observedRightQuarterTurnCount-observedLeftQuarterTurnCount)
        var motorDirection = -1.0 // Positive base-relative yaw is ROB's left.
        var maximumDegreesPerSecond = 8.0
        var accelerationDegreesPerSecondSquared = 8.0

        func velocityUnits(_ degrees: Double) -> Int32? {
            guard degrees.isFinite, pulsesPerTurn.isFinite, (1 ... 10_000_000).contains(pulsesPerTurn),abs(motorDirection)==1,
                  abs(degrees) <= 20 else { return nil }
            let value = degrees * pulsesPerTurn / 360 * 10_000 * motorDirection
            guard abs(value) <= 500_000_000 else { return nil }
            return Int32(value.rounded())
        }
        var accelerationUnits: Int32? {
            guard accelerationDegreesPerSecondSquared.isFinite,
                  (0.1 ... 30).contains(accelerationDegreesPerSecondSquared),
                  let scaled = velocityUnits(accelerationDegreesPerSecondSquared / 100) else { return nil }
            return max(100, abs(scaled))
        }
    }

    typealias Executor = ([String]) throws -> String
    struct PositionSample {
        let count: Int32
        let velocity: Int32
        let uncertain: Bool
        let capturedAt: TimeInterval
        let energized: Bool
        let operationState: String
    }
    private enum Demand { case arm(Profile, Bool), velocity(Double, TimeInterval, Bool), read, stop }
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
    private var controlActivity: NSObjectProtocol?
    private var lastPublishedDetail = ""
    private let execute: Executor
    var onState: ((Bool, String) -> Void)?
    var onPosition: ((PositionSample) -> Void)?
    /// Runs on the serialized USB queue immediately before an admitted nonzero
    /// velocity write. A failed/partial write still invalidates old geometry.
    var onMotionDispatch: (() -> Void)?

    init(execute: Executor? = nil) {
        self.execute = execute ?? Self.executeTic
    }

    deinit {
        if let controlActivity { ProcessInfo.processInfo.endActivity(controlActivity) }
    }

    private func beginControlActivity() {
        guard controlActivity == nil else { return }
        controlActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Maintain the torso controller watchdog and fresh motor feedback")
    }

    private func endControlActivityIfIdle() {
        guard !armed, !motorMayBeEnergized, release == nil, let activity = controlActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        controlActivity = nil
    }

    func arm(profile: Profile, energizedHold: Bool = false) { enqueue(.arm(profile, energizedHold), interrupt: true) }
    /// A zero-speed powered hold does not authorize a nonzero torso request.
    /// The coordinator retains the separate both-arm clearance/motion gate.
    func energize(profile: Profile) { arm(profile: profile, energizedHold: true) }
    func velocity(_ degreesPerSecond: Double, validUntil: TimeInterval, releaseWhenStopped: Bool = true) {
        enqueue(.velocity(degreesPerSecond, validUntil, releaseWhenStopped), interrupt: false)
    }
    func stop() { enqueue(.stop, interrupt: true) }
    /// Read-only and lower priority than every motion/Stop request.
    func readPosition() { enqueue(.read, interrupt: false) }

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
        if case .read = demand, pending != nil { lock.unlock(); return }
        // A speed update cannot replace a pending stop or explicit arm request.
        if case .velocity = demand {
            if let pending {
                switch pending {
                case .arm, .stop: lock.unlock(); return
                case .velocity, .read: break
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
        if detail != lastPublishedDetail {
            lastPublishedDetail = detail
            NSLog("Torso TIC: %@", detail)
            Self.trace(detail)
        }
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
                case .read:
                    let capturedAt = ProcessInfo.processInfo.systemUptime
                    let status = try execute(["--status", "--full"])
                    try publishPosition(status, capturedAt: capturedAt, token: token)
                    try Self.checkStatus(status, starting: !driveActive)
                    if !armed && release == nil {
                        publish(false, "Tic connected; motor \(Self.fields(status)["Energized"] == "Yes" ? "energized" : "de-energized")", token: token)
                    }
                case .stop:
                    beginControlActivity()
                    armed = false
                    // Explicit De-energize must also stop a motor previously
                    // energized in another app, or before this app launched.
                    try beginRelease(readyWhenComplete: false, detail: nil, token: token)
                case .arm(let requested, let energizedHold):
                    beginControlActivity()
                    armed = false
                    guard let signedSpeed = requested.velocityUnits(requested.maximumDegreesPerSecond), signedSpeed != 0,
                          let acceleration = requested.accelerationUnits else {
                        throw Self.error("Invalid torso motion profile")
                    }
                    let speed=abs(signedSpeed)
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
                    let preflightCapturedAt = ProcessInfo.processInfo.systemUptime
                    let status = try execute(["--status", "--full"])
                    motorMayBeEnergized = Self.fields(status)["Energized"] != "No"
                    try Self.checkStatus(status, starting: true)
                    try publishPosition(status, capturedAt: preflightCapturedAt, token: token)
                    if energizedHold, try Self.currentVelocity(status) != 0 {
                        throw Self.error("Stop the torso before requesting an energized hold")
                    }
                    guard current(token) else { continue }
                    // Replace any prior target before applying limits. Ordinary
                    // arming leaves power off; explicit Energize retains a hold.
                    _ = try execute(["--velocity", "0", "--max-speed", String(speed),
                                     "--starting-speed", "0", "--max-accel", String(acceleration),
                                     "--max-decel", String(acceleration), "--enter-safe-start"])
                    profile = requested
                    guard current(token) else { continue }
                    if energizedHold {
                        release = nil
                        motorMayBeEnergized = true
                        _ = try execute(["--velocity", "0", "--energize", "--exit-safe-start"])
                        guard current(token) else { continue }
                        let capturedAt = ProcessInfo.processInfo.systemUptime
                        let heldStatus = try execute(["--status", "--full"])
                        try Self.checkStatus(heldStatus, starting: false)
                        guard try Self.currentVelocity(heldStatus) == 0 else {
                            throw Self.error("Tic did not confirm zero velocity for the energized hold")
                        }
                        try publishPosition(heldStatus, capturedAt: capturedAt, token: token)
                        driveActive = true; armed = true
                        publish(true, "Motor energized; holding at zero speed", token: token)
                    } else {
                        try beginRelease(readyWhenComplete: true, detail: nil, token: token)
                    }
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
                        try Self.checkStatus(execute(["--status", "--full"]), starting: true)
                        guard current(token) else { continue }
                        guard ProcessInfo.processInfo.systemUptime <= validUntil else {
                            throw Self.error("Torso demand expired before energizing")
                        }
                        // ticcmd sets velocity before energize/exit-safe-start,
                        // so explicitly clear any old target before powering up.
                        motorMayBeEnergized = true
                        _ = try execute(["--velocity", "0", "--energize", "--exit-safe-start"])
                        guard current(token) else { continue }
                        try Self.checkStatus(execute(["--status", "--full"]), starting: false)
                        driveActive = true
                        publish(true, "Torso motor energized for movement", token: token)
                    }
                    guard current(token) else { continue }
                    guard ProcessInfo.processInfo.systemUptime <= validUntil else {
                        throw Self.error("Torso demand expired before movement")
                    }
                    if units != 0 {onMotionDispatch?()}
                    // One process renews the command and then returns feedback.
                    // Separate processes could put a slow
                    // velocity write in front of the next status poll.
                    let capturedAt = ProcessInfo.processInfo.systemUptime
                    let status = try execute(["--velocity", String(units), "--status", "--full"])
                    try publishPosition(status, capturedAt: capturedAt, token: token)
                    try Self.checkStatus(status, starting: false)
                }
            } catch {
                fail(error.localizedDescription, token: token)
            }
        }
    }

    private func publishPosition(_ status: String, capturedAt: TimeInterval, token: UInt64) throws {
        let fields = Self.fields(status)
        guard let count = fields["Current position"].flatMap(Int32.init),
              let uncertain = fields["Position uncertain"], ["Yes", "No"].contains(uncertain),
              let energized = fields["Energized"], ["Yes", "No"].contains(energized),
              let operationState = fields["Operation state"] else {
            throw Self.error("Tic position feedback is unavailable")
        }
        let sample = PositionSample(count: count, velocity: try Self.currentVelocity(status),
            uncertain: uncertain == "Yes", capturedAt: capturedAt,
            energized: energized == "Yes", operationState: operationState)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(token) else { return }
            self.onPosition?(sample)
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
        endControlActivityIfIdle()
    }

    /// Runs on the USB queue, with scheduled polls so a pending Stop or newer
    /// demand can interrupt settling. Never infer physical rest from host demand.
    private func beginRelease(readyWhenComplete: Bool, detail: String?, token: UInt64) throws {
        driveActive = false
        // Until the hardware confirms off, even an app with no prior ownership
        // must report a failed De-energize as unconfirmed power state.
        motorMayBeEnergized = true
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
            let capturedAt = ProcessInfo.processInfo.systemUptime
            let status = try execute(["--status", "--full"])
            try publishPosition(status, capturedAt: capturedAt, token: state.token)
            guard try Self.currentVelocity(status) == 0 else {
                // Status reads do not renew the Tic command watchdog. Keep
                // safe-start deceleration alive without restoring motion.
                _ = try execute(["--reset-command-timeout"])
                queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pollRelease(id: id) }
                return
            }
            _ = try execute(["--deenergize"])
            let offCapturedAt = ProcessInfo.processInfo.systemUptime
            let offStatus = try execute(["--status", "--full"])
            guard Self.fields(offStatus)["Energized"] == "No",
                  try Self.currentVelocity(offStatus) == 0 else {
                throw Self.error("Tic did not confirm motor power off at rest")
            }
            try publishPosition(offStatus, capturedAt: offCapturedAt, token: state.token)
            motorMayBeEnergized = false
            release = nil
            guard current(state.token) else { return }
            if state.readyWhenComplete { try Self.checkStatus(offStatus, starting: true) }
            armed = state.readyWhenComplete
            endControlActivityIfIdle()
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
        endControlActivityIfIdle()
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
        // ticcmd 1.8.3 emits the historical-error heading immediately after
        // current errors, without an empty separating line. Parse the indented
        // section only; historical errors cannot masquerade as active faults.
        let sectionLines = section[1].components(separatedBy: "\n")
        let inline = sectionLines[0].trimmingCharacters(in: .whitespaces)
        let lines = sectionLines.dropFirst()
            .prefix { $0.isEmpty || $0.hasPrefix(" ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors: [String]
        if inline == "None", lines.isEmpty {
            // Actual ticcmd emits its healthy state on the heading line.
            errors = []
        } else if inline.isEmpty, lines == ["None"] {
            errors = []
        } else {
            guard inline.isEmpty, !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("- ") }) else {
                throw error("Tic error status was truncated or malformed")
            }
            errors = lines.map { String($0.dropFirst(2)) }
        }
        let expected = starting ? Set(["Command timeout", "Safe start violation", "Intentionally de-energized"]) : Set<String>()
        guard errors.allSatisfy({ expected.contains($0) }),
              starting || (values["Operation state"] == "Normal" && values["Energized"] == "Yes") else {
            throw error("Tic fault: \(errors.isEmpty ? values["Operation state"] ?? "unknown" : errors.joined(separator: ", ")); re-arm explicitly")
        }
        // Position uncertain is not a homing requirement. The caller labels
        // count propagation as an estimate and owns its software base reference.
    }

    private static func error(_ detail: String) -> NSError {
        NSError(domain: "ROBTorso", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    /// Local bounded diagnostic trace; command arguments are not recorded.
    static func trace(_ detail: String) {
        #if DEBUG
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cerebro", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("torso-usb.log").path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size < 1_048_576 else { return }
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, detail)
        line.utf8CString.withUnsafeBytes { bytes in _ = write(fd, bytes.baseAddress, bytes.count-1) }
        #endif
    }

    private static func executeTic(_ arguments: [String]) throws -> String {
        let defaults = UserDefaults.standard
        let executable = ROBTicCommandConfiguration.executablePath
        guard let serial = defaults.string(forKey: "ROB.Hardware.LastVerifiedTicSerialNumber"),
              !serial.isEmpty, serial.count <= 64,
              serial.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw error("A verified Tic serial number is required")
        }
        return try runCommand(executable: NSString(string: executable).expandingTildeInPath,
                              arguments: ["-d", serial] + arguments, operation: arguments.first ?? "command")
    }

    /// Bound child completion directly on the USB queue, independently of
    /// asynchronous app callbacks, and drain output without blocking on a pipe.
    static func runCommand(executable: String, arguments: [String], operation: String,
                           timeout: TimeInterval = 0.4) throws -> String {
        guard timeout.isFinite, timeout > 0, timeout <= 2 else { throw error("Invalid USB command timeout") }
        let began = ProcessInfo.processInfo.systemUptime
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw error("Could not create the Tic output pipe") }
        var writePipeOpen = true
        defer { close(descriptors[0]); if writePipeOpen { close(descriptors[1]) } }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw error("Could not prepare Tic file descriptors") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw error("Could not prepare Tic process attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw error("Could not configure Tic process isolation")
        }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup($0.key+"="+$0.value) } + [nil]
        defer { for pointer in argv + environment { free(pointer) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw error("Could not allocate Tic process arguments")
        }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer {
            arguments in environment.withUnsafeMutableBufferPointer {
                posix_spawn(&pid, executable, &actions, &attributes, arguments.baseAddress!, $0.baseAddress!)
            }
        }
        close(descriptors[1]); writePipeOpen = false
        guard spawned == 0 else { throw error("Tic could not launch: \(String(cString: strerror(spawned)))") }
        let launched = ProcessInfo.processInfo.systemUptime
        var reaped = false, childStatus: Int32 = 0
        defer {
            if !reaped {
                kill(pid, SIGKILL)
                while waitpid(pid, &childStatus, 0) < 0 && errno == EINTR {}
            }
        }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { throw error("Could not read Tic output") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        func drainOutput() throws {
            while true {
                let count = read(descriptors[0], &buffer, buffer.count)
                if count > 0 {
                    guard data.count+count <= 16_384 else { throw error("Oversized Tic response") }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count < 0 && errno == EINTR { continue }
                else if count < 0 && errno != EAGAIN { throw error("Could not read Tic output") }
                else { return }
            }
        }
        while true {
            try drainOutput()
            let result = waitpid(pid, &childStatus, WNOHANG)
            if result == pid { reaped = true; try drainOutput(); break }
            if result < 0 && errno != EINTR {
                if errno == ECHILD { reaped = true }
                throw error("Could not read Tic exit status")
            }
            guard ProcessInfo.processInfo.systemUptime-began < timeout else {
                throw error("Tic USB \(operation) timed out; motion authority dropped")
            }
            var descriptor = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 5)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime-began
        trace(String(format: "%@ %.0f ms (launch %.0f ms)", operation, elapsed*1000, (launched-began)*1000))
        let text = String(data: data, encoding: .utf8) ?? ""
        guard childStatus == 0 else {
            throw error("Tic unavailable: \(text.prefix(400)). Disconnect Tic Control Center before using Cerebro.")
        }
        return text
    }
}
