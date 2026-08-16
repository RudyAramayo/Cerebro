#import <Foundation/Foundation.h>

#import "ROBSpeechLanguageDetector.h"

static void ROBExpectLanguage(NSString *text, ROBSpeechDetectedLanguage expected)
{
    ROBSpeechDetectedLanguage actual =
        [ROBSpeechLanguageDetector detectedLanguageForText:text];
    if (actual != expected) {
        NSLog(@"Unexpected language %ld for %@; expected %ld",
              (long)actual, text, (long)expected);
        abort();
    }
}

int main(void)
{
    @autoreleasepool {
        ROBExpectLanguage(@"Hola, ¿cómo estás?", ROBSpeechDetectedLanguageSpanish);
        ROBExpectLanguage(@"ROB, puedes girar noventa grados.", ROBSpeechDetectedLanguageSpanish);
        ROBExpectLanguage(@"Sí.", ROBSpeechDetectedLanguageSpanish);
        ROBExpectLanguage(@"Gracias.", ROBSpeechDetectedLanguageSpanish);
        ROBExpectLanguage(@"No.", ROBSpeechDetectedLanguageUnknown);
        ROBExpectLanguage(@"Cerebro.", ROBSpeechDetectedLanguageUnknown);

        ROBExpectLanguage(@"你好，我是机器人。", ROBSpeechDetectedLanguageChinese);
        ROBExpectLanguage(@"繁體中文也可以。", ROBSpeechDetectedLanguageChinese);
        ROBExpectLanguage(@"ROB 2.0：你好！", ROBSpeechDetectedLanguageChinese);
        ROBExpectLanguage(@"今日は ROB camera 2 です。", ROBSpeechDetectedLanguageJapanese);
        ROBExpectLanguage(@"東京", ROBSpeechDetectedLanguageJapanese);
        ROBExpectLanguage(@"日本料理", ROBSpeechDetectedLanguageUnknown);
        ROBExpectLanguage(@"寿司", ROBSpeechDetectedLanguageUnknown);

        ROBExpectLanguage(@"The robot is ready.", ROBSpeechDetectedLanguageEnglish);
        ROBExpectLanguage(@"1234 🤖", ROBSpeechDetectedLanguageUnknown);
        NSLog(@"ROB speech language detector fixtures passed");
    }
    return 0;
}
