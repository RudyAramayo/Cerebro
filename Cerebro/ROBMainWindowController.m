//
//  ROBMainWindowController.m
//  Cerebro
//

#import "ROBMainWindowController.h"
#import "AppDelegate.h"
#import "ROBMainViewController.h"
#import "ROBPythonRuntime.h"
#import "ROBSystemDependencyManager.h"

@interface ROBMainWindowController ()
@property (nonatomic, strong) NSButton *pythonSettingsButton;
@property (nonatomic, strong) NSButton *geminiDiagnosticsButton;
@property (nonatomic, strong) NSButton *insta360DiagnosticsButton;
@property (nonatomic, strong) NSButton *stageShowButton;
@property (nonatomic, strong) NSTitlebarAccessoryViewController *settingsAccessoryController;
@property (nonatomic, assign) BOOL pythonRuntimeNeedsAttention;
@property (nonatomic, assign) BOOL systemDependenciesNeedAttention;
@property (nonatomic, assign) BOOL systemDependencyInstallInProgress;
@end

@implementation ROBMainWindowController

- (void)windowDidLoad
{
    [super windowDidLoad];

    self.pythonSettingsButton = [NSButton buttonWithTitle:@"Settings…"
                                                   target:self
                                                   action:@selector(openPythonSettings:)];
    self.pythonSettingsButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.pythonSettingsButton.frame = NSMakeRect(0, 0, 148, 28);
    self.pythonSettingsButton.toolTip = @"Manage Cerebro's Python environment and system tools";

    self.geminiDiagnosticsButton = [NSButton buttonWithTitle:@"Gemini…"
                                                      target:self
                                                      action:@selector(openGeminiDiagnostics:)];
    self.geminiDiagnosticsButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.geminiDiagnosticsButton.toolTip = @"Connect or disconnect Gemini and control microphone/camera streaming";

    self.insta360DiagnosticsButton = [NSButton buttonWithTitle:@"360°…"
                                                        target:self
                                                        action:@selector(openInsta360Diagnostics:)];
    self.insta360DiagnosticsButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.insta360DiagnosticsButton.toolTip = @"Open the opt-in Insta360 RTSP/RTMP developer monitor";

    self.stageShowButton = [NSButton buttonWithTitle:@"Show…"
                                              target:self
                                              action:@selector(openStageShow:)];
    self.stageShowButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.stageShowButton.toolTip = @"Validate, dry-run, and rehearse a connection-tolerant stage show";

    NSView *accessoryView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 468, 30)];
    self.stageShowButton.frame = NSMakeRect(4, 1, 98, 28);
    self.insta360DiagnosticsButton.frame = NSMakeRect(108, 1, 78, 28);
    self.geminiDiagnosticsButton.frame = NSMakeRect(192, 1, 112, 28);
    self.pythonSettingsButton.frame = NSMakeRect(310, 1, 148, 28);
    [accessoryView addSubview:self.stageShowButton];
    [accessoryView addSubview:self.insta360DiagnosticsButton];
    [accessoryView addSubview:self.geminiDiagnosticsButton];
    [accessoryView addSubview:self.pythonSettingsButton];

    self.settingsAccessoryController = [[NSTitlebarAccessoryViewController alloc] init];
    self.settingsAccessoryController.view = accessoryView;
    self.settingsAccessoryController.layoutAttribute = NSLayoutAttributeRight;
    [self.window addTitlebarAccessoryViewController:self.settingsAccessoryController];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pythonRuntimeDidChange:)
                                                 name:ROBPythonRuntimeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pythonRuntimeNeedsConfiguration:)
                                                 name:ROBPythonRuntimeConfigurationRequiredNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(systemDependenciesDidChange:)
                                                 name:ROBSystemDependenciesDidChangeNotification
                                               object:nil];
    self.pythonRuntimeNeedsAttention = [ROBPythonRuntime sharedRuntime].effectivePythonPath.length == 0;
    ROBSystemDependencyManager *dependencyManager = [ROBSystemDependencyManager sharedManager];
    self.systemDependenciesNeedAttention = dependencyManager.sshpassPath.length == 0;
    self.systemDependencyInstallInProgress = dependencyManager.isInstallingSSHpass;
    [self updatePythonSettingsButton];
}

