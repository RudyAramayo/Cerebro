//
//  SpeechBox.m
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "ROBSpeechBox.h"
#import "ROBMainViewController.h"
#import "ROBSpeechLanguageDetector.h"

//Emotions: 'anger', 'joy', 'neutral', 'sadness', 'fear'
#define anger @"anger"
#define joy @"joy"
#define neutral @"neutral"
#define sadness @"sadness"
#define fear @"fear"

@import Speech;
@import AVFoundation;

NSString * const ROBEnglishVoiceIdentifierDefaultsKey = @"ROBEnglishVoiceIdentifier";
NSString * const ROBJapaneseVoiceIdentifierDefaultsKey = @"ROBJapaneseVoiceIdentifier";
NSString * const ROBSpanishVoiceIdentifierDefaultsKey = @"ROBSpanishVoiceIdentifier";
NSString * const ROBChineseVoiceIdentifierDefaultsKey = @"ROBChineseVoiceIdentifier";
NSString * const ROBSpeechVoicePreferencesDidChangeNotification = @"ROBSpeechVoicePreferencesDidChange";
NSString * const ROBSpeechAcknowledgementPhraseDefaultsKey = @"ROBSpokenAcknowledgementPhrase";
NSString * const ROBDefaultSpeechAcknowledgementPhrase = @"I hear you.";

NSArray<NSString *> *ROBResolvedSpeechAcknowledgementPhrases(void)
{
    id storedValue = [[NSUserDefaults standardUserDefaults]
        objectForKey:ROBSpeechAcknowledgementPhraseDefaultsKey];
    if (![storedValue isKindOfClass:[NSString class]]) {
        return @[ROBDefaultSpeechAcknowledgementPhrase];
    }

    NSMutableArray<NSString *> *phrases = [NSMutableArray array];
    NSArray<NSString *> *lines = [(NSString *)storedValue
        componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *line in lines) {
        NSString *trimmed = [line
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0 && ![phrases containsObject:trimmed]) {
            [phrases addObject:trimmed];
        }
    }
    return phrases.count > 0 ? [phrases copy] : @[ROBDefaultSpeechAcknowledgementPhrase];
}

NSString *ROBResolvedSpeechAcknowledgementPhrase(void)
{
    NSArray<NSString *> *phrases = ROBResolvedSpeechAcknowledgementPhrases();
    // Randomize each acknowledgement while avoiding an immediate repeat when
    // at least two distinct configured phrases are available.
    static NSString *previousPhrase = nil;
    @synchronized ([ROBSpeechBox class]) {
        if (phrases.count == 1) {
            previousPhrase = phrases.firstObject;
            return previousPhrase;
        }
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        for (NSString *phrase in phrases) {
            if (![phrase isEqualToString:previousPhrase]) {
                [candidates addObject:phrase];
            }
        }
        if (candidates.count == 0) {
            [candidates addObjectsFromArray:phrases];
        }
        NSString *selected = candidates[arc4random_uniform((uint32_t)candidates.count)];
        previousPhrase = selected;
        return selected;
    }
}

@interface ROBSpeechBox() <AVSpeechSynthesizerDelegate, SFSpeechRecognizerDelegate, SFSpeechRecognitionTaskDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVSpeechSynthesizer *avSpeechSynthesizer;
@property (nonatomic, strong) NSMapTable<AVSpeechUtterance *, id> *utteranceCompletions;
@property (nonatomic, strong) NSMutableArray<AVSpeechUtterance *> *pendingSpeechUtterances;

//new properties
@property (nonatomic, strong) AVCaptureSession *capture;
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, strong) AVAudioEngine *audioEngine;


@property (readwrite, retain) NSMutableArray *localeArray;
@property (readwrite, assign) int selectedLocaleIndex;
@property (readwrite, retain) NSTimer *debounceSpeechInputTimer;
@property (readwrite, retain) NSString *currentTextInput;
@property (readwrite, retain) NSString *robsPersonalVoice;
@property (readwrite, retain) NSString *robsDefaultVoiceIdentifier;
@property (readwrite, retain) AVSpeechSynthesisVoice *robsDefaultVoice;
@property (readwrite, retain) AVSpeechSynthesisVoice *japaneseVoice;
@property (readwrite, retain) AVSpeechSynthesisVoice *spanishVoice;
@property (readwrite, retain) AVSpeechSynthesisVoice *chineseVoice;
// This must not be named outputLanguage: that property's generated setter
// would collide with the public -setOutputLanguage: method below.
@property (readwrite, copy) NSString *currentOutputLanguage;
@property (nonatomic, assign) BOOL microphoneTapInstalled;
@property (nonatomic, assign) BOOL recognizerStartInProgress;
@property (nonatomic, assign) BOOL recognizerRestartScheduled;
@property (nonatomic, assign) BOOL localRecognitionUnavailable;
@property (nonatomic, assign) BOOL speechQueueCancellationInProgress;
@property (nonatomic, assign) BOOL isShuttingDown;
@property (nonatomic, assign) NSUInteger recognitionGeneration;
@property (nonatomic, assign) BOOL hologramRecordingOwnsMicrophone;

- (void)beginRecognitionSession;
- (void)startAudioCapture;
- (void)scheduleRecognizerRestart;
- (void)teardownSpeechRecognition;
- (void)teardownAudioCapture;
- (void)finishSpeechEventForSynthesizer:(AVSpeechSynthesizer *)synthesizer
                              utterance:(AVSpeechUtterance *)utterance
                                finished:(BOOL)finished;
