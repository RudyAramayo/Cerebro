//
//  AppDelegate.m
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "AppDelegate.h"
#import "ROBPythonRuntime.h"
#import "ROBPythonSettingsWindowController.h"
#import "ROBMainViewController.h"
#import "ROBSystemDependencyManager.h"
#import "ROBTaskLaunchGuard.h"
#import "Cerebro-Swift.h"
#import <signal.h>
#import <unistd.h>

static NSString * const ROBDepthCameraSocketDefaultsKey = @"ROBDepthCameraSocketPath";
static NSString * const ROBDepthCameraServiceReadyNotification = @"ROBDepthCameraServiceReady";
static NSString * const ROBLegacyLuxonisUVCDefaultsKey = @"ROBAllowLuxonisUVCFallback";
static NSString * const ROBDevelopmentModeDefaultsKey = @"ROBDevelopmentMode";
static NSString * const ROBShowControllerInputDiagnosticsNotification = @"ROBShowControllerInputDiagnostics";
static NSString * const ROBDevelopmentModeDidChangeNotification = @"ROBDevelopmentModeDidChange";
static NSString * const ROBHologramMovieRecordingStateDidChangeNotification = @"ROBHologramMovieRecordingStateDidChange";

@interface AppDelegate ()
@property (readwrite, retain) NSTimer *rplidarCheckTimer;
@property (readwrite, retain) NSTimer *utcWebCamCheckTimer;
@property (readwrite, assign) BOOL utcWebCamIsOnline;
@property (readwrite, retain) NSTask *utcWebCamTask;
@property (readwrite, retain) NSPipe *utcWebCamPipe;
@property (readwrite, retain) NSMutableString *utcWebCamOutput;
@property (readwrite, strong) dispatch_queue_t utcWebCamOutputQueue;
@property (readwrite, retain) ROBPythonSettingsWindowController *pythonSettingsWindowController;
@property (readwrite, assign) BOOL presentedPythonSettingsForCurrentError;
@property (readwrite, assign) BOOL pythonEnvironmentNeedsAttention;
@property (readwrite, assign) BOOL utcWebCamPreflightRunning;
@property (readwrite, assign) BOOL restartUTCWebCamAfterTermination;
@property (readwrite, assign) NSUInteger pythonRuntimeGeneration;
@property (readwrite, assign) BOOL reportedMissingRPLidarApplication;
@property (readwrite, retain) NSMenuItem *developmentModeMenuItem;
@property (readwrite, retain) NSMenuItem *controllerDiagnosticsMenuItem;
@property (readwrite, retain) NSMenuItem *cameraDiagnosticsMenuItem;
@property (readwrite, retain) NSMenuItem *amberDiagnosticsMenuItem;
@property (readwrite, retain) NSMenuItem *wakeUpCalibrationMenuItem;
@property (readwrite, retain) NSMenuItem *hologramExportMenuItem;
@property (readwrite, retain) NSMenuItem *hologramSettingsMenuItem;
@property (readwrite, retain) NSMenuItem *hologramRecordMenuItem;
@property (readwrite, retain) NSMenuItem *hologramStopMenuItem;
@property (readwrite, retain) NSMenuItem *hologramAirDropMenuItem;
- (void)workspaceDidWake:(NSNotification *)notification;
- (ROBMainViewController *)mainViewControllerInViewController:(NSViewController *)viewController;

@end

@implementation AppDelegate

// How to set ROB's wake/sleep schedule:
//   sudo pmset repeat shutdown MTWRFSU 23:50:00 wakeorpoweron MTWRFSU 07:00:00

- (BOOL)applicationShouldSaveApplicationState:(NSApplication *)application
{
    return NO;
}

