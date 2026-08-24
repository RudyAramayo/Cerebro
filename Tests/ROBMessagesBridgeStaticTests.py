#!/usr/bin/env python3
"""Static integration checks for ROB's isolated Apple Messages bridge."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = ROOT / "Cerebro" / "ROBMessagesBridge.swift"
RESPONDER_PATH = ROOT / "Cerebro" / "ROBMessagesAIResponder.swift"
BRIDGE = BRIDGE_PATH.read_text(encoding="utf-8")
RESPONDER = RESPONDER_PATH.read_text(encoding="utf-8")
TRANSCRIPT = (
    ROOT / "Cerebro" / "ROBMessagesTranscriptStore.swift"
).read_text(encoding="utf-8")
LOCAL_PROVIDER_SOURCE = (
    ROOT / "Cerebro" / "ROBAI.swift"
).read_text(encoding="utf-8")
LOCAL_PROVIDER_START = LOCAL_PROVIDER_SOURCE.index("enum ROBIsolatedLocalTextRole")
LOCAL_PROVIDER_END = LOCAL_PROVIDER_SOURCE.index(
    "private actor ROBLocalConversationFallback",
    LOCAL_PROVIDER_START,
)
LOCAL_PROVIDER = LOCAL_PROVIDER_SOURCE[LOCAL_PROVIDER_START:LOCAL_PROVIDER_END]
MAIN = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(encoding="utf-8")
SETTINGS = (
    ROOT / "Cerebro" / "ROBPythonSettingsWindowController.m"
).read_text(encoding="utf-8")
STATUS = (ROOT / "Cerebro" / "ROBSystemStatusCoordinator.swift").read_text(
    encoding="utf-8"
)
INFO = (ROOT / "Cerebro" / "Info.plist").read_text(encoding="utf-8")
ENTITLEMENTS = (ROOT / "Cerebro" / "Cerebro.entitlements").read_text(
    encoding="utf-8"
)
PROJECT = (ROOT / "Cerebro.xcodeproj" / "project.pbxproj").read_text(
    encoding="utf-8"
)
CURRENT_INFORMATION = (
    ROOT / "Cerebro" / "ROBMessagesCurrentInformationService.swift"
).read_text(encoding="utf-8")
WEATHER = (
    ROOT / "Cerebro" / "ROBWeatherSearchService.swift"
).read_text(encoding="utf-8")
VISION_REPLY_POLICY = (
    ROOT / "Cerebro" / "ROBMessagesVisionReplyPolicy.swift"
).read_text(encoding="utf-8")
TRANSCRIPT_WINDOW = (
    ROOT / "Cerebro" / "ROBMessagesTranscriptWindowController.swift"
).read_text(encoding="utf-8")
COMMAND_WINDOW = (
    ROOT / "Cerebro" / "ROBMessagesAdministratorCommandWindowController.swift"
).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    require(
        'defaultAccountIdentifier = "rob@orbitusrobotics.com"' in BRIDGE,
        "The Messages bridge is no longer scoped to ROB's requested account by default",
    )
    require(
        "configuration.enabled" in BRIDGE
        and 'enabledDefaultsKey = "ROBMessagesBridgeEnabled"' in BRIDGE,
        "The permission-sensitive Messages bridge must remain explicitly enableable and default-off",
    )

    require(
        "SQLITE_OPEN_READONLY" in BRIDGE and '"PRAGMA query_only = ON"' in BRIDGE,
        "The inbox database is not opened and enforced as read-only",
    )
    require(
        "highestRowID()" in BRIDGE
        and "if let currentCursor" in BRIDGE
        and "after: currentCursor" in BRIDGE
        and "UserDefaults.standard.removeObject(forKey: Self.cursorDefaultsKey)" in BRIDGE,
        "First enablement no longer seeds a high-water cursor before polling new messages",
    )
    require(
        'recentGUIDsDefaultsKey = "ROBMessagesBridgeRecentMessageGUIDs"' in BRIDGE
        and "seenGUIDs.contains(message.guid)" in BRIDGE
        and "rememberMessageGUID(message.guid)" in BRIDGE,
        "Inbound GUID deduplication is missing or no longer persists across restarts",
    )

    require(
        "chatAccountCandidates.contains" in BRIDGE
        and "accountCandidate($0, matches: configuredAccount)" in BRIDGE
        and 'chatColumns.contains("last_addressed_handle")' in BRIDGE
        and 'chatColumns.contains("account_login")' in BRIDGE,
        "Inbound routes are not proven to belong to the configured receiving account",
    )
    require(
        "!message.isFromMe" in BRIDGE and "sender != configuredAccount" in BRIDGE,
        "Outbound/self Messages events are no longer rejected before AI submission",
    )
    require(
        "configuration.allowAllSenders" in BRIDGE
        and "configuration.allowedSenders.contains(sender)" in BRIDGE
        and 'allowAllSendersDefaultsKey = "ROBMessagesBridgeAllowAllSenders"' in BRIDGE,
        "The sender policy no longer distinguishes restricted and explicit public mode",
    )
    require(
        "allowAllSenders = configuration.allowAllSenders" in BRIDGE
        and "allowAllSenders ||" in BRIDGE
        and "allowedSenders.contains(sender)" in BRIDGE
        and "ROBMessagesAdministratorPolicy.isAdministrator(sender)" in BRIDGE,
        "The final reply gate no longer authorizes explicit public mode",
    )
    administrator_contract = [
        '"orbitus@orbitusrobotics.com"',
        '"+19253238322"',
        '"mkierie@gmail.com"',
        'command: "Shutdown"',
        'command: "Reboot"',
        'confirmationResponse: "YES"',
        'tell application id "com.apple.systemevents" to shut down',
        'tell application id "com.apple.systemevents" to restart',
        "message.attachmentCount == 0",
        "case .sendingQuestion:",
        "case .awaitingResponse:",
        "pending.command.confirms(text)",
        "authorizationGate.authorizes(",
        "try executor.execute(script: pending.command.script)",
    ]
    require(
        all(symbol in BRIDGE for symbol in administrator_contract),
        "Administrator commands lost fixed identities, confirmation gating, or final authorization",
    )
    require(
        'process.executableURL = URL(fileURLWithPath: "/bin/zsh")' in BRIDGE
        and 'process.arguments = ["-f", "-s"]' in BRIDGE
        and "process.standardInput = inputPipe" in BRIDGE
        and '"-c"' not in BRIDGE[BRIDGE.index("final class ROBMessagesZshAdministratorCommandExecutor"):BRIDGE.index("enum ROBMessagesInboxError")],
        "Administrator scripts must use a fixed zsh executable and stdin without shell interpolation",
    )
    require(
        'state = "processing"' in BRIDGE
        and "Waiting for \\(pendingRoutes.count) isolated text reply" in BRIDGE,
        "Accepted Messages no longer make processing visible in bridge status",
    )
    require(
        "message.participantCount == 1" in BRIDGE
        and "message.chatJoinCount == 1" in BRIDGE
        and "message.soleChatParticipant" in BRIDGE,
        "Group, ambiguous, or sender-mismatched Messages routes are no longer rejected",
    )
    require(
        "configuration.allowsImages" in BRIDGE
        and "message.attachmentCount == 1" in BRIDGE
        and "message.attachment?.isSupportedImageDeclaration == true" in BRIDGE
        and 'tableExists("message_attachment_join"' in BRIDGE
        and 'tableExists("attachment"' in BRIDGE
        and "maximumCompressedBytes = 10 * 1_024 * 1_024" in BRIDGE
        and "maximumPixelCount = 24_000_000" in BRIDGE
        and "resolvingSymlinksInPath()" in BRIDGE
        and "CGImageSourceCreateThumbnailAtIndex" in BRIDGE,
        "Messages image ingestion is not single-image, bounded, and attachment-root confined",
    )
    require(
        "message.itemType == 0" in BRIDGE
        and "message.groupActionType == 0" in BRIDGE
        and "message.associatedMessageGUID" in BRIDGE,
        "Reactions, edits, deletions, or other service events can reach the AI",
    )
    require(
        "maximumInboundCharacters" in BRIDGE
        and "maximumUTF8Bytes" in BRIDGE
        and "ROBMessagesPlainTextPolicy.normalized(message.text)" in BRIDGE,
        "The Messages text-only input boundary is no longer bounded",
    )
    require(
        "ROBMessagesAttributedBodyDecoder" in BRIDGE
        and "maximumArchiveBytes = 64 * 1_024" in BRIDGE
        and "NSUnarchiver(" not in BRIDGE
        and "NSUnarchiver.unarchive" not in BRIDGE
        and "decodeCanonicalUnsignedInteger" in BRIDGE
        and "sqlite3_column_bytes" in BRIDGE,
        "The bounded attributedBody typed-stream fallback is missing",
    )

    require(
        'let contextID = "messages:\\(UUID().uuidString.lowercased())"' in BRIDGE
        and "pendingRoutes[contextID]" in BRIDGE,
        "Messages requests do not receive unique correlated contexts",
    )
    require(
        "chatID: message.chatID" in BRIDGE
        and "let canonicalSender = ROBMessagesBridgeConfiguration.canonicalHandle(message.sender)"
        in BRIDGE
        and "sender: canonicalSender" in BRIDGE
        and "originatingAccountAliases: message.chatAccountCandidates" in BRIDGE
        and "toChat: route.chatID" in BRIDGE
        and "originatingAccountAliases: route.originatingAccountAliases" in BRIDGE
        and "expectedSender: route.sender" in BRIDGE,
        "AI responses are not routed to the immutable originating chat, account aliases, and sender",
    )
    require(
        'process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")' in BRIDGE
        and '"-e", Self.script, "--", chatID, boundedReply, account, expectedSender'
        in BRIDGE,
        "Messages reply text must travel as a Process argument, never through shell interpolation",
    )
    require(
        "if (count of argv) is less than 5" in BRIDGE
        and "set expectedSender to item 4 of argv" in BRIDGE
        and "set expectedAccountAliases to items 5 thru -1 of argv" in BRIDGE
        and "on compactPhonePresentation(candidateValue, expectedValue)" in BRIDGE
        and "on accountMatchesAlias(accountDescription, accountID, expectedAlias)" in BRIDGE
        and "repeat with expectedAliasValue in expectedAccountAliases" in BRIDGE
        and "if accountMatchesRoute is false" in BRIDGE
        and "accountID does not contain expectedAccount" not in BRIDGE
        and "set targetParticipants to participants of targetChat" in BRIDGE
        and "if (count of targetParticipants) is not 1" in BRIDGE
        and "if comparedParticipantHandle is not comparedExpectedSender" in BRIDGE,
        "The reply sender no longer revalidates the exact one-to-one participant before sending",
    )

    isolated_configuration = [
        "streamsAudio: false",
        "streamsVideo: true",
        "exposesRobotActionTool: false",
        "enablesGoogleSearch: true",
        "enablesNewsSearch: true",
        "enablesAppleMusic: false",
        'responseModality: "TEXT"',
    ]
    require(
        all(setting in RESPONDER for setting in isolated_configuration),
        "The Messages AI profile lost bounded image input, read-only search, or isolation from action/audio surfaces",
    )
    require(
        "sessionsByChatID" in RESPONDER
        and "ROBAI(configuration:" in RESPONDER,
        "Messages chats no longer own isolated AI conversation sessions",
    )
    provider_contract = [
        "ROBMessagesAIProvider",
        'case gemini = "Gemini"',
        'case local = "On-device local"',
        "scheduleGeminiTimeout(for:",
        "beginLocalFallback(contextID:",
        "geminiFailure:",
        "drainLocalQueue(for:",
        "completeLocalTurn(contextID:",
        "result:",
        "allProvidersFailed(gemini:",
        "local:",
    ]
    require(
        all(symbol in RESPONDER for symbol in provider_contract),
        "Messages AI no longer implements Gemini-first, bounded local fallback, and combined errors",
    )
    require(
        "ai.sendImageJPEG(" in RESPONDER
        and "imageJPEG: jpegData" in LOCAL_PROVIDER_SOURCE
        and "let imageWasSent = try await sendVideo(" in LOCAL_PROVIDER_SOURCE
        and "GeminiRoboticsProtocol.realtimeTextMessage(turn.text)" in LOCAL_PROVIDER_SOURCE,
        "Gemini image turns no longer send a bounded still image before their correlated text",
    )
    require(
        "ROBMessagesVisionReplyPolicy.isGenericDeflection(trimmed)" in RESPONDER
        and "ROBMessagesVisionReplyPolicy.preferredReply(" in LOCAL_PROVIDER
        and "using Swift MLX analysis" in LOCAL_PROVIDER
        and "apologize for the inconvenience" in VISION_REPLY_POLICY
        and "isGrounded(reply:" in VISION_REPLY_POLICY,
        "Generic or visually ungrounded model replies can replace Swift MLX image evidence",
    )
    local_provider_contract = [
        "ROBIsolatedLocalTextProvider",
        "static func respond(",
        "prompt rawPrompt:",
        "history:",
        "ROBIsolatedLocalTextTurn",
        "ROBIsolatedLocalTextRole",
        "ROBIsolatedLocalVisionProvider",
        "analyzeMessageImage(",
        "Swift MLX visual analysis (untrusted data)",
        "refineWithAppleFoundationModels(",
    ]
    require(
        all(symbol in LOCAL_PROVIDER for symbol in local_provider_contract),
        "The isolated local Messages provider contract is incomplete",
    )
    current_information_contract = [
        "ROBMessagesCurrentInformationService.shared.context(",
        "currentInformation?.modelContext",
        "currentInformation.fallbackReply",
        "read-only publisher-news and weather services",
    ]
    require(
        all(symbol in LOCAL_PROVIDER for symbol in current_information_contract),
        "Apple Foundation Models and Swift MLX no longer receive bounded current-information results",
    )
    require(
        'case news(source: String, query: String?, limit: Int)' in CURRENT_INFORMATION
        and 'case weather(location: String?, days: Int)' in CURRENT_INFORMATION
        and '"source": source' in CURRENT_INFORMATION
        and '"location": location' in CURRENT_INFORMATION
        and "shouldReturnDirectly: allRequestsFailed" in CURRENT_INFORMATION,
        "The local current-information router lost its deterministic news/weather boundary",
    )
    require(
        'static let geocodingBaseURL = URL(' in WEATHER
        and 'string: "https://geocoding-api.open-meteo.com/v1/search"' in WEATHER
        and 'string: "https://api.open-meteo.com/v1/forecast"' in WEATHER
        and 'request.httpMethod = "GET"' in WEATHER
        and "willPerformHTTPRedirection" in WEATHER
        and "completionHandler(nil)" in WEATHER,
        "The weather service is no longer fixed-host, GET-only, bounded, and redirect rejecting",
    )
    forbidden_local_dependencies = (
        "ROBMainViewController",
        "ROBScene",
        "ROBMemory",
        "CameraManager",
        "AVCapture",
        "ROBAITool",
        "ROBRobotTool",
        "executeTool",
        "toolDeclarations",
    )
    require(
        not any(symbol in LOCAL_PROVIDER for symbol in forbidden_local_dependencies),
        "The local Messages fallback references scene, memory, camera, or tool surfaces",
    )
    require(
        "didReceiveToolCall call: ROBAIRobotToolCall" in RESPONDER
        and '"status": "rejected"' in RESPONDER,
        "The Messages AI responder lacks its defensive delegated-tool rejection",
    )

    forbidden_output_symbols = ("ROBSpeechBox", "AVSpeechSynthesizer", "sayIt:")
    combined_messages_sources = BRIDGE + RESPONDER
    require(
        not any(symbol in combined_messages_sources for symbol in forbidden_output_symbols),
        "The Messages-only response path has acquired a speech dependency",
    )
    require(
        "ROBWeatherSearchService.swift" in PROJECT
        and "ROBMessagesCurrentInformationService.swift" in PROJECT,
        "The Messages current-information services are not part of the app target",
    )
    transcript_contract = [
        "AES.GCM.seal(",
        "AES.GCM.open(",
        "HMAC<SHA256>.authenticationCode(",
        "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
        '"MessagesTranscript.sqlite3"',
        'delivery_status IN (\'delivery_pending\', \'delivered\')',
        "account_hash = ? AND sender_hash = ?",
        "maximumMemoryCharacters = 8_000",
        '"has_image":',
        "CREATE TABLE IF NOT EXISTS operator_replies",
        "try encrypt(text, contextID: contextID, field: \"reply\"",
    ]
    require(
        all(symbol in TRANSCRIPT for symbol in transcript_contract),
        "The Messages transcript is no longer encrypted, device-keyed, bounded, and same-sender scoped",
    )
    require(
        "jpegData" not in TRANSCRIPT and "imageData" not in TRANSCRIPT,
        "The Messages transcript store must never retain image pixels",
    )
    require(
        "try transcriptStore.recordInbound(" in BRIDGE
        and "memoryContext = try transcriptStore.memoryContext(" in BRIDGE
        and "try transcriptStore.recordReply(" in BRIDGE
        and "try replySender.send(" in BRIDGE
        and BRIDGE.index("try transcriptStore.recordReply(")
        < BRIDGE.index(
            "try replySender.send(",
            BRIDGE.index("try transcriptStore.recordReply("),
        ),
        "Archived Messages are not persisted before inference and reply delivery",
    )
    require(
        "memoryContext: boundedMemoryContext(memoryContext)" in RESPONDER
        and "Same-sender encrypted transcript excerpts" in RESPONDER
        and "memoryContext: turn.memoryContext" in RESPONDER
        and "for: prompt" in LOCAL_PROVIDER,
        "Same-sender memory is not bounded across Gemini/local fallback or current-information isolation",
    )
    require(
        "[[ROBMessagesBridge shared] start]" in MAIN
        and "[[ROBMessagesBridge shared] stop]" in MAIN,
        "The Messages bridge is not tied to Cerebro startup and shutdown",
    )
    require(
        'messagesTab.label = @"Messages"' in SETTINGS
        and "messagesBridgeEnabledToggle" in SETTINGS
        and "messagesReceivingAccountField" in SETTINGS
        and "messagesAllowedSendersTextView" in SETTINGS,
        "Settings no longer exposes the Messages enable, account, and sender controls",
    )
    require(
        "messagesAllowImagesToggle" in SETTINGS
        and "messagesAllowGeminiImagesToggle" in SETTINGS
        and "setConfiguredAllowsImages:" in SETTINGS
        and "setConfiguredAllowsGeminiImages:" in SETTINGS
        and 'alert.messageText = @"Send approved Messages images to Gemini?"' in SETTINGS,
        "Settings lost the separate local-image and Gemini-upload privacy controls",
    )
    require(
        "messagesArchiveToggle" in SETTINGS
        and "messagesViewTranscriptButton" in SETTINGS
        and "showMessagesTranscriptWindow:" in SETTINGS
        and "setConfiguredArchivesTranscripts:" in SETTINGS
        and "exportMessagesTranscriptTo:" in SETTINGS
        and "deleteMessagesTranscript" in SETTINGS
        and "When Gemini answers, relevant excerpts may be sent to Gemini" in SETTINGS,
        "Settings lost explicit transcript retention, export, clear, or Gemini privacy disclosure",
    )
    require(
        'window.title = "Messages Transcripts"' in TRANSCRIPT_WINDOW
        and "Search people and messages" in TRANSCRIPT_WINDOW
        and "store.browseSnapshot()" in TRANSCRIPT_WINDOW
        and "record.inboundText" in TRANSCRIPT_WINDOW
        and "record.replyText" in TRANSCRIPT_WINDOW
        and "Image attached — pixels are not stored" in TRANSCRIPT_WINDOW,
        "The local Messages transcript browser lost search, readable turns, or image privacy labeling",
    )
    require(
        "ROBMessagesWorkspaceViewController" in TRANSCRIPT_WINDOW
        and 'labelWithString: "Text Messages"' in TRANSCRIPT_WINDOW
        and 'placeholderString = "Search people and message text"' in TRANSCRIPT_WINDOW
        and 'sendButton.title = "Reply"' in TRANSCRIPT_WINDOW
        and "bridge.sendOperatorReply(" in TRANSCRIPT_WINDOW
        and 'sender = "You"' in TRANSCRIPT_WINDOW
        and "operatorReplies.map" in TRANSCRIPT_WINDOW,
        "The main Messages workspace lost direct search, replies, or operator history",
    )
    require(
        "func sendOperatorReply(" in BRIDGE
        and "authorizationGate.authorizes(" in BRIDGE
        and "inbox.replyRoute(forChatID: record.chatID)" in BRIDGE
        and "route.participantCount == 1" in BRIDGE
        and "originatingAccountAliases: route.accountCandidates" in BRIDGE
        and "toChat: record.chatID" in BRIDGE
        and "expectedSender: sender" in BRIDGE
        and "try transcriptStore.recordOperatorReply(" in BRIDGE,
        "Operator Messages replies lost authorization, immutable routing, or encrypted history",
    )
    require(
        "[self configureMainWorkspace]" in MAIN
        and '@"Main AI"' in MAIN
        and '@"360° Live View"' in MAIN
        and '@"Settings"' in MAIN
        and "ROBMessagesWorkspaceViewController" in MAIN
        and "NSSplitView *workspace" in MAIN
        and "addArrangedSubview:aiCard" in MAIN
        and "addArrangedSubview:messagesView" in MAIN
        and "@selector(showInsta360Diagnostics:)" in MAIN
        and "@selector(showSettings:)" in MAIN,
        "The detailed communication workspace lost its visible Main AI and Messages panes",
    )
    require(
        "workspaceButtonForAction:" in MAIN
        and "self.conversationTableView.enclosingScrollView" in MAIN
        and "if (self.speechTextView == nil)" in MAIN
        and "composerScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect]"
        in MAIN
        and "self.mainAISendButton == nil || self.resetConversationButton == nil"
        not in MAIN
        and "buttonWithTitle:@\"Send\"" in MAIN
        and "buttonWithTitle:@\"Clear\"" in MAIN,
        "A missing storyboard button outlet can suppress the entire communication workspace",
    )
    require(
        'window.title = "Messages Administrator Commands"' in COMMAND_WINDOW
        and "NSTableViewDataSource" in COMMAND_WINDOW
        and 'NSTextView()' in COMMAND_WINDOW
        and '"Save Commands"' in COMMAND_WINDOW
        and "ROBMessagesAdministratorCommandStore.save" in COMMAND_WINDOW
        and "showMessagesAdministratorCommands:" in SETTINGS
        and "ROBMessagesAdministratorCommandWindowController.swift" in PROJECT,
        "Settings lost the administrator-command table, script editor, or persistence wiring",
    )
    require(
        "[ROBMessagesBridge setConfiguredEnabled:shouldEnable]" in SETTINGS
        and "[ROBMessagesBridge hasConfiguredAuthorizedSenders]" in SETTINGS
        and "[ROBMessagesBridge setConfiguredAccountIdentifier:" in SETTINGS
        and "[ROBMessagesBridge setConfiguredAllowedSendersText:" in SETTINGS,
        "Messages Settings no longer persist a fail-closed account/sender configuration",
    )
    require(
        "Full Disk Access" in SETTINGS and "Automation" in SETTINGS,
        "Settings does not explain both required macOS privacy permissions",
    )
    require(
        "messagesBridgeCard(now: now)" in STATUS
        and "ROBMessagesBridge.shared.statusSnapshot()" in STATUS
        and 'id: "messages-ai-bridge"' in STATUS
        and '.init(label: "Images", value: imageMode)' in STATUS
        and '.init(label: "Transcript archive", value: transcriptMode)' in STATUS
        and '.init(label: "Output", value: "Messages only")' in STATUS,
        "The Services grid no longer reports the cached Messages-only bridge state",
    )
    require(
        "NSAppleEventsUsageDescription" in INFO,
        "Cerebro does not explain the Automation permission used to send Messages replies",
    )
    require(
        "AEDeterminePermissionToAutomateTarget(" in BRIDGE
        and "askUserIfNeeded: false" in BRIDGE
        and "automationPermissionCheck(false)" in BRIDGE
        and "checkMessagesAutomationPermission()" in BRIDGE,
        "Bridge initialization no longer performs a non-prompting Messages Automation check",
    )
    require(
        "ENABLE_HARDENED_RUNTIME = YES" in PROJECT,
        "The Cerebro target no longer enables the hardened runtime",
    )
    required_entitlements = (
        "com.apple.security.automation.apple-events",
        "com.apple.security.device.camera",
        "com.apple.security.device.audio-input",
    )
    require(
        all(entitlement in ENTITLEMENTS for entitlement in required_entitlements),
        "Cerebro is missing Automation, camera, or audio-input entitlements",
    )
    require(
        "NSAppleMusicUsageDescription" in INFO,
        "Cerebro does not explain Music automation for playback control",
    )
    require(
        'requestMessagesAutomationPermission' in SETTINGS
        and 'requestMusicAutomationPermission' in SETTINGS
        and 'handleAutomationPermissionRequest' in SETTINGS
        and '[ROBMessagesBridge requestMessagesAutomationPermission]' in SETTINGS
        and 'QOS_CLASS_USER_INITIATED' in SETTINGS
        and 'Messages Automation permission…' in SETTINGS
        and '[[ROBMessagesBridge shared] reloadConfiguration]' in SETTINGS
        and '[ROBAppleMusicPermissions requestAutomationPermission]' in SETTINGS,
        "Settings permission-request actions no longer check asynchronously and reload the bridge",
    )
    require(
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?" in SETTINGS
        and 'openPrivacySettings:@"Privacy_Automation"' in SETTINGS,
        "Messages Automation settings no longer use the modern Privacy & Security deep link",
    )
    for filename in (
        "ROBMessagesBridge.swift",
        "ROBMessagesAIResponder.swift",
        "ROBMessagesTranscriptStore.swift",
        "ROBMessagesVisionReplyPolicy.swift",
        "ROBMessagesTranscriptWindowController.swift",
    ):
        require(
            PROJECT.count(f"/* {filename} */") >= 2
            and f"/* {filename} in Sources */" in PROJECT,
            f"{filename} is not part of the Cerebro application target",
        )

    print("ROB Messages bridge static integration passed")


if __name__ == "__main__":
    main()
