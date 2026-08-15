//
//  SpeechBox.h
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

@protocol ROBSpeechDelegate <NSObject>

- (void)willStartProcessingSpeech;
- (void)didFinishProcessingSpeech;
- (void)inputText:(NSString *)textInput;
- (void)willSpeakWord:(NSRange)characterRange ofString:(NSString *)string;

@optional
- (void)didCaptureAudioBuffer:(AVAudioPCMBuffer *)buffer;

@end

@interface ROBSpeechBox : NSObject <NSSpeechRecognizerDelegate>
{
    
}
@property (nonatomic, weak) id<ROBSpeechDelegate> delegate;
@property (atomic, assign) BOOL isSpeaking;

@property (readwrite, retain) NSString *emotion;
@property (readwrite, retain) NSMutableArray *commands;
@property (readwrite, retain) NSString *previousInputText_1;
@property (readwrite, retain) NSString *previousInputAnswer_1;
@property (readwrite, retain) NSString *previousInputText_2;
@property (readwrite, retain) NSString *previousInputAnswer_2;
@property (readwrite, retain) NSString *previousInputText_3;
@property (readwrite, retain) NSString *previousInputAnswer_3;

- (void) didSeeNewPerson:(NSString *)userID;
- (void) lostSightOfPerson:(NSString*)userID;
- (void) sayIt:(NSString *)stringToSpeak;
- (void)sayIt:(NSString *)stringToSpeak completion:(void (^ _Nullable)(BOOL finished))completion;
- (void) stopIt:(id)sender;
- (void) setOutputLanguage:(NSString *)language;
- (void) startRecognizer;
- (void) shutdown;

- (void) switchMood_anger;
- (void) switchMood_joy;
- (void) switchMood_neutral;
- (void) switchMood_sadness;
- (void) switchMood_fear;

@end
