#!/usr/bin/env python3
"""Structural checks for the news-result-to-SpeechBox narration path."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROB_AI = (ROOT / "Cerebro" / "ROBAI.swift").read_text(encoding="utf-8")
MAIN_CONTROLLER = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(
    encoding="utf-8"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


local_start = ROB_AI.index("private func handleLocalNewsToolCall")
local_end = ROB_AI.index("private func notifyConnectionState", local_start)
local_handler = ROB_AI[local_start:local_end]
require(
    "service.execute(arguments: call.arguments)" in local_handler
    and "session?.sendToolResponse(" in local_handler,
    "News results no longer return through the correlated Gemini tool response",
)
require(
    "SpeechBox" not in local_handler and "sayIt" not in local_handler,
    "The local news handler must not speak directly and double-narrate results",
)

response_start = MAIN_CONTROLLER.index(
    "didReceiveResponseText:(NSString *)text\n{"
)
response_end = MAIN_CONTROLLER.index(
    "didReceiveInputTranscription:(NSString *)text", response_start
)
response_handlers = MAIN_CONTROLLER[response_start:response_end]
require(
    "[self appendConversationText:text fromUser:NO];" in response_handlers
    and "[self didRespond:text];" in response_handlers,
    "Completed Gemini text no longer reaches the normal spoken-response path",
)

did_respond_start = MAIN_CONTROLLER.index("- (void) didRespond:")
did_respond_end = MAIN_CONTROLLER.index("#pragma mark - ROBAIDelegate", did_respond_start)
did_respond = MAIN_CONTROLLER[did_respond_start:did_respond_end]
require(
    "[self.speechBox sayIt:responseText];" in did_respond,
    "ROB responses no longer use SpeechBox narration",
)

interrupt_start = MAIN_CONTROLLER.index("- (void)robAIWasInterrupted:")
interrupt_end = MAIN_CONTROLLER.index("didReceiveToolCall:", interrupt_start)
require(
    "[self.speechBox stopIt:nil];"
    in MAIN_CONTROLLER[interrupt_start:interrupt_end],
    "A Gemini interruption no longer stops headline narration",
)

speech_start = MAIN_CONTROLLER.index("- (void) willStartProcessingSpeech")
speech_end = MAIN_CONTROLLER.index("- (void) willSpeakWord:", speech_start)
speech_lifecycle = MAIN_CONTROLLER[speech_start:speech_end]
require(
    "[self.robAI sendAudioStreamEnd];" in speech_lifecycle
    and "[self startListeningAgain];" in speech_lifecycle,
    "SpeechBox no longer brackets narration with Gemini microphone suppression",
)

print("ROB news headline narration static checks passed")