- (void)enqueueSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)finishSpeechQueueIfIdle;
- (void)cancelPendingSpeech;
- (AVSpeechSynthesisVoice *)resolveROBVoice;
- (AVSpeechSynthesisVoice *)bestInstalledVoiceForLanguage:(NSString *)language;
- (AVSpeechSynthesisVoice *)bestInstalledVoiceForLanguagePrefixes:(NSArray<NSString *> *)languagePrefixes
                                                  preferredLanguage:(NSString *)preferredLanguage;
- (AVSpeechSynthesisVoice *)voiceForText:(NSString *)text;
@end


@implementation ROBSpeechBox



- (instancetype)init
{
    self = [super init];
    if (self) {
        NSLog(@"SpeechBox Init");
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(pauseForHologramRecording:)
                                                     name:@"ROBHologramWillBeginAudioRecording"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(resumeAfterHologramRecording:)
                                                     name:@"ROBHologramDidEndAudioRecording"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(voicePreferencesDidChange:)
                                                     name:ROBSpeechVoicePreferencesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(availableSpeechVoicesDidChange:)
                                                     name:AVSpeechSynthesisAvailableVoicesDidChangeNotification
                                                   object:nil];
        self.emotion = anger;
        self.commands = [@[@"robbie", @"robot", @"hey robbie", @"hey robot", @"rob",  @"robbie one"] mutableCopy];
        self.robsDefaultVoiceIdentifier = @"com.apple.voice.enhanced.en-GB.Oliver";
        self.currentOutputLanguage = @"en-US";
        [self reloadVoicePreferences];
        self.utteranceCompletions = [NSMapTable strongToStrongObjectsMapTable];
        self.pendingSpeechUtterances = [NSMutableArray array];
        [self setupSpeechSynthesizer];
        
        self.localeArray = @[
        //English
        @{@"locale_id":@"en-US",@"locale_string":@"English (United States)"},
        @{@"locale_id":@"en-ZA",@"locale_string":@"English (SouthAfrica)"},
        @{@"locale_id":@"en-PH",@"locale_string":@"English (Republic of the Philippines)"},
        @{@"locale_id":@"en-CA",@"locale_string":@"English (Canadian)"},
        @{@"locale_id":@"en-SG",@"locale_string":@"English (Singapore)"},
        @{@"locale_id":@"en-IN",@"locale_string":@"English (India)"},
        @{@"locale_id":@"en-NZ",@"locale_string":@"English (New Zealand)"},
        @{@"locale_id":@"en-GB",@"locale_string":@"English (British)"},
        @{@"locale_id":@"en-ID",@"locale_string":@"English (Indonesia)"},
        @{@"locale_id":@"en-AE",@"locale_string":@"English (Australia)"},
        @{@"locale_id":@"en-AU",@"locale_string":@"English (Australia)"},
        @{@"locale_id":@"en-IE",@"locale_string":@"English (Ireland"},
        @{@"locale_id":@"en-SA",@"locale_string":@"English (?)"},
        //Spanish
        @{@"locale_id":@"es-MX",@"locale_string":@"Mexican Spanish"},
        @{@"locale_id":@"es-CL",@"locale_string":@"Chilean Spanish"},
        @{@"locale_id":@"ca-ES",@"locale_string":@"Catalan Spain"},
        @{@"locale_id":@"es-ES",@"locale_string":@"Castilian Spanish"},
        @{@"locale_id":@"es-CO",@"locale_string":@"Colombian Spanish"},
        @{@"locale_id":@"es-US",@"locale_string":@"United States - Spanish"},
        //French
        @{@"locale_id":@"fr-FR",@"locale_string":@"French"},
        @{@"locale_id":@"fr-CH",@"locale_string":@"French (Switzerland)"},
        @{@"locale_id":@"fr-CA",@"locale_string":@"French (Canada)"},
        @{@"locale_id":@"fr-BE",@"locale_string":@"French (Belgium)"},
        //Chinese
        @{@"locale_id":@"zh-HK",@"locale_string":@"Chinese (Hong Kong)"},
        @{@"locale_id":@"zh-CN",@"locale_string":@"Chinese (Mainland China)"},
        @{@"locale_id":@"zh-TW",@"locale_string":@"Chinese (Taiwanese Mandarin)"},
        @{@"locale_id":@"yue-CN",@"locale_string":@"Chinese (?)"},
        //Portugese
        @{@"locale_id":@"pt-BR",@"locale_string":@"Portuguese (Brazilian)"},
        @{@"locale_id":@"pt-PT",@"locale_string":@"Portuguese (European)"},
        //German
        @{@"locale_id":@"de-DE",@"locale_string":@"German"},
        @{@"locale_id":@"de-CH",@"locale_string":@"German (Switzerland)"},
        //Dutch
        @{@"locale_id":@"nl-NL",@"locale_string":@"Dutch"},
        @{@"locale_id":@"nl-BE",@"locale_string":@"Dutch (Belgium"},
        //Danish
        @{@"locale_id":@"da-DK",@"locale_string":@"Danish (Denmark)"},
        @{@"locale_id":@"de-AT",@"locale_string":@"Danish (?)"},
        //Italian
        @{@"locale_id":@"it-IT",@"locale_string":@"Italian"},
        @{@"locale_id":@"it-CH",@"locale_string":@"Italian (Switzerland)"},

        //Single Locale ID Languages:
        @{@"locale_id":@"vi-VN",@"locale_string":@"Vietnamese"},

        @{@"locale_id":@"ko-KR",@"locale_string":@"Korean"},

        @{@"locale_id":@"ro-RO",@"locale_string":@"Romanian"},

        @{@"locale_id":@"sv-SE",@"locale_string":@"Swedish (Sweden"},

        @{@"locale_id":@"ar-SA",@"locale_string":@"Arabic (Saudi Arabia)"},

        @{@"locale_id":@"hu-HU",@"locale_string":@"Hungarian"},

        @{@"locale_id":@"ja-JP",@"locale_string":@"Japanese"},

        @{@"locale_id":@"fi-FI",@"locale_string":@"Finnish (Finland)"},

        @{@"locale_id":@"tr-TR",@"locale_string":@"Turkish"},

        @{@"locale_id":@"nb-NO",@"locale_string":@"Norwegian (Bokmål) - Norway"},

        @{@"locale_id":@"pl-PL",@"locale_string":@"Polish"},

        @{@"locale_id":@"id-ID",@"locale_string":@"Indonesian"},

        @{@"locale_id":@"ms-MY",@"locale_string":@"Malaysia (Malay)"},

        @{@"locale_id":@"el-GR",@"locale_string":@"Greek"},

        @{@"locale_id":@"cs-CZ",@"locale_string":@"Czech (Czech Republic)"},

        @{@"locale_id":@"hr-HR",@"locale_string":@"Croatian"},

        @{@"locale_id":@"he-IL",@"locale_string":@"Hebrew (Israel)"},

        @{@"locale_id":@"ru-RU",@"locale_string":@"Russian"},

        @{@"locale_id":@"th-TH",@"locale_string":@"Thai"},

        @{@"locale_id":@"sk-SK",@"locale_string":@"Slovak (Slovakia"},

        @{@"locale_id":@"uk-UA",@"locale_string":@"Ukrainian (Ukraine)"}
        ].mutableCopy;
        self.selectedLocaleIndex = 0;
        
        self.previousInputText_1 = @"";
        self.previousInputAnswer_1 = @"";
        self.previousInputText_2 = @"";
        self.previousInputAnswer_2 = @"";
        self.previousInputText_3 = @"";
        self.previousInputAnswer_3 = @"";
        
        [self resume_listening]; //Disables the internal speech mechanisms cause they suck ass
        
        [self handlePersonalVoiceAccess];
        
        [self sayIt:@"Orbitus Robot Online"];
    }
    return self;
}

