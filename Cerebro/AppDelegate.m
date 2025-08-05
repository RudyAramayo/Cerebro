//
//  AppDelegate.m
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "AppDelegate.h"

@interface AppDelegate ()
@property (readwrite, retain) NSTimer *rplidarCheckTimer;
@end

@implementation AppDelegate

// How to set ROB's wake/sleep schedule:
//   sudo pmset repeat shutdown MTWRFSU 23:50:00 wakeorpoweron MTWRFSU 07:00:00

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    [self cerebroCheck];
    
    //Give RPLidar 10 seconds to warm up as the macmini is booting quite fast
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self rpLidarCheck];
    });
    
}

- (void) cerebroCheck {
    //ps aux | grep Cerebro
    //system("ps aux | grep Cerebro");
    NSTask *cerebroIsRunning = [NSTask new];
    cerebroIsRunning.launchPath = @"/bin/ps";
    cerebroIsRunning.arguments = @[@"aux"]; // | grep Cerebro
    
    NSPipe *pipe = [NSPipe pipe];
    cerebroIsRunning.standardOutput = pipe;
    
    [cerebroIsRunning launch];
    //[cerebroIsRunning waitUntilExit];
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if ([output componentsSeparatedByString:@"Cerebro.app"].count > 2) { //If we have a count greater than 2 then we have multiple instances of Cerebro.app running
        NSLog(@"Cerebro is already running! Exiting");
        exit(1);
    }
    
    //NSLog(@"Cerebro check passsed...");
}
- (void) rpLidarCheck {
    
    self.rplidarCheckTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        //open RPLidar only after 10 seconds to let it start up
        // /usr/bin/open /Users/rob/Library/Developer/Xcode/DerivedData/RPLidar-fziuydzdocbagjfcyicbboaqukse/Build/Products/Debug-iphoneos/.XCInstall/RPLidar.app

        NSTask *rpLidarIsRunning = [NSTask new];
        rpLidarIsRunning.launchPath = @"/bin/ps";
        rpLidarIsRunning.arguments = @[@"aux"];
        
        NSPipe *pipe = [NSPipe pipe];
        rpLidarIsRunning.standardOutput = pipe;
        
        [rpLidarIsRunning launch];
        
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                
        if ([output componentsSeparatedByString:@"RPLidar.app"].count < 2) { //If we have a count of 2 then 1 RPLidar instance is running
            NSLog(@"Launching RPLidar...");
            
            NSTask *launchRPLidar = [NSTask new];
            launchRPLidar.launchPath = @"/usr/bin/open";
            launchRPLidar.arguments = @[@"/Users/rob/Library/Developer/Xcode/DerivedData/RPLidar-fziuydzdocbagjfcyicbboaqukse/Build/Products/Debug-iphoneos/.XCInstall/RPLidar.app"];
            [launchRPLidar launch];
        } else {
            //NSLog(@"RPLidar check passsed...");
        }
    }];
}
@end
