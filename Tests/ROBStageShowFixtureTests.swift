import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class FakeStageDelegate: NSObject, ROBStageShowCoordinatorDelegate {
    var spoken: [String] = []
    var geminiPrompts: [String] = []
    var geminiRequestIDs: [String] = []
    var cancelledGeminiRequestIDs: [String] = []
    var gestures: [String] = []
    var stopCount = 0
    var failGemini = false
    var holdGemini = false
    var gestureSucceeds = false

    func stageShowCoordinator(_ coordinator: ROBStageShowCoordinator, speak text: String, cueID: String) {
        spoken.append(text)
        coordinator.speechDidFinish()
    }

    func stageShowCoordinator(
        _ coordinator: ROBStageShowCoordinator,
        requestGeminiTurn prompt: String,
        cueID: String,
        requestID: String,
        timeout: TimeInterval
    ) {
        geminiPrompts.append(prompt)
        geminiRequestIDs.append(requestID)
        if holdGemini {
            return
        }
        if failGemini {
            _ = coordinator.failGeminiTurn("fixture network unavailable", requestID: requestID)
        } else {
            _ = coordinator.acceptGeminiResponse("Fixture adaptive line", requestID: requestID)
        }
    }

    func stageShowCoordinator(
        _ coordinator: ROBStageShowCoordinator,
        cancelGeminiTurn requestID: String
    ) {
        cancelledGeminiRequestIDs.append(requestID)
    }

    func stageShowCoordinator(
        _ coordinator: ROBStageShowCoordinator,
        requestGesture name: String,
        cueID: String,
        timeout: TimeInterval
    ) {
        gestures.append(name)
        _ = coordinator.completeGesture(
            success: gestureSucceeds,
            detail: gestureSucceeds ? "fixture completed" : "fixture executor unavailable"
        )
    }

    func stageShowCoordinatorDidRequestStop(_ coordinator: ROBStageShowCoordinator) {
        stopCount += 1
    }
}

private final class FakeLocalImprovisationProvider: ROBLocalImprovisationProviding {
    let providerName = "Fixture local director"
    let maximumRequestSeconds: TimeInterval = 3
    var plan = ROBLocalImprovisationPlan(
        beat: .robotJoke,
        delivery: .deadpan,
        offlineLine: "My local comedy circuit is ready even when the cloud is not."
    )
    var shouldFail = false
    var shouldHold = false
    var requestCount = 0
    var cancelCount = 0
    var fallbackCount = 0
    private var heldCompletion: ((Result<ROBLocalImprovisationPlan, Error>) -> Void)?

    func generatePlan(
        for request: ROBLocalImprovisationRequest,
        requestID: String,
        timeout: TimeInterval,
        completion: @escaping (Result<ROBLocalImprovisationPlan, Error>) -> Void
    ) {
        requestCount += 1
        if shouldHold {
            heldCompletion = completion
        } else if shouldFail {
            completion(.failure(ROBLocalImprovisationError.serverUnavailable("fixture unavailable")))
        } else {
            completion(.success(plan))
        }
    }

    func cancel(requestID: String) {
        cancelCount += 1
    }

    func checkHealth(timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        completion(.success("Fixture ready"))
    }

    func noteFallback() {
        fallbackCount += 1
    }

    func diagnosticsSnapshot() -> ROBLocalImprovisationDiagnosticsSnapshot {
        ROBLocalImprovisationDiagnosticsSnapshot(
            providerName: providerName,
            state: "fixture",
            redactedEndpoint: nil,
            model: nil,
            requestCount: UInt64(requestCount),
            successCount: UInt64(max(0, requestCount - (shouldFail ? 1 : 0))),
            fallbackCount: UInt64(fallbackCount),
            lastLatency: nil,
            lastErrorCategory: shouldFail ? "unavailable" : nil
        )
    }

    func completeHeldRequest() {
        let completion = heldCompletion
        heldCompletion = nil
        completion?(.success(plan))
    }
}

@main
struct ROBStageShowFixtureTests {
    static func main() throws {
        try testSampleRoundTrip()
        try testUnknownHardwareFieldsAreRejected()
        try testCueValidationAndLimits()
        try testDryRunHasNoSideEffects()
        try testOfflineAndAdaptiveFallbacks()
        try testLocalProviderPreflight()
        try testLocalDirectorRoutes()
        try testLateLocalCompletionIsSuppressed()
        try testGeminiTurnLifecycleCancellation()
        try testOptionalGestureAndCancellation()
        print("ROB stage-show fixtures passed")
    }