- (AVSpeechSynthesisVoice *)resolveROBVoice
{
    AVSpeechSynthesisVoice *oliver =
        [AVSpeechSynthesisVoice voiceWithIdentifier:self.robsDefaultVoiceIdentifier];
    if (oliver != nil) {
        NSLog(@"ROB voice: %@ (%@)", oliver.name, oliver.identifier);
        return oliver;
    }

    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        if ([voice.name caseInsensitiveCompare:@"Oliver"] == NSOrderedSame
            && voice.quality == AVSpeechSynthesisVoiceQualityEnhanced) {
            NSLog(@"ROB voice: resolved Oliver Enhanced as %@", voice.identifier);
            return voice;
        }
    }

    NSLog(@"Oliver Enhanced is not installed; using the best available en-GB voice.");
    return [AVSpeechSynthesisVoice voiceWithLanguage:@"en-GB"];
}

- (AVSpeechSynthesisVoice *)bestInstalledVoiceForLanguage:(NSString *)language
{
    AVSpeechSynthesisVoice *bestVoice = [AVSpeechSynthesisVoice voiceWithLanguage:language];
    if (![bestVoice.language isEqualToString:language]) {
        bestVoice = nil;
    }
    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        if (![voice.language isEqualToString:language]) { continue; }
        if (bestVoice == nil || voice.quality > bestVoice.quality) {
            bestVoice = voice;
        }
    }
    return bestVoice;
}

