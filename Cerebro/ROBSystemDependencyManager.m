//
//  ROBSystemDependencyManager.m
//  Cerebro
//

#import "ROBSystemDependencyManager.h"
#import "ROBTaskLaunchGuard.h"

NSString * const ROBSystemDependenciesDidChangeNotification = @"ROBSystemDependenciesDidChangeNotification";
NSString * const ROBSystemDependencyErrorDomain = @"com.orbitusrobotics.Cerebro.SystemDependencies";
static NSString * const ROBPreferredSystemPackageManagerDefaultsKey = @"ROBPreferredSystemPackageManager";

NSString *ROBSystemPackageManagerDisplayName(ROBSystemPackageManager packageManager)
{
    switch (packageManager) {
        case ROBSystemPackageManagerHomebrew:
            return @"Homebrew";
        case ROBSystemPackageManagerMacPorts:
            return @"MacPorts";
    }
    return @"Unknown package manager";
}

@interface ROBSystemDependencyManager ()
@property (nonatomic, assign, readwrite, getter=isInstallingSSHpass) BOOL installingSSHpass;
@property (nonatomic, assign, readwrite) ROBSystemPackageManager installingPackageManager;
@property (nonatomic, strong, readwrite, nullable) NSError *lastSSHpassError;
@property (nonatomic, copy, nullable) NSString *lastKnownSSHpassPath;
@property (nonatomic, strong) NSMutableArray<ROBSystemDependencyCompletion> *pendingSSHpassCompletions;
@property (nonatomic, strong, nullable) NSTask *sshpassInstallTask;
@property (nonatomic, copy, nullable) NSString *installingExecutablePath;
- (nullable NSString *)firstExecutableFromCandidates:(NSArray<NSString *> *)candidates;
- (nullable NSString *)validatedMacPortsPathAndReturnError:(NSError **)error;
- (NSString *)shellQuotedArgument:(NSString *)argument;
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
        _installingPackageManager = ROBSystemPackageManagerHomebrew;
    }
    return self;
}

- (ROBSystemPackageManager)preferredPackageManager
{
    NSNumber *savedValue = [[NSUserDefaults standardUserDefaults]
        objectForKey:ROBPreferredSystemPackageManagerDefaultsKey];
    if (savedValue != nil) {
        NSInteger rawValue = savedValue.integerValue;
        if (rawValue == ROBSystemPackageManagerHomebrew ||
            rawValue == ROBSystemPackageManagerMacPorts) {
            return (ROBSystemPackageManager)rawValue;
        }
    }

    if (self.macPortsPath.length > 0 && self.homebrewPath.length == 0) {
        return ROBSystemPackageManagerMacPorts;
    }
    return ROBSystemPackageManagerHomebrew;
}

- (void)setPreferredPackageManager:(ROBSystemPackageManager)preferredPackageManager
{
    if (preferredPackageManager != ROBSystemPackageManagerHomebrew &&
        preferredPackageManager != ROBSystemPackageManagerMacPorts) {
        return;
    }
    [[NSUserDefaults standardUserDefaults]
        setInteger:preferredPackageManager
            forKey:ROBPreferredSystemPackageManagerDefaultsKey];
    self.lastSSHpassError = nil;
    self.lastKnownSSHpassPath = self.sshpassPath;
    [self postDependenciesDidChange];
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

- (NSString *)macPortsPath
{
    return [self validatedMacPortsPathAndReturnError:NULL];
}

- (NSError *)macPortsValidationError
{
    NSError *error = nil;
    [self validatedMacPortsPathAndReturnError:&error];
    return error;
}

- (NSString *)validatedMacPortsPathAndReturnError:(NSError **)error
{
    NSString *portPath = @"/opt/local/bin/port";
    if (![[NSFileManager defaultManager] fileExistsAtPath:portPath]) {
        return nil;
    }

    NSArray<NSDictionary<NSString *, id> *> *checks = @[
        @{@"path": @"/opt", @"type": NSFileTypeDirectory},
        @{@"path": @"/opt/local", @"type": NSFileTypeDirectory},
        @{@"path": @"/opt/local/bin", @"type": NSFileTypeDirectory},
        @{@"path": portPath, @"type": NSFileTypeRegular}
    ];
    for (NSDictionary<NSString *, id> *check in checks) {
        NSString *path = check[@"path"];
        NSError *attributesError = nil;
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                             error:&attributesError];
        NSNumber *ownerID = attributes[NSFileOwnerAccountID];
        NSNumber *permissions = attributes[NSFilePosixPermissions];
        NSString *fileType = attributes[NSFileType];
        BOOL correctType = [fileType isEqualToString:check[@"type"]];
        BOOL rootOwned = ownerID.unsignedIntegerValue == 0;
        BOOL writableByNonOwner = (permissions.unsignedIntegerValue & 0022) != 0;
        if (attributes == nil || !correctType || !rootOwned || writableByNonOwner) {
            NSString *detail = attributesError.localizedDescription ?: [NSString stringWithFormat:
                @"%@ must be root-owned, must not be group/world-writable, and must have the expected file type.", path];
            if (error != NULL) {
                *error = [self errorWithCode:ROBSystemDependencyErrorUntrustedPackageManager
                                 description:@"Cerebro found an unsafe MacPorts installation and will not suggest running it with administrator privileges."
                          recoverySuggestion:@"Repair or reinstall MacPorts from https://www.macports.org/install.php, then return to Cerebro Settings."
                                      output:detail];
            }
            return nil;
        }
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:portPath]) {
        if (error != NULL) {
            *error = [self errorWithCode:ROBSystemDependencyErrorUntrustedPackageManager
                             description:@"The canonical MacPorts executable is not executable."
                      recoverySuggestion:@"Repair or reinstall MacPorts from https://www.macports.org/install.php, then return to Cerebro Settings."
                                  output:portPath];
        }
        return nil;
    }
    return portPath;
}

