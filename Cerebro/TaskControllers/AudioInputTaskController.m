//
//  TasksController.m
//  Cerebro
//
//  Created by Rob Makina on 5/22/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "AudioInputTaskController.h"
#import "ROBMainViewController.h"


@interface AudioInputTaskController ()
{
    
}

@property (readwrite, retain) NSPipe *outputPipe;
@property (readwrite, retain) NSTask *task;

@property (readwrite, retain) NSString *currentIncommingVerbalMessage;
@property (readwrite, retain) NSTimer *verbalInputTimer;

@property (readwrite, assign) bool ignoreText;
@property (readwrite, assign) bool alreadyProcessing;
@property (readwrite, retain) NSString *language;

@end

@implementation AudioInputTaskController

- (void) resetTranscript {
    
}

//Robot has recieved text either from textField and hence the a nearby user from onboard mic, or from the input controller
- (void) queryTextInput:(NSString *)queryTextInput {
    self.isListening = YES;
    self.ignoreText = NO;
    //dispatch_async(dispatch_get_main_queue(), ^(){
    //    self.textView.string = @"";
    //});
    __block NSString *queryInput = [queryTextInput copy];
    dispatch_queue_t aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);

    dispatch_async(aQueue, ^{
        
        ///------- DUPLICATED BLOCK IN ROBSerialBox.m ---------
        if (![self.currentIncommingVerbalMessage isEqualToString:queryInput])
        {
            
            if (![queryInput isEqualToString:@""] && !self.alreadyProcessing)
            {
                self.alreadyProcessing = YES;
                dispatch_async(dispatch_get_main_queue(), ^(){
                    self.textView.editable = NO;
                });

                //Disable the textField and it won't recieve any audio
                //[self.delegate shutdownAudioInput];
                //[self.delegate inputText:queryInput];
                //[self.delegate clearInputTextMessage];
                self.currentIncommingVerbalMessage = queryInput;
                
                
                NSString *path = @"/usr/local/bin/python3";
                self.task = [NSTask new];
                self.task.launchPath = path;
                //self.task.arguments = @[@"/Users/rob/dev/openai_test.py", [NSString stringWithFormat:@"\"%@\"", self.currentIncommingVerbalMessage]];
                self.task.arguments = @[@"/Users/rob/Library/Mobile\ Documents/com~apple~CloudDocs/dev/google_ai_test.py", [NSString stringWithFormat:@"\"%@\"", self.currentIncommingVerbalMessage]];
                
                __weak AudioInputTaskController *weakSelf = self;
                
                self.task.terminationHandler = ^(NSTask *task){
                    dispatch_async(dispatch_get_main_queue(), ^(){
                        NSLog(@"************* COMPLETED TASK *************");
                        self.alreadyProcessing = NO;
                        self.textView.string = @"";
                    });
                };
                
                
                [self captureStandardOutputAndRouteToTextView:self.task];
                
                [self.task launch];
                [self.task waitUntilExit];
            }
            
        }
        //-----------------------------------------------------
        
        
    });
}

- (void) startListeningAgain
{
    self.ignoreText = NO;
}


- (void) beginToIgnore
{
    self.ignoreText = YES;
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
        
        if (![textInput isEqualToString:@""]) {
            NSLog(@"didHear = %@", textInput);
            [self.delegate didRespond:textInput];
            
            [self updateTranscriptWithText:textInput];
            
            [self.outputPipe.fileHandleForReading waitForDataInBackgroundAndNotify];
            //dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                //self.textView.editable = YES;
                //self.textView.string = @"";
                //[self.delegate makeTextViewFirstResponder:self.textView];
                //[self.textView becomeFirstResponder];
            //});
            
        }
        
    }];
}

- (void) updateTranscriptWithText:(NSString *) textInput {
    dispatch_async(dispatch_get_main_queue(), ^(){
        NSString *previousOutput = self.transcriptTextView.string;
        NSString *nextOutput = [[previousOutput stringByAppendingString:@"\n"] stringByAppendingString:textInput];
        self.transcriptTextView.string = nextOutput;
        NSRange range = NSMakeRange([nextOutput length], 0);
        [self.transcriptTextView scrollRangeToVisible:range];
    });
}

@end
