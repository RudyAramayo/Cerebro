import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Network
import Security

enum ROBVideoTransport {
    static let serviceType = "_robvideo._udp"
    static let applicationProtocol = "robvideo/1"
    static let protocolVersion: UInt8 = 1
    static let defaultPort: UInt16 = 12_346
    /// One isolated QUIC connection per camera keeps a slow panorama from
    /// adding head-of-line pressure to the driving cameras.
    static let maximumConnections = 8
    static let maximumConnectionsPerController = 4
    static let authenticationTimeout: TimeInterval = 5
    static let cameraFrameStallTimeout: TimeInterval = 15
    static let mediaSendTimeout: TimeInterval = 10
    static let sendCompletionTimeout: TimeInterval = 10
    static let maximumControlPayloadBytes = 64 * 1_024
    static let maximumFramedPayloadBytes = ROBVideoWireLimits.maximumAccessUnitBytes + 92

    static let maximumWidth: UInt16 = 960
    static let maximumHeight: UInt16 = 540
    static let maximumFramesPerSecond: UInt16 = 20
    static let maximumBitrate: UInt32 = 1_500_000
    static let minimumBitrate: UInt32 = 250_000
    static let desktopMaximumBitrate: UInt32 = 40_000_000
}

enum ROBVideoTransportError: LocalizedError {
    case listenerUnavailable
    case authenticationTimedOut
    case authenticationFailed
    case authorizationFailed
    case capacityReached
    case invalidMessage
    case unsupportedRequest

    var errorDescription: String? {
        switch self {
        case .listenerUnavailable:
            return "The ROB video listener could not be created."
        case .authenticationTimedOut:
            return "The ROB video peer did not complete authentication before the timeout."
        case .authenticationFailed:
            return "The ROB video pairing proof was rejected."
        case .authorizationFailed:
            return "The paired device is not authorized for this video stream."
        case .capacityReached:
            return "Cerebro has reached its video-stream capacity."
        case .invalidMessage:
            return "The ROB video peer sent an invalid message."
        case .unsupportedRequest:
            return "The requested ROB video profile is unavailable."
        }
    }
}

struct ROBVideoSubscriptionStatusSnapshot: Sendable {
    let stableID: String
    let controllerID: String
    let sessionID: String
    let profile: String
}

struct ROBVideoServerStatusSnapshot: Sendable {
    let listenerState: String
    let detail: String?
    let isStarted: Bool
    let connectionCount: Int
    let cameraAvailability: String
    let subscriptions: [ROBVideoSubscriptionStatusSnapshot]
}

enum ROBVideoMessageType: UInt16 {
    case invalid = 0
    case authenticationChallenge = 1
    case authenticationProof = 2
    case authenticationAccepted = 3
    case authenticationRejected = 4
    case capabilities = 5
    case subscribe = 6
    case subscriptionResponse = 7
    case unsubscribe = 8
    case feedback = 9
    case codecConfiguration = 10
    case accessUnit = 11
    case streamEnded = 12
    /// Opens the controller-initiated bidirectional QUIC stream before the
    /// server writes its challenge. Appended to preserve every existing v1
    /// message value.
    case authenticationHello = 13
}

extension Notification.Name {
    static let robControlLiveSessionDidEnd = Notification.Name(
        "com.orbitusrobotics.robctl.v2.live-session-ended"
    )
    static let robVideoCameraDemandDidChange = Notification.Name(
        "com.orbitusrobotics.robvideo.camera-demand-changed"
    )
}

enum ROBVideoCameraDemandNotification {
    static let cameraIDKey = "cameraID"
    static let isActiveKey = "isActive"
}

enum ROBControlLiveSessionNotification {
    static let controllerIDKey = "controllerID"
    static let sessionIDKey = "sessionID"
}

/// Thread-safe bridge between the safety-critical control connection and the
/// separate media service. A video subscription is valid only while the exact
/// authenticated operator/control-session pair remains live.
enum ROBControlLiveSessionRegistry {
    private struct Entry {
        let sessionID: Data
        let role: ROBControlPeerRole
    }

    private static let queue = DispatchQueue(
        label: "com.orbitusrobotics.robctl.v2.live-session-registry"
    )
    private static var entriesByControllerID: [UUID: Entry] = [:]

    static func activate(controllerID: UUID, sessionID: Data, role: ROBControlPeerRole) {
        guard sessionID.count == 16 else { return }
        let displacedSessionID = queue.sync { () -> UUID? in
            let previous = entriesByControllerID[controllerID]
            entriesByControllerID[controllerID] = Entry(sessionID: sessionID, role: role)
            guard previous?.sessionID != sessionID,
                  let previousBytes = previous?.sessionID else { return nil }
            return UUID(robVideoBytes: previousBytes)
        }
        if let displacedSessionID {
            NotificationCenter.default.post(
                name: .robControlLiveSessionDidEnd,
                object: nil,
                userInfo: [
                    ROBControlLiveSessionNotification.controllerIDKey: controllerID,
                    ROBControlLiveSessionNotification.sessionIDKey: displacedSessionID,
                ]
            )
        }
    }

    static func isActiveOperator(controllerID: UUID, sessionID: UUID) -> Bool {
        let expectedBytes = sessionID.robVideoBytes
        return queue.sync {
            guard let entry = entriesByControllerID[controllerID] else { return false }
            return entry.role == .operatorController && entry.sessionID == expectedBytes
        }
    }

    static func deactivate(controllerID: UUID, sessionID: Data) {
        let removed = queue.sync { () -> Bool in
            guard entriesByControllerID[controllerID]?.sessionID == sessionID else { return false }
            entriesByControllerID.removeValue(forKey: controllerID)
            return true
        }
        guard removed, let sessionUUID = UUID(robVideoBytes: sessionID) else { return }
        NotificationCenter.default.post(
            name: .robControlLiveSessionDidEnd,
            object: nil,
            userInfo: [
                ROBControlLiveSessionNotification.controllerIDKey: controllerID,
                ROBControlLiveSessionNotification.sessionIDKey: sessionUUID,
            ]
        )
    }
}

private struct ROBVideoAuthChallenge {
    static let encodedSize = 65

    let channelID: Data
    let serverNonce: Data
    let robotID: UUID

    var encoded: Data {
        var data = Data([ROBVideoTransport.protocolVersion])
        data.append(channelID)
        data.append(serverNonce)
        data.append(robotID.robVideoBytes)
        return data
    }

    init(channelID: Data, serverNonce: Data, robotID: UUID) {
        self.channelID = channelID
        self.serverNonce = serverNonce
        self.robotID = robotID
    }
}

private struct ROBVideoAuthHello {
    static let legacyEncodedSize = 17
    static let sessionBoundEncodedSize = 33

    let controllerID: UUID
    let controlSessionID: UUID?

    init?(_ data: Data) {
        let bytes = Data(data)
        let sizeIsSupported = bytes.count == Self.legacyEncodedSize
            || bytes.count == Self.sessionBoundEncodedSize
        guard sizeIsSupported,
              bytes[0] == ROBVideoTransport.protocolVersion,
              let controllerID = UUID(robVideoBytes: bytes.subdata(in: 1..<17)) else {
            return nil
        }
        self.controllerID = controllerID
        if bytes.count == Self.sessionBoundEncodedSize {
            guard let controlSessionID = UUID(
                robVideoBytes: bytes.subdata(in: 17..<33)
            ) else {
                return nil
            }
            self.controlSessionID = controlSessionID
        } else {
            controlSessionID = nil
        }
    }
}

private struct ROBVideoAuthProof {
    static let encodedSize = 97

    let channelID: Data
    let controllerID: UUID
    let clientNonce: Data
    let mac: Data

    init?(_ data: Data) {
        let bytes = Data(data)
        guard bytes.count == Self.encodedSize,
              bytes[0] == ROBVideoTransport.protocolVersion,
              let controllerID = UUID(robVideoBytes: bytes.subdata(in: 17..<33)) else {
            return nil
        }
        channelID = bytes.subdata(in: 1..<17)
        self.controllerID = controllerID
        clientNonce = bytes.subdata(in: 33..<65)
        mac = bytes.subdata(in: 65..<97)
    }
}

private struct ROBVideoAuthAccepted {
    let channelID: Data
    let controllerID: UUID
    let mac: Data

    var encoded: Data {
        var data = Data([ROBVideoTransport.protocolVersion])
        data.append(channelID)
        data.append(controllerID.robVideoBytes)
        data.append(mac)
        return data
    }
}

/// A video connection may inherit authentication from the exact live control
/// session that created it. TLS protects the random session UUID in transit,
/// and the server rechecks the controller/session pair before accepting.
private struct ROBVideoSessionAuthAccepted {
    let channelID: Data
    let controllerID: UUID
    let controlSessionID: UUID

    var encoded: Data {
        var data = Data([ROBVideoTransport.protocolVersion])
        data.append(channelID)
        data.append(controllerID.robVideoBytes)
        data.append(controlSessionID.robVideoBytes)
        return data
    }
}