- (NSString *)pathForPackageManager:(ROBSystemPackageManager)packageManager
{
    switch (packageManager) {
        case ROBSystemPackageManagerHomebrew:
            return self.homebrewPath;
        case ROBSystemPackageManagerMacPorts:
            return self.macPortsPath;
    }
    return nil;
}

- (NSString *)shellQuotedArgument:(NSString *)argument
{
    NSString *escaped = [argument stringByReplacingOccurrencesOfString:@"'"
                                                            withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

- (NSString *)sshpassInstallCommandForPackageManager:(ROBSystemPackageManager)packageManager
{
    NSString *managerPath = [self pathForPackageManager:packageManager];
    if (managerPath.length == 0) {
        return nil;
    }
    return [self sshpassInstallCommandForPackageManager:packageManager
                                         executablePath:managerPath];
}

- (NSString *)sshpassInstallCommandForPackageManager:(ROBSystemPackageManager)packageManager
                                       executablePath:(NSString *)executablePath
{
    if (executablePath.length == 0) {
        return nil;
    }
    NSString *quotedPath = [self shellQuotedArgument:
        [executablePath stringByStandardizingPath]];
    switch (packageManager) {
        case ROBSystemPackageManagerHomebrew:
            return [NSString stringWithFormat:@"%@ install sshpass", quotedPath];
        case ROBSystemPackageManagerMacPorts:
            return [NSString stringWithFormat:@"sudo %@ install sshpass", quotedPath];
    }
    return nil;
}

- (BOOL)requiresExternalAuthorizationForPackageManager:(ROBSystemPackageManager)packageManager
{
    return packageManager == ROBSystemPackageManagerMacPorts;
}

- (NSString *)sshpassPath
{
    NSMutableArray<NSString *> *knownPaths = [NSMutableArray array];
    ROBSystemPackageManager preferred = self.preferredPackageManager;
    NSArray<NSNumber *> *managerOrder = preferred == ROBSystemPackageManagerMacPorts
        ? @[@(ROBSystemPackageManagerMacPorts), @(ROBSystemPackageManagerHomebrew)]
        : @[@(ROBSystemPackageManagerHomebrew), @(ROBSystemPackageManagerMacPorts)];
    for (NSNumber *managerValue in managerOrder) {
        NSString *managerPath = [self pathForPackageManager:(ROBSystemPackageManager)managerValue.integerValue];
        if (managerPath.length == 0) {
            continue;
        }
        NSString *prefix = [[managerPath stringByDeletingLastPathComponent]
                            stringByDeletingLastPathComponent];
        [knownPaths addObject:[[prefix stringByAppendingPathComponent:@"bin"]
                               stringByAppendingPathComponent:@"sshpass"]];
    }
    [knownPaths addObjectsFromArray:@[
        @"/opt/local/bin/sshpass",
        @"/opt/homebrew/bin/sshpass",
        @"/usr/local/bin/sshpass",
        @"/home/linuxbrew/.linuxbrew/bin/sshpass"
    ]];
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

- (void)refreshSSHpassAvailability
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshSSHpassAvailability];
        });
        return;
    }

    NSString *currentPath = self.sshpassPath;
    BOOL changed = (self.lastKnownSSHpassPath == nil) != (currentPath == nil) ||
        (self.lastKnownSSHpassPath != nil &&
         ![self.lastKnownSSHpassPath isEqualToString:currentPath]);
    if (!changed) {
        return;
    }
    self.lastKnownSSHpassPath = currentPath;
    if (currentPath.length > 0) {
        self.lastSSHpassError = nil;
    }
    [self postDependenciesDidChange];
}

