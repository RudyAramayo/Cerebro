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


@interface ROBSpeechBox() <AVSpeechSynthesizerDelegate, SFSpeechRecognizerDelegate, SFSpeechRecognitionTaskDelegate, NSSpeechSynthesizerDelegate>

@property (readwrite, retain) NSSpeechSynthesizer *speechSynth;

//new properties
@property (nonatomic, strong) AVCaptureSession *capture;
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, assign) BOOL isSpeaking;
@property (readwrite, retain) NSMutableArray *localeArray;
@property (readwrite, assign) int selectedLocaleIndex;
@property (readwrite, retain) NSTimer *speechDidStopProcessingTimer;
@property (readwrite, retain) NSTimer *debounceSpeechInputTimer;
@property (readwrite, retain) NSString *currentTextInput;

@end


@implementation ROBSpeechBox



- (instancetype)init
{
    self = [super init];
    if (self) {
        NSLog(@"SpeechBox Init");
        self.emotion = anger;
        self.commands = [@[@"robbie", @"robot", @"hey robbie", @"hey robot", @"rob",  @"robbie one"] mutableCopy];
        self.speechSynth = [[NSSpeechSynthesizer alloc] initWithVoice:[NSSpeechSynthesizer defaultVoice]];
        
        self.speechSynth.delegate = self;
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
        
        [self sayIt:@"Orbitus Robot Online"];
        
    }
    return self;
}

- (void) resume_listening
{
    [[NSApplication sharedApplication] becomeFirstResponder];
        
    if (self.audioEngine.isRunning)
    {
        [self.audioEngine stop];
        [self.speechRequest endAudio];
    }
    else{
        [self setupSpeechRecognition];
    }
    NSLog(@"Listening");
}


- (void) setupSpeechRecognition
{
    self.isSpeaking = false;
    
    [self startRecognizer];
    
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.speechSynthesizer  = [[AVSpeechSynthesizer alloc] init];
    [self.speechSynthesizer setDelegate:self];

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
}


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance
{
    NSLog(@"didFinishSpeechUtterance");
    self.isSpeaking = false;
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
}


- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)characterRange utterance:(AVSpeechUtterance *)utterance
{
    NSLog(@"willSpeakRangeOfSpeechString");
    NSLog(@"Speaking!");
}

#pragma mark -

- (void)startRecognizer
{
    NSString *locale = [self.localeArray[self.selectedLocaleIndex] valueForKey:@"locale_id"];
    self.currentTextInput = @"";
    NSLog(@"starting speech recognizer with Locale - %@", locale);
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:locale]];
    self.speechRecognizer.delegate = self;
    
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status == SFSpeechRecognizerAuthorizationStatusAuthorized){
            
            self.speechRequest = [SFSpeechAudioBufferRecognitionRequest new];
            self.speechRequest.shouldReportPartialResults = YES;
            self.speechRequest.requiresOnDeviceRecognition = YES;
            
            AVAudioInputNode *inputNode = [self.audioEngine inputNode];

            if (self.speechRequest == nil) {
                NSLog(@"Unable to created a SFSpeechAudioBufferRecognitionRequest object");
            }
            
            if (inputNode == nil) {
                NSLog(@"Unable to created a inputNode object");
            }
                        
            self.task = [self.speechRecognizer recognitionTaskWithRequest:self.speechRequest resultHandler:^(SFSpeechRecognitionResult* result, NSError *error){
                BOOL isFinal = false;
                
                if (result != nil)
                {
                    //NSLog(@"final - %@", result.bestTranscription.formattedString);
                    isFinal = result.isFinal;
                    
                    if (![result.bestTranscription.formattedString isEqualToString:self.currentTextInput]) {
                        //PROCESS SPOKE WORDS HERE
                        //NSLog(@"final - %@", result.bestTranscription.formattedString);

                        if ([result.bestTranscription.formattedString containsString:@"hold on"]) {
                            
                        }
                            
                        self.currentTextInput = result.bestTranscription.formattedString;
                        
                        if (!self.isSpeaking) {
                            if (self.debounceSpeechInputTimer) {
                                [self.debounceSpeechInputTimer invalidate];
                            }
                            self.debounceSpeechInputTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:NO block:^(NSTimer * _Nonnull timer) {
                                [self.delegate inputText:result.bestTranscription.formattedString];
                            }];
                        }
                    }
                }
                
                if (error != nil || isFinal)
                {
                    if (!isFinal)
                        NSLog(@"error = %@", error.localizedDescription);
                    else
                        NSLog(@"restarting speech recognition ");
                    
                    [self.audioEngine stop];
                    [inputNode removeTapOnBus:0];
                    
                    self.speechRequest = nil;
                    self.task = nil;
                    
                    //self.recordButton.enabled = true;
                    //[self.recordButton setTitle:@"Stop Recording"];
                    
                    [self startRecognizer];
                }
                
            }];
            
            [inputNode installTapOnBus:0 bufferSize:1024 format:[inputNode outputFormatForBus:0] block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when){
                [self.speechRequest appendAudioPCMBuffer:buffer];
            }];
            
            
            NSError *outError;
            
            [self.audioEngine prepare];
            [self.audioEngine startAndReturnError:&outError];
            
            if (outError)
                NSLog(@"Error %@", outError);

            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"\n(Go ahead, I'm listening)");
                //self.textView.text = [self.textView.text stringByAppendingString:@"\n(Go ahead, I'm listening)" ];
            });
            

            
            //---------
            // Shows a different audio tap method that shows sample buffers
            // should call startCapture method in main queue or it may crash
            //dispatch_async(dispatch_get_main_queue(), ^{
            //    [self startCapture];
            //});
            //---------
            
        }
    }];
}

