//
//  ROBPythonRuntime.m
//  Cerebro
//

#import "ROBPythonRuntime.h"
#import "ROBTaskLaunchGuard.h"

NSString * const ROBPythonRuntimeDidChangeNotification = @"ROBPythonRuntimeDidChangeNotification";
NSString * const ROBPythonRuntimeConfigurationRequiredNotification = @"ROBPythonRuntimeConfigurationRequiredNotification";
NSString * const ROBPythonRuntimeErrorDomain = @"com.orbitusrobotics.Cerebro.PythonRuntime";

static NSString * const ROBPythonExecutableDefaultsKey = @"ROBPythonExecutablePath";

@interface ROBPythonRuntime ()
- (nullable NSString *)resolvedPythonPathAndReturnError:(NSError **)error;
- (nullable NSString *)autoDetectedPythonPathExcludingManagedEnvironment:(BOOL)excludeManaged;
- (BOOL)isExecutableFileAtPath:(NSString *)path;
- (BOOL)probePython3AtPath:(NSString *)path error:(NSError **)error;
- (NSError *)errorWithCode:(ROBPythonRuntimeErrorCode)code
               description:(NSString *)description
            recoveryReason:(nullable NSString *)recoveryReason;
- (void)postConfigurationRequired:(NSError *)error;
- (NSDictionary<NSString *, NSString *> *)pythonTaskEnvironmentForPythonPath:(NSString *)pythonPath;
- (nullable NSString *)requirementsFilePath;
- (void)postRuntimeDidChange;
@end

@implementation ROBPythonRuntime

+ (ROBPythonRuntime *)sharedRuntime
{
    static ROBPythonRuntime *runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = [[ROBPythonRuntime alloc] init];
    });
    return runtime;
}

- (NSString *)configuredPythonPath
{
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:ROBPythonExecutableDefaultsKey];
    return path.length > 0 ? path : nil;
}

- (NSString *)effectivePythonPath
{
    return [self resolvedPythonPathAndReturnError:nil];
}

