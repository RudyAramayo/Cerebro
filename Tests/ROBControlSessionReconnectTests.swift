import Foundation
import Network

// Standalone fixture adapters for unrelated app services. The actual server
// connection, authentication, framing, and admission policy compile unchanged.
enum ROBVideoTransport { static let applicationProtocol = "robvideo/1" }
final class ROBVideoFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: ROBVideoFramer.self)
    static var label: String { "UnusedFixtureVideo" }
    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
    func handleInput(framer: NWProtocolFramer.Instance) -> Int { 0 }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) { fatalError("Unexpected media traffic") }
}

struct ROBControlNetworkStatusSnapshot {
    let receivedBytesPerSecond, sentBytesPerSecond: Double
    let receivedMessagesPerSecond, sentMessagesPerSecond: Double
    let totalReceivedBytes, totalSentBytes: UInt64
    let lastReceiveAge, lastSendAge: TimeInterval?
    let probeSupported: Bool
    let roundTripMilliseconds: Double?
    let probesSent, probeReplies, consecutiveProbeMisses: UInt64
    let lastProbeResponseAge: TimeInterval?
}

enum ROBControlLiveSessionRegistry {
    static var active = [UUID: Data]()
    static func activate(controllerID: UUID, sessionID: Data, role: ROBControlPeerRole) {
        precondition(active[controllerID] == nil, "Two sessions became authorized at once")
        active[controllerID] = sessionID
    }
    static func deactivate(controllerID: UUID, sessionID: Data) {
        precondition(active[controllerID] == sessionID, "Wrong session was deauthorized")
        active.removeValue(forKey: controllerID)
    }
}

final class AutoNetServer {
    var connections = [Int: AutoNetServerConnection]()
    var onReady: ((AutoNetServerConnection) -> Void)?
    var onStop: ((AutoNetServerConnection, Error?) -> Void)?
    func reserveAuthentication(deviceID: UUID, for candidate: AutoNetServerConnection) -> Bool {
        AutoNetServerConnection.reserveAuthentication(
            deviceID: deviceID, for: candidate, among: Array(connections.values))
    }
    func authenticatedConnectionDidBecomeReady(_ connection: AutoNetServerConnection) {
        onReady?(connection)
    }
    func receiveApplicationMessage(type: DataMessageType, data: Data,
                                   sendingConnection: AutoNetServerConnection) {
        precondition(sendingConnection.consumeNetworkProbeMessage(data), "Unexpected robot command")
    }
    func acceptLidarTelemetry(_ message: ROBLidarScanFrame, from: AutoNetServerConnection,
                              nowMilliseconds: UInt64) -> Bool { false }
}

private func parameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(
        NWProtocolFramer.Options(definition: ROBV2ControlFramer.definition), at: 0)
    return parameters
}

private func send(_ connection: NWConnection, type: DataMessageType, data: Data) {
    connection.send(content: data, contentContext: .init(identifier: "fixture",
        metadata: [AutoNetTransportMode.v2.makeMessage(type: type)]), isComplete: true,
        completion: .contentProcessed { error in
            precondition(error == nil, "Fixture send failed: \(String(describing: error))")
        })
}

private final class Peer {
    let connection: NWConnection
    let credential: ROBControlCredential
    let corruptProof: Bool
    let completion: (DataMessageType, Data) -> Void
    var receivedAcceptance = false

