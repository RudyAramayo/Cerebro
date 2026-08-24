//
//  AutoNetServer.swift
//  Cerebro
//

import Darwin
import Foundation
import Network

struct ROBControlNetworkStatusSnapshot: Sendable {
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double
    let receivedMessagesPerSecond: Double
    let sentMessagesPerSecond: Double
    let totalReceivedBytes: UInt64
    let totalSentBytes: UInt64
    let lastReceiveAge: TimeInterval?
    let lastSendAge: TimeInterval?
    let probeSupported: Bool
    let roundTripMilliseconds: Double?
    let probesSent: UInt64
    let probeReplies: UInt64
    let consecutiveProbeMisses: UInt64
    let lastProbeResponseAge: TimeInterval?
}

struct ROBControlConnectionStatusSnapshot: Sendable {
    let stableID: String
    let state: String
    let role: String
    let deviceID: String?
    let deviceName: String?
    let sessionID: String?
    let usesLegacyTransport: Bool
    let network: ROBControlNetworkStatusSnapshot
}

struct ROBControlServerStatusSnapshot: Sendable {
    let listenerState: String
    let detail: String?
    let isPaused: Bool
    let connections: [ROBControlConnectionStatusSnapshot]
}

@objc public protocol AutoNetServerDataDelegate: AnyObject {
    func didReceiveData(_ data: Data)
    /// Binary scan bytes cross this callback only after a frame-7 message has
    /// been authenticated as a lidarPublisher and fully validated.
    @objc optional func didReceiveLidarTelemetry(_ data: Data, deviceID: String)
}

/// Robot-control server. Production traffic uses a TLS 1.3 protected QUIC
/// stream advertised as `_robctl._udp`. The misleading `_roboNet._tcp`
/// service is accepted only when the explicit legacy compatibility switch is
/// enabled; there is no automatic downgrade.
@available(macOS 12.0, *)
@objcMembers public final class AutoNetServer: NSObject {
    public let port: NWEndpoint.Port
    public private(set) var listener: NWListener?
    public var paused = true
    public weak var dataDelegate: AutoNetServerDataDelegate?

    private let transportMode: AutoNetTransportMode?
    private let v2Credential: ROBControlCredential?
    private let startupError: Error?
    private var connectionsByID: [Int: AutoNetServerConnection] = [:]
    private var lastLidarSequenceByDeviceID: [UUID: UInt64] = [:]
    private var lastLidarScanUptimeByDeviceID: [UUID: TimeInterval] = [:]
    private var credentialRevocationObserver: NSObjectProtocol?
    private var listenerStatus = "stopped"
    private var listenerStatusDetail: String?
    @nonobjc private lazy var localLidarIPCServer = ROBLidarLocalIPCServer(
        stateDidChange: { ready in
            if ready {
                print("RPLidar local IPC fast path is ready")
            }
        },
        receiveScan: { [weak self] data in
            DispatchQueue.main.async {
                self?.receiveLocalLidarTelemetry(data)
            }
        }
    )
    private lazy var armControllerBridge = ROBArmControllerBridge(server: self)
    private lazy var gripperControllerBridge = ROBGripperControllerBridge(server: self)
    private lazy var administratorTerminalCoordinator = ROBAdministratorTerminalCoordinator(server: self)

    public var legacyCompatibilityIsActive: Bool {
        if case .legacy? = transportMode { return true }
        return false
    }

    public init(service: String, port: UInt16, dataDelegate: AutoNetServerDataDelegate?) {
        self.dataDelegate = dataDelegate
        self.port = NWEndpoint.Port(rawValue: port)!

        do {
            let mode = try AutoNetTransportMode(service: service)
            let credential: ROBControlCredential?
            if case .v2 = mode {
                credential = try ROBControlPairing.serverAuthenticationMaterial()
            } else {
                credential = nil
            }
            let parameters = try mode.makeServerParameters()
            let listener = try NWListener(using: parameters, on: self.port)
            let advertisedPrefix: String
            switch mode {
            case .v2: advertisedPrefix = "ROBONET-v2"
            case .legacy: advertisedPrefix = "ROBONET-LEGACY"
            }
            let advertisedName = "\(advertisedPrefix)-\(ProcessInfo.processInfo.hostName)"
            if case .v2 = mode {
                listener.service = NWListener.Service(
                    name: advertisedName,
                    type: mode.serviceType,
                    domain: nil,
                    txtRecord: try ROBControlPairing.serverBonjourTXTRecord()
                )
            } else {
                listener.service = NWListener.Service(name: advertisedName, type: mode.serviceType)
            }
            self.transportMode = mode
            self.v2Credential = credential
            self.listener = listener
            self.startupError = nil
        } catch {
            self.transportMode = nil
            self.v2Credential = nil
            self.listener = nil
            self.startupError = error
        }

        super.init()
        if let startupError {
            listenerStatus = "unavailable"
            listenerStatusDetail = startupError.localizedDescription
        }
        credentialRevocationObserver = NotificationCenter.default.addObserver(
            forName: .robControlCredentialWasRevoked,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.credentialWasRevoked(notification)
        }
    }

