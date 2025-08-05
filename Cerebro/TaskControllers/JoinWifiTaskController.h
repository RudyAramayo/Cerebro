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

@interface JoinWifiTaskController : NSObject

@property (readwrite, assign) BOOL isListening;
@property (readwrite, retain) NSTextView *textView;
@property (readwrite, retain) ROBMainViewController *delegate;

- (IBAction) startTask:(id)sender
            withDevice:(NSString *)networkDevice
                  ssid:(NSString *)ssid
              password:(NSString *)password;

- (void) shutdownTask;


@end