- (BOOL)applicationShouldRestoreApplicationState:(NSApplication *)application
{
    return NO;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    [self installDevelopmentMenu];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(workspaceDidWake:)
               name:NSWorkspaceDidWakeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hologramMovieRecordingStateDidChange:)
                                                 name:ROBHologramMovieRecordingStateDidChangeNotification
                                               object:nil];

    self.utcWebCamIsOnline = NO;
    self.utcWebCamOutput = [NSMutableString string];
    self.utcWebCamOutputQueue = dispatch_queue_create("com.orbitusrobotics.Cerebro.UTCWebCamOutput", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pythonRuntimeDidChange:)
                                                 name:ROBPythonRuntimeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pythonConfigurationRequired:)
                                                 name:ROBPythonRuntimeConfigurationRequiredNotification
                                               object:nil];
    ROBSystemDependencyManager *dependencyManager = [ROBSystemDependencyManager sharedManager];
    [dependencyManager refreshSSHpassAvailability];
    if (dependencyManager.sshpassPath.length > 0) {
        NSLog(@"Cerebro system dependency ready: sshpass at %@", dependencyManager.sshpassPath);
    } else {
        NSLog(@"Cerebro system dependency needs attention: choose Homebrew or MacPorts in Settings to install sshpass");
    }
    [self utcWebCamCheck];
    [[ROBInsta360CameraService shared] start];
    [[ROBMLXRuntime shared] prepareVisionModel];
    //Give RPLidar 10 seconds to warm up as the macmini is booting quite fast
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self rpLidarCheck];
    });
}

- (void)installDevelopmentMenu
{
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Development"];
    self.developmentModeMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Development Mode"
               action:@selector(toggleDevelopmentMode:)
        keyEquivalent:@""];
    self.developmentModeMenuItem.target = self;
    [submenu addItem:self.developmentModeMenuItem];
    [submenu addItem:NSMenuItem.separatorItem];

    self.controllerDiagnosticsMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Controller Input Scene…"
               action:@selector(showControllerInputDiagnostics:)
        keyEquivalent:@""];
    self.controllerDiagnosticsMenuItem.target = self;
    [submenu addItem:self.controllerDiagnosticsMenuItem];
    self.cameraDiagnosticsMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Camera Diagnostics…"
               action:@selector(showCameraDiagnostics:)
        keyEquivalent:@""];
    self.cameraDiagnosticsMenuItem.target = self;
    [submenu addItem:self.cameraDiagnosticsMenuItem];
    self.amberDiagnosticsMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Amber Arm Diagnostics…"
               action:@selector(showAmberArmDiagnostics:)
        keyEquivalent:@""];
    self.amberDiagnosticsMenuItem.target = self;
    [submenu addItem:self.amberDiagnosticsMenuItem];
    self.wakeUpCalibrationMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"ROB Wake-Up Calibration (Dry Run)…"
               action:@selector(showWakeUpCalibration:)
        keyEquivalent:@""];
    self.wakeUpCalibrationMenuItem.target = self;
    [submenu addItem:self.wakeUpCalibrationMenuItem];
    self.hologramSettingsMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Hologram Voxel Detail…"
               action:@selector(showHologramCaptureSettings:)
        keyEquivalent:@""];
    self.hologramSettingsMenuItem.target = self;
    [submenu addItem:self.hologramSettingsMenuItem];
    self.hologramExportMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Capture Hologram Web Package…"
               action:@selector(exportHologramMessage:)
        keyEquivalent:@""];
    self.hologramExportMenuItem.target = self;
    [submenu addItem:self.hologramExportMenuItem];
    self.hologramRecordMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Start AR Voxel Hologram Recording…"
               action:@selector(startHologramMovieRecording:)
        keyEquivalent:@""];
    self.hologramRecordMenuItem.target = self;
    [submenu addItem:self.hologramRecordMenuItem];
    self.hologramStopMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Stop and Export AR Voxel Recording…"
               action:@selector(stopHologramMovieRecording:)
        keyEquivalent:@""];
    self.hologramStopMenuItem.target = self;
    [submenu addItem:self.hologramStopMenuItem];
    self.hologramAirDropMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"AirDrop Latest Hologram for 10 Minutes…"
               action:@selector(shareLatestHologramViaAirDrop:)
        keyEquivalent:@""];
    self.hologramAirDropMenuItem.target = self;
    [submenu addItem:self.hologramAirDropMenuItem];

    NSMenuItem *developmentItem = [[NSMenuItem alloc] initWithTitle:@"Development"
                                                             action:nil
                                                      keyEquivalent:@""];
    developmentItem.submenu = submenu;
    [NSApp.mainMenu addItem:developmentItem];
    [self updateDevelopmentMenuState];
}

