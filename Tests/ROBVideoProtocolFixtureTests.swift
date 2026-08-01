import Foundation

private enum FixtureFailure: Error {
    case assertion(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure.assertion(message) }
}

private func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw FixtureFailure.assertion(message)
    } catch is FixtureFailure {
        throw FixtureFailure.assertion(message)
    } catch {
        return
    }
}

private func expectProtocolError(
    _ expected: ROBVideoProtocolError,
    _ message: String,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        throw FixtureFailure.assertion(message)
    } catch let error as ROBVideoProtocolError {
        try expect(error == expected, "\(message); received \(error) instead of \(expected)")
    } catch {
        throw FixtureFailure.assertion("\(message); received unexpected error \(error)")
    }
}

private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let streamID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

private func testControlJSONUsesPlainUUIDs() throws {
    let request = ROBVideoSubscriptionRequest(
        sessionID: sessionID,
        id: streamID,
        cameraID: "front",
        preferredCodecs: [.h264],
        constraints: ROBVideoConstraints(
            maximumWidth: 960,
            maximumHeight: 540,
            maximumFramesPerSecond: 20,
            maximumBitrate: 1_500_000
        ),
        delivery: .reliableStream
    )
    let data = try ROBVideoJSON.encode(request)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    try expect(object["sessionID"] is String, "sessionID must encode as one JSON string")
    try expect(object["id"] is String, "subscription ID must encode as one JSON string")
    let decoded = try ROBVideoJSON.decode(ROBVideoSubscriptionRequest.self, from: data)
    try expect(decoded == request, "subscription JSON did not round-trip")

    var objectWithUnknownField = object
    objectWithUnknownField["futurePrivilege"] = true
    let unknownFieldData = try JSONSerialization.data(withJSONObject: objectWithUnknownField)
    try expectProtocolError(
        .invalidControlMessage("unexpected fields: futurePrivilege"),
        "unknown subscription fields must be rejected"
    ) {
        _ = try ROBVideoJSON.decode(
            ROBVideoSubscriptionRequest.self,
            from: unknownFieldData
        )
    }

    let hostileFeedback = Data("""
    {
      "protocolVersion": 1,
      "sessionID": "\(sessionID.uuidString)",
      "id": "\(streamID.uuidString)",
      "estimatedPacketLoss": 7.5,
      "estimatedJitterMilliseconds": -42,
      "decodedFramesPerSecond": -5,
      "desiredBitrate": 900000,
      "requestsKeyFrame": false
    }
    """.utf8)
    let feedback = try ROBVideoJSON.decode(ROBVideoReceiverFeedback.self, from: hostileFeedback)
    try expect(feedback.estimatedPacketLoss == 1, "decoded packet loss was not clamped")
    try expect(feedback.estimatedJitterMilliseconds == 0, "decoded jitter was not clamped")
    try expect(feedback.decodedFramesPerSecond == 0, "decoded frame rate was not clamped")

    let invalidDescriptor = Data("""
    {
      "sessionID": "\(sessionID.uuidString)",
      "id": "\(streamID.uuidString)",
      "cameraID": "front",
      "codec": "h264",
      "width": 0,
      "height": 540,
      "framesPerSecond": 20,
      "bitrate": 1500000,
      "delivery": "reliableStream"
    }
    """.utf8)
    try expectProtocolError(
        .invalidStreamDescriptor,
        "decoded stream descriptors must use constructor validation"
    ) {
        _ = try ROBVideoJSON.decode(ROBVideoStreamDescriptor.self, from: invalidDescriptor)
    }

    let longReason = String(repeating: "x", count: 300)
    let endedData = Data("""
    {
      "protocolVersion": 1,
      "sessionID": "\(sessionID.uuidString)",
      "id": "\(streamID.uuidString)",
      "reason": "\(longReason)"
    }
    """.utf8)
    let ended = try ROBVideoJSON.decode(ROBVideoStreamEnded.self, from: endedData)
    try expect(ended.reason.count == 256, "decoded stream-ended reason was not bounded")
}

