//
//  TasksController.m
//  Cerebro
//
//  Created by Rob Makina on 5/22/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "ReSpeakerTaskController.h"
#import "ROBMainViewController.h"
#import "ROBPythonRuntime.h"
#import "ROBTaskLaunchGuard.h"


@interface ReSpeakerTaskController ()
{
    
}

@property (readwrite, retain) NSPipe *outputPipe;
@property (readwrite, retain) NSPipe *inputPipe;
@property (readwrite, retain) NSPipe *errorPipe;
@property (readwrite, retain) NSTask *task;
@property (readwrite, assign) bool shouldRelaunch;


@end

@implementation ReSpeakerTaskController


- (IBAction) startTask:(id)sender
{
    self.shouldRelaunch = true;
    dispatch_queue_t aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);

    dispatch_async(aQueue, ^{
        
        NSString *scriptPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"ROBReSpeakerScriptPath"];
        scriptPath = [scriptPath stringByExpandingTildeInPath];
        if (scriptPath.length == 0 || ![[NSFileManager defaultManager] isReadableFileAtPath:scriptPath]) {
            NSLog(@"ReSpeaker Python script is not configured; set ROBReSpeakerScriptPath before enabling this legacy task.");
            self.shouldRelaunch = false;
            return;
        }

        NSError *taskError = nil;
        self.task = [[ROBPythonRuntime sharedRuntime] newTaskWithArguments:@[scriptPath]
                                                                    error:&taskError];
        if (self.task == nil) {
            NSLog(@"ReSpeaker Python task could not be configured: %@", taskError.localizedDescription);
            self.shouldRelaunch = false;
            return;
        }

        __weak ReSpeakerTaskController *weakSelf = self;

        self.task.terminationHandler = ^(NSTask *task){
            dispatch_async(dispatch_get_main_queue(), ^(){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakSelf.shouldRelaunch)
                        [weakSelf startTask:nil];
                });
            });
        };
        
        
        [self captureStandardOutputAndRouteToTextView:self.task];

        
        if (!ROBLaunchTaskSafely(self.task, &taskError)) {
            NSLog(@"ReSpeaker Python task could not launch: %@", taskError.localizedDescription);
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
    self.errorPipe = [NSPipe new];
    
    self.task.standardOutput = self.outputPipe;
    self.task.standardInput = self.inputPipe;
    self.task.standardError = self.errorPipe;
    
    [self.outputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    [self.errorPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    
    //StandardOutput Textview update
    [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleDataAvailableNotification object:self.outputPipe.fileHandleForReading queue:nil usingBlock:^(NSNotification *note){
        NSData *output = self.outputPipe.fileHandleForReading.availableData;
        NSString *outputString = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];

        dispatch_async(dispatch_get_main_queue(), ^(){
            NSString *previousOutput = self.textView.string;
            NSString *nextOutput = [previousOutput stringByAppendingString:outputString];
            self.textView.string = nextOutput;
            NSRange range = NSMakeRange([nextOutput length], 0);
            [self.textView scrollRangeToVisible:range];
        });
    }];
}

@end