- (NSString *)managedEnvironmentDirectory
{
    NSURL *applicationSupportURL = [[[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask] firstObject];
    return [[applicationSupportURL URLByAppendingPathComponent:@"Cerebro/PythonEnvironment"
                                                   isDirectory:YES] path];
}

- (NSArray<NSString *> *)requiredPackages
{
    // amber_api is shipped with the application and added to PYTHONPATH. The
    // webcam service is the only active bundled Python feature with a pip
    // dependency.
    // Keep the fallback identical to PythonRequirements.txt in case the bundle
    // resource is ever omitted from a development build.
    return @[@"depthai==3.8.0"];
}

- (NSError *)errorWithCode:(ROBPythonRuntimeErrorCode)code
               description:(NSString *)description
            recoveryReason:(NSString *)recoveryReason
{
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (recoveryReason.length > 0) {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = recoveryReason;
    }
    return [NSError errorWithDomain:ROBPythonRuntimeErrorDomain code:code userInfo:userInfo];
}

- (BOOL)isExecutableFileAtPath:(NSString *)path
{
    if (path.length == 0 || !path.isAbsolutePath) {
        return NO;
    }
    BOOL isDirectory = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
    return exists && !isDirectory && [[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

- (BOOL)probePython3AtPath:(NSString *)path error:(NSError **)error
{
    if (![self isExecutableFileAtPath:path]) {
        if (error != NULL) {
            *error = [self errorWithCode:ROBPythonRuntimeErrorInvalidInterpreter
                             description:[NSString stringWithFormat:
                                 @"The selected Python launch path is not accessible: %@",
                                 path.length > 0 ? path : @"(not configured)"]
                          recoveryReason:@"Choose an accessible Python 3.9 or newer interpreter in Settings."];
        }
        return NO;
    }

    NSTask *probe = [[NSTask alloc] init];
    probe.executableURL = [NSURL fileURLWithPath:path];
    probe.arguments = @[
        @"-c",
        @"import sys; print('CerebroPython3'); raise SystemExit(0 if sys.version_info >= (3, 9) else 3)"
    ];
    probe.environment = [self pythonTaskEnvironmentForPythonPath:path];
    NSPipe *pipe = [NSPipe pipe];
    probe.standardOutput = pipe;
    probe.standardError = pipe;

    NSError *launchError = nil;
    if (!ROBLaunchTaskSafely(probe, &launchError)) {
        if (error != NULL) {
            *error = [self errorWithCode:ROBPythonRuntimeErrorInvalidInterpreter
                             description:[NSString stringWithFormat:@"The selected executable could not start: %@", launchError.localizedDescription]
                          recoveryReason:@"Choose a Python 3.9 or newer interpreter."];
        }
        return NO;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (probe.isRunning && [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.01];
    }
    if (probe.isRunning) {
        [probe terminate];
        if (error != NULL) {
            *error = [self errorWithCode:ROBPythonRuntimeErrorInvalidInterpreter
                             description:@"The selected executable did not respond like a Python interpreter."
                          recoveryReason:@"Choose the python3 executable inside the environment."];
        }
        return NO;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    if (probe.terminationStatus != 0 || ![output containsString:@"CerebroPython3"]) {
        if (error != NULL) {
            *error = [self errorWithCode:ROBPythonRuntimeErrorInvalidInterpreter
                             description:@"The selected executable is not Python 3.9 or newer."
                          recoveryReason:@"DepthAI 3.8 requires Python 3.9 or newer."];
        }
        return NO;
    }
    return YES;
}

- (NSString *)interpreterPathForSelection:(NSString *)selection error:(NSError **)error
{
    NSString *expandedPath = [[selection stringByExpandingTildeInPath] stringByStandardizingPath];
    if (expandedPath.length == 0) {
        if (error != NULL) {
            *error = [self errorWithCode:ROBPythonRuntimeErrorInvalidInterpreter
                             description:@"No Python interpreter was selected."
                          recoveryReason:@"Choose a Python executable or an environment directory."];
        }
        return nil;
    }

    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:expandedPath isDirectory:&isDirectory] && isDirectory) {
        NSArray<NSString *> *relativeCandidates = @[@"bin/python3", @"bin/python"];
        for (NSString *relativePath in relativeCandidates) {
            NSString *candidate = [expandedPath stringByAppendingPathComponent:relativePath];
            if ([self isExecutableFileAtPath:candidate]) {
                return candidate;
            }
        }
    } else if ([self isExecutableFileAtPath:expandedPath]) {
        return expandedPath;
    }

    if (error != NULL) {
        *error = [self errorWithCode:ROBPythonRuntimeErrorInvalidInterpreter
                         description:[NSString stringWithFormat:@"Python is not executable at %@.", expandedPath]
                      recoveryReason:@"Choose the python3 executable inside a working virtualenv, Conda environment, Homebrew installation, or system installation."];
    }
    return nil;
}

- (BOOL)selectPythonAtPath:(NSString *)selection error:(NSError **)error
{
    NSString *interpreter = [self interpreterPathForSelection:selection error:error];
    if (interpreter == nil) {
        return NO;
    }
    if (![self probePython3AtPath:interpreter error:error]) {
        return NO;
    }

    [[NSUserDefaults standardUserDefaults] setObject:interpreter forKey:ROBPythonExecutableDefaultsKey];
    [self postRuntimeDidChange];
    return YES;
}

- (void)postRuntimeDidChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ROBPythonRuntimeDidChangeNotification
                                                            object:self];
    });
}

