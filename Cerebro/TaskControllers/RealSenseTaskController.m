//
//  TasksController.m
//  Cerebro
//
//  Created by Rob Makina on 5/22/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "RealSenseTaskController.h"
#import "ROBMainViewController.h"


@interface RealSenseTaskController ()
{
    
}

@property (readwrite, retain) NSPipe *outputPipe;
@property (readwrite, retain) NSPipe *inputPipe;
@property (readwrite, retain) NSPipe *errorPipe;
@property (readwrite, retain) NSTask *task;
@property (readwrite, assign) bool shouldRelaunch;


@end

@implementation RealSenseTaskController


- (IBAction) startTask:(id)sender
{
    self.shouldRelaunch = true;
    //self.textView.string = @"";
    
    dispatch_queue_t aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);

    dispatch_async(aQueue, ^{
        
        NSString *path = [[NSBundle mainBundle] pathForResource:@"RealSenseTaskController" ofType:@"command"];
        self.task = [NSTask new];
        self.task.launchPath = path;
        //self.task.arguments = @[@""];

        __weak RealSenseTaskController *weakSelf = self;

        self.task.terminationHandler = ^(NSTask *task){
            dispatch_async(dispatch_get_main_queue(), ^(){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakSelf.shouldRelaunch)
                        [weakSelf startTask:nil];
                });
            });
        };
        
        
        [self captureStandardOutputAndRouteToTextView:self.task];

        
        [self.task launch];
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
        
        //TODO: capture the robot position here!
        NSLog(@"outputString = %@", outputString);
          
        /* //ONLY PROCESS TEXT IF YOU ARE WATCHING AS A HUMAN
        dispatch_async(dispatch_get_main_queue(), ^(){
            self.textView.string = outputString;
            NSString *previousOutput = self.textView.string;
            NSString *nextOutput = [previousOutput stringByAppendingString:outputString];
            self.textView.string = nextOutput;
            NSRange range = NSMakeRange([nextOutput length], 0);
            [self.textView scrollRangeToVisible:range];
        });
        //Not sure if this is necessary but it was crashing*/
        [self.outputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
        
    }];
    
    //StandardError Textview update
    [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleDataAvailableNotification object:self.errorPipe.fileHandleForReading queue:nil usingBlock:^(NSNotification *note){
        NSData *output = self.errorPipe.fileHandleForReading.availableData;
        NSString *outputString = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        
        //NSLog(@"errorString = %@", outputString);
        
        dispatch_async(dispatch_get_main_queue(), ^(){
            NSString *previousOutput = self.textView.string;
            NSString *nextOutput = [[previousOutput stringByAppendingString:@"\n"] stringByAppendingString:outputString];
            self.textView.string = nextOutput;
            NSRange range = NSMakeRange([nextOutput length], 0);
            [self.textView scrollRangeToVisible:range];
        });
        //Not sure if this is necessary but it was crashing
        //[self.outputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    }];
}

@end