    deinit {
        if let credentialRevocationObserver {
            NotificationCenter.default.removeObserver(credentialRevocationObserver)
        }
    }

    public func start() throws {
        if let startupError = startupError {
            throw startupError
        }
        guard let listener = listener, transportMode != nil else {
            throw AutoNetTransportError.listenerUnavailable
        }

        paused = false
        listenerStatus = "starting"
        listenerStatusDetail = nil
        armControllerBridge.start()
        gripperControllerBridge.start()
        localLidarIPCServer.start()
        listener.stateUpdateHandler = { [weak self] state in
            self?.stateDidChange(to: state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.didAccept(nwConnection: connection)
        }
        listener.start(queue: .main)
    }

    func didReceiveData(_ data: Data) {
        dataDelegate?.didReceiveData(data)
    }

    public func sendString(_ string: NSString) {
        guard let data = string.data(using: String.Encoding.utf8.rawValue) else { return }
        _ = sendMessage(data as NSData)
    }

    /// Returns true when at least one authenticated QUIC connection accepted
    /// the message for transmission.
    @discardableResult public func sendMessage(_ data: NSData) -> Bool {
        guard !paused, !data.isEmpty else { return false }
        var didQueue = false
        for connection in connectionsByID.values
            where connection.isReady && connection.canReceiveApplicationMessage(type: .sendData) {
            if connection.send(type: .sendData, data: data as Data) {
                didQueue = true
            }
        }
        return didQueue
    }

    /// Arm traffic never crosses the plaintext compatibility transport.
    /// Target/authority replies can be bound to the exact authenticated
    /// session that originated them; telemetry broadcasts reach only current
    /// v2 operator sessions.
    @discardableResult func sendArmControlMessage(
        _ data: Data,
        to deviceID: UUID?,
        sessionID: UUID? = nil
    ) -> Bool {
        guard !paused, !data.isEmpty,
              data.count <= ROBArmControlProtocol.maximumMessageBytes else { return false }
        var didQueue = false
        for connection in connectionsByID.values
            where connection.isReady
                && connection.canReceiveApplicationMessage(type: .sendData)
                && connection.authenticatedRole == .operatorController
                && connection.authenticatedDeviceID != nil
                && connection.authenticatedSessionUUID != nil
                && (deviceID == nil || connection.authenticatedDeviceID == deviceID)
                && (sessionID == nil || connection.authenticatedSessionUUID == sessionID) {
            if connection.send(type: .sendData, data: data) {
                didQueue = true
            }
        }
        return didQueue
    }

    /// Gripper state and dispositions use the same authenticated v2 operator
    /// sessions as arm telemetry, but remain a separately versioned protocol.
    @discardableResult func sendGripperControlMessage(
        _ data: Data,
        to deviceID: UUID?,
        sessionID: UUID? = nil
    ) -> Bool {
        guard !paused, !data.isEmpty,
              data.count <= ROBGripperControlProtocol.maximumMessageBytes else { return false }
        var didQueue = false
        for connection in connectionsByID.values
            where connection.isReady
                && connection.canReceiveApplicationMessage(type: .sendData)
                && connection.authenticatedRole == .operatorController
                && connection.authenticatedDeviceID != nil
                && connection.authenticatedSessionUUID != nil
                && (deviceID == nil || connection.authenticatedDeviceID == deviceID)
                && (sessionID == nil || connection.authenticatedSessionUUID == sessionID) {
            if connection.send(type: .sendData, data: data) { didQueue = true }
        }
        return didQueue
    }

    /// PTY output is returned only to the exact authenticated controller
    /// session that most recently attached the terminal. It is never broadcast.
    @discardableResult func sendAdministratorTerminalMessage(
        _ data: Data,
        to deviceID: UUID,
        sessionID: UUID
    ) -> Bool {
        guard !paused, !data.isEmpty,
              data.count <= ROBAdministratorTerminalProtocol.maximumMessageBytes else { return false }
        for connection in connectionsByID.values
            where connection.isReady
                && connection.canReceiveApplicationMessage(type: .sendData)
                && connection.authenticatedRole == .operatorController
                && connection.authenticatedDeviceID == deviceID
                && connection.authenticatedSessionUUID == sessionID {
            return connection.send(type: .sendData, data: data)
        }
        return false
    }

    func receiveApplicationMessage(
        type: DataMessageType,
        data: Data,
        sendingConnection: AutoNetServerConnection
    ) {
        guard !paused, !data.isEmpty, sendingConnection.isReady else { return }
        switch type {
        case .sendData:
            if sendingConnection.consumeNetworkProbeMessage(data) {
                return
            }
            // lidarPublisher sendData is reserved exclusively for negotiated
            // probe capability/echo payloads. Generic commands remain an
            // authorization failure and never reach the historical parser.
            if sendingConnection.authenticatedRole == .lidarPublisher {
                sendingConnection.stop(error: AutoNetTransportError.authorizationFailed)
                return
            }
            if administratorTerminalCoordinator.claimsProtocol(data) {
                if sendingConnection.authenticatedRole == .operatorController,
                   let controllerID = sendingConnection.authenticatedDeviceID,
                   let sessionID = sendingConnection.authenticatedSessionUUID {
                    administratorTerminalCoordinator.consumeInbound(
                        data,
                        authenticatedControllerID: controllerID,
                        authenticatedSessionID: sessionID
                    )
                } else {
                    NSLog("Discarded administrator-terminal data outside an authenticated v2 operator session")
                }
                // Claimed terminal messages, including malformed ones, never
                // reach motion parsing and are never relayed to observers.
                return
            }
            if armControllerBridge.claimsArmControlProtocol(data) {
                if sendingConnection.authenticatedRole == .operatorController,
                   let controllerID = sendingConnection.authenticatedDeviceID,
                   let sessionID = sendingConnection.authenticatedSessionUUID {
                    _ = armControllerBridge.consumeInbound(
                        data,
                        authenticatedControllerID: controllerID,
                        authenticatedSessionID: sessionID
                    )
                } else {
                    NSLog("Discarded arm-control data outside an authenticated v2 operator session")
                }
                // Claimed arm messages are never relayed to other controllers
                // or passed to the historical motion parser, including on the
                // explicit legacy compatibility transport.
                return
            }
            if gripperControllerBridge.claimsGripperControlProtocol(data) {
                if sendingConnection.authenticatedRole == .operatorController,
                   let controllerID = sendingConnection.authenticatedDeviceID,
                   let sessionID = sendingConnection.authenticatedSessionUUID {
                    _ = gripperControllerBridge.consumeInbound(
                        data,
                        authenticatedControllerID: controllerID,
                        authenticatedSessionID: sessionID
                    )
                } else {
                    NSLog("Discarded gripper-control data outside an authenticated v2 operator session")
                }
                return
            }
            dataDelegate?.didReceiveData(data)
            // Preserve controller observer behavior, but never expose generic
            // commands/results to a telemetry-only publisher.
            for connection in connectionsByID.values
                where connection !== sendingConnection
                    && connection.isReady
                    && connection.canReceiveApplicationMessage(type: .sendData) {
                _ = connection.send(type: .sendData, data: data)
            }
        case .lidarTelemetry:
            guard let deviceID = sendingConnection.authenticatedDeviceID else {
                sendingConnection.stop(error: AutoNetTransportError.authorizationFailed)
                return
            }
            dataDelegate?.didReceiveLidarTelemetry?(data, deviceID: deviceID.uuidString.lowercased())
        default:
            sendingConnection.stop(error: AutoNetTransportError.authorizationFailed)
        }
    }

    /// Prevents copied credentials from owning multiple concurrent sessions.
    /// Authentication and connection callbacks are serialized on the main queue.
    func reserveAuthentication(
        deviceID: UUID,
        for candidate: AutoNetServerConnection
    ) -> Bool {
        !connectionsByID.values.contains {
            $0 !== candidate && $0.blocksDuplicateSession(for: deviceID)
        }
    }

    /// Supplies non-periodic state to a newly authenticated operator. Arm
    /// telemetry already refreshes continuously, while gripper calibration is
    /// session-local and event-driven; without this targeted bootstrap, a
    /// Vision client connecting after calibration could remain falsely stuck
    /// in "state unknown" until another local gripper event occurred.
    func authenticatedConnectionDidBecomeReady(_ connection: AutoNetServerConnection) {
        guard !paused, connection.isReady,
              connection.authenticatedRole == .operatorController,
              let controllerID = connection.authenticatedDeviceID,
              let sessionID = connection.authenticatedSessionUUID else { return }
        gripperControllerBridge.operatorSessionDidBecomeReady(
            controllerID: controllerID,
            sessionID: sessionID
        )
    }

    /// Performs sequence and rate authorization with state that survives a QUIC
    /// reconnect. The message has already passed its structural/device checks.
    func acceptLidarTelemetry(
        _ message: ROBLidarScanFrame,
        from connection: AutoNetServerConnection,
        nowMilliseconds: UInt64
    ) -> Bool {
        guard connection.authenticatedRole == .lidarPublisher,
              let deviceID = connection.authenticatedDeviceID else { return false }
        return acceptLidarTelemetry(
            message,
            authenticatedDeviceID: deviceID,
            nowMilliseconds: nowMilliseconds
        )
    }

    private func acceptLidarTelemetry(
        _ message: ROBLidarScanFrame,
        authenticatedDeviceID deviceID: UUID,
        nowMilliseconds: UInt64
    ) -> Bool {
        guard message.validationError(
            authenticatedDeviceID: deviceID,
            lastAcceptedSequence: lastLidarSequenceByDeviceID[deviceID] ?? 0,
            nowMilliseconds: nowMilliseconds
        ) == nil else { return false }

        let nowUptime = ProcessInfo.processInfo.systemUptime
        if let last = lastLidarScanUptimeByDeviceID[deviceID], nowUptime - last < 0.100 {
            return false
        }
        lastLidarScanUptimeByDeviceID[deviceID] = nowUptime
        lastLidarSequenceByDeviceID[deviceID] = message.sequence
        return true
    }

    private func receiveLocalLidarTelemetry(_ envelope: Data) {
        precondition(Thread.isMainThread, "RPLidar authorization is owned by the main queue")
        guard !paused,
              let unverifiedScanData = ROBLidarLocalIPCEnvelope.scanData(from: envelope),
              let message = try? ROBLidarScanFrame.decode(unverifiedScanData) else { return }

        let record: ROBControlPeerAuthenticationRecord?
        do {
            record = try ROBControlPairing.activePeerAuthenticationRecord(for: message.deviceID)
        } catch {
            NSLog("Discarded local RPLidar scan because the pairing registry is unavailable: %@",
                  error.localizedDescription)
            return
        }
        guard let record, record.role == .lidarPublisher else {
            NSLog("Discarded local RPLidar scan from an unauthorized publisher")
            return
        }
        guard let scanData = ROBLidarLocalIPCEnvelope.open(
            envelope,
            sharedSecret: record.credential.sharedSecret
        ) else {
            NSLog("Discarded local RPLidar scan with an invalid pairing authentication code")
            return
        }

        let nowMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        guard acceptLidarTelemetry(
            message,
            authenticatedDeviceID: message.deviceID,
            nowMilliseconds: nowMilliseconds
        ) else { return }
        dataDelegate?.didReceiveLidarTelemetry?(
            scanData,
            deviceID: message.deviceID.uuidString.lowercased()
        )
    }

    public func stateDidChange(to state: NWListener.State) {
        switch state {
        case .ready:
            listenerStatus = "ready"
            listenerStatusDetail = legacyCompatibilityIsActive
                ? "Legacy plaintext compatibility mode"
                : "QUIC/TLS listener"
            switch transportMode {
            case .v2:
                print("ROBControl server ready on \(ROBControlPairing.serviceType) using QUIC/TLS")
            case .legacy:
                print("WARNING: legacy plaintext AutoNet UDP adapter is enabled as \(ROBControlPairing.legacyServiceType)")
            case nil:
                break
            }
        case .waiting(let error):
            listenerStatus = "waiting"
            listenerStatusDetail = error.localizedDescription
        case .failed(let error):
            listenerStatus = "failed"
            listenerStatusDetail = error.localizedDescription
            print("ROBControl server failed: \(error.localizedDescription)")
            stop()
        case .cancelled:
            paused = true
            if listenerStatus != "failed" {
                listenerStatus = "stopped"
                listenerStatusDetail = nil
            }
        default:
            break
        }
    }

    public func didAccept(nwConnection: NWConnection) {
        guard !paused, let transportMode = transportMode else {
            nwConnection.cancel()
            return
        }
        let connection = AutoNetServerConnection(
            nwConnection: nwConnection,
            transportMode: transportMode,
            credential: v2Credential,
            delegate: self
        )
        connectionsByID[connection.id] = connection
        connection.didStopCallback = { [weak self, weak connection] _ in
            guard let self = self, let connection = connection else { return }
            self.connectionDidStop(connection)
        }
        connection.start()
    }

    private func connectionDidStop(_ connection: AutoNetServerConnection) {
        connectionsByID.removeValue(forKey: connection.id)
    }

    private func credentialWasRevoked(_ notification: Notification) {
        guard let deviceID = notification.userInfo?[ROBControlCredentialNotification.deviceIDKey]
                as? UUID else { return }
        let matchingConnections = connectionsByID.values.filter {
            $0.referencesCredential(deviceID)
        }
        for connection in matchingConnections {
            connection.stop(error: AutoNetTransportError.credentialRevoked)
        }
        administratorTerminalCoordinator.closeSessions(for: deviceID)
        lastLidarSequenceByDeviceID.removeValue(forKey: deviceID)
        lastLidarScanUptimeByDeviceID.removeValue(forKey: deviceID)
    }

    public func connectionList() -> String {
        return connectionsByID.values
            .map {
                let role = $0.authenticatedRole?.rawValue ?? "unpaired"
                let device = $0.authenticatedDeviceID?.uuidString.lowercased() ?? "unknown"
                return "\($0.id):\($0.isReady ? "ready" : "connecting"):\(role):\(device)"
            }
            .joined(separator: ", ")
    }

    /// Cached, read-only process telemetry for the system-status panel. This
    /// deliberately performs no health check and never exposes credentials.
    @nonobjc func statusSnapshot() -> ROBControlServerStatusSnapshot {
        precondition(Thread.isMainThread, "ROBControl status is owned by the main queue")
        let connections = connectionsByID.values.map { connection in
            let usesLegacyTransport: Bool
            if case .legacy = connection.transportMode {
                usesLegacyTransport = true
            } else {
                usesLegacyTransport = false
            }
            return ROBControlConnectionStatusSnapshot(
                stableID: "robcontrol-\(connection.id)",
                state: connection.isReady ? "ready" : "connecting",
                role: connection.authenticatedRole?.rawValue ?? "unpaired",
                deviceID: connection.authenticatedDeviceID?.uuidString.lowercased(),
                deviceName: connection.authenticatedDeviceName,
                sessionID: connection.authenticatedSessionUUID?.uuidString.lowercased(),
                usesLegacyTransport: usesLegacyTransport,
                network: connection.networkStatusSnapshot()
            )
        }.sorted {
            let lhsName = $0.deviceName ?? $0.deviceID ?? $0.stableID
            let rhsName = $1.deviceName ?? $1.deviceID ?? $1.stableID
            let order = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if order == .orderedSame { return $0.stableID < $1.stableID }
            return order == .orderedAscending
        }
        return ROBControlServerStatusSnapshot(
            listenerState: listenerStatus,
            detail: listenerStatusDetail,
            isPaused: paused,
            connections: connections
        )
    }

    public func pause() {
        paused = true
    }

    public func resume() {
        paused = false
    }

    public func stop() {
        guard !paused || listener != nil || !connectionsByID.isEmpty else { return }
        paused = true
        if listenerStatus != "failed" {
            listenerStatus = "stopped"
            listenerStatusDetail = nil
        }
        armControllerBridge.stop()
        gripperControllerBridge.stop()
        administratorTerminalCoordinator.stop()
        localLidarIPCServer.stop()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connectionsByID.values {
            connection.didStopCallback = nil
            connection.stop()
        }
        connectionsByID.removeAll()
    }
}

// MARK: - Administrator PTY sessions

/// Owns a bounded collection of shells for paired administrator controllers.
/// Face identity is used only to bind the already-authenticated controller ID;
/// it never replaces the QUIC credential or authorizes an unpaired peer.
@available(macOS 12.0, *)
private final class ROBAdministratorTerminalCoordinator {
    private final class SessionRecord {
        struct BufferedOutput {
            let sequence: UInt64
            let data: Data
        }

