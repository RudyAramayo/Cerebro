//
//  TasksController.h
//  Cerebro
//
//  Created by Rob Makina on 5/22/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>


@class ROBMainViewController;

@interface AudioInputTaskController : NSObject

@property (readwrite, assign) BOOL isListening;
@property (readwrite, assign) NSTextView *transcriptTextView;
@property (readwrite, assign) NSTextView *textView;
@property (readwrite, retain) ROBMainViewController *delegate;
- (void) resetTranscript;
//- (IBAction) startTask:(id)sender withLanguage:(NSString *)language;
- (void) queryTextInput:(NSString *)queryTextInput;
- (void) shutdownTask;
- (void) startListeningAgain;
- (void) beginToIgnore;


@end