- (BOOL)voice:(AVSpeechSynthesisVoice *)voice
matchesLanguagePrefixes:(NSArray<NSString *> *)languagePrefixes
{
    for (NSString *prefix in languagePrefixes) {
        if ([voice.language hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

- (AVSpeechSynthesisVoice *)bestInstalledVoiceForLanguagePrefixes:(NSArray<NSString *> *)languagePrefixes
                                                  preferredLanguage:(NSString *)preferredLanguage
{
    // Keep the expected accent/script unless that locale is unavailable. The
    // settings UI can deliberately select any other compatible installed
    // voice, including a Premium regional voice.
    AVSpeechSynthesisVoice *bestVoice =
        [self bestInstalledVoiceForLanguage:preferredLanguage];
    if (bestVoice != nil) {
        return bestVoice;
    }
    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        if (![self voice:voice matchesLanguagePrefixes:languagePrefixes]) { continue; }
        if (bestVoice == nil || voice.quality > bestVoice.quality) {
            bestVoice = voice;
        }
    }
    return bestVoice;
}

- (AVSpeechSynthesisVoice *)preferredVoiceForDefaultsKey:(NSString *)defaultsKey
                                        languagePrefixes:(NSArray<NSString *> *)languagePrefixes
                                       preferredLanguage:(NSString *)preferredLanguage
{
    NSString *identifier = [[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey];
    AVSpeechSynthesisVoice *voice = identifier.length > 0
        ? [AVSpeechSynthesisVoice voiceWithIdentifier:identifier]
        : nil;
    if (voice != nil && [self voice:voice matchesLanguagePrefixes:languagePrefixes]) {
        return voice;
    }
    return [self bestInstalledVoiceForLanguagePrefixes:languagePrefixes
                                           preferredLanguage:preferredLanguage];
}

- (NSString *)qualityNameForVoice:(AVSpeechSynthesisVoice *)voice
{
    if (voice == nil) { return @"Unavailable"; }
    if (voice.quality == AVSpeechSynthesisVoiceQualityPremium) { return @"Premium"; }
    if (voice.quality == AVSpeechSynthesisVoiceQualityEnhanced) { return @"Enhanced"; }
    return @"Default";
}

- (void)reloadVoicePreferences
{
    NSString *savedEnglishIdentifier = [[NSUserDefaults standardUserDefaults]
        stringForKey:ROBEnglishVoiceIdentifierDefaultsKey];
    AVSpeechSynthesisVoice *englishVoice = nil;
    if (savedEnglishIdentifier.length > 0) {
        englishVoice = [self preferredVoiceForDefaultsKey:ROBEnglishVoiceIdentifierDefaultsKey
                                         languagePrefixes:@[@"en-"]
                                        preferredLanguage:@"en-GB"];
    }
    englishVoice = englishVoice ?: [self resolveROBVoice];
    self.japaneseVoice =
        [self preferredVoiceForDefaultsKey:ROBJapaneseVoiceIdentifierDefaultsKey
                          languagePrefixes:@[@"ja-"]
                         preferredLanguage:@"ja-JP"];
    self.spanishVoice =
        [self preferredVoiceForDefaultsKey:ROBSpanishVoiceIdentifierDefaultsKey
                          languagePrefixes:@[@"es-"]
                         preferredLanguage:@"es-ES"];
    self.chineseVoice =
        [self preferredVoiceForDefaultsKey:ROBChineseVoiceIdentifierDefaultsKey
                          languagePrefixes:@[@"zh-", @"yue-"]
                         preferredLanguage:@"zh-CN"];
    if (self.currentOutputLanguage.length == 0 || [self.currentOutputLanguage hasPrefix:@"en-"]) {
        self.robsDefaultVoice = englishVoice;
    } else if ([self.currentOutputLanguage hasPrefix:@"es-"]) {
        self.robsDefaultVoice = self.spanishVoice ?: englishVoice;
    } else if ([self.currentOutputLanguage hasPrefix:@"ja-"]) {
        self.robsDefaultVoice = self.japaneseVoice ?: englishVoice;
    } else if ([self.currentOutputLanguage hasPrefix:@"zh-"] ||
               [self.currentOutputLanguage hasPrefix:@"yue-"]) {
        self.robsDefaultVoice = self.chineseVoice ?: englishVoice;
    }
    NSLog(@"Speech preferences loaded: English=%@ (%@), Spanish=%@ (%@), Japanese=%@ (%@), Chinese=%@ (%@)",
          englishVoice.name ?: @"unavailable", [self qualityNameForVoice:englishVoice],
          self.spanishVoice.name ?: @"unavailable", [self qualityNameForVoice:self.spanishVoice],
          self.japaneseVoice.name ?: @"unavailable", [self qualityNameForVoice:self.japaneseVoice],
          self.chineseVoice.name ?: @"unavailable", [self qualityNameForVoice:self.chineseVoice]);
}

- (void)voicePreferencesDidChange:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadVoicePreferences];
    });
}

- (void)availableSpeechVoicesDidChange:(NSNotification *)notification
{
    // A newly downloaded Enhanced/Premium asset becomes eligible without a
    // Cerebro restart. A persisted exact choice still wins.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadVoicePreferences];
    });
}

- (AVSpeechSynthesisVoice *)voiceForText:(NSString *)text
{
    ROBSpeechDetectedLanguage detectedLanguage =
        [ROBSpeechLanguageDetector detectedLanguageForText:text];
    AVSpeechSynthesisVoice *voice = nil;
    NSString *languageName = nil;
    switch (detectedLanguage) {
        case ROBSpeechDetectedLanguageSpanish:
            voice = self.spanishVoice;
            languageName = @"Spanish";
            break;
        case ROBSpeechDetectedLanguageJapanese:
            voice = self.japaneseVoice;
            languageName = @"Japanese";
            break;
        case ROBSpeechDetectedLanguageChinese:
            voice = self.chineseVoice;
            languageName = @"Chinese";
            break;
        case ROBSpeechDetectedLanguageEnglish:
        case ROBSpeechDetectedLanguageUnknown:
            break;
    }
    if (voice != nil) {
        NSLog(@"Using %@ voice %@ (%@, %@, %@) for this utterance",
              languageName, voice.name, [self qualityNameForVoice:voice],
              voice.language, voice.identifier);
        return voice;
    }
    if (languageName != nil) {
        NSLog(@"A %@ response was detected, but no compatible voice is installed",
              languageName);
    }

    return self.robsDefaultVoice;
}

- (void) resume_listening
{
    [[NSApplication sharedApplication] becomeFirstResponder];

    // Audio capture and Apple Speech recognition have separate lifecycles. The
    // microphone can remain active for Gemini after the local recognition task
    // has ended, so always ask startRecognizer to ensure a task exists.
    [self setupSpeechRecognition];
    NSLog(@"Listening");
}


- (void) setupSpeechRecognition
{
    self.isShuttingDown = NO;
    if (!self.audioEngine) {
        self.audioEngine = [[AVAudioEngine alloc] init];
    }
    [self startAudioCapture];
    [self startRecognizer];

}

- (void) setupSpeechSynthesizer {
    self.avSpeechSynthesizer  = [[AVSpeechSynthesizer alloc] init];
    [self.avSpeechSynthesizer setDelegate:self];
}


#pragma mark - SFSpeechRecognizerDelegate


- (void) speechRecognizer:(SFSpeechRecognizer *)sf availabilityDidChange:(BOOL)available
{
    if (available)
    {
        NSLog(@"recognizer is available");
    }
    else{
        NSLog(@"recognizer is not available");
    }
}