/// One-byte failure codes are deliberately non-secret. They let a paired app
/// distinguish resource pressure and stale authorization from an invalid HMAC
/// without exposing any credential material.
private enum ROBVideoAuthRejectionCode: UInt8 {
    case proofRejected = 1
    case notAuthorized = 2
    case capacityReached = 3
    case invalidMessage = 4
}

private enum ROBVideoAuthenticator {
    private static let transcriptDomain = Data("robvideo/1\0".utf8)
    private static let clientDomain = Data("ROBVIDEO-AUTH-V1/CLIENT-PROOF\0".utf8)
    private static let serverDomain = Data("ROBVIDEO-AUTH-V1/SERVER-ACCEPTED\0".utf8)

    static func makeChallenge(robotID: UUID) throws -> ROBVideoAuthChallenge {
        ROBVideoAuthChallenge(
            channelID: try random(count: 16),
            serverNonce: try random(count: 32),
            robotID: robotID
        )
    }

    static func validate(
        _ proof: ROBVideoAuthProof,
        challenge: ROBVideoAuthChallenge,
        credential: ROBControlCredential
    ) -> Bool {
        guard proof.channelID == challenge.channelID,
              proof.controllerID == credential.controllerID,
              challenge.robotID == credential.robotID else {
            return false
        }
        var input = clientDomain
        input.append(transcript(
            challenge: challenge,
            controllerID: proof.controllerID,
            clientNonce: proof.clientNonce
        ))
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof.mac,
            authenticating: input,
            using: SymmetricKey(data: credential.sharedSecret)
        )
    }

    static func accepted(
        for proof: ROBVideoAuthProof,
        challenge: ROBVideoAuthChallenge,
        credential: ROBControlCredential
    ) -> ROBVideoAuthAccepted {
        var input = serverDomain
        input.append(transcript(
            challenge: challenge,
            controllerID: proof.controllerID,
            clientNonce: proof.clientNonce
        ))
        input.append(proof.mac)
        return ROBVideoAuthAccepted(
            channelID: challenge.channelID,
            controllerID: proof.controllerID,
            mac: Data(HMAC<SHA256>.authenticationCode(
                for: input,
                using: SymmetricKey(data: credential.sharedSecret)
            ))
        )
    }

    private static func transcript(
        challenge: ROBVideoAuthChallenge,
        controllerID: UUID,
        clientNonce: Data
    ) -> Data {
        var data = transcriptDomain
        data.append(challenge.encoded)
        data.append(controllerID.robVideoBytes)
        data.append(clientNonce)
        return data
    }

    private static func random(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AutoNetTransportError.randomGeneration(status)
        }
        return data
    }
}

@available(macOS 12.0, *)
final class ROBVideoFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: ROBVideoFramer.self)
    static var label: String { "ROBVideoV1" }

    private var nextOutputSequence: UInt64 = 1
    private var lastInputSequence: UInt64 = 0

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        guard messageLength >= 0,
              messageLength <= ROBVideoTransport.maximumFramedPayloadBytes,
              message.robVideoMessageType != .invalid,
              nextOutputSequence < UInt64.max else {
            framer.markFailed(error: NWError.posix(.EMSGSIZE))
            return
        }
        let header = ROBVideoFrameHeader(
            type: message.robVideoMessageType,
            payloadLength: UInt32(messageLength),
            sequence: nextOutputSequence
        )
        nextOutputSequence += 1
        framer.writeOutput(data: header.encodedData)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: NWError.posix(.EIO))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var parsedHeader: ROBVideoFrameHeader?
            var malformed = false
            let headerSize = ROBVideoFrameHeader.encodedSize
            let parsed = framer.parseInput(
                minimumIncompleteLength: headerSize,
                maximumLength: headerSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= headerSize else { return 0 }
                parsedHeader = ROBVideoFrameHeader(buffer)
                malformed = parsedHeader == nil
                return headerSize
            }
            guard parsed else { return headerSize }
            guard !malformed,
                  let header = parsedHeader,
                  header.sequence > lastInputSequence else {
                framer.markFailed(error: NWError.posix(.EPROTO))
                return 0
            }
            lastInputSequence = header.sequence

            let message = NWProtocolFramer.Message(definition: Self.definition)
            message.robVideoMessageType = header.type
            if !framer.deliverInputNoCopy(
                length: Int(header.payloadLength),
                message: message,
                isComplete: true
            ) {
                return 0
            }
        }
    }
}

private struct ROBVideoFrameHeader {
    static let magic: UInt32 = 0x5256_4944 // "RVID"
    static let encodedSize = 32

    let type: ROBVideoMessageType
    let payloadLength: UInt32
    let sequence: UInt64

    init(type: ROBVideoMessageType, payloadLength: UInt32, sequence: UInt64) {
        self.type = type
        self.payloadLength = payloadLength
        self.sequence = sequence
    }

    init?(_ buffer: UnsafeMutableRawBufferPointer) {
        guard buffer.count >= Self.encodedSize,
              Self.readUInt32(buffer, at: 0) == Self.magic,
              buffer[4] == ROBVideoTransport.protocolVersion,
              buffer[5] == UInt8(Self.encodedSize),
              let type = ROBVideoMessageType(rawValue: Self.readUInt16(buffer, at: 6)),
              type != .invalid,
              Self.readUInt16(buffer, at: 12) == 0,
              Self.readUInt16(buffer, at: 14) == 0,
              Self.readUInt64(buffer, at: 24) == 0 else {
            return nil
        }
        let payloadLength = Self.readUInt32(buffer, at: 8)
        let payloadLimit = type == .codecConfiguration || type == .accessUnit
            ? ROBVideoTransport.maximumFramedPayloadBytes
            : ROBVideoTransport.maximumControlPayloadBytes
        guard payloadLength <= UInt32(payloadLimit) else {
            return nil
        }
        self.type = type
        self.payloadLength = payloadLength
        sequence = Self.readUInt64(buffer, at: 16)
    }

    var encodedData: Data {
        var data = Data()
        data.reserveCapacity(Self.encodedSize)
        data.appendBigEndian(Self.magic)
        data.append(ROBVideoTransport.protocolVersion)
        data.append(UInt8(Self.encodedSize))
        data.appendBigEndian(type.rawValue)
        data.appendBigEndian(payloadLength)
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(sequence)
        data.appendBigEndian(UInt64(0))
        return data
    }

    private static func readUInt16(_ bytes: UnsafeMutableRawBufferPointer, at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: UnsafeMutableRawBufferPointer, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in offset..<(offset + 4) {
            value = (value << 8) | UInt32(bytes[index])
        }
        return value
    }

    private static func readUInt64(_ bytes: UnsafeMutableRawBufferPointer, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(bytes[index])
        }
        return value
    }
}

@available(macOS 12.0, *)
private extension NWProtocolFramer.Message {
    var robVideoMessageType: ROBVideoMessageType {
        get { self["ROBVideoMessageType"] as? ROBVideoMessageType ?? .invalid }
        set { self["ROBVideoMessageType"] = newValue }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}

private extension UUID {
    var robVideoBytes: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    init?(robVideoBytes data: Data) {
        guard data.count == 16 else { return nil }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        self.init(uuid: value)
    }
}

@available(macOS 12.0, *)
final class ROBVideoServerRegistry {
    static let shared = ROBVideoServerRegistry()

    private let lock = NSLock()
    private weak var server: ROBVideoServer?

    private init() {}

    func install(_ server: ROBVideoServer) {
        lock.lock()
        self.server = server
        lock.unlock()
    }

    func remove(_ candidate: ROBVideoServer) {
        lock.lock()
        if server === candidate { server = nil }
        lock.unlock()
    }

    func offer(cameraID: String, sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let server = server
        lock.unlock()
        server?.offer(cameraID: cameraID, sampleBuffer: sampleBuffer)
    }

    func offerInsta360JPEG(_ data: Data) {
        lock.lock()
        let server = server
        lock.unlock()
        server?.offerJPEG(cameraID: "insta360", data: data)
    }

    func updateCameraState(_ state: CameraSourceState, cameraID: String) {
        lock.lock()
        let server = server
        lock.unlock()
        server?.updateCameraState(state, cameraID: cameraID)
    }
}

@available(macOS 12.0, *)
final class ROBVideoServer {
    private enum CameraAvailability {
        case unknown
        case available
        case unavailable
    }

    let port: NWEndpoint.Port
    fileprivate let queue = DispatchQueue(
        label: "com.orbitusrobotics.robvideo.server",
        qos: .userInitiated
    )

