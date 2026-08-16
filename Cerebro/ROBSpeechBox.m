//
//  SpeechBox.m
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "ROBSpeechBox.h"
#import "ROBMainViewController.h"

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
NSString * const ROBSpeechVoicePreferencesDidChangeNotification = @"ROBSpeechVoicePreferencesDidChange";

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
    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        if (![voice.language isEqualToString:language]) { continue; }
        if (bestVoice == nil || voice.quality > bestVoice.quality) {
            bestVoice = voice;
        }
    }
    return bestVoice;
}

- (AVSpeechSynthesisVoice *)preferredVoiceForDefaultsKey:(NSString *)defaultsKey
                                                language:(NSString *)language
{
    NSString *identifier = [[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey];
    AVSpeechSynthesisVoice *voice = identifier.length > 0
        ? [AVSpeechSynthesisVoice voiceWithIdentifier:identifier]
        : nil;
    if (voice != nil && [voice.language hasPrefix:language]) {
        return voice;
    }
    return [self bestInstalledVoiceForLanguage:language];
}

- (void)reloadVoicePreferences
{
    AVSpeechSynthesisVoice *englishVoice = [self preferredVoiceForDefaultsKey:ROBEnglishVoiceIdentifierDefaultsKey
                                                                     language:@"en-"];
    if (englishVoice == nil) {
        englishVoice = [self resolveROBVoice];
    }
    self.japaneseVoice = [self preferredVoiceForDefaultsKey:ROBJapaneseVoiceIdentifierDefaultsKey
                                                    language:@"ja-JP"];
    if (self.currentOutputLanguage.length == 0 || [self.currentOutputLanguage hasPrefix:@"en-"]) {
        self.robsDefaultVoice = englishVoice;
    }
    NSLog(@"Speech preferences loaded: English=%@, Japanese=%@",
          englishVoice.name ?: @"unavailable", self.japaneseVoice.name ?: @"unavailable");
}

- (void)voicePreferencesDidChange:(NSNotification *)notification
{
    [self reloadVoicePreferences];
}

- (AVSpeechSynthesisVoice *)voiceForText:(NSString *)text
{
    // Japanese kana are unambiguous even when the response also contains
    // Latin names, numbers, or punctuation. CJK ideographs alone cannot be
    // reliably distinguished from Chinese without additional context.
    static NSCharacterSet *japaneseKanaCharacterSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *characterSet = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x3040, 0x60)];
        [characterSet addCharactersInRange:NSMakeRange(0x30A0, 0x60)];
        [characterSet addCharactersInRange:NSMakeRange(0x31F0, 0x10)];
        [characterSet addCharactersInRange:NSMakeRange(0xFF66, 0x38)];
        japaneseKanaCharacterSet = [characterSet copy];
    });

    if ([text rangeOfCharacterFromSet:japaneseKanaCharacterSet].location != NSNotFound) {
        AVSpeechSynthesisVoice *japaneseVoice = self.japaneseVoice ?: [self bestInstalledVoiceForLanguage:@"ja-JP"];
        if (japaneseVoice != nil) {
            NSString *quality = japaneseVoice.quality == AVSpeechSynthesisVoiceQualityPremium
                ? @"Premium"
                : (japaneseVoice.quality == AVSpeechSynthesisVoiceQualityEnhanced ? @"Enhanced" : @"Default");
            NSLog(@"Using Japanese voice %@ (%@, %@) for this utterance",
                  japaneseVoice.name, quality, japaneseVoice.identifier);
            return japaneseVoice;
        }
        NSLog(@"A Japanese response was received, but no ja-JP voice is installed");
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
    
    dispatch_async(dispatch_get_main_queue(), ^{
        //self.textView.text = translatedString;
    });
    
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
    dispatch_async(dispatch_get_main_queue(), ^{
        //self.textView.text = translatedString;
    });
    
    //[self.speechSynthesizer speakUtterance:[AVSpeechUtterance speechUtteranceWithString:translatedString]];
    
}

#pragma mark - NSSpeechRecognizerDelegate


- (void)speechRecognizer:(NSSpeechRecognizer *)sender didRecognizeCommand:(NSString *)command
{
    if ([self.commands containsObject:command])
    {
        //NSTask *task = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/osascript" arguments:@[ [[NSBundle mainBundle] pathForResource:@"dictation_start" ofType:@"scpt"] ]];
        
        [[NSWorkspace sharedWorkspace] launchApplication:@"/Applications/Siri.app"];
        
    }
}


