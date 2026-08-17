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
        try testRuntimeSettingsDefaultsAndOverrides()
        try testPromptPreservesWakePhrase()
        try testMediaMessages()
        try testRealtimeTextMessage()
        try testServerTurnParsing()
        try testDiagnosticsStateAndRedaction()
        try testIndependentTranscriptionParsing()
        try testTranscriptionAggregation()
        try testMicrophoneTurnAssociationOrdering()
        try testTurnDeadlineTracking()
        try testFailureCircuitBreakerThresholdAndCooldownBoundary()
        try testFailureCircuitBreakerRollingWindow()
        try testFailureCircuitBreakerSuccessReset()
        try testToolAndSessionParsing()
        try testPriorityStopPolicy()
        print("Gemini Robotics protocol fixtures passed")
    }

    private static func testPriorityStopPolicy() throws {
        let stop = GeminiRoboticsToolCall(
            id: "stop-1",
            name: "robot_action",
            arguments: ["action": "stop_motion"]
        )
        let gesture = GeminiRoboticsToolCall(
            id: "gesture-1",
            name: "robot_action",
            arguments: ["action": "play_gesture", "gesture": "b1.salute"]
        )
        let unrelated = GeminiRoboticsToolCall(
            id: "other-1",
            name: "other_tool",
            arguments: ["action": "stop_motion"]
        )
        try expect(GeminiRoboticsToolPolicy.requiresPriorityDispatch(stop), "stop_motion must bypass ordinary tool work")
        try expect(!GeminiRoboticsToolPolicy.requiresPriorityDispatch(gesture), "A gesture was incorrectly prioritized")
        try expect(!GeminiRoboticsToolPolicy.requiresPriorityDispatch(unrelated), "An unrelated tool was incorrectly prioritized")
        let news = GeminiRoboticsToolCall(
            id: "news-1",
            name: ROBNewsSearchService.toolName,
            arguments: ["source": "rt", "limit": 3]
        )
        try expect(
            GeminiRoboticsToolPolicy.dispatchRoute(for: news) == .localNews,
            "search_news must bypass the robot-action delegate"
        )
        try expect(
            GeminiRoboticsToolPolicy.dispatchRoute(for: gesture) == .delegate,
            "robot_action must stay on the controller delegate path"
        )
        try expect(!GeminiRoboticsToolPolicy.requiresPriorityDispatch(news), "News lookup was incorrectly put on the safety-stop lane")
        try expect(
            GeminiRoboticsToolPolicy.isStageContextID("stage:fixture-turn"),
            "A stage text-turn context was not recognized"
        )
        try expect(
            !GeminiRoboticsToolPolicy.isStageContextID("local-stage:fixture-turn"),
            "A local-provider request was confused with a Gemini stage turn"
        )
        try expect(
            !GeminiRoboticsToolPolicy.isStageContextID(nil),
            "An uncorrelated tool call was incorrectly assigned to a stage turn"
        )
    }

    private static func testPromptPreservesWakePhrase() throws {
        try expect(
            GeminiRoboticsConfiguration.defaultSystemInstruction.contains("Google Search is also already authorized by Cerebro"),
            "The system instruction must not send informational requests to ROBController"
        )
        try expect(
            GeminiRoboticsConfiguration.defaultSystemInstruction.contains("always call search_news first") &&
                GeminiRoboticsConfiguration.defaultSystemInstruction.contains("untrusted publisher data") &&
                GeminiRoboticsConfiguration.defaultSystemInstruction.contains("never requires ROBController approval"),
            "The default instruction must route current publisher news through the trusted local boundary"
        )
        try expect(
            GeminiRoboticsConfiguration.defaultSystemInstruction.contains("never complete a recognized user turn silently"),
            "The default Live instruction must require a spoken acknowledgement"
        )
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

        let malformedMediaConfiguration = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-key",
                "GEMINI_ROBOTICS_STREAM_AUDIO": "flase",
                "GEMINI_ROBOTICS_STREAM_VIDEO": "certainly",
                "GEMINI_ROBOT_ACTION_TOOL_ENABLED": "enabled",
                "GEMINI_GOOGLE_SEARCH_ENABLED": "dangerously",
                "GEMINI_NEWS_SEARCH_ENABLED": "probably"
            ]),
            "Malformed optional flags should not invalidate an otherwise usable configuration"
        )
        try expect(!malformedMediaConfiguration.streamsAudio, "Malformed audio flag must fail closed")
        try expect(!malformedMediaConfiguration.streamsVideo, "Malformed video flag must fail closed")
        try expect(!malformedMediaConfiguration.exposesRobotActionTool, "Malformed action-tool flag must fail closed")
        try expect(!malformedMediaConfiguration.enablesGoogleSearch, "Malformed Search flag must fail closed")
        try expect(!malformedMediaConfiguration.enablesNewsSearch, "Malformed news-search flag must fail closed")

        let defaultToolConfiguration = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-key"
            ]),
            "Default-tool fixture configuration should load"
        )
        try expect(defaultToolConfiguration.exposesRobotActionTool, "Robot action tool should be exposed by default")
        try expect(defaultToolConfiguration.enablesGoogleSearch, "Google Search should be enabled by default")
        try expect(defaultToolConfiguration.enablesNewsSearch, "Read-only news search should be enabled by default")
        let defaultSetup = GeminiRoboticsProtocol.setupMessage(
            configuration: defaultToolConfiguration,
            resumptionHandle: nil
        )
        let defaultSetupBody = try require(
            defaultSetup["setup"] as? [String: Any],
            "Default-tool setup envelope is missing"
        )
        let defaultTools = try require(
            defaultSetupBody["tools"] as? [[String: Any]],
            "Default setup did not expose tools"
        )
        try expect(
            defaultTools.contains {
                ($0["googleSearch"] as? [String: Any])?.isEmpty == true
            },
            "Default setup did not declare Google Search"
        )
        let defaultFunctionNames = defaultTools.flatMap {
            ($0["functionDeclarations"] as? [[String: Any]]) ?? []
        }.compactMap { $0["name"] as? String }
        try expect(
            defaultFunctionNames.contains("robot_action"),
            "Default setup did not declare robot_action"
        )
        try expect(
            defaultFunctionNames.contains(ROBNewsSearchService.toolName),
            "Default setup did not declare search_news"
        )

        let explicitlyDisabledTools = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-key",
                "GEMINI_ROBOT_ACTION_TOOL_ENABLED": "false",
                "GEMINI_GOOGLE_SEARCH_ENABLED": "false",
                "GEMINI_NEWS_SEARCH_ENABLED": "false"
            ]),
            "Explicitly disabled tool fixture configuration should load"
        )
        try expect(!explicitlyDisabledTools.exposesRobotActionTool, "Explicit robot-action disable was ignored")
        try expect(!explicitlyDisabledTools.enablesGoogleSearch, "Explicit Google Search disable was ignored")
        try expect(!explicitlyDisabledTools.enablesNewsSearch, "Explicit news-search disable was ignored")
        let disabledSetup = GeminiRoboticsProtocol.setupMessage(
            configuration: explicitlyDisabledTools,
            resumptionHandle: nil
        )
        let disabledSetupBody = try require(
            disabledSetup["setup"] as? [String: Any],
            "Disabled-tool setup envelope is missing"
        )
        try expect(
            disabledSetupBody["tools"] == nil,
            "Explicitly disabling both tools should omit the setup tools array"
        )

        let newsOnlyConfiguration = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-key",
                "GEMINI_ROBOT_ACTION_TOOL_ENABLED": "false",
                "GEMINI_GOOGLE_SEARCH_ENABLED": "false"
            ]),
            "News-only fixture configuration should load"
        )
        let newsOnlySetup = try require(
            GeminiRoboticsProtocol.setupMessage(
                configuration: newsOnlyConfiguration,
                resumptionHandle: nil
            )["setup"] as? [String: Any],
            "News-only setup envelope is missing"
        )
        let newsOnlyTools = try require(
            newsOnlySetup["tools"] as? [[String: Any]],
            "News search must remain available independently of robot_action and Google Search"
        )
        let newsOnlyNames = newsOnlyTools.flatMap {
            ($0["functionDeclarations"] as? [[String: Any]]) ?? []
        }.compactMap { $0["name"] as? String }
        try expect(newsOnlyNames == [ROBNewsSearchService.toolName], "News-only setup exposed the wrong function tools")
    }

    private static func testRuntimeSettingsDefaultsAndOverrides() throws {
        let configuration = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-key",
                "GEMINI_ROBOTICS_STREAM_AUDIO": "false",
                "GEMINI_ROBOTICS_STREAM_VIDEO": "true"
            ]),
            "Runtime-settings fixture configuration should load"
        )

        let firstRun = GeminiRoboticsRuntimeSettings(configuration: configuration)
        try expect(firstRun.connectionEnabled, "An explicitly enabled existing deployment should connect on first run")
        try expect(!firstRun.streamsAudio, "First-run audio should inherit launch configuration")
        try expect(firstRun.streamsVideo, "First-run video should inherit launch configuration")

        let persisted = GeminiRoboticsRuntimeSettings(
            configuration: configuration,
            storedConnectionEnabled: false,
            storedAudioStreamingEnabled: true,
            storedVideoStreamingEnabled: false
        )
        try expect(!persisted.connectionEnabled, "Persisted connection-off intent was ignored")
        try expect(persisted.streamsAudio, "Persisted audio override was ignored")
        try expect(!persisted.streamsVideo, "Persisted video override was ignored")

        let unavailable = GeminiRoboticsRuntimeSettings(
            configuration: nil,
            storedConnectionEnabled: true,
            storedAudioStreamingEnabled: true,
            storedVideoStreamingEnabled: true
        )
        try expect(
            unavailable == GeminiRoboticsRuntimeSettings(configuration: nil),
            "Stored preferences must not bypass missing launch configuration or credentials"
        )
    }

    private static func testConfigurationAndSetup() throws {
        let environment = [
            "GEMINI_ROBOTICS_ENABLED": "true",
            "GEMINI_API_KEY": "fixture-key",
            "GEMINI_ROBOTICS_MODEL": "gemini-robotics-er-2-streaming-preview",
            "GEMINI_ROBOT_ACTION_TOOL_ENABLED": "true",
            "GEMINI_GOOGLE_SEARCH_ENABLED": "true"
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
        try expect(
            (tools.first?["googleSearch"] as? [String: Any])?.isEmpty == true,
            "Google Search was not declared as a server-side Live tool"
        )
        let declarations = try require(
            tools.dropFirst().first?["functionDeclarations"] as? [[String: Any]],
            "Missing function declarations"
        )
        let robotDeclaration = try require(
            declarations.first { $0["name"] as? String == "robot_action" },
            "Missing robot_action declaration"
        )
        try expect(robotDeclaration["behavior"] as? String == "BLOCKING", "Physical tools must be blocking")
        let parameters = try require(
            robotDeclaration["parameters"] as? [String: Any],
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

        let newsDeclaration = try require(
            declarations.first { $0["name"] as? String == ROBNewsSearchService.toolName },
            "Missing search_news declaration"
        )
        try expect(newsDeclaration["behavior"] as? String == "BLOCKING", "News lookup must wait for its feed result")
        let newsParameters = try require(
            newsDeclaration["parameters"] as? [String: Any],
            "Missing search_news parameters"
        )
        try expect(newsParameters["required"] as? [String] == ["source"], "search_news must require a source")
        let newsProperties = try require(
            newsParameters["properties"] as? [String: Any],
            "Missing search_news properties"
        )
        let source = try require(newsProperties["source"] as? [String: Any], "Missing news source schema")
        try expect(
            Set(source["enum"] as? [String] ?? []) == Set(ROBNewsSource.identifiers + ["all"]),
            "News source allowlist changed"
        )
        let newsLimit = try require(newsProperties["limit"] as? [String: Any], "Missing news limit schema")
        try expect((newsLimit["minimum"] as? NSNumber)?.intValue == 1, "News limit minimum changed")
        try expect((newsLimit["maximum"] as? NSNumber)?.intValue == 5, "News limit maximum changed")

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

        let streamEnd = GeminiRoboticsProtocol.audioStreamEndMessage()
        let realtimeStreamEnd = try require(
            streamEnd["realtimeInput"] as? [String: Any],
            "Missing audio stream-end envelope"
        )
        try expect(
            realtimeStreamEnd["audioStreamEnd"] as? Bool == true,
            "Turning off microphone streaming must emit audioStreamEnd"
        )
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

    private static func testDiagnosticsStateAndRedaction() throws {
        let localTextConfiguration = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-secret-key",
                "GEMINI_ROBOTICS_STREAM_AUDIO": "false",
                "GEMINI_ROBOTICS_STREAM_VIDEO": "false"
            ]),
            "Local-text diagnostics configuration should load"
        )
        let localTextStore = GeminiRoboticsDiagnosticsStore(configuration: localTextConfiguration)
        localTextStore.noteConnectionState("ready")
        let localTextSnapshot = localTextStore.snapshot()
        try expect(!localTextSnapshot.streamsAudio, "Requested audio flag should be false")
        try expect(!localTextSnapshot.streamsVideo, "Requested video flag should be false")
        try expect(localTextSnapshot.inputMode == .localText, "Disabled raw audio should use local text")
        localTextStore.noteRuntimeSettings(GeminiRoboticsRuntimeSettings(
            configuration: localTextConfiguration,
            storedConnectionEnabled: false,
            storedAudioStreamingEnabled: true,
            storedVideoStreamingEnabled: true
        ))
        let operatorDisabledSnapshot = localTextStore.snapshot()
        try expect(!operatorDisabledSnapshot.isConnectionEnabled, "Runtime connection-off state was not retained")
        try expect(operatorDisabledSnapshot.inputMode == .disabled, "Connection off must disable all Gemini input")

        let rawAudioConfiguration = try require(
            GeminiRoboticsConfiguration.fromEnvironment([
                "GEMINI_ROBOTICS_ENABLED": "true",
                "GEMINI_API_KEY": "fixture-secret-key",
                "GEMINI_ROBOTICS_STREAM_AUDIO": "true",
                "GEMINI_ROBOTICS_STREAM_VIDEO": "true",
                "GEMINI_ROBOT_ACTION_TOOL_ENABLED": "true"
            ]),
            "Raw-audio diagnostics configuration should load"
        )
        let store = GeminiRoboticsDiagnosticsStore(configuration: rawAudioConfiguration)
        try expect(store.snapshot().inputMode == .localText, "A session that is not ready should use text fallback")
        store.noteConnectionState("ready")
        try expect(
            store.snapshot().inputMode == .localText,
            "Requested audio must not become effective before the session actor applies it"
        )
        let appliedSettings = GeminiRoboticsRuntimeSettings(configuration: rawAudioConfiguration)
        store.noteRuntimeSettingsApplied(appliedSettings)
        try expect(store.snapshot().inputMode == .rawAudio, "A ready audio session should report raw audio")
        try expect(store.snapshot().isAudioStreamingApplied, "Applied audio state was not retained")
        try expect(store.snapshot().isVideoStreamingApplied, "Applied video state was not retained")

        store.noteVideoFrameEncoded()
        store.noteVideoFrameEncoded()
        let videoSendDate = Date(timeIntervalSince1970: 1_700_000_000)
        store.noteVideoFrameSent(at: videoSendDate)

        var event = GeminiRoboticsServerEvent()
        event.textFragments = ["private model output"]
        event.inputTranscription = "private microphone transcript"
        event.outputTranscription = "private spoken reply"
        event.turnComplete = true
        event.interrupted = true
        event.toolCalls = [GeminiRoboticsToolCall(
            id: "private-call-id",
            name: "private-tool-name",
            arguments: ["secret": "private-tool-argument"]
        )]
        event.cancelledToolCallIDs = ["private-cancel-id"]
        event.isResumable = true
        event.resumptionHandle = "private-resumption-handle"
        event.shouldReconnect = true
        event.serverError = "private-server-error-detail"
        let serverEventDate = Date(timeIntervalSince1970: 1_700_000_010)
        store.noteServerEvent(event, at: serverEventDate)

        store.noteConnectionState("reconnecting")
        let snapshot = store.snapshot()
        try expect(snapshot.inputMode == .localText, "Reconnect should expose the active local-text fallback")
        try expect(snapshot.videoFramesEncoded == 2, "Encoded frame count changed unexpectedly")
        try expect(snapshot.videoFramesSent == 1, "Sent frame count changed unexpectedly")
        try expect(snapshot.lastVideoSendDate == videoSendDate, "Last video send date was not retained")
        try expect(snapshot.lastServerEventDate == serverEventDate, "Last server event date was not retained")
        let summary = try require(snapshot.lastServerEvent, "Missing server event summary")
        for category in [
            "model output (1 part)", "input transcription", "output transcription",
            "turn complete", "interrupted", "tool calls (1)", "tool cancellations (1)",
            "session resumption update", "go away", "server error"
        ] {
            try expect(summary.contains(category), "Diagnostics summary omitted \(category)")
        }
        for privateValue in [
            "private model output", "private microphone transcript", "private spoken reply",
            "private-call-id", "private-tool-name", "private-tool-argument", "private-cancel-id",
            "private-resumption-handle", "private-server-error-detail", "fixture-secret-key"
        ] {
            try expect(!summary.contains(privateValue), "Diagnostics leaked \(privateValue)")
        }

        let failureDate = Date(timeIntervalSince1970: 1_700_000_020)
        store.noteRequestFailure(
            "Gemini's request queue is full. private-provider-detail",
            at: failureDate
        )
        let failureSnapshot = store.snapshot()
        try expect(
            failureSnapshot.lastRequestFailureCategory == "queue_full",
            "Request failure did not retain its redacted category"
        )
        try expect(
            failureSnapshot.lastRequestFailureDate == failureDate,
            "Request failure date was not retained"
        )
        try expect(
            !String(describing: failureSnapshot).contains("private-provider-detail"),
            "Request diagnostics retained raw provider failure detail"
        )

        store.noteRequestFailure(
            "Gemini did not start a response to the microphone input within 6 seconds.",
            at: failureDate
        )
        try expect(
            store.snapshot().lastRequestFailureCategory == "raw_response_start_timeout",
            "Raw microphone silence was not classified separately"
        )

        let transcriptionDate = Date(timeIntervalSince1970: 1_700_000_025)
        store.noteServerInputTranscription(characterCount: 18, at: transcriptionDate)
        store.noteRawTurnTimeout(kind: "response_start", at: transcriptionDate)
        let audioSnapshot = store.snapshot()
        try expect(
            audioSnapshot.serverInputTranscriptionEventCount == 1 &&
                audioSnapshot.lastServerInputTranscriptionCharacterCount == 18 &&
                audioSnapshot.lastServerInputTranscriptionDate == transcriptionDate,
            "Redacted server input-transcription telemetry changed"
        )
        try expect(
            audioSnapshot.rawTurnTimeoutCount == 1 &&
                audioSnapshot.lastRawTurnTimeoutKind == "response_start" &&
                audioSnapshot.lastRawTurnTimeoutDate == transcriptionDate,
            "Raw microphone timeout telemetry changed"
        )

        let fallbackDate = Date(timeIntervalSince1970: 1_700_000_030)
        store.noteLocalFallback(provider: "Swift MLX", at: fallbackDate)
        store.noteLocalFallback(provider: "Apple Foundation Models", at: fallbackDate)
        let fallbackSnapshot = store.snapshot()
        try expect(fallbackSnapshot.localFallbackCount == 2, "Local fallback count changed")
        try expect(
            fallbackSnapshot.lastLocalFallbackProvider == "Apple Foundation Models",
            "Latest local fallback provider was not retained"
        )
        try expect(
            fallbackSnapshot.lastLocalFallbackDate == fallbackDate,
            "Local fallback date was not retained"
        )

        let disabledStore = GeminiRoboticsDiagnosticsStore(configuration: nil)
        let disabledSnapshot = disabledStore.snapshot()
        try expect(!disabledSnapshot.isConfigured, "Missing configuration should remain disabled")
        try expect(disabledSnapshot.inputMode == .disabled, "Missing configuration should disable Gemini input")
        try expect(
            GeminiRoboticsProtocol.diagnosticsSummary(for: GeminiRoboticsServerEvent()) == "message received",
            "Unknown server envelopes need a safe generic summary"
        )
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

    private static func testFailureCircuitBreakerThresholdAndCooldownBoundary() throws {
        var breaker = GeminiFailureCircuitBreaker()
        try expect(breaker.failureThreshold == 2, "Gemini failure threshold changed")
        try expect(breaker.failureWindow == 60, "Gemini failure window changed")
        try expect(breaker.cooldown == 90, "Gemini cooldown changed")
        try expect(!breaker.isOpen(now: 100), "A fresh Gemini circuit started open")
        try expect(!breaker.recordFailure(now: 100), "One Gemini failure opened the circuit")
        try expect(
            breaker.recordFailure(now: 160),
            "Two Gemini failures at the inclusive 60-second boundary did not open the circuit"
        )
        try expect(breaker.openUntil == 250, "Gemini circuit did not open for exactly 90 seconds")
        try expect(breaker.isOpen(now: 249.999), "Gemini circuit closed before its cooldown elapsed")
        try expect(
            breaker.recordFailure(now: 200),
            "A failure observed during cooldown did not report an open circuit"
        )
        try expect(breaker.openUntil == 250, "A failure during cooldown extended the open interval")
        try expect(!breaker.isOpen(now: 250), "Gemini circuit stayed open at the cooldown boundary")
        try expect(breaker.openUntil == nil, "Expired Gemini cooldown state was not cleared")
        try expect(
            breaker.remainingCooldown(now: 250) == nil,
            "Expired Gemini circuit reported a remaining cooldown"
        )
    }

    private static func testFailureCircuitBreakerRollingWindow() throws {
        var breaker = GeminiFailureCircuitBreaker()
        try expect(!breaker.recordFailure(now: 0), "The first rolling-window failure opened the circuit")
        try expect(
            !breaker.recordFailure(now: 61),
            "Failures more than 60 seconds apart opened the Gemini circuit"
        )
        try expect(
            breaker.recordFailure(now: 121),
            "The retained failure at the inclusive rolling-window boundary did not open the circuit"
        )
        try expect(breaker.openUntil == 211, "Rolling-window failure opened with the wrong cooldown")
    }

    private static func testFailureCircuitBreakerSuccessReset() throws {
        var breaker = GeminiFailureCircuitBreaker()
        try expect(!breaker.recordFailure(now: 10), "The first pre-success failure opened the circuit")
        breaker.recordSuccess()
        try expect(
            !breaker.recordFailure(now: 20),
            "A Gemini success did not clear the prior failure count"
        )
        try expect(breaker.recordFailure(now: 30), "Two post-reset failures did not open the circuit")
        try expect(breaker.isOpen(now: 30), "Gemini circuit was not open after reaching its threshold")

        breaker.recordSuccess()
        try expect(!breaker.isOpen(now: 30), "A Gemini success did not close an open circuit")
        try expect(breaker.openUntil == nil, "A Gemini success retained the open-until deadline")
        try expect(
            !breaker.recordFailure(now: 31),
            "The first failure after an open-circuit success reset reopened the circuit"
        )
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