private func testH264ConfigurationBinaryFixture() throws {
    let configuration = try ROBVideoCodecConfiguration(
        sessionID: sessionID,
        id: streamID,
        codec: .h264,
        generation: 1,
        parameterSets: [
            try ROBVideoParameterSet(kind: .sps, bytes: Data([0x67, 0x42, 0x00, 0x1f])),
            try ROBVideoParameterSet(kind: .pps, bytes: Data([0x68, 0xce, 0x06, 0xe2])),
        ],
        nalLengthFieldBytes: 4
    )
    let encoded = try configuration.encodedBinary()
    try expect(Array(encoded.prefix(4)) == Array("RBVD".utf8), "wrong media magic")
    try expect(encoded[4] == 1, "wrong media protocol version")
    try expect(encoded[5] == 1, "wrong configuration message kind")
    try expect(encoded[6] == 2, "wrong H.264 codec value")
    try expect(encoded.count == 92 + 24, "wrong bounded configuration frame length")

    let golden = Data([
        0x52, 0x42, 0x56, 0x44, 0x01, 0x01, 0x02, 0x00,
        0x00, 0x5c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18,
        0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
        0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x99, 0x99, 0x99, 0x99, 0x88, 0x88, 0x77, 0x77,
        0x66, 0x66, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x04, 0x02, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x67, 0x42, 0x00, 0x1f,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04,
        0x68, 0xce, 0x06, 0xe2,
    ])
    try expect(encoded == golden, "configuration bytes do not match the literal RBVD vector")
    let decoded = try ROBVideoCodecConfiguration(binary: encoded)
    try expect(decoded == configuration, "configuration binary did not round-trip")

    var malformed = encoded
    malformed[10] = 1
    try expectThrows("nonzero reserved header bytes must be rejected") {
        _ = try ROBVideoCodecConfiguration(binary: malformed)
    }

    var malformedSetReserved = encoded
    malformedSetReserved[93] = 1
    try expectThrows("nonzero parameter-set reserved bytes must be rejected") {
        _ = try ROBVideoCodecConfiguration(binary: malformedSetReserved)
    }

    var mismatchedSetCount = encoded
    mismatchedSetCount[89] = 3
    try expectThrows("parameter-set count mismatch must be rejected") {
        _ = try ROBVideoCodecConfiguration(binary: mismatchedSetCount)
    }

    let sixteenSets = try (0..<16).map { index in
        try ROBVideoParameterSet(
            kind: index.isMultiple(of: 2) ? .sps : .pps,
            bytes: Data([index.isMultiple(of: 2) ? 0x67 : 0x68])
        )
    }
    _ = try ROBVideoCodecConfiguration(
        sessionID: sessionID,
        id: streamID,
        codec: .h264,
        generation: 1,
        parameterSets: sixteenSets,
        nalLengthFieldBytes: 4
    )
    try expectProtocolError(
        .invalidCodecConfiguration,
        "more than 16 parameter sets must be rejected"
    ) {
        _ = try ROBVideoCodecConfiguration(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            generation: 1,
            parameterSets: sixteenSets + [
                try ROBVideoParameterSet(kind: .sps, bytes: Data([0x67]))
            ],
            nalLengthFieldBytes: 4
        )
    }

    var maximumSPS = Data([0x67])
    maximumSPS.append(Data(repeating: 0, count: 65_534))
    _ = try ROBVideoCodecConfiguration(
        sessionID: sessionID,
        id: streamID,
        codec: .h264,
        generation: 1,
        parameterSets: [
            try ROBVideoParameterSet(kind: .sps, bytes: maximumSPS),
            try ROBVideoParameterSet(kind: .pps, bytes: Data([0x68])),
        ],
        nalLengthFieldBytes: 4
    )
    maximumSPS.append(0)
    try expectProtocolError(
        .oversizedCodecConfiguration,
        "raw codec configuration above 64 KiB must be rejected"
    ) {
        _ = try ROBVideoCodecConfiguration(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            generation: 1,
            parameterSets: [
                try ROBVideoParameterSet(kind: .sps, bytes: maximumSPS),
                try ROBVideoParameterSet(kind: .pps, bytes: Data([0x68])),
            ],
            nalLengthFieldBytes: 4
        )
    }
}