        let terminalID: UUID
        let ownerControllerID: UUID
        let pseudoTerminal: ROBPseudoTerminalSession
        var attachedNetworkSessionID: UUID
        var lastRequestSequence: UInt64
        var nextResponseSequence: UInt64 = 0
        var bufferedOutput: [BufferedOutput] = []
        var bufferedOutputBytes = 0
        var highestDiscardedOutputSequence: UInt64 = 0
        var isClosing = false

        init(
            terminalID: UUID,
            ownerControllerID: UUID,
            attachedNetworkSessionID: UUID,
            requestSequence: UInt64,
            pseudoTerminal: ROBPseudoTerminalSession
        ) {
            self.terminalID = terminalID
            self.ownerControllerID = ownerControllerID
            self.attachedNetworkSessionID = attachedNetworkSessionID
            self.lastRequestSequence = requestSequence
            self.pseudoTerminal = pseudoTerminal
        }

        func nextSequence() -> UInt64 {
            nextResponseSequence &+= 1
            return nextResponseSequence
        }
    }

    private static let maximumBufferedOutputBytes = 512 * 1_024
    private weak var server: AutoNetServer?
    private var sessions: [UUID: SessionRecord] = [:]
    private var authorizationCache: [UUID: (allowed: Bool, checkedAt: TimeInterval)] = [:]

