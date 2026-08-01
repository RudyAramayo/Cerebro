//
//  AutoNetClientConnection.swift
//  Cerebro
//
//  Plaintext UDP connection used only by LegacyAutoNetClient.
//

import Foundation
import Network

protocol LegacyAutoNetClientConnectionDelegate: AnyObject {
    func legacyConnectionDidReceive(_ data: Data)
}

@available(macOS 12.0, *)
final class LegacyAutoNetClientConnection {
    weak var delegate: LegacyAutoNetClientConnectionDelegate?
    var readinessDidChange: ((Bool) -> Void)?

    private let connection: NWConnection
    private let mode: AutoNetTransportMode
    private let queue = DispatchQueue(label: "com.orbitusrobotics.autonet.legacy-client")
    private var stopped = false

    init(connection: NWConnection, mode: AutoNetTransportMode) {
        self.connection = connection
        self.mode = mode
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.readinessDidChange?(true)
                self.receiveNext()
            case .waiting:
                self.readinessDidChange?(false)
            case .failed, .cancelled:
                self.stop()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.stopped, !data.isEmpty else { return }
            let metadata = self.mode.makeMessage(type: .sendData)
            let context = NWConnection.ContentContext(identifier: "LegacyAutoNet.SendData", metadata: [metadata])
            self.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.stop() }
            })
        }
    }

    private func receiveNext() {
        guard !stopped else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                self.stop()
                return
            }
            guard self.mode.messageType(from: context) == .sendData else {
                self.stop()
                return
            }
            if let data, !data.isEmpty { self.delegate?.legacyConnectionDidReceive(data) }
            self.receiveNext()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        readinessDidChange?(false)
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
