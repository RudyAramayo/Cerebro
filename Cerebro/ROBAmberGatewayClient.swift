import Foundation
import Network
import Security

@objc public enum ROBAmberGatewayState: Int {
    case disconnected
    case connecting
    case authenticating
    case ready
    case failed
}

@objcMembers public final class ROBAmberGatewayTelemetry: NSObject {
    public let arm: String
    public let sequence: UInt64
    public let sampleAgeMilliseconds: Double
    public let receivedAtUptime: TimeInterval
    public let positionsRadians: [NSNumber]
    public let velocitiesRadiansPerSecond: [NSNumber]
    public let currents: [NSNumber]
    public let statuses: [NSNumber]

    fileprivate init(message: ROBAmberGatewayMessage) {
        arm = message.arm ?? ""
        sequence = message.sequence ?? 0
        sampleAgeMilliseconds = message.sampleAgeMilliseconds ?? .infinity
        receivedAtUptime = ProcessInfo.processInfo.systemUptime
        positionsRadians = (message.positionsRadians ?? []).map(NSNumber.init(value:))
        velocitiesRadiansPerSecond = (message.velocitiesRadiansPerSecond ?? []).map(NSNumber.init(value:))
        currents = (message.currents ?? []).map(NSNumber.init(value:))
        statuses = (message.statuses ?? []).map(NSNumber.init(value:))
        super.init()
    }

    /// Gateway age at receipt plus elapsed local monotonic time. Consumers must
    /// use this value instead of treating a frozen cached sample as perpetually
    /// fresh when telemetry delivery stops.
    public var effectiveSampleAgeMilliseconds: Double {
        guard sampleAgeMilliseconds.isFinite,
              sampleAgeMilliseconds >= 0 else { return .infinity }
        let elapsed = max(
            0,
            ProcessInfo.processInfo.systemUptime - receivedAtUptime
        ) * 1_000
        return sampleAgeMilliseconds + elapsed
    }
}

extension Notification.Name {
    static let ROBAmberGatewayStateDidChange = Notification.Name("ROBAmberGatewayStateDidChange")
    static let ROBAmberGatewayTelemetryDidUpdate = Notification.Name("ROBAmberGatewayTelemetryDidUpdate")
    static let ROBAmberGatewayCommandDidComplete = Notification.Name("ROBAmberGatewayCommandDidComplete")
    static let ROBAmberGatewayGripperDidUpdate = Notification.Name("ROBAmberGatewayGripperDidUpdate")
    static let ROBAmberDebugAuthorityDidChange = Notification.Name("ROBAmberDebugAuthorityDidChange")
}

@objcMembers public final class ROBAmberGatewayConfiguration: NSObject {
    public static let shared = ROBAmberGatewayConfiguration()
    private let service = "com.orbitusrobotics.Cerebro.amber-gateway"

    public var hasGatewayToken: Bool { secret(account: "gateway-token") != nil }
    public var hasSSHPassword: Bool { secret(account: "ssh-password") != nil }

    public func gatewayToken() -> String? { secret(account: "gateway-token") }
    public func sshPassword() -> String? { secret(account: "ssh-password") }

    public func saveGatewayToken(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 32 else { throw ConfigurationError.invalidGatewayToken }
        try save(value, account: "gateway-token")
    }

    public func saveSSHPassword(_ password: String) throws {
        guard !password.isEmpty else { throw ConfigurationError.emptySSHPassword }
        try save(password, account: "ssh-password")
    }

    public func removeCredentials() throws {
        for account in ["gateway-token", "ssh-password"] {
            let status = SecItemDelete(identity(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ConfigurationError.keychain(status)
            }
        }
    }

    private func identity(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func secret(account: String) -> String? {
        var query = identity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, account: String) throws {
        let identity = identity(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ConfigurationError.keychain(update) }
        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw ConfigurationError.keychain(add) }
    }

    public enum ConfigurationError: LocalizedError {
        case invalidGatewayToken
        case emptySSHPassword
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidGatewayToken: return "The Amber gateway token must contain at least 32 characters."
            case .emptySSHPassword: return "Enter the Amber SSH password."
            case .keychain(let status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
            }
        }
    }
}

/// A deliberately short-lived local grant for experimental embodied control.
/// It is never persisted, so relaunching Cerebro always returns to fail-closed.
@objcMembers public final class ROBAmberDebugAuthority: NSObject {
    public static let shared = ROBAmberDebugAuthority()
    private struct State {
        var expiresAt: Date?
        var allowsGemini = false
        var allowsController = false
    }

    private let stateLock = NSLock()
    private var authorityState = State()

    public var expiresAt: Date? { snapshot().expiresAt }
    public var allowsGemini: Bool { snapshot().allowsGemini }
    public var allowsController: Bool { snapshot().allowsController }
    public var isEnabled: Bool {
        let state = snapshot()
        return state.expiresAt.map { $0 > Date() } == true
    }
    public var remainingSeconds: TimeInterval {
        let state = snapshot()
        return max(0, state.expiresAt?.timeIntervalSinceNow ?? 0)
    }