    init(server: AutoNetServer) {
        self.server = server
    }

    func claimsProtocol(_ data: Data) -> Bool {
        ROBAdministratorTerminalProtocol.claimsProtocol(data)
    }

    func consumeInbound(
        _ data: Data,
        authenticatedControllerID controllerID: UUID,
        authenticatedSessionID networkSessionID: UUID
    ) {
        precondition(Thread.isMainThread, "administrator terminal ownership is main-queue isolated")
        guard let message = try? ROBAdministratorTerminalProtocol.decode(data) else {
            NSLog("Discarded malformed administrator-terminal frame from %@", controllerID.uuidString)
            return
        }
        guard isAuthorizedAdministrator(controllerID) else {
            closeSessions(for: controllerID)
            sendStandaloneState(
                kind: .error,
                text: "Administrator terminal denied. Complete administrator face enrollment with this paired controller.",
                request: message,
                controllerID: controllerID,
                networkSessionID: networkSessionID
            )
            return
        }

        switch message.kind {
        case .open:
            openOrAttach(message, controllerID: controllerID, networkSessionID: networkSessionID)
        case .input, .resize, .close:
            consumeSessionRequest(message, controllerID: controllerID, networkSessionID: networkSessionID)
        case .output, .ready, .title, .exited, .error:
            sendStandaloneState(
                kind: .error,
                text: "The controller sent a server-only terminal message.",
                request: message,
                controllerID: controllerID,
                networkSessionID: networkSessionID
            )
        }
    }

