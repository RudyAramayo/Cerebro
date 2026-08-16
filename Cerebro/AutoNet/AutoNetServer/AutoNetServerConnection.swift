//
//  AutoNetServerConnection.swift
//  Cerebro
//

import Foundation
import Network

@available(macOS 12.0, *)
public final class AutoNetServerConnection {
    private enum AuthenticationState {
        case transportConnecting
        case awaitingHello
        case awaitingProof(ROBControlAuthChallenge)
        case sendingAccepted
        case authenticated
        case stopped
    }

    private static var nextID = 0
    private static let authenticationTimeout: TimeInterval = 5

    weak var serverDelegate: AutoNetServer?
    let connection: NWConnection
    let transportMode: AutoNetTransportMode
    let id: Int
    private let credential: ROBControlCredential?
    private(set) var isReady = false
    private(set) var authenticatedControllerID: UUID?
    private(set) var authenticatedRole: ROBControlPeerRole?
    private(set) var authenticatedDeviceName: String?
    private var authenticatedSessionID: Data?
    private var authenticatingDeviceID: UUID?
    private var authenticationState: AuthenticationState = .transportConnecting
    private var authenticationTimeoutWorkItem: DispatchWorkItem?
    private var didStop = false

    init(
        nwConnection: NWConnection,
        transportMode: AutoNetTransportMode,
        credential: ROBControlCredential?,
        delegate: AutoNetServer
    ) {
        self.connection = nwConnection
        self.transportMode = transportMode
        self.credential = credential
        self.serverDelegate = delegate
        self.id = Self.nextID
        Self.nextID += 1
    }

    var didStopCallback: ((Error?) -> Void)?