private func testH264AccessUnitBinaryFixture() throws {
    let avccIDR = Data([0, 0, 0, 2, 0x65, 0x88])
    let accessUnit = try ROBVideoEncodedAccessUnit(
        sessionID: sessionID,
        id: streamID,
        codec: .h264,
        sequence: 7,
        captureTimestampUnixMilliseconds: 1_785_552_000_100,
        presentationTimestamp: 300_000,
        duration: 50_000,
        timescale: 1_000_000,
        isKeyFrame: true,
        codecConfigurationGeneration: 1,
        nalLengthFieldBytes: 4,
        payload: avccIDR
    )
    let encoded = try accessUnit.encodedBinary()
    try expect(encoded[5] == 2, "wrong access-unit message kind")
    try expect(encoded[7] == 1, "key-frame flag is missing")
    try expect(encoded.count == 92 + avccIDR.count, "wrong access-unit frame length")
    let golden = Data([
        0x52, 0x42, 0x56, 0x44, 0x01, 0x02, 0x02, 0x01,
        0x00, 0x5c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06,
        0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
        0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x99, 0x99, 0x99, 0x99, 0x88, 0x88, 0x77, 0x77,
        0x66, 0x66, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07,
        0x00, 0x00, 0x01, 0x9f, 0xbb, 0x31, 0x54, 0x64,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x93, 0xe0,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x50,
        0x00, 0x0f, 0x42, 0x40, 0x00, 0x00, 0x00, 0x01,
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x65, 0x88,
    ])
    try expect(encoded == golden, "access-unit bytes do not match the literal RBVD vector")
    let decoded = try ROBVideoEncodedAccessUnit(binary: encoded)
    try expect(decoded == accessUnit, "access-unit binary did not round-trip")

    var padded = Data([0xaa])
    padded.append(encoded)
    padded.append(0xbb)
    let sliced = padded[padded.index(after: padded.startIndex)..<padded.index(before: padded.endIndex)]
    try expect(sliced.startIndex != 0, "fixture did not create a nonzero-index Data slice")
    let decodedSlice = try ROBVideoEncodedAccessUnit(binary: sliced)
    try expect(decodedSlice == accessUnit, "nonzero-index Data slice did not decode")

    try expectThrows("a claimed H.264 key frame without an IDR must be rejected") {
        _ = try ROBVideoEncodedAccessUnit(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            sequence: 8,
            captureTimestampUnixMilliseconds: 1,
            presentationTimestamp: 1,
            duration: 1,
            timescale: 1_000,
            isKeyFrame: true,
            codecConfigurationGeneration: 1,
            nalLengthFieldBytes: 4,
            payload: Data([0, 0, 0, 2, 0x41, 0x88])
        )
    }


    try expectThrows("an H.264 IDR marked as a delta frame must be rejected") {
        _ = try ROBVideoEncodedAccessUnit(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            sequence: 8,
            captureTimestampUnixMilliseconds: 1,
            presentationTimestamp: 1,
            duration: 1,
            timescale: 1_000,
            isKeyFrame: false,
            codecConfigurationGeneration: 1,
            nalLengthFieldBytes: 4,
            payload: Data([0, 0, 0, 2, 0x65, 0x88])
        )
    }

    try expectThrows("an access unit without a VCL NAL must be rejected") {
        _ = try ROBVideoEncodedAccessUnit(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            sequence: 8,
            captureTimestampUnixMilliseconds: 1,
            presentationTimestamp: 1,
            duration: 1,
            timescale: 1_000,
            isKeyFrame: false,
            codecConfigurationGeneration: 1,
            nalLengthFieldBytes: 4,
            payload: Data([0, 0, 0, 2, 0x67, 0x42])
        )
    }
}

