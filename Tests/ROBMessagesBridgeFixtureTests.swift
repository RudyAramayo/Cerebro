import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// A deterministic, Messages-free contract fixture for the account-scoped
/// bridge. The production boundary may read the local chat.db after the user
/// grants Full Disk Access, but its policy and routing must preserve these
/// rules without touching a live Messages database during tests.
private struct FixtureInboundMessage: Sendable {
    let id: String
    let receivingAccount: String
    let chatID: String
    let sender: String
    let isFromMe: Bool
    let text: String?
}

private struct FixtureMessagesBridgeConfiguration: Sendable {
    let receivingAccount: String
    let allowedSenders: Set<String>
    let allowAllSenders: Bool

    init(
        receivingAccount: String,
        allowedSenders: Set<String>? = nil,
        allowAllSenders: Bool = false
    ) {
        self.receivingAccount = receivingAccount
        self.allowedSenders = Set((allowedSenders ?? []).map(Self.canonicalHandle))
        self.allowAllSenders = allowAllSenders
    }

    static func canonicalHandle(_ handle: String) -> String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private enum FixtureMessageRejection: Equatable, Sendable {
    case wrongAccount
    case outboundOrSelf
    case missingSender
    case senderNotAllowed
    case missingChat
    case nonText
    case duplicate
}

private enum FixtureMessageDisposition: Equatable, Sendable {
    case accepted(contextID: String)
    case rejected(FixtureMessageRejection)
}

private enum FixtureResponseModality: Equatable, Sendable {
    case text
}

private struct FixtureAIRequest: Equatable, Sendable {
    let contextID: String
    let conversationID: String
    let prompt: String
    let responseModality: FixtureResponseModality
    let toolsEnabled: Bool
    let physicalActionsEnabled: Bool
}

private protocol FixtureAIResponding: Sendable {
    func respond(to request: FixtureAIRequest) async -> String
}

private protocol FixtureOutputRouting: Sendable {
    func sendMessage(_ text: String, toChat chatID: String) async
    func speak(_ text: String) async
    func performPhysicalAction(named name: String) async
    func executeTool(named name: String) async
}

private actor FixtureControlledAI: FixtureAIResponding {
    private var requests: [FixtureAIRequest] = []
    private var continuations: [String: CheckedContinuation<String, Never>] = [:]

    func respond(to request: FixtureAIRequest) async -> String {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            continuations[request.contextID] = continuation
        }
    }

    func requestSnapshot() -> [FixtureAIRequest] {
        requests
    }

    func complete(contextID: String, with response: String) throws {
        guard let continuation = continuations.removeValue(forKey: contextID) else {
            throw FixtureFailure.failed("No pending AI request for \(contextID)")
        }
        continuation.resume(returning: response)
    }
}

private actor FixtureOutputRecorder: FixtureOutputRouting {
    struct Message: Equatable, Sendable {
        let text: String
        let chatID: String
    }

    private(set) var messages: [Message] = []
    private(set) var spokenText: [String] = []
    private(set) var physicalActions: [String] = []
    private(set) var toolExecutions: [String] = []

    func sendMessage(_ text: String, toChat chatID: String) {
        messages.append(Message(text: text, chatID: chatID))
    }

    func speak(_ text: String) {
        spokenText.append(text)
    }

    func performPhysicalAction(named name: String) {
        physicalActions.append(name)
    }

    func executeTool(named name: String) {
        toolExecutions.append(name)
    }

    func snapshot() -> (
        messages: [Message],
        spokenText: [String],
        physicalActions: [String],
        toolExecutions: [String]
    ) {
        (messages, spokenText, physicalActions, toolExecutions)
    }
}