- (void)updateDevelopmentMenuState
{
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey];
    self.developmentModeMenuItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.controllerDiagnosticsMenuItem.enabled = enabled;
    self.cameraDiagnosticsMenuItem.enabled = enabled;
    self.amberDiagnosticsMenuItem.enabled = enabled;
    self.wakeUpCalibrationMenuItem.enabled = enabled;
    self.hologramExportMenuItem.enabled = enabled;
    BOOL recording = [ROBHologramExporter shared].isMovieRecording;
    self.hologramSettingsMenuItem.enabled = enabled && !recording;
    self.hologramRecordMenuItem.enabled = enabled && !recording;
    self.hologramStopMenuItem.enabled = enabled && recording;
    self.hologramAirDropMenuItem.enabled = enabled && !recording;
}

- (IBAction)toggleDevelopmentMode:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![defaults boolForKey:ROBDevelopmentModeDefaultsKey];
    [defaults setBool:enabled forKey:ROBDevelopmentModeDefaultsKey];
    [self updateDevelopmentMenuState];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ROBDevelopmentModeDidChangeNotification
                      object:self];
}

- (IBAction)showControllerInputDiagnostics:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ROBShowControllerInputDiagnosticsNotification
                      object:self];
}

- (IBAction)showCameraDiagnostics:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    for (NSWindow *window in NSApp.windows) {
        ROBMainViewController *mainViewController =
            [self mainViewControllerInViewController:window.contentViewController];
        if (mainViewController != nil) {
            [mainViewController showCameraDiagnostics:sender];
            return;
        }
    }
    NSBeep();
}

- (IBAction)showAmberArmDiagnostics:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    [[ROBAmberDiagnosticsWindowController shared] showWindow:sender];
}

- (IBAction)showWakeUpCalibration:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    [[ROBWakeUpCalibrationWindowController shared] showWindow:sender];
}

- (IBAction)exportHologramMessage:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    [[ROBHologramExporter shared] exportInteractively];
}

- (IBAction)showHologramCaptureSettings:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    [[ROBHologramExporter shared] showCaptureSettings];
}

- (IBAction)startHologramMovieRecording:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    [[ROBHologramExporter shared] startMovieRecording];
    [self updateDevelopmentMenuState];
}

- (IBAction)stopHologramMovieRecording:(id)sender
{
    [[ROBHologramExporter shared] stopMovieRecordingInteractively];
    [self updateDevelopmentMenuState];
}

- (IBAction)shareLatestHologramViaAirDrop:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        NSBeep();
        return;
    }
    [[ROBHologramExporter shared] shareLatestHologramViaAirDrop];
}

- (void)hologramMovieRecordingStateDidChange:(NSNotification *)notification
{
    [self updateDevelopmentMenuState];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self.rplidarCheckTimer invalidate];
    [self.utcWebCamCheckTimer invalidate];
    [[ROBHologramExporter shared] stopAirDropSession];
    [[ROBInsta360CameraService shared] stop];
    [self stopUTCWebCamTask];
}