    private static func testSampleRoundTrip() throws {
        let data = try ROBStageShowCodec.encode(ROBStageShowSamples.makerFaireOpening)
        let decoded = try ROBStageShowCodec.decode(data)
        try expect(decoded == ROBStageShowSamples.makerFaireOpening, "Sample show changed during round trip")
        try expect(decoded.cues.count == 7, "Unexpected sample cue count")

        let bundledURL = URL(fileURLWithPath: "Cerebro/StageShows/MakerFaireOpening.robshow.json")
        let bundled = try ROBStageShowCodec.decode(Data(contentsOf: bundledURL))
        try expect(bundled == decoded, "Bundled sample and compiled fallback diverged")

        let comedyURL = URL(fileURLWithPath: "Cerebro/StageShows/OrbitusTenMinuteComedy.robshow.json")
        let comedy = try ROBStageShowCodec.decode(Data(contentsOf: comedyURL))
        let runtime = ROBStageShowCodec.estimatedDuration(of: comedy)
        try expect(comedy.cues.count >= 35, "Ten-minute comedy show is unexpectedly short")
        try expect((9 * 60 ... 11 * 60).contains(runtime), "Comedy show runtime is not approximately ten minutes")
        try expect(comedy.cues.filter { $0.kind == .geminiTurn }.count >= 5,
                   "Comedy show needs multiple adaptive moments")
    }

    private static func testUnknownHardwareFieldsAreRejected() throws {
        let rawServo = """
        {
          "schema":"com.orbitusrobotics.stage-show",
          "version":1,
          "show_id":"unsafe",
          "title":"Unsafe",
          "cues":[{"id":"move","kind":"speak","text":"hello","servo_1":1.2}]
        }
        """
        try expectThrows("Raw servo field was accepted") {
            _ = try ROBStageShowCodec.decode(Data(rawServo.utf8))
        }

        let rawSSH = """
        {
          "schema":"com.orbitusrobotics.stage-show",
          "version":1,
          "show_id":"unsafe-ssh",
          "title":"Unsafe SSH",
          "ssh_command":"move arm",
          "cues":[{"id":"line","kind":"speak","text":"hello"}]
        }
        """
        try expectThrows("Raw SSH field was accepted") {
            _ = try ROBStageShowCodec.decode(Data(rawSSH.utf8))
        }
    }

    private static func testCueValidationAndLimits() throws {
        let duplicate = ROBStageShow(
            showID: "duplicate",
            title: "Duplicate",
            cues: [
                ROBStageCue(id: "same", kind: .speak, text: "one"),
                ROBStageCue(id: "same", kind: .speak, text: "two")
            ]
        )
        try expectThrows("Duplicate cue IDs were accepted") {
            try ROBStageShowCodec.validate(duplicate)
        }

        let noFallback = ROBStageShow(
            showID: "no-fallback",
            title: "No fallback",
            cues: [
                ROBStageCue(id: "live", kind: .geminiTurn, text: "improvise", durationSeconds: 5)
            ]
        )
        try expectThrows("Gemini cue without offline fallback was accepted") {
            try ROBStageShowCodec.validate(noFallback)
        }

        let excessiveWait = ROBStageShow(
            showID: "slow",
            title: "Slow",
            cues: [ROBStageCue(id: "wait", kind: .wait, durationSeconds: 121)]
        )
        try expectThrows("Excessive wait was accepted") {
            try ROBStageShowCodec.validate(excessiveWait)
        }
    }

    private static func testDryRunHasNoSideEffects() throws {
        let coordinator = ROBStageShowCoordinator()
        let delegate = FakeStageDelegate()
        let localProvider = FakeLocalImprovisationProvider()
        coordinator.delegate = delegate
        coordinator.localImprovisationProvider = localProvider
        try coordinator.load(ROBStageShowSamples.makerFaireOpening)
        coordinator.start(mode: .dryRun)
        try waitUntil(timeout: 2) { !coordinator.isRunning }
        try expect(coordinator.state == "completed", "Dry run did not complete")
        try expect(delegate.spoken.isEmpty, "Dry run emitted speech")
        try expect(delegate.geminiPrompts.isEmpty, "Dry run emitted a Gemini request")
        try expect(delegate.gestures.isEmpty, "Dry run emitted a gesture request")
        try expect(localProvider.requestCount == 0, "Dry run emitted a local model request")
    }

