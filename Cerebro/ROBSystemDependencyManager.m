//
//  ROBSystemDependencyManager.m
//  Cerebro
//

#import "ROBSystemDependencyManager.h"
#import "ROBTaskLaunchGuard.h"

NSString * const ROBSystemDependenciesDidChangeNotification = @"ROBSystemDependenciesDidChangeNotification";
NSString * const ROBSystemDependencyErrorDomain = @"com.orbitusrobotics.Cerebro.SystemDependencies";

@interface ROBSystemDependencyManager ()
@property (nonatomic, assign, readwrite, getter=isInstallingSSHpass) BOOL installingSSHpass;
@property (nonatomic, strong, readwrite, nullable) NSError *lastSSHpassError;
@property (nonatomic, strong) NSMutableArray<ROBSystemDependencyCompletion> *pendingSSHpassCompletions;
@property (nonatomic, strong, nullable) NSTask *sshpassInstallTask;
- (nullable NSString *)firstExecutableFromCandidates:(NSArray<NSString *> *)candidates;
- (NSDictionary<NSString *, NSString *> *)taskEnvironmentPrependingDirectories:(NSArray<NSString *> *)directories;
- (NSError *)errorWithCode:(ROBSystemDependencyErrorCode)code
               description:(NSString *)description
        recoverySuggestion:(nullable NSString *)recoverySuggestion
                    output:(nullable NSString *)output;
- (void)finishSSHpassInstallationWithSuccess:(BOOL)success
                                      output:(NSString *)output
                                       error:(nullable NSError *)error;
@end

@implementation ROBSystemDependencyManager

+ (ROBSystemDependencyManager *)sharedManager
{
    static ROBSystemDependencyManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[ROBSystemDependencyManager alloc] init];
    });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _pendingSSHpassCompletions = [NSMutableArray array];
    }
    return self;
}