- (NSArray<NSString *> *)availablePythonPaths
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    NSDictionary<NSString *, NSString *> *environment = processInfo.environment;

    NSArray<NSString *> *environmentRoots = @[
        environment[@"VIRTUAL_ENV"] ?: @"",
        environment[@"CONDA_PREFIX"] ?: @""
    ];
    for (NSString *root in environmentRoots) {
        if (root.length > 0) {
            for (NSString *name in @[@"python3"]) {
                NSString *candidate = [[root stringByAppendingPathComponent:@"bin"] stringByAppendingPathComponent:name];
                if ([self isExecutableFileAtPath:candidate] && ![seen containsObject:candidate]) {
                    [seen addObject:candidate];
                    [candidates addObject:candidate];
                }
            }
        }
    }

    NSString *managedPython = [[self managedEnvironmentDirectory] stringByAppendingPathComponent:@"bin/python3"];
    if ([self isExecutableFileAtPath:managedPython]) {
        [seen addObject:managedPython];
        [candidates addObject:managedPython];
    }

    for (NSString *directory in [environment[@"PATH"] componentsSeparatedByString:@":"]) {
        if (directory.length == 0) {
            continue;
        }
        for (NSString *name in @[@"python3"]) {
            NSString *candidate = [[directory stringByAppendingPathComponent:name] stringByStandardizingPath];
            if ([self isExecutableFileAtPath:candidate] && ![seen containsObject:candidate]) {
                [seen addObject:candidate];
                [candidates addObject:candidate];
            }
        }
    }

    for (NSString *candidate in @[@"/opt/homebrew/bin/python3",
                                    @"/usr/local/bin/python3",
                                    @"/usr/bin/python3"]) {
        if ([self isExecutableFileAtPath:candidate] && ![seen containsObject:candidate]) {
            [seen addObject:candidate];
            [candidates addObject:candidate];
        }
    }
    return candidates;
}

- (NSString *)autoDetectedPythonPathExcludingManagedEnvironment:(BOOL)excludeManaged
{
    NSString *managedPrefix = [[self managedEnvironmentDirectory] stringByAppendingString:@"/"];
    for (NSString *candidate in [self availablePythonPaths]) {
        if (!excludeManaged || ![candidate hasPrefix:managedPrefix]) {
            return candidate;
        }
    }
    return nil;
}

- (NSString *)resolvedPythonPathAndReturnError:(NSError **)error
{
    NSString *configuredPath = self.configuredPythonPath;
    if (configuredPath.length > 0) {
        NSString *validated = [self interpreterPathForSelection:configuredPath error:error];
        return validated;
    }

    NSString *detectedPath = [self autoDetectedPythonPathExcludingManagedEnvironment:NO];
    if (detectedPath.length > 0) {
        return detectedPath;
    }

    if (error != NULL) {
        *error = [self errorWithCode:ROBPythonRuntimeErrorNoInterpreter
                         description:@"Cerebro could not find a Python 3.9 or newer interpreter."
                      recoveryReason:@"Open Python Settings to select an environment or create the managed environment."];
    }
    return nil;
}

- (NSDictionary<NSString *,NSString *> *)pythonTaskEnvironmentForPythonPath:(NSString *)pythonPath
{
    NSMutableDictionary<NSString *, NSString *> *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSArray<NSString *> *pythonEnvironmentKeys = [environment.allKeys filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *key, NSDictionary *bindings) {
            return [key isEqualToString:@"PYTHONHOME"] ||
                   [key isEqualToString:@"PYTHONPATH"] ||
                   [key isEqualToString:@"VIRTUAL_ENV"] ||
                   [key hasPrefix:@"CONDA_"] ||
                   [key hasPrefix:@"PYENV_"];
        }]];
    [environment removeObjectsForKeys:pythonEnvironmentKeys];

    environment[@"PYTHONUNBUFFERED"] = @"1";
    environment[@"PYTHONDONTWRITEBYTECODE"] = @"1";
    environment[@"CEREBRO_PYTHON_EXECUTABLE"] = pythonPath;

    NSString *pythonBinDirectory = [pythonPath stringByDeletingLastPathComponent];
    NSString *inheritedPath = [NSProcessInfo processInfo].environment[@"PATH"];
    environment[@"PATH"] = inheritedPath.length > 0
        ? [NSString stringWithFormat:@"%@:%@", pythonBinDirectory, inheritedPath]
        : [NSString stringWithFormat:@"%@:/usr/bin:/bin:/usr/sbin:/sbin", pythonBinDirectory];

    NSString *environmentRoot = [pythonBinDirectory stringByDeletingLastPathComponent];
    if ([[NSFileManager defaultManager]
        fileExistsAtPath:[environmentRoot stringByAppendingPathComponent:@"pyvenv.cfg"]]) {
        environment[@"VIRTUAL_ENV"] = environmentRoot;
    }

    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *amberZipPath = [[NSBundle mainBundle] pathForResource:@"amber_api" ofType:@"zip"];
    NSMutableArray<NSString *> *pythonPaths = [NSMutableArray array];
    if (resourcePath.length > 0) {
        [pythonPaths addObject:resourcePath];
    }
    if (amberZipPath.length > 0) {
        [pythonPaths addObject:amberZipPath];
    }
    if (pythonPaths.count > 0) {
        environment[@"PYTHONPATH"] = [pythonPaths componentsJoinedByString:@":"];
    }
    return environment;
}

