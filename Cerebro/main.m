//
//  main.m
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/file.h>
#import <unistd.h>

static int ROBCerebroInstanceLock = -1;

static BOOL ROBAcquireCerebroInstanceLock(void) {
    NSString *lockName = [NSString stringWithFormat:@"com.orbitusrobotics.Cerebro.%u.lock", getuid()];
    NSString *lockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:lockName];
    ROBCerebroInstanceLock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (ROBCerebroInstanceLock < 0) {
        NSLog(@"Cerebro could not open its singleton lock at %@: %s", lockPath, strerror(errno));
        return NO;
    }

    if (flock(ROBCerebroInstanceLock, LOCK_EX | LOCK_NB) == 0) {
        return YES;
    }

    close(ROBCerebroInstanceLock);
    ROBCerebroInstanceLock = -1;
    for (NSRunningApplication *application in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.orbitusrobotics.Cerebro"]) {
        if (!application.isTerminated && application.processIdentifier != getpid()) {
            [application activateWithOptions:NSApplicationActivateAllWindows];
            break;
        }
    }
    return NO;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (!ROBAcquireCerebroInstanceLock()) {
            NSLog(@"Another Cerebro process owns the singleton lock; exiting before AppKit startup");
            return 0;
        }
    }
    return NSApplicationMain(argc, argv);
}