- (NSString *)firstExecutableFromCandidates:(NSArray<NSString *> *)candidates
{
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *candidate in candidates) {
        NSString *path = [[candidate stringByExpandingTildeInPath] stringByStandardizingPath];
        if (path.length == 0 || [seen containsObject:path]) {
            continue;
        }
        [seen addObject:path];
        BOOL isDirectory = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
        if (exists && !isDirectory && [[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (NSArray<NSString *> *)pathCandidatesForExecutable:(NSString *)name
                                          knownPaths:(NSArray<NSString *> *)knownPaths
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithArray:knownPaths];
    NSString *inheritedPath = [NSProcessInfo processInfo].environment[@"PATH"];
    for (NSString *directory in [inheritedPath componentsSeparatedByString:@":"]) {
        if (directory.length > 0) {
            [candidates addObject:[directory stringByAppendingPathComponent:name]];
        }
    }
    return candidates;
}

- (NSString *)homebrewPath
{
    return [self firstExecutableFromCandidates:[self pathCandidatesForExecutable:@"brew"
                                                                      knownPaths:@[
        @"/opt/homebrew/bin/brew",
        @"/usr/local/bin/brew",
        @"/home/linuxbrew/.linuxbrew/bin/brew"
    ]]];
}

- (NSString *)sshpassPath
{
    NSMutableArray<NSString *> *knownPaths = [NSMutableArray arrayWithArray:@[
        @"/opt/homebrew/bin/sshpass",
        @"/usr/local/bin/sshpass",
        @"/home/linuxbrew/.linuxbrew/bin/sshpass"
    ]];
    NSString *brewPath = self.homebrewPath;
    if (brewPath.length > 0) {
        NSString *brewPrefix = [[brewPath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        [knownPaths insertObject:[[brewPrefix stringByAppendingPathComponent:@"bin"]
                                  stringByAppendingPathComponent:@"sshpass"]
                       atIndex:0];
    }
    return [self firstExecutableFromCandidates:[self pathCandidatesForExecutable:@"sshpass"
                                                                      knownPaths:knownPaths]];
}

- (NSDictionary<NSString *,NSString *> *)taskEnvironmentPrependingDirectories:(NSArray<NSString *> *)directories
{
    NSMutableDictionary<NSString *, NSString *> *environment =
        [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSMutableArray<NSString *> *pathParts = [NSMutableArray array];
    for (NSString *directory in directories) {
        if (directory.length > 0 && ![pathParts containsObject:directory]) {
            [pathParts addObject:directory];
        }
    }
    NSString *inheritedPath = environment[@"PATH"];
    if (inheritedPath.length > 0) {
        [pathParts addObject:inheritedPath];
    } else {
        [pathParts addObject:@"/usr/bin:/bin:/usr/sbin:/sbin"];
    }
    environment[@"PATH"] = [pathParts componentsJoinedByString:@":"];
    return environment;
}

- (NSError *)errorWithCode:(ROBSystemDependencyErrorCode)code
               description:(NSString *)description
        recoverySuggestion:(NSString *)recoverySuggestion
                    output:(NSString *)output
{
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (recoverySuggestion.length > 0) {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = recoverySuggestion;
    }
    if (output.length > 0) {
        userInfo[@"commandOutput"] = output;
    }
    return [NSError errorWithDomain:ROBSystemDependencyErrorDomain code:code userInfo:userInfo];
}

- (void)postDependenciesDidChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ROBSystemDependenciesDidChangeNotification
                          object:self];
    });
}

- (void)ensureSSHpassInstalledWithCompletion:(ROBSystemDependencyCompletion)completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensureSSHpassInstalledWithCompletion:completion];
        });
        return;
    }

    NSString *installedPath = self.sshpassPath;
    if (installedPath.length > 0) {
        self.lastSSHpassError = nil;
        if (completion != nil) {
            completion(YES,
                       [NSString stringWithFormat:@"sshpass is ready at %@", installedPath],
                       nil);
        }
        [self postDependenciesDidChange];
        return;
    }

    if (completion != nil) {
        [self.pendingSSHpassCompletions addObject:[completion copy]];
    }
    if (self.isInstallingSSHpass) {
        return;
    }

    NSString *brewPath = self.homebrewPath;
    if (brewPath.length == 0) {
        NSError *error = [self errorWithCode:ROBSystemDependencyErrorHomebrewUnavailable
                                 description:@"Cerebro could not install sshpass because Homebrew is not installed."
                          recoverySuggestion:@"Install Homebrew from https://brew.sh, then return to Cerebro Settings and retry."
                                      output:nil];
        [self finishSSHpassInstallationWithSuccess:NO output:@"" error:error];
        return;
    }

    self.installingSSHpass = YES;
    self.lastSSHpassError = nil;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:brewPath];
    task.arguments = @[@"install", @"sshpass"];
    task.environment = [self taskEnvironmentPrependingDirectories:@[
        [brewPath stringByDeletingLastPathComponent]
    ]];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.sshpassInstallTask = task;
    [self postDependenciesDidChange];

    NSMutableData *outputData = [NSMutableData data];
    NSFileHandle *readHandle = pipe.fileHandleForReading;
    readHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length == 0) {
            handle.readabilityHandler = nil;
            return;
        }
        @synchronized (outputData) {
            [outputData appendData:chunk];
        }
    };
    task.terminationHandler = ^(NSTask *completedTask) {
        readHandle.readabilityHandler = nil;
        NSData *capturedOutput = nil;
        @synchronized (outputData) {
            capturedOutput = [outputData copy];
        }
        NSString *output = [[NSString alloc] initWithData:capturedOutput
                                                  encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.sshpassInstallTask != completedTask) {
                return;
            }
            NSString *resolvedPath = self.sshpassPath;
            if (completedTask.terminationStatus != 0 || resolvedPath.length == 0) {
                NSError *error = [self errorWithCode:ROBSystemDependencyErrorInstallFailed
                                         description:[NSString stringWithFormat:@"Homebrew could not install sshpass (status %d).", completedTask.terminationStatus]
                                  recoverySuggestion:@"Review the Homebrew output, correct the installation problem, and retry."
                                              output:output];
                [self finishSSHpassInstallationWithSuccess:NO output:output error:error];
                return;
            }

            NSString *successOutput = output.length > 0
                ? output
                : [NSString stringWithFormat:@"sshpass installed at %@", resolvedPath];
            [self finishSSHpassInstallationWithSuccess:YES output:successOutput error:nil];
        });
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *launchError = nil;
        if (!ROBLaunchTaskSafely(task, &launchError)) {
            readHandle.readabilityHandler = nil;
            NSError *error = [self errorWithCode:ROBSystemDependencyErrorInstallFailed
                                     description:[NSString stringWithFormat:@"Homebrew could not start: %@", launchError.localizedDescription]
                              recoverySuggestion:@"Check the Homebrew installation and retry from Cerebro Settings."
                                          output:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.sshpassInstallTask == task) {
                    [self finishSSHpassInstallationWithSuccess:NO output:@"" error:error];
                }
            });
        }
    });
}