    init(port: NWEndpoint.Port, credential: ROBControlCredential, corruptProof: Bool = false,
         completion: @escaping (DataMessageType, Data) -> Void) {
        self.credential = credential
        self.corruptProof = corruptProof
        self.completion = completion
        connection = NWConnection(host: "127.0.0.1", port: port, using: parameters())
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            if case .ready = state {
                var hello = Data(credential.controllerID.uuidString.lowercased().utf8)
                hello.append(Data(repeating: 0, count: 4096 - hello.count))
                send(connection, type: .pairingHello, data: hello)
                receive()
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection.receiveMessage { [self] data, context, _, error in
            // The deliberately silent first peer is expected to be closed.
            if error != nil { return }
            guard let data, let type = AutoNetTransportMode.v2.messageType(from: context) else { return }
            if type == .pairingChallenge {
                let challenge = ROBControlAuthChallenge(data)!
                var proof = try! ROBControlAuthenticator.makeProof(challenge: challenge, credential: credential).encoded
                if corruptProof { proof[proof.count - 1] ^= 0xFF }
                send(connection, type: .pairingProof, data: proof)
                receive()
            } else if type == .pairingAccepted {
                receivedAcceptance = true
                send(connection, type: .sendData, data: Data("ROBNET-PROBE-CAP-V1".utf8))
                completion(type, data)
                receive()
            } else if type == .pairingRejected {
                completion(type, data)
            } else {
                precondition(receivedAcceptance && type == .sendData)
                // Keep the socket open and read packets, but simulate an app
                // that never answers heartbeats. QUIC/TCP readiness is not enough.
                receive()
            }
        }
    }
}

private final class ReconnectFixture {
    let server = AutoNetServer()
    let credential = ROBControlCredential(
        version: 2, robotID: UUID(), controllerID: UUID(),
        serviceType: ROBControlPairing.serviceType, applicationProtocol: ROBControlPairing.applicationProtocol,
        certificateSHA256: Data(repeating: 0xA5, count: 32), sharedSecret: Data((0..<32).map(UInt8.init)))
    var listener: NWListener!
    var peers = [Peer]()
    var first: AutoNetServerConnection?
    var firstAccepted = false
    var checkedDuplicate = false
    var checkedInvalidProof = false
    var replacementAccepted = false

    func start() throws {
        ROBControlPairing.installSessionFixturePeers([credential])
        let local = parameters()
        local.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: local)
        listener.newConnectionHandler = { [self] connection in
            let accepted = AutoNetServerConnection(nwConnection: connection, transportMode: .v2,
                credential: credential, delegate: server)
            server.connections[accepted.id] = accepted
            accepted.didStopCallback = { [self, weak accepted] error in
                guard let accepted else { return }
                server.connections.removeValue(forKey: accepted.id)
                didStop(accepted, error: error)
            }
            accepted.start()
        }
        server.onReady = { [self] connection in
            if first == nil { first = connection }
            continueWhenReady()
        }
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state {
                connect { [self] type, _ in
                    precondition(type == .pairingAccepted)
                    firstAccepted = true
                    continueWhenReady()
                }
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { fatalError("Reconnect fixture timed out") }
    }

    func connect(corruptProof: Bool = false, completion: @escaping (DataMessageType, Data) -> Void) {
        let peer = Peer(port: listener.port!, credential: credential, corruptProof: corruptProof, completion: completion)
        peers.append(peer)
        peer.start()
    }

    func continueWhenReady() {
        guard first != nil, firstAccepted else { return }
        if !checkedDuplicate {
            checkedDuplicate = true
            connect { [self] type, payload in
                precondition(type == .pairingRejected)
                precondition(ROBControlPairingRejectionReason(payload: payload) == .sessionInUse)
                precondition(first!.isReady, "A healthy original session was displaced")
                connect(corruptProof: true) { [self] type, payload in
                    precondition(type == .pairingRejected)
                    precondition(ROBControlPairingRejectionReason(payload: payload) == .unspecified)
                    precondition(first!.isReady, "An invalid proof displaced the original session")
                    checkedInvalidProof = true
                }
            }
        }
        if replacementAccepted, server.connections.values.contains(where: { $0 !== first && $0.isReady }) {
            precondition(ROBControlLiveSessionRegistry.active.count == 1)
            print("ROBControl reconnect fixture passed: duplicate denied, invalid proof denied, silent session expired, replacement authenticated")
            exit(0)
        }
    }

    func didStop(_ connection: AutoNetServerConnection, error: Error?) {
        guard connection === first else { return }
        precondition(checkedInvalidProof)
        precondition(error as? NWError == .posix(.ETIMEDOUT))
        precondition(!connection.blocksDuplicateSession(for: credential.controllerID))
        precondition(ROBControlLiveSessionRegistry.active.isEmpty, "Expired authorization survived cleanup")
        connect { [self] type, _ in
            precondition(type == .pairingAccepted, "Reconnect was rejected after expiry")
            replacementAccepted = true
            continueWhenReady()
        }
    }
}

@main
struct ROBControlSessionReconnectTests {
    private static let fixture = ReconnectFixture()
    static func main() throws {
        try fixture.start()
        // Keep the actual main thread alive, as AppKit does. dispatchMain()
        // may service the main queue on a worker in a command-line process.
        RunLoop.main.run()
        fatalError("The fixture run loop exited before completion")
    }
}