    func closeSessions(for controllerID: UUID) {
        precondition(Thread.isMainThread, "administrator terminal ownership is main-queue isolated")
        let matching = sessions.values.filter { $0.ownerControllerID == controllerID }
        for record in matching {
            sessions.removeValue(forKey: record.terminalID)
            record.isClosing = true
            record.pseudoTerminal.stop()
        }
        authorizationCache.removeValue(forKey: controllerID)
    }

    func stop() {
        precondition(Thread.isMainThread, "administrator terminal ownership is main-queue isolated")
        let active = Array(sessions.values)
        sessions.removeAll()
        for record in active {
            record.isClosing = true
            record.pseudoTerminal.stop()
        }
    }

    private func openOrAttach(
        _ message: ROBAdministratorTerminalMessage,
        controllerID: UUID,
        networkSessionID: UUID
    ) {
        guard let acknowledgedSequence = ROBAdministratorTerminalProtocol.acknowledgement(
            from: message.payload
        ) else { return }

        if let record = sessions[message.terminalID] {
            guard record.ownerControllerID == controllerID else {
                sendStandaloneState(
                    kind: .error,
                    text: "That terminal belongs to another administrator controller.",
                    request: message,
                    controllerID: controllerID,
                    networkSessionID: networkSessionID
                )
                return
            }
            guard message.sequence > record.lastRequestSequence else { return }
            record.lastRequestSequence = message.sequence
            record.attachedNetworkSessionID = networkSessionID
            record.pseudoTerminal.resize(columns: message.columns, rows: message.rows)
            replayBufferedOutput(record, after: acknowledgedSequence)
            sendState(.ready, text: record.pseudoTerminal.workingDirectory.path, for: record)
            return
        }

        let ownedCount = sessions.values.filter { $0.ownerControllerID == controllerID }.count
        guard ownedCount < ROBAdministratorTerminalProtocol.maximumTabs else {
            sendStandaloneState(
                kind: .error,
                text: "The administrator terminal limit is \(ROBAdministratorTerminalProtocol.maximumTabs) tabs.",
                request: message,
                controllerID: controllerID,
                networkSessionID: networkSessionID
            )
            return
        }

        let pseudoTerminal = ROBPseudoTerminalSession(
            terminalID: message.terminalID,
            output: { [weak self] terminalID, data in
                DispatchQueue.main.async { self?.receiveOutput(data, terminalID: terminalID) }
            },
            terminated: { [weak self] terminalID, exitCode in
                DispatchQueue.main.async { self?.terminalDidExit(terminalID, exitCode: exitCode) }
            }
        )
        let record = SessionRecord(
            terminalID: message.terminalID,
            ownerControllerID: controllerID,
            attachedNetworkSessionID: networkSessionID,
            requestSequence: message.sequence,
            pseudoTerminal: pseudoTerminal
        )
        sessions[message.terminalID] = record
        do {
            try pseudoTerminal.start(columns: message.columns, rows: message.rows)
            sendState(.ready, text: pseudoTerminal.workingDirectory.path, for: record)
        } catch {
            sessions.removeValue(forKey: message.terminalID)
            sendStandaloneState(
                kind: .error,
                text: "Unable to open the shell: \(error.localizedDescription)",
                request: message,
                controllerID: controllerID,
                networkSessionID: networkSessionID
            )
        }
    }

