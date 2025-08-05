//
//  ReSpeakerTaskController.h
//  Cerebro
//
//  Created by Rob Makina on 5/22/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>


@class ROBMainViewController;

@interface ReSpeakerTaskController : NSObject

@property (readwrite, retain) NSTextView *textView;
@property (readwrite, retain) ROBMainViewController *delegate;
- (IBAction) startTask:(id)sender;
- (void) quitTheTask;


@end