    public func enable(gemini: Bool, controller: Bool, durationMinutes: Double = 15) {
        let boundedMinutes = min(max(durationMinutes, 1), 60)
        stateLock.lock()
        authorityState = State(
            expiresAt: Date(timeIntervalSinceNow: boundedMinutes * 60),
            allowsGemini: gemini,
            allowsController: controller
        )
        stateLock.unlock()
        notify()
    }

    public func revoke() {
        stateLock.lock()
        authorityState = State()
        stateLock.unlock()
        notify()
    }

    public func authorizesGemini() -> Bool {
        let state = snapshot()
        return state.allowsGemini && state.expiresAt.map { $0 > Date() } == true
    }

    public func authorizesController() -> Bool {
        let state = snapshot()
        return state.allowsController && state.expiresAt.map { $0 > Date() } == true
    }

    @nonobjc private func snapshot() -> State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return authorityState
    }

    private func notify() {
        NotificationCenter.default.post(name: .ROBAmberDebugAuthorityDidChange, object: self)
    }
}

extension Notification.Name {
    static let ROBAmberGatewayTunnelDidChange = Notification.Name("ROBAmberGatewayTunnelDidChange")
}

/// Owns the development SSH tunnel so the gateway can remain bound to Ubuntu
/// loopback. Credentials are loaded from Keychain and never placed in argv.
@objcMembers public final class ROBAmberGatewayTunnel: NSObject {
    public static let shared = ROBAmberGatewayTunnel()
    public private(set) var isRunning = false
    public private(set) var detail = "Tunnel disconnected"
    private var task: Process?

    public func connect(host: String = "amber-master.local") {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.connect(host: host) }
            return
        }
        disconnect()
        guard let token = ROBAmberGatewayConfiguration.shared.gatewayToken(),
              let password = ROBAmberGatewayConfiguration.shared.sshPassword() else {
            update(running: false, detail: "Save the Amber gateway token and SSH password first")
            return
        }
        let candidates = [
            "/opt/homebrew/bin/sshpass", "/opt/local/bin/sshpass", "/usr/local/bin/sshpass",
        ]
        guard let sshpass = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            update(running: false, detail: "sshpass is unavailable; install it from Cerebro Settings")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshpass)
        process.arguments = [
            "-e", "/usr/bin/ssh", "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "7443:127.0.0.1:7443",
            "amber@\(host)",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSHPASS"] = password
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process, process === self.task else { return }
                self.task = nil
                ROBAmberGatewayClient.shared.disconnect()
                self.update(running: false, detail: errorText?.isEmpty == false
                    ? "SSH tunnel ended: \(errorText!)" : "SSH tunnel ended")
            }
        }
        do {
            try process.run()
            task = process
            update(running: true, detail: "Opening secure tunnel to amber@\(host)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak process] in
                guard let self, let process, process === self.task, process.isRunning else { return }
                ROBAmberGatewayClient.shared.connect(token: token)
                self.update(running: true, detail: "SSH tunnel active to \(host)")
            }
        } catch {
            update(running: false, detail: "Could not start SSH tunnel: \(error.localizedDescription)")
        }
    }

    public func disconnect() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.disconnect() }
            return
        }
        ROBAmberGatewayClient.shared.disconnect()
        task?.terminationHandler = nil
        if task?.isRunning == true { task?.terminate() }
        task = nil
        update(running: false, detail: "Tunnel disconnected")
    }

    private func update(running: Bool, detail: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.update(running: running, detail: detail)
            }
            return
        }
        isRunning = running
        self.detail = detail
        NotificationCenter.default.post(name: .ROBAmberGatewayTunnelDidChange, object: self)
    }
}

private struct ROBAmberGatewayMessage: Codable {
    var type: String
    var protocolName: String? = nil
    var token: String? = nil
    var commandID: UInt64? = nil
    var arm: String? = nil
    var positionsRadians: [Double]? = nil
    var durationSeconds: Double? = nil
    var leaseMilliseconds: UInt32? = nil
    var sequence: UInt64? = nil
    var sampleAgeMilliseconds: Double? = nil
    var velocitiesRadiansPerSecond: [Double]? = nil
    var currents: [Double]? = nil
    var statuses: [Double]? = nil
    var modes: [Int]? = nil
    var activeModes: [Int]? = nil
    var capturedPositionsRadians: [Double]? = nil
    var holdDurationSeconds: Double? = nil
    var holdConfirmed: Bool? = nil
    var activeAmberResponse: Int? = nil
    var holdAmberResponse: Int? = nil
    var exclusiveControllerSession: Bool? = nil
    var action: String? = nil
    var force: Int? = nil
    var calibrationState: String? = nil
    var calibrationVerified: Bool? = nil
    var feedbackAvailable: Bool? = nil
    var commandInFlight: Bool? = nil
    var calibrationCommandAccepted: Bool? = nil
    var completionVerified: Bool? = nil
    var forceMinimum: Int? = nil
    var forceMaximum: Int? = nil
    var forceUnit: String? = nil
    var supportedActions: [String]? = nil
    var accepted: Bool? = nil
    var amberResponse: Int? = nil
    var gatewayLatencyMilliseconds: Double? = nil
    var error: String? = nil

