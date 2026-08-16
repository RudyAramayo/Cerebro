//
//  ROBSpeechLanguageDetector.h
//  Cerebro
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ROBSpeechDetectedLanguage) {
    ROBSpeechDetectedLanguageUnknown = 0,
    ROBSpeechDetectedLanguageEnglish,
    ROBSpeechDetectedLanguageSpanish,
    ROBSpeechDetectedLanguageJapanese,
    ROBSpeechDetectedLanguageChinese,
};

/// Side-effect-free language routing for ROB's synthesized replies. Script
/// evidence wins where possible; Natural Language handles the shared Latin
/// and Han writing systems with guards for ambiguous one-word responses.
@interface ROBSpeechLanguageDetector : NSObject

+ (ROBSpeechDetectedLanguage)detectedLanguageForText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