//- (void) inputText:(NSString *)inputText
//{
//    NSLog(@"Did hear some spoken text - %@", inputText);
//    
//    /* Lets hold off on this for now
//    //printf(".");
//    if (!self.isProcessingSpeech)
//    {
//        //NSLog(@"Did hear some spoken text - %@", inputText);
//
//        self.isProcessingSpeech = true;
//        
//        //int pid = [[NSProcessInfo processInfo] processIdentifier];
//        NSPipe *pipe = [NSPipe pipe];
//        NSFileHandle *file = pipe.fileHandleForReading;
//        
//        NSTask *task = [[NSTask alloc] init];
//        task.launchPath = @"/usr/local/bin/python3";
//        //task.launchPath = @"/usr/local/bin/python";
//        //task.launchPath = @"/Users/rob/anaconda3/bin/python";
//        
//        
//        //Emotions: 'anger', 'joy', 'neutral', 'sadness', 'fear'
//        // anger - really fun
//        // joy - i love you's
//        // neutral - boring
//        // sadness - im bored
//        // fear - im scared
//        if (![self.previousInputText_1 isEqualToString:@""] && ![self.previousInputText_2 isEqualToString:@""] && ![self.previousInputText_3 isEqualToString:@""] )
//        {
//            //Level 3 conversation
//            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-e", self.emotion, @"-f", @"localhost", @"-p", @"8080",
//                               @"-c", self.previousInputText_3, @"-c", self.previousInputAnswer_3,
//                               @"-c", self.previousInputText_2, @"-c", self.previousInputAnswer_2,
//                               @"-c", self.previousInputText_1, @"-c", self.previousInputAnswer_1,
//                               @"-c", inputText];
//        }
//        else if (![self.previousInputText_1 isEqualToString:@""] && ![self.previousInputText_2 isEqualToString:@""] && [self.previousInputText_3 isEqualToString:@""])
//        {
//            //Level 2 conversation
//            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-e", self.emotion, @"-f", @"localhost", @"-p", @"8080",
//                               @"-c", self.previousInputText_2, @"-c", self.previousInputAnswer_2,
//                               @"-c", self.previousInputText_1, @"-c", self.previousInputAnswer_1,
//                               @"-c", inputText];
//        }
//        else if (![self.previousInputText_1 isEqualToString:@""] && [self.previousInputText_2 isEqualToString:@""] && [self.previousInputText_3 isEqualToString:@""])
//        {
//            //Level 1 conversation
//            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-e", self.emotion, @"-f", @"localhost", @"-p", @"8080", @"-c", self.previousInputText_1, @"-c", self.previousInputAnswer_1, @"-c", inputText];
//        }
//        else
//        {
//            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-f", @"localhost", @"-p", @"8080", @"-c", inputText];
//        }
//        
//        task.standardOutput = pipe;
//        
//        [task launch];
//        
//        NSData *data = [file readDataToEndOfFile];
//        [file closeFile];
//        
//        NSString *chatbot_response = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
//        
//        NSLog (@"chatbot:%@", chatbot_response);
//        //chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"{u'response': u'" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"{'response': '" withString:@""];
//        //chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"u'response': u\"" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"'response': \"" withString:@""];
//        
//        chatbot_response = [chatbot_response substringToIndex:chatbot_response.length-3];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"\"" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"[" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"]" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"(" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@")" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"{" withString:@""];
//        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"}" withString:@""];
//        //NSLog (@"chatbot:%@", chatbot_response);
//        
//        //--
//        [self sayIt:chatbot_response];
//        
//        //3<-2
//        self.previousInputAnswer_3 = self.previousInputAnswer_2;
//        self.previousInputText_3 = self.previousInputText_2;
//        //2<-1
//        self.previousInputAnswer_2 = self.previousInputAnswer_1;
//        self.previousInputText_2 = self.previousInputText_1;
//        //1<-0
//        self.previousInputAnswer_1 = chatbot_response;
//        self.previousInputText_1 = inputText;
//    }
//    */
//}
//

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
        //To Allow for pauses in the google gemini responses
        // Use the below algorithm and try to break up the speech and queue up each element instead, once didFinishSpeaking is reached try to continue with the next element
//        NSArray *speechComponentCategories = [stringToSpeak componentsSeparatedByString:@"\n**"];
//        for (NSString *speechComponentCategory in speechComponentCategories) {
//            NSArray *speechComponentSubCategories = [speechComponentCategory componentsSeparatedByString:@"*   **"];
//            for (NSString *speechComponentSubCategory in speechComponentSubCategories) {
//                [NSThread sleepForTimeInterval:0.5];
//                [self.speechSynth startSpeakingString:speechComponentSubCategory];
//                [NSThread sleepForTimeInterval:0.5];
//            }
//        }
        //AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"ru_RU"];
        
        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:stringToSpeak];
        if (completion != nil) {
            [self.utteranceCompletions setObject:[completion copy] forKey:utterance];
        }
        utterance.voice = [self voiceForText:stringToSpeak];
        //possible parameters to specify in the future
        //utterance.volume
        //utterance.rate
        //utterance.pitchMultiplier
        
        // This voice is using a mexican accent which is wrong
        if (![self.robsPersonalVoice isEqualToString:@""]) {
            //utterance.voice = [AVSpeechSynthesisVoice voiceWithIdentifier:self.robsPersonalVoice];
            NSLog(@"language = %@", utterance.voice.language);
        }
        //NSLog(@"voice = %@", voice.identifier);w
        
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
        //if ([voice.voiceTraits containsObject:AVSpeechSynthesisVoiceTraitIsPersonalVoice]) {
        if (voice.voiceTraits & AVSpeechSynthesisVoiceTraitIsPersonalVoice) {
            NSLog(@"Found personal voice: %@ - %@", voice.name, voice.identifier);
            //com.apple.speech.personalvoice.2EC375A4-5645-4D92-BE9E-3027ED5936BC
            self.robsPersonalVoice = voice.identifier;
            return;
        }
    }
    
    NSLog(@"No personal voices found.");
}
//
//- (void)speakWithVoiceIdentifier:(NSString *)identifier {
//    AVSpeechSynthesizer *synthesizer = [[AVSpeechSynthesizer alloc] init];
//    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithIdentifier:identifier];
//    
//    if (voice) {
//        AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:@"Hello, this is a test using my personal voice."];
//        utterance.voice = voice;
//        [synthesizer speakUtterance:utterance];
//    } else {
//        NSLog(@"Failed to create voice with identifier: %@", identifier);
//    }
//}

