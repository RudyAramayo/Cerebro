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

@class ROBMainViewController;

@interface ROBSpeechBox : NSObject <NSSpeechRecognizerDelegate>
{
    
}
@property (readwrite, retain) ROBMainViewController *delegate;

@property (readwrite, retain) NSString *emotion;
@property (readwrite, retain) NSMutableArray *commands;
@property (readwrite, retain) NSString *previousInputText_1;
@property (readwrite, retain) NSString *previousInputAnswer_1;
@property (readwrite, retain) NSString *previousInputText_2;
@property (readwrite, retain) NSString *previousInputAnswer_2;
@property (readwrite, retain) NSString *previousInputText_3;
@property (readwrite, retain) NSString *previousInputAnswer_3;

- (void) inputText:(NSString *)inputText;
- (void) didSeeNewPerson:(NSString *)userID;
- (void) lostSightOfPerson:(NSString*)userID;
- (void) sayIt:(NSString *)stringToSpeak;
- (void) setOutputLanguage:(NSString *)language;

- (void) switchMood_anger;
- (void) switchMood_joy;
- (void) switchMood_neutral;
- (void) switchMood_sadness;
- (void) switchMood_fear;

@end