private actor FixtureMessagesBridge {
    private struct Route: Sendable {
        let chatID: String
    }

    private let configuration: FixtureMessagesBridgeConfiguration
    private let ai: any FixtureAIResponding
    private let output: any FixtureOutputRouting
    private var seenMessageIDs = Set<String>()
    private var routesByContextID: [String: Route] = [:]
    private var nextContextSequence: UInt64 = 0

    init(
        configuration: FixtureMessagesBridgeConfiguration,
        ai: any FixtureAIResponding,
        output: any FixtureOutputRouting
    ) {
        self.configuration = configuration
        self.ai = ai
        self.output = output
    }

    func receive(_ message: FixtureInboundMessage) -> FixtureMessageDisposition {
        let canonicalAccount = FixtureMessagesBridgeConfiguration.canonicalHandle(
            message.receivingAccount
        )
        let configuredAccount = FixtureMessagesBridgeConfiguration.canonicalHandle(
            configuration.receivingAccount
        )
        guard canonicalAccount == configuredAccount else {
            return .rejected(.wrongAccount)
        }

        let canonicalSender = FixtureMessagesBridgeConfiguration.canonicalHandle(message.sender)
        guard !message.isFromMe, canonicalSender != configuredAccount else {
            return .rejected(.outboundOrSelf)
        }
        guard !canonicalSender.isEmpty else {
            return .rejected(.missingSender)
        }
        guard configuration.allowAllSenders
                || configuration.allowedSenders.contains(canonicalSender) else {
            return .rejected(.senderNotAllowed)
        }

        let chatID = message.chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatID.isEmpty else {
            return .rejected(.missingChat)
        }
        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return .rejected(.nonText)
        }

        let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageID.isEmpty, seenMessageIDs.insert(messageID).inserted else {
            return .rejected(.duplicate)
        }

        nextContextSequence &+= 1
        let contextID = "messages:\(nextContextSequence)"
        routesByContextID[contextID] = Route(chatID: chatID)
        let request = FixtureAIRequest(
            contextID: contextID,
            conversationID: "messages-chat:\(chatID)",
            prompt: text,
            responseModality: .text,
            toolsEnabled: false,
            physicalActionsEnabled: false
        )

        Task { [weak self, ai] in
            let response = await ai.respond(to: request)
            await self?.finish(response: response, contextID: contextID)
        }
        return .accepted(contextID: contextID)
    }

    private func finish(response: String, contextID: String) async {
        guard let route = routesByContextID.removeValue(forKey: contextID) else { return }
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await output.sendMessage(text, toChat: route.chatID)
    }
}

@main
private struct ROBMessagesBridgeFixtureTests {
    static func main() async throws {
        try await testAccountAndSenderFiltering()
        try await testDedupeAndOutboundLoopPrevention()
        try await testTextOnlyAndForbiddenSideEffects()
        try await testPerChatCorrelationWithConcurrentResponses()
        print("ROB Messages bridge policy fixtures passed")
    }

    private static func testAccountAndSenderFiltering() async throws {
        let ai = FixtureControlledAI()
        let output = FixtureOutputRecorder()
        let bridge = FixtureMessagesBridge(
            configuration: FixtureMessagesBridgeConfiguration(
                receivingAccount: "rob@orbitusrobotics.com",
                allowedSenders: ["owner@example.com"]
            ),
            ai: ai,
            output: output
        )

        try await expectRejected(
            .wrongAccount,
            by: bridge,
            message: message(id: "wrong-account", account: "other@example.com")
        )
        try await expectRejected(
            .missingSender,
            by: bridge,
            message: message(id: "missing-sender", sender: "  ")
        )
        try await expectRejected(
            .senderNotAllowed,
            by: bridge,
            message: message(id: "untrusted", sender: "stranger@example.com")
        )
        let failClosedBridge = FixtureMessagesBridge(
            configuration: FixtureMessagesBridgeConfiguration(
                receivingAccount: "rob@orbitusrobotics.com",
                allowedSenders: nil
            ),
            ai: FixtureControlledAI(),
            output: FixtureOutputRecorder()
        )
        try await expectRejected(
            .senderNotAllowed,
            by: failClosedBridge,
            message: message(id: "no-allowlist")
        )
        let publicAI = FixtureControlledAI()
        let publicBridge = FixtureMessagesBridge(
            configuration: FixtureMessagesBridgeConfiguration(
                receivingAccount: "rob@orbitusrobotics.com",
                allowedSenders: nil,
                allowAllSenders: true
            ),
            ai: publicAI,
            output: FixtureOutputRecorder()
        )
        let publicDisposition = await publicBridge.receive(
            message(id: "public-outsider", sender: "stranger@example.com")
        )
        guard case .accepted = publicDisposition else {
            throw FixtureFailure.failed("Public mode rejected a remote sender")
        }
        try await expectRejected(
            .wrongAccount,
            by: publicBridge,
            message: message(
                id: "public-wrong-account",
                account: "other@example.com",
                sender: "stranger@example.com"
            )
        )
        try await expectRejected(
            .outboundOrSelf,
            by: publicBridge,
            message: message(
                id: "public-self-handle",
                sender: " ROB@OrbitusRobotics.com "
            )
        )
        try await waitUntil("The public remote sender did not reach the AI") {
            await publicAI.requestSnapshot().count == 1
        }
        try await expectRejected(
            .missingChat,
            by: bridge,
            message: message(id: "missing-chat", chatID: "")
        )
        try await expectRejected(
            .nonText,
            by: bridge,
            message: message(id: "attachment-only", text: nil)
        )

        let accepted = await bridge.receive(message(id: "allowed", text: "Hello ROB"))
        guard case .accepted = accepted else {
            throw FixtureFailure.failed("A valid message to ROB's configured account was rejected")
        }
        try await waitUntil("The accepted sender did not reach the AI") {
            await ai.requestSnapshot().count == 1
        }
    }