    enum CodingKeys: String, CodingKey {
        case type, token, arm, sequence, accepted, error, currents, statuses, modes
        case action, force
        case protocolName = "protocol"
        case commandID = "command_id"
        case positionsRadians = "positions_rad"
        case durationSeconds = "duration_s"
        case leaseMilliseconds = "lease_ms"
        case sampleAgeMilliseconds = "sample_age_ms"
        case velocitiesRadiansPerSecond = "velocities_rad_s"
        case activeModes = "active_modes"
        case capturedPositionsRadians = "captured_positions_rad"
        case holdDurationSeconds = "hold_duration_s"
        case holdConfirmed = "hold_confirmed"
        case amberResponse = "amber_response"
        case activeAmberResponse = "active_amber_response"
        case holdAmberResponse = "hold_amber_response"
        case exclusiveControllerSession = "exclusive_controller_session"
        case calibrationState = "calibration_state"
        case calibrationVerified = "calibration_verified"
        case feedbackAvailable = "feedback_available"
        case commandInFlight = "command_in_flight"
        case calibrationCommandAccepted = "calibration_command_accepted"
        case completionVerified = "completion_verified"
        case forceMinimum = "force_min"
        case forceMaximum = "force_max"
        case forceUnit = "force_unit"
        case supportedActions = "supported_actions"
        case gatewayLatencyMilliseconds = "gateway_latency_ms"
    }
}

private struct ROBAmberGatewayGripperStateSnapshot {
    var calibrationState = "required"
    var calibrationVerified = false
    var feedbackAvailable = false
    var commandInFlight = false
    var lastAction: String?
    var lastForce: Int?
    var detail = "Gateway session unavailable; calibration is required"
}

private struct ROBAmberGatewayPendingGripperCommand {
    let operation: String
    let arm: String
    let action: String?
    let force: Int?
    let acknowledgementDeadline: DispatchTime
}

private struct ROBAmberGatewayGripperAcknowledgementResult {
    let accepted: Bool
    let error: String
    let userInfo: [String: Any]
}

/// Persistent client for the loopback SSH-tunneled Ubuntu Amber gateway.
/// Commands retain Amber's duration-controlled Ruckig path; telemetry never
/// participates directly in the motor-control loop.
@objcMembers public final class ROBAmberGatewayClient: NSObject {
    public static let shared = ROBAmberGatewayClient()
    public private(set) var state: ROBAmberGatewayState = .disconnected
    public private(set) var stateDetail = "Disconnected"
    public private(set) var leftTelemetry: ROBAmberGatewayTelemetry?
    public private(set) var rightTelemetry: ROBAmberGatewayTelemetry?
    public private(set) var leftModes: [NSNumber] = []
    public private(set) var rightModes: [NSNumber] = []
    public private(set) var leftTargetPositionsRadians: [NSNumber] = []
    public private(set) var rightTargetPositionsRadians: [NSNumber] = []
    public private(set) var exclusiveControllerSession = false