- (void)installSSHpassWithPackageManager:(ROBSystemPackageManager)packageManager
                  expectedExecutablePath:(NSString *)expectedExecutablePath
                              completion:(ROBSystemDependencyCompletion)completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self installSSHpassWithPackageManager:packageManager
                            expectedExecutablePath:expectedExecutablePath
                                        completion:completion];
        });
        return;
    }

    if (packageManager != ROBSystemPackageManagerHomebrew &&
        packageManager != ROBSystemPackageManagerMacPorts) {
        NSError *error = [self errorWithCode:ROBSystemDependencyErrorInvalidPackageManager
                                 description:@"Cerebro cannot install sshpass with the selected package manager."
                          recoverySuggestion:@"Choose Homebrew or MacPorts in Cerebro Settings."
                                      output:nil];
        self.lastSSHpassError = error;
        [self postDependenciesDidChange];
        if (completion != nil) {
            completion(NO, @"", error);
        }
        return;
    }

    NSString *expectedPath = [expectedExecutablePath stringByStandardizingPath];
    if (expectedPath.length == 0) {
        NSError *error = [self errorWithCode:ROBSystemDependencyErrorInvalidPackageManager
                                 description:@"The package-manager path confirmed by the operator is missing."
                          recoverySuggestion:@"Return to Cerebro Settings and confirm the installation command again."
                                      output:nil];
        self.lastSSHpassError = error;
        [self postDependenciesDidChange];
        if (completion != nil) {
            completion(NO, @"", error);
        }
        return;
    }

    NSString *installedPath = self.sshpassPath;
    if (installedPath.length > 0) {
        self.lastKnownSSHpassPath = installedPath;
        self.lastSSHpassError = nil;
        if (completion != nil) {
            completion(YES,
                       [NSString stringWithFormat:@"sshpass is ready at %@", installedPath],
                       nil);
        }
        [self postDependenciesDidChange];
        return;
    }

    if (self.isInstallingSSHpass) {
        if (packageManager == self.installingPackageManager &&
            [expectedPath isEqualToString:self.installingExecutablePath]) {
            if (completion != nil) {
                [self.pendingSSHpassCompletions addObject:[completion copy]];
            }
            return;
        }
        NSString *activeName = ROBSystemPackageManagerDisplayName(self.installingPackageManager);
        NSError *error = [self errorWithCode:ROBSystemDependencyErrorInstallInProgress
                                 description:[NSString stringWithFormat:@"Cerebro is already installing sshpass with %@.", activeName]
                          recoverySuggestion:@"Wait for that installation to finish before choosing another package manager."
                                      output:nil];
        if (completion != nil) {
            completion(NO, @"", error);
        }
        return;
    }

    NSString *managerName = ROBSystemPackageManagerDisplayName(packageManager);
    NSString *currentManagerPath = [[self pathForPackageManager:packageManager]
                                    stringByStandardizingPath];
    if (currentManagerPath.length == 0) {
        NSError *validationError = packageManager == ROBSystemPackageManagerMacPorts
            ? self.macPortsValidationError
            : nil;
        ROBSystemDependencyErrorCode errorCode = packageManager == ROBSystemPackageManagerHomebrew
            ? ROBSystemDependencyErrorHomebrewUnavailable
            : ROBSystemDependencyErrorPackageManagerUnavailable;
        NSString *helpURL = packageManager == ROBSystemPackageManagerHomebrew
            ? @"https://brew.sh/"
            : @"https://www.macports.org/install.php";
        NSError *error = validationError ?: [self errorWithCode:errorCode
                                 description:[NSString stringWithFormat:@"Cerebro could not install sshpass because %@ is not installed.", managerName]
                          recoverySuggestion:[NSString stringWithFormat:@"Install %@ from %@, then return to Cerebro Settings and retry.", managerName, helpURL]
                                      output:nil];
        self.lastSSHpassError = error;
        [self postDependenciesDidChange];
        if (completion != nil) {
            completion(NO, @"", error);
        }
        return;
    }

    if (![currentManagerPath isEqualToString:expectedPath]) {
        NSError *error = [self errorWithCode:ROBSystemDependencyErrorInvalidPackageManager
                                 description:[NSString stringWithFormat:@"The %@ executable changed after the operator reviewed the command.", managerName]
                          recoverySuggestion:@"Cerebro did not run anything. Return to Settings and review the updated command before retrying."
                                      output:[NSString stringWithFormat:@"Reviewed: %@\nCurrent: %@", expectedPath, currentManagerPath]];
        self.lastSSHpassError = error;
        [self postDependenciesDidChange];
        if (completion != nil) {
            completion(NO, @"", error);
        }
        return;
    }

    NSString *managerPath = expectedPath;
    if ([self requiresExternalAuthorizationForPackageManager:packageManager]) {
        NSString *command = [self sshpassInstallCommandForPackageManager:packageManager
                                                           executablePath:managerPath] ?: @"sudo port install sshpass";
        NSError *error = [self errorWithCode:ROBSystemDependencyErrorAdministratorAuthorizationRequired
                                 description:@"MacPorts requires administrator authorization to install sshpass."
                          recoverySuggestion:@"Copy the displayed command from Cerebro Settings and run it in Terminal. Cerebro never collects the administrator password."
                                      output:command];
        self.lastSSHpassError = error;
        [self postDependenciesDidChange];
        if (completion != nil) {
            completion(NO, command, error);
        }
        return;
    }

    if (completion != nil) {
        [self.pendingSSHpassCompletions addObject:[completion copy]];
    }
    self.installingSSHpass = YES;
    self.installingPackageManager = packageManager;
    self.installingExecutablePath = managerPath;
    self.lastSSHpassError = nil;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:managerPath];
    task.arguments = @[@"install", @"sshpass"];
    task.environment = [self taskEnvironmentPrependingDirectories:@[
        [managerPath stringByDeletingLastPathComponent]
    ]];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.sshpassInstallTask = task;
    [self postDependenciesDidChange];

    NSMutableData *outputData = [NSMutableData data];
    dispatch_group_t pipeDrainGroup = dispatch_group_create();
    dispatch_group_enter(pipeDrainGroup);
    __block BOOL pipeDrainFinished = NO;
    void (^finishPipeDrain)(void) = ^{
        @synchronized (outputData) {
            if (pipeDrainFinished) {
                return;
            }
            pipeDrainFinished = YES;
            dispatch_group_leave(pipeDrainGroup);
        }
    };
    NSFileHandle *readHandle = pipe.fileHandleForReading;
    readHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length == 0) {
            handle.readabilityHandler = nil;
            finishPipeDrain();
            return;
        }
        @synchronized (outputData) {
            [outputData appendData:chunk];
        }
    };
    task.terminationHandler = ^(NSTask *completedTask) {
        dispatch_group_notify(pipeDrainGroup,
                              dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
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
                                             description:[NSString stringWithFormat:@"%@ could not install sshpass (status %d).", managerName, completedTask.terminationStatus]
                                      recoverySuggestion:[NSString stringWithFormat:@"Review the %@ output, correct the installation problem, and retry.", managerName]
                                                  output:output];
                    [self finishSSHpassInstallationWithSuccess:NO output:output error:error];
                    return;
                }

                NSString *successOutput = output.length > 0
                    ? output
                    : [NSString stringWithFormat:@"sshpass installed at %@", resolvedPath];
                [self finishSSHpassInstallationWithSuccess:YES output:successOutput error:nil];
            });
        });
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *launchError = nil;
        if (!ROBLaunchTaskSafely(task, &launchError)) {
            readHandle.readabilityHandler = nil;
            finishPipeDrain();
            NSError *error = [self errorWithCode:ROBSystemDependencyErrorInstallFailed
                                     description:[NSString stringWithFormat:@"%@ could not start: %@", managerName, launchError.localizedDescription]
                              recoverySuggestion:[NSString stringWithFormat:@"Check the %@ installation and retry from Cerebro Settings.", managerName]
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
    self.installingExecutablePath = nil;
    self.lastKnownSSHpassPath = self.sshpassPath;
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
