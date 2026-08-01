//
//  ROBMainWindowController.m
//  Cerebro
//

#import "ROBMainWindowController.h"
#import "AppDelegate.h"
#import "ROBPythonRuntime.h"
#import "ROBSystemDependencyManager.h"

@interface ROBMainWindowController ()
@property (nonatomic, strong) NSButton *pythonSettingsButton;
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

    NSView *accessoryView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 156, 30)];
    self.pythonSettingsButton.frame = NSMakeRect(4, 1, 148, 28);
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
        self.pythonSettingsButton.title = needsAttention ? @"⚠ Settings…" : @"Settings…";
        if (self.systemDependencyInstallInProgress && self.pythonRuntimeNeedsAttention) {
            self.pythonSettingsButton.toolTip = @"The Python environment needs attention; installing sshpass with Homebrew…";
        } else if (self.systemDependencyInstallInProgress) {
            self.pythonSettingsButton.toolTip = @"Installing sshpass with Homebrew…";
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
