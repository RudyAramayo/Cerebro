import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let detail): return detail
        }
    }
}

@main
struct ROBArmControlProtocolFixtureTests {
    private static let now: Int64 = 1_725_000_000_000
    private static let controllerID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
    private static let sessionID = UUID(
        uuidString: "12345678-1234-5678-9abc-def012345678"
    )!
    private static let authorityID = UUID(
        uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
    )!

    static func main() throws {
        try measuredStateRoundTripAndModes()
        try authorityIntentAndStateRoundTrips()
        try targetIntentRoundTripAndBounds()
        try targetFreshnessAndStrictSchema()
        try holdIntentRoundTripAndBounds()
        try dispositionExecutionAndTerminalInvariants()
        try failClosedRoutingClassification()
        try targetAuthorityAndIdentityGate()
        try executionPreflightGate()
        print("ROB arm-control/2 execution protocol fixtures passed")
    }

    private static func measuredStateRoundTripAndModes() throws {
        let state = ROBArmMeasuredState(
            messageID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            arm: .left,
            sequence: 42,
            sampledAtUnixMilliseconds: now,
            sampleAgeMilliseconds: 2.5,
            positionsRadians: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7],
            velocitiesRadiansPerSecond: Array(repeating: 0, count: 7),
            currents: [1, 2, 3, 4, 5, 6, 7],
            statuses: Array(repeating: 1, count: 7),
            modes: [0, 1, 2, 3, 4, 2, 2]
        )
        let data = try ROBArmControlWireCodec.encode(state)
        guard case .measuredState(let decoded)? = try ROBArmControlWireCodec.decode(data) else {
            throw FixtureFailure.failed("Measured state did not decode")
        }
        try expect(decoded == state, "Measured state changed during round-trip")
        try expect(decoded.modes == state.modes, "Measured joint modes were not preserved")

        let object = try jsonObject(data)
        try expect(
            object["protocol"] as? String == "rob-arm-control/2",
            "Arm protocol marker was not v2"
        )
        try expect(object["schema_version"] as? Int == 2, "Arm schema was not v2")
        try expect(object["type"] as? String == "measured_state", "Measured type changed")

        let invalidMode = ROBArmMeasuredState(
            arm: .right,
            sequence: 1,
            sampledAtUnixMilliseconds: now,
            sampleAgeMilliseconds: 0,
            positionsRadians: Array(repeating: 0, count: 7),
            velocitiesRadiansPerSecond: Array(repeating: 0, count: 7),
            currents: Array(repeating: 0, count: 7),
            statuses: Array(repeating: 0, count: 7),
            modes: [2, 2, 2, 2, 2, 2, 5]
        )
        try expectThrows("An out-of-range measured joint mode was encoded") {
            _ = try ROBArmControlWireCodec.encode(invalidMode)
        }

