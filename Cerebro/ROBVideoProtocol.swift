import Foundation

enum ROBVideoWireLimits {
    static let maximumAccessUnitBytes = 8 * 1_024 * 1_024
    static let maximumCodecConfigurationBytes = 64 * 1_024
    static let maximumControlMessageBytes = 64 * 1_024
    static let maximumDimension = 4_096
    static let maximumDecodedPixels = 4_096 * 2_160
    static let maximumFramesPerSecond = 240
    static let maximumBitrate: UInt32 = 1_000_000_000
    static let maximumParameterSets = 16
}

enum ROBVideoProtocolError: LocalizedError, Equatable {
    case oversizedControlMessage
    case invalidControlMessage(String)
    case invalidStreamDescriptor
    case invalidCodecConfiguration
    case invalidAccessUnit
    case oversizedCodecConfiguration
    case oversizedAccessUnit
    case malformedBinaryFrame
    case unsupportedVersion(UInt8)

    var errorDescription: String? {
        switch self {
        case .oversizedControlMessage:
            return "The video control message exceeds its hard size limit."
        case .invalidControlMessage(let reason):
            return "The video control message is invalid: \(reason)."
        case .invalidStreamDescriptor:
            return "The negotiated video stream descriptor is invalid."
        case .invalidCodecConfiguration:
            return "The encoded video configuration is invalid."
        case .invalidAccessUnit:
            return "The encoded video access unit is invalid."
        case .oversizedCodecConfiguration:
            return "The encoded video configuration exceeds its hard size limit."
        case .oversizedAccessUnit:
            return "The encoded video access unit exceeds its hard size limit."
        case .malformedBinaryFrame:
            return "The encoded video binary frame is malformed."
        case .unsupportedVersion(let version):
            return "Video protocol version \(version) is unsupported."
        }
    }
}

private struct ROBVideoArbitraryCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func robVideoRejectUnknownKeys<Key>(
    from decoder: Decoder,
    allowed: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: ROBVideoArbitraryCodingKey.self)
    let allowedNames = Set(Key.allCases.map(\.stringValue))
    let unexpected = container.allKeys
        .map(\.stringValue)
        .filter { !allowedNames.contains($0) }
        .sorted()
    guard unexpected.isEmpty else {
        throw ROBVideoProtocolError.invalidControlMessage(
            "unexpected fields: \(unexpected.joined(separator: ", "))"
        )
    }
}

enum ROBVideoCodec: String, Codable, CaseIterable, Hashable {
    case jpeg
    case h264
    case hevc

    fileprivate var binaryValue: UInt8 {
        switch self {
        case .jpeg: return 1
        case .h264: return 2
        case .hevc: return 3
        }
    }

    fileprivate init?(binaryValue: UInt8) {
        switch binaryValue {
        case 1: self = .jpeg
        case 2: self = .h264
        case 3: self = .hevc
        default: return nil
        }
    }
}

enum ROBVideoDeliveryMode: String, Codable, CaseIterable, Hashable {
    case jpegFrames
    case reliableStream
    case quicDatagrams
}

struct ROBVideoCameraDescriptor: Codable, Equatable {
    let id: String
    let name: String
    let supportedCodecs: [ROBVideoCodec]
    let supportedDeliveryModes: [ROBVideoDeliveryMode]
    let maximumWidth: UInt16
    let maximumHeight: UInt16
    let maximumFramesPerSecond: UInt16
    let maximumBitrate: UInt32
}

struct ROBVideoCapabilities: Codable, Equatable {
    static let currentProtocolVersion: UInt8 = 1

    let protocolVersion: UInt8
    let cameras: [ROBVideoCameraDescriptor]

    init(
        protocolVersion: UInt8 = Self.currentProtocolVersion,
        cameras: [ROBVideoCameraDescriptor]
    ) {
        self.protocolVersion = protocolVersion
        self.cameras = cameras
    }
}

struct ROBVideoConstraints: Codable, Equatable {
    let maximumWidth: UInt16
    let maximumHeight: UInt16
    let maximumFramesPerSecond: UInt16
    let maximumBitrate: UInt32

    init(
        maximumWidth: UInt16,
        maximumHeight: UInt16,
        maximumFramesPerSecond: UInt16,
        maximumBitrate: UInt32
    ) {
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.maximumBitrate = maximumBitrate
    }

