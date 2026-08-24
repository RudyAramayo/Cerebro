from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AI = (ROOT / "Cerebro" / "ROBAI.swift").read_text()
MAIN = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def braced_declaration(source: str, marker: str) -> str:
    start = source.find(marker)
    require(start >= 0, f"Missing declaration: {marker}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body for: {marker}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"Unterminated body for: {marker}")


def main() -> None:
    send_audio = braced_declaration(AI, "public func sendAudioBuffer")
    require(
        "microphoneConversationIsActive" in send_audio,
        "Raw Gemini audio no longer requires the controller-owned wake window",
    )

    actor_audio = braced_declaration(AI, "func enqueueAudioPCM16")
    require(
        "microphoneConversationAuthorized" in actor_audio,
        "The Live actor no longer independently rejects audio outside the wake window",
    )

    gate_setter = braced_declaration(AI, "public func setMicrophoneConversationActive")
    require(
        "setMicrophoneConversationAuthorized" in gate_setter
        and "endStream" in gate_setter,
        "Closing the wake window no longer reaches the Live actor and audio boundary",
    )

    actor_gate_setter = braced_declaration(
        AI, "func setMicrophoneConversationAuthorized"
    )
    require(
        "inFlightMicrophoneTurnID == nil" in actor_gate_setter
        and "completeInFlightMicrophoneTurnDeadline()" not in actor_gate_setter,
        "Closing input admission must not cancel a response already in flight",
    )

    input_handler = braced_declaration(MAIN, "- (void) inputText:")
    require(
        "Apple Speech heard:" in input_handler,
        "Apple Speech transcripts are no longer source-labelled for diagnosis",
    )
    require(
        "[self.robAI setMicrophoneConversationActive:YES]" in input_handler,
        "An explicit ROB address no longer opens the raw-audio continuation window",
    )
    require(
        "submitAddressedWakeTurnAsText" in input_handler
        and "[self.robAI sendRecognizedSpeechText:textInput speechWordiness:speechWordiness]" in input_handler,
        "The first addressed request is not submitted after pre-wake audio is withheld",
    )

    attention_timer = braced_declaration(MAIN, "- (void) resetSpeechResponseAttentionTimer")
    require(
        "kROBConversationContinuationWindowSeconds" in attention_timer
        and "setMicrophoneConversationActive:NO" in attention_timer,
        "Attention-window expiry no longer closes raw microphone admission",
    )
    require(
        "kROBConversationContinuationWindowSeconds = 15.0" in MAIN,
        "The bounded continuation window is no longer 15 seconds",
    )

    server_transcript = braced_declaration(MAIN, "didReceiveInputTranscription:")
    require(
        "isMicrophoneConversationActive" in server_transcript
        and "ignored outside ROB wake window" in server_transcript,
        "Late Gemini transcripts can once again bypass the wake window",
    )

    local_reply = braced_declaration(AI, "private func generateReply(to rawPrompt:")
    require(
        "ROBLearnObjectRequestGate.candidate" in local_reply
        and "hasFreshIndexFingerPoint" in local_reply
        and "acceptsLearnObjectIntent" in local_reply,
        "Object learning no longer requires deterministic language, pointing, and intent evidence",
    )
    require(
        local_reply.find("ROBLearnObjectRequestGate.candidate")
        < local_reply.find("ROBFoundationSceneInterpreter().interpret"),
        "The generative scene interpreter runs before deterministic object-learning admission",
    )

    fallback = braced_declaration(AI, "private func performLocalFallback")
    require(
        "fallback turn" in fallback
        and "source.rawValue" in fallback
        and "providerTurnID" in fallback,
        "Local fallback logs lost turn and transcript-source correlation",
    )
    require(
        "ROB local fallback turn" in AI
        and "ROB AI response:" in MAIN
        and "Gemini Robotics response:" not in MAIN,
        "Provider-neutral responses are still mislabeled as Gemini output",
    )

    print("ROB wake-window and local-fallback hardening checks passed")


if __name__ == "__main__":
    main()