- (void)postConfigurationRequired:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ROBPythonRuntimeConfigurationRequiredNotification
                          object:self
                        userInfo:error != nil ? @{@"error": error} : nil];
    });
}

- (NSTask *)newTaskWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error
{
    NSError *resolutionError = nil;
    NSString *pythonPath = [self resolvedPythonPathAndReturnError:&resolutionError];
    if (pythonPath == nil) {
        if (error != NULL) {
            *error = resolutionError;
        }
        [self postConfigurationRequired:resolutionError];
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:pythonPath];
    task.arguments = arguments;
    task.environment = [self pythonTaskEnvironmentForPythonPath:pythonPath];
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    if (resourcePath.length > 0) {
        task.currentDirectoryURL = [NSURL fileURLWithPath:resourcePath isDirectory:YES];
    }
    return task;
}

- (NSString *)runPythonWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error
{
    NSError *taskError = nil;
    NSTask *task = [self newTaskWithArguments:arguments error:&taskError];
    if (task == nil) {
        if (error != NULL) {
            *error = taskError;
        }
        return nil;
    }

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    if (!ROBLaunchTaskSafely(task, &taskError)) {
        NSError *launchError = [self errorWithCode:ROBPythonRuntimeErrorLaunchFailed
                                       description:[NSString stringWithFormat:@"Python could not be launched: %@", taskError.localizedDescription]
                                    recoveryReason:@"Choose another Python environment in Settings."];
        if (error != NULL) {
            *error = launchError;
        }
        [self postConfigurationRequired:launchError];
        return nil;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus != 0 && error != NULL) {
        NSString *description = output.length > 0
            ? [NSString stringWithFormat:@"Python exited with status %d: %@", task.terminationStatus, output]
            : [NSString stringWithFormat:@"Python exited with status %d.", task.terminationStatus];
        *error = [self errorWithCode:ROBPythonRuntimeErrorCommandFailed
                         description:description
                      recoveryReason:@"Check the selected environment and its installed dependencies."];
    }
    return output;
}

- (void)validateEnvironmentWithCompletion:(ROBPythonRuntimeCompletion)completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *output = [self runPythonWithArguments:@[
            @"-c",
            @"import sys; import depthai; from amber_api.amber_robot import Amber_Robot; v=str(getattr(depthai, '__version__', '')); assert v == '3.8.0', 'Webcam_color.py requires DepthAI 3.8.0'; print(sys.executable); print(sys.version.split()[0]); print('depthai ' + v); print('amber_api bundled')"
        ] error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil, output ?: @"", error);
        });
    });
}

- (NSString *)requirementsFilePath
{
    return [[NSBundle mainBundle] pathForResource:@"PythonRequirements" ofType:@"txt"];
}