private func testHardLimitsAndMalformedFrames() throws {
    let oversized = Data(repeating: 0xaa, count: ROBVideoWireLimits.maximumAccessUnitBytes + 1)
    try expectProtocolError(
        .oversizedAccessUnit,
        "oversized access units must be rejected before NAL parsing"
    ) {
        _ = try ROBVideoEncodedAccessUnit(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            sequence: 1,
            captureTimestampUnixMilliseconds: 1,
            presentationTimestamp: 1,
            duration: 1,
            timescale: 1_000,
            isKeyFrame: false,
            codecConfigurationGeneration: 1,
            nalLengthFieldBytes: 4,
            payload: oversized
        )
    }

    try expectThrows("Annex-B H.264 must not be accepted as AVCC") {
        _ = try ROBVideoEncodedAccessUnit(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            sequence: 1,
            captureTimestampUnixMilliseconds: 1,
            presentationTimestamp: 1,
            duration: 1,
            timescale: 1_000,
            isKeyFrame: true,
            codecConfigurationGeneration: 1,
            nalLengthFieldBytes: 4,
            payload: Data([0, 0, 0, 1, 0x65, 0])
        )
    }

    var length256Payload = Data([0, 0, 1, 0, 0x41])
    length256Payload.append(Data(repeating: 0, count: 255))
    _ = try ROBVideoEncodedAccessUnit(
        sessionID: sessionID,
        id: streamID,
        codec: .h264,
        sequence: 1,
        captureTimestampUnixMilliseconds: 1,
        presentationTimestamp: 1,
        duration: 1,
        timescale: 1_000,
        isKeyFrame: false,
        codecConfigurationGeneration: 1,
        nalLengthFieldBytes: 4,
        payload: length256Payload
    )

    try expectThrows("timescales above the shared hard maximum must be rejected") {
        _ = try ROBVideoEncodedAccessUnit(
            sessionID: sessionID,
            id: streamID,
            codec: .h264,
            sequence: 1,
            captureTimestampUnixMilliseconds: 1,
            presentationTimestamp: 1,
            duration: 1,
            timescale: 1_000_000_001,
            isKeyFrame: true,
            codecConfigurationGeneration: 1,
            nalLengthFieldBytes: 4,
            payload: Data([0, 0, 0, 2, 0x65, 0x88])
        )
    }

    _ = try ROBVideoEncodedAccessUnit(
        sessionID: sessionID,
        id: streamID,
        codec: .h264,
        sequence: 1,
        captureTimestampUnixMilliseconds: 1,
        presentationTimestamp: 1,
        duration: 1,
        timescale: 1_000_000_000,
        isKeyFrame: true,
        codecConfigurationGeneration: 1,
        nalLengthFieldBytes: 4,
        payload: Data([0, 0, 0, 2, 0x65, 0x88])
    )

    let valid = try ROBVideoEncodedAccessUnit(
        sessionID: sessionID,
        id: streamID,
        codec: .h264,
        sequence: 1,
        captureTimestampUnixMilliseconds: 1,
        presentationTimestamp: 1,
        duration: 1,
        timescale: 1_000,
        isKeyFrame: true,
        codecConfigurationGeneration: 1,
        nalLengthFieldBytes: 4,
        payload: Data([0, 0, 0, 2, 0x65, 0x88])
    )
    var truncated = try valid.encodedBinary()
    truncated.removeLast()
    try expectThrows("truncated binary media must be rejected") {
        _ = try ROBVideoEncodedAccessUnit(binary: truncated)
    }


    var unsupportedVersion = try valid.encodedBinary()
    unsupportedVersion[4] = 2
    try expectProtocolError(
        .unsupportedVersion(2),
        "unsupported RBVD versions must be reported exactly"
    ) {
        _ = try ROBVideoEncodedAccessUnit(binary: unsupportedVersion)
    }

    var reservedFlags = try valid.encodedBinary()
    reservedFlags[7] |= 0x80
    try expectProtocolError(
        .malformedBinaryFrame,
        "reserved RBVD flag bits must be rejected"
    ) {
        _ = try ROBVideoEncodedAccessUnit(binary: reservedFlags)
    }

    var trailing = try valid.encodedBinary()
    trailing.append(0)
    try expectProtocolError(
        .malformedBinaryFrame,
        "trailing RBVD bytes must be rejected"
    ) {
        _ = try ROBVideoEncodedAccessUnit(binary: trailing)
    }

    var oversizedBinary = Data((try valid.encodedBinary()).prefix(92))
    oversizedBinary.replaceSubrange(12..<16, with: [0x00, 0x20, 0x00, 0x01])
    oversizedBinary.append(Data(
        repeating: 0,
        count: ROBVideoWireLimits.maximumAccessUnitBytes + 1
    ))
    try expectProtocolError(
        .malformedBinaryFrame,
        "declared binary access units above 2 MiB must be rejected"
    ) {
        _ = try ROBVideoEncodedAccessUnit(binary: oversizedBinary)
    }
}

private func testHEVCHeaderValidation() throws {
    _ = try ROBVideoCodecConfiguration(
        sessionID: sessionID,
        id: streamID,
        codec: .hevc,
        generation: 1,
        parameterSets: [
            try ROBVideoParameterSet(kind: .vps, bytes: Data([0x40, 0x01])),
            try ROBVideoParameterSet(kind: .sps, bytes: Data([0x42, 0x01])),
            try ROBVideoParameterSet(kind: .pps, bytes: Data([0x44, 0x01])),
        ],
        nalLengthFieldBytes: 4
    )
    _ = try ROBVideoEncodedAccessUnit(
        sessionID: sessionID,
        id: streamID,
        codec: .hevc,
        sequence: 1,
        captureTimestampUnixMilliseconds: 1,
        presentationTimestamp: 1,
        duration: 1,
        timescale: 1_000,
        isKeyFrame: true,
        codecConfigurationGeneration: 1,
        nalLengthFieldBytes: 4,
        payload: Data([0, 0, 0, 2, 0x26, 0x01])
    )

    try expectProtocolError(
        .invalidAccessUnit,
        "HEVC NAL units shorter than the two-byte header must be rejected"
    ) {
        _ = try ROBVideoEncodedAccessUnit(
            sessionID: sessionID,
            id: streamID,
            codec: .hevc,
            sequence: 1,
            captureTimestampUnixMilliseconds: 1,
            presentationTimestamp: 1,
            duration: 1,
            timescale: 1_000,
            isKeyFrame: true,
            codecConfigurationGeneration: 1,
            nalLengthFieldBytes: 4,
            payload: Data([0, 0, 0, 1, 0x26])
        )
    }
}

@main
private enum ROBVideoProtocolFixtureRunner {
    static func main() {
        do {
            try testControlJSONUsesPlainUUIDs()
            try testH264ConfigurationBinaryFixture()
            try testH264AccessUnitBinaryFixture()
            try testHardLimitsAndMalformedFrames()
            try testHEVCHeaderValidation()
            print("ROBVideoProtocol fixtures passed")
        } catch {
            fputs("ROBVideoProtocol fixture failure: \(error)\n", stderr)
            exit(1)
        }
    }
}
