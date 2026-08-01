//
//  AutoNetClient.swift
//  Cerebro
//
//  Explicit compatibility client for the historical service-name mismatch.
//  Production ROBController code lives in the sibling ROBController project.
//

import Foundation
import Network

@objc public protocol LegacyAutoNetClientDataDelegate: AnyObject {
    func didReceiveLegacyAutoNetData(_ data: Data)
}

/// This is the only client allowed to request `_roboNet._tcp` while using UDP.
/// Construction fails unless the deliberate legacy switch is enabled.
@available(macOS 12.0, *)
@objcMembers public final class LegacyAutoNetClient: NSObject, LegacyAutoNetClientConnectionDelegate {
    public weak var dataDelegate: LegacyAutoNetClientDataDelegate?
    public private(set) var isConnected = false

    private var browser: NWBrowser?
    private var connection: LegacyAutoNetClientConnection?

    public override init() {
        super.init()
    }

    public func start() throws {
        let mode = try AutoNetTransportMode(service: ROBControlPairing.legacyServiceType)
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: mode.serviceType, domain: nil),
            using: parameters
        )
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil,
                  let endpoint = results.sorted(by: {
                    $0.endpoint.debugDescription < $1.endpoint.debugDescription
                  }).first?.endpoint else { return }
            do {
                let nwConnection = NWConnection(to: endpoint, using: try mode.makeClientParameters())
                let connection = LegacyAutoNetClientConnection(connection: nwConnection, mode: mode)
                connection.delegate = self
                connection.readinessDidChange = { [weak self] ready in self?.isConnected = ready }
                self.connection = connection
                connection.start()
            } catch {
                print("Legacy AutoNet client refused connection: \(error.localizedDescription)")
            }
        }
        browser.start(queue: .main)
    }

    public func send(_ data: Data) {
        connection?.send(data)
    }

    public func stop() {
        isConnected = false
        browser?.cancel()
        browser = nil
        connection?.stop()
        connection = nil
    }

    func legacyConnectionDidReceive(_ data: Data) {
        dataDelegate?.didReceiveLegacyAutoNetData(data)
    }
}