- (void)finishSSHpassInstallationWithSuccess:(BOOL)success
                                      output:(NSString *)output
                                       error:(NSError *)error
{
    NSAssert([NSThread isMainThread], @"Dependency installation state must finish on the main thread");
    self.installingSSHpass = NO;
    self.lastSSHpassError = error;
    self.sshpassInstallTask = nil;
    NSArray<ROBSystemDependencyCompletion> *completions = [self.pendingSSHpassCompletions copy];
    [self.pendingSSHpassCompletions removeAllObjects];
    [self postDependenciesDidChange];
    for (ROBSystemDependencyCompletion completion in completions) {
        completion(success, output ?: @"", error);
    }
}

- (NSTask *)newSSHpassTaskWithSSHArguments:(NSArray<NSString *> *)sshArguments
                                      error:(NSError **)error
{
    NSString *sshpassPath = self.sshpassPath;
    if (sshpassPath.length == 0) {
        NSError *dependencyError = self.lastSSHpassError ?: [self
            errorWithCode:ROBSystemDependencyErrorToolUnavailable
               description:@"sshpass is not installed."
        recoverySuggestion:@"Open Cerebro Settings to install the system dependency."
                    output:nil];
        if (error != NULL) {
            *error = dependencyError;
        }
        return nil;
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/ssh"]) {
        NSError *dependencyError = [self errorWithCode:ROBSystemDependencyErrorToolUnavailable
                                           description:@"The macOS OpenSSH client is unavailable at /usr/bin/ssh."
                                    recoverySuggestion:@"Restore the standard macOS SSH client before using Amber remote controls."
                                                output:nil];
        if (error != NULL) {
            *error = dependencyError;
        }
        return nil;
    }

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:
        @"-d", @"0", @"/usr/bin/ssh",
        @"-o", @"ConnectTimeout=10",
        @"-o", @"ServerAliveInterval=15",
        @"-o", @"ServerAliveCountMax=2",
        nil];
    [arguments addObjectsFromArray:sshArguments];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:sshpassPath];
    task.arguments = arguments;
    task.environment = [self taskEnvironmentPrependingDirectories:@[
        [sshpassPath stringByDeletingLastPathComponent],
        @"/usr/bin",
        @"/bin"
    ]];
    task.standardInput = [NSPipe pipe];
    return task;
}

- (BOOL)launchSSHpassTask:(NSTask *)task
                 password:(NSString *)password
                    error:(NSError **)error
{
    NSError *launchError = nil;
    if (!ROBLaunchTaskSafely(task, &launchError)) {
        NSError *dependencyError = [self errorWithCode:ROBSystemDependencyErrorLaunchFailed
                                           description:[NSString stringWithFormat:@"The Amber SSH task could not start: %@", launchError.localizedDescription]
                                    recoverySuggestion:@"Recheck sshpass in Cerebro Settings."
                                                output:nil];
        if (error != NULL) {
            *error = dependencyError;
        }
        return NO;
    }

    NSPipe *passwordPipe = [task.standardInput isKindOfClass:[NSPipe class]] ? task.standardInput : nil;
    NSError *writeError = nil;
    NSData *passwordData = [[password stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (passwordPipe == nil || ![passwordPipe.fileHandleForWriting writeData:passwordData error:&writeError]) {
        [passwordPipe.fileHandleForWriting closeFile];
        if (task.isRunning) {
            [task terminate];
        }
        NSError *dependencyError = [self errorWithCode:ROBSystemDependencyErrorLaunchFailed
                                           description:[NSString stringWithFormat:@"Cerebro could not provide the Amber SSH credential: %@", writeError.localizedDescription ?: @"password pipe unavailable"]
                                    recoverySuggestion:@"Retry the Amber connection."
                                                output:nil];
        if (error != NULL) {
            *error = dependencyError;
        }
        return NO;
    }
    [passwordPipe.fileHandleForWriting closeFile];
    return YES;
}

@end