    var isValid: Bool {
        maximumWidth > 0
            && maximumHeight > 0
            && maximumFramesPerSecond > 0
            && maximumBitrate > 0
            && Int(maximumWidth) <= ROBVideoWireLimits.maximumDimension
            && Int(maximumHeight) <= ROBVideoWireLimits.maximumDimension
            && Int(maximumWidth) * Int(maximumHeight) <= ROBVideoWireLimits.maximumDecodedPixels
            && Int(maximumFramesPerSecond) <= ROBVideoWireLimits.maximumFramesPerSecond
            && maximumBitrate <= ROBVideoWireLimits.maximumBitrate
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case maximumWidth
        case maximumHeight
        case maximumFramesPerSecond
        case maximumBitrate
    }

    init(from decoder: Decoder) throws {
        try robVideoRejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maximumWidth: try container.decode(UInt16.self, forKey: .maximumWidth),
            maximumHeight: try container.decode(UInt16.self, forKey: .maximumHeight),
            maximumFramesPerSecond: try container.decode(
                UInt16.self,
                forKey: .maximumFramesPerSecond
            ),
            maximumBitrate: try container.decode(UInt32.self, forKey: .maximumBitrate)
        )
    }
}

struct ROBVideoSubscriptionRequest: Codable, Equatable {
    static let currentProtocolVersion: UInt8 = 1

    let protocolVersion: UInt8
    let sessionID: UUID
    let id: UUID
    let cameraID: String
    let preferredCodecs: [ROBVideoCodec]
    let constraints: ROBVideoConstraints
    let delivery: ROBVideoDeliveryMode

    init(
        protocolVersion: UInt8 = Self.currentProtocolVersion,
        sessionID: UUID,
        id: UUID,
        cameraID: String,
        preferredCodecs: [ROBVideoCodec],
        constraints: ROBVideoConstraints,
        delivery: ROBVideoDeliveryMode
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.id = id
        self.cameraID = cameraID
        self.preferredCodecs = preferredCodecs
        self.constraints = constraints
        self.delivery = delivery
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case sessionID
        case id
        case cameraID
        case preferredCodecs
        case constraints
        case delivery
    }

    init(from decoder: Decoder) throws {
        try robVideoRejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(UInt8.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            id: try container.decode(UUID.self, forKey: .id),
            cameraID: try container.decode(String.self, forKey: .cameraID),
            preferredCodecs: try container.decode([ROBVideoCodec].self, forKey: .preferredCodecs),
            constraints: try container.decode(ROBVideoConstraints.self, forKey: .constraints),
            delivery: try container.decode(ROBVideoDeliveryMode.self, forKey: .delivery)
        )
    }

    func validationError() -> String? {
        guard protocolVersion == Self.currentProtocolVersion else {
            return "unsupported protocol version"
        }
        guard cameraID == "front" else { return "camera is unavailable" }
        guard !preferredCodecs.isEmpty else { return "codec preference is empty" }
        guard constraints.isValid else { return "constraints are invalid" }
        return nil
    }
}

struct ROBVideoStreamDescriptor: Codable, Equatable {
    let sessionID: UUID
    let id: UUID
    let cameraID: String
    let codec: ROBVideoCodec
    let width: UInt16
    let height: UInt16
    let framesPerSecond: UInt16
    let bitrate: UInt32
    let delivery: ROBVideoDeliveryMode

    init(
        sessionID: UUID,
        id: UUID,
        cameraID: String,
        codec: ROBVideoCodec,
        width: UInt16,
        height: UInt16,
        framesPerSecond: UInt16,
        bitrate: UInt32,
        delivery: ROBVideoDeliveryMode
    ) throws {
        guard width > 0,
              height > 0,
              framesPerSecond > 0,
              bitrate > 0,
              Int(width) <= ROBVideoWireLimits.maximumDimension,
              Int(height) <= ROBVideoWireLimits.maximumDimension,
              Int(width) * Int(height) <= ROBVideoWireLimits.maximumDecodedPixels,
              Int(framesPerSecond) <= ROBVideoWireLimits.maximumFramesPerSecond,
              bitrate <= ROBVideoWireLimits.maximumBitrate else {
            throw ROBVideoProtocolError.invalidStreamDescriptor
        }
        self.sessionID = sessionID
        self.id = id
        self.cameraID = cameraID
        self.codec = codec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.delivery = delivery
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID
        case id
        case cameraID
        case codec
        case width
        case height
        case framesPerSecond
        case bitrate
        case delivery
    }

