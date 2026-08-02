import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct GeminiRoboticsProtocolFixtureTests {
    static func main() throws {
        try testConfigurationRequiresExplicitOptIn()
        try testConfigurationAndSetup()
        try testPromptPreservesWakePhrase()
        try testMediaMessages()
        try testRealtimeTextMessage()
        try testServerTurnParsing()
        try testIndependentTranscriptionParsing()
        try testTranscriptionAggregation()
        try testMicrophoneTurnAssociationOrdering()
        try testTurnDeadlineTracking()
        try testToolAndSessionParsing()
        print("Gemini Robotics protocol fixtures passed")
    }

    private static func testPromptPreservesWakePhrase() throws {
        let prompt = GeminiRoboticsPrompt.spokenText("Hey Rob, look at this", speechWordiness: 0)
        try expect(prompt.contains("Hey Rob"), "Text fallback must preserve ROB's wake phrase")
        try expect(prompt.hasPrefix("Answer in one concise spoken sentence:"), "Wordiness guidance is missing")
    }

    private static func testConfigurationRequiresExplicitOptIn() throws {
        try expect(
            GeminiRoboticsConfiguration.fromEnvironment(["GEMINI_API_KEY": "fixture-key"]) == nil,
            "A credential alone must not enable camera or microphone streaming"
        )
        try expect(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "tru",
                "GEMINI_API_KEY": "fixture-key"
            ]) == nil,
            "Unrecognized enable values must fail closed"
        )
    }

    private static func testConfigurationAndSetup() throws {
        let environment = [
            "GEMINI_ROBOTICS_ENABLED": "true",
            "GEMINI_API_KEY": "fixture-key",
            "GEMINI_ROBOTICS_MODEL": "gemini-robotics-er-2-streaming-preview",
            "GEMINI_ROBOT_ACTION_TOOL_ENABLED": "true"
        ]
        let configuration = try require(
            GeminiRoboticsConfiguration.fromEnvironment(environment),
            "Configuration should load from GEMINI_API_KEY"
        )
        try expect(
            configuration.model == GeminiRoboticsConfiguration.defaultModel,
            "Model names should be normalized with the models/ prefix"
        )
        let url = try configuration.webSocketURL()
        try expect(url.scheme == "wss", "Gemini must use a secure WebSocket")
        try expect(url.query?.contains("key=fixture-key") == true, "API key query item is missing")

        let setup = GeminiRoboticsProtocol.setupMessage(
            configuration: configuration,
            resumptionHandle: "resume-123"
        )
        let setupBody = try require(setup["setup"] as? [String: Any], "Missing setup envelope")
        try expect(setupBody["model"] as? String == configuration.model, "Wrong setup model")
        let generationConfig = try require(
            setupBody["generationConfig"] as? [String: Any],
            "Missing generationConfig"
        )
        try expect(
            generationConfig["responseModalities"] as? [String] == ["TEXT"],
            "Robotics ER 2 must preserve its accepted TEXT setup by default"
        )
        let inputTranscription = try require(
            setupBody["inputAudioTranscription"] as? [String: Any],
            "Input transcription must be enabled at the setup level"
        )
        let outputTranscription = try require(
            setupBody["outputAudioTranscription"] as? [String: Any],
            "Output transcription must be enabled at the setup level"
        )
        try expect(inputTranscription.isEmpty, "Input transcription setup should be an empty options object")
        try expect(outputTranscription.isEmpty, "Output transcription setup should be an empty options object")
        try expect(generationConfig["inputAudioTranscription"] == nil, "Input transcription is in the wrong object")
        try expect(generationConfig["outputAudioTranscription"] == nil, "Output transcription is in the wrong object")
        let resumption = try require(
            setupBody["sessionResumption"] as? [String: String],
            "Missing session resumption config"
        )
        try expect(resumption["handle"] == "resume-123", "Resumption handle was not serialized")

        let tools = try require(setupBody["tools"] as? [[String: Any]], "Missing enabled tool declarations")
        let declarations = try require(
            tools.first?["functionDeclarations"] as? [[String: Any]],
            "Missing function declarations"
        )
        try expect(declarations.first?["name"] as? String == "robot_action", "Wrong tool name")
        try expect(declarations.first?["behavior"] as? String == "BLOCKING", "Physical tools must be blocking")
        let parameters = try require(
            declarations.first?["parameters"] as? [String: Any],
            "Missing robot_action parameters"
        )
        let properties = try require(
            parameters["properties"] as? [String: Any],
            "Missing robot_action properties"
        )
        let distance = try require(
            properties["distance_m"] as? [String: Any],
            "Missing distance_m schema"
        )
        let speed = try require(
            properties["speed_scale"] as? [String: Any],
            "Missing speed_scale schema"
        )
        try expect((distance["minimum"] as? NSNumber)?.doubleValue == -1.0, "Distance minimum changed")
        try expect((distance["maximum"] as? NSNumber)?.doubleValue == 1.0, "Distance maximum changed")
        try expect((speed["maximum"] as? NSNumber)?.doubleValue == 0.35, "Speed cap changed")

        let audioConfiguration = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-key",
                "GEMINI_ROBOTICS_RESPONSE_MODALITY": "audio"
            ]),
            "AUDIO response configuration should load"
        )
        try expect(audioConfiguration.responseModality == "AUDIO", "AUDIO response override was ignored")
    }

    private static func testMediaMessages() throws {
        let bytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let audio = GeminiRoboticsProtocol.realtimeAudioMessage(bytes)
        let realtimeAudio = try require(audio["realtimeInput"] as? [String: Any], "Missing realtime audio envelope")
        let audioBlob = try require(realtimeAudio["audio"] as? [String: String], "Missing audio blob")
        try expect(audioBlob["mimeType"] == "audio/pcm;rate=16000", "Wrong audio MIME type")
        try expect(audioBlob["data"] == bytes.base64EncodedString(), "Wrong audio base64 payload")

        let video = GeminiRoboticsProtocol.realtimeVideoMessage(bytes)
        let realtimeVideo = try require(video["realtimeInput"] as? [String: Any], "Missing realtime video envelope")
        let videoBlob = try require(realtimeVideo["video"] as? [String: String], "Missing video blob")
        try expect(videoBlob["mimeType"] == "image/jpeg", "Wrong video MIME type")
    }

    private static func testRealtimeTextMessage() throws {
        let message = GeminiRoboticsProtocol.realtimeTextMessage("Hey ROB, say seven")
        try expect(message["clientContent"] == nil, "Runtime text must not use the initial-history envelope")
        let realtimeInput = try require(
            message["realtimeInput"] as? [String: Any],
            "Missing realtime text envelope"
        )
        try expect(realtimeInput["text"] as? String == "Hey ROB, say seven", "Wrong realtime text")
    }

    private static func testServerTurnParsing() throws {
        let message = """
        {
          "serverContent": {
            "modelTurn": {
              "role": "model",
              "parts": [{"text":"I can see "}, {"text":"the red cup."}]
            },
            "turnComplete": true,
            "interrupted": false
          }
        }
        """
        let event = try GeminiRoboticsProtocol.parseServerMessage(Data(message.utf8))
        try expect(event.textFragments == ["I can see ", "the red cup."], "Text fragments were not preserved")
        try expect(event.turnComplete, "Turn completion was not parsed")
        try expect(!event.interrupted, "Turn was incorrectly marked interrupted")
    }

    private static func testIndependentTranscriptionParsing() throws {
        let inputEvent = try GeminiRoboticsProtocol.parseServerMessage(Data("""
        {
          "serverContent": {
            "inputTranscription": {"text":"Hey ROB, say seven"}
          }
        }
        """.utf8))
        try expect(inputEvent.inputTranscription == "Hey ROB, say seven", "Input transcription was not parsed")
        try expect(inputEvent.outputTranscription == nil, "Input transcription was confused with model output")

        let outputEvent = try GeminiRoboticsProtocol.parseServerMessage(Data("""
        {
          "serverContent": {
            "outputTranscription": {"text":"Seven."},
            "generationComplete": true,
            "turnComplete": false
          }
        }
        """.utf8))
        try expect(outputEvent.outputTranscription == "Seven.", "Output transcription was not parsed")
        try expect(outputEvent.inputTranscription == nil, "Output transcription was confused with microphone input")
        try expect(outputEvent.generationComplete, "Generation completion was not parsed")
        try expect(!outputEvent.turnComplete, "Generation completion must remain distinct from turn completion")

        let turnEvent = try GeminiRoboticsProtocol.parseServerMessage(
            Data(#"{"serverContent":{"generationComplete":false,"turnComplete":true}}"#.utf8)
        )
        try expect(!turnEvent.generationComplete, "Turn completion was confused with generation completion")
        try expect(turnEvent.turnComplete, "Independent turn completion was not parsed")
    }

    private static func testTurnDeadlineTracking() throws {
        var tracker = GeminiTurnDeadlineTracker(responseStartTimeout: 5, turnCompletionTimeout: 20)
        tracker.begin(turnID: 41, now: 100)
        try expect(tracker.expiration(turnID: 41, now: 104.9) == nil, "Turn expired before its response deadline")
        try expect(
            tracker.expiration(turnID: 41, now: 105) == .responseNotStarted(turnID: 41),
            "Missing-response expiry was not reported"
        )

        tracker.noteResponse(turnID: 41)
        try expect(tracker.expiration(turnID: 41, now: 110) == nil, "A started response used the wrong deadline")
        try expect(
            tracker.expiration(turnID: 41, now: 120) == .turnNotCompleted(turnID: 41),
            "Absolute turn expiry was not reported"
        )

        tracker.complete(turnID: 40)
        try expect(tracker.activeTurnID == 41, "A stale completion cleared the active turn")
        tracker.complete(turnID: 41)
        try expect(tracker.activeTurnID == nil, "Turn completion did not clear the deadline")
        try expect(tracker.expiration(turnID: 41, now: 200) == nil, "Completed turn remained armed")
    }

    private static func testTranscriptionAggregation() throws {
        var accumulator = GeminiTranscriptionAccumulator()
        accumulator.append("go")
        accumulator.append("go")
        accumulator.append(".")
        try expect(accumulator.text == "gogo.", "Ordered transcription deltas were deduplicated or reordered")
        accumulator.reset()
        try expect(accumulator.text.isEmpty, "Transcription reset retained a prior turn")
    }

    private static func testMicrophoneTurnAssociationOrdering() throws {
        var callbackBeforeInterruption = GeminiMicrophoneTurnAssociation()
        callbackBeforeInterruption.noteModelResponseStarted()
        try expect(
            callbackBeforeInterruption.noteLocalTranscript() == .associateWithActiveResponse,
            "A callback during model output was assigned to a new response"
        )
        try expect(
            callbackBeforeInterruption.noteInterruption(),
            "Callback-before-interruption ordering lost the barge-in follow-up"
        )
        try expect(
            callbackBeforeInterruption.awaitingInterruptedTurnCompletion,
            "Interruption did not retain the old turn-completion boundary"
        )
        try expect(
            callbackBeforeInterruption.consumeInterruptedTurnCompletion(),
            "The old interrupted turn's trailing completion was not consumed"
        )
        try expect(
            !callbackBeforeInterruption.awaitingInterruptedTurnCompletion,
            "The old interrupted turn boundary remained active"
        )

        var interruptionBeforeCallback = GeminiMicrophoneTurnAssociation()
        interruptionBeforeCallback.noteModelResponseStarted()
        try expect(
            !interruptionBeforeCallback.noteInterruption(),
            "An interruption without a prior callback invented a follow-up"
        )
        try expect(
            interruptionBeforeCallback.noteLocalTranscript() == .beginOrRefreshInterruptedFollowup,
            "Callback-after-interruption ordering was not assigned to the follow-up"
        )
        try expect(
            interruptionBeforeCallback.consumeInterruptedTurnCompletion(),
            "Separate interrupted and turnComplete envelopes lost their boundary"
        )

        var repeatedCallbackBeforeResponse = GeminiMicrophoneTurnAssociation()
        try expect(
            repeatedCallbackBeforeResponse.noteLocalTranscript() == .beginAwaitingResponse,
            "The first raw callback did not begin a response wait"
        )
        _ = repeatedCallbackBeforeResponse.noteLocalTranscript(hasTrackedTurn: true)
        try expect(
            repeatedCallbackBeforeResponse.noteInterruption(),
            "A second callback before model output was lost when interruption followed"
        )
        try expect(
            repeatedCallbackBeforeResponse.consumeInterruptedTurnCompletion(),
            "The interrupted no-response turn did not preserve its completion boundary"
        )

        var completedTurn = GeminiMicrophoneTurnAssociation()
        completedTurn.noteModelResponseStarted()
        _ = completedTurn.noteLocalTranscript()
        completedTurn.reset()
        try expect(
            !completedTurn.consumeInterruptedTurnCompletion(),
            "Normal completion retained a stale barge-in notice"
        )
    }

    private static func testToolAndSessionParsing() throws {
        let message = """
        {
          "toolCall": {
            "functionCalls": [{
              "id": "call-123",
              "name": "robot_action",
              "args": {"action":"look_at", "target_id":"red-cup-1"}
            }]
          },
          "toolCallCancellation": {"ids":["call-456"]},
          "sessionResumptionUpdate": {"resumable":true, "newHandle":"handle-789"},
          "goAway": {"timeLeft":"5s"}
        }
        """
        let event = try GeminiRoboticsProtocol.parseServerMessage(Data(message.utf8))
        try expect(event.toolCalls.count == 1, "Tool call was not parsed")
        try expect(event.toolCalls[0].id == "call-123", "Tool call ID was not preserved")
        try expect(event.toolCalls[0].arguments["action"] as? String == "look_at", "Tool arguments were not parsed")
        try expect(event.cancelledToolCallIDs == ["call-456"], "Cancellation IDs were not parsed")
        try expect(event.resumptionHandle == "handle-789", "Resumption handle was not parsed")
        try expect(event.shouldReconnect, "GoAway should request reconnection")

        let nonResumable = try GeminiRoboticsProtocol.parseServerMessage(
            Data(#"{"sessionResumptionUpdate":{"resumable":false}}"#.utf8)
        )
        try expect(nonResumable.isResumable == false, "A non-resumable session update was not parsed")
        try expect(nonResumable.resumptionHandle == nil, "A non-resumable update must not expose a handle")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw FixtureFailure.failed(message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw FixtureFailure.failed(message)
        }
        return value
    }
}