- (void) setOutputLanguage:(NSString *)language
{
    NSLog(@"language = %@", language);
    self.currentOutputLanguage = [language copy];
    AVSpeechSynthesisVoice *newVoice = [AVSpeechSynthesisVoice voiceWithLanguage:language];
    if (newVoice != nil) {
        if ([language hasPrefix:@"en-"]) {
            [self reloadVoicePreferences];
        } else {
            self.robsDefaultVoice = [AVSpeechSynthesisVoice voiceWithLanguage:language];
        }
    }
    [self sayIt:[NSString stringWithFormat:@"Language set to %@", language]];
    //*** Choose a language that matches the language code ***
    
    //self.speechSynth = [[NSSpeechSynthesizer alloc] initWithVoice:@"com.apple.speech.synthesis.voice.jorge.premium"];
 
    /*
     //self.speechSynth = [[NSSpeechSynthesizer alloc] initWithVoice:@"com.apple.speech.synthesis.voice.jorge.premium"];
     
     
     NSLog(@"availableVoices, %@", [NSSpeechSynthesizer availableVoices]);
     
     availableVoices, (
     "com.apple.speech.synthesis.voice.Agnes",
     "com.apple.speech.synthesis.voice.Albert",
     "com.apple.speech.synthesis.voice.Alex",
     "com.apple.speech.synthesis.voice.alice",
     "com.apple.speech.synthesis.voice.alva",
     "com.apple.speech.synthesis.voice.amelie",
     "com.apple.speech.synthesis.voice.anna",
     "com.apple.speech.synthesis.voice.BadNews",
     "com.apple.speech.synthesis.voice.Bahh",
     "com.apple.speech.synthesis.voice.Bells",
     "com.apple.speech.synthesis.voice.Boing",
     "com.apple.speech.synthesis.voice.Bruce",
     "com.apple.speech.synthesis.voice.Bubbles",
     "com.apple.speech.synthesis.voice.carmit",
     "com.apple.speech.synthesis.voice.Cellos",
     "com.apple.speech.synthesis.voice.damayanti",
     "com.apple.speech.synthesis.voice.daniel",
     "com.apple.speech.synthesis.voice.Deranged",
     "com.apple.speech.synthesis.voice.diego",
     "com.apple.speech.synthesis.voice.ellen",
     "com.apple.speech.synthesis.voice.felipe.premium",
     "com.apple.speech.synthesis.voice.fiona",
     "com.apple.speech.synthesis.voice.Fred",
     "com.apple.speech.synthesis.voice.GoodNews",
     "com.apple.speech.synthesis.voice.Hysterical",
     "com.apple.speech.synthesis.voice.ioana",
     "com.apple.speech.synthesis.voice.joana",
     "com.apple.speech.synthesis.voice.jorge.premium",
     "com.apple.speech.synthesis.voice.juan",
     "com.apple.speech.synthesis.voice.Junior",
     "com.apple.speech.synthesis.voice.kanya",
     "com.apple.speech.synthesis.voice.karen",
     "com.apple.speech.synthesis.voice.Kathy",
     "com.apple.speech.synthesis.voice.kyoko",
     "com.apple.speech.synthesis.voice.laura",
     "com.apple.speech.synthesis.voice.lekha",
     "com.apple.speech.synthesis.voice.luca",
     "com.apple.speech.synthesis.voice.luciana",
     "com.apple.speech.synthesis.voice.maged",
     "com.apple.speech.synthesis.voice.mariska",
     "com.apple.speech.synthesis.voice.mei-jia",
     "com.apple.speech.synthesis.voice.melina",
     "com.apple.speech.synthesis.voice.milena",
     "com.apple.speech.synthesis.voice.moira",
     "com.apple.speech.synthesis.voice.monica",
     "com.apple.speech.synthesis.voice.nora",
     "com.apple.speech.synthesis.voice.oliver.premium",
     "com.apple.speech.synthesis.voice.oskar.premium",
     "com.apple.speech.synthesis.voice.paulina",
     "com.apple.speech.synthesis.voice.Organ",
     "com.apple.speech.synthesis.voice.Princess",
     "com.apple.speech.synthesis.voice.Ralph",
     "com.apple.speech.synthesis.voice.samantha.premium",
     "com.apple.speech.synthesis.voice.sara",
     "com.apple.speech.synthesis.voice.satu",
     "com.apple.speech.synthesis.voice.sin-ji",
     "com.apple.speech.synthesis.voice.tessa",
     "com.apple.speech.synthesis.voice.thomas",
     "com.apple.speech.synthesis.voice.ting-ting",
     "com.apple.speech.synthesis.voice.Trinoids",
     "com.apple.speech.synthesis.voice.veena",
     "com.apple.speech.synthesis.voice.Vicki",
     "com.apple.speech.synthesis.voice.Victoria",
     "com.apple.speech.synthesis.voice.Whisper",
     "com.apple.speech.synthesis.voice.xander",
     "com.apple.speech.synthesis.voice.yelda",
     "com.apple.speech.synthesis.voice.yuna",
     "com.apple.speech.synthesis.voice.yuri.premium",
     "com.apple.speech.synthesis.voice.Zarvox",
     "com.apple.speech.synthesis.voice.zosia",
     "com.apple.speech.synthesis.voice.zuzana"
     )
     
     com.apple.speech.synthesis.voice.Agnes speak en_US
     com.apple.speech.synthesis.voice.Albert speak en_US
     com.apple.speech.synthesis.voice.Alex speak en_US
     com.apple.speech.synthesis.voice.alice speak it_IT
     com.apple.speech.synthesis.voice.alva speak sv_SE
     com.apple.speech.synthesis.voice.amelie speak fr_CA
     com.apple.speech.synthesis.voice.anna speak de_DE
     com.apple.speech.synthesis.voice.BadNews speak en_US
     com.apple.speech.synthesis.voice.Bahh speak en_US
     com.apple.speech.synthesis.voice.Bells speak en_US
     com.apple.speech.synthesis.voice.Boing speak en_US
     com.apple.speech.synthesis.voice.Bruce speak en_US
     com.apple.speech.synthesis.voice.Bubbles speak en_US
     com.apple.speech.synthesis.voice.carmit speak he_IL
     com.apple.speech.synthesis.voice.Cellos speak en_US
     com.apple.speech.synthesis.voice.damayanti speak id_ID
     com.apple.speech.synthesis.voice.daniel speak en_GB
     com.apple.speech.synthesis.voice.Deranged speak en_US
     com.apple.speech.synthesis.voice.diego speak es_AR
     com.apple.speech.synthesis.voice.ellen speak nl_BE
     com.apple.speech.synthesis.voice.felipe.premium speak pt_BR
     com.apple.speech.synthesis.voice.fiona speak en-scotland
     com.apple.speech.synthesis.voice.Fred speak en_US
     com.apple.speech.synthesis.voice.GoodNews speak en_US
     com.apple.speech.synthesis.voice.Hysterical speak en_US
     com.apple.speech.synthesis.voice.ioana speak ro_RO
     com.apple.speech.synthesis.voice.joana speak pt_PT
     com.apple.speech.synthesis.voice.jorge.premium speak es_ES
     com.apple.speech.synthesis.voice.juan speak es_MX
     com.apple.speech.synthesis.voice.Junior speak en_US
     com.apple.speech.synthesis.voice.kanya speak th_TH
     com.apple.speech.synthesis.voice.karen speak en_AU
     com.apple.speech.synthesis.voice.Kathy speak en_US
     com.apple.speech.synthesis.voice.kyoko speak ja_JP
     com.apple.speech.synthesis.voice.laura speak sk_SK
     com.apple.speech.synthesis.voice.lekha speak hi_IN
     com.apple.speech.synthesis.voice.luca speak it_IT
     com.apple.speech.synthesis.voice.luciana speak pt_BR
     com.apple.speech.synthesis.voice.maged speak ar_SA
     com.apple.speech.synthesis.voice.mariska speak hu_HU
     com.apple.speech.synthesis.voice.mei-jia speak zh_TW
     com.apple.speech.synthesis.voice.melina speak el_GR
     com.apple.speech.synthesis.voice.milena speak ru_RU
     com.apple.speech.synthesis.voice.moira speak en_IE
     com.apple.speech.synthesis.voice.monica speak es_ES
     com.apple.speech.synthesis.voice.nora speak nb_NO
     com.apple.speech.synthesis.voice.oliver.premium speak en_GB
     com.apple.speech.synthesis.voice.oskar.premium speak sv_SE
     com.apple.speech.synthesis.voice.paulina speak es_MX
     com.apple.speech.synthesis.voice.Organ speak en_US
     com.apple.speech.synthesis.voice.Princess speak en_US
     com.apple.speech.synthesis.voice.Ralph speak en_US
     com.apple.speech.synthesis.voice.samantha.premium speak en_US
     com.apple.speech.synthesis.voice.sara speak da_DK
     com.apple.speech.synthesis.voice.satu speak fi_FI
     com.apple.speech.synthesis.voice.sin-ji speak zh_HK
     com.apple.speech.synthesis.voice.tessa speak en_ZA
     com.apple.speech.synthesis.voice.thomas speak fr_FR
     com.apple.speech.synthesis.voice.ting-ting speak zh_CN
     com.apple.speech.synthesis.voice.Trinoids speak en_US
     com.apple.speech.synthesis.voice.veena speak en_IN
     com.apple.speech.synthesis.voice.Vicki speak en_US
     com.apple.speech.synthesis.voice.Victoria speak en_US
     com.apple.speech.synthesis.voice.Whisper speak en_US
     com.apple.speech.synthesis.voice.xander speak nl_NL
     com.apple.speech.synthesis.voice.yelda speak tr_TR
     com.apple.speech.synthesis.voice.yuna speak ko_KR
     com.apple.speech.synthesis.voice.yuri.premium speak ru_RU
     com.apple.speech.synthesis.voice.Zarvox speak en_US
     com.apple.speech.synthesis.voice.zosia speak pl_PL
     com.apple.speech.synthesis.voice.zuzana speak cs_CZ
     
     for (NSString *voiceIdentifierString in [NSSpeechSynthesizer availableVoices]) {
         NSString *voiceLocaleIdentifier = [[NSSpeechSynthesizer attributesForVoice:voiceIdentifierString] objectForKey:NSVoiceLocaleIdentifier];
         printf("%s speak %s\n", [voiceIdentifierString cStringUsingEncoding:NSUTF8StringEncoding], [voiceLocaleIdentifier cStringUsingEncoding:NSUTF8StringEncoding]);
     }*/
}