    private let credential: ROBControlCredential
    private var listener: NWListener?
    private var connectionsByID: [UUID: ROBVideoServerConnection] = [:]
    private var reservedConnectionCountByControllerID: [UUID: Int] = [:]
    private var subscriptionOwners: [UUID: UUID] = [:]
    private var readySubscriptionIDs: Set<UUID> = []
    private var started = false
    private var wantsStarted = false
    private var listenerRestartAttempt = 0
    private var listenerRestartWorkItem: DispatchWorkItem?
    private var cameraAvailability: CameraAvailability = .unknown
    private var lastReportedCameraDemand: Set<String> = []
    private var credentialRevocationObserver: NSObjectProtocol?
    private var controlSessionObserver: NSObjectProtocol?
    private let statusLock = NSLock()
    private var cachedStatus = ROBVideoServerStatusSnapshot(
        listenerState: "stopped",
        detail: nil,
        isStarted: false,
        connectionCount: 0,
        cameraAvailability: "unknown",
        subscriptions: []
    )
    private var listenerStatus = "stopped"
    private var listenerStatusDetail: String?

    private lazy var desktopCapture = ROBRemoteDesktopCaptureService { [weak self] sample, jpeg, width, height in
        self?.queue.async { [weak self] in
            self?.offerDesktopFrame(sample, jpeg: jpeg, width: width, height: height)
        }
    }

    private let offeredSampleLock = NSLock()
    private var latestOfferedSamples: [String: CMSampleBuffer] = [:]
    private var sampleDrainScheduled = false
    private var acceptedCameraIDs: Set<String> = []
    private let jpegConversionQueue = DispatchQueue(
        label: "com.orbitusrobotics.robvideo.jpeg-conversion",
        qos: .userInitiated
    )
    private let jpegLock = NSLock()
    private var latestJPEGByCameraID: [String: Data] = [:]
    private var jpegDrainScheduled = false

