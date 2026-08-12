import Foundation
import Network

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
    public let positionsRadians: [NSNumber]
    public let velocitiesRadiansPerSecond: [NSNumber]
    public let currents: [NSNumber]
    public let statuses: [NSNumber]

    fileprivate init(message: ROBAmberGatewayMessage) {
        arm = message.arm ?? ""
        sequence = message.sequence ?? 0
        sampleAgeMilliseconds = message.sampleAgeMilliseconds ?? .infinity
        positionsRadians = (message.positionsRadians ?? []).map(NSNumber.init(value:))
        velocitiesRadiansPerSecond = (message.velocitiesRadiansPerSecond ?? []).map(NSNumber.init(value:))
        currents = (message.currents ?? []).map(NSNumber.init(value:))
        statuses = (message.statuses ?? []).map(NSNumber.init(value:))
        super.init()
    }
}

extension Notification.Name {
    static let ROBAmberGatewayStateDidChange = Notification.Name("ROBAmberGatewayStateDidChange")
    static let ROBAmberGatewayTelemetryDidUpdate = Notification.Name("ROBAmberGatewayTelemetryDidUpdate")
    static let ROBAmberGatewayCommandDidComplete = Notification.Name("ROBAmberGatewayCommandDidComplete")
}

private struct ROBAmberGatewayMessage: Codable {
    var type: String
    var protocolName: String? = nil
    var token: String? = nil
    var commandID: UInt64? = nil
    var arm: String? = nil
    var positionsRadians: [Double]? = nil
    var durationSeconds: Double? = nil
    var sequence: UInt64? = nil
    var sampleAgeMilliseconds: Double? = nil
    var velocitiesRadiansPerSecond: [Double]? = nil
    var currents: [Double]? = nil
    var statuses: [Double]? = nil
    var accepted: Bool? = nil
    var amberResponse: Int? = nil
    var gatewayLatencyMilliseconds: Double? = nil
    var error: String? = nil

    enum CodingKeys: String, CodingKey {
        case type, token, arm, sequence, accepted, error, currents, statuses
        case protocolName = "protocol"
        case commandID = "command_id"
        case positionsRadians = "positions_rad"
        case durationSeconds = "duration_s"
        case sampleAgeMilliseconds = "sample_age_ms"
        case velocitiesRadiansPerSecond = "velocities_rad_s"
        case amberResponse = "amber_response"
        case gatewayLatencyMilliseconds = "gateway_latency_ms"
    }
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

    private static let protocolName = "rob-amber-gateway/1"
    private static let maximumLineBytes = 16_384
    private static let heartbeatInterval: TimeInterval = 1
    private let queue = DispatchQueue(label: "com.orbitusrobotics.amber-gateway")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var heartbeatTimer: DispatchSourceTimer?
    private var token = ""
    private var nextCommandID: UInt64 = 1
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public func connect(host: String = "127.0.0.1", port: UInt16 = 7443, token: String) {
        queue.async {
            self.disconnectOnQueue(detail: "Reconnecting")
            guard token.count >= 32, let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.transition(.failed, detail: "Gateway token or port is invalid")
                return
            }
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
                  positionsRadians.allSatisfy({ $0.doubleValue.isFinite && abs($0.doubleValue) <= 3.10 }),
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
            transition(.ready, detail: "Amber gateway ready")
            startHeartbeat()
        case "telemetry":
            guard ["left", "right"].contains(message.arm ?? ""),
                  message.positionsRadians?.count == 7,
                  message.velocitiesRadiansPerSecond?.count == 7,
                  message.currents?.count == 7,
                  message.statuses?.count == 7 else { return }
            let telemetry = ROBAmberGatewayTelemetry(message: message)
            if telemetry.arm == "left" { leftTelemetry = telemetry } else { rightTelemetry = telemetry }
            NotificationCenter.default.post(
                name: .ROBAmberGatewayTelemetryDidUpdate, object: self,
                userInfo: ["telemetry": telemetry]
            )
        case "trajectory_ack":
            NotificationCenter.default.post(
                name: .ROBAmberGatewayCommandDidComplete, object: self,
                userInfo: [
                    "commandID": message.commandID ?? 0,
                    "accepted": message.accepted ?? false,
                    "amberResponse": message.amberResponse ?? -1,
                    "latencyMilliseconds": message.gatewayLatencyMilliseconds ?? .infinity,
                ]
            )
        case "heartbeat_ack": break
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
        timer.setEventHandler { [weak self] in self?.send(ROBAmberGatewayMessage(type: "heartbeat")) }
        heartbeatTimer = timer
        timer.resume()
    }

    private func send(_ message: ROBAmberGatewayMessage) {
        guard let connection, let encoded = try? encoder.encode(message) else { return }
        var framed = encoded
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.disconnectOnQueue(detail: "Gateway send failed: \(error.localizedDescription)", failed: true)
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