- (void)endRecognizer
{
    // END capture and END voice Reco
    // or Apple will terminate this task after 30000ms.
    [self endCapture];
    [self.speechRequest endAudio];
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
        [self.audioEngine stop];
        [self.audioEngine.inputNode removeTapOnBus:0];
        self.task = nil;
        self.speechRequest = nil;
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
    self.isSpeaking = true;
    dispatch_async(dispatch_get_main_queue(), ^(){
        // Is the string zero-length?
        if ([stringToSpeak length] == 0) {
            NSLog(@"string is of zero-length");
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
        [self.speechSynth startSpeakingString:stringToSpeak];
        NSLog(@"Have started to say: %@", stringToSpeak);
    });
}

- (void) setOutputLanguage:(NSString *)language
{
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
    NSLog(@"stopping");
    [self.speechSynth stopSpeaking];
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


#pragma mark -


- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking
{
    NSLog(@"didFinishSpeaking");
//    if (self.speechDidStopProcessingTimer) {
//        [self.speechDidStopProcessingTimer invalidate];
//    }
    
//    float finalizeSpeechProcessingTime = 10;
//    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(finalizeSpeechProcessingTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//        self.isSpeaking = false;
//        NSLog(@"isSpeaking is false");
//    });
    
    //self.isProcessingSpeech = false;
    [self.delegate didFinishProcessingSpeech];
    
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender willSpeakWord:(NSRange)characterRange ofString:(NSString *)string
{
    int speechDidFailToProcessTimeout = 1.5;
    self.isSpeaking = true;
    //self.isProcessingSpeech = true;
    [self.delegate willStartProcessingSpeech];
    NSString *word = [string substringWithRange:characterRange];
    NSLog(@"willSpeakWord = %@", word);
    
    if (self.speechDidStopProcessingTimer) {
        [self.speechDidStopProcessingTimer invalidate];
    }
    self.speechDidStopProcessingTimer = [NSTimer scheduledTimerWithTimeInterval:speechDidFailToProcessTimeout repeats:NO block:^(NSTimer * _Nonnull timer) {
        NSLog(@"isSpeaking is false");
        self.isSpeaking = false;
    }];
}


- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender willSpeakPhoneme:(short)phonemeOpcode
{
    NSLog(@"willSpeakPhoneme");
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didEncounterErrorAtIndex:(NSUInteger)characterIndex ofString:(NSString *)string message:(NSString *)message
{
    self.isSpeaking = false;
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didEncounterSyncMessage:(NSString *)message NS_SWIFT_UI_ACTOR API_AVAILABLE(macos(10.5)) {
    NSLog(@"speech sync message");
    self.isSpeaking = false;
}


@end