    init(from decoder: Decoder) throws {
        try robVideoRejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(UUID.self, forKey: .sessionID),
            id: container.decode(UUID.self, forKey: .id),
            cameraID: container.decode(String.self, forKey: .cameraID),
            codec: container.decode(ROBVideoCodec.self, forKey: .codec),
            width: container.decode(UInt16.self, forKey: .width),
            height: container.decode(UInt16.self, forKey: .height),
            framesPerSecond: container.decode(UInt16.self, forKey: .framesPerSecond),
            bitrate: container.decode(UInt32.self, forKey: .bitrate),
            delivery: container.decode(ROBVideoDeliveryMode.self, forKey: .delivery)
        )
    }
}

enum ROBVideoSubscriptionRejection: String, Codable, Error, Equatable {
    case cameraUnavailable
    case codecUnavailable
    case invalidConstraints
    case capacityReached
    case duplicateSubscriptionID
    case deliveryUnavailable
}

enum ROBVideoSubscriptionResponse: Codable, Equatable {
    case accepted(ROBVideoStreamDescriptor)
    case rejected(sessionID: UUID, id: UUID, reason: ROBVideoSubscriptionRejection)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case stream
        case sessionID
        case id
        case reason
    }

    private enum Kind: String, Codable {
        case accepted
        case rejected
    }

    init(from decoder: Decoder) throws {
        try robVideoRejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .accepted:
            guard container.contains(.stream),
                  !container.contains(.sessionID),
                  !container.contains(.id),
                  !container.contains(.reason) else {
                throw ROBVideoProtocolError.invalidControlMessage(
                    "accepted subscription response has contradictory fields"
                )
            }
            self = .accepted(try container.decode(ROBVideoStreamDescriptor.self, forKey: .stream))
        case .rejected:
            guard !container.contains(.stream),
                  container.contains(.sessionID),
                  container.contains(.id),
                  container.contains(.reason) else {
                throw ROBVideoProtocolError.invalidControlMessage(
                    "rejected subscription response has contradictory fields"
                )
            }
            self = .rejected(
                sessionID: try container.decode(UUID.self, forKey: .sessionID),
                id: try container.decode(UUID.self, forKey: .id),
                reason: try container.decode(ROBVideoSubscriptionRejection.self, forKey: .reason)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let stream):
            try container.encode(Kind.accepted, forKey: .type)
            try container.encode(stream, forKey: .stream)
        case .rejected(let sessionID, let id, let reason):
            try container.encode(Kind.rejected, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(id, forKey: .id)
            try container.encode(reason, forKey: .reason)
        }
    }
}

struct ROBVideoUnsubscribeRequest: Codable, Equatable {
    let protocolVersion: UInt8
    let sessionID: UUID
    let id: UUID

    init(protocolVersion: UInt8 = 1, sessionID: UUID, id: UUID) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.id = id
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case sessionID
        case id
    }

    init(from decoder: Decoder) throws {
        try robVideoRejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(UInt8.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            id: try container.decode(UUID.self, forKey: .id)
        )
    }
}

struct ROBVideoReceiverFeedback: Codable, Equatable {
    let protocolVersion: UInt8
    let sessionID: UUID
    let id: UUID
    let estimatedPacketLoss: Double
    let estimatedJitterMilliseconds: Double
    let decodedFramesPerSecond: Double
    let desiredBitrate: UInt32?
    let requestsKeyFrame: Bool

    init(
        protocolVersion: UInt8 = 1,
        sessionID: UUID,
        id: UUID,
        estimatedPacketLoss: Double,
        estimatedJitterMilliseconds: Double,
        decodedFramesPerSecond: Double,
        desiredBitrate: UInt32?,
        requestsKeyFrame: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.id = id
        self.estimatedPacketLoss = estimatedPacketLoss.isFinite
            ? min(1, max(0, estimatedPacketLoss)) : 1
        self.estimatedJitterMilliseconds = estimatedJitterMilliseconds.isFinite
            ? max(0, estimatedJitterMilliseconds) : 0
        self.decodedFramesPerSecond = decodedFramesPerSecond.isFinite
            ? max(0, decodedFramesPerSecond) : 0
        self.desiredBitrate = desiredBitrate
        self.requestsKeyFrame = requestsKeyFrame
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case sessionID
        case id
        case estimatedPacketLoss
        case estimatedJitterMilliseconds
        case decodedFramesPerSecond
        case desiredBitrate
        case requestsKeyFrame
    }