    private static func testOfflineAndAdaptiveFallbacks() throws {
        let show = ROBStageShow(
            showID: "fallbacks",
            title: "Fallbacks",
            cues: [
                ROBStageCue(
                    id: "live",
                    kind: .geminiTurn,
                    text: "say something",
                    durationSeconds: 2,
                    fallbackText: "Authored fallback"
                )
            ]
        )

        let offlineCoordinator = ROBStageShowCoordinator()
        let offlineDelegate = FakeStageDelegate()
        offlineCoordinator.delegate = offlineDelegate
        try offlineCoordinator.load(show)
        offlineCoordinator.start(mode: .speechOnly)
        try expect(!offlineCoordinator.isRunning, "Synchronous offline fixture did not complete")
        try expect(offlineDelegate.geminiPrompts.isEmpty, "Offline mode contacted Gemini")
        try expect(offlineDelegate.spoken == ["Authored fallback"], "Offline fallback was not spoken")

        let adaptiveCoordinator = ROBStageShowCoordinator()
        let adaptiveDelegate = FakeStageDelegate()
        adaptiveDelegate.failGemini = true
        adaptiveCoordinator.delegate = adaptiveDelegate
        try adaptiveCoordinator.load(show)
        adaptiveCoordinator.start(mode: .adaptive)
        try expect(!adaptiveCoordinator.isRunning, "Synchronous adaptive fixture did not complete")
        try expect(adaptiveDelegate.geminiPrompts == ["say something"], "Adaptive prompt was not requested")
        try expect(adaptiveDelegate.spoken == ["Authored fallback"], "Adaptive failure did not use fallback")
        try expect(
            adaptiveDelegate.cancelledGeminiRequestIDs == adaptiveDelegate.geminiRequestIDs,
            "A failed Gemini turn was not cancelled/dequeued"
        )
    }

    private static func testLocalDirectorRoutes() throws {
        let show = ROBStageShow(
            showID: "local-routes",
            title: "Local routes",
            cues: [
                ROBStageCue(
                    id: "improv",
                    kind: .geminiTurn,
                    text: "Connect the visitor's comment to ROB's origin story.",
                    durationSeconds: 10,
                    fallbackText: "My origin story has excellent error handling."
                )
            ]
        )

        let adaptiveCoordinator = ROBStageShowCoordinator()
        let adaptiveDelegate = FakeStageDelegate()
        let adaptiveLocal = FakeLocalImprovisationProvider()
        adaptiveCoordinator.delegate = adaptiveDelegate
        adaptiveCoordinator.localImprovisationProvider = adaptiveLocal
        try adaptiveCoordinator.load(show)
        adaptiveCoordinator.start(mode: .adaptive)
        try expect(!adaptiveCoordinator.isRunning, "Local-directed adaptive fixture did not complete")
        try expect(adaptiveLocal.requestCount == 1, "Adaptive mode did not ask the local director")
        try expect(adaptiveDelegate.geminiPrompts.count == 1, "Local plan was not handed to Gemini")
        let handoff = adaptiveDelegate.geminiPrompts[0]
        try expect(handoff.contains("STAGE DIALOGUE ONLY"), "Gemini handoff lacks its dialogue-only boundary")
        try expect(handoff.contains(adaptiveLocal.plan.beat.rawValue), "Gemini handoff lost the allow-listed beat")
        try expect(handoff.contains(adaptiveLocal.plan.delivery.rawValue), "Gemini handoff lost the delivery")
        try expect(
            !handoff.contains(adaptiveLocal.plan.offlineLine),
            "Free-form local dialogue escaped into the Gemini handoff"
        )
        try expect(adaptiveDelegate.spoken == ["Fixture adaptive line"], "Gemini result was not spoken")

        let cloudFailureCoordinator = ROBStageShowCoordinator()
        let cloudFailureDelegate = FakeStageDelegate()
        let cloudFailureLocal = FakeLocalImprovisationProvider()
        cloudFailureDelegate.failGemini = true
        cloudFailureCoordinator.delegate = cloudFailureDelegate
        cloudFailureCoordinator.localImprovisationProvider = cloudFailureLocal
        try cloudFailureCoordinator.load(show)
        cloudFailureCoordinator.start(mode: .adaptive)
        try expect(!cloudFailureCoordinator.isRunning, "Cloud-failure fixture did not complete")
        try expect(
            cloudFailureDelegate.spoken == [cloudFailureLocal.plan.offlineLine],
            "Gemini failure did not use the validated local line"
        )
        try expect(cloudFailureLocal.fallbackCount == 1, "Local fallback use was not recorded")

        let localOnlyCoordinator = ROBStageShowCoordinator()
        let localOnlyDelegate = FakeStageDelegate()
        let localOnlyProvider = FakeLocalImprovisationProvider()
        localOnlyCoordinator.delegate = localOnlyDelegate
        localOnlyCoordinator.localImprovisationProvider = localOnlyProvider
        try localOnlyCoordinator.load(show)
        localOnlyCoordinator.start(mode: .localOnly)
        try expect(!localOnlyCoordinator.isRunning, "Local-only fixture did not complete")
        try expect(localOnlyDelegate.geminiPrompts.isEmpty, "Local-only mode contacted Gemini")
        try expect(
            localOnlyDelegate.spoken == [localOnlyProvider.plan.offlineLine],
            "Local-only mode did not speak the generated local line"
        )

        let localFailureCoordinator = ROBStageShowCoordinator()
        let localFailureDelegate = FakeStageDelegate()
        let localFailureProvider = FakeLocalImprovisationProvider()
        localFailureProvider.shouldFail = true
        localFailureCoordinator.delegate = localFailureDelegate
        localFailureCoordinator.localImprovisationProvider = localFailureProvider
        try localFailureCoordinator.load(show)
        localFailureCoordinator.start(mode: .adaptive)
        try expect(!localFailureCoordinator.isRunning, "Local-failure adaptive fixture did not complete")
        try expect(
            localFailureDelegate.geminiPrompts == ["Connect the visitor's comment to ROB's origin story."],
            "Local failure did not preserve the authored Gemini route"
        )

        let speechOnlyCoordinator = ROBStageShowCoordinator()
        let speechOnlyDelegate = FakeStageDelegate()
        let unusedLocalProvider = FakeLocalImprovisationProvider()
        speechOnlyCoordinator.delegate = speechOnlyDelegate
        speechOnlyCoordinator.localImprovisationProvider = unusedLocalProvider
        try speechOnlyCoordinator.load(show)
        speechOnlyCoordinator.start(mode: .speechOnly)
        try expect(unusedLocalProvider.requestCount == 0, "Speech-only mode contacted the local model")
        try expect(
            speechOnlyDelegate.spoken == ["My origin story has excellent error handling."],
            "Speech-only mode lost its authored fallback"
        )
    }