#pragma mark - AVSpeechSynthesizer delegate


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didStartSpeechUtterance:(AVSpeechUtterance *)utterance
{
    NSLog(@"didStartSpeechUtterance");
    self.isSpeaking = true;
    [self.delegate willStartProcessingSpeech];
}


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance
{
    NSLog(@"didFinishSpeechUtterance");
    [self finishSpeechEventForSynthesizer:synthesizer utterance:utterance finished:YES];
}


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didPauseSpeechUtterance:(AVSpeechUtterance *)utterance
{
    NSLog(@"didPauseSpeechUtterance");
}


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didContinueSpeechUtterance:(AVSpeechUtterance *)utterance
{
    NSLog(@"didContinueSpeechUtterance");
}


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance
{
    NSLog(@"didCancelSpeechUtterance");
    [self finishSpeechEventForSynthesizer:synthesizer utterance:utterance finished:NO];
}

- (void)finishSpeechEventForSynthesizer:(AVSpeechSynthesizer *)synthesizer
                              utterance:(AVSpeechUtterance *)utterance
                                finished:(BOOL)finished
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishSpeechEventForSynthesizer:synthesizer utterance:utterance finished:finished];
        });
        return;
    }

    void (^completion)(BOOL) = [self.utteranceCompletions objectForKey:utterance];
    if (completion != nil) {
        [self.utteranceCompletions removeObjectForKey:utterance];
    }
    [self.pendingSpeechUtterances removeObjectIdenticalTo:utterance];
    if (completion != nil) {
        completion(finished);
    }

    if (self.speechQueueCancellationInProgress) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishSpeechQueueIfIdle];
    });
}

- (void)enqueueSpeechUtterance:(AVSpeechUtterance *)utterance
{
    NSAssert(NSThread.isMainThread, @"Speech utterances must be queued on the main thread");
    [self.pendingSpeechUtterances addObject:utterance];
    self.isSpeaking = true;
    [self.avSpeechSynthesizer speakUtterance:utterance];
}

- (void)finishSpeechQueueIfIdle
{
    // AVSpeechSynthesizer can still report isSpeaking after its final
    // didFinish callback. Waiting for that flag left isSpeaking stuck forever
    // at startup and caused the shared microphone tap to discard every buffer.
    // Our own queue is authoritative and also accounts for paced stage speech.
    if (self.isShuttingDown) {
        self.isSpeaking = false;
        return;
    }
    if (self.pendingSpeechUtterances.count == 0 && self.isSpeaking) {
        self.isSpeaking = false;
        NSLog(@"Speech queue drained; microphone input resumed");
        [self.delegate didFinishProcessingSpeech];
    }
}

- (void)cancelPendingSpeech
{
    NSArray<AVSpeechUtterance *> *utterances = [self.pendingSpeechUtterances copy];
    BOOL hadPendingSpeech = self.isSpeaking || utterances.count > 0;
    NSMutableArray *cancelledCompletions = [NSMutableArray array];
    [self.pendingSpeechUtterances removeAllObjects];
    for (AVSpeechUtterance *utterance in utterances) {
        void (^completion)(BOOL) = [self.utteranceCompletions objectForKey:utterance];
        if (completion != nil) {
            [self.utteranceCompletions removeObjectForKey:utterance];
            [cancelledCompletions addObject:[completion copy]];
        }
    }
    self.speechQueueCancellationInProgress = YES;
    [self.avSpeechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    self.speechQueueCancellationInProgress = NO;

    for (id completionObject in cancelledCompletions) {
        void (^completion)(BOOL) = completionObject;
        completion(NO);
    }
    if (hadPendingSpeech) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishSpeechQueueIfIdle];
        });
    }
}


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)characterRange utterance:(AVSpeechUtterance *)utterance
{
    self.isSpeaking = true;
    NSString *word = [utterance.speechString substringWithRange:characterRange];
    NSLog(@"willSpeakWord = %@", word);

    [self.delegate willSpeakWord:characterRange ofString:utterance.speechString];
}

#pragma mark -

- (void)startRecognizer
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startRecognizer];
        });
        return;
    }
    if (self.isShuttingDown || self.hologramRecordingOwnsMicrophone) {
        return;
    }

    // This method is also Cerebro's public "listen again" entry point. Restore
    // the shared microphone engine first even when Apple Dictation is disabled;
    // Gemini Live consumes the raw buffers from this same tap.
    [self startAudioCapture];

    if (self.localRecognitionUnavailable || self.recognizerStartInProgress || self.task != nil) {
        return;
    }

    NSLog(@"Attempting to start Apple Speech recognizer");
    self.recognizerStartInProgress = YES;
    SFSpeechRecognizerAuthorizationStatus status = [SFSpeechRecognizer authorizationStatus];
    if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
        [self beginRecognitionSession];
        return;
    }
    if (status != SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        self.recognizerStartInProgress = NO;
        NSLog(@"Speech recognition is not authorized");
        return;
    }

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus authorizationStatus) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (authorizationStatus == SFSpeechRecognizerAuthorizationStatusAuthorized && !self.isShuttingDown) {
                [self beginRecognitionSession];
            } else {
                self.recognizerStartInProgress = NO;
                NSLog(@"Speech recognition authorization was not granted");
            }
        });
    }];
}