    init(from decoder: Decoder) throws {
        try robVideoRejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(UInt8.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            id: try container.decode(UUID.self, forKey: .id),
            estimatedPacketLoss: try container.decode(Double.self, forKey: .estimatedPacketLoss),
            estimatedJitterMilliseconds: try container.decode(
                Double.self,
                forKey: .estimatedJitterMilliseconds
            ),
            decodedFramesPerSecond: try container.decode(
                Double.self,
                forKey: .decodedFramesPerSecond
            ),
            desiredBitrate: try container.decodeIfPresent(UInt32.self, forKey: .desiredBitrate),
            requestsKeyFrame: try container.decode(Bool.self, forKey: .requestsKeyFrame)
        )
    }
}

struct ROBVideoStreamEnded: Codable, Equatable {
    let protocolVersion: UInt8
    let sessionID: UUID
    let id: UUID
    let reason: String

    init(protocolVersion: UInt8 = 1, sessionID: UUID, id: UUID, reason: String) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.id = id
        self.reason = String(reason.prefix(256))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case sessionID
        case id
        case reason
    }

    init(from decoder: Decoder) throws {
        try robVideoRejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(UInt8.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            id: try container.decode(UUID.self, forKey: .id),
            reason: try container.decode(String.self, forKey: .reason)
        )
    }
}