    private static func testDedupeAndOutboundLoopPrevention() async throws {
        let ai = FixtureControlledAI()
        let output = FixtureOutputRecorder()
        let bridge = FixtureMessagesBridge(
            configuration: FixtureMessagesBridgeConfiguration(
                receivingAccount: "rob@orbitusrobotics.com",
                allowedSenders: ["owner@example.com"]
            ),
            ai: ai,
            output: output
        )
        let incoming = message(id: "dedupe-id", text: "Only process this once")
        let first = await bridge.receive(incoming)
        guard case .accepted = first else {
            throw FixtureFailure.failed("The first delivery was rejected")
        }
        try await expectRejected(.duplicate, by: bridge, message: incoming)
        try await expectRejected(
            .outboundOrSelf,
            by: bridge,
            message: message(id: "outbound-echo", isFromMe: true, text: "AI reply")
        )
        try await expectRejected(
            .outboundOrSelf,
            by: bridge,
            message: message(
                id: "self-handle",
                sender: " ROB@OrbitusRobotics.com ",
                text: "AI reply echoed as an incoming event"
            )
        )
        try await waitUntil("The first message was not submitted") {
            await ai.requestSnapshot().count == 1
        }
        let submittedRequestCount = await ai.requestSnapshot().count
        try expect(
            submittedRequestCount == 1,
            "A duplicate or outbound echo was submitted to the AI"
        )
    }

    private static func testTextOnlyAndForbiddenSideEffects() async throws {
        let ai = FixtureControlledAI()
        let output = FixtureOutputRecorder()
        let bridge = FixtureMessagesBridge(
            configuration: FixtureMessagesBridgeConfiguration(
                receivingAccount: "rob@orbitusrobotics.com",
                allowedSenders: ["owner@example.com"]
            ),
            ai: ai,
            output: output
        )
        let disposition = await bridge.receive(
            message(id: "safe-policy", chatID: "safe-chat", text: "Wave and answer aloud")
        )
        let contextID = try acceptedContext(from: disposition)
        try await waitUntil("The safe request did not reach the AI") {
            await ai.requestSnapshot().count == 1
        }
        let request = try require(
            await ai.requestSnapshot().first,
            "The AI request was not recorded"
        )
        try expect(request.responseModality == .text, "Messages requested a non-text AI modality")
        try expect(!request.toolsEnabled, "Messages were allowed to invoke AI tools")
        try expect(!request.physicalActionsEnabled, "Messages were allowed to invoke robot actions")

        try await ai.complete(contextID: contextID, with: "  Text reply only  ")
        try await waitUntil("The AI reply did not reach Messages") {
            await output.snapshot().messages.count == 1
        }
        let snapshot = await output.snapshot()
        try expect(
            snapshot.messages == [.init(text: "Text reply only", chatID: "safe-chat")],
            "The text response was not routed back to its Messages chat"
        )
        try expect(snapshot.spokenText.isEmpty, "A Messages response reached a speech output")
        try expect(snapshot.physicalActions.isEmpty, "A Messages request caused a physical action")
        try expect(snapshot.toolExecutions.isEmpty, "A Messages request executed a tool")
    }

