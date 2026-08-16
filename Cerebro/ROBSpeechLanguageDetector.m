//
//  ROBSpeechLanguageDetector.m
//  Cerebro
//

#import "ROBSpeechLanguageDetector.h"

@import NaturalLanguage;

@implementation ROBSpeechLanguageDetector

+ (NSCharacterSet *)japaneseKanaCharacterSet
{
    static NSCharacterSet *characterSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *characters =
            [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x3040, 0x60)];
        [characters addCharactersInRange:NSMakeRange(0x30A0, 0x60)];
        [characters addCharactersInRange:NSMakeRange(0x31F0, 0x10)];
        [characters addCharactersInRange:NSMakeRange(0xFF66, 0x38)];
        characterSet = [characters copy];
    });
    return characterSet;
}

+ (NSCharacterSet *)hanCharacterSet
{
    static NSCharacterSet *characterSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *characters =
            [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x3400, 0x19C0)];
        [characters addCharactersInRange:NSMakeRange(0x4E00, 0x5200)];
        [characters addCharactersInRange:NSMakeRange(0xF900, 0x200)];
        characterSet = [characters copy];
    });
    return characterSet;
}

+ (NSCharacterSet *)strongSpanishCharacterSet
{
    static NSCharacterSet *characterSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        characterSet = [NSCharacterSet characterSetWithCharactersInString:
            @"¿¡áéíóúüñÁÉÍÓÚÜÑ"];
    });
    return characterSet;
}

+ (NSUInteger)wordCountInText:(NSString *)text
{
    __block NSUInteger wordCount = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *substring,
                                       NSRange substringRange,
                                       NSRange enclosingRange,
                                       BOOL *stop) {
        (void)substring;
        (void)substringRange;
        (void)enclosingRange;
        (void)stop;
        wordCount += 1;
    }];
    return wordCount;
}

+ (NSUInteger)hanCharacterCountInText:(NSString *)text
{
    __block NSUInteger characterCount = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *substring,
                                       NSRange substringRange,
                                       NSRange enclosingRange,
                                       BOOL *stop) {
        (void)substringRange;
        (void)enclosingRange;
        (void)stop;
        if ([substring rangeOfCharacterFromSet:self.hanCharacterSet].location != NSNotFound) {
            characterCount += 1;
        }
    }];
    return characterCount;
}

+ (BOOL)isCommonShortSpanishReply:(NSString *)text
{
    static NSSet<NSString *> *phrases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        phrases = [NSSet setWithArray:@[
            @"hola", @"gracias", @"adiós", @"hasta luego", @"por favor",
            @"de acuerdo", @"buenos días", @"buenas tardes", @"buenas noches"
        ]];
    });
    NSString *normalized = [[text lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
    normalized = [normalized stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [phrases containsObject:normalized];
}

+ (BOOL)containsCommonShortChineseReply:(NSString *)text
{
    static NSArray<NSString *> *phrases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        phrases = @[@"你好", @"您好", @"谢谢", @"謝謝", @"再见", @"再見",
                    @"好的", @"可以", @"是的", @"不行"];
    });
    for (NSString *phrase in phrases) {
        if ([text containsString:phrase]) { return YES; }
    }
    return NO;
}

+ (ROBSpeechDetectedLanguage)detectedLanguageForText:(NSString *)text
{
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return ROBSpeechDetectedLanguageUnknown;
    }

    // Kana is conclusive and must win before examining Han ideographs shared
    // by Japanese and Chinese.
    if ([trimmed rangeOfCharacterFromSet:self.japaneseKanaCharacterSet].location != NSNotFound) {
        return ROBSpeechDetectedLanguageJapanese;
    }

    BOOL containsHan =
        [trimmed rangeOfCharacterFromSet:self.hanCharacterSet].location != NSNotFound;
    NLLanguageRecognizer *recognizer = [[NLLanguageRecognizer alloc] init];
    recognizer.languageConstraints = @[
        NLLanguageEnglish,
        NLLanguageSpanish,
        NLLanguageJapanese,
        NLLanguageSimplifiedChinese,
        NLLanguageTraditionalChinese,
    ];
    [recognizer processString:trimmed];
    NLLanguage dominantLanguage = recognizer.dominantLanguage;
    NSDictionary<NLLanguage, NSNumber *> *hypotheses =
        [recognizer languageHypothesesWithMaximum:5];

    if (containsHan) {
        if ([dominantLanguage isEqualToString:NLLanguageJapanese]) {
            return ROBSpeechDetectedLanguageJapanese;
        }
        if ([dominantLanguage isEqualToString:NLLanguageSimplifiedChinese] ||
            [dominantLanguage isEqualToString:NLLanguageTraditionalChinese]) {
            double chineseConfidence = hypotheses[dominantLanguage].doubleValue;
            BOOL hasEnoughHanContext = [self hanCharacterCountInText:trimmed] >= 3;
            if (chineseConfidence >= 0.55 &&
                (hasEnoughHanContext || [self containsCommonShortChineseReply:trimmed])) {
                return ROBSpeechDetectedLanguageChinese;
            }
            return ROBSpeechDetectedLanguageUnknown;
        }
    }

    if ([dominantLanguage isEqualToString:NLLanguageSpanish]) {
        double spanishConfidence = hypotheses[NLLanguageSpanish].doubleValue;
        BOOL hasStrongSpanishCharacter =
            [trimmed rangeOfCharacterFromSet:self.strongSpanishCharacterSet].location != NSNotFound;
        BOOL hasEnoughWords = [self wordCountInText:trimmed] >= 2;
        if ((hasEnoughWords && spanishConfidence >= 0.70) ||
            (hasStrongSpanishCharacter && spanishConfidence >= 0.55) ||
            [self isCommonShortSpanishReply:trimmed]) {
            return ROBSpeechDetectedLanguageSpanish;
        }
        // Natural Language documents reduced accuracy for short strings. A
        // bare "No", product name, or place name must not switch accents.
        return ROBSpeechDetectedLanguageUnknown;
    }

    if ([dominantLanguage isEqualToString:NLLanguageEnglish]) {
        return ROBSpeechDetectedLanguageEnglish;
    }
    return ROBSpeechDetectedLanguageUnknown;
}

@end