    var authenticatedDeviceID: UUID? { authenticatedControllerID }
    var authenticatedSessionUUID: UUID? {
        authenticatedSessionID.flatMap(UUID.init(robControlBytes:))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateDidChange(to: state)
        }
        connection.start(queue: .main)
    }

    private func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .waiting(let error):
            isReady = false
            print("ROBControl connection \(id) waiting: \(error.localizedDescription)")
        case .ready:
            switch transportMode {
            case .legacy:
                authenticationState = .authenticated
                authenticatedRole = .operatorController
                isReady = true
                print("ROBControl legacy connection \(id) ready (plaintext compatibility mode)")
                receiveNextMessage()
            case .v2:
                switch authenticationState {
                case .transportConnecting:
                    beginV2Authentication()
                case .authenticated:
                    guard let deviceID = authenticatedControllerID,
                          serverDelegate?.reserveAuthentication(deviceID: deviceID, for: self) == true else {
                        stop(error: AutoNetTransportError.authorizationFailed)
                        return
                    }
                    isReady = true
                    serverDelegate?.authenticatedConnectionDidBecomeReady(self)
                    print("ROBControl connection \(id) recovered its authenticated QUIC path")
                case .awaitingHello, .awaitingProof, .sendingAccepted, .stopped:
                    break
                }
            }
        case .failed(let error):
            stop(error: error)
        case .cancelled:
            stop(error: nil)
        default:
            break
        }
    }

    private func beginV2Authentication() {
        guard case .transportConnecting = authenticationState,
              let credential else {
            stop(error: AutoNetTransportError.authenticationFailed)
            return
        }
        authenticationState = .awaitingHello
        let timeout = DispatchWorkItem { [weak self] in
            self?.stop(error: AutoNetTransportError.authenticationFailed)
        }
        authenticationTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.authenticationTimeout, execute: timeout)
        receiveNextMessage()
    }

    private func sendV2Challenge() {
        guard case .awaitingHello = authenticationState, let credential else {
            stop(error: AutoNetTransportError.authenticationFailed)
            return
        }
        do {
            let challenge = try ROBControlAuthenticator.makeChallenge(robotID: credential.robotID)
            authenticationState = .awaitingProof(challenge)
            sendFrame(type: .pairingChallenge, data: challenge.encoded) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.stop(error: error)
                } else {
                    self.receiveNextMessage()
                }
            }
        } catch {
            stop(error: error)
        }
    }

    private func receiveNextMessage() {
        guard !didStop else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.stop(error: error)
                return
            }
            guard let type = self.transportMode.messageType(from: context),
                  let data else {
                self.stop(error: NWError.posix(.EPROTO))
                return
            }

            if case .v2 = self.transportMode, !self.isReady {
                self.handleAuthenticationMessage(type: type, data: data)
                return
            }

            if case .v2 = self.transportMode {
                guard let role = self.authenticatedRole,
                      self.registryAuthorizationIsCurrent(role: role),
                      ROBControlAuthorizationPolicy.allowsInbound(type, for: role) else {
                    self.stop(error: AutoNetTransportError.authorizationFailed)
                    return
                }
            }

            switch type {
            case .sendData:
                if !data.isEmpty {
                    self.serverDelegate?.receiveApplicationMessage(
                        type: .sendData,
                        data: data,
                        sendingConnection: self
                    )
                }
            case .lidarTelemetry:
                guard self.validateLidarTelemetry(data) else { return }
                self.serverDelegate?.receiveApplicationMessage(
                    type: .lidarTelemetry,
                    data: data,
                    sendingConnection: self
                )
            case .setAutomationScript:
                if case .legacy = self.transportMode {
                    print("ROBControl legacy setAutomationScript is not implemented")
                } else {
                    self.stop(error: AutoNetTransportError.authorizationFailed)
                    return
                }
            case .pairingChallenge, .pairingProof, .pairingAccepted, .pairingRejected,
                 .pairingHello, .invalid:
                self.stop(error: NWError.posix(.EPROTO))
                return
            }
            self.receiveNextMessage()
        }
    }

    private func handleAuthenticationMessage(type: DataMessageType, data: Data) {
        if case .awaitingHello = authenticationState {
            guard type == .pairingHello,
                  data.count >= 36,
                  let identifier = String(data: data.prefix(36), encoding: .utf8),
                  let deviceID = UUID(uuidString: identifier),
                  (try? ROBControlPairing.activePeerAuthenticationRecord(for: deviceID)) != nil else {
                rejectAuthentication()
                return
            }
            sendV2Challenge()
            return
        }
        guard type == .pairingProof,
              case .awaitingProof(let challenge) = authenticationState,
              let proof = ROBControlAuthProof(data) else {
            rejectAuthentication()
            return
        }

        // A proof is single-use even when invalid; do not leave the challenge
        // live for retries on the same QUIC connection.
        authenticationState = .sendingAccepted
        let peer: ROBControlPeerAuthenticationRecord
        do {
            guard let resolved = try ROBControlPairing.activePeerAuthenticationRecord(
                for: proof.controllerID
            ) else {
                rejectAuthentication()
                return
            }
            peer = resolved
        } catch {
            stop(error: error)
            return
        }
        guard ROBControlAuthenticator.validate(
            proof,
            challenge: challenge,
            credential: peer.credential
        ) else {
            rejectAuthentication()
            return
        }
        authenticatingDeviceID = peer.credential.controllerID
        guard serverDelegate?.reserveAuthentication(
            deviceID: peer.credential.controllerID,
            for: self
        ) == true else {
            rejectAuthentication()
            return
        }

        let accepted = ROBControlAuthenticator.accepted(
            for: proof,
            challenge: challenge,
            credential: peer.credential
        )
        sendFrame(type: .pairingAccepted, data: accepted.encoded) { [weak self] error in
            guard let self else { return }
            guard !self.didStop, self.authenticatingDeviceID == proof.controllerID else { return }
            if let error {
                self.stop(error: error)
                return
            }
            self.authenticationTimeoutWorkItem?.cancel()
            self.authenticationTimeoutWorkItem = nil
            self.authenticationState = .authenticated
            self.authenticatedControllerID = proof.controllerID
            self.authenticatedRole = peer.role
            self.authenticatedDeviceName = peer.deviceName
            self.authenticatedSessionID = challenge.sessionID
            self.authenticatingDeviceID = nil
            self.isReady = true
            ROBControlLiveSessionRegistry.activate(
                controllerID: proof.controllerID,
                sessionID: challenge.sessionID,
                role: peer.role
            )
            self.serverDelegate?.authenticatedConnectionDidBecomeReady(self)
            print(
                "ROBControl connection \(self.id) paired as \(peer.role.rawValue) "
                    + "device \(proof.controllerID.uuidString.lowercased())"
            )
            self.receiveNextMessage()
        }
    }

    private func rejectAuthentication() {
        sendFrame(type: .pairingRejected, data: Data([1])) { [weak self] _ in
            self?.stop(error: AutoNetTransportError.authenticationFailed)
        }
    }

    private func sendFrame(type: DataMessageType, data: Data, completion: @escaping (NWError?) -> Void) {
        guard !didStop else { return }
        let message = transportMode.makeMessage(type: type)
        let context = NWConnection.ContentContext(identifier: "ROBControl.\(type.rawValue)", metadata: [message])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed(completion))
    }

    private func validateLidarTelemetry(_ data: Data) -> Bool {
        guard authenticatedRole == .lidarPublisher,
              let authenticatedDeviceID,
              let message = try? JSONDecoder().decode(ROBLidarTelemetryMessage.self, from: data) else {
            stop(error: AutoNetTransportError.authorizationFailed)
            return false
        }
        let nowMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        guard message.deviceID == authenticatedDeviceID,
              serverDelegate?.acceptLidarTelemetry(
                message,
                from: self,
                nowMilliseconds: nowMilliseconds
              ) == true else {
            stop(error: AutoNetTransportError.authorizationFailed)
            return false
        }
        return true
    }

    func canReceiveApplicationMessage(type: DataMessageType) -> Bool {
        guard isReady, !didStop else { return false }
        switch transportMode {
        case .legacy:
            return type == .sendData
        case .v2:
            guard let authenticatedRole,
                  registryAuthorizationIsCurrent(role: authenticatedRole) else { return false }
            return ROBControlAuthorizationPolicy.allowsOutbound(type, to: authenticatedRole)
        }
    }

    private func registryAuthorizationIsCurrent(role: ROBControlPeerRole) -> Bool {
        guard let authenticatedControllerID,
              let record = try? ROBControlPairing.activePeerAuthenticationRecord(
                for: authenticatedControllerID
              ) else { return false }
        return record.role == role
    }

    @discardableResult
    func send(type: DataMessageType, data: Data) -> Bool {
        guard canReceiveApplicationMessage(type: type), !data.isEmpty else { return false }
        sendFrame(type: type, data: data) { [weak self] error in
            if let error { self?.stop(error: error) }
        }
        return true
    }

    func referencesCredential(_ deviceID: UUID) -> Bool {
        authenticatedControllerID == deviceID || authenticatingDeviceID == deviceID
    }

    func blocksDuplicateSession(for deviceID: UUID) -> Bool {
        authenticatingDeviceID == deviceID
            || (authenticatedControllerID == deviceID && isReady)
    }

    func stop() {
        stop(error: nil)
    }

    func stop(error: Error?) {
        guard !didStop else { return }
        let endingControllerID = authenticatedControllerID
        let endingSessionID = authenticatedSessionID
        didStop = true
        authenticationState = .stopped
        authenticationTimeoutWorkItem?.cancel()
        authenticationTimeoutWorkItem = nil
        isReady = false
        authenticatedControllerID = nil
        authenticatedRole = nil
        authenticatedDeviceName = nil
        authenticatedSessionID = nil
        authenticatingDeviceID = nil
        if let endingControllerID, let endingSessionID {
            ROBControlLiveSessionRegistry.deactivate(
                controllerID: endingControllerID,
                sessionID: endingSessionID
            )
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = didStopCallback
        didStopCallback = nil
        callback?(error)
    }
}
