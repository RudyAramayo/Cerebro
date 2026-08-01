//
//  ROBTaskLaunchGuard.h
//  Cerebro
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ROBTaskLaunchGuardErrorCode) {
    ROBTaskLaunchGuardErrorExecutableUnavailable = 1,
    ROBTaskLaunchGuardErrorLaunchException,
};

/// Confirms that the task has an absolute executable URL whose target currently
/// exists, is not a directory, and is executable. This check is intentionally
/// repeated immediately before launch so a missing optional dependency is a
/// recoverable error rather than an NSTask exception.
static inline BOOL ROBTaskExecutableIsAccessible(NSTask *task, NSError **error)
{
    NSString *path = [[task.executableURL.path stringByExpandingTildeInPath]
        stringByStandardizingPath];
    BOOL isDirectory = NO;
    BOOL accessible = path.length > 0 && path.isAbsolutePath &&
        [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] &&
        !isDirectory && [[NSFileManager defaultManager] isExecutableFileAtPath:path];
    if (accessible) {
        return YES;
    }

    if (error != NULL) {
        NSString *displayPath = path.length > 0 ? path : @"(not configured)";
        *error = [NSError errorWithDomain:@"com.orbitusrobotics.Cerebro.TaskLaunch"
                                     code:ROBTaskLaunchGuardErrorExecutableUnavailable
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Launch executable is not accessible: %@", displayPath],
            NSLocalizedRecoverySuggestionErrorKey:
                @"Install the dependency or choose an accessible executable in Cerebro Settings.",
            NSFilePathErrorKey: displayPath
        }];
    }
    return NO;
}

/// Performs the accessibility preflight and uses the non-throwing NSTask API.
/// The exception boundary is a final defense for invalid legacy task state;
/// callers always receive NO plus an NSError instead of terminating Cerebro.
static inline BOOL ROBLaunchTaskSafely(NSTask *task, NSError **error)
{
    if (!ROBTaskExecutableIsAccessible(task, error)) {
        return NO;
    }

    @try {
        return [task launchAndReturnError:error];
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"com.orbitusrobotics.Cerebro.TaskLaunch"
                                         code:ROBTaskLaunchGuardErrorLaunchException
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"The task could not launch safely: %@",
                                               exception.reason ?: exception.name],
                NSLocalizedRecoverySuggestionErrorKey:
                    @"Verify the dependency path and retry."
            }];
        }
        return NO;
    }
}

NS_ASSUME_NONNULL_END
