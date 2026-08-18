//
//  TasksController.m
//  Cerebro
//
//  Created by Rob Makina on 5/22/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "SimpleUserTrackerTaskController.h"
#import "ROBMainViewController.h"
#import "ROBTaskLaunchGuard.h"


@interface SimpleUserTrackerTaskController ()
{
    
}

@property (readwrite, retain) NSPipe *outputPipe;
@property (readwrite, retain) NSPipe *inputPipe;
@property (readwrite, retain) NSTask *task;
@property (readwrite, assign) bool shouldRelaunch;


@end

@implementation SimpleUserTrackerTaskController


- (IBAction) startTask:(id)sender
{
    self.shouldRelaunch = true;
    self.textView.string = @"";
    
    dispatch_queue_t aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);

    dispatch_async(aQueue, ^{
        
        NSString *path = [[NSBundle mainBundle] pathForResource:@"SimpleUserTracker" ofType:@"command"];
        self.task = [NSTask new];
        if (path.length > 0) {
            self.task.executableURL = [NSURL fileURLWithPath:path];
        }

        __weak SimpleUserTrackerTaskController *weakSelf = self;

        self.task.terminationHandler = ^(NSTask *task){
            dispatch_async(dispatch_get_main_queue(), ^(){
                NSLog(@"************* COMPLETED TASK..... SHOULD NOT BE HERE *************");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakSelf.shouldRelaunch)
                        [weakSelf startTask:nil];
                });
            });
        };
        
        
        [self captureStandardOutputAndRouteToTextView:self.task];

        
        NSError *launchError = nil;
        if (!ROBLaunchTaskSafely(self.task, &launchError)) {
            NSLog(@"SimpleUserTracker task could not launch: %@", launchError.localizedDescription);
            self.shouldRelaunch = false;
            return;
        }
        [self.task waitUntilExit];
        
    });
    
}

- (void) quitTheTask
{
    self.shouldRelaunch = false;
    [self.inputPipe.fileHandleForWriting writeData:[@" " dataUsingEncoding:NSUTF8StringEncoding]];
}


- (void) captureStandardOutputAndRouteToTextView:(NSTask *)task
{
    self.outputPipe = [NSPipe new];
    self.inputPipe = [NSPipe new];
    self.task.standardOutput = self.outputPipe;
    self.task.standardInput = self.inputPipe;
    
    [self.outputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleDataAvailableNotification object:self.outputPipe.fileHandleForReading queue:nil usingBlock:^(NSNotification *note){
        NSData *output = self.outputPipe.fileHandleForReading.availableData;
        NSString *outputString = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];

        dispatch_async(dispatch_get_main_queue(), ^(){
            NSString *previousOutput = self.textView.string;
            NSString *nextOutput = [[previousOutput stringByAppendingString:@"\n"] stringByAppendingString:outputString];
            self.textView.string = nextOutput;
            NSRange range = NSMakeRange([nextOutput length], 0);
            [self.textView scrollRangeToVisible:range];
        });
        
        [self.outputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    }];
}

@end
