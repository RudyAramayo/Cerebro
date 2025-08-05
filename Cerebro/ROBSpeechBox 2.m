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


@interface ROBSpeechBox() <NSSpeechSynthesizerDelegate>

@property (readwrite, retain) NSStatusItem *statusBarItem;
@property (readwrite, retain) NSSpeechRecognizer *speechRecognizer;
@property (readwrite, retain) NSSpeechSynthesizer *speechSynth;
@property (readwrite, assign) bool isProcessingSpeech;
@end


@implementation ROBSpeechBox



- (instancetype)init
{
    self = [super init];
    if (self) {
        NSLog(@"SpeechBox Init");
        self.emotion = anger;
        self.commands = [@[@"robbie", @"robot", @"hey robbie", @"hey robot", @"rob",  @"robbie one"] mutableCopy];
        self.statusBarItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        self.speechRecognizer = [NSSpeechRecognizer new];
        self.isProcessingSpeech = false;
        self.speechSynth = [[NSSpeechSynthesizer alloc] initWithVoice:[NSSpeechSynthesizer defaultVoice]];
        
        self.speechSynth.delegate = self;
        self.previousInputText_1 = @"";
        self.previousInputAnswer_1 = @"";
        self.previousInputText_2 = @"";
        self.previousInputAnswer_2 = @"";
        self.previousInputText_3 = @"";
        self.previousInputAnswer_3 = @"";
        [self initialize_macos_statusbarItem];
        
        //[self resume_listening]; //Disables the internal speech mechanisms cause they suck ass
        
        [self sayIt:@"Orbitus Robot Online"];
        
    }
    return self;
}


- (void) initialize_macos_statusbarItem
{
    self.statusBarItem.title = @"Cerebro";
    NSMenu *menu = [NSMenu new];
    
    
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Resume Listening" action:@selector(resume_listening) keyEquivalent:@"r"]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Resume Listening" action:@selector(resume_listening) keyEquivalent:@"r"]];
    
    self.statusBarItem.menu = menu;
}


- (void) resume_listening
{
    [[NSApplication sharedApplication] becomeFirstResponder];
    
    self.speechRecognizer.delegate = self;
    self.speechRecognizer.displayedCommandsTitle = @"Bot";
    self.speechRecognizer.commands = self.commands;
    self.speechRecognizer.listensInForegroundOnly = false;
    self.speechRecognizer.blocksOtherRecognizers  = false; //test this to see what happens!!
    [self.speechRecognizer startListening];
    NSLog(@"Listening");
}


- (void) stop_listening
{
    [self.speechRecognizer stopListening];
    [[NSApplication sharedApplication] resignFirstResponder];
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


- (void) inputText:(NSString *)inputText
{
    printf(".");
    if (!self.isProcessingSpeech)
    {
        //NSLog(@"Did hear some spoken text - %@", inputText);

        self.isProcessingSpeech = true;
        
        //int pid = [[NSProcessInfo processInfo] processIdentifier];
        NSPipe *pipe = [NSPipe pipe];
        NSFileHandle *file = pipe.fileHandleForReading;
        
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/python";
        //task.launchPath = @"/usr/local/bin/python";
        //task.launchPath = @"/Users/rob/anaconda3/bin/python";
        
        
        //Emotions: 'anger', 'joy', 'neutral', 'sadness', 'fear'
        // anger - really fun
        // joy - i love you's
        // neutral - boring
        // sadness - im bored
        // fear - im scared
        if (![self.previousInputText_1 isEqualToString:@""] && ![self.previousInputText_2 isEqualToString:@""] && ![self.previousInputText_3 isEqualToString:@""] )
        {
            //Level 3 conversation
            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-e", self.emotion, @"-f", @"localhost", @"-p", @"8080",
                               @"-c", self.previousInputText_3, @"-c", self.previousInputAnswer_3,
                               @"-c", self.previousInputText_2, @"-c", self.previousInputAnswer_2,
                               @"-c", self.previousInputText_1, @"-c", self.previousInputAnswer_1,
                               @"-c", inputText];
        }
        else if (![self.previousInputText_1 isEqualToString:@""] && ![self.previousInputText_2 isEqualToString:@""] && [self.previousInputText_3 isEqualToString:@""])
        {
            //Level 2 conversation
            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-e", self.emotion, @"-f", @"localhost", @"-p", @"8080",
                               @"-c", self.previousInputText_2, @"-c", self.previousInputAnswer_2,
                               @"-c", self.previousInputText_1, @"-c", self.previousInputAnswer_1,
                               @"-c", inputText];
        }
        else if (![self.previousInputText_1 isEqualToString:@""] && [self.previousInputText_2 isEqualToString:@""] && [self.previousInputText_3 isEqualToString:@""])
        {
            //Level 1 conversation
            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-e", self.emotion, @"-f", @"localhost", @"-p", @"8080", @"-c", self.previousInputText_1, @"-c", self.previousInputAnswer_1, @"-c", inputText];
        }
        else
        {
            task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-f", @"localhost", @"-p", @"8080", @"-c", inputText];
        }
        
        task.standardOutput = pipe;
        
        [task launch];
        
        NSData *data = [file readDataToEndOfFile];
        [file closeFile];
        
        NSString *chatbot_response = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
        
        //NSLog (@"chatbot:%@", chatbot_response);
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"{u'response': u'" withString:@""];
        
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"u'response': u\"" withString:@""];
        
        
        chatbot_response = [chatbot_response substringToIndex:chatbot_response.length-3];
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"[" withString:@""];
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"]" withString:@""];
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"(" withString:@""];
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@")" withString:@""];
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"{" withString:@""];
        chatbot_response = [chatbot_response stringByReplacingOccurrencesOfString:@"}" withString:@""];
        //NSLog (@"chatbot:%@", chatbot_response);
        
        //--
        [self sayIt:chatbot_response];
        
        //3<-2
        self.previousInputAnswer_3 = self.previousInputAnswer_2;
        self.previousInputText_3 = self.previousInputText_2;
        //2<-1
        self.previousInputAnswer_2 = self.previousInputAnswer_1;
        self.previousInputText_2 = self.previousInputText_1;
        //1<-0
        self.previousInputAnswer_1 = chatbot_response;
        self.previousInputText_1 = inputText;
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
    dispatch_async(dispatch_get_main_queue(), ^(){
        // Is the string zero-length?
        if ([stringToSpeak length] == 0) {
            NSLog(@"string is of zero-length");
            return;
        }
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
    //NSLog(@"didFinishSpeaking");
    self.isProcessingSpeech = false;
    [self.delegate didFinishProcessingSpeech];
}


- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender willSpeakWord:(NSRange)characterRange ofString:(NSString *)string
{
    self.isProcessingSpeech = true;
    [self.delegate willStartProcessingSpeech];
    //NSLog(@"willSpeakWord");
}


- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender willSpeakPhoneme:(short)phonemeOpcode
{
    //NSLog(@"willSpeakPhoneme");
}


- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didEncounterErrorAtIndex:(NSUInteger)characterIndex ofString:(NSString *)string message:(NSString *)message
{
    self.isProcessingSpeech = false;

}

@end