- (void)beginRecognitionSession
{
    self.recognizerStartInProgress = NO;
    self.recognizerRestartScheduled = NO;
    if (self.isShuttingDown) {
        return;
    }

    [self teardownSpeechRecognition];
    NSUInteger generation = self.recognitionGeneration;

    NSString *locale = [self.localeArray[self.selectedLocaleIndex] valueForKey:@"locale_id"];
    self.currentTextInput = @"";
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:locale]];
    self.speechRecognizer.delegate = self;
    if (!self.speechRecognizer.supportsOnDeviceRecognition) {
        NSLog(@"On-device speech recognition is unavailable for locale %@; Gemini microphone capture remains active", locale);
        self.speechRecognizer = nil;
        return;
    }
    self.speechRequest = [SFSpeechAudioBufferRecognitionRequest new];
    self.speechRequest.shouldReportPartialResults = YES;
    self.speechRequest.requiresOnDeviceRecognition = YES;

    __weak typeof(self) weakSelf = self;
    self.task = [self.speechRecognizer recognitionTaskWithRequest:self.speechRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.isShuttingDown || generation != self.recognitionGeneration) {
                return;
            }

            BOOL isFinal = result.isFinal;
            NSString *transcription = result.bestTranscription.formattedString;
            if (transcription.length > 0 && ![transcription isEqualToString:self.currentTextInput]) {
                self.currentTextInput = transcription;
                if (!self.isSpeaking) {
                    [self.debounceSpeechInputTimer invalidate];
                    self.debounceSpeechInputTimer = [NSTimer scheduledTimerWithTimeInterval:0.75 repeats:NO block:^(NSTimer *timer) {
                        [self.delegate inputText:transcription];
                    }];
                }
            }

            if (error || isFinal) {
                if (error) {
                    NSLog(@"Speech recognition error: %@", error.localizedDescription);
                    BOOL dictationIsDisabled =
                        ([error.domain isEqualToString:@"kLSRErrorDomain"] && error.code == 201) ||
                        [error.localizedDescription localizedCaseInsensitiveContainsString:@"Dictation are disabled"] ||
                        [error.localizedDescription localizedCaseInsensitiveContainsString:@"Dictation is disabled"] ||
                        [error.localizedDescription localizedCaseInsensitiveContainsString:@"Siri and Dictation are disabled"];
                    if (dictationIsDisabled) {
                        // This is a persistent system preference, not a
                        // transient recognition failure. Keep the shared audio
                        // tap alive for Gemini, but stop hammering Apple Speech
                        // until Cerebro is relaunched after Dictation is enabled.
                        self.localRecognitionUnavailable = YES;
                        [self teardownSpeechRecognition];
                        NSLog(@"Local Apple speech recognition disabled; Gemini raw microphone capture remains active");
                        return;
                    }
                }
                [self scheduleRecognizerRestart];
            }
        });
    }];

    NSLog(@"Starting speech recognizer with locale %@", locale);
}

- (void)startAudioCapture
{
    if (self.isShuttingDown || self.hologramRecordingOwnsMicrophone) {
        return;
    }
    if (!self.audioEngine) {
        self.audioEngine = [[AVAudioEngine alloc] init];
    }

    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    if (!self.microphoneTapInstalled) {
        __weak typeof(self) weakSelf = self;
        [inputNode installTapOnBus:0 bufferSize:1024 format:[inputNode outputFormatForBus:0] block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.isShuttingDown || self.isSpeaking) {
                return;
            }
            [self.speechRequest appendAudioPCMBuffer:buffer];
            if ([self.delegate respondsToSelector:@selector(didCaptureAudioBuffer:)]) {
                [self.delegate didCaptureAudioBuffer:buffer];
            }
        }];
        self.microphoneTapInstalled = YES;
    }

    if (!self.audioEngine.isRunning) {
        NSError *audioError = nil;
        [self.audioEngine prepare];
        BOOL started = [self.audioEngine startAndReturnError:&audioError];
        if (!started || audioError) {
            NSLog(@"Unable to start microphone capture: %@", audioError.localizedDescription);
        } else {
            NSLog(@"Microphone capture started; Gemini and Apple Speech audio tap is active");
        }
    } else {
        NSLog(@"Microphone capture already running; shared audio tap is active");
    }
}

- (void)pauseForHologramRecording:(NSNotification *)notification
{
    self.hologramRecordingOwnsMicrophone = YES;
    self.recognizerRestartScheduled = NO;
    [self teardownSpeechRecognition];
    [self teardownAudioCapture];
}

- (void)resumeAfterHologramRecording:(NSNotification *)notification
{
    if (!self.hologramRecordingOwnsMicrophone) {
        return;
    }
    self.hologramRecordingOwnsMicrophone = NO;
    if (!self.isShuttingDown) {
        [self setupSpeechRecognition];
    }
}

- (void)scheduleRecognizerRestart
{
    if (self.isShuttingDown || self.recognizerRestartScheduled) {
        return;
    }
    self.recognizerRestartScheduled = YES;
    [self teardownSpeechRecognition];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.recognizerRestartScheduled = NO;
        [self startRecognizer];
    });
}

- (void)teardownSpeechRecognition
{
    self.recognitionGeneration += 1;
    [self.speechRequest endAudio];
    [self.task cancel];
    self.task = nil;
    self.speechRequest = nil;
}

- (void)teardownAudioCapture
{
    if (self.audioEngine) {
        [self.audioEngine stop];
        if (self.microphoneTapInstalled) {
            [self.audioEngine.inputNode removeTapOnBus:0];
            self.microphoneTapInstalled = NO;
        }
    }
}

- (void)endRecognizer
{
    // END capture and END voice Reco
    // or Apple will terminate this task after 30000ms.
    [self endCapture];
    [self teardownSpeechRecognition];
    [self teardownAudioCapture];
}