    private static func testLocalProviderPreflight() throws {
        let coordinator = ROBStageShowCoordinator()
        let provider = FakeLocalImprovisationProvider()
        coordinator.localImprovisationProvider = provider
        var resultDescription: String?
        var resultError: Error?
        coordinator.preflightLocalImprovisationProvider { result in
            switch result {
            case .success(let description): resultDescription = description
            case .failure(let error): resultError = error
            }
        }
        try expect(resultError == nil, "Local-provider preflight failed")
        try expect(
            resultDescription?.contains("schema-constrained") == true,
            "Local-provider preflight did not validate schema generation"
        )
        try expect(provider.requestCount == 1, "Local-provider preflight did not request a plan")
    }

    private static func testLateLocalCompletionIsSuppressed() throws {
        let show = ROBStageShow(
            showID: "late-local",
            title: "Late local",
            cues: [
                ROBStageCue(
                    id: "improv",
                    kind: .geminiTurn,
                    text: "Plan a short line.",
                    durationSeconds: 10,
                    fallbackText: "Authored fallback"
                )
            ]
        )
        let coordinator = ROBStageShowCoordinator()
        let delegate = FakeStageDelegate()
        let localProvider = FakeLocalImprovisationProvider()
        localProvider.shouldHold = true
        coordinator.delegate = delegate
        coordinator.localImprovisationProvider = localProvider
        try coordinator.load(show)
        coordinator.start(mode: .adaptive)
        try expect(coordinator.isRunning, "Held local fixture was not awaiting a result")
        coordinator.cancel(reason: "fixture cancellation")
        localProvider.completeHeldRequest()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try expect(!coordinator.isRunning, "Late local completion restarted a cancelled show")
        try expect(delegate.geminiPrompts.isEmpty, "Late local completion emitted a Gemini request")
        try expect(localProvider.cancelCount == 1, "Show cancellation did not cancel local inference")
    }