- (void)openInsta360Diagnostics:(id)sender
{
    ROBMainViewController *mainViewController = (ROBMainViewController *)self.contentViewController;
    if ([mainViewController respondsToSelector:@selector(showInsta360Diagnostics:)]) {
        [mainViewController showInsta360Diagnostics:sender];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)openPythonSettings:(id)sender
{
    id appDelegate = NSApp.delegate;
    if ([appDelegate respondsToSelector:@selector(showPythonSettings:)]) {
        [appDelegate showPythonSettings:sender];
    }
}

- (void)openGeminiDiagnostics:(id)sender
{
    ROBMainViewController *mainViewController = (ROBMainViewController *)self.contentViewController;
    if ([mainViewController respondsToSelector:@selector(showGeminiDiagnostics:)]) {
        [mainViewController showGeminiDiagnostics:sender];
    }
}

- (void)openStageShow:(id)sender
{
    ROBMainViewController *mainViewController = (ROBMainViewController *)self.contentViewController;
    if ([mainViewController respondsToSelector:@selector(showStageShow:)]) {
        [mainViewController showStageShow:sender];
    }
}

- (void)pythonRuntimeDidChange:(NSNotification *)notification
{
    self.pythonRuntimeNeedsAttention = NO;
    [self updatePythonSettingsButton];
}

- (void)pythonRuntimeNeedsConfiguration:(NSNotification *)notification
{
    self.pythonRuntimeNeedsAttention = YES;
    [self updatePythonSettingsButton];
}

- (void)systemDependenciesDidChange:(NSNotification *)notification
{
    ROBSystemDependencyManager *dependencyManager = [ROBSystemDependencyManager sharedManager];
    self.systemDependenciesNeedAttention = dependencyManager.sshpassPath.length == 0;
    self.systemDependencyInstallInProgress = dependencyManager.isInstallingSSHpass;
    [self updatePythonSettingsButton];
}

- (void)updatePythonSettingsButton
{
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL unresolvedSystemDependency =
            self.systemDependenciesNeedAttention && !self.systemDependencyInstallInProgress;
        BOOL needsAttention = self.pythonRuntimeNeedsAttention || unresolvedSystemDependency;
        NSString *installingPackageManager = ROBSystemPackageManagerDisplayName(
            [ROBSystemDependencyManager sharedManager].installingPackageManager);
        self.pythonSettingsButton.title = needsAttention ? @"⚠ Settings…" : @"Settings…";
        if (self.systemDependencyInstallInProgress && self.pythonRuntimeNeedsAttention) {
            self.pythonSettingsButton.toolTip = [NSString stringWithFormat:
                @"The Python environment needs attention; installing sshpass with %@…",
                installingPackageManager];
        } else if (self.systemDependencyInstallInProgress) {
            self.pythonSettingsButton.toolTip = [NSString stringWithFormat:
                @"Installing sshpass with %@…", installingPackageManager];
        } else if (self.pythonRuntimeNeedsAttention && self.systemDependenciesNeedAttention) {
            self.pythonSettingsButton.toolTip = @"Python and sshpass dependencies need attention";
        } else if (self.pythonRuntimeNeedsAttention) {
            self.pythonSettingsButton.toolTip = @"The Python environment needs attention";
        } else if (self.systemDependenciesNeedAttention) {
            self.pythonSettingsButton.toolTip = @"sshpass is unavailable; open Settings for installation status";
        } else {
            self.pythonSettingsButton.toolTip = @"Manage Cerebro's Python environment and system tools";
        }
    });
}

@end