- (void)startCapture
{
    NSError *error;
    self.capture = [[AVCaptureSession alloc] init];
    AVCaptureDevice *audioDev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (audioDev == nil){
        NSLog(@"Couldn't create audio capture device");
        return ;
    }
    
    // create mic device
    AVCaptureDeviceInput *audioIn = [AVCaptureDeviceInput deviceInputWithDevice:audioDev error:&error];
    if (error != nil){
        NSLog(@"Couldn't create audio input");
        return ;
    }
    
    // add mic device in capture object
    if ([self.capture canAddInput:audioIn] == NO){
        NSLog(@"Couldn't add audio input");
        return ;
    }
    [self.capture addInput:audioIn];
    // export audio data
    AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [audioOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    if ([self.capture canAddOutput:audioOutput] == NO){
        NSLog(@"Couldn't add audio output");
        return ;
    }
    [self.capture addOutput:audioOutput];
    [audioOutput connectionWithMediaType:AVMediaTypeAudio];
    [self.capture startRunning];
}

- (void)endCapture
{
    if (self.capture != nil && [self.capture isRunning]){
        [self.capture stopRunning];
    }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (!self.isSpeaking)
        [self.speechRequest appendAudioSampleBuffer:sampleBuffer];
}



// Called when the task first detects speech in the source audio
- (void)speechRecognitionDidDetectSpeech:(SFSpeechRecognitionTask *)task
{
    NSLog(@"didDetectSpeech - %@", task);
}



- (void)speechRecognitionTask:(SFSpeechRecognitionTask *)task didFinishRecognition:(SFSpeechRecognitionResult *)result {
    
    NSLog(@"speechRecognitionTask:(SFSpeechRecognitionTask *)task didFinishRecognition");
    NSString * translatedString = [[[result bestTranscription] formattedString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    NSLog(@"%@",translatedString);
    
    if ([result isFinal]) {
        // The microphone tap is shared with Gemini and must remain installed
        // while the local recognizer rolls over to a fresh request.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scheduleRecognizerRestart];
        });
    }
}



// Called for all recognitions, including non-final hypothesis
- (void)speechRecognitionTask:(SFSpeechRecognitionTask *)task didHypothesizeTranscription:(SFTranscription *)transcription
{
    NSString * translatedString = [transcription formattedString];
    NSLog(@"didHypothesizeTranscription - %@", translatedString);
}

#pragma mark - NSSpeechRecognizerDelegate


- (void)speechRecognizer:(NSSpeechRecognizer *)sender didRecognizeCommand:(NSString *)command
{
    if ([self.commands containsObject:command])
    {
        [[NSWorkspace sharedWorkspace] launchApplication:@"/Applications/Siri.app"];
    }
}


- (void) didSeeNewPerson:(NSString *)userID
{
    [self sayIt:[NSString stringWithFormat:@"Hello there person %@, I see you", userID]];
}


- (void) lostSightOfPerson:(NSString*)userID
{
    [self sayIt:[NSString stringWithFormat:@"Goodbye person %@", userID]];
}


- (void)sayIt:(NSString *)stringToSpeak
{
    [self sayIt:stringToSpeak completion:nil];
}

- (void)sayItIfNotQueued:(NSString *)stringToSpeak
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([stringToSpeak length] == 0) {
            NSLog(@"string is of zero-length");
            return;
        }

        for (AVSpeechUtterance *pendingUtterance in self.pendingSpeechUtterances) {
            if ([pendingUtterance.speechString isEqualToString:stringToSpeak]) {
                NSLog(@"Speech is already queued; suppressing duplicate: %@", stringToSpeak);
                return;
            }
        }

        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:stringToSpeak];
        utterance.voice = [self voiceForText:stringToSpeak];
        if (![self.robsPersonalVoice isEqualToString:@""]) {
            NSLog(@"language = %@", utterance.voice.language);
        }
        [self enqueueSpeechUtterance:utterance];
        NSLog(@"Have started to say: %@", stringToSpeak);
    });
}

- (void)sayIt:(NSString *)stringToSpeak completion:(void (^)(BOOL finished))completion
{
    dispatch_async(dispatch_get_main_queue(), ^(){
        // Is the string zero-length?
        if ([stringToSpeak length] == 0) {
            NSLog(@"string is of zero-length");
            if (completion != nil) {
                completion(NO);
            }
            return;
        }
        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:stringToSpeak];
        if (completion != nil) {
            [self.utteranceCompletions setObject:[completion copy] forKey:utterance];
        }
        utterance.voice = [self voiceForText:stringToSpeak];
        if (![self.robsPersonalVoice isEqualToString:@""]) {
            NSLog(@"language = %@", utterance.voice.language);
        }

        [self enqueueSpeechUtterance:utterance];
        NSLog(@"Have started to say: %@", stringToSpeak);
    });
}

