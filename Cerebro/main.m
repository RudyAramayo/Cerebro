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
#import <spawn.h>
#import <string.h>
#import <sys/file.h>
#import <sys/wait.h>
#import <unistd.h>

static int ROBCerebroInstanceLock = -1;
extern char **environ;

static void ROBPrepareForXcodeDebugging(void) {
    NSString *domainTarget = [NSString stringWithFormat:@"gui/%u/com.orbitusrobotics.Cerebro.keepalive", getuid()];
    const char *arguments[] = { "/bin/launchctl", "bootout", domainTarget.UTF8String, NULL };
    pid_t launchctlProcess = 0;
    if (posix_spawn(&launchctlProcess, arguments[0], NULL, NULL, (char *const *)arguments, environ) == 0) {
        waitpid(launchctlProcess, NULL, 0);
    }

    for (NSRunningApplication *application in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.orbitusrobotics.Cerebro"]) {
        if ([application.bundleURL.path isEqualToString:@"/Applications/Cerebro.app"] &&
            application.processIdentifier != getpid()) {
            [application terminate];
        }
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (deadline.timeIntervalSinceNow > 0) {
        BOOL productionIsRunning = NO;
        for (NSRunningApplication *application in
             [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.orbitusrobotics.Cerebro"]) {
            productionIsRunning |= [application.bundleURL.path isEqualToString:@"/Applications/Cerebro.app"] &&
                                   !application.isTerminated;
        }
        if (!productionIsRunning) break;
        [NSThread sleepForTimeInterval:0.05];
    }
}

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
        if ([NSProcessInfo.processInfo.environment[@"CEREBRO_XCODE_DEBUG_SESSION"] boolValue]) {
            ROBPrepareForXcodeDebugging();
        }
        if (!ROBAcquireCerebroInstanceLock()) {
            NSLog(@"Another Cerebro process owns the singleton lock; exiting before AppKit startup");
            return 0;
        }
    }
    return NSApplicationMain(argc, argv);
}