    private static let protocolName = "rob-amber-gateway/1"
    private static let maximumLineBytes = 16_384
    private static let heartbeatInterval: TimeInterval = 1
    private static let gripperAcknowledgementTimeout: TimeInterval = 3
    private static let gripperCalibrationRequired = "required"
    private static let gripperCalibrationAcceptedUnverified = "command_accepted_unverified"
    private static let gripperForceRange = 1 ... 300
    private static let gripperForceUnit = "vendor_intensity"
    private static let gripperActions = ["release", "hold"]
    private static let jointBoundsRadians: [ClosedRange<Double>] = [
        -2.4435 ... 2.4435,
        -2.3213 ... 2.3213,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -3.05 ... 3.05,
    ]
    private let queue = DispatchQueue(label: "com.orbitusrobotics.amber-gateway")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var heartbeatTimer: DispatchSourceTimer?
    private var token = ""
    private var nextCommandID: UInt64 = 1
    private var gripperStates: [String: ROBAmberGatewayGripperStateSnapshot] = [
        "left": ROBAmberGatewayGripperStateSnapshot(),
        "right": ROBAmberGatewayGripperStateSnapshot(),
    ]
    private var pendingGripperCommands: [UInt64: ROBAmberGatewayPendingGripperCommand] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public func connect(host: String = "127.0.0.1", port: UInt16 = 7443, token: String) {
        queue.async {
            self.disconnectOnQueue(detail: "Reconnecting")
            guard token.count >= 32, let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.transition(.failed, detail: "Gateway token or port is invalid")
                return
            }
            // Command ordering is scoped to an authenticated TCP session.
            self.nextCommandID = 1
            self.token = token
            self.transition(.connecting, detail: "Connecting to \(host):\(port)")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.transition(.authenticating, detail: "Waiting for gateway challenge")
                    self.receive(on: connection)
                case .failed(let error):
                    self.disconnectOnQueue(detail: "Gateway failed: \(error.localizedDescription)", failed: true)
                case .cancelled:
                    self.disconnectOnQueue(detail: "Gateway disconnected")
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    public func disconnect() {
        queue.async { self.disconnectOnQueue(detail: "Disconnected") }
    }

    @discardableResult
    public func sendTrajectory(arm: String, positionsRadians: [NSNumber],
                               duration: TimeInterval) -> UInt64 {
        let commandID = queue.sync { () -> UInt64 in
            guard state == .ready, ["left", "right"].contains(arm),
                  positionsRadians.count == 7,
                  zip(positionsRadians, Self.jointBoundsRadians).allSatisfy({ value, bounds in
                      value.doubleValue.isFinite && bounds.contains(value.doubleValue)
                  }),
                  nextCommandID <= UInt64(UInt32.max),
                  duration.isFinite, (0.65 ... 10).contains(duration) else { return 0 }
            let commandID = nextCommandID
            nextCommandID &+= 1
            send(ROBAmberGatewayMessage(
                type: "trajectory", commandID: commandID, arm: arm,
                positionsRadians: positionsRadians.map(\.doubleValue), durationSeconds: duration
            ))
            return commandID
        }
        return commandID
    }

    /// Sends a controller trajectory guarded by the Ubuntu gateway's own
    /// monotonic lease. This is the only trajectory API used by Vision Pro;
    /// expiry or loss of Cerebro's gateway session independently requests a
    /// measured-position hold on the Ubuntu host.
    @discardableResult
    public func sendLeasedTrajectory(
        arm: String,
        positionsRadians: [NSNumber],
        duration: TimeInterval,
        leaseMilliseconds: UInt32
    ) -> UInt64 {
        queue.sync {
            guard state == .ready, ["left", "right"].contains(arm),
                  positionsRadians.count == 7,
                  zip(positionsRadians, Self.jointBoundsRadians).allSatisfy({ value, bounds in
                      value.doubleValue.isFinite && bounds.contains(value.doubleValue)
                  }),
                  nextCommandID <= UInt64(UInt32.max),
                  duration.isFinite, (0.65 ... 10).contains(duration),
                  (700 ... 1_500).contains(leaseMilliseconds) else { return 0 }
            let commandID = nextCommandID
            nextCommandID &+= 1
            send(ROBAmberGatewayMessage(
                type: "leased_trajectory",
                commandID: commandID,
                arm: arm,
                positionsRadians: positionsRadians.map(\.doubleValue),
                durationSeconds: duration,
                leaseMilliseconds: leaseMilliseconds
            ))
            return commandID
        }
    }

    @discardableResult public func queryMode(forArm arm: String) -> UInt64 {
        sendArmCommand(type: "mode_query", arm: arm)
    }

    @discardableResult public func activateArm(_ arm: String) -> UInt64 {
        sendArmCommand(type: "activate", arm: arm)
    }

    @discardableResult public func enterPositionMode(forArm arm: String) -> UInt64 {
        sendArmCommand(type: "position_mode", arm: arm)
    }

    @discardableResult public func holdCurrentPosition(forArm arm: String) -> UInt64 {
        sendArmCommand(type: "hold_current", arm: arm)
    }

    /// Priority stop lane for a leased Vision motion. The gateway accepts this
    /// after normal motion admission has ended, but never activates an arm.
    @discardableResult public func priorityHold(forArm arm: String) -> UInt64 {
        sendArmCommand(type: "priority_hold", arm: arm)
    }

    /// Extends the gateway-owned watchdog for an already accepted leased
    /// trajectory without replaying or changing its physical target.
    @discardableResult public func renewLease(
        forArm arm: String,
        leaseMilliseconds: UInt32
    ) -> UInt64 {
        queue.sync {
            guard state == .ready, ["left", "right"].contains(arm),
                  (700 ... 1_500).contains(leaseMilliseconds),
                  nextCommandID <= UInt64(UInt32.max) else { return 0 }
            let commandID = nextCommandID
            nextCommandID &+= 1
            send(ROBAmberGatewayMessage(
                type: "renew_lease",
                commandID: commandID,
                arm: arm,
                leaseMilliseconds: leaseMilliseconds
            ))
            return commandID
        }
    }

    @discardableResult public func deactivateArm(_ arm: String) -> UInt64 {
        sendArmCommand(type: "deactivate", arm: arm)
    }

    /// Queries gateway-owned, session-local gripper state without commanding
    /// hardware. The result remains explicitly unverified because Amber does
    /// not provide gripper feedback in its arm telemetry.
    @discardableResult public func queryGripperState(forArm arm: String) -> UInt64 {
        sendGripperCommand(type: "gripper_state", arm: arm)
    }

    /// Requests vendor gripper calibration. An accepted acknowledgement means
    /// only that the Amber core accepted the command for dispatch.
    @discardableResult public func calibrateGripper(forArm arm: String) -> UInt64 {
        sendGripperCommand(type: "gripper_calibrate", arm: arm)
    }

    /// Sends the two evidence-backed Amber actions using opaque vendor
    /// intensity units. No jaw position, force, or completion is inferred.
    @discardableResult public func controlGripper(
        forArm arm: String,
        action: String,
        force: Int
    ) -> UInt64 {
        sendGripperCommand(
            type: "gripper_control", arm: arm, action: action, force: force
        )
    }

    /// Queue-consistent snapshots for motion validation and rendering. The
    /// returned telemetry objects and arrays are immutable.
    public func telemetry(forArm arm: String) -> ROBAmberGatewayTelemetry? {
        queue.sync { arm == "left" ? leftTelemetry : arm == "right" ? rightTelemetry : nil }
    }

    public func modes(forArm arm: String) -> [NSNumber] {
        queue.sync { arm == "left" ? leftModes : arm == "right" ? rightModes : [] }
    }

    public func targetPositions(forArm arm: String) -> [NSNumber] {
        queue.sync {
            arm == "left" ? leftTargetPositionsRadians
                : arm == "right" ? rightTargetPositionsRadians : []
        }
    }

    /// Queue-consistent, Objective-C-compatible state. Optional last-action
    /// fields are represented by NSNull so each dictionary is a full snapshot.
    public func gripperSnapshot(forArm arm: String) -> NSDictionary {
        queue.sync {
            guard ["left", "right"].contains(arm) else { return NSDictionary() }
            return gripperDictionary(forArm: arm) as NSDictionary
        }
    }

    /// Returns connection fields from the gateway queue as one coherent,
    /// Objective-C-compatible snapshot for diagnostics and UI presentation.
    public func connectionSnapshot() -> NSDictionary {
        queue.sync {
            [
                "state": NSNumber(value: state.rawValue),
                "detail": stateDetail,
                "exclusiveControllerSession": NSNumber(value: exclusiveControllerSession),
            ]
        }
    }

    public func isReady() -> Bool {
        queue.sync { state == .ready }
    }

    private func sendArmCommand(type: String, arm: String) -> UInt64 {
        queue.sync {
            guard state == .ready, ["left", "right"].contains(arm),
                  nextCommandID <= UInt64(UInt32.max) else { return 0 }
            let commandID = nextCommandID
            nextCommandID &+= 1
            send(ROBAmberGatewayMessage(type: type, commandID: commandID, arm: arm))
            return commandID
        }
    }

    private func handleGripperAcknowledgement(
        _ message: ROBAmberGatewayMessage,
        acknowledgement: String
    ) -> ROBAmberGatewayGripperAcknowledgementResult {
        let operation = String(acknowledgement.dropLast(4))
        let commandID = message.commandID ?? 0
        let pending = pendingGripperCommands.removeValue(forKey: commandID)
        let arm = pending?.arm ?? message.arm ?? ""
        var accepted = message.accepted == true
        var error = message.error ?? ""
        var protocolFailure = false

        if message.accepted == nil
            || pending == nil || pending?.operation != operation
            || (message.arm != nil && message.arm != pending?.arm)
            || (accepted && message.arm == nil) {
            accepted = false
            protocolFailure = true
            error = "Gripper acknowledgement did not match an outstanding command"
        }

        if accepted {
            let returnedActions = message.supportedActions ?? []
            let commonFieldsAreValid =
                [Self.gripperCalibrationRequired,
                 Self.gripperCalibrationAcceptedUnverified].contains(message.calibrationState ?? "")
                && message.calibrationVerified == false
                && message.feedbackAvailable == false
                && message.commandInFlight == false
                && message.forceMinimum == Self.gripperForceRange.lowerBound
                && message.forceMaximum == Self.gripperForceRange.upperBound
                && message.forceUnit == Self.gripperForceUnit
                && returnedActions.count == Self.gripperActions.count
                && Set(returnedActions) == Set(Self.gripperActions)
                && message.gatewayLatencyMilliseconds?.isFinite == true
                && (message.gatewayLatencyMilliseconds ?? -1) >= 0
                && (message.error?.isEmpty ?? true)
            let operationFieldsAreValid: Bool
            switch operation {
            case "gripper_state":
                operationFieldsAreValid = message.amberResponse == nil
                    && message.calibrationCommandAccepted == nil
                    && message.completionVerified == nil
                    && message.action == nil
                    && message.force == nil
            case "gripper_calibrate":
                operationFieldsAreValid = message.amberResponse == 1
                    && message.calibrationCommandAccepted == true
                    && message.completionVerified == false
                    && message.calibrationState == Self.gripperCalibrationAcceptedUnverified
                    && message.action == nil
                    && message.force == nil
            case "gripper_control":
                operationFieldsAreValid = message.amberResponse == 1
                    && message.calibrationCommandAccepted == nil
                    && message.completionVerified == false
                    && message.calibrationState == Self.gripperCalibrationAcceptedUnverified
                    && message.action == pending?.action
                    && message.force == pending?.force
            default:
                operationFieldsAreValid = false
            }
            if !commonFieldsAreValid || !operationFieldsAreValid {
                accepted = false
                protocolFailure = true
                error = "Gateway returned an invalid gripper acknowledgement"
            }
        } else if !protocolFailure {
            let rejectionFieldsAreValid = !error.isEmpty
                && (message.gatewayLatencyMilliseconds.map {
                    $0.isFinite && $0 >= 0
                } ?? true)
            if !rejectionFieldsAreValid {
                protocolFailure = true
                error = "Gateway returned an invalid gripper rejection"
            }
        }

        if protocolFailure {
            // A semantic protocol mismatch makes all session-local calibration
            // claims untrustworthy, so terminate and invalidate both arms.
            disconnectOnQueue(detail: error, failed: true)
        } else if ["left", "right"].contains(arm) {
            var snapshot = gripperStates[arm] ?? ROBAmberGatewayGripperStateSnapshot()
            snapshot.commandInFlight = false
            if accepted {
                snapshot.calibrationState = message.calibrationState
                    ?? Self.gripperCalibrationRequired
                snapshot.calibrationVerified = false
                snapshot.feedbackAvailable = false
                if operation == "gripper_control" {
                    snapshot.lastAction = message.action
                    snapshot.lastForce = message.force
                } else if snapshot.calibrationState == Self.gripperCalibrationRequired {
                    snapshot.lastAction = nil
                    snapshot.lastForce = nil
                }
                switch operation {
                case "gripper_calibrate":
                    snapshot.detail = "Calibration dispatch accepted; physical completion is unverified"
                case "gripper_control":
                    snapshot.detail = "Gripper dispatch accepted; position, force, and completion are unverified"
                default:
                    snapshot.detail = snapshot.calibrationState
                        == Self.gripperCalibrationAcceptedUnverified
                        ? "Calibration dispatch was accepted in this gateway session; completion is unverified"
                        : "Calibration is required for this gateway session"
                }
            } else {
                // Any rejected gripper operation leaves the client unable to
                // prove that its session-local calibration view still matches
                // the gateway. Require a successful state query or calibration
                // before another physical action.
                snapshot.calibrationState = Self.gripperCalibrationRequired
                snapshot.calibrationVerified = false
                snapshot.feedbackAvailable = false
                snapshot.lastAction = nil
                snapshot.lastForce = nil
                if error.isEmpty { error = "Gateway rejected the gripper command" }
                snapshot.detail = error.isEmpty
                    ? "Gateway rejected the gripper command"
                    : error
            }
            gripperStates[arm] = snapshot
            publishGripperState(forArm: arm)
        }

        let snapshot = ["left", "right"].contains(arm)
            ? gripperDictionary(forArm: arm)
            : [String: Any]()
        var userInfo = snapshot
        userInfo["snapshot"] = snapshot as NSDictionary
        userInfo.merge([
            "operation": operation,
            "commandID": commandID,
            "arm": arm,
            "accepted": accepted,
            "amberResponse": message.amberResponse ?? -1,
            "latencyMilliseconds": message.gatewayLatencyMilliseconds ?? .infinity,
            "calibrationCommandAccepted": accepted
                && message.calibrationCommandAccepted == true,
            "completionVerified": false,
            "error": error,
        ]) { _, new in new }
        if let action = message.action ?? pending?.action {
            userInfo["action"] = action
        }
        if let force = message.force ?? pending?.force {
            userInfo["force"] = force
        }
        return ROBAmberGatewayGripperAcknowledgementResult(
            accepted: accepted,
            error: error,
            userInfo: userInfo
        )
    }

    private func sendGripperCommand(
        type: String,
        arm: String,
        action: String? = nil,
        force: Int? = nil
    ) -> UInt64 {
        queue.sync {
            guard state == .ready,
                  ["left", "right"].contains(arm),
                  let current = gripperStates[arm],
                  !current.commandInFlight,
                  nextCommandID <= UInt64(UInt32.max) else { return 0 }

            // Calibration can sweep a jaw through its full travel. Serialize
            // it against every other gripper request across both arms so a
            // local calibration cannot overlap a Vision-originated command.
            let calibrationIsPending = pendingGripperCommands.values.contains {
                $0.operation == "gripper_calibrate"
            }
            guard !calibrationIsPending,
                  type != "gripper_calibrate" || pendingGripperCommands.isEmpty else {
                return 0
            }

            switch type {
            case "gripper_state", "gripper_calibrate":
                guard action == nil, force == nil else { return 0 }
            case "gripper_control":
                guard let action,
                      Self.gripperActions.contains(action),
                      let force,
                      Self.gripperForceRange.contains(force),
                      current.calibrationState == Self.gripperCalibrationAcceptedUnverified
                else { return 0 }
            default:
                return 0
            }

            let commandID = nextCommandID
            nextCommandID &+= 1
            pendingGripperCommands[commandID] = ROBAmberGatewayPendingGripperCommand(
                operation: type,
                arm: arm,
                action: action,
                force: force,
                acknowledgementDeadline: .now() + .milliseconds(
                    Int(Self.gripperAcknowledgementTimeout * 1_000)
                )
            )

            var updated = current
            updated.commandInFlight = true
            switch type {
            case "gripper_calibrate":
                // Recalibration invalidates the earlier session-local
                // acceptance before the request can become ambiguous.
                updated.calibrationState = Self.gripperCalibrationRequired
                updated.calibrationVerified = false
                updated.feedbackAvailable = false
                updated.lastAction = nil
                updated.lastForce = nil
                updated.detail = "Calibration dispatch is awaiting acknowledgement"
            case "gripper_control":
                updated.detail = "Gripper \(action ?? "action") dispatch is awaiting acknowledgement"
            default:
                updated.detail = "Gripper state query is awaiting acknowledgement"
            }
            gripperStates[arm] = updated
            publishGripperState(forArm: arm)
            send(ROBAmberGatewayMessage(
                type: type,
                commandID: commandID,
                arm: arm,
                action: action,
                force: force
            ))
            return commandID
        }
    }

    private func gripperDictionary(forArm arm: String) -> [String: Any] {
        guard let snapshot = gripperStates[arm] else { return [:] }
        var dictionary: [String: Any] = [
            "arm": arm,
            "calibrationState": snapshot.calibrationState,
            "calibrationVerified": snapshot.calibrationVerified,
            "feedbackAvailable": snapshot.feedbackAvailable,
            "commandInFlight": snapshot.commandInFlight,
            "detail": snapshot.detail,
            "forceMin": Self.gripperForceRange.lowerBound,
            "forceMax": Self.gripperForceRange.upperBound,
            "forceUnit": Self.gripperForceUnit,
            "supportedActions": Self.gripperActions,
        ]
        dictionary["lastAction"] = snapshot.lastAction.map { $0 as Any } ?? NSNull()
        dictionary["lastForce"] = snapshot.lastForce.map { NSNumber(value: $0) } ?? NSNull()
        return dictionary
    }

    private func publishGripperState(forArm arm: String) {
        var userInfo = gripperDictionary(forArm: arm)
        let snapshot = userInfo as NSDictionary
        userInfo["snapshot"] = snapshot
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ROBAmberGatewayGripperDidUpdate,
                object: self,
                userInfo: userInfo
            )
        }
    }

    private func resetGripperStates(detail: String) {
        pendingGripperCommands.removeAll()
        for arm in ["left", "right"] {
            var snapshot = ROBAmberGatewayGripperStateSnapshot()
            snapshot.detail = detail
            gripperStates[arm] = snapshot
            publishGripperState(forArm: arm)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection else { return }
            if let data { self.consume(data) }
            if let error {
                self.disconnectOnQueue(detail: "Gateway receive failed: \(error.localizedDescription)", failed: true)
            } else if isComplete {
                self.disconnectOnQueue(detail: "Gateway closed the connection")
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        if receiveBuffer.count > Self.maximumLineBytes {
            disconnectOnQueue(detail: "Gateway message exceeded protocol limit", failed: true)
            return
        }
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do { handle(try decoder.decode(ROBAmberGatewayMessage.self, from: line)) }
            catch {
                disconnectOnQueue(detail: "Invalid gateway message: \(error.localizedDescription)", failed: true)
                return
            }
        }
    }

    private func handle(_ message: ROBAmberGatewayMessage) {
        switch message.type {
        case "challenge":
            guard message.protocolName == Self.protocolName else {
                disconnectOnQueue(detail: "Unsupported Amber gateway protocol", failed: true)
                return
            }
            send(ROBAmberGatewayMessage(type: "hello", protocolName: Self.protocolName, token: token))
        case "ready":
            guard message.exclusiveControllerSession == true else {
                disconnectOnQueue(
                    detail: "Amber gateway upgrade required: exclusive controller ownership is unavailable",
                    failed: true
                )
                return
            }
            exclusiveControllerSession = true
            resetGripperStates(
                detail: "Gateway ready; calibration is required for this session"
            )
            transition(.ready, detail: "Amber gateway ready")
            startHeartbeat()
        case "telemetry":
            guard ["left", "right"].contains(message.arm ?? ""),
                  let sequence = message.sequence, sequence > 0,
                  let sampleAge = message.sampleAgeMilliseconds,
                  sampleAge.isFinite, sampleAge >= 0,
                  let positions = message.positionsRadians,
                  positions.count == 7, positions.allSatisfy(\.isFinite),
                  let velocities = message.velocitiesRadiansPerSecond,
                  velocities.count == 7, velocities.allSatisfy(\.isFinite),
                  let currents = message.currents,
                  currents.count == 7, currents.allSatisfy(\.isFinite),
                  let statuses = message.statuses,
                  statuses.count == 7, statuses.allSatisfy(\.isFinite) else { return }
            let telemetry = ROBAmberGatewayTelemetry(message: message)
            if telemetry.arm == "left" { leftTelemetry = telemetry } else { rightTelemetry = telemetry }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .ROBAmberGatewayTelemetryDidUpdate, object: self,
                    userInfo: ["telemetry": telemetry]
                )
            }
        case "heartbeat_ack": break
        case let acknowledgement where acknowledgement.hasSuffix("_ack"):
            if acknowledgement.hasPrefix("gripper_")
                || message.commandID.map({ pendingGripperCommands[$0] != nil }) == true {
                let result = handleGripperAcknowledgement(
                    message,
                    acknowledgement: acknowledgement
                )
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ROBAmberGatewayCommandDidComplete,
                        object: self,
                        userInfo: result.userInfo
                    )
                }
                return
            }
            let accepted = message.accepted == true
            let hasAcceptedModes = accepted && message.modes?.count == 7
            // Invalidate first for every mode-related result. Only a complete,
            // accepted seven-mode acknowledgement below may re-establish a
            // verified cache; partial transitions and malformed successes
            // therefore remain fail-closed.
            if [
                "mode_query_ack", "activate_ack", "position_mode_ack",
                "hold_current_ack", "priority_hold_ack", "deactivate_ack",
            ].contains(acknowledgement) {
                if message.arm == "left" {
                    leftModes = []
                    if acknowledgement != "mode_query_ack" || !hasAcceptedModes {
                        leftTargetPositionsRadians = []
                    }
                }
                if message.arm == "right" {
                    rightModes = []
                    if acknowledgement != "mode_query_ack" || !hasAcceptedModes {
                        rightTargetPositionsRadians = []
                    }
                }
            }
            if accepted, let modes = message.modes, modes.count == 7 {
                let bridged = modes.map(NSNumber.init(value:))
                if message.arm == "left" { leftModes = bridged }
                if message.arm == "right" { rightModes = bridged }
                if !modes.allSatisfy({ $0 == 2 }) {
                    if message.arm == "left" { leftTargetPositionsRadians = [] }
                    if message.arm == "right" { rightTargetPositionsRadians = [] }
                }
            }
            if accepted,
               ["trajectory_ack", "leased_trajectory_ack"].contains(acknowledgement),
               let positions = message.positionsRadians, positions.count == 7 {
                let bridged = positions.map(NSNumber.init(value:))
                if message.arm == "left" { leftTargetPositionsRadians = bridged }
                if message.arm == "right" { rightTargetPositionsRadians = bridged }
            }
            if accepted,
               let captured = message.capturedPositionsRadians, captured.count == 7,
               (["position_mode_ack", "hold_current_ack"].contains(acknowledgement)
                || (acknowledgement == "priority_hold_ack"
                    && message.holdConfirmed == true)) {
                let bridged = captured.map(NSNumber.init(value:))
                if message.arm == "left" { leftTargetPositionsRadians = bridged }
                if message.arm == "right" { rightTargetPositionsRadians = bridged }
            }
            let userInfo: [String: Any] = [
                "operation": String(acknowledgement.dropLast(4)),
                "commandID": message.commandID ?? 0,
                "arm": message.arm ?? "",
                "accepted": accepted,
                "amberResponse": message.amberResponse ?? -1,
                "activeAmberResponse": message.activeAmberResponse ?? -1,
                "holdAmberResponse": message.holdAmberResponse ?? -1,
                "latencyMilliseconds": message.gatewayLatencyMilliseconds ?? .infinity,
                "modes": message.modes ?? [],
                "activeModes": message.activeModes ?? [],
                "capturedPositionsRadians": message.capturedPositionsRadians ?? [],
                "holdDurationSeconds": message.holdDurationSeconds ?? 0,
                "holdConfirmed": message.holdConfirmed ?? false,
                "positionsRadians": message.positionsRadians ?? [],
                "durationSeconds": message.durationSeconds ?? 0,
                "leaseMilliseconds": message.leaseMilliseconds ?? 0,
                "error": message.error ?? "",
            ]
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .ROBAmberGatewayCommandDidComplete, object: self,
                    userInfo: userInfo
                )
            }
        case "heartbeat_expired", "error":
            disconnectOnQueue(detail: message.error ?? message.type, failed: true)
        default:
            disconnectOnQueue(detail: "Unknown gateway message type", failed: true)
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func heartbeatTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let expired = pendingGripperCommands.first(where: {
            $0.value.acknowledgementDeadline.uptimeNanoseconds <= now
        }) {
            disconnectOnQueue(
                detail: "Gripper acknowledgement timed out for command \(expired.key); calibration state invalidated",
                failed: true
            )
            return
        }
        send(ROBAmberGatewayMessage(type: "heartbeat"))
    }

    private func send(_ message: ROBAmberGatewayMessage) {
        guard let connection, let encoded = try? encoder.encode(message) else { return }
        var framed = encoded
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed {
            [weak self, weak connection] error in
            guard let self, let connection, connection === self.connection else { return }
            if let error {
                self.disconnectOnQueue(detail: "Gateway send failed: \(error.localizedDescription)", failed: true)
            }
        })
    }

    private func disconnectOnQueue(detail: String, failed: Bool = false) {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        token = ""
        leftTelemetry = nil
        rightTelemetry = nil
        leftModes = []
        rightModes = []
        leftTargetPositionsRadians = []
        rightTargetPositionsRadians = []
        resetGripperStates(
            detail: "Gateway session unavailable; calibration acceptance reset (\(detail))"
        )
        exclusiveControllerSession = false
        transition(failed ? .failed : .disconnected, detail: detail)
    }

    private func transition(_ state: ROBAmberGatewayState, detail: String) {
        self.state = state
        stateDetail = detail
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ROBAmberGatewayStateDidChange, object: self,
                userInfo: ["state": state.rawValue, "detail": detail]
            )
        }
    }
}