    private func consumeSessionRequest(
        _ message: ROBAdministratorTerminalMessage,
        controllerID: UUID,
        networkSessionID: UUID
    ) {
        guard let record = sessions[message.terminalID],
              record.ownerControllerID == controllerID else {
            sendStandaloneState(
                kind: .error,
                text: "This terminal session is no longer available. Open a new tab.",
                request: message,
                controllerID: controllerID,
                networkSessionID: networkSessionID
            )
            return
        }
        guard message.sequence > record.lastRequestSequence else { return }
        record.lastRequestSequence = message.sequence
        record.attachedNetworkSessionID = networkSessionID

        switch message.kind {
        case .input:
            do {
                try record.pseudoTerminal.write(message.payload)
            } catch {
                sendState(.error, text: "Terminal input failed: \(error.localizedDescription)", for: record)
            }
        case .resize:
            record.pseudoTerminal.resize(columns: message.columns, rows: message.rows)
        case .close:
            record.isClosing = true
            sendState(.exited, text: "Terminal closed by administrator.", for: record)
            sessions.removeValue(forKey: record.terminalID)
            record.pseudoTerminal.stop()
        default:
            break
        }
    }

    private func receiveOutput(_ data: Data, terminalID: UUID) {
        precondition(Thread.isMainThread, "administrator terminal ownership is main-queue isolated")
        guard let record = sessions[terminalID], !record.isClosing, !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            let upperBound = min(offset + ROBAdministratorTerminalProtocol.maximumPayloadBytes, data.count)
            let chunk = data.subdata(in: offset ..< upperBound)
            let sequence = record.nextSequence()
            record.bufferedOutput.append(.init(sequence: sequence, data: chunk))
            record.bufferedOutputBytes += chunk.count
            trimBufferedOutput(record)
            send(.output, sequence: sequence, payload: chunk, for: record)
            offset = upperBound
        }
    }