    private static func testGeminiTurnLifecycleCancellation() throws {
        let heldShow = ROBStageShow(
            showID: "held-gemini",
            title: "Held Gemini",
            cues: [
                ROBStageCue(
                    id: "improv",
                    kind: .geminiTurn,
                    text: "Hold this fixture request.",
                    durationSeconds: 10,
                    fallbackText: "Held fallback"
                )
            ]
        )
        let cancelledCoordinator = ROBStageShowCoordinator()
        let cancelledDelegate = FakeStageDelegate()
        cancelledDelegate.holdGemini = true
        cancelledCoordinator.delegate = cancelledDelegate
        try cancelledCoordinator.load(heldShow)
        cancelledCoordinator.start(mode: .adaptive)
        let cancelledRequestID = try require(
            cancelledDelegate.geminiRequestIDs.first,
            "Held stage turn did not emit a Gemini context ID"
        )
        cancelledCoordinator.cancel(reason: "fixture operator stop")
        cancelledCoordinator.cancel(reason: "duplicate fixture stop")
        try expect(
            cancelledDelegate.cancelledGeminiRequestIDs == [cancelledRequestID],
            "Explicit show cancellation did not idempotently dequeue its Gemini turn"
        )
        try expect(
            !cancelledCoordinator.acceptGeminiResponse("late", requestID: cancelledRequestID),
            "A late response was accepted after its Gemini turn was cancelled"
        )

        let timeoutShow = ROBStageShow(
            showID: "timed-out-gemini",
            title: "Timed-out Gemini",
            cues: [
                ROBStageCue(
                    id: "improv",
                    kind: .geminiTurn,
                    text: "Time out this fixture request.",
                    durationSeconds: 1,
                    fallbackText: "Timeout fallback"
                )
            ]
        )
        let timeoutCoordinator = ROBStageShowCoordinator()
        let timeoutDelegate = FakeStageDelegate()
        timeoutDelegate.holdGemini = true
        timeoutCoordinator.delegate = timeoutDelegate
        try timeoutCoordinator.load(timeoutShow)
        timeoutCoordinator.start(mode: .adaptive)
        try waitUntil(timeout: 1.5) { !timeoutCoordinator.isRunning }
        try expect(
            timeoutDelegate.cancelledGeminiRequestIDs == timeoutDelegate.geminiRequestIDs,
            "A timed-out Gemini turn was not cancelled/dequeued before fallback"
        )
        try expect(
            timeoutDelegate.spoken == ["Timeout fallback"],
            "Gemini timeout did not continue through the authored fallback"
        )
    }

    private static func testOptionalGestureAndCancellation() throws {
        let optionalShow = ROBStageShow(
            showID: "optional-gesture",
            title: "Optional gesture",
            cues: [
                ROBStageCue(
                    id: "gesture",
                    kind: .playGesture,
                    durationSeconds: 2,
                    gesture: "b1.salute",
                    required: false
                ),
                ROBStageCue(id: "line", kind: .speak, text: "continued")
            ]
        )
        let coordinator = ROBStageShowCoordinator()
        let delegate = FakeStageDelegate()
        coordinator.delegate = delegate
        try coordinator.load(optionalShow)
        coordinator.start(mode: .speechOnly)
        try expect(!coordinator.isRunning, "Optional gesture failure stopped the show")
        try expect(delegate.gestures == ["b1.salute"], "Named gesture was not requested")
        try expect(delegate.spoken == ["continued"], "Show did not continue after optional gesture")

        let cancellable = ROBStageShow(
            showID: "cancel",
            title: "Cancel",
            cues: [ROBStageCue(id: "wait", kind: .wait, durationSeconds: 10)]
        )
        let cancelCoordinator = ROBStageShowCoordinator()
        let cancelDelegate = FakeStageDelegate()
        cancelCoordinator.delegate = cancelDelegate
        try cancelCoordinator.load(cancellable)
        cancelCoordinator.start(mode: .speechOnly)
        cancelCoordinator.cancel(reason: "fixture stop")
        cancelCoordinator.cancel(reason: "duplicate stop")
        try expect(cancelCoordinator.state == "cancelled", "Cancellation did not become terminal")
        try expect(cancelDelegate.stopCount == 1, "Cancellation stop was not idempotent")
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        try expect(condition(), "Timed out waiting for fixture condition")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FixtureFailure.failed(message) }
        return value
    }

    private static func expectThrows(_ message: String, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw FixtureFailure.failed(message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureFailure.failed(message) }
    }
}
