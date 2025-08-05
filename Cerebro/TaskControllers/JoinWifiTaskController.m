//
//  TasksController.m
//  Cerebro
//
//  Created by Rob Makina on 5/22/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "JoinWifiTaskController.h"
#import "ROBMainViewController.h"


@interface JoinWifiTaskController ()
{
    
}

@property (readwrite, retain) NSPipe *outputPipe;
@property (readwrite, retain) NSTask *task;

@end

@implementation JoinWifiTaskController


- (IBAction) startTask:(id)sender
            withDevice:(NSString *)networkDevice
                  ssid:(NSString *)ssid
              password:(NSString *)password
{
    self.isListening = YES;
    
    dispatch_async(dispatch_get_main_queue(), ^(){
        self.textView.string = @"";
    });
    
    dispatch_queue_t aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);

    dispatch_async(aQueue, ^{
        
        NSString *path = [[NSBundle mainBundle] pathForResource:@"JoinWifiTaskController" ofType:@"command"];
        self.task = [NSTask new];
        self.task.launchPath = path;
        self.task.arguments = @[networkDevice, ssid, password];

        __weak JoinWifiTaskController *weakSelf = self;

        self.task.terminationHandler = ^(NSTask *task){
            dispatch_async(dispatch_get_main_queue(), ^(){
                NSLog(@"************* COMPLETED TASK..... SHOULD NOT BE HERE *************");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    weakSelf.isListening = NO;
                    //Unchecking this will make the task loop infinitely
                    //[weakSelf startTask:nil withLanguage:weakSelf.language];
                });
            });
        };
        
        
        [self captureStandardOutputAndRouteToTextView:self.task];

        
        [self.task launch];
        [self.task waitUntilExit];
        
    });
}


- (void) shutdownTask
{
    [self.task terminate];
}

- (void) captureStandardOutputAndRouteToTextView:(NSTask *)task
{
    self.outputPipe = [NSPipe new];
    self.task.standardOutput = self.outputPipe;
    
    [self.outputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleDataAvailableNotification object:self.outputPipe.fileHandleForReading queue:nil usingBlock:^(NSNotification *note){
        NSData *textInputData = self.outputPipe.fileHandleForReading.availableData;
        NSString *textInput = [[NSString alloc] initWithData:textInputData encoding:NSUTF8StringEncoding];
        
        NSLog(@"JoinWifi: %@", textInput);
    }];
}

@end