- (void)workspaceDidWake:(NSNotification *)notification
{
    NSLog(@"Cerebro is recovering hardware and service health after system wake");

    ROBSystemDependencyManager *dependencyManager = [ROBSystemDependencyManager sharedManager];
    [dependencyManager refreshSSHpassAvailability];

    [self.rplidarCheckTimer invalidate];
    self.rplidarCheckTimer = nil;
    [self rpLidarCheck];

    [self.utcWebCamCheckTimer invalidate];
    self.utcWebCamCheckTimer = nil;
    self.utcWebCamPreflightRunning = NO;
    if (!self.utcWebCamTask.isRunning) {
        self.utcWebCamIsOnline = NO;
    }
    [self utcWebCamCheck];
    [[ROBInsta360CameraService shared] recoverAfterWake];
}

- (IBAction)showPythonSettings:(id)sender
{
    if (self.pythonSettingsWindowController == nil) {
        self.pythonSettingsWindowController = [[ROBPythonSettingsWindowController alloc] init];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.pythonSettingsWindowController showWindow:sender];
}

- (IBAction)showInsta360Settings:(id)sender
{
    if (self.pythonSettingsWindowController == nil) {
        self.pythonSettingsWindowController = [[ROBPythonSettingsWindowController alloc] init];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.pythonSettingsWindowController showInsta360Settings:sender];
}

- (IBAction)showSystemStatus:(id)sender
{
    for (NSWindow *window in NSApp.windows) {
        ROBMainViewController *mainViewController =
            [self mainViewControllerInViewController:window.contentViewController];
        if (mainViewController != nil) {
            [mainViewController showSystemStatus:sender];
            return;
        }
    }
    NSBeep();
}

- (ROBMainViewController *)mainViewControllerInViewController:(NSViewController *)viewController
{
    if ([viewController isKindOfClass:[ROBMainViewController class]]) {
        return (ROBMainViewController *)viewController;
    }
    for (NSViewController *childViewController in viewController.childViewControllers) {
        ROBMainViewController *mainViewController =
            [self mainViewControllerInViewController:childViewController];
        if (mainViewController != nil) {
            return mainViewController;
        }
    }
    return nil;
}

- (void)pythonConfigurationRequired:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = notification.userInfo[@"error"];
        if (error != nil) {
            NSLog(@"Python configuration required: %@", error.localizedDescription);
        }
        self.pythonEnvironmentNeedsAttention = YES;
        if (!self.presentedPythonSettingsForCurrentError) {
            self.presentedPythonSettingsForCurrentError = YES;
            [self showPythonSettings:nil];
        }
    });
}

- (void)pythonRuntimeDidChange:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.presentedPythonSettingsForCurrentError = NO;
        self.pythonEnvironmentNeedsAttention = NO;
        self.pythonRuntimeGeneration += 1;
        self.utcWebCamPreflightRunning = NO;
        self.utcWebCamIsOnline = NO;
        [self restartUTCWebCamForRuntimeChange];
    });
}


