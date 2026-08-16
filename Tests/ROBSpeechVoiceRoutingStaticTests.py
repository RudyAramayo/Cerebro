#!/usr/bin/env python3
"""Static integration checks for multilingual ROB speech voice routing."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEECH_HEADER = (ROOT / "Cerebro" / "ROBSpeechBox.h").read_text(encoding="utf-8")
SPEECH_SOURCE = (ROOT / "Cerebro" / "ROBSpeechBox.m").read_text(encoding="utf-8")
SETTINGS_SOURCE = (
    ROOT / "Cerebro" / "ROBPythonSettingsWindowController.m"
).read_text(encoding="utf-8")
PROJECT = (ROOT / "Cerebro.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")


def objective_c_method(source, signature, start=0):
    method_start = source.index(signature, start)
    body_start = source.index("{", method_start)
    depth = 0
    for index in range(body_start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[method_start : index + 1]
    raise AssertionError(f"Unterminated Objective-C method: {signature}")


def main():
    implementation_start = SPEECH_SOURCE.index("@implementation ROBSpeechBox")
    for defaults_key in (
        "ROBEnglishVoiceIdentifierDefaultsKey",
        "ROBSpanishVoiceIdentifierDefaultsKey",
        "ROBJapaneseVoiceIdentifierDefaultsKey",
        "ROBChineseVoiceIdentifierDefaultsKey",
    ):
        assert defaults_key in SPEECH_HEADER
        assert defaults_key in SPEECH_SOURCE
        assert defaults_key in SETTINGS_SOURCE

    voice_router = objective_c_method(
        SPEECH_SOURCE, "voiceForText:", implementation_start
    )
    assert "ROBSpeechLanguageDetector detectedLanguageForText:" in voice_router
    assert "ROBSpeechDetectedLanguageSpanish" in voice_router
    assert "ROBSpeechDetectedLanguageJapanese" in voice_router
    assert "ROBSpeechDetectedLanguageChinese" in voice_router

    best_voice = objective_c_method(
        SPEECH_SOURCE, "bestInstalledVoiceForLanguage:", implementation_start
    )
    assert "AVSpeechSynthesisVoice.speechVoices" in best_voice
    assert "voice.quality > bestVoice.quality" in best_voice

    # Every active utterance path—including sentence-paced stage delivery—must
    # pass through the same per-text router.
    assert SPEECH_SOURCE.count("utterance.voice = [self voiceForText:") == 3

    for popup in (
        "englishVoicePopup",
        "spanishVoicePopup",
        "japaneseVoicePopup",
        "chineseVoicePopup",
    ):
        assert popup in SETTINGS_SOURCE
    assert "AVSpeechSynthesisVoiceQualityPremium" in SETTINGS_SOURCE
    assert "AVSpeechSynthesisAvailableVoicesDidChangeNotification" in SETTINGS_SOURCE
    assert "ROBSpeechLanguageDetector.m in Sources" in PROJECT
    print("ROB multilingual speech voice routing integration passed")


if __name__ == "__main__":
    main()