    init(port: UInt16 = ROBVideoTransport.defaultPort) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ROBVideoTransportError.listenerUnavailable
        }
        self.port = endpointPort
        credential = try ROBControlPairing.serverAuthenticationMaterial()
        listener = try Self.makeListener(
            endpointPort: endpointPort,
            credential: credential
        )
        installCredentialObservers()
    }

    private static func makeListener(
        endpointPort: NWEndpoint.Port,
        credential: ROBControlCredential
    ) throws -> NWListener {
        let parameters = try ROBControlPairing.makeVideoServerParameters()
        let listener = try NWListener(using: parameters, on: endpointPort)
        let txtRecord = NetService.data(fromTXTRecord: [
            "ver": Data("1".utf8),
            "alpn": Data(ROBVideoTransport.applicationProtocol.utf8),
            "robot_id": Data(credential.robotID.uuidString.lowercased().utf8),
            "codec": Data(ROBVideoCodec.h264.rawValue.utf8),
            "delivery": Data(ROBVideoDeliveryMode.reliableStream.rawValue.utf8),
        ])
        listener.service = NWListener.Service(
            name: "ROBVIDEO-\(ProcessInfo.processInfo.hostName)",
            type: ROBVideoTransport.serviceType,
            domain: nil,
            txtRecord: txtRecord
        )
        return listener
    }

    private func installCredentialObservers() {
        credentialRevocationObserver = NotificationCenter.default.addObserver(
            forName: .robControlCredentialWasRevoked,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let controllerID = notification.userInfo?[
                ROBControlCredentialNotification.deviceIDKey
            ] as? UUID else { return }
            self?.queue.async {
                self?.closeConnections(controllerID: controllerID, sessionID: nil)
            }
        }
        controlSessionObserver = NotificationCenter.default.addObserver(
            forName: .robControlLiveSessionDidEnd,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let controllerID = notification.userInfo?[
                ROBControlLiveSessionNotification.controllerIDKey
            ] as? UUID,
                  let sessionID = notification.userInfo?[
                    ROBControlLiveSessionNotification.sessionIDKey
                  ] as? UUID else { return }
            self?.queue.async {
                self?.closeConnections(controllerID: controllerID, sessionID: sessionID)
            }
        }
    }

    deinit {
        listenerRestartWorkItem?.cancel()
        if let credentialRevocationObserver {
            NotificationCenter.default.removeObserver(credentialRevocationObserver)
        }
        if let controlSessionObserver {
            NotificationCenter.default.removeObserver(controlSessionObserver)
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
    }

    func start() throws {
        try queue.sync {
            guard !wantsStarted else { return }
            wantsStarted = true
            if listener == nil {
                listener = try Self.makeListener(endpointPort: port, credential: credential)
            }
            guard let listener else { throw ROBVideoTransportError.listenerUnavailable }
            startListener(listener)
            publishStatus()
        }
    }

    private func startListener(_ listener: NWListener) {
        dispatchPrecondition(condition: .onQueue(queue))
        started = true
        listenerStatus = "starting"
        listenerStatusDetail = nil
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            self?.listenerStateDidChange(state, source: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        // Retain the server until cleanup runs. This matters when an owning view
        // calls stop() from deinit and releases its last reference immediately.
        queue.async {
            self.stopOnQueue()
        }
    }

    /// Updates the media service without coupling camera lifecycle to control.
    /// Stopped/connecting/reconnecting are intentionally "unknown": accepting a
    /// subscription is what starts demand-driven capture.
    func updateCameraState(_ state: CameraSourceState) {
        updateCameraState(state, cameraID: "front")
    }

    func updateCameraState(_ state: CameraSourceState, cameraID: String) {
        let availability: CameraAvailability
        switch state {
        case .streamingRGB, .streamingRGBD:
            availability = .available
        case .unavailable:
            availability = .unavailable
        case .stopped, .connecting, .reconnecting:
            availability = .unknown
        }
        queue.async { [weak self] in
            guard let self else { return }
            if cameraID == "front" { self.cameraAvailability = availability }
            self.publishStatus()
            guard availability == .unavailable else { return }
            for connection in Array(self.connectionsByID.values) {
                connection.cameraDidBecomeUnavailable(cameraID: cameraID)
            }
        }
    }

    /// Offers the latest real camera sample without allowing capture to wait
    /// behind scaling, encoding, or a stalled network peer.
    func offer(_ sampleBuffer: CMSampleBuffer) {
        offer(cameraID: "front", sampleBuffer: sampleBuffer)
    }

    func offer(cameraID: String, sampleBuffer: CMSampleBuffer) {
        offeredSampleLock.lock()
        guard acceptedCameraIDs.contains(cameraID) else {
            offeredSampleLock.unlock()
            return
        }
        latestOfferedSamples[cameraID] = sampleBuffer
        let shouldSchedule = !sampleDrainScheduled
        if shouldSchedule { sampleDrainScheduled = true }
        offeredSampleLock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in self?.drainLatestSample() }
        }
    }

    /// Converts the Insta360 service's stitched JPEG output away from its
    /// capture queue. Only the newest panorama is retained while conversion or
    /// encoding is busy.
    func offerJPEG(cameraID: String, data: Data) {
        offeredSampleLock.lock()
        let isAccepted = acceptedCameraIDs.contains(cameraID)
        offeredSampleLock.unlock()
        guard isAccepted else { return }

        jpegLock.lock()
        latestJPEGByCameraID[cameraID] = data
        let shouldSchedule = !jpegDrainScheduled
        if shouldSchedule { jpegDrainScheduled = true }
        jpegLock.unlock()
        if shouldSchedule {
            jpegConversionQueue.async { [weak self] in self?.drainLatestJPEG() }
        }
    }

    fileprivate func reserveAuthenticatedConnection(
        controllerID: UUID,
        candidate: ROBVideoServerConnection
    ) -> Bool {
        guard connectionsByID[candidate.id] === candidate,
              connectionsByID.count <= ROBVideoTransport.maximumConnections,
              reservedConnectionCountByControllerID[controllerID, default: 0]
                < ROBVideoTransport.maximumConnectionsPerController else {
            return false
        }
        reservedConnectionCountByControllerID[controllerID, default: 0] += 1
        publishStatus()
        return true
    }

    fileprivate func reserveSubscription(
        id: UUID,
        controllerID: UUID,
        candidate: ROBVideoServerConnection
    ) -> ROBVideoSubscriptionRejection? {
        guard connectionsByID[candidate.id] === candidate else { return .capacityReached }
        guard subscriptionOwners[id] == nil else { return .duplicateSubscriptionID }
        guard subscriptionOwners.count < ROBVideoTransport.maximumConnections else {
            return .capacityReached
        }
        subscriptionOwners[id] = controllerID
        return nil
    }

    fileprivate func activateSubscription(id: UUID, controllerID: UUID) {
        guard subscriptionOwners[id] == controllerID else { return }
        readySubscriptionIDs.insert(id)
        updateCameraDemand()
        publishStatus()
    }

    fileprivate func releaseSubscription(id: UUID, controllerID: UUID) {
        guard subscriptionOwners[id] == controllerID else { return }
        subscriptionOwners.removeValue(forKey: id)
        readySubscriptionIDs.remove(id)
        updateCameraDemand()
        publishStatus()
    }

    fileprivate func connectionDidStop(_ connection: ROBVideoServerConnection) {
        connectionsByID.removeValue(forKey: connection.id)
        if connection.hasAuthenticationReservation,
           let controllerID = connection.referencedControllerID {
            let remaining = reservedConnectionCountByControllerID[controllerID, default: 1] - 1
            if remaining > 0 {
                reservedConnectionCountByControllerID[controllerID] = remaining
            } else {
                reservedConnectionCountByControllerID.removeValue(forKey: controllerID)
            }
        }
        if let stream = connection.activeStream,
           let controllerID = connection.referencedControllerID {
            releaseSubscription(id: stream.id, controllerID: controllerID)
        }
        publishStatus()
    }

    fileprivate func advertisedCameras() -> [ROBVideoCameraDescriptor] {
        return [
            ROBVideoCameraDescriptor(
                id: "front",
                name: "Main Camera",
                supportedCodecs: [.h264],
                supportedDeliveryModes: [.reliableStream],
                maximumWidth: ROBVideoTransport.maximumWidth,
                maximumHeight: ROBVideoTransport.maximumHeight,
                maximumFramesPerSecond: ROBVideoTransport.maximumFramesPerSecond,
                maximumBitrate: ROBVideoTransport.maximumBitrate
            ),
            ROBVideoCameraDescriptor(
                id: "belly",
                name: "Belly Camera",
                supportedCodecs: [.h264],
                supportedDeliveryModes: [.reliableStream],
                maximumWidth: ROBVideoTransport.maximumWidth,
                maximumHeight: ROBVideoTransport.maximumHeight,
                maximumFramesPerSecond: ROBVideoTransport.maximumFramesPerSecond,
                maximumBitrate: ROBVideoTransport.maximumBitrate
            ),
            ROBVideoCameraDescriptor(
                id: "insta360",
                name: "Insta360 Pro (Equirectangular 360°)",
                supportedCodecs: [.h264],
                supportedDeliveryModes: [.reliableStream],
                maximumWidth: ROBVideoTransport.maximumWidth,
                maximumHeight: 480,
                maximumFramesPerSecond: ROBVideoTransport.maximumFramesPerSecond,
                maximumBitrate: ROBVideoTransport.maximumBitrate
            ),
            ROBVideoCameraDescriptor(
                id: ROBRemoteDesktopCaptureService.cameraID,
                name: "Cerebro Desktop",
                supportedCodecs: [.jpeg, .h264],
                supportedDeliveryModes: [.jpegFrames, .reliableStream],
                maximumWidth: UInt16(ROBRemoteDesktopCaptureService.maximumWidth),
                maximumHeight: UInt16(ROBRemoteDesktopCaptureService.maximumHeight),
                maximumFramesPerSecond: UInt16(ROBRemoteDesktopCaptureService.framesPerSecond),
                maximumBitrate: ROBVideoTransport.desktopMaximumBitrate
            ),
        ]
    }

    private func listenerStateDidChange(_ state: NWListener.State, source: NWListener) {
        guard listener === source else { return }
        switch state {
        case .ready:
            listenerRestartAttempt = 0
            listenerStatus = "ready"
            listenerStatusDetail = "QUIC/TLS media listener"
            print(
                "ROBVideo server ready on \(ROBVideoTransport.serviceType) "
                    + "using QUIC/TLS and \(ROBVideoTransport.applicationProtocol)"
            )
        case .waiting(let error):
            listenerStatus = "waiting"
            listenerStatusDetail = error.localizedDescription
            print("ROBVideo listener waiting: \(error.localizedDescription)")
        case .failed(let error):
            listenerStatus = "reconnecting"
            listenerStatusDetail = error.localizedDescription
            print("ROBVideo listener failed: \(error.localizedDescription)")
            retireFailedListener(source)
            scheduleListenerRestart()
        case .cancelled:
            started = false
            if wantsStarted {
                listener = nil
                listenerStatus = "reconnecting"
                listenerStatusDetail = "The media listener stopped unexpectedly."
                scheduleListenerRestart()
            } else if listenerStatus != "failed" {
                listenerStatus = "stopped"
                listenerStatusDetail = nil
            }
        default:
            break
        }
        publishStatus()
    }

    private func retireFailedListener(_ failedListener: NWListener) {
        failedListener.stateUpdateHandler = nil
        failedListener.newConnectionHandler = nil
        failedListener.cancel()
        if listener === failedListener {
            listener = nil
        }
        started = false
        for connection in Array(connectionsByID.values) {
            connection.stop(error: ROBVideoTransportError.listenerUnavailable)
        }
    }

    private func scheduleListenerRestart() {
        guard wantsStarted, listenerRestartWorkItem == nil else { return }
        listenerRestartAttempt += 1
        let delay = min(10.0, Double(1 << min(listenerRestartAttempt - 1, 3)))
        let workItem = DispatchWorkItem { [weak self] in
            self?.restartListenerOnQueue()
        }
        listenerRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func restartListenerOnQueue() {
        listenerRestartWorkItem = nil
        guard wantsStarted, listener == nil else { return }
        do {
            let replacement = try Self.makeListener(endpointPort: port, credential: credential)
            listener = replacement
            startListener(replacement)
        } catch {
            started = false
            listenerStatus = "reconnecting"
            listenerStatusDetail = error.localizedDescription
            scheduleListenerRestart()
        }
        publishStatus()
    }

    private func accept(_ nwConnection: NWConnection) {
        guard started, connectionsByID.count < ROBVideoTransport.maximumConnections else {
            nwConnection.cancel()
            return
        }
        let connection = ROBVideoServerConnection(
            nwConnection: nwConnection,
            serverCredential: credential,
            server: self
        )
        connectionsByID[connection.id] = connection
        publishStatus()
        connection.start()
    }

    private func closeConnections(controllerID: UUID, sessionID: UUID?) {
        let matching = connectionsByID.values.filter {
            $0.referencedControllerID == controllerID
                && (sessionID == nil || $0.activeStream?.sessionID == sessionID)
        }
        for connection in matching {
            connection.stop(error: ROBVideoTransportError.authorizationFailed)
        }
    }

    private func drainLatestSample() {
        offeredSampleLock.lock()
        let samples = latestOfferedSamples
        latestOfferedSamples.removeAll(keepingCapacity: true)
        offeredSampleLock.unlock()

        for (cameraID, sample) in samples {
            for connection in connectionsByID.values {
                connection.offer(cameraID: cameraID, sampleBuffer: sample)
            }
        }

        offeredSampleLock.lock()
        if latestOfferedSamples.isEmpty {
            sampleDrainScheduled = false
            offeredSampleLock.unlock()
        } else {
            offeredSampleLock.unlock()
            queue.async { [weak self] in self?.drainLatestSample() }
        }
    }

    private func drainLatestJPEG() {
        jpegLock.lock()
        let frames = latestJPEGByCameraID
        latestJPEGByCameraID.removeAll(keepingCapacity: true)
        jpegLock.unlock()

        for (cameraID, data) in frames {
            if let sampleBuffer = Self.makeSampleBuffer(fromJPEG: data) {
                offer(cameraID: cameraID, sampleBuffer: sampleBuffer)
            }
        }

        jpegLock.lock()
        if latestJPEGByCameraID.isEmpty {
            jpegDrainScheduled = false
            jpegLock.unlock()
        } else {
            jpegLock.unlock()
            jpegConversionQueue.async { [weak self] in self?.drainLatestJPEG() }
        }
    }

    private func offerDesktopFrame(
        _ sampleBuffer: CMSampleBuffer,
        jpeg data: Data,
        width: Int,
        height: Int
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard acceptedCameraIDs.contains(ROBRemoteDesktopCaptureService.cameraID),
              !data.isEmpty,
              data.count <= ROBVideoWireLimits.maximumAccessUnitBytes else { return }
        for connection in connectionsByID.values {
            connection.offer(
                cameraID: ROBRemoteDesktopCaptureService.cameraID,
                sampleBuffer: sampleBuffer
            )
            connection.offerJPEG(
                cameraID: ROBRemoteDesktopCaptureService.cameraID,
                data: data,
                width: width,
                height: height
            )
        }
    }

    private static func makeSampleBuffer(fromJPEG data: Data) -> CMSampleBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0 else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: image.width,
            kCVPixelBufferHeightKey: image.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
              let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func updateCameraDemand() {
        let activeStreams = connectionsByID.values.compactMap { connection -> ROBVideoStreamDescriptor? in
            guard let stream = connection.activeStream,
                  readySubscriptionIDs.contains(stream.id) else { return nil }
            return stream
        }
        let activeCameraIDs = Set(activeStreams.map(\.cameraID))
        offeredSampleLock.lock()
        acceptedCameraIDs = activeCameraIDs
        latestOfferedSamples = latestOfferedSamples.filter {
            activeCameraIDs.contains($0.key)
        }
        offeredSampleLock.unlock()
        let desktopStream = activeStreams
            .filter { $0.cameraID == ROBRemoteDesktopCaptureService.cameraID }
            .max {
                let leftPixels = Int($0.width) * Int($0.height)
                let rightPixels = Int($1.width) * Int($1.height)
                if leftPixels == rightPixels { return $0.bitrate < $1.bitrate }
                return leftPixels < rightPixels
            }
        let desktopConfiguration = desktopStream.map {
            ROBRemoteDesktopCaptureService.Configuration(
                maximumWidth: Int($0.width),
                maximumHeight: Int($0.height),
                framesPerSecond: Int($0.framesPerSecond),
                jpegQuality: $0.bitrate >= 20_000_000
                    ? 0.94
                    : ($0.framesPerSecond >= 8 ? 0.62 : 0.68)
            )
        }
        desktopCapture.setConfiguration(desktopConfiguration)
        let changedCameraIDs = activeCameraIDs.symmetricDifference(lastReportedCameraDemand)
        guard !changedCameraIDs.isEmpty else { return }
        lastReportedCameraDemand = activeCameraIDs
        DispatchQueue.main.async {
            for cameraID in changedCameraIDs {
                NotificationCenter.default.post(
                    name: .robVideoCameraDemandDidChange,
                    object: nil,
                    userInfo: [
                        ROBVideoCameraDemandNotification.cameraIDKey: cameraID,
                        ROBVideoCameraDemandNotification.isActiveKey:
                            activeCameraIDs.contains(cameraID),
                    ]
                )
            }
        }
    }

    private func stopOnQueue() {
        wantsStarted = false
        listenerRestartWorkItem?.cancel()
        listenerRestartWorkItem = nil
        started = false
        if listenerStatus != "failed" {
            listenerStatus = "stopped"
            listenerStatusDetail = nil
        }
        if let credentialRevocationObserver {
            NotificationCenter.default.removeObserver(credentialRevocationObserver)
            self.credentialRevocationObserver = nil
        }
        if let controlSessionObserver {
            NotificationCenter.default.removeObserver(controlSessionObserver)
            self.controlSessionObserver = nil
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let connections = Array(connectionsByID.values)
        for connection in connections {
            connection.stop(error: nil)
        }
        connectionsByID.removeAll()
        reservedConnectionCountByControllerID.removeAll()
        subscriptionOwners.removeAll()
        readySubscriptionIDs.removeAll()
        updateCameraDemand()
        desktopCapture.setConfiguration(nil)
        publishStatus()
    }

    /// Returns cached transport state only; it never starts a listener,
    /// requests a camera, authenticates a peer, or probes the network.
    func statusSnapshot() -> ROBVideoServerStatusSnapshot {
        statusLock.lock()
        defer { statusLock.unlock() }
        return cachedStatus
    }

    private func publishStatus() {
        dispatchPrecondition(condition: .onQueue(queue))
        let cameraDescription: String
        switch cameraAvailability {
        case .unknown: cameraDescription = "unknown"
        case .available: cameraDescription = "available"
        case .unavailable: cameraDescription = "unavailable"
        }
        let subscriptions = connectionsByID.values.compactMap { connection -> ROBVideoSubscriptionStatusSnapshot? in
            guard let controllerID = connection.authenticatedControllerID,
                  let stream = connection.activeStream,
                  readySubscriptionIDs.contains(stream.id) else { return nil }
            return ROBVideoSubscriptionStatusSnapshot(
                stableID: stream.id.uuidString.lowercased(),
                controllerID: controllerID.uuidString.lowercased(),
                sessionID: stream.sessionID.uuidString.lowercased(),
                profile: "\(stream.cameraID) · \(stream.width)×\(stream.height) @ \(stream.framesPerSecond) FPS"
            )
        }.sorted { $0.stableID < $1.stableID }
        let snapshot = ROBVideoServerStatusSnapshot(
            listenerState: listenerStatus,
            detail: listenerStatusDetail,
            isStarted: started,
            connectionCount: connectionsByID.count,
            cameraAvailability: cameraDescription,
            subscriptions: subscriptions
        )
        statusLock.lock()
        cachedStatus = snapshot
        statusLock.unlock()
    }
}

@available(macOS 12.0, *)
private final class ROBVideoSendCompletionGate {
    private let lock = NSLock()
    private var handler: ((NWError?) -> Void)?

    init(handler: @escaping (NWError?) -> Void) {
        self.handler = handler
    }

    @discardableResult
    func complete(_ error: NWError?) -> Bool {
        lock.lock()
        let claimedHandler = handler
        handler = nil
        lock.unlock()
        claimedHandler?(error)
        return claimedHandler != nil
    }
}

@available(macOS 12.0, *)
private final class ROBVideoServerConnection {
    private enum AuthenticationState {
        case connecting
        case awaitingHello
        case awaitingProof(ROBVideoAuthChallenge)
        case sendingAccepted
        case authenticated
        case stopped
    }

    let id = UUID()
    private(set) var authenticatedControllerID: UUID?
    private(set) var activeStream: ROBVideoStreamDescriptor?
    var referencedControllerID: UUID? {
        authenticatedControllerID ?? authenticatingControllerID
    }
    private(set) var hasAuthenticationReservation = false

    private let connection: NWConnection
    private let serverCredential: ROBControlCredential
    private weak var server: ROBVideoServer?
    private var authenticationState: AuthenticationState = .connecting
    private var authenticationTimeout: DispatchWorkItem?
    private var streamLivenessCheck: DispatchWorkItem?
    private var mediaSendTimeout: DispatchWorkItem?
    private var authenticatingControllerID: UUID?
    private var authenticatingControlSessionID: UUID?
    private var encoder: ROBCameraH264Encoder?
    private var subscriptionIsReady = false
    private var streamGeneration: UInt64 = 0
    private var encoderOutputPending = false
    private var mediaSendInFlight = false
    private var mediaSendID: UInt64 = 0
    private var codecConfigurationGeneration: UInt32 = 0
    private var lastParameterSets: [Data]?
    private var lastNALLengthFieldBytes: UInt8?
    private var resendConfigurationOnNextKeyFrame = true
    private var hasProducedFirstFrame = false
    private var streamLivenessStartedUptime: TimeInterval?
    private var lastProducedFrameUptime: TimeInterval?
    private var lastFeedbackUptime: TimeInterval = 0
    private var nextJPEGSequence: UInt64 = 1
    private var stopped = false

    init(
        nwConnection: NWConnection,
        serverCredential: ROBControlCredential,
        server: ROBVideoServer
    ) {
        connection = nwConnection
        self.serverCredential = serverCredential
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateDidChange(state)
        }
        guard let server else {
            connection.cancel()
            return
        }
        connection.start(queue: server.queue)
    }

    func offer(cameraID: String, sampleBuffer: CMSampleBuffer) {
        guard !stopped,
              activeStream?.cameraID == cameraID,
              subscriptionIsReady,
              let encoder else { return }
        guard !mediaSendInFlight, !encoderOutputPending else {
            // This raw sample was never submitted to the encoder, so no
            // decoder reference was lost and an IDR would only waste bitrate.
            return
        }

        encoderOutputPending = true
        do {
            if try !encoder.encode(sampleBuffer) {
                encoderOutputPending = false
            }
        } catch {
            encoderOutputPending = false
            endStream(reason: error.localizedDescription, notifyPeer: true)
        }
    }

    func offerJPEG(cameraID: String, data: Data, width: Int, height: Int) {
        guard !stopped,
              let stream = activeStream,
              stream.cameraID == cameraID,
              stream.codec == .jpeg,
              stream.delivery == .jpegFrames,
              subscriptionIsReady,
              !mediaSendInFlight,
              nextJPEGSequence < UInt64.max,
              width == Int(stream.width),
              height == Int(stream.height) else { return }
        do {
            let nowMilliseconds = Int64(max(0, Date().timeIntervalSince1970 * 1_000))
            let unit = try ROBVideoEncodedAccessUnit(
                sessionID: stream.sessionID,
                id: stream.id,
                codec: .jpeg,
                sequence: nextJPEGSequence,
                captureTimestampUnixMilliseconds: nowMilliseconds,
                presentationTimestamp: nowMilliseconds,
                duration: 1,
                timescale: Int32(stream.framesPerSecond),
                isKeyFrame: true,
                codecConfigurationGeneration: 0,
                nalLengthFieldBytes: 0,
                payload: data
            )
            nextJPEGSequence &+= 1
            let mediaSendID = beginMediaSend()
            recordProducedFrame(streamGeneration: streamGeneration)
            sendAccessUnit(
                try unit.encodedBinary(),
                streamGeneration: streamGeneration,
                mediaSendID: mediaSendID
            )
        } catch {
            endStream(reason: error.localizedDescription, notifyPeer: true)
        }
    }

    func stop(error: Error?) {
        guard !stopped else { return }
        stopped = true
        authenticationState = .stopped
        authenticationTimeout?.cancel()
        authenticationTimeout = nil
        streamLivenessCheck?.cancel()
        streamLivenessCheck = nil
        mediaSendTimeout?.cancel()
        mediaSendTimeout = nil
        let controllerID = authenticatedControllerID
        let stream = activeStream
        encoder?.finish()
        encoder = nil
        activeStream = nil
        subscriptionIsReady = false
        streamGeneration &+= 1
        encoderOutputPending = false
        mediaSendInFlight = false
        mediaSendID &+= 1
        connection.stateUpdateHandler = nil
        connection.cancel()

        if let controllerID, let stream {
            server?.releaseSubscription(id: stream.id, controllerID: controllerID)
        }
        server?.connectionDidStop(self)
        if let error {
            print("ROBVideo connection \(id) stopped: \(error.localizedDescription)")
        }
        server = nil
    }

    private func stateDidChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if case .connecting = authenticationState {
                beginAuthentication()
            }
        case .waiting(let error):
            print("ROBVideo connection \(id) waiting: \(error.localizedDescription)")
        case .failed(let error):
            stop(error: error)
        case .cancelled:
            stop(error: nil)
        default:
            break
        }
    }

    private func beginAuthentication() {
        authenticationState = .awaitingHello
        let timeout = DispatchWorkItem { [weak self] in
            self?.stop(error: ROBVideoTransportError.authenticationTimedOut)
        }
        authenticationTimeout = timeout
        server?.queue.asyncAfter(
            deadline: .now() + ROBVideoTransport.authenticationTimeout,
            execute: timeout
        )
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        guard !stopped else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.stop(error: error)
                return
            }
            guard let data,
                  let metadata = context?.protocolMetadata(definition: ROBVideoFramer.definition)
                    as? NWProtocolFramer.Message else {
                self.stop(error: ROBVideoTransportError.invalidMessage)
                return
            }
            let type = metadata.robVideoMessageType
            switch self.authenticationState {
            case .awaitingHello, .awaitingProof:
                self.handleAuthentication(type: type, data: data)
            case .authenticated:
                self.handleApplicationMessage(type: type, data: data)
            case .connecting, .sendingAccepted, .stopped:
                self.stop(error: ROBVideoTransportError.invalidMessage)
            }
        }
    }

    private func handleAuthentication(type: ROBVideoMessageType, data: Data) {
        if case .awaitingHello = authenticationState {
            guard type == .authenticationHello,
                  let hello = ROBVideoAuthHello(data) else {
                rejectAuthentication(error: .invalidMessage, code: .invalidMessage)
                return
            }
            let peer: ROBControlPeerAuthenticationRecord
            do {
                guard let resolved = try ROBControlPairing.activePeerAuthenticationRecord(
                    for: hello.controllerID
                ) else {
                    rejectAuthentication(error: .authorizationFailed, code: .notAuthorized)
                    return
                }
                peer = resolved
            } catch {
                stop(error: error)
                return
            }
            guard peer.role == .operatorController else {
                rejectAuthentication(error: .authorizationFailed, code: .notAuthorized)
                return
            }
            if let controlSessionID = hello.controlSessionID,
               !ROBControlLiveSessionRegistry.isActiveOperator(
                    controllerID: hello.controllerID,
                    sessionID: controlSessionID
               ) {
                rejectAuthentication(error: .authorizationFailed, code: .notAuthorized)
                return
            }
            // Bind the challenge to the identity that opened this QUIC stream.
            // The proof repeats this ID; authorization then comes from either
            // the exact live control session or the legacy pairing-secret MAC.
            authenticatingControllerID = hello.controllerID
            authenticatingControlSessionID = hello.controlSessionID
            sendAuthenticationChallenge()
            return
        }
        guard type == .authenticationProof,
              case .awaitingProof(let challenge) = authenticationState,
              let proof = ROBVideoAuthProof(data) else {
            rejectAuthentication(error: .invalidMessage, code: .invalidMessage)
            return
        }
        authenticationState = .sendingAccepted
        guard proof.controllerID == authenticatingControllerID else {
            rejectAuthentication(error: .authenticationFailed, code: .proofRejected)
            return
        }

        let peer: ROBControlPeerAuthenticationRecord
        do {
            guard let resolved = try ROBControlPairing.activePeerAuthenticationRecord(
                for: proof.controllerID
            ) else {
                rejectAuthentication(error: .authorizationFailed, code: .notAuthorized)
                return
            }
            peer = resolved
        } catch {
            stop(error: error)
            return
        }
        guard peer.role == .operatorController else {
            rejectAuthentication(error: .authorizationFailed, code: .notAuthorized)
            return
        }
        let sessionAuthenticationIsValid = authenticatingControlSessionID.map {
            ROBControlLiveSessionRegistry.isActiveOperator(
                controllerID: proof.controllerID,
                sessionID: $0
            )
        } ?? false
        let pairingProofIsValid = ROBVideoAuthenticator.validate(
            proof,
            challenge: challenge,
            credential: peer.credential
        )
        guard sessionAuthenticationIsValid || pairingProofIsValid else {
            rejectAuthentication(error: .authenticationFailed, code: .proofRejected)
            return
        }
        if sessionAuthenticationIsValid && !pairingProofIsValid {
            print(
                "ROBVideo connection \(id) authenticated through its live control session; "
                    + "the legacy pairing proof did not validate."
            )
        }
        guard server?.reserveAuthenticatedConnection(
                controllerID: proof.controllerID,
                candidate: self
              ) == true else {
            rejectAuthentication(error: .capacityReached, code: .capacityReached)
            return
        }
        hasAuthenticationReservation = true

        let acceptedData: Data
        if sessionAuthenticationIsValid,
           let controlSessionID = authenticatingControlSessionID {
            acceptedData = ROBVideoSessionAuthAccepted(
                channelID: challenge.channelID,
                controllerID: proof.controllerID,
                controlSessionID: controlSessionID
            ).encoded
        } else {
            acceptedData = ROBVideoAuthenticator.accepted(
                for: proof,
                challenge: challenge,
                credential: peer.credential
            ).encoded
        }
        sendFrame(type: .authenticationAccepted, data: acceptedData) { [weak self] error in
            guard let self, !self.stopped else { return }
            if let error {
                self.stop(error: error)
                return
            }
            self.authenticationTimeout?.cancel()
            self.authenticationTimeout = nil
            self.authenticationState = .authenticated
            self.authenticatedControllerID = proof.controllerID
            self.authenticatingControllerID = nil
            self.authenticatingControlSessionID = nil
            self.sendCapabilities()
        }
    }

    /// Waiting for the hello is essential with Network.framework QUIC: the
    /// first application write determines which peer opens the stream. If the
    /// server writes first, it creates stream 1, which a plain client
    /// `NWConnection` cannot accept without an `NWConnectionGroup` listener.
    private func sendAuthenticationChallenge() {
        do {
            let challenge = try ROBVideoAuthenticator.makeChallenge(
                robotID: serverCredential.robotID
            )
            authenticationState = .awaitingProof(challenge)
            sendFrame(
                type: .authenticationChallenge,
                data: challenge.encoded
            ) { [weak self] error in
                if let error {
                    self?.stop(error: error)
                } else {
                    self?.receiveNextMessage()
                }
            }
        } catch {
            stop(error: error)
        }
    }

    private func rejectAuthentication(
        error: ROBVideoTransportError,
        code: ROBVideoAuthRejectionCode
    ) {
        sendFrame(type: .authenticationRejected, data: Data([code.rawValue])) { [weak self] _ in
            self?.stop(error: error)
        }
    }

    private func sendCapabilities() {
        do {
            let data = try ROBVideoJSON.encode(ROBVideoCapabilities(
                cameras: server?.advertisedCameras() ?? []
            ))
            sendFrame(type: .capabilities, data: data) { [weak self] error in
                if let error {
                    self?.stop(error: error)
                } else {
                    self?.receiveNextMessage()
                }
            }
        } catch {
            stop(error: error)
        }
    }

    private func handleApplicationMessage(type: ROBVideoMessageType, data: Data) {
        do {
            switch type {
            case .subscribe:
                try handleSubscribe(ROBVideoJSON.decode(
                    ROBVideoSubscriptionRequest.self,
                    from: data
                ))
            case .unsubscribe:
                try handleUnsubscribe(ROBVideoJSON.decode(
                    ROBVideoUnsubscribeRequest.self,
                    from: data
                ))
            case .feedback:
                try handleFeedback(ROBVideoJSON.decode(
                    ROBVideoReceiverFeedback.self,
                    from: data
                ))
            default:
                throw ROBVideoTransportError.invalidMessage
            }
            receiveNextMessage()
        } catch {
            stop(error: error)
        }
    }

    private func handleSubscribe(_ request: ROBVideoSubscriptionRequest) throws {
        guard let controllerID = authenticatedControllerID else {
            throw ROBVideoTransportError.authorizationFailed
        }
        guard ROBControlLiveSessionRegistry.isActiveOperator(
            controllerID: controllerID,
            sessionID: request.sessionID
        ) else {
            throw ROBVideoTransportError.authorizationFailed
        }
        if let reason = subscriptionRejection(for: request) {
            try sendSubscriptionResponse(.rejected(
                sessionID: request.sessionID,
                id: request.id,
                reason: reason
            ))
            return
        }

        let camera = server?.advertisedCameras().first { $0.id == request.cameraID }
        let isDesktop = request.cameraID == ROBRemoteDesktopCaptureService.cameraID
        let usesDesktopJPEG = isDesktop && request.delivery == .jpegFrames
        let width: UInt16
        let height: UInt16
        if usesDesktopJPEG {
            let sourceWidth = max(1, CGDisplayPixelsWide(CGMainDisplayID()))
            let sourceHeight = max(1, CGDisplayPixelsHigh(CGMainDisplayID()))
            let maximumWidth = min(
                Int(request.constraints.maximumWidth),
                Int(camera?.maximumWidth ?? UInt16(ROBRemoteDesktopCaptureService.maximumWidth))
            )
            let maximumHeight = min(
                Int(request.constraints.maximumHeight),
                Int(camera?.maximumHeight ?? UInt16(ROBRemoteDesktopCaptureService.maximumHeight))
            )
            let scale = min(
                1,
                min(Double(maximumWidth) / Double(sourceWidth),
                    Double(maximumHeight) / Double(sourceHeight))
            )
            width = UInt16(max(2, Int(Double(sourceWidth) * scale)) & ~1)
            height = UInt16(max(2, Int(Double(sourceHeight) * scale)) & ~1)
        } else {
            width = min(
                request.constraints.maximumWidth,
                camera?.maximumWidth ?? ROBVideoTransport.maximumWidth
            ) & ~1
            height = min(
                request.constraints.maximumHeight,
                camera?.maximumHeight ?? ROBVideoTransport.maximumHeight
            ) & ~1
        }
        let framesPerSecond = min(
            request.constraints.maximumFramesPerSecond,
            camera?.maximumFramesPerSecond ?? ROBVideoTransport.maximumFramesPerSecond
        )
        let bitrate = min(
            request.constraints.maximumBitrate,
            camera?.maximumBitrate ?? ROBVideoTransport.maximumBitrate
        )
        guard width >= 160,
              height >= 90,
              bitrate >= ROBVideoTransport.minimumBitrate else {
            try sendSubscriptionResponse(.rejected(
                sessionID: request.sessionID,
                id: request.id,
                reason: .invalidConstraints
            ))
            return
        }
        if let rejection = server?.reserveSubscription(
            id: request.id,
            controllerID: controllerID,
            candidate: self
        ) {
            try sendSubscriptionResponse(.rejected(
                sessionID: request.sessionID,
                id: request.id,
                reason: rejection
            ))
            return
        }

        do {
            streamGeneration &+= 1
            let newStreamGeneration = streamGeneration
            let descriptor = try ROBVideoStreamDescriptor(
                sessionID: request.sessionID,
                id: request.id,
                cameraID: request.cameraID,
                codec: usesDesktopJPEG ? .jpeg : .h264,
                width: width,
                height: height,
                framesPerSecond: framesPerSecond,
                bitrate: bitrate,
                delivery: usesDesktopJPEG ? .jpegFrames : .reliableStream
            )
            let encoder: ROBCameraH264Encoder?
            if usesDesktopJPEG {
                encoder = nil
                nextJPEGSequence = 1
            } else {
                encoder = try ROBCameraH264Encoder(
                    width: Int(width),
                    height: Int(height),
                    framesPerSecond: Int(framesPerSecond),
                    averageBitrate: bitrate
                ) { [weak self] output in
                    guard let self, let server = self.server else { return }
                    server.queue.async { [weak self] in
                        self?.handleEncoderOutput(
                            output,
                            streamGeneration: newStreamGeneration
                        )
                    }
                }
            }
            self.encoder = encoder
            activeStream = descriptor
            subscriptionIsReady = false
            codecConfigurationGeneration = 0
            lastParameterSets = nil
            lastNALLengthFieldBytes = nil
            resendConfigurationOnNextKeyFrame = true
            hasProducedFirstFrame = false
            streamLivenessStartedUptime = nil
            lastProducedFrameUptime = nil
            try sendSubscriptionResponse(
                .accepted(descriptor),
                streamGeneration: newStreamGeneration
            ) { [weak self] in
                guard let self,
                      self.streamGeneration == newStreamGeneration,
                      let controllerID = self.authenticatedControllerID,
                      let stream = self.activeStream else { return }
                self.subscriptionIsReady = true
                self.server?.activateSubscription(id: stream.id, controllerID: controllerID)
                self.startStreamLivenessChecks(streamGeneration: newStreamGeneration)
            }
        } catch {
            if activeStream?.id == request.id {
                endStream(reason: error.localizedDescription, notifyPeer: false)
            } else {
                server?.releaseSubscription(id: request.id, controllerID: controllerID)
            }
            throw error
        }
    }

    private func subscriptionRejection(
        for request: ROBVideoSubscriptionRequest
    ) -> ROBVideoSubscriptionRejection? {
        if activeStream != nil { return .capacityReached }
        if mediaSendInFlight { return .capacityReached }
        if request.protocolVersion != ROBVideoSubscriptionRequest.currentProtocolVersion
            || !request.constraints.isValid {
            return .invalidConstraints
        }
        let availableCameraIDs = Set(server?.advertisedCameras().map(\.id) ?? [])
        if !availableCameraIDs.contains(request.cameraID) { return .cameraUnavailable }
        if request.cameraID == ROBRemoteDesktopCaptureService.cameraID {
            guard let controllerID = authenticatedControllerID,
                  ROBAdministratorControllerAuthorization.isAuthorized(controllerID),
                  ROBRemoteDesktopCaptureService.hasScreenCaptureAccess else {
                return .cameraUnavailable
            }
            switch request.delivery {
            case .jpegFrames:
                if !request.preferredCodecs.contains(.jpeg) { return .codecUnavailable }
            case .reliableStream:
                if !request.preferredCodecs.contains(.h264) { return .codecUnavailable }
            case .quicDatagrams:
                return .deliveryUnavailable
            }
        } else {
            if !request.preferredCodecs.contains(.h264) { return .codecUnavailable }
            if request.delivery != .reliableStream { return .deliveryUnavailable }
        }
        return nil
    }

    private func sendSubscriptionResponse(
        _ response: ROBVideoSubscriptionResponse,
        streamGeneration: UInt64? = nil,
        onSuccess: (() -> Void)? = nil
    ) throws {
        let data = try ROBVideoJSON.encode(response)
        sendFrame(type: .subscriptionResponse, data: data) { [weak self] error in
            guard let self else { return }
            if let streamGeneration,
               streamGeneration != self.streamGeneration {
                return
            }
            if let error {
                self.stop(error: error)
            } else {
                onSuccess?()
            }
        }
    }

    private func handleUnsubscribe(_ request: ROBVideoUnsubscribeRequest) throws {
        guard request.protocolVersion == 1 else {
            throw ROBVideoTransportError.invalidMessage
        }
        guard let stream = activeStream else { return }
        guard request.sessionID == stream.sessionID, request.id == stream.id else {
            throw ROBVideoTransportError.authorizationFailed
        }
        endStream(reason: "unsubscribed", notifyPeer: true)
    }

    private func handleFeedback(_ feedback: ROBVideoReceiverFeedback) throws {
        guard feedback.protocolVersion == 1,
              let stream = activeStream,
              feedback.sessionID == stream.sessionID,
              feedback.id == stream.id else {
            throw ROBVideoTransportError.authorizationFailed
        }
        if feedback.requestsKeyFrame {
            resendConfigurationOnNextKeyFrame = true
            encoder?.requestKeyFrame()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFeedbackUptime >= 1,
              let desired = feedback.desiredBitrate else { return }
        lastFeedbackUptime = now
        let clamped = min(stream.bitrate, max(ROBVideoTransport.minimumBitrate, desired))
        try encoder?.updateAverageBitrate(clamped)
    }

    private func handleEncoderOutput(
        _ output: ROBCameraH264EncoderOutput,
        streamGeneration: UInt64
    ) {
        guard streamGeneration == self.streamGeneration else { return }
        encoderOutputPending = false
        guard !stopped, let stream = activeStream, let encoder else { return }
        switch output {
        case .frameDropped:
            resendConfigurationOnNextKeyFrame = true
            encoder.requestKeyFrame()
        case .failed(let error):
            endStream(reason: error.localizedDescription, notifyPeer: true)
        case .frame(let frame):
            guard !mediaSendInFlight else {
                resendConfigurationOnNextKeyFrame = true
                encoder.requestKeyFrame()
                return
            }
            do {
                let configurationData = try updateCodecConfiguration(
                    frame: frame,
                    stream: stream
                )
                guard codecConfigurationGeneration > 0 else {
                    resendConfigurationOnNextKeyFrame = true
                    encoder.requestKeyFrame()
                    return
                }
                let unit = try ROBVideoEncodedAccessUnit(
                    sessionID: stream.sessionID,
                    id: stream.id,
                    codec: .h264,
                    sequence: frame.sequence,
                    captureTimestampUnixMilliseconds: frame.captureTimestampUnixMilliseconds,
                    presentationTimestamp: frame.presentationTimeMicroseconds,
                    duration: Int64(frame.durationMicroseconds),
                    timescale: 1_000_000,
                    isKeyFrame: frame.isKeyFrame,
                    codecConfigurationGeneration: codecConfigurationGeneration,
                    nalLengthFieldBytes: frame.nalUnitHeaderLength,
                    payload: frame.payload
                )
                let accessUnitData = try unit.encodedBinary()
                let mediaSendID = beginMediaSend()
                recordProducedFrame(streamGeneration: streamGeneration)
                if let configurationData {
                    sendFrame(type: .codecConfiguration, data: configurationData) { [weak self] error in
                        guard let self else { return }
                        if let error {
                            self.completeMediaSend(id: mediaSendID, error: error)
                        } else if streamGeneration != self.streamGeneration {
                            // The stream ended while its configuration was in
                            // flight. Do not append the retired access unit.
                            self.completeMediaSend(id: mediaSendID, error: nil)
                        } else {
                            self.sendAccessUnit(
                                accessUnitData,
                                streamGeneration: streamGeneration,
                                mediaSendID: mediaSendID
                            )
                        }
                    }
                } else {
                    sendAccessUnit(
                        accessUnitData,
                        streamGeneration: streamGeneration,
                        mediaSendID: mediaSendID
                    )
                }
            } catch {
                endStream(reason: error.localizedDescription, notifyPeer: true)
            }
        }
    }

    private func updateCodecConfiguration(
        frame: ROBCameraH264EncodedFrame,
        stream: ROBVideoStreamDescriptor
    ) throws -> Data? {
        guard let parameterSets = frame.parameterSets else { return nil }
        let changed = parameterSets != lastParameterSets
            || frame.nalUnitHeaderLength != lastNALLengthFieldBytes
        if changed {
            guard codecConfigurationGeneration < UInt32.max else {
                throw ROBVideoProtocolError.invalidCodecConfiguration
            }
            codecConfigurationGeneration += 1
            lastParameterSets = parameterSets
            lastNALLengthFieldBytes = frame.nalUnitHeaderLength
        }
        guard changed || (resendConfigurationOnNextKeyFrame && frame.isKeyFrame) else {
            return nil
        }

        var sets: [ROBVideoParameterSet] = []
        for bytes in parameterSets {
            guard let first = bytes.first else {
                throw ROBVideoProtocolError.invalidCodecConfiguration
            }
            switch first & 0x1f {
            case 7: sets.append(try ROBVideoParameterSet(kind: .sps, bytes: bytes))
            case 8: sets.append(try ROBVideoParameterSet(kind: .pps, bytes: bytes))
            default: throw ROBVideoProtocolError.invalidCodecConfiguration
            }
        }
        let configuration = try ROBVideoCodecConfiguration(
            sessionID: stream.sessionID,
            id: stream.id,
            codec: .h264,
            generation: codecConfigurationGeneration,
            parameterSets: sets,
            nalLengthFieldBytes: frame.nalUnitHeaderLength
        )
        resendConfigurationOnNextKeyFrame = false
        return try configuration.encodedBinary()
    }

    private func sendAccessUnit(
        _ data: Data,
        streamGeneration: UInt64,
        mediaSendID: UInt64
    ) {
        guard streamGeneration == self.streamGeneration else {
            completeMediaSend(id: mediaSendID, error: nil)
            return
        }
        sendFrame(type: .accessUnit, data: data) { [weak self] error in
            guard let self else { return }
            self.completeMediaSend(id: mediaSendID, error: error)
        }
    }

    private func endStream(reason: String, notifyPeer: Bool) {
        guard let stream = activeStream,
              let controllerID = authenticatedControllerID else { return }
        encoder?.finish()
        encoder = nil
        streamLivenessCheck?.cancel()
        streamLivenessCheck = nil
        activeStream = nil
        subscriptionIsReady = false
        streamGeneration &+= 1
        let endedStreamGeneration = streamGeneration
        encoderOutputPending = false
        codecConfigurationGeneration = 0
        lastParameterSets = nil
        lastNALLengthFieldBytes = nil
        streamLivenessStartedUptime = nil
        lastProducedFrameUptime = nil
        server?.releaseSubscription(id: stream.id, controllerID: controllerID)

        guard notifyPeer,
              let data = try? ROBVideoJSON.encode(ROBVideoStreamEnded(
                sessionID: stream.sessionID,
                id: stream.id,
                reason: reason
              )) else { return }
        sendFrame(type: .streamEnded, data: data) { [weak self] error in
            guard let self,
                  self.streamGeneration == endedStreamGeneration else { return }
            if let error { self.stop(error: error) }
        }
    }

    func cameraDidBecomeUnavailable(cameraID: String) {
        guard activeStream?.cameraID == cameraID else { return }
        endStream(reason: "camera unavailable", notifyPeer: true)
    }

    private func startStreamLivenessChecks(streamGeneration: UInt64) {
        streamLivenessStartedUptime = ProcessInfo.processInfo.systemUptime
        lastProducedFrameUptime = nil
        scheduleStreamLivenessCheck(
            streamGeneration: streamGeneration,
            after: ROBVideoTransport.cameraFrameStallTimeout
        )
    }

    private func scheduleStreamLivenessCheck(
        streamGeneration: UInt64,
        after delay: TimeInterval
    ) {
        streamLivenessCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.stopped,
                  self.streamGeneration == streamGeneration,
                  self.subscriptionIsReady,
                  self.activeStream != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard let reference = self.lastProducedFrameUptime
                    ?? self.streamLivenessStartedUptime else {
                self.endStream(reason: "camera did not produce a frame", notifyPeer: true)
                return
            }
            let remaining = ROBVideoTransport.cameraFrameStallTimeout - (now - reference)
            if remaining <= 0 {
                let reason = self.hasProducedFirstFrame
                    ? "camera frame stream stalled"
                    : "camera did not produce a frame"
                self.endStream(reason: reason, notifyPeer: true)
            } else {
                self.scheduleStreamLivenessCheck(
                    streamGeneration: streamGeneration,
                    after: remaining
                )
            }
        }
        streamLivenessCheck = check
        server?.queue.asyncAfter(deadline: .now() + max(0.1, delay), execute: check)
    }

    private func recordProducedFrame(streamGeneration: UInt64) {
        guard self.streamGeneration == streamGeneration else { return }
        hasProducedFirstFrame = true
        lastProducedFrameUptime = ProcessInfo.processInfo.systemUptime
    }

    private func beginMediaSend() -> UInt64 {
        mediaSendID &+= 1
        let id = mediaSendID
        mediaSendInFlight = true
        mediaSendTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.mediaSendInFlight,
                  self.mediaSendID == id else { return }
            self.stop(error: NWError.posix(.ETIMEDOUT))
        }
        mediaSendTimeout = timeout
        server?.queue.asyncAfter(
            deadline: .now() + ROBVideoTransport.mediaSendTimeout,
            execute: timeout
        )
        return id
    }

    private func completeMediaSend(id: UInt64, error: NWError?) {
        guard id == mediaSendID else { return }
        mediaSendTimeout?.cancel()
        mediaSendTimeout = nil
        mediaSendInFlight = false
        if let error {
            stop(error: error)
        }
    }

    private func sendFrame(
        type: ROBVideoMessageType,
        data: Data,
        completion: @escaping (NWError?) -> Void
    ) {
        guard !stopped else {
            completion(NWError.posix(.ECANCELED))
            return
        }
        guard let server else {
            completion(NWError.posix(.ECANCELED))
            return
        }
        let isMedia = type == .codecConfiguration || type == .accessUnit
        let limit = isMedia
            ? ROBVideoTransport.maximumFramedPayloadBytes
            : ROBVideoTransport.maximumControlPayloadBytes
        guard !data.isEmpty, data.count <= limit else {
            completion(NWError.posix(.EMSGSIZE))
            return
        }
        let message = NWProtocolFramer.Message(definition: ROBVideoFramer.definition)
        message.robVideoMessageType = type
        let context = NWConnection.ContentContext(
            identifier: "ROBVideo.\(type.rawValue)",
            metadata: [message]
        )
        let completionGate = ROBVideoSendCompletionGate(handler: completion)
        let timeoutError = NWError.posix(.ETIMEDOUT)
        let timeout = DispatchWorkItem { [weak self] in
            guard completionGate.complete(timeoutError) else { return }
            self?.stop(error: timeoutError)
        }
        server.queue.asyncAfter(
            deadline: .now() + ROBVideoTransport.sendCompletionTimeout,
            execute: timeout
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                timeout.cancel()
                completionGate.complete(error)
            }
        )
    }
}