- (void)sayStageShowText:(NSString *)stringToSpeak completion:(void (^)(BOOL finished))completion
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *trimmed = [stringToSpeak stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) {
            if (completion != nil) {
                completion(NO);
            }
            return;
        }

        NSMutableArray<NSString *> *sentences = [NSMutableArray array];
        [trimmed enumerateSubstringsInRange:NSMakeRange(0, trimmed.length)
                                   options:NSStringEnumerationBySentences
                                usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            NSString *sentence = [substring stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (sentence.length > 0) {
                [sentences addObject:sentence];
            }
        }];
        if (sentences.count == 0) {
            [sentences addObject:trimmed];
        }

        [sentences enumerateObjectsUsingBlock:^(NSString *sentence, NSUInteger index, BOOL *stop) {
            AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:sentence];
            utterance.voice = [self voiceForText:sentence];
            // A third of a second is perceptible enough for a punchline or
            // explanation to land without making a live show feel sluggish.
            utterance.postUtteranceDelay = index + 1 == sentences.count ? 0.18 : 0.34;
            if (index + 1 == sentences.count && completion != nil) {
                [self.utteranceCompletions setObject:[completion copy] forKey:utterance];
            }
            [self enqueueSpeechUtterance:utterance];
        }];
        NSLog(@"Queued %lu paced stage-show sentence(s)", (unsigned long)sentences.count);
    });
}
- (void)handlePersonalVoiceAccess {
    AVSpeechSynthesisPersonalVoiceAuthorizationStatus status = [AVSpeechSynthesizer personalVoiceAuthorizationStatus];

    if (status == AVSpeechSynthesisPersonalVoiceAuthorizationStatusAuthorized) {
        NSLog(@"Personal Voice access is already authorized.");
        [self retrieveAndUsePersonalVoices];
    } else if (status == AVSpeechSynthesisPersonalVoiceAuthorizationStatusNotDetermined) {
        NSLog(@"Requesting Personal Voice authorization...");
        [AVSpeechSynthesizer requestPersonalVoiceAuthorizationWithCompletionHandler:^(AVSpeechSynthesisPersonalVoiceAuthorizationStatus newStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (newStatus == AVSpeechSynthesisPersonalVoiceAuthorizationStatusAuthorized) {
                    NSLog(@"Authorization granted. Retrieving voices.");
                    [self retrieveAndUsePersonalVoices];
                } else {
                    NSLog(@"Authorization denied or unsupported.");
                }
            });
        }];
    } else {
        NSLog(@"Personal Voice access is denied or unsupported. Status: %ld", (long)status);
    }
}

- (void)retrieveAndUsePersonalVoices {
    NSArray<AVSpeechSynthesisVoice *> *availableVoices = [AVSpeechSynthesisVoice speechVoices];
    
    for (AVSpeechSynthesisVoice *voice in availableVoices) {
        if (voice.voiceTraits & AVSpeechSynthesisVoiceTraitIsPersonalVoice) {
            NSLog(@"Found personal voice: %@ - %@", voice.name, voice.identifier);
            self.robsPersonalVoice = voice.identifier;
            return;
        }
    }
    
    NSLog(@"No personal voices found.");
}
- (void) setOutputLanguage:(NSString *)language
{
    NSLog(@"language = %@", language);
    self.currentOutputLanguage = [language copy];
    [self reloadVoicePreferences];
    AVSpeechSynthesisVoice *newVoice = nil;
    if ([language hasPrefix:@"en-"]) {
        newVoice = [self preferredVoiceForDefaultsKey:ROBEnglishVoiceIdentifierDefaultsKey
                                     languagePrefixes:@[@"en-"]
                                    preferredLanguage:language];
    } else if ([language hasPrefix:@"es-"]) {
        newVoice = [self preferredVoiceForDefaultsKey:ROBSpanishVoiceIdentifierDefaultsKey
                                     languagePrefixes:@[@"es-"]
                                    preferredLanguage:language];
    } else if ([language hasPrefix:@"ja-"]) {
        newVoice = [self preferredVoiceForDefaultsKey:ROBJapaneseVoiceIdentifierDefaultsKey
                                     languagePrefixes:@[@"ja-"]
                                    preferredLanguage:@"ja-JP"];
    } else if ([language hasPrefix:@"zh-"] || [language hasPrefix:@"yue-"]) {
        NSString *preferredChineseLanguage = @"zh-CN";
        if ([language hasPrefix:@"zh-TW"] || [language hasPrefix:@"zh-Hant"]) {
            preferredChineseLanguage = @"zh-TW";
        } else if ([language hasPrefix:@"zh-HK"] || [language hasPrefix:@"yue-"]) {
            preferredChineseLanguage = @"yue-HK";
        }
        newVoice = [self preferredVoiceForDefaultsKey:ROBChineseVoiceIdentifierDefaultsKey
                                     languagePrefixes:@[@"zh-", @"yue-"]
                                    preferredLanguage:preferredChineseLanguage];
    } else {
        newVoice = [self bestInstalledVoiceForLanguage:language];
    }
    if (newVoice != nil) {
        self.robsDefaultVoice = newVoice;
    }
    [self sayIt:[NSString stringWithFormat:@"Language set to %@", language]];
}


- (void)stopIt:(id)sender {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopIt:sender];
        });
        return;
    }
    NSLog(@"stopping");
    // stopSpeaking clears AVSpeechSynthesizer's whole queue, but queued
    // utterances are not guaranteed to each produce a delegate callback.
    [self cancelPendingSpeech];
}

- (void)shutdown {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self shutdown];
        });
        return;
    }
    if (self.isShuttingDown) {
        return;
    }
    self.isShuttingDown = YES;
    self.recognizerRestartScheduled = NO;
    [self.debounceSpeechInputTimer invalidate];
    self.debounceSpeechInputTimer = nil;
    [self teardownSpeechRecognition];
    [self teardownAudioCapture];
    [self.pendingSpeechUtterances removeAllObjects];
    [self.utteranceCompletions removeAllObjects];
    self.isSpeaking = false;
    self.speechQueueCancellationInProgress = YES;
    [self.avSpeechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    self.speechQueueCancellationInProgress = NO;
}


#pragma mark - Switch Emotions


- (void) switchMood_anger
{
    self.emotion = anger;
}


- (void) switchMood_joy
{
    self.emotion = joy;
}


- (void) switchMood_neutral
{
    self.emotion = neutral;
}


- (void) switchMood_sadness
{
    self.emotion = sadness;
}


- (void) switchMood_fear
{
    self.emotion = fear;
}

@end