        var unexpected = object
        unexpected["execute"] = true
        try expectThrows("An unknown measured-state field was accepted") {
            _ = try ROBArmControlWireCodec.decode(try jsonData(unexpected))
        }
    }

    private static func authorityIntentAndStateRoundTrips() throws {
        let requestID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let acquire = ROBArmAuthorityIntentEnvelope(
            messageID: requestID,
            senderID: controllerID,
            sessionID: sessionID,
            sequence: 5,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 60_000,
            arm: .right,
            operation: .acquire
        )
        let acquireData = try ROBArmControlWireCodec.encode(acquire)
        guard case .authorityIntent(let decodedAcquire)? = try ROBArmControlWireCodec.decode(
            acquireData,
            nowUnixMilliseconds: now
        ) else {
            throw FixtureFailure.failed("Authority acquire did not decode")
        }
        try expect(decodedAcquire == acquire, "Authority acquire changed during round-trip")

        let release = ROBArmAuthorityIntentEnvelope(
            senderID: controllerID,
            sessionID: sessionID,
            sequence: 6,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 250,
            arm: .right,
            operation: .release
        )
        let releaseData = try ROBArmControlWireCodec.encode(release)
        guard case .authorityIntent(let decodedRelease)? = try ROBArmControlWireCodec.decode(
            releaseData,
            nowUnixMilliseconds: now
        ) else {
            throw FixtureFailure.failed("Authority release did not decode")
        }
        try expect(decodedRelease == release, "Authority release changed during round-trip")

        let state = ROBArmAuthorityStateEnvelope(
            messageID: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            requestMessageID: requestID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .right,
            state: .granted,
            authorityID: authorityID,
            expiresAtUnixMilliseconds: now + 60_000,
            detail: "Supervised right-arm authority granted.",
            baselinePositionsRadians: [0, 0.1, -0.1, 0.2, -0.2, 0.3, 0],
            baselineSequence: 91,
            modes: Array(repeating: 2, count: 7)
        )
        let stateData = try ROBArmControlWireCodec.encode(state)
        guard case .authorityState(let decodedState)? = try ROBArmControlWireCodec.decode(
            stateData
        ) else {
            throw FixtureFailure.failed("Granted authority state did not decode")
        }
        try expect(decodedState == state, "Authority state changed during round-trip")
        try expect(decodedState.authorityID == authorityID, "Authority grant ID changed")
        try expect(
            decodedState.baselinePositionsRadians == state.baselinePositionsRadians,
            "Measured authority baseline changed"
        )
        try expect(
            decodedState.modes == Array(repeating: 2, count: 7),
            "Authority state lost position modes"
        )

        let incompleteGrant = ROBArmAuthorityStateEnvelope(
            requestMessageID: requestID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .right,
            state: .granted,
            authorityID: nil,
            expiresAtUnixMilliseconds: now + 60_000,
            detail: "Incomplete grant.",
            baselinePositionsRadians: Array(repeating: 0, count: 7),
            baselineSequence: 1,
            modes: Array(repeating: 2, count: 7)
        )
        try expectThrows("A granted authority state without an authority ID was encoded") {
            _ = try ROBArmControlWireCodec.encode(incompleteGrant)
        }

        let shortAcquire = ROBArmAuthorityIntentEnvelope(
            senderID: controllerID,
            sessionID: sessionID,
            sequence: 7,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 59_999,
            arm: .left,
            operation: .acquire
        )
        try expectThrows("An authority acquisition shorter than one minute was encoded") {
            _ = try ROBArmControlWireCodec.encode(shortAcquire)
        }

        var unexpected = try jsonObject(acquireData)
        unexpected["grant_without_confirmation"] = true
        try expectThrows("An unknown authority field was accepted") {
            _ = try ROBArmControlWireCodec.decode(
                try jsonData(unexpected),
                nowUnixMilliseconds: now
            )
        }
    }

    private static func targetIntentRoundTripAndBounds() throws {
        let target = makeTarget(
            messageID: UUID(uuidString: "44444444-5555-6666-7777-888888888888")!,
            sequence: 9,
            arm: .right,
            positions: [0, 0.05, -0.05, 0.08, -0.08, 0.1, 0],
            duration: 0.8
        )
        let data = try ROBArmControlWireCodec.encode(target, nowUnixMilliseconds: now)
        guard case .targetIntent(let decoded)? = try ROBArmControlWireCodec.decode(
            data,
            nowUnixMilliseconds: now
        ) else {
            throw FixtureFailure.failed("Target intent did not decode")
        }
        try expect(decoded == target, "Target intent changed during round-trip")
        try expect(decoded.senderID == controllerID, "Controller identity changed")
        try expect(decoded.sessionID == sessionID, "Authenticated session binding changed")
        try expect(decoded.authorityID == authorityID, "Authority binding changed")
        try expect(decoded.deadManHeld, "Held dead-man state changed")

        let upperBounds = ROBArmControlProtocol.targetJointBoundsRadians.map(\.upperBound)
        let lowerBounds = ROBArmControlProtocol.targetJointBoundsRadians.map(\.lowerBound)
        for positions in [upperBounds, lowerBounds] {
            let boundary = makeTarget(sequence: 10, positions: positions, duration: 10)
            try expect(
                boundary.boundsValidationError == nil,
                "A calibrated B1 boundary target was rejected"
            )
        }
        for jointIndex in 0 ..< ROBArmControlProtocol.jointCount {
            var above = Array(repeating: 0.0, count: ROBArmControlProtocol.jointCount)
            above[jointIndex] = upperBounds[jointIndex] + 0.0001
            try expect(
                makeTarget(sequence: 11, positions: above).boundsValidationError != nil,
                "Joint \(jointIndex + 1) exceeded its upper B1 bound"
            )
            var below = Array(repeating: 0.0, count: ROBArmControlProtocol.jointCount)
            below[jointIndex] = lowerBounds[jointIndex] - 0.0001
            try expect(
                makeTarget(sequence: 12, positions: below).boundsValidationError != nil,
                "Joint \(jointIndex + 1) exceeded its lower B1 bound"
            )
        }

        let deadManReleased = makeTarget(sequence: 13, deadManHeld: false)
        try expect(deadManReleased.boundsValidationError != nil, "Released dead-man was valid")
        try expectThrows("A target without a held dead-man was encoded") {
            _ = try ROBArmControlWireCodec.encode(
                deadManReleased,
                nowUnixMilliseconds: now
            )
        }

        let shortDuration = makeTarget(sequence: 14, duration: 0.649)
        try expect(shortDuration.boundsValidationError != nil, "Short duration was valid")
        let longLease = makeTarget(sequence: 15, leaseMilliseconds: 1_501)
        try expect(longLease.boundsValidationError != nil, "Oversized target lease was valid")
    }

    private static func targetFreshnessAndStrictSchema() throws {
        let expired = makeTarget(
            sequence: 20,
            issuedAtUnixMilliseconds: now - 1_001,
            leaseMilliseconds: 1_000
        )
        let encoder = JSONEncoder()
        let expiredData = try encoder.encode(expired)
        try expectThrows("Expired target passed the freshness gate") {
            _ = try ROBArmControlWireCodec.decode(expiredData, nowUnixMilliseconds: now)
        }
        guard case .targetIntent? = try ROBArmControlWireCodec.decode(
            expiredData,
            nowUnixMilliseconds: now,
            requireFreshTarget: false
        ) else {
            throw FixtureFailure.failed("Bridge could not structurally inspect an expired target")
        }

        let nearFuture = makeTarget(
            sequence: 21,
            issuedAtUnixMilliseconds: now + 4_999,
            leaseMilliseconds: 1_000
        )
        let nearFutureData = try ROBArmControlWireCodec.encode(
            nearFuture,
            nowUnixMilliseconds: now
        )
        guard case .targetIntent? = try ROBArmControlWireCodec.decode(
            nearFutureData,
            nowUnixMilliseconds: now
        ) else {
            throw FixtureFailure.failed("Allowed future clock skew was rejected")
        }
        try expectThrows("A future-dated target remained fresh after its own lease") {
            _ = try ROBArmControlWireCodec.decode(
                nearFutureData,
                nowUnixMilliseconds: nearFuture.issuedAtUnixMilliseconds
                    + Int64(nearFuture.leaseMilliseconds) + 1
            )
        }

        let tooFarFuture = makeTarget(
            sequence: 22,
            issuedAtUnixMilliseconds: now + 5_001,
            leaseMilliseconds: 1_000
        )
        try expectThrows("A target over five seconds in the future was encoded") {
            _ = try ROBArmControlWireCodec.encode(
                tooFarFuture,
                nowUnixMilliseconds: now
            )
        }

        var object = try jsonObject(expiredData)
        object["execute"] = true
        try expectThrows("Unknown execution field was ignored") {
            _ = try ROBArmControlWireCodec.decode(
                try jsonData(object),
                nowUnixMilliseconds: now,
                requireFreshTarget: false
            )
        }

        object = try jsonObject(expiredData)
        object.removeValue(forKey: "authority_id")
        try expectThrows("A target without authority_id was accepted") {
            _ = try ROBArmControlWireCodec.decode(
                try jsonData(object),
                nowUnixMilliseconds: now,
                requireFreshTarget: false
            )
        }

        object = try jsonObject(expiredData)
        object.removeValue(forKey: "dead_man_held")
        try expectThrows("A target without dead_man_held was accepted") {
            _ = try ROBArmControlWireCodec.decode(
                try jsonData(object),
                nowUnixMilliseconds: now,
                requireFreshTarget: false
            )
        }
    }

    private static func holdIntentRoundTripAndBounds() throws {
        let hold = ROBArmHoldIntentEnvelope(
            messageID: UUID(uuidString: "55555555-6666-7777-8888-999999999999")!,
            senderID: controllerID,
            sessionID: sessionID,
            authorityID: authorityID,
            sequence: 31,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 250,
            arm: .left,
            reason: "dead-man released"
        )
        let data = try ROBArmControlWireCodec.encode(hold)
        guard case .holdIntent(let decoded)? = try ROBArmControlWireCodec.decode(data) else {
            throw FixtureFailure.failed("Hold intent did not decode")
        }
        try expect(decoded == hold, "Hold intent changed during round-trip")
        try expect(decoded.authorityID == authorityID, "Hold authority binding changed")

        let authorityIndependentHold = ROBArmHoldIntentEnvelope(
            senderID: controllerID,
            sessionID: sessionID,
            authorityID: nil,
            sequence: 32,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 50,
            arm: .right,
            reason: "session ending"
        )
        let independentData = try ROBArmControlWireCodec.encode(authorityIndependentHold)
        guard case .holdIntent(let decodedIndependent)? = try ROBArmControlWireCodec.decode(
            independentData
        ) else {
            throw FixtureFailure.failed("Authority-independent safety hold did not decode")
        }
        try expect(
            decodedIndependent.authorityID == nil,
            "Authority-independent safety hold acquired an authority ID"
        )

        let invalidLease = ROBArmHoldIntentEnvelope(
            senderID: controllerID,
            sessionID: sessionID,
            authorityID: nil,
            sequence: 33,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 49,
            arm: .left,
            reason: "too short"
        )
        try expectThrows("A hold below the minimum lease was encoded") {
            _ = try ROBArmControlWireCodec.encode(invalidLease)
        }

        var unexpected = try jsonObject(data)
        unexpected["activate_position_mode"] = true
        try expectThrows("An unknown hold-intent field was accepted") {
            _ = try ROBArmControlWireCodec.decode(try jsonData(unexpected))
        }
    }

    private static func dispositionExecutionAndTerminalInvariants() throws {
        let targetID = UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!
        let terminalDispositions: Set<ROBArmTargetDispositionKind> = [
            .completedMeasured, .cancelledHeld, .leaseExpiredHeld,
            .holdConfirmed, .holdUnconfirmed, .failed,
            .rejectedAuthorityDisabled, .rejectedExpired,
            .rejectedIdentityMismatch, .rejectedSessionInactive,
            .rejectedStaleSequence, .rejectedTelemetryStale,
            .rejectedPositionModeRequired, .rejectedStepLimit,
            .rejectedSpeedLimit, .rejectedArmBusy, .rejectedInvalid,
        ]
        let eligibleDispositions: Set<ROBArmTargetDispositionKind> = [
            .acceptedForExecution, .executing, .completedMeasured,
        ]

        for kind in ROBArmTargetDispositionKind.allCases {
            let isCompleted = kind == .completedMeasured
            let disposition = ROBArmTargetDispositionEnvelope(
                targetMessageID: targetID,
                recipientID: controllerID,
                sessionID: sessionID,
                arm: .left,
                receivedAtUnixMilliseconds: now,
                disposition: kind,
                executionEligible: eligibleDispositions.contains(kind),
                terminal: terminalDispositions.contains(kind),
                detail: "Deterministic v2 disposition fixture.",
                measuredPositionsRadians: isCompleted ? Array(repeating: 0.05, count: 7) : nil,
                maximumErrorRadians: isCompleted ? 0.012 : nil
            )
            let data = try ROBArmControlWireCodec.encode(disposition)
            guard case .targetDisposition(let decoded)? = try ROBArmControlWireCodec.decode(data)
            else {
                throw FixtureFailure.failed("Target disposition \(kind.rawValue) did not decode")
            }
            try expect(decoded == disposition, "Disposition \(kind.rawValue) changed on the wire")
        }

        let accepted = ROBArmTargetDispositionEnvelope(
            targetMessageID: targetID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .left,
            receivedAtUnixMilliseconds: now,
            disposition: .acceptedForExecution,
            executionEligible: true,
            terminal: false,
            detail: "Admitted to the leased executor."
        )
        try expect(accepted.executionEligible, "Execution admission was not executable")
        try expect(!accepted.terminal, "Execution admission incorrectly reported completion")

        let completed = ROBArmTargetDispositionEnvelope(
            targetMessageID: targetID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .left,
            receivedAtUnixMilliseconds: now,
            disposition: .completedMeasured,
            executionEligible: true,
            terminal: true,
            detail: "Measured target settled.",
            measuredPositionsRadians: Array(repeating: 0.05, count: 7),
            maximumErrorRadians: 0.01
        )
        try expect(completed.terminal, "Measured completion was not terminal")
        try expect(
            completed.measuredPositionsRadians?.count == 7,
            "Measured completion omitted its joint vector"
        )

        let falselyTerminalAdmission = ROBArmTargetDispositionEnvelope(
            targetMessageID: targetID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .left,
            receivedAtUnixMilliseconds: now,
            disposition: .acceptedForExecution,
            executionEligible: true,
            terminal: true,
            detail: "Invalid early completion."
        )
        try expectThrows("Execution admission was allowed to claim terminal completion") {
            _ = try ROBArmControlWireCodec.encode(falselyTerminalAdmission)
        }

        let falselyExecutableRejection = ROBArmTargetDispositionEnvelope(
            targetMessageID: targetID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .left,
            receivedAtUnixMilliseconds: now,
            disposition: .rejectedExpired,
            executionEligible: true,
            terminal: true,
            detail: "Invalid executable rejection."
        )
        try expectThrows("A rejection was allowed to claim execution eligibility") {
            _ = try ROBArmControlWireCodec.encode(falselyExecutableRejection)
        }
    }

    private static func failClosedRoutingClassification() throws {
        let padding = String(repeating: "x", count: ROBArmControlProtocol.maximumMessageBytes)
        let oversized = Data("""
            {"padding":"\(padding)","type":"target_intent",
             "protocol" : "rob-arm-control/2"}
            """.utf8)
        try expect(
            oversized.count > ROBArmControlProtocol.maximumMessageBytes,
            "Oversized routing fixture did not exceed the arm decode limit"
        )
        try expect(
            ROBArmControlWireCodec.claimsProtocolForRouting(oversized),
            "Oversized v2 arm envelope could fall through to the historical parser"
        )
        try expectThrows("Oversized arm envelope reached normal decoding") {
            _ = try ROBArmControlWireCodec.decode(oversized, requireFreshTarget: false)
        }

        let malformed = Data("""
            {"type":"target_intent",
             "sender_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
             "protocol" \t : \n "rob-arm-control/2"
            """.utf8)
        try expect(
            ROBArmControlWireCodec.claimsProtocolForRouting(malformed),
            "Malformed, reordered v2 arm envelope could fall through"
        )

        let escapedKey = Data(#"{"pro\u0074ocol":"rob-arm-control/2","type":"target_intent"}"#.utf8)
        try expect(
            ROBArmControlWireCodec.claimsProtocolForRouting(escapedKey),
            "JSON key escaping hid the v2 arm protocol marker"
        )

        let v1 = Data(#"{"protocol":"rob-arm-control/1","type":"target_intent"}"#.utf8)
        try expect(
            ROBArmControlWireCodec.claimsProtocolForRouting(v1),
            "Legacy arm data could fall through to the historical parser"
        )
        try expect(
            try ROBArmControlWireCodec.decode(v1, requireFreshTarget: false) == nil,
            "Legacy preview protocol decoded as the execution protocol"
        )

        let unrelated = Data(#"{"protocol":"another-protocol/1","message":"rob-arm-control/2"}"#.utf8)
        try expect(
            !ROBArmControlWireCodec.claimsProtocolForRouting(unrelated),
            "Unrelated JSON was misclassified by a marker in an ordinary value"
        )
    }

    private static func targetAuthorityAndIdentityGate() throws {
        let target = makeTarget(
            sequence: 41,
            positions: Array(repeating: 0.05, count: 7)
        )
        let disabled = ROBArmTargetGateEvaluator.evaluate(
            target,
            authenticatedControllerID: controllerID,
            authenticatedSessionID: sessionID,
            lastAcceptedSequence: 40,
            authorityEnabled: false,
            executionContext: validExecutionContext(),
            nowUnixMilliseconds: now
        )
        try expect(
            disabled.disposition == .rejectedAuthorityDisabled,
            "Disabled controller authority accepted a target"
        )
        try expect(disabled.advancesSequence, "Rejected valid target did not consume its sequence")

        let accepted = ROBArmTargetGateEvaluator.evaluate(
            target,
            authenticatedControllerID: controllerID,
            authenticatedSessionID: sessionID,
            lastAcceptedSequence: 40,
            authorityEnabled: true,
            executionContext: validExecutionContext(),
            nowUnixMilliseconds: now
        )
        try expect(
            accepted.disposition == .acceptedForExecution,
            "Authorized safe target was not admitted for execution"
        )
        try expect(accepted.passedExecutionPreflight, "Safe target did not pass preflight")
        try expect(
            accepted.detail.contains("leased Amber executor"),
            "Admission did not identify the leased executor"
        )

        let wrongController = ROBArmTargetGateEvaluator.evaluate(
            target,
            authenticatedControllerID: UUID(),
            authenticatedSessionID: sessionID,
            lastAcceptedSequence: 40,
            authorityEnabled: true,
            executionContext: validExecutionContext(),
            nowUnixMilliseconds: now
        )
        try expect(
            wrongController.disposition == .rejectedIdentityMismatch,
            "Target from another authenticated controller was accepted"
        )
        try expect(!wrongController.advancesSequence, "Identity mismatch consumed a sequence")

        let wrongSession = ROBArmTargetGateEvaluator.evaluate(
            target,
            authenticatedControllerID: controllerID,
            authenticatedSessionID: UUID(),
            lastAcceptedSequence: 40,
            authorityEnabled: true,
            executionContext: validExecutionContext(),
            nowUnixMilliseconds: now
        )
        try expect(
            wrongSession.disposition == .rejectedIdentityMismatch,
            "Target from another authenticated session was accepted"
        )

        let replay = ROBArmTargetGateEvaluator.evaluate(
            target,
            authenticatedControllerID: controllerID,
            authenticatedSessionID: sessionID,
            lastAcceptedSequence: target.sequence,
            authorityEnabled: true,
            executionContext: validExecutionContext(),
            nowUnixMilliseconds: now
        )
        try expect(replay.disposition == .rejectedStaleSequence, "Replay was accepted")
        try expect(!replay.advancesSequence, "Replay advanced the sequence")

        let expired = makeTarget(
            sequence: 42,
            issuedAtUnixMilliseconds: now - 1_001,
            leaseMilliseconds: 1_000
        )
        let expiredDecision = evaluate(expired, context: validExecutionContext())
        try expect(expiredDecision.disposition == .rejectedExpired, "Expired target was accepted")
        try expect(!expiredDecision.advancesSequence, "Expired target consumed a sequence")

        let deadManReleased = makeTarget(sequence: 43, deadManHeld: false)
        let releasedDecision = evaluate(deadManReleased, context: validExecutionContext())
        try expect(
            releasedDecision.disposition == .rejectedInvalid,
            "Target with released dead-man passed the gate"
        )
        try expect(!releasedDecision.advancesSequence, "Invalid target consumed a sequence")
    }

    private static func executionPreflightGate() throws {
        let safe = makeTarget(
            sequence: 51,
            positions: Array(repeating: 0.05, count: 7),
            duration: 1
        )
        let sessionEnded = evaluate(safe, context: validExecutionContext(sessionCurrent: false))
        try expect(
            sessionEnded.disposition == .rejectedSessionInactive,
            "Inactive authenticated session passed preflight"
        )

        let missing = evaluate(safe, context: validExecutionContext(measured: nil))
        try expect(
            missing.disposition == .rejectedTelemetryStale,
            "Missing measured telemetry passed preflight"
        )

        let stale = evaluate(safe, context: validExecutionContext(ageMilliseconds: 250.1))
        try expect(
            stale.disposition == .rejectedTelemetryStale,
            "Stale measured telemetry passed preflight"
        )

        let wrongMode = evaluate(
            safe,
            context: validExecutionContext(modes: [2, 2, 2, 2, 2, 2, 1])
        )
        try expect(
            wrongMode.disposition == .rejectedPositionModeRequired,
            "A non-position-mode joint passed preflight"
        )

        let busy = evaluate(safe, context: validExecutionContext(armBusy: true))
        try expect(busy.disposition == .rejectedArmBusy, "A second in-flight target was accepted")

        let tooFast = makeTarget(
            sequence: 52,
            positions: Array(repeating: 0.14, count: 7),
            duration: 0.65
        )
        try expect(
            evaluate(tooFast, context: validExecutionContext()).disposition
                == .rejectedSpeedLimit,
            "A target over 0.20 rad/s passed preflight"
        )

        let tooLarge = makeTarget(
            sequence: 53,
            positions: Array(repeating: 0.1001, count: 7),
            duration: 1
        )
        try expect(
            evaluate(tooLarge, context: validExecutionContext()).disposition
                == .rejectedStepLimit,
            "A target over the 0.10-radian update limit passed preflight"
        )

        let admitted = evaluate(safe, context: validExecutionContext())
        try expect(
            admitted.disposition == .acceptedForExecution,
            "Safe target was not admitted for execution"
        )
        try expect(admitted.passedExecutionPreflight, "Safe target failed execution preflight")
        try expect(admitted.advancesSequence, "Admitted target did not consume its sequence")
    }

    private static func makeTarget(
        messageID: UUID = UUID(),
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64 = now,
        leaseMilliseconds: UInt32 = 1_000,
        arm: ROBArmSide = .left,
        positions: [Double] = Array(repeating: 0, count: 7),
        duration: Double = 1,
        deadManHeld: Bool = true
    ) -> ROBArmTargetIntentEnvelope {
        ROBArmTargetIntentEnvelope(
            messageID: messageID,
            senderID: controllerID,
            sessionID: sessionID,
            authorityID: authorityID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            leaseMilliseconds: leaseMilliseconds,
            arm: arm,
            source: .visionProJointUI,
            positionsRadians: positions,
            durationSeconds: duration,
            deadManHeld: deadManHeld
        )
    }

    private static func validExecutionContext(
        sessionCurrent: Bool = true,
        measured: [Double]? = Array(repeating: 0, count: 7),
        ageMilliseconds: Double? = 10,
        modes: [Int] = Array(repeating: 2, count: 7),
        armBusy: Bool = false
    ) -> ROBArmTargetExecutionContext {
        ROBArmTargetExecutionContext(
            authenticatedSessionIsCurrent: sessionCurrent,
            measuredPositionsRadians: measured,
            effectiveTelemetryAgeMilliseconds: ageMilliseconds,
            modes: modes,
            armHasInFlightTarget: armBusy
        )
    }

    private static func evaluate(
        _ target: ROBArmTargetIntentEnvelope,
        context: ROBArmTargetExecutionContext
    ) -> ROBArmTargetGateDecision {
        ROBArmTargetGateEvaluator.evaluate(
            target,
            authenticatedControllerID: controllerID,
            authenticatedSessionID: sessionID,
            lastAcceptedSequence: 0,
            authorityEnabled: true,
            executionContext: context,
            nowUnixMilliseconds: now
        )
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Fixture was not a JSON object"
        )
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
        guard try condition() else { throw FixtureFailure.failed(detail) }
    }

    private static func expectThrows(_ detail: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw FixtureFailure.failed(detail)
        } catch is FixtureFailure {
            throw FixtureFailure.failed(detail)
        } catch {
            return
        }
    }

    private static func require<T>(_ value: T?, _ detail: String) throws -> T {
        guard let value else { throw FixtureFailure.failed(detail) }
        return value
    }
}