- (void) rpLidarCheck {
    
    self.rplidarCheckTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        //open RPLidar only after 10 seconds to let it start up
        // /usr/bin/open /Users/rob/Library/Developer/Xcode/DerivedData/RPLidar-fziuydzdocbagjfcyicbboaqukse/Build/Products/Debug-iphoneos/.XCInstall/RPLidar.app
        
        NSTask *rpLidarIsRunning = [NSTask new];
        rpLidarIsRunning.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
        rpLidarIsRunning.arguments = @[@"aux"];
        
        NSPipe *pipe = [NSPipe pipe];
        rpLidarIsRunning.standardOutput = pipe;
        
        NSError *processCheckError = nil;
        if (!ROBLaunchTaskSafely(rpLidarIsRunning, &processCheckError)) {
            NSLog(@"RPLidar process check could not start: %@", processCheckError.localizedDescription);
            return;
        }
        
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        if ([output componentsSeparatedByString:@"RPLidar.app"].count < 2) { //If we have a count of 2 then 1 RPLidar instance is running
            NSString *configuredPath = [[NSUserDefaults standardUserDefaults]
                stringForKey:@"ROBRPLidarApplicationPath"];
            NSArray<NSString *> *candidates = configuredPath.length > 0
                ? @[configuredPath]
                : @[@"/Applications/RPLidar.app", @"~/Applications/RPLidar.app"];
            NSString *rplidarApplicationPath = nil;
            for (NSString *candidate in candidates) {
                NSString *expandedPath = [[candidate stringByExpandingTildeInPath]
                    stringByStandardizingPath];
                BOOL isDirectory = NO;
                if ([[NSFileManager defaultManager] fileExistsAtPath:expandedPath
                                                         isDirectory:&isDirectory] && isDirectory) {
                    rplidarApplicationPath = expandedPath;
                    break;
                }
            }
            if (rplidarApplicationPath.length == 0) {
                if (!self.reportedMissingRPLidarApplication) {
                    NSLog(@"RPLidar application is unavailable; install it in Applications or set ROBRPLidarApplicationPath.");
                    self.reportedMissingRPLidarApplication = YES;
                }
                return;
            }
            self.reportedMissingRPLidarApplication = NO;
            NSLog(@"Launching RPLidar at %@...", rplidarApplicationPath);
            
            NSTask *launchRPLidar = [NSTask new];
            launchRPLidar.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
            launchRPLidar.arguments = @[rplidarApplicationPath];
            NSError *openError = nil;
            if (!ROBLaunchTaskSafely(launchRPLidar, &openError)) {
                NSLog(@"RPLidar launcher could not start: %@", openError.localizedDescription);
            }
        } else {
            //NSLog(@"RPLidar check passsed...");
        }
    }];
}

- (void) utcWebCamCheck {
    [self checkIfUTCWebcamIsOnline];
    self.utcWebCamCheckTimer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self checkIfUTCWebcamIsOnline];
    }];
}

- (void) checkIfUTCWebcamIsOnline {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:ROBLegacyLuxonisUVCDefaultsKey]) {
        if (self.utcWebCamTask.isRunning) {
            [self stopUTCWebCamTask];
        }
        self.utcWebCamIsOnline = NO;
        return;
    }
    if (self.pythonEnvironmentNeedsAttention || self.utcWebCamPreflightRunning ||
        self.utcWebCamIsOnline || self.utcWebCamTask.isRunning) {
        return;
    }

    self.utcWebCamPreflightRunning = YES;
    NSUInteger generation = self.pythonRuntimeGeneration;
    [[ROBPythonRuntime sharedRuntime] validateEnvironmentWithCompletion:^(BOOL success, NSString *output, NSError *error) {
        if (generation != self.pythonRuntimeGeneration) {
            return;
        }
        self.utcWebCamPreflightRunning = NO;
        if (!success) {
            self.pythonEnvironmentNeedsAttention = YES;
            NSError *configurationError = error ?: [NSError
                errorWithDomain:ROBPythonRuntimeErrorDomain
                           code:ROBPythonRuntimeErrorCommandFailed
                       userInfo:@{NSLocalizedDescriptionKey: @"The selected Python environment did not pass validation."}];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:ROBPythonRuntimeConfigurationRequiredNotification
                              object:[ROBPythonRuntime sharedRuntime]
                            userInfo:@{@"error": configurationError}];
            return;
        }
        [self startUTCWebcamProcess];
    }];
}