- (void)installDependenciesWithCompletion:(ROBPythonRuntimeCompletion)completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[@"-m", @"pip", @"install", @"--upgrade"]];
        NSString *requirementsPath = [self requirementsFilePath];
        if (requirementsPath.length > 0) {
            [arguments addObjectsFromArray:@[@"--requirement", requirementsPath]];
        } else {
            [arguments addObjectsFromArray:self.requiredPackages];
        }

        NSError *error = nil;
        NSString *output = [self runPythonWithArguments:arguments error:&error];
        // A failed pip run can still leave a partially updated environment,
        // and managed-environment creation saves its interpreter silently so
        // services do not race pip. Notify once provisioning has finished in
        // either case so every Python feature switches atomically afterward.
        [self postRuntimeDidChange];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil, output ?: @"", error);
        });
    });
}

- (void)createManagedEnvironmentWithCompletion:(ROBPythonRuntimeCompletion)completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *basePython = nil;
        NSError *configuredError = nil;
        NSString *configuredPath = self.configuredPythonPath;
        if (configuredPath.length > 0) {
            NSString *candidate = [self interpreterPathForSelection:configuredPath error:&configuredError];
            NSString *managedPrefix = [[self managedEnvironmentDirectory] stringByAppendingString:@"/"];
            if (candidate.length > 0 && ![candidate hasPrefix:managedPrefix]) {
                basePython = candidate;
            }
        }
        if (basePython.length == 0) {
            basePython = [self autoDetectedPythonPathExcludingManagedEnvironment:YES];
        }
        if (basePython.length == 0) {
            NSError *error = [self errorWithCode:ROBPythonRuntimeErrorNoInterpreter
                                      description:@"A base Python 3.9 or newer installation is required to create the managed environment."
                                   recoveryReason:@"Install Python 3.9 or newer, or select an existing environment first."];
            [self postConfigurationRequired:error];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"", error);
            });
            return;
        }

        NSString *managedDirectory = self.managedEnvironmentDirectory;
        NSString *parentDirectory = [managedDirectory stringByDeletingLastPathComponent];
        NSError *directoryError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:parentDirectory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError];
        if (directoryError != nil) {
            NSError *error = [self errorWithCode:ROBPythonRuntimeErrorManagedEnvironmentFailed
                                      description:[NSString stringWithFormat:@"The managed environment directory could not be created: %@", directoryError.localizedDescription]
                                   recoveryReason:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"", error);
            });
            return;
        }

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:basePython];
        task.arguments = @[@"-m", @"venv", managedDirectory];
        task.environment = [self pythonTaskEnvironmentForPythonPath:basePython];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSError *launchError = nil;
        if (!ROBLaunchTaskSafely(task, &launchError)) {
            NSError *error = [self errorWithCode:ROBPythonRuntimeErrorManagedEnvironmentFailed
                                      description:[NSString stringWithFormat:@"The managed environment could not be created: %@", launchError.localizedDescription]
                                   recoveryReason:@"Select a Python installation that supports the venv module."];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"", error);
            });
            return;
        }

        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (task.terminationStatus != 0) {
            NSError *error = [self errorWithCode:ROBPythonRuntimeErrorManagedEnvironmentFailed
                                      description:[NSString stringWithFormat:@"Creating the managed environment failed: %@", output]
                                   recoveryReason:@"Select a Python installation that supports the venv module."];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, output, error);
            });
            return;
        }

        NSString *managedPython = [managedDirectory stringByAppendingPathComponent:@"bin/python3"];
        NSError *selectionError = nil;
        NSString *validatedManagedPython = [self interpreterPathForSelection:managedPython
                                                                        error:&selectionError];
        if (validatedManagedPython == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, output, selectionError);
            });
            return;
        }
        // Do not publish a runtime-change notification until the settings
        // controller's immediately following dependency install completes.
        [[NSUserDefaults standardUserDefaults] setObject:validatedManagedPython
                                                  forKey:ROBPythonExecutableDefaultsKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, output, nil);
        });
    });
}

@end