enum ROBVideoJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= ROBVideoWireLimits.maximumControlMessageBytes else {
            throw ROBVideoProtocolError.oversizedControlMessage
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= ROBVideoWireLimits.maximumControlMessageBytes else {
            throw ROBVideoProtocolError.oversizedControlMessage
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

enum ROBVideoParameterSetKind: UInt8, Codable, Equatable, Hashable {
    case vps = 1
    case sps = 2
    case pps = 3
}

struct ROBVideoParameterSet: Codable, Equatable {
    let kind: ROBVideoParameterSetKind
    let bytes: Data

    init(kind: ROBVideoParameterSetKind, bytes: Data) throws {
        guard !bytes.isEmpty,
              bytes.count <= ROBVideoWireLimits.maximumCodecConfigurationBytes else {
            throw ROBVideoProtocolError.invalidCodecConfiguration
        }
        self.kind = kind
        self.bytes = bytes
    }
}

struct ROBVideoCodecConfiguration: Equatable {
    let sessionID: UUID
    let id: UUID
    let codec: ROBVideoCodec
    let generation: UInt32
    let parameterSets: [ROBVideoParameterSet]
    let nalLengthFieldBytes: UInt8

    init(
        sessionID: UUID,
        id: UUID,
        codec: ROBVideoCodec,
        generation: UInt32,
        parameterSets: [ROBVideoParameterSet],
        nalLengthFieldBytes: UInt8
    ) throws {
        self.sessionID = sessionID
        self.id = id
        self.codec = codec
        self.generation = generation
        self.parameterSets = parameterSets
        self.nalLengthFieldBytes = nalLengthFieldBytes
        try validate()
    }

    func encodedBinary() throws -> Data {
        try validate()
        var payload = Data()
        for parameterSet in parameterSets {
            payload.append(parameterSet.kind.rawValue)
            payload.append(contentsOf: [0, 0, 0])
            payload.appendBigEndian(UInt32(parameterSet.bytes.count))
            payload.append(parameterSet.bytes)
        }
        return ROBVideoBinaryHeader(
            kind: .codecConfiguration,
            codec: codec,
            isKeyFrame: false,
            payloadLength: UInt32(payload.count),
            sessionID: sessionID,
            id: id,
            sequence: 0,
            captureTimestampUnixMilliseconds: 0,
            presentationTimestamp: 0,
            duration: 0,
            timescale: 0,
            configurationGeneration: generation,
            nalLengthFieldBytes: nalLengthFieldBytes,
            parameterSetCount: UInt8(parameterSets.count)
        ).encoded + payload
    }

    init(binary data: Data) throws {
        let header = try ROBVideoBinaryHeader(data)
        guard header.kind == .codecConfiguration,
              header.sequence == 0,
              header.captureTimestampUnixMilliseconds == 0,
              header.presentationTimestamp == 0,
              header.duration == 0,
              header.timescale == 0,
              !header.isKeyFrame,
              header.parameterSetCount > 0,
              Int(header.parameterSetCount) <= ROBVideoWireLimits.maximumParameterSets,
              header.payloadLength <= UInt32(
                ROBVideoWireLimits.maximumCodecConfigurationBytes
                    + (ROBVideoWireLimits.maximumParameterSets * 8)
              ) else {
            throw ROBVideoProtocolError.malformedBinaryFrame
        }
        let payload = Data(data.dropFirst(ROBVideoBinaryHeader.encodedSize))
        var offset = payload.startIndex
        var sets: [ROBVideoParameterSet] = []
        sets.reserveCapacity(Int(header.parameterSetCount))
        for _ in 0..<header.parameterSetCount {
            guard payload.distance(from: offset, to: payload.endIndex) >= 8,
                  let kind = ROBVideoParameterSetKind(rawValue: payload[offset]),
                  payload[payload.index(offset, offsetBy: 1)] == 0,
                  payload[payload.index(offset, offsetBy: 2)] == 0,
                  payload[payload.index(offset, offsetBy: 3)] == 0 else {
                throw ROBVideoProtocolError.malformedBinaryFrame
            }
            let lengthOffset = payload.index(offset, offsetBy: 4)
            let length = Int(payload.readUInt32BigEndian(
                at: payload.distance(from: payload.startIndex, to: lengthOffset)
            ))
            let bytesStart = payload.index(offset, offsetBy: 8)
            guard length > 0,
                  let bytesEnd = payload.index(bytesStart, offsetBy: length, limitedBy: payload.endIndex) else {
                throw ROBVideoProtocolError.malformedBinaryFrame
            }
            sets.append(try ROBVideoParameterSet(kind: kind, bytes: Data(payload[bytesStart..<bytesEnd])))
            offset = bytesEnd
        }
        guard offset == payload.endIndex else { throw ROBVideoProtocolError.malformedBinaryFrame }
        try self.init(
            sessionID: header.sessionID,
            id: header.id,
            codec: header.codec,
            generation: header.configurationGeneration,
            parameterSets: sets,
            nalLengthFieldBytes: header.nalLengthFieldBytes
        )
    }

    private func validate() throws {
        guard codec != .jpeg,
              generation > 0,
              [1, 2, 4].contains(nalLengthFieldBytes),
              !parameterSets.isEmpty,
              parameterSets.count <= ROBVideoWireLimits.maximumParameterSets else {
            throw ROBVideoProtocolError.invalidCodecConfiguration
        }
        let total = parameterSets.reduce(0) { $0 + $1.bytes.count }
        guard total <= ROBVideoWireLimits.maximumCodecConfigurationBytes else {
            throw ROBVideoProtocolError.oversizedCodecConfiguration
        }
        let kinds = Set(parameterSets.map(\.kind))
        switch codec {
        case .h264:
            guard kinds.contains(.sps), kinds.contains(.pps), !kinds.contains(.vps) else {
                throw ROBVideoProtocolError.invalidCodecConfiguration
            }
        case .hevc:
            guard kinds.contains(.vps), kinds.contains(.sps), kinds.contains(.pps) else {
                throw ROBVideoProtocolError.invalidCodecConfiguration
            }
        case .jpeg:
            throw ROBVideoProtocolError.invalidCodecConfiguration
        }
        for set in parameterSets where !Self.parameterSetMatchesCodec(set, codec: codec) {
            throw ROBVideoProtocolError.invalidCodecConfiguration
        }
    }

    private static func parameterSetMatchesCodec(
        _ parameterSet: ROBVideoParameterSet,
        codec: ROBVideoCodec
    ) -> Bool {
        guard let first = parameterSet.bytes.first else { return false }
        switch codec {
        case .h264:
            guard first & 0x80 == 0 else { return false }
            switch parameterSet.kind {
            case .sps: return first & 0x1f == 7
            case .pps: return first & 0x1f == 8
            case .vps: return false
            }
        case .hevc:
            guard parameterSet.bytes.count >= 2,
                  first & 0x80 == 0,
                  parameterSet.bytes[parameterSet.bytes.index(after: parameterSet.bytes.startIndex)]
                    & 0x07 != 0 else { return false }
            let type = (first >> 1) & 0x3f
            switch parameterSet.kind {
            case .vps: return type == 32
            case .sps: return type == 33
            case .pps: return type == 34
            }
        case .jpeg:
            return false
        }
    }
}

struct ROBVideoEncodedAccessUnit: Equatable {
    let sessionID: UUID
    let id: UUID
    let codec: ROBVideoCodec
    let sequence: UInt64
    let captureTimestampUnixMilliseconds: Int64
    let presentationTimestamp: Int64
    let duration: Int64
    let timescale: Int32
    let isKeyFrame: Bool
    let codecConfigurationGeneration: UInt32
    let nalLengthFieldBytes: UInt8
    let payload: Data

    init(
        sessionID: UUID,
        id: UUID,
        codec: ROBVideoCodec,
        sequence: UInt64,
        captureTimestampUnixMilliseconds: Int64,
        presentationTimestamp: Int64,
        duration: Int64,
        timescale: Int32,
        isKeyFrame: Bool,
        codecConfigurationGeneration: UInt32,
        nalLengthFieldBytes: UInt8,
        payload: Data
    ) throws {
        self.sessionID = sessionID
        self.id = id
        self.codec = codec
        self.sequence = sequence
        self.captureTimestampUnixMilliseconds = captureTimestampUnixMilliseconds
        self.presentationTimestamp = presentationTimestamp
        self.duration = duration
        self.timescale = timescale
        self.isKeyFrame = isKeyFrame
        self.codecConfigurationGeneration = codecConfigurationGeneration
        self.nalLengthFieldBytes = nalLengthFieldBytes
        // Rebase Data slices before the fixed-width AVCC walker uses integer
        // offsets; Data may otherwise retain a nonzero startIndex.
        self.payload = Data(payload)
        try validate()
    }

    func encodedBinary() throws -> Data {
        try validate()
        return ROBVideoBinaryHeader(
            kind: .accessUnit,
            codec: codec,
            isKeyFrame: isKeyFrame,
            payloadLength: UInt32(payload.count),
            sessionID: sessionID,
            id: id,
            sequence: sequence,
            captureTimestampUnixMilliseconds: UInt64(captureTimestampUnixMilliseconds),
            presentationTimestamp: UInt64(presentationTimestamp),
            duration: UInt64(duration),
            timescale: UInt32(timescale),
            configurationGeneration: codecConfigurationGeneration,
            nalLengthFieldBytes: nalLengthFieldBytes,
            parameterSetCount: 0
        ).encoded + payload
    }

    init(binary data: Data) throws {
        let header = try ROBVideoBinaryHeader(data)
        guard header.kind == .accessUnit,
              header.parameterSetCount == 0,
              header.captureTimestampUnixMilliseconds <= UInt64(Int64.max),
              header.presentationTimestamp <= UInt64(Int64.max),
              header.duration <= UInt64(Int64.max),
              header.timescale <= UInt32(Int32.max) else {
            throw ROBVideoProtocolError.malformedBinaryFrame
        }
        try self.init(
            sessionID: header.sessionID,
            id: header.id,
            codec: header.codec,
            sequence: header.sequence,
            captureTimestampUnixMilliseconds: Int64(header.captureTimestampUnixMilliseconds),
            presentationTimestamp: Int64(header.presentationTimestamp),
            duration: Int64(header.duration),
            timescale: Int32(header.timescale),
            isKeyFrame: header.isKeyFrame,
            codecConfigurationGeneration: header.configurationGeneration,
            nalLengthFieldBytes: header.nalLengthFieldBytes,
            payload: Data(data.dropFirst(ROBVideoBinaryHeader.encodedSize))
        )
    }

    private func validate() throws {
        guard sequence > 0,
              captureTimestampUnixMilliseconds >= 0,
              presentationTimestamp >= 0,
              duration > 0,
              timescale > 0,
              timescale <= 1_000_000_000,
              duration <= Int64(timescale) * 10,
              !payload.isEmpty else {
            throw ROBVideoProtocolError.invalidAccessUnit
        }
        guard payload.count <= ROBVideoWireLimits.maximumAccessUnitBytes else {
            throw ROBVideoProtocolError.oversizedAccessUnit
        }
        if codec == .jpeg {
            guard isKeyFrame,
                  codecConfigurationGeneration == 0,
                  nalLengthFieldBytes == 0,
                  payload.count >= 4,
                  payload.prefix(2) == Data([0xff, 0xd8]),
                  payload.suffix(2) == Data([0xff, 0xd9]) else {
                throw ROBVideoProtocolError.invalidAccessUnit
            }
            return
        }
        guard codecConfigurationGeneration > 0,
              [1, 2, 4].contains(nalLengthFieldBytes) else {
            throw ROBVideoProtocolError.invalidAccessUnit
        }
        let nalTypes = try parseNALUnitTypes()
        let containsKeyFrame: Bool
        let containsVideoCodingLayer: Bool
        switch codec {
        case .h264:
            containsKeyFrame = nalTypes.contains { $0 == 5 }
            containsVideoCodingLayer = nalTypes.contains { (1...5).contains($0) }
        case .hevc:
            containsKeyFrame = nalTypes.contains { (16...23).contains($0) }
            containsVideoCodingLayer = nalTypes.contains { (0...31).contains($0) }
        case .jpeg:
            containsKeyFrame = false
            containsVideoCodingLayer = false
        }
        guard containsVideoCodingLayer, isKeyFrame == containsKeyFrame else {
            throw ROBVideoProtocolError.invalidAccessUnit
        }
    }

    private func parseNALUnitTypes() throws -> [UInt8] {
        var offset = 0
        var types: [UInt8] = []
        while offset < payload.count {
            let prefixLength = Int(nalLengthFieldBytes)
            guard payload.count - offset >= prefixLength else {
                throw ROBVideoProtocolError.invalidAccessUnit
            }
            var length = 0
            for byte in payload[offset..<(offset + prefixLength)] {
                length = (length << 8) | Int(byte)
            }
            offset += prefixLength
            guard length > 0, length <= payload.count - offset else {
                throw ROBVideoProtocolError.invalidAccessUnit
            }
            let first = payload[offset]
            switch codec {
            case .h264:
                guard first & 0x80 == 0 else {
                    throw ROBVideoProtocolError.invalidAccessUnit
                }
            case .hevc:
                guard length >= 2,
                      first & 0x80 == 0,
                      payload[offset + 1] & 0x07 != 0 else {
                    throw ROBVideoProtocolError.invalidAccessUnit
                }
            case .jpeg:
                throw ROBVideoProtocolError.invalidAccessUnit
            }
            types.append(codec == .h264 ? first & 0x1f : (first >> 1) & 0x3f)
            offset += length
        }
        guard offset == payload.count, !types.isEmpty else {
            throw ROBVideoProtocolError.invalidAccessUnit
        }
        return types
    }
}

private enum ROBVideoBinaryKind: UInt8 {
    case codecConfiguration = 1
    case accessUnit = 2
}

private struct ROBVideoBinaryHeader {
    static let magic: UInt32 = 0x5242_5644 // "RBVD"
    static let version: UInt8 = 1
    static let encodedSize = 92

    let kind: ROBVideoBinaryKind
    let codec: ROBVideoCodec
    let isKeyFrame: Bool
    let payloadLength: UInt32
    let sessionID: UUID
    let id: UUID
    let sequence: UInt64
    let captureTimestampUnixMilliseconds: UInt64
    let presentationTimestamp: UInt64
    let duration: UInt64
    let timescale: UInt32
    let configurationGeneration: UInt32
    let nalLengthFieldBytes: UInt8
    let parameterSetCount: UInt8

    init(
        kind: ROBVideoBinaryKind,
        codec: ROBVideoCodec,
        isKeyFrame: Bool,
        payloadLength: UInt32,
        sessionID: UUID,
        id: UUID,
        sequence: UInt64,
        captureTimestampUnixMilliseconds: UInt64,
        presentationTimestamp: UInt64,
        duration: UInt64,
        timescale: UInt32,
        configurationGeneration: UInt32,
        nalLengthFieldBytes: UInt8,
        parameterSetCount: UInt8
    ) {
        self.kind = kind
        self.codec = codec
        self.isKeyFrame = isKeyFrame
        self.payloadLength = payloadLength
        self.sessionID = sessionID
        self.id = id
        self.sequence = sequence
        self.captureTimestampUnixMilliseconds = captureTimestampUnixMilliseconds
        self.presentationTimestamp = presentationTimestamp
        self.duration = duration
        self.timescale = timescale
        self.configurationGeneration = configurationGeneration
        self.nalLengthFieldBytes = nalLengthFieldBytes
        self.parameterSetCount = parameterSetCount
    }

    init(_ data: Data) throws {
        // A Data slice may retain a nonzero startIndex. Rebase before reading
        // fixed wire offsets so every checked subscript is safe and absolute.
        let bytes = Data(data)
        guard bytes.count >= Self.encodedSize,
              bytes.readUInt32BigEndian(at: 0) == Self.magic else {
            throw ROBVideoProtocolError.malformedBinaryFrame
        }
        let version = bytes[4]
        guard version == Self.version else { throw ROBVideoProtocolError.unsupportedVersion(version) }
        guard let kind = ROBVideoBinaryKind(rawValue: bytes[5]),
              let codec = ROBVideoCodec(binaryValue: bytes[6]),
              bytes.readUInt16BigEndian(at: 8) == UInt16(Self.encodedSize),
              bytes.readUInt16BigEndian(at: 10) == 0,
              bytes.readUInt16BigEndian(at: 90) == 0,
              let sessionID = UUID(robVideoProtocolBytes: Data(bytes[16..<32])),
              let id = UUID(robVideoProtocolBytes: Data(bytes[32..<48])) else {
            throw ROBVideoProtocolError.malformedBinaryFrame
        }
        let flags = bytes[7]
        guard flags & 0xfe == 0 else { throw ROBVideoProtocolError.malformedBinaryFrame }
        let payloadLength = bytes.readUInt32BigEndian(at: 12)
        guard payloadLength <= UInt32(ROBVideoWireLimits.maximumAccessUnitBytes),
              bytes.count == Self.encodedSize + Int(payloadLength) else {
            throw ROBVideoProtocolError.malformedBinaryFrame
        }
        self.kind = kind
        self.codec = codec
        isKeyFrame = flags & 1 == 1
        self.payloadLength = payloadLength
        self.sessionID = sessionID
        self.id = id
        sequence = bytes.readUInt64BigEndian(at: 48)
        captureTimestampUnixMilliseconds = bytes.readUInt64BigEndian(at: 56)
        presentationTimestamp = bytes.readUInt64BigEndian(at: 64)
        duration = bytes.readUInt64BigEndian(at: 72)
        timescale = bytes.readUInt32BigEndian(at: 80)
        configurationGeneration = bytes.readUInt32BigEndian(at: 84)
        nalLengthFieldBytes = bytes[88]
        parameterSetCount = bytes[89]
    }

    var encoded: Data {
        var data = Data()
        data.reserveCapacity(Self.encodedSize)
        data.appendBigEndian(Self.magic)
        data.append(Self.version)
        data.append(kind.rawValue)
        data.append(codec.binaryValue)
        data.append(isKeyFrame ? 1 : 0)
        data.appendBigEndian(UInt16(Self.encodedSize))
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(payloadLength)
        data.append(sessionID.robVideoProtocolBytes)
        data.append(id.robVideoProtocolBytes)
        data.appendBigEndian(sequence)
        data.appendBigEndian(captureTimestampUnixMilliseconds)
        data.appendBigEndian(presentationTimestamp)
        data.appendBigEndian(duration)
        data.appendBigEndian(timescale)
        data.appendBigEndian(configurationGeneration)
        data.append(nalLengthFieldBytes)
        data.append(parameterSetCount)
        data.appendBigEndian(UInt16(0))
        return data
    }
}

private extension UUID {
    var robVideoProtocolBytes: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    init?(robVideoProtocolBytes data: Data) {
        guard data.count == 16 else { return nil }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        self.init(uuid: value)
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

    func readUInt16BigEndian(at offset: Int) -> UInt16 {
        let index = startIndex + offset
        return (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    func readUInt32BigEndian(at offset: Int) -> UInt32 {
        let index = startIndex + offset
        var value: UInt32 = 0
        for byte in self[index..<(index + 4)] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    func readUInt64BigEndian(at offset: Int) -> UInt64 {
        let index = startIndex + offset
        var value: UInt64 = 0
        for byte in self[index..<(index + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