- (void)startUTCWebcamProcess
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:ROBLegacyLuxonisUVCDefaultsKey]) {
        return;
    }
    if (self.pythonEnvironmentNeedsAttention || self.utcWebCamIsOnline || self.utcWebCamTask.isRunning) {
        return;
    }

    NSLog(@"Attempting to start the DepthAI RGB-D service");

    NSString *webcam_color_script_path = [[NSBundle mainBundle] pathForResource:@"Webcam_color" ofType:@"py"];
    if (webcam_color_script_path.length == 0) {
        NSLog(@"DepthAI service could not start because Webcam_color.py is missing from the application bundle.");
        return;
    }
    NSLog(@"scriptPath = %@", webcam_color_script_path);

    NSURL *applicationSupportURL = [[[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask] firstObject];
    NSURL *serviceDirectory = [applicationSupportURL URLByAppendingPathComponent:@"Cerebro"
                                                                      isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:serviceDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        NSLog(@"DepthAI service directory is unavailable: %@", directoryError.localizedDescription);
        return;
    }
    NSString *socketPath = [[serviceDirectory URLByAppendingPathComponent:@"depth-camera.sock"] path];
    [[NSUserDefaults standardUserDefaults] setObject:socketPath forKey:ROBDepthCameraSocketDefaultsKey];

    NSError *taskError = nil;
    NSString *parentProcessID = [NSString stringWithFormat:@"%d", getpid()];
    NSString *mxid = [[NSUserDefaults standardUserDefaults] stringForKey:@"ROBFaceCameraMXID"];
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[
        webcam_color_script_path,
        @"--socket", socketPath,
        @"--parent-pid", parentProcessID
    ]];
    if (mxid != nil && mxid.length > 0) {
        [args addObject:@"--mxid"];
        [args addObject:mxid];
    }
    NSTask *task = [[ROBPythonRuntime sharedRuntime]
        newTaskWithArguments:args
                         error:&taskError];
    if (task == nil) {
        NSLog(@"UTC Webcam Python configuration error: %@", taskError.localizedDescription);
        return;
    }

    self.utcWebCamOutput = [NSMutableString string];
    self.utcWebCamPipe = [NSPipe pipe];
    task.standardOutput = self.utcWebCamPipe;
    task.standardError = self.utcWebCamPipe;
    self.utcWebCamTask = task;

    __weak AppDelegate *weakSelf = self;
    NSFileHandle *readHandle = self.utcWebCamPipe.fileHandleForReading;
    dispatch_queue_t outputQueue = self.utcWebCamOutputQueue;
    NSUInteger taskGeneration = self.pythonRuntimeGeneration;
    readHandle.readabilityHandler = ^(NSFileHandle *handle) {
        dispatch_sync(outputQueue, ^{
            NSData *data = handle.availableData;
            if (data.length == 0) {
                return;
            }
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (output.length > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (weakSelf.utcWebCamTask == task &&
                        weakSelf.pythonRuntimeGeneration == taskGeneration) {
                        [weakSelf handleUTCWebCamOutput:output];
                    }
                });
            }
        });
    };

    task.terminationHandler = ^(NSTask *completedTask) {
        readHandle.readabilityHandler = nil;
        dispatch_sync(outputQueue, ^{
            NSData *remainingData = [readHandle readDataToEndOfFile];
            NSString *remainingOutput = [[NSString alloc] initWithData:remainingData
                                                               encoding:NSUTF8StringEncoding] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                AppDelegate *strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf.utcWebCamTask != completedTask) {
                    return;
                }
                BOOL belongsToCurrentRuntime = strongSelf.pythonRuntimeGeneration == taskGeneration;
                BOOL shouldRestart = strongSelf.restartUTCWebCamAfterTermination;
                if (belongsToCurrentRuntime && !shouldRestart && remainingOutput.length > 0) {
                    [strongSelf handleUTCWebCamOutput:remainingOutput];
                }
                strongSelf.utcWebCamTask = nil;
                strongSelf.utcWebCamPipe = nil;
                strongSelf.utcWebCamIsOnline = NO;
                NSLog(@"DepthAI service exited with status %d", completedTask.terminationStatus);
                strongSelf.restartUTCWebCamAfterTermination = NO;
                if (shouldRestart && !strongSelf.pythonEnvironmentNeedsAttention) {
                    [strongSelf checkIfUTCWebcamIsOnline];
                }
            });
        });
    };

    if (!ROBLaunchTaskSafely(task, &taskError)) {
        readHandle.readabilityHandler = nil;
        self.utcWebCamTask = nil;
        self.utcWebCamPipe = nil;
        NSLog(@"DepthAI service could not launch Python: %@", taskError.localizedDescription);
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ROBPythonRuntimeConfigurationRequiredNotification
                          object:[ROBPythonRuntime sharedRuntime]
                        userInfo:@{@"error": taskError}];
    }
}