    private func replayBufferedOutput(_ record: SessionRecord, after acknowledgedSequence: UInt64) {
        let pending = record.bufferedOutput.filter { $0.sequence > acknowledgedSequence }
        if record.highestDiscardedOutputSequence > acknowledgedSequence {
            sendState(.error, text: "Some earlier terminal output was discarded while disconnected.", for: record)
        }
        for chunk in pending {
            send(.output, sequence: chunk.sequence, payload: chunk.data, for: record)
        }
    }

    private func terminalDidExit(_ terminalID: UUID, exitCode: Int32) {
        precondition(Thread.isMainThread, "administrator terminal ownership is main-queue isolated")
        guard let record = sessions.removeValue(forKey: terminalID), !record.isClosing else { return }
        sendState(.exited, text: "Shell exited with status \(exitCode).", for: record)
    }

    private func trimBufferedOutput(_ record: SessionRecord) {
        while record.bufferedOutputBytes > Self.maximumBufferedOutputBytes,
              !record.bufferedOutput.isEmpty {
            let discarded = record.bufferedOutput.removeFirst()
            record.bufferedOutputBytes -= discarded.data.count
            record.highestDiscardedOutputSequence = discarded.sequence
        }
    }

    private func sendState(
        _ kind: ROBAdministratorTerminalMessageKind,
        text: String,
        for record: SessionRecord
    ) {
        send(kind, sequence: record.nextSequence(), payload: Data(text.utf8), for: record)
    }