    private static func testPerChatCorrelationWithConcurrentResponses() async throws {
        let ai = FixtureControlledAI()
        let output = FixtureOutputRecorder()
        let bridge = FixtureMessagesBridge(
            configuration: FixtureMessagesBridgeConfiguration(
                receivingAccount: "rob@orbitusrobotics.com",
                allowedSenders: ["owner@example.com"]
            ),
            ai: ai,
            output: output
        )

        async let firstDisposition = bridge.receive(
            message(id: "chat-a-1", chatID: "chat-A", text: "Question A")
        )
        async let secondDisposition = bridge.receive(
            message(id: "chat-b-1", chatID: "chat-B", text: "Question B")
        )
        let (first, second) = await (firstDisposition, secondDisposition)
        let firstContext = try acceptedContext(from: first)
        let secondContext = try acceptedContext(from: second)
        try expect(firstContext != secondContext, "Concurrent messages reused a response context")
        try await waitUntil("Both concurrent requests were not recorded") {
            await ai.requestSnapshot().count == 2
        }

        let requests = await ai.requestSnapshot()
        let requestByPrompt = Dictionary(uniqueKeysWithValues: requests.map { ($0.prompt, $0) })
        try expect(
            requestByPrompt["Question A"]?.conversationID == "messages-chat:chat-A",
            "Chat A lost its conversation identity"
        )
        try expect(
            requestByPrompt["Question B"]?.conversationID == "messages-chat:chat-B",
            "Chat B lost its conversation identity"
        )

        // Deliberately complete B before A. Correlation must not rely on the
        // order in which Gemini happens to finish concurrent turns.
        let contextForB = try require(requestByPrompt["Question B"]?.contextID, "Missing B context")
        let contextForA = try require(requestByPrompt["Question A"]?.contextID, "Missing A context")
        try await ai.complete(contextID: contextForB, with: "Answer B")
        try await waitUntil("The deliberately first B response was not routed") {
            await output.snapshot().messages.count == 1
        }
        try await ai.complete(contextID: contextForA, with: "Answer A")
        try await waitUntil("Both concurrent replies were not routed") {
            await output.snapshot().messages.count == 2
        }
        let messages = await output.snapshot().messages
        try expect(
            messages == [
                .init(text: "Answer B", chatID: "chat-B"),
                .init(text: "Answer A", chatID: "chat-A")
            ],
            "Out-of-order AI responses crossed Messages chats"
        )
    }

    private static func message(
        id: String,
        account: String = "rob@orbitusrobotics.com",
        chatID: String = "fixture-chat",
        sender: String = "owner@example.com",
        isFromMe: Bool = false,
        text: String? = "Fixture message"
    ) -> FixtureInboundMessage {
        FixtureInboundMessage(
            id: id,
            receivingAccount: account,
            chatID: chatID,
            sender: sender,
            isFromMe: isFromMe,
            text: text
        )
    }

    private static func expectRejected(
        _ reason: FixtureMessageRejection,
        by bridge: FixtureMessagesBridge,
        message: FixtureInboundMessage
    ) async throws {
        let disposition = await bridge.receive(message)
        try expect(
            disposition == .rejected(reason),
            "Expected \(reason), got \(disposition)"
        )
    }

    private static func acceptedContext(
        from disposition: FixtureMessageDisposition
    ) throws -> String {
        guard case .accepted(let contextID) = disposition else {
            throw FixtureFailure.failed("Expected an accepted message, got \(disposition)")
        }
        return contextID
    }

    private static func waitUntil(
        _ failure: String,
        attempts: Int = 1_000,
        predicate: () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await predicate() { return }
            await Task.yield()
        }
        throw FixtureFailure.failed(failure)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw FixtureFailure.failed(message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FixtureFailure.failed(message) }
        return value
    }
}
