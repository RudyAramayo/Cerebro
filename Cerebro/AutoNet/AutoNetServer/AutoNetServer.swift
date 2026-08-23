//
//  AutoNetServer.swift
//  Cerebro
//

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
    private lazy var armControllerBridge = ROBArmControllerBridge(server: self)
    private lazy var gripperControllerBridge = ROBGripperControllerBridge(server: self)

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
              let deviceID = connection.authenticatedDeviceID,
              message.validationError(
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
