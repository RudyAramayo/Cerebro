import Foundation

struct GeminiRoboticsRuntimePolicy {
    let settings: GeminiRoboticsRuntimeSettings
    let revision: UInt64
    let connectionGeneration: UInt64
    let audioGeneration: UInt64
    let videoGeneration: UInt64
}

/// A synchronous privacy boundary shared by the UI-facing runtime and the
/// Live actor. Runtime-policy application is asynchronous; this gate ensures
/// an older queued frame cannot slip onto the socket while a source-off or
/// camera-off policy is still waiting to reach the actor.
final class GeminiVideoAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0

    func update(policy: GeminiRoboticsRuntimePolicy) {
        lock.lock()
        guard policy.revision > revision else {
            lock.unlock()
            return
        }
        revision = policy.revision
        generation = policy.videoGeneration
        enabled = policy.settings.connectionEnabled &&
            policy.settings.streamsVideo &&
            (policy.settings.streamsMainCameraVideo ||
                policy.settings.streamsInsta360Video)
        lock.unlock()
    }

    func revoke() {
        lock.lock()
        enabled = false
        lock.unlock()
    }

    func allows(generation candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && candidate == generation
    }

    /// Linearizes authorization with the actual WebSocket enqueue call. The
    /// lock is held only for the synchronous submission, never for network I/O
    /// or its completion callback.
    func performIfAllowed(
        generation candidate: UInt64,
        _ submit: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled && candidate == generation else { return false }
        submit()
        return true
    }
}

struct GeminiRoboticsAttributedToolCall {
    let call: GeminiRoboticsToolCall
    let contextID: String?
    var provider: ROBRealtimeProvider = .gemini
}

enum ROBRealtimeConnectionState: String {
    case off
    case connecting
    case ready
    case reconnecting
    case disconnected
    case failed
}

enum ROBRealtimeEvent {
    case connectionState(ROBRealtimeConnectionState, String?)
    case runtimePolicyApplied(GeminiRoboticsRuntimePolicy)
    case completedText(String, contextID: String?)
    case personalityText(String, provider: ROBRealtimeProvider, utteranceID: String)
    case inputTranscription(String)
    case requestFailed(
        String,
        contextID: String?,
        localFallbackPrompt: GeminiLocalFallbackPrompt?
    )
    case interrupted
    case toolCalls([GeminiRoboticsAttributedToolCall])
    case cancelledToolCalls([String])
}

/// Both providers use the same local input gates and action executive.
/// Audio entering an adapter is signed PCM16, mono, 16 kHz.
protocol ROBRealtimeSession: AnyObject {
    func applyRuntimePolicy(_ policy: GeminiRoboticsRuntimePolicy) async
    func stop(connectionState: ROBRealtimeConnectionState, failureDetail: String?, invalidatePendingPolicies: Bool) async
    func setMicrophoneConversationAuthorized(_ authorized: Bool, generation: UInt64) async
    func enqueueAudioPCM16(_ data: Data, generation: UInt64) async
    func enqueueAudioStreamEnd(generation: UInt64) async
    func sendVideoJPEG(_ data: Data, generation: UInt64) async -> Bool
    func sendTextTurn(_ text: String, imageJPEG: Data?, contextID: String?, localFallbackPrompt: String?,
                      fallbackSource: GeminiConversationTranscriptSource, generation: UInt64,
                      minimumPolicyRevision: UInt64) async
    func cancelTextTurn(contextID: String) async
    func noteMicrophoneTurnAwaitingResponse(transcript: String, generation: UInt64,
                                            transcriptIsCumulative: Bool, source: GeminiConversationTranscriptSource) async
    func sendToolResponse(callID: String, name: String, result: [String: Any]) async
    func confirmToolCallCancellation(callID: String) async
    func finishPersonalitySpeech(utteranceID: String, finished: Bool) async
    func cancelDialogue() async
    func startDialogue() async
}

extension ROBRealtimeSession {
    func finishPersonalitySpeech(utteranceID: String, finished: Bool) async {}
    func cancelDialogue() async {}
    func startDialogue() async {}
    func stop(connectionState: ROBRealtimeConnectionState, failureDetail: String?) async {
        await stop(connectionState: connectionState, failureDetail: failureDetail, invalidatePendingPolicies: true)
    }
    func sendTextTurn(_ text: String, contextID: String?, localFallbackPrompt: String?,
                      fallbackSource: GeminiConversationTranscriptSource, generation: UInt64,
                      minimumPolicyRevision: UInt64) async {
        await sendTextTurn(text, imageJPEG: nil, contextID: contextID, localFallbackPrompt: localFallbackPrompt,
                           fallbackSource: fallbackSource, generation: generation, minimumPolicyRevision: minimumPolicyRevision)
    }
    func noteMicrophoneTurnAwaitingResponse(transcript: String, generation: UInt64, source: GeminiConversationTranscriptSource) async {
        await noteMicrophoneTurnAwaitingResponse(transcript: transcript, generation: generation,
                                                transcriptIsCumulative: true, source: source)
    }
}
