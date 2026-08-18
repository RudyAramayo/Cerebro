#!/usr/bin/env python3
"""Static checks for ROB's randomly selected acknowledgement phrase list."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEECH_HEADER = (ROOT / "Cerebro" / "ROBSpeechBox.h").read_text(encoding="utf-8")
SPEECH_SOURCE = (ROOT / "Cerebro" / "ROBSpeechBox.m").read_text(encoding="utf-8")
SETTINGS_SOURCE = (
    ROOT / "Cerebro" / "ROBPythonSettingsWindowController.m"
).read_text(encoding="utf-8")
MAIN_SOURCE = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(
    encoding="utf-8"
)
SETTINGS_IMPLEMENTATION = SETTINGS_SOURCE.index(
    "@implementation ROBPythonSettingsWindowController"
)
MAIN_IMPLEMENTATION = MAIN_SOURCE.index("@implementation ROBMainViewController")


def braced_declaration(source: str, signature: str, start: int = 0) -> str:
    declaration_start = source.index(signature, start)
    body_start = source.index("{", declaration_start)
    depth = 0
    for index in range(body_start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[declaration_start : index + 1]
    raise AssertionError(f"Unterminated declaration: {signature}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    defaults_key = "ROBSpeechAcknowledgementPhraseDefaultsKey"
    list_resolver = "ROBResolvedSpeechAcknowledgementPhrases"
    random_resolver = "ROBResolvedSpeechAcknowledgementPhrase"

    require(defaults_key in SPEECH_HEADER, "Acknowledgement defaults key is not public")
    require(
        f"{list_resolver}(void)" in SPEECH_HEADER,
        "The resolved acknowledgement phrase list is not public",
    )
    require(
        f"{random_resolver}(void)" in SPEECH_HEADER,
        "The random acknowledgement resolver is not public",
    )
    require(
        f'NSString * const {defaults_key} = @"ROBSpokenAcknowledgementPhrase";'
        in SPEECH_SOURCE,
        "The existing acknowledgement defaults key must remain unchanged so saved single phrases migrate",
    )
    require(
        'NSString * const ROBDefaultSpeechAcknowledgementPhrase = @"I hear you.";'
        in SPEECH_SOURCE,
        "The default spoken acknowledgement changed",
    )

    list_resolution = braced_declaration(SPEECH_SOURCE, f"{list_resolver}(void)")
    require(
        f"ForKey:{defaults_key}" in list_resolution,
        "Acknowledgement list resolver no longer reads the saved preference",
    )
    require(
        "isKindOfClass:[NSString class]" in list_resolution,
        "A legacy single NSString acknowledgement must remain a supported stored value",
    )
    require(
        "componentsSeparatedByCharactersInSet:" in list_resolution
        and "newlineCharacterSet" in list_resolution,
        "The saved acknowledgement string must be split into one phrase per line",
    )
    require(
        "whitespaceAndNewlineCharacterSet" in list_resolution
        and "stringByTrimmingCharactersInSet:" in list_resolution
        and "length > 0" in list_resolution,
        "Each acknowledgement line must be trimmed and blank lines must be ignored",
    )
    require(
        list_resolution.count("ROBDefaultSpeechAcknowledgementPhrase") >= 2,
        "Missing, wrong-type, or all-blank acknowledgement data must fall back to 'I hear you.'",
    )

    random_resolution = braced_declaration(
        SPEECH_SOURCE, f"{random_resolver}(void)"
    )
    require(
        list_resolver in random_resolution,
        "Random acknowledgement selection must use the complete resolved phrase list",
    )
    require(
        "arc4random_uniform" in random_resolution
        and ".count" in random_resolution,
        "ROB must randomly select a valid index from the configured phrases for each acknowledgement",
    )

    build_interface = braced_declaration(
        SETTINGS_SOURCE, "- (void)buildInterface", SETTINGS_IMPLEMENTATION
    )
    require(
        "NSTextView *acknowledgementPhrasesTextView" in SETTINGS_SOURCE,
        "The Speech tab needs a multiline acknowledgement phrase-list editor",
    )
    require(
        "NSScrollView" in build_interface
        and "self.acknowledgementPhrasesTextView" in build_interface
        and "self.acknowledgementPhrasesTextView.delegate = self" in build_interface
        and "[self refreshAcknowledgementPhrasesTextView]" in build_interface,
        "The Speech tab must provide a scrollable editor that loads the complete phrase list",
    )
    require(
        "Acknowledgement" in build_interface
        and "one per line" in build_interface.lower()
        and "random" in build_interface.lower(),
        "The acknowledgement editor must explain the one-per-line random behavior",
    )

    refresh_editor = braced_declaration(
        SETTINGS_SOURCE,
        "- (void)refreshAcknowledgementPhrasesTextView",
        SETTINGS_IMPLEMENTATION,
    )
    require(
        list_resolver in refresh_editor
        and "componentsJoinedByString:" in refresh_editor,
        "Settings must display every resolved phrase as a newline-delimited list",
    )

    save_action = braced_declaration(
        SETTINGS_SOURCE, "- (void)textDidChange:", SETTINGS_IMPLEMENTATION
    )
    require(
        "self.acknowledgementPhrasesTextView.string" in save_action,
        "Settings no longer reads the multiline acknowledgement editor",
    )
    require(
        "whitespaceAndNewlineCharacterSet" in save_action
        and "stringByTrimmingCharactersInSet:" in save_action,
        "Settings no longer trim the configured acknowledgement list",
    )
    require(
        defaults_key in save_action
        and ("setObject:" in save_action or "removeObjectForKey:" in save_action),
        "Settings no longer persist the acknowledgement phrase list",
    )
    require(
        "removeObjectForKey:" in save_action,
        "An empty or all-blank acknowledgement list must clear the preference",
    )
    finish_action = braced_declaration(
        SETTINGS_SOURCE,
        "- (void)textDidEndEditing:",
        SETTINGS_IMPLEMENTATION,
    )
    require(
        "[self refreshAcknowledgementPhrasesTextView]" in finish_action,
        "Blank acknowledgement edits no longer restore the default list in Settings",
    )

    acknowledgement_helper = braced_declaration(
        MAIN_SOURCE,
        "- (void)speakConfiguredAcknowledgementIfNotQueued",
        MAIN_IMPLEMENTATION,
    )
    require(
        random_resolver in acknowledgement_helper,
        "The shared acknowledgement path no longer chooses a configured phrase",
    )
    transcription_handler = braced_declaration(
        MAIN_SOURCE, "didReceiveInputTranscription:", MAIN_IMPLEMENTATION
    )
    input_handler = braced_declaration(
        MAIN_SOURCE, "- (void) inputText:", MAIN_IMPLEMENTATION
    )
    require(
        "[self speakConfiguredAcknowledgementIfNotQueued]" in transcription_handler,
        "Gemini input transcriptions no longer use the configured acknowledgement",
    )
    require(
        input_handler.count("[self speakConfiguredAcknowledgementIfNotQueued]") >= 2,
        "Both accepted local text turns and Gemini microphone turns must use the shared acknowledgement path",
    )
    require(
        random_resolver not in input_handler,
        "Do not consume a random acknowledgement until the shared helper is actually going to enqueue it",
    )
    require(
        '@"I hear you."' not in MAIN_SOURCE,
        "ROBMainViewController still bypasses the configured acknowledgement phrase",
    )

    print("ROB random acknowledgement phrase-list Settings integration passed")


if __name__ == "__main__":
    main()