- (void)stopIt:(id)sender {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopIt:sender];
        });
        return;
    }
    NSLog(@"stopping");
    //[self.speechSynth stopSpeaking];
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
/*
NSLog(@"voices = %@", [AVSpeechSynthesisVoice speechVoices]);
voices = (
    "[AVSpeechSynthesisVoice 0xbe44bb460] Language: en-US, Name: Samantha, Quality: Default [com.apple.voice.compact.en-US.Samantha]",
    "[AVSpeechSynthesisVoice 0xbe44bb470] Language: en-US, Name: Zoe, Quality: Premium [com.apple.voice.premium.en-US.Zoe]",
    "[AVSpeechSynthesisVoice 0xbe44bb530] Language: en-US, Name: Eddy, Quality: Default [com.apple.eloquence.en-US.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb880] Language: en-US, Name: Flo, Quality: Default [com.apple.eloquence.en-US.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb890] Language: en-US, Name: Grandma, Quality: Default [com.apple.eloquence.en-US.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb8a0] Language: en-US, Name: Grandpa, Quality: Default [com.apple.eloquence.en-US.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb8b0] Language: en-US, Name: Reed, Quality: Default [com.apple.eloquence.en-US.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb8c0] Language: en-US, Name: Rocko, Quality: Default [com.apple.eloquence.en-US.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bb7c0] Language: en-US, Name: Sandy, Quality: Default [com.apple.eloquence.en-US.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44bb7d0] Language: en-US, Name: Shelley, Quality: Default [com.apple.eloquence.en-US.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bb7b0] Language: en-US, Name: Bruce, Quality: Enhanced [com.apple.speech.synthesis.voice.Bruce]",
    "[AVSpeechSynthesisVoice 0xbe44ba910] Language: en-US, Name: Susan, Quality: Enhanced [com.apple.voice.enhanced.en-US.Susan]",
    "[AVSpeechSynthesisVoice 0xbe44ba610] Language: en-US, Name: Tom, Quality: Enhanced [com.apple.voice.enhanced.en-US.Tom]",
    "[AVSpeechSynthesisVoice 0xbe44b9240] Language: en-US, Name: Albert, Quality: Default [com.apple.speech.synthesis.voice.Albert]",
    "[AVSpeechSynthesisVoice 0xbe44ba130] Language: en-US, Name: Bad News, Quality: Default [com.apple.speech.synthesis.voice.BadNews]",
    "[AVSpeechSynthesisVoice 0xbe44b9ec0] Language: en-US, Name: Bahh, Quality: Default [com.apple.speech.synthesis.voice.Bahh]",
    "[AVSpeechSynthesisVoice 0xbe44b9e70] Language: en-US, Name: Bells, Quality: Default [com.apple.speech.synthesis.voice.Bells]",
    "[AVSpeechSynthesisVoice 0xbe44b88f0] Language: en-US, Name: Boing, Quality: Default [com.apple.speech.synthesis.voice.Boing]",
    "[AVSpeechSynthesisVoice 0xbe44b88e0] Language: en-US, Name: Bubbles, Quality: Default [com.apple.speech.synthesis.voice.Bubbles]",
    "[AVSpeechSynthesisVoice 0xbe44b8880] Language: en-US, Name: Cellos, Quality: Default [com.apple.speech.synthesis.voice.Cellos]",
    "[AVSpeechSynthesisVoice 0xbe44b89f0] Language: en-US, Name: Wobble, Quality: Default [com.apple.speech.synthesis.voice.Deranged]",
    "[AVSpeechSynthesisVoice 0xbe44b8910] Language: en-US, Name: Fred, Quality: Default [com.apple.speech.synthesis.voice.Fred]",
    "[AVSpeechSynthesisVoice 0xbe44b8500] Language: en-US, Name: Good News, Quality: Default [com.apple.speech.synthesis.voice.GoodNews]",
    "[AVSpeechSynthesisVoice 0xbe44b9eb0] Language: en-US, Name: Jester, Quality: Default [com.apple.speech.synthesis.voice.Hysterical]",
    "[AVSpeechSynthesisVoice 0xbe44b9e90] Language: en-US, Name: Junior, Quality: Default [com.apple.speech.synthesis.voice.Junior]",
    "[AVSpeechSynthesisVoice 0xbe44b8870] Language: en-US, Name: Kathy, Quality: Default [com.apple.speech.synthesis.voice.Kathy]",
    "[AVSpeechSynthesisVoice 0xbe44b8780] Language: en-US, Name: Organ, Quality: Default [com.apple.speech.synthesis.voice.Organ]",
    "[AVSpeechSynthesisVoice 0xbe44b86d0] Language: en-US, Name: Superstar, Quality: Default [com.apple.speech.synthesis.voice.Princess]",
    "[AVSpeechSynthesisVoice 0xbe44b86e0] Language: en-US, Name: Ralph, Quality: Default [com.apple.speech.synthesis.voice.Ralph]",
    "[AVSpeechSynthesisVoice 0xbe44b86f0] Language: en-US, Name: Trinoids, Quality: Default [com.apple.speech.synthesis.voice.Trinoids]",
    "[AVSpeechSynthesisVoice 0xbe44b8690] Language: en-US, Name: Whisper, Quality: Default [com.apple.speech.synthesis.voice.Whisper]",
    "[AVSpeechSynthesisVoice 0xbe44b8680] Language: en-US, Name: Zarvox, Quality: Default [com.apple.speech.synthesis.voice.Zarvox]",
    "[AVSpeechSynthesisVoice 0xbe44b8620] Language: en-GB, Name: Daniel, Quality: Enhanced [com.apple.voice.enhanced.en-GB.Daniel]",
    "[AVSpeechSynthesisVoice 0xbe44b8660] Language: en-IE, Name: Moira, Quality: Enhanced [com.apple.voice.enhanced.en-IE.Moira]",
    "[AVSpeechSynthesisVoice 0xbe44b8fb0] Language: en-GB, Name: Daniel, Quality: Default [com.apple.voice.super-compact.en-GB.Daniel]",
    "[AVSpeechSynthesisVoice 0xbe44b8ea0] Language: en-AU, Name: Karen, Quality: Default [com.apple.voice.super-compact.en-AU.Karen]",
    "[AVSpeechSynthesisVoice 0xbe44b8f30] Language: en-IE, Name: Moira, Quality: Default [com.apple.voice.super-compact.en-IE.Moira]",
    "[AVSpeechSynthesisVoice 0xbe44b8f00] Language: en-IN, Name: Rishi, Quality: Default [com.apple.voice.super-compact.en-IN.Rishi]",
    "[AVSpeechSynthesisVoice 0xbe44b8f10] Language: en-ZA, Name: Tessa, Quality: Default [com.apple.voice.super-compact.en-ZA.Tessa]",
    "[AVSpeechSynthesisVoice 0xbe44b8ef0] Language: en-GB, Name: Jamie, Quality: Premium [com.apple.voice.premium.en-GB.Malcolm]",
    "[AVSpeechSynthesisVoice 0xbe44b8f20] Language: en-GB, Name: Serena, Quality: Premium [com.apple.voice.premium.en-GB.Serena]",
    "[AVSpeechSynthesisVoice 0xbe44b8ee0] Language: en-GB, Name: Eddy, Quality: Default [com.apple.eloquence.en-GB.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44b8ec0] Language: en-GB, Name: Flo, Quality: Default [com.apple.eloquence.en-GB.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44b8ed0] Language: en-GB, Name: Grandma, Quality: Default [com.apple.eloquence.en-GB.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44b8e20] Language: en-GB, Name: Grandpa, Quality: Default [com.apple.eloquence.en-GB.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44b8e10] Language: en-GB, Name: Reed, Quality: Default [com.apple.eloquence.en-GB.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44b8df0] Language: en-GB, Name: Rocko, Quality: Default [com.apple.eloquence.en-GB.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44b8e00] Language: en-GB, Name: Sandy, Quality: Default [com.apple.eloquence.en-GB.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44b8440] Language: en-GB, Name: Shelley, Quality: Default [com.apple.eloquence.en-GB.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44b9290] Language: en-GB, Name: Oliver, Quality: Enhanced [com.apple.voice.enhanced.en-GB.Oliver]",
    "[AVSpeechSynthesisVoice 0xbe44b9280] Language: en-IN, Name: Sangeeta, Quality: Enhanced [com.apple.voice.enhanced.en-IN.Sangeeta]",
    "[AVSpeechSynthesisVoice 0xbe44b9220] Language: en-IN, Name: Veena, Quality: Enhanced [com.apple.voice.enhanced.en-IN.Veena]",
    "[AVSpeechSynthesisVoice 0xbe44b9210] Language: es-MX, Name: Paulina, Quality: Default [com.apple.voice.compact.es-MX.Paulina]",
    "[AVSpeechSynthesisVoice 0xbe44b8d70] Language: it-IT, Name: Alice, Quality: Default [com.apple.voice.super-compact.it-IT.Alice]",
    "[AVSpeechSynthesisVoice 0xbe44b8d60] Language: sv-SE, Name: Alva, Quality: Default [com.apple.voice.super-compact.sv-SE.Alva]",
    "[AVSpeechSynthesisVoice 0xbe44b8590] Language: fr-CA, Name: Am\U00e9lie, Quality: Default [com.apple.voice.super-compact.fr-CA.Amelie]",
    "[AVSpeechSynthesisVoice 0xbe44b8560] Language: ms-MY, Name: Amira, Quality: Default [com.apple.voice.super-compact.ms-MY.Amira]",
    "[AVSpeechSynthesisVoice 0xbe44b8570] Language: de-DE, Name: Anna, Quality: Default [com.apple.voice.super-compact.de-DE.Anna]",
    "[AVSpeechSynthesisVoice 0xbe44b8550] Language: he-IL, Name: Carmit, Quality: Default [com.apple.voice.super-compact.he-IL.Carmit]",
    "[AVSpeechSynthesisVoice 0xbe44b8580] Language: id-ID, Name: Damayanti, Quality: Default [com.apple.voice.super-compact.id-ID.Damayanti]",
    "[AVSpeechSynthesisVoice 0xbe44b8540] Language: bg-BG, Name: Daria, Quality: Default [com.apple.voice.super-compact.bg-BG.Daria]",
    "[AVSpeechSynthesisVoice 0xbe44b8520] Language: nl-BE, Name: Ellen, Quality: Default [com.apple.voice.super-compact.nl-BE.Ellen]",
    "[AVSpeechSynthesisVoice 0xbe44b8530] Language: ro-RO, Name: Ioana, Quality: Default [com.apple.voice.super-compact.ro-RO.Ioana]",
    "[AVSpeechSynthesisVoice 0xbe44b8480] Language: pt-PT, Name: Joana, Quality: Default [com.apple.voice.super-compact.pt-PT.Joana]",
    "[AVSpeechSynthesisVoice 0xbe44b8470] Language: th-TH, Name: Kanya, Quality: Default [com.apple.voice.super-compact.th-TH.Kanya]",
    "[AVSpeechSynthesisVoice 0xbe44b8450] Language: ja-JP, Name: Kyoko, Quality: Default [com.apple.voice.super-compact.ja-JP.Kyoko]",
    "[AVSpeechSynthesisVoice 0xbe44b8460] Language: hr-HR, Name: Lana, Quality: Default [com.apple.voice.super-compact.hr-HR.Lana]",
    "[AVSpeechSynthesisVoice 0xbe44b8040] Language: sk-SK, Name: Laura, Quality: Default [com.apple.voice.super-compact.sk-SK.Laura]",
    "[AVSpeechSynthesisVoice 0xbe44b8940] Language: hi-IN, Name: Lekha, Quality: Default [com.apple.voice.super-compact.hi-IN.Lekha]",
    "[AVSpeechSynthesisVoice 0xbe44b8930] Language: uk-UA, Name: Lesya, Quality: Default [com.apple.voice.super-compact.uk-UA.Lesya]",
    "[AVSpeechSynthesisVoice 0xbe44b88d0] Language: vi-VN, Name: Linh, Quality: Default [com.apple.voice.super-compact.vi-VN.Linh]",
    "[AVSpeechSynthesisVoice 0xbe44b88c0] Language: pt-BR, Name: Luciana, Quality: Default [com.apple.voice.super-compact.pt-BR.Luciana]",
    "[AVSpeechSynthesisVoice 0xbe44b83a0] Language: ar-001, Name: Majed, Quality: Default [com.apple.voice.super-compact.ar-001.Maged]",
    "[AVSpeechSynthesisVoice 0xbe44b8390] Language: hu-HU, Name: T\U00fcnde, Quality: Default [com.apple.voice.super-compact.hu-HU.Mariska]",
    "[AVSpeechSynthesisVoice 0xbe44b8170] Language: zh-TW, Name: Meijia, Quality: Default [com.apple.voice.super-compact.zh-TW.Meijia]",
    "[AVSpeechSynthesisVoice 0xbe44b81f0] Language: el-GR, Name: Melina, Quality: Default [com.apple.voice.super-compact.el-GR.Melina]",
    "[AVSpeechSynthesisVoice 0xbe44b8230] Language: ru-RU, Name: Milena, Quality: Default [com.apple.voice.super-compact.ru-RU.Milena]",
    "[AVSpeechSynthesisVoice 0xbe44b8220] Language: es-ES, Name: M\U00f3nica, Quality: Default [com.apple.voice.super-compact.es-ES.Monica]",
    "[AVSpeechSynthesisVoice 0xbe44b8210] Language: ca-ES, Name: Montse, Quality: Default [com.apple.voice.super-compact.ca-ES.Montserrat]",
    "[AVSpeechSynthesisVoice 0xbe44b8080] Language: nb-NO, Name: Nora, Quality: Default [com.apple.voice.super-compact.nb-NO.Nora]",
    "[AVSpeechSynthesisVoice 0xbe44b8070] Language: da-DK, Name: Sara, Quality: Default [com.apple.voice.super-compact.da-DK.Sara]",
    "[AVSpeechSynthesisVoice 0xbe44b8050] Language: fi-FI, Name: Satu, Quality: Default [com.apple.voice.super-compact.fi-FI.Satu]",
    "[AVSpeechSynthesisVoice 0xbe44b8060] Language: yue-HK, Name: Sinji, Quality: Default [com.apple.voice.super-compact.zh-HK.Sinji]",
    "[AVSpeechSynthesisVoice 0xbe44b8820] Language: fr-FR, Name: Thomas, Quality: Default [com.apple.voice.super-compact.fr-FR.Thomas]",
    "[AVSpeechSynthesisVoice 0xbe44b8330] Language: sl-SI, Name: Tina, Quality: Default [com.apple.voice.super-compact.sl-SI.Tina]",
    "[AVSpeechSynthesisVoice 0xbe44b8310] Language: zh-CN, Name: Tingting, Quality: Default [com.apple.voice.super-compact.zh-CN.Tingting]",
    "[AVSpeechSynthesisVoice 0xbe44b8320] Language: nl-NL, Name: Xander, Quality: Default [com.apple.voice.super-compact.nl-NL.Xander]",
    "[AVSpeechSynthesisVoice 0xbe44b8300] Language: tr-TR, Name: Yelda, Quality: Default [com.apple.voice.super-compact.tr-TR.Yelda]",
    "[AVSpeechSynthesisVoice 0xbe44b82f0] Language: ko-KR, Name: Yuna, Quality: Default [com.apple.voice.super-compact.ko-KR.Yuna]",
    "[AVSpeechSynthesisVoice 0xbe44b8290] Language: pl-PL, Name: Zosia, Quality: Default [com.apple.voice.super-compact.pl-PL.Zosia]",
    "[AVSpeechSynthesisVoice 0xbe44b8280] Language: cs-CZ, Name: Zuzana, Quality: Default [com.apple.voice.super-compact.cs-CZ.Zuzana]",
    "[AVSpeechSynthesisVoice 0xbe44bb420] Language: ta-IN, Name: Vani, Quality: Default [com.apple.voice.super-compact.ta-IN.Vani]",
    "[AVSpeechSynthesisVoice 0xbe44bb430] Language: zh-CN, Name: Eddy, Quality: Default [com.apple.eloquence.zh-CN.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb410] Language: zh-TW, Name: Eddy, Quality: Default [com.apple.eloquence.zh-TW.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb400] Language: de-DE, Name: Eddy, Quality: Default [com.apple.eloquence.de-DE.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb3f0] Language: es-ES, Name: Eddy, Quality: Default [com.apple.eloquence.es-ES.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb3e0] Language: es-MX, Name: Eddy, Quality: Default [com.apple.eloquence.es-MX.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb3d0] Language: fi-FI, Name: Eddy, Quality: Default [com.apple.eloquence.fi-FI.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb3c0] Language: fr-CA, Name: Eddy, Quality: Default [com.apple.eloquence.fr-CA.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb3b0] Language: fr-FR, Name: Eddy, Quality: Default [com.apple.eloquence.fr-FR.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44ba140] Language: it-IT, Name: Eddy, Quality: Default [com.apple.eloquence.it-IT.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb380] Language: ja-JP, Name: Eddy, Quality: Default [com.apple.eloquence.ja-JP.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb390] Language: ko-KR, Name: Eddy, Quality: Default [com.apple.eloquence.ko-KR.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb370] Language: pt-BR, Name: Eddy, Quality: Default [com.apple.eloquence.pt-BR.Eddy]",
    "[AVSpeechSynthesisVoice 0xbe44bb360] Language: zh-CN, Name: Flo, Quality: Default [com.apple.eloquence.zh-CN.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb350] Language: zh-TW, Name: Flo, Quality: Default [com.apple.eloquence.zh-TW.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb340] Language: de-DE, Name: Flo, Quality: Default [com.apple.eloquence.de-DE.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb330] Language: es-ES, Name: Flo, Quality: Default [com.apple.eloquence.es-ES.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb320] Language: es-MX, Name: Flo, Quality: Default [com.apple.eloquence.es-MX.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb310] Language: fi-FI, Name: Flo, Quality: Default [com.apple.eloquence.fi-FI.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44ba090] Language: fr-CA, Name: Flo, Quality: Default [com.apple.eloquence.fr-CA.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb2e0] Language: fr-FR, Name: Flo, Quality: Default [com.apple.eloquence.fr-FR.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb2f0] Language: it-IT, Name: Flo, Quality: Default [com.apple.eloquence.it-IT.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb2d0] Language: ja-JP, Name: Flo, Quality: Default [com.apple.eloquence.ja-JP.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb2c0] Language: ko-KR, Name: Flo, Quality: Default [com.apple.eloquence.ko-KR.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb2b0] Language: pt-BR, Name: Flo, Quality: Default [com.apple.eloquence.pt-BR.Flo]",
    "[AVSpeechSynthesisVoice 0xbe44bb2a0] Language: zh-CN, Name: Grandma, Quality: Default [com.apple.eloquence.zh-CN.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb290] Language: zh-TW, Name: Grandma, Quality: Default [com.apple.eloquence.zh-TW.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb280] Language: de-DE, Name: Grandma, Quality: Default [com.apple.eloquence.de-DE.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb270] Language: es-ES, Name: Grandma, Quality: Default [com.apple.eloquence.es-ES.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44b9f70] Language: es-MX, Name: Grandma, Quality: Default [com.apple.eloquence.es-MX.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb240] Language: fi-FI, Name: Grandma, Quality: Default [com.apple.eloquence.fi-FI.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb250] Language: fr-CA, Name: Grandma, Quality: Default [com.apple.eloquence.fr-CA.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb230] Language: fr-FR, Name: Grandma, Quality: Default [com.apple.eloquence.fr-FR.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb220] Language: it-IT, Name: Grandma, Quality: Default [com.apple.eloquence.it-IT.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb210] Language: ja-JP, Name: Grandma, Quality: Default [com.apple.eloquence.ja-JP.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb200] Language: ko-KR, Name: Grandma, Quality: Default [com.apple.eloquence.ko-KR.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb1f0] Language: pt-BR, Name: Grandma, Quality: Default [com.apple.eloquence.pt-BR.Grandma]",
    "[AVSpeechSynthesisVoice 0xbe44bb1e0] Language: zh-CN, Name: Grandpa, Quality: Default [com.apple.eloquence.zh-CN.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb1d0] Language: zh-TW, Name: Grandpa, Quality: Default [com.apple.eloquence.zh-TW.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44b9f30] Language: de-DE, Name: Grandpa, Quality: Default [com.apple.eloquence.de-DE.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb1a0] Language: es-ES, Name: Grandpa, Quality: Default [com.apple.eloquence.es-ES.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb1b0] Language: es-MX, Name: Grandpa, Quality: Default [com.apple.eloquence.es-MX.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb190] Language: fi-FI, Name: Grandpa, Quality: Default [com.apple.eloquence.fi-FI.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb180] Language: fr-CA, Name: Grandpa, Quality: Default [com.apple.eloquence.fr-CA.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb170] Language: fr-FR, Name: Grandpa, Quality: Default [com.apple.eloquence.fr-FR.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb160] Language: it-IT, Name: Grandpa, Quality: Default [com.apple.eloquence.it-IT.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb150] Language: ja-JP, Name: Grandpa, Quality: Default [com.apple.eloquence.ja-JP.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb140] Language: ko-KR, Name: Grandpa, Quality: Default [com.apple.eloquence.ko-KR.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44bb130] Language: pt-BR, Name: Grandpa, Quality: Default [com.apple.eloquence.pt-BR.Grandpa]",
    "[AVSpeechSynthesisVoice 0xbe44b9e80] Language: fr-FR, Name: Jacques, Quality: Default [com.apple.eloquence.fr-FR.Jacques]",
    "[AVSpeechSynthesisVoice 0xbe44bb100] Language: zh-CN, Name: Reed, Quality: Default [com.apple.eloquence.zh-CN.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb110] Language: zh-TW, Name: Reed, Quality: Default [com.apple.eloquence.zh-TW.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb0f0] Language: de-DE, Name: Reed, Quality: Default [com.apple.eloquence.de-DE.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb0e0] Language: es-ES, Name: Reed, Quality: Default [com.apple.eloquence.es-ES.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb0d0] Language: es-MX, Name: Reed, Quality: Default [com.apple.eloquence.es-MX.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb0c0] Language: fi-FI, Name: Reed, Quality: Default [com.apple.eloquence.fi-FI.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb0b0] Language: fr-CA, Name: Reed, Quality: Default [com.apple.eloquence.fr-CA.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb0a0] Language: it-IT, Name: Reed, Quality: Default [com.apple.eloquence.it-IT.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb090] Language: ja-JP, Name: Reed, Quality: Default [com.apple.eloquence.ja-JP.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44b9dd0] Language: ko-KR, Name: Reed, Quality: Default [com.apple.eloquence.ko-KR.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb060] Language: pt-BR, Name: Reed, Quality: Default [com.apple.eloquence.pt-BR.Reed]",
    "[AVSpeechSynthesisVoice 0xbe44bb070] Language: zh-CN, Name: Rocko, Quality: Default [com.apple.eloquence.zh-CN.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bb050] Language: zh-TW, Name: Rocko, Quality: Default [com.apple.eloquence.zh-TW.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bb040] Language: de-DE, Name: Rocko, Quality: Default [com.apple.eloquence.de-DE.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bb030] Language: es-ES, Name: Rocko, Quality: Default [com.apple.eloquence.es-ES.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bb020] Language: es-MX, Name: Rocko, Quality: Default [com.apple.eloquence.es-MX.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bb010] Language: fi-FI, Name: Rocko, Quality: Default [com.apple.eloquence.fi-FI.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bb000] Language: fr-CA, Name: Rocko, Quality: Default [com.apple.eloquence.fr-CA.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44baff0] Language: fr-FR, Name: Rocko, Quality: Default [com.apple.eloquence.fr-FR.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44b9d20] Language: it-IT, Name: Rocko, Quality: Default [com.apple.eloquence.it-IT.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bafc0] Language: ja-JP, Name: Rocko, Quality: Default [com.apple.eloquence.ja-JP.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bafd0] Language: ko-KR, Name: Rocko, Quality: Default [com.apple.eloquence.ko-KR.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bafb0] Language: pt-BR, Name: Rocko, Quality: Default [com.apple.eloquence.pt-BR.Rocko]",
    "[AVSpeechSynthesisVoice 0xbe44bafa0] Language: zh-CN, Name: Sandy, Quality: Default [com.apple.eloquence.zh-CN.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf90] Language: zh-TW, Name: Sandy, Quality: Default [com.apple.eloquence.zh-TW.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf80] Language: de-DE, Name: Sandy, Quality: Default [com.apple.eloquence.de-DE.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf70] Language: es-ES, Name: Sandy, Quality: Default [com.apple.eloquence.es-ES.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf60] Language: es-MX, Name: Sandy, Quality: Default [com.apple.eloquence.es-MX.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf50] Language: fi-FI, Name: Sandy, Quality: Default [com.apple.eloquence.fi-FI.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44b9c70] Language: fr-CA, Name: Sandy, Quality: Default [com.apple.eloquence.fr-CA.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf20] Language: fr-FR, Name: Sandy, Quality: Default [com.apple.eloquence.fr-FR.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf30] Language: it-IT, Name: Sandy, Quality: Default [com.apple.eloquence.it-IT.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf10] Language: ja-JP, Name: Sandy, Quality: Default [com.apple.eloquence.ja-JP.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baf00] Language: ko-KR, Name: Sandy, Quality: Default [com.apple.eloquence.ko-KR.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baef0] Language: pt-BR, Name: Sandy, Quality: Default [com.apple.eloquence.pt-BR.Sandy]",
    "[AVSpeechSynthesisVoice 0xbe44baee0] Language: zh-CN, Name: Shelley, Quality: Default [com.apple.eloquence.zh-CN.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44baed0] Language: zh-TW, Name: Shelley, Quality: Default [com.apple.eloquence.zh-TW.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44baec0] Language: de-DE, Name: Shelley, Quality: Default [com.apple.eloquence.de-DE.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44baeb0] Language: es-ES, Name: Shelley, Quality: Default [com.apple.eloquence.es-ES.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44b9a80] Language: es-MX, Name: Shelley, Quality: Default [com.apple.eloquence.es-MX.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bae80] Language: fi-FI, Name: Shelley, Quality: Default [com.apple.eloquence.fi-FI.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bae90] Language: fr-CA, Name: Shelley, Quality: Default [com.apple.eloquence.fr-CA.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44badc0] Language: fr-FR, Name: Shelley, Quality: Default [com.apple.eloquence.fr-FR.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bae50] Language: it-IT, Name: Shelley, Quality: Default [com.apple.eloquence.it-IT.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bae60] Language: ja-JP, Name: Shelley, Quality: Default [com.apple.eloquence.ja-JP.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bad00] Language: ko-KR, Name: Shelley, Quality: Default [com.apple.eloquence.ko-KR.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bb710] Language: pt-BR, Name: Shelley, Quality: Default [com.apple.eloquence.pt-BR.Shelley]",
    "[AVSpeechSynthesisVoice 0xbe44bb720] Language: kn-IN, Name: Soumya, Quality: Default [com.apple.voice.compact.kn-IN.Alpana]",
    "[AVSpeechSynthesisVoice 0xbe44bb5f0] Language: te-IN, Name: Geeta, Quality: Default [com.apple.voice.compact.te-IN.Geeta]",
    "[AVSpeechSynthesisVoice 0xbe44bb8d0] Language: bn-IN, Name: Piya, Quality: Default [com.apple.voice.compact.bn-IN.Paya]"
)
*/
