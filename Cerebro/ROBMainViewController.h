//
//  GameViewController.h
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <SceneKit/SceneKit.h>

@class ROBSerialBox;
@class ROBSpeechBox;

@interface ROBMainViewController : NSViewController
{
    
}
@property (readwrite, retain) IBOutlet NSImageView *cameraImageView;
@property (readwrite, assign) IBOutlet NSTextView *speechTextView;
@property (readwrite, assign) IBOutlet NSTextView *speechTranscriptTextView;
@property (readwrite, retain) ROBSerialBox *serialBox;
@property (readwrite, retain) ROBSpeechBox *speechBox;
- (IBAction)showControls:(id)sender;
- (IBAction)showSerialDebug:(id)sender;
- (IBAction)showMainNavigation:(id)sender;

- (IBAction) joinSupaRobonet_WIFI:(id)sender;
- (IBAction) joinATT9m78y5D:(id)sender;
- (IBAction) maestro_getErrors_command:(id)sender;

//Speech
- (void) makeTextViewFirstResponder:(NSTextView *)textView;
- (void) clearInputTextMessage;
- (void) inputText:(NSString *)textInput;
- (void) didRespond: (NSString *) responseText;
//Tracking
- (void) didSeeNewPerson:(NSString *)userID;
- (void) lostSightOfPerson:(NSString*)userID;
- (void) trackingPerson:(NSString *)userID position:(NSString *)position;
- (void) leashHandPosition:(SCNVector3)position;

- (void) shutdownAudioInput;
- (void) didFinishProcessingSpeech;
- (void) willStartProcessingSpeech;
- (void) didOutputSerialResponse_Head:(NSString *)response;
- (void) didOutputSerialResponse_Torso:(NSString *)response;
- (void) didOutputSerialResponse_Base:(NSString *)response;
- (void) didOutputSerialResponse_Maestro:(NSString *)response;


@end