    private func send(
        _ kind: ROBAdministratorTerminalMessageKind,
        sequence: UInt64,
        payload: Data,
        for record: SessionRecord
    ) {
        let message = ROBAdministratorTerminalMessage(
            kind: kind,
            terminalID: record.terminalID,
            sequence: sequence,
            columns: 0,
            rows: 0,
            payload: payload
        )
        guard let encoded = try? ROBAdministratorTerminalProtocol.encode(message) else { return }
        _ = server?.sendAdministratorTerminalMessage(
            encoded,
            to: record.ownerControllerID,
            sessionID: record.attachedNetworkSessionID
        )
    }

    private func sendStandaloneState(
        kind: ROBAdministratorTerminalMessageKind,
        text: String,
        request: ROBAdministratorTerminalMessage,
        controllerID: UUID,
        networkSessionID: UUID
    ) {
        let response = ROBAdministratorTerminalMessage(
            kind: kind,
            terminalID: request.terminalID,
            sequence: max(1, request.sequence),
            columns: 0,
            rows: 0,
            payload: Data(text.prefix(1_024).utf8)
        )
        guard let encoded = try? ROBAdministratorTerminalProtocol.encode(response) else { return }
        _ = server?.sendAdministratorTerminalMessage(
            encoded,
            to: controllerID,
            sessionID: networkSessionID
        )
    }

    private func isAuthorizedAdministrator(_ controllerID: UUID) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = authorizationCache[controllerID], now - cached.checkedAt < 5 {
            return cached.allowed
        }
        let expectedReference = controllerID.uuidString.lowercased()
        do {
            let allowed = try ROBFaceIdentityGallery.shared.profiles().contains { profile in
                profile.role == .administrator
                    && profile.enrollmentIsComplete
                    && profile.trustedEnrollmentReference
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == expectedReference
            }
            authorizationCache[controllerID] = (allowed, now)
            return allowed
        } catch {
            NSLog("Administrator terminal denied because the encrypted face gallery was unavailable: %@",
                  error.localizedDescription)
            authorizationCache[controllerID] = (false, now)
            return false
        }
    }
}

@available(macOS 12.0, *)
private final class ROBPseudoTerminalSession {
    enum SessionError: LocalizedError {
        case openFailed(Int32)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .openFailed(let code): return String(cString: strerror(code))
            case .unavailable: return "The pseudo-terminal is not running."
            }
        }
    }

    let terminalID: UUID
    let workingDirectory: URL
    private let outputHandler: (UUID, Data) -> Void
    private let terminationHandler: (UUID, Int32) -> Void
    private var process: Process?
    private var masterHandle: FileHandle?
    private var didStop = false

    init(
        terminalID: UUID,
        output: @escaping (UUID, Data) -> Void,
        terminated: @escaping (UUID, Int32) -> Void
    ) {
        self.terminalID = terminalID
        self.outputHandler = output
        self.terminationHandler = terminated
        let home = FileManager.default.homeDirectoryForCurrentUser
        let development = home.appendingPathComponent("dev", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: development.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            workingDirectory = development
        } else {
            workingDirectory = home
        }
    }

    deinit {
        stop()
    }

    func start(columns: UInt16, rows: UInt16) throws {
        guard process == nil, masterHandle == nil else { return }
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0 else {
            throw SessionError.openFailed(errno)
        }

        let master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: true)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-l", "-i"]
        shell.currentDirectoryURL = workingDirectory
        shell.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ROBController",
            "TERM_SESSION_ID": terminalID.uuidString.lowercased()
        ]) { _, terminalValue in terminalValue }
        shell.standardInput = slave
        shell.standardOutput = slave
        shell.standardError = slave
        shell.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.terminationHandler(self.terminalID, process.terminationStatus)
        }

        master.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self.outputHandler(self.terminalID, data)
            }
        }
        masterHandle = master
        process = shell
        resize(columns: columns, rows: rows)
        do {
            try shell.run()
            slave.closeFile()
        } catch {
            master.readabilityHandler = nil
            master.closeFile()
            slave.closeFile()
            masterHandle = nil
            process = nil
            throw error
        }
    }

    func write(_ data: Data) throws {
        guard let masterHandle, process?.isRunning == true, !didStop else {
            throw SessionError.unavailable
        }
        try masterHandle.write(contentsOf: data)
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard let descriptor = masterHandle?.fileDescriptor, descriptor >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(descriptor, TIOCSWINSZ, &size)
    }

    func stop() {
        guard !didStop else { return }
        didStop = true
        masterHandle?.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        masterHandle?.closeFile()
        masterHandle = nil
        process = nil
    }
}