- (void)handleUTCWebCamOutput:(NSString *)output
{
    [self.utcWebCamOutput appendString:output];
    if (self.utcWebCamOutput.length > 32768) {
        [self.utcWebCamOutput deleteCharactersInRange:NSMakeRange(0, self.utcWebCamOutput.length - 32768)];
    }
    NSLog(@"DepthAI service: %@", [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);

    if (!self.pythonEnvironmentNeedsAttention &&
        ([self.utcWebCamOutput containsString:@"ModuleNotFoundError"] ||
         [self.utcWebCamOutput containsString:@"No module named 'depthai'"])) {
        NSError *dependencyError = [NSError
            errorWithDomain:ROBPythonRuntimeErrorDomain
                       code:ROBPythonRuntimeErrorCommandFailed
                   userInfo:@{
                       NSLocalizedDescriptionKey: @"The selected Python environment is missing the depthai dependency.",
                       NSLocalizedRecoverySuggestionErrorKey: @"Open Python Settings and install the managed dependencies."
                   }];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ROBPythonRuntimeConfigurationRequiredNotification
                          object:[ROBPythonRuntime sharedRuntime]
                        userInfo:@{@"error": dependencyError}];
    }

    if ([self.utcWebCamOutput containsString:@"CEREBRO_DEPTHCAM_READY "]) {
        if (self.utcWebCamIsOnline) {
            return;
        }
        NSLog(@"DepthAI RGB-D service is ready");
        self.utcWebCamIsOnline = YES;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ROBDepthCameraServiceReadyNotification
                          object:nil
                        userInfo:@{ @"socketPath": [[NSUserDefaults standardUserDefaults]
                            stringForKey:ROBDepthCameraSocketDefaultsKey] ?: @"" }];
    }
}

- (void)restartUTCWebCamForRuntimeChange
{
    NSTask *task = self.utcWebCamTask;
    if (task.isRunning) {
        self.restartUTCWebCamAfterTermination = YES;
        self.utcWebCamPipe.fileHandleForReading.readabilityHandler = nil;
        pid_t processIdentifier = task.processIdentifier;
        [task terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (task.isRunning && task.processIdentifier == processIdentifier && processIdentifier > 0) {
                NSLog(@"DepthAI service did not exit after SIGTERM; sending SIGKILL to child %d.", processIdentifier);
                kill(processIdentifier, SIGKILL);
            }
        });
        return;
    }
    [self stopUTCWebCamTask];
    [self checkIfUTCWebcamIsOnline];
}

- (void)stopUTCWebCamTask
{
    self.restartUTCWebCamAfterTermination = NO;
    NSTask *task = self.utcWebCamTask;
    self.utcWebCamTask = nil;
    self.utcWebCamPipe.fileHandleForReading.readabilityHandler = nil;
    self.utcWebCamPipe = nil;
    if (task.isRunning) {
        pid_t processIdentifier = task.processIdentifier;
        [task terminate];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
        while (task.isRunning && deadline.timeIntervalSinceNow > 0) {
            [NSThread sleepForTimeInterval:0.02];
        }
        if (task.isRunning && task.processIdentifier == processIdentifier && processIdentifier > 0) {
            NSLog(@"DepthAI service did not stop cleanly; sending SIGKILL to child %d.", processIdentifier);
            kill(processIdentifier, SIGKILL);
        }
    }
}

@end
