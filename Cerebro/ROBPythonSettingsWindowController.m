//
//  ROBPythonSettingsWindowController.m
//  Cerebro
//

#import "ROBPythonSettingsWindowController.h"
#import "ROBPythonRuntime.h"
#import "ROBSystemDependencyManager.h"

@interface ROBPythonSettingsWindowController ()
@property (nonatomic, strong) NSTextField *pythonPathField;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextView *logTextView;
@property (nonatomic, strong) NSProgressIndicator *progressIndicator;
@property (nonatomic, strong) NSTextField *systemDependencyLabel;
@property (nonatomic, strong) NSButton *installSSHpassButton;
@property (nonatomic, strong) NSArray<NSButton *> *actionButtons;
@property (nonatomic, assign) NSUInteger operationGeneration;
@property (nonatomic, assign) BOOL operationInProgress;
- (BOOL)requireAppliedPythonSelection;
- (void)applyPythonSelectionAtPath:(NSString *)selection;
- (void)refreshControlAvailability;
- (void)refreshSystemDependencyStatus;
- (void)validateAfterInstallForGeneration:(NSUInteger)generation pipOutput:(NSString *)pipOutput;
@end

@implementation ROBPythonSettingsWindowController

- (instancetype)init
{
    NSRect frame = NSMakeRect(0, 0, 680, 500);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        window.title = @"Cerebro Settings";
        window.releasedWhenClosed = NO;
        [window center];
        [self buildInterface];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(runtimeDidChange:)
                                                     name:ROBPythonRuntimeDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(systemDependenciesDidChange:)
                                                     name:ROBSystemDependenciesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame
{
    NSTextField *label = [NSTextField labelWithString:string];
    label.frame = frame;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    return label;
}

- (NSButton *)buttonWithTitle:(NSString *)title
                        frame:(NSRect)frame
                       action:(SEL)action
{
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (void)buildInterface
{
    NSView *contentView = self.window.contentView;

    NSTextField *heading = [self labelWithString:@"Python Environment" frame:NSMakeRect(24, 450, 632, 28)];
    heading.font = [NSFont boldSystemFontOfSize:20.0];
    [contentView addSubview:heading];

    NSTextField *explanation = [self labelWithString:
        @"Cerebro uses this interpreter for the DepthAI webcam service and bundled Amber arm scripts. Choose an existing virtualenv/Conda environment, or create a Cerebro-managed environment."
        frame:NSMakeRect(24, 398, 632, 44)];
    explanation.textColor = [NSColor secondaryLabelColor];
    [contentView addSubview:explanation];

    [contentView addSubview:[self labelWithString:@"Python executable or environment directory:"
                                             frame:NSMakeRect(24, 370, 632, 20)]];

    self.pythonPathField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 334, 492, 28)];
    self.pythonPathField.placeholderString = @"/path/to/environment/bin/python3";
    self.pythonPathField.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    [contentView addSubview:self.pythonPathField];

    NSButton *chooseButton = [self buttonWithTitle:@"Choose…"
                                             frame:NSMakeRect(528, 332, 128, 32)
                                            action:@selector(choosePython:)];
    [contentView addSubview:chooseButton];

    NSButton *applyButton = [self buttonWithTitle:@"Use Selected Python"
                                            frame:NSMakeRect(20, 286, 174, 34)
                                           action:@selector(applySelection:)];
    NSButton *detectButton = [self buttonWithTitle:@"Use Auto-Detected"
                                             frame:NSMakeRect(198, 286, 164, 34)
                                            action:@selector(useAutoDetectedPython:)];
    NSButton *managedButton = [self buttonWithTitle:@"Create Managed Environment + Install"
                                              frame:NSMakeRect(366, 286, 294, 34)
                                             action:@selector(createManagedEnvironment:)];
    [contentView addSubview:applyButton];
    [contentView addSubview:detectButton];
    [contentView addSubview:managedButton];

    self.statusLabel = [self labelWithString:@"Checking environment…" frame:NSMakeRect(24, 250, 632, 22)];
    self.statusLabel.font = [NSFont boldSystemFontOfSize:13.0];
    [contentView addSubview:self.statusLabel];

    NSScrollView *logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 116, 632, 126)];
    logScrollView.hasVerticalScroller = YES;
    logScrollView.borderType = NSBezelBorder;
    self.logTextView = [[NSTextView alloc] initWithFrame:logScrollView.contentView.bounds];
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.logTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    logScrollView.documentView = self.logTextView;
    [contentView addSubview:logScrollView];

    NSString *packageText = [NSString stringWithFormat:@"Managed packages: %@. The Amber API is bundled with Cerebro.",
                             [[[ROBPythonRuntime sharedRuntime] requiredPackages] componentsJoinedByString:@", "]];
    NSTextField *packageLabel = [self labelWithString:packageText frame:NSMakeRect(24, 88, 632, 20)];
    packageLabel.textColor = [NSColor secondaryLabelColor];
    [contentView addSubview:packageLabel];

    self.systemDependencyLabel = [self labelWithString:@"Checking system tools…"
                                                  frame:NSMakeRect(24, 64, 632, 20)];
    self.systemDependencyLabel.textColor = [NSColor secondaryLabelColor];
    self.systemDependencyLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.systemDependencyLabel.maximumNumberOfLines = 1;
    [contentView addSubview:self.systemDependencyLabel];

    NSButton *installButton = [self buttonWithTitle:@"Install Python Packages"
                                              frame:NSMakeRect(20, 22, 210, 34)
                                             action:@selector(installDependencies:)];
    NSButton *checkButton = [self buttonWithTitle:@"Check Python"
                                            frame:NSMakeRect(234, 22, 150, 34)
                                           action:@selector(checkEnvironment:)];
    self.installSSHpassButton = [self buttonWithTitle:@"Install sshpass"
                                                frame:NSMakeRect(388, 22, 240, 34)
                                               action:@selector(installSSHpass:)];
    [contentView addSubview:installButton];
    [contentView addSubview:checkButton];
    [contentView addSubview:self.installSSHpassButton];

    self.progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(636, 30, 20, 20)];
    self.progressIndicator.style = NSProgressIndicatorStyleSpinning;
    self.progressIndicator.displayedWhenStopped = NO;
    [contentView addSubview:self.progressIndicator];

    self.actionButtons = @[chooseButton, applyButton, detectButton, managedButton,
                           installButton, checkButton, self.installSSHpassButton];
    [self refreshFromRuntimeAndValidate:NO];
    [self refreshSystemDependencyStatus];
}

- (void)showWindow:(id)sender
{
    [super showWindow:sender];
    [self.window makeKeyAndOrderFront:sender];
    [self refreshSystemDependencyStatus];
    [self refreshFromRuntimeAndValidate:!self.operationInProgress];
}

- (NSUInteger)beginOperationWithStatus:(NSString *)status
{
    self.operationGeneration += 1;
    self.operationInProgress = YES;
    [self setBusy:YES status:status];
    return self.operationGeneration;
}

- (BOOL)finishOperation:(NSUInteger)generation status:(NSString *)status
{
    if (generation != self.operationGeneration) {
        return NO;
    }
    self.operationInProgress = NO;
    [self setBusy:NO status:status];
    return YES;
}

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    if (status.length > 0) {
        self.statusLabel.stringValue = status;
    }
    [self refreshSystemDependencyStatus];
}

- (void)refreshControlAvailability
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    for (NSButton *button in self.actionButtons) {
        button.enabled = !self.operationInProgress;
    }
    self.installSSHpassButton.enabled = !self.operationInProgress && !manager.isInstallingSSHpass;
    self.pythonPathField.enabled = !self.operationInProgress;
    if (self.operationInProgress || manager.isInstallingSSHpass) {
        [self.progressIndicator startAnimation:nil];
    } else {
        [self.progressIndicator stopAnimation:nil];
    }
}

- (void)refreshSystemDependencyStatus
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    [self refreshControlAvailability];
    NSString *sshpassPath = manager.sshpassPath;
    if (sshpassPath.length > 0) {
        self.systemDependencyLabel.stringValue =
            [NSString stringWithFormat:@"System tool: sshpass ready — %@", sshpassPath];
        self.systemDependencyLabel.textColor = [NSColor systemGreenColor];
        self.systemDependencyLabel.toolTip = sshpassPath;
        self.installSSHpassButton.title = @"Recheck sshpass";
        return;
    }
    if (manager.isInstallingSSHpass) {
        self.systemDependencyLabel.stringValue = @"System tool: installing sshpass with Homebrew…";
        self.systemDependencyLabel.textColor = [NSColor systemOrangeColor];
        self.systemDependencyLabel.toolTip = nil;
        self.installSSHpassButton.title = @"Installing sshpass…";
        return;
    }
    NSError *lastError = manager.lastSSHpassError;
    if ([lastError.domain isEqualToString:ROBSystemDependencyErrorDomain] &&
        lastError.code == ROBSystemDependencyErrorInstallFailed) {
        self.systemDependencyLabel.stringValue = @"System tool: sshpass installation failed — click Retry.";
        self.systemDependencyLabel.textColor = [NSColor systemRedColor];
        self.systemDependencyLabel.toolTip =
            [self messageForError:lastError output:lastError.userInfo[@"commandOutput"] ?: @""];
        self.installSSHpassButton.title = @"Retry sshpass Install";
        return;
    }
    if (manager.homebrewPath.length == 0) {
        self.systemDependencyLabel.stringValue = @"System tool: sshpass missing — Homebrew is required.";
        self.systemDependencyLabel.textColor = [NSColor systemRedColor];
        self.systemDependencyLabel.toolTip = manager.lastSSHpassError.localizedDescription;
        self.installSSHpassButton.title = @"Open Homebrew…";
    } else {
        self.systemDependencyLabel.stringValue = @"System tool: sshpass missing — automatic install is available.";
        self.systemDependencyLabel.textColor = [NSColor systemOrangeColor];
        self.systemDependencyLabel.toolTip = nil;
        self.installSSHpassButton.title = @"Install sshpass";
    }
}

- (void)setLogText:(NSString *)text
{
    self.logTextView.string = text ?: @"";
    [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.string.length, 0)];
}

- (void)refreshFromRuntimeAndValidate:(BOOL)validate
{
    ROBPythonRuntime *runtime = [ROBPythonRuntime sharedRuntime];
    NSString *displayPath = runtime.configuredPythonPath ?: runtime.effectivePythonPath ?: @"";
    self.pythonPathField.stringValue = displayPath;
    if (!validate) {
        return;
    }
    [self validateCurrentEnvironment];
}

- (void)validateCurrentEnvironment
{
    ROBPythonRuntime *runtime = [ROBPythonRuntime sharedRuntime];
    if (runtime.effectivePythonPath.length == 0) {
        self.statusLabel.textColor = [NSColor systemRedColor];
        self.statusLabel.stringValue = @"Python is not configured.";
        [self setLogText:@"Choose an existing Python environment or create the managed environment."];
        return;
    }

    self.statusLabel.textColor = [NSColor labelColor];
    NSUInteger generation = [self beginOperationWithStatus:@"Checking Python and dependencies…"];
    [runtime validateEnvironmentWithCompletion:^(BOOL success, NSString *output, NSError *error) {
        if (![self finishOperation:generation
                            status:success ? @"Python environment is ready." : @"Python works, but dependencies need attention."]) {
            return;
        }
        self.statusLabel.textColor = success ? [NSColor systemGreenColor] : [NSColor systemOrangeColor];
        [self setLogText:success ? output : [self messageForError:error output:output]];
    }];
}

- (NSString *)messageForError:(NSError *)error output:(NSString *)output
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (error.localizedDescription.length > 0) {
        [parts addObject:error.localizedDescription];
    }
    NSString *suggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey];
    if (suggestion.length > 0) {
        [parts addObject:suggestion];
    }
    if (output.length > 0 && ![error.localizedDescription containsString:output]) {
        [parts addObject:output];
    }
    return [parts componentsJoinedByString:@"\n\n"];
}

- (BOOL)requireAppliedPythonSelection
{
    ROBPythonRuntime *runtime = [ROBPythonRuntime sharedRuntime];
    if (runtime.configuredPythonPath.length == 0) {
        self.statusLabel.textColor = [NSColor systemOrangeColor];
        self.statusLabel.stringValue = @"Apply a Python selection before installing packages.";
        [self setLogText:@"Auto-detection is read-only until you click Use Auto-Detected or Use Selected Python. This prevents Cerebro from modifying an unintended system environment."];
        return NO;
    }

    NSError *fieldError = nil;
    NSString *fieldPath = [runtime interpreterPathForSelection:self.pythonPathField.stringValue
                                                         error:&fieldError];
    if (fieldPath == nil || ![fieldPath isEqualToString:runtime.configuredPythonPath]) {
        self.statusLabel.textColor = [NSColor systemOrangeColor];
        self.statusLabel.stringValue = @"The path field has unapplied changes.";
        [self setLogText:@"Click Use Selected Python before installing dependencies into this environment."];
        return NO;
    }
    return YES;
}

- (void)validateAfterInstallForGeneration:(NSUInteger)generation pipOutput:(NSString *)pipOutput
{
    [self setBusy:YES status:@"Dependencies installed; validating the environment…"];
    [[ROBPythonRuntime sharedRuntime] validateEnvironmentWithCompletion:^(BOOL ready, NSString *validationOutput, NSError *validationError) {
        if (![self finishOperation:generation
                            status:ready ? @"Python environment is ready." : @"Packages installed, but validation failed."]) {
            return;
        }
        self.statusLabel.textColor = ready ? [NSColor systemGreenColor] : [NSColor systemRedColor];
        NSString *result = ready
            ? [NSString stringWithFormat:@"%@\n\nValidation:\n%@", pipOutput, validationOutput]
            : [NSString stringWithFormat:@"%@\n\nValidation:\n%@", pipOutput,
               [self messageForError:validationError output:validationOutput]];
        [self setLogText:result];
    }];
}

- (void)choosePython:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Choose a Python Interpreter or Environment";
    panel.message = @"Choose python3 itself, or choose a virtualenv/Conda environment directory containing bin/python3.";
    panel.prompt = @"Choose";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            self.pythonPathField.stringValue = panel.URL.path ?: @"";
            [self applySelection:nil];
        }
    }];
}

- (void)applySelection:(id)sender
{
    [self applyPythonSelectionAtPath:self.pythonPathField.stringValue];
}

- (void)applyPythonSelectionAtPath:(NSString *)selection
{
    NSString *selectionCopy = [selection copy] ?: @"";
    NSUInteger generation = [self beginOperationWithStatus:@"Checking the selected Python interpreter…"];
    [self setLogText:[NSString stringWithFormat:@"Checking %@", selectionCopy.length > 0 ? selectionCopy : @"the selected path"]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL selected = [[ROBPythonRuntime sharedRuntime] selectPythonAtPath:selectionCopy error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.operationGeneration) {
                return;
            }
            if (!selected) {
                [self finishOperation:generation status:@"The selected Python environment is not usable."];
                self.statusLabel.textColor = [NSColor systemRedColor];
                [self setLogText:[self messageForError:error output:@""]];
                return;
            }

            [self finishOperation:generation status:@"Python interpreter selected."];
            [self refreshFromRuntimeAndValidate:YES];
        });
    });
}

- (void)useAutoDetectedPython:(id)sender
{
    NSString *candidate = [[[ROBPythonRuntime sharedRuntime] availablePythonPaths] firstObject];
    if (candidate.length == 0) {
        self.statusLabel.textColor = [NSColor systemRedColor];
        self.statusLabel.stringValue = @"No Python installation was detected.";
        [self setLogText:@"Install Python 3.9 or newer, then choose its interpreter here."];
        return;
    }
    self.pythonPathField.stringValue = candidate;
    [self applyPythonSelectionAtPath:candidate];
}

- (void)createManagedEnvironment:(id)sender
{
    NSUInteger generation = [self beginOperationWithStatus:@"Creating the managed Python environment…"];
    [self setLogText:[NSString stringWithFormat:@"Creating %@", [ROBPythonRuntime sharedRuntime].managedEnvironmentDirectory]];
    [[ROBPythonRuntime sharedRuntime] createManagedEnvironmentWithCompletion:^(BOOL success, NSString *output, NSError *error) {
        if (generation != self.operationGeneration) {
            return;
        }
        if (!success) {
            [self finishOperation:generation status:@"Managed environment creation failed."];
            self.statusLabel.textColor = [NSColor systemRedColor];
            [self setLogText:[self messageForError:error output:output]];
            return;
        }
        self.pythonPathField.stringValue = [ROBPythonRuntime sharedRuntime].effectivePythonPath ?: @"";
        [self setBusy:YES status:@"Managed environment created; installing dependencies…"];
        [[ROBPythonRuntime sharedRuntime] installDependenciesWithCompletion:^(BOOL installed, NSString *installOutput, NSError *installError) {
            if (generation != self.operationGeneration) {
                return;
            }
            if (!installed) {
                [self finishOperation:generation status:@"Dependency installation failed."];
                self.statusLabel.textColor = [NSColor systemRedColor];
                [self setLogText:[self messageForError:installError output:installOutput]];
                return;
            }
            [self validateAfterInstallForGeneration:generation pipOutput:installOutput];
        }];
    }];
}

- (void)installDependencies:(id)sender
{
    if (![self requireAppliedPythonSelection]) {
        return;
    }
    NSUInteger generation = [self beginOperationWithStatus:@"Installing Python dependencies…"];
    [self setLogText:@"Running pip in the selected environment. This can take a few minutes."];
    [[ROBPythonRuntime sharedRuntime] installDependenciesWithCompletion:^(BOOL success, NSString *output, NSError *error) {
        if (generation != self.operationGeneration) {
            return;
        }
        if (!success) {
            [self finishOperation:generation status:@"Dependency installation failed."];
            self.statusLabel.textColor = [NSColor systemRedColor];
            [self setLogText:[self messageForError:error output:output]];
            return;
        }
        [self validateAfterInstallForGeneration:generation pipOutput:output];
    }];
}

- (void)checkEnvironment:(id)sender
{
    [self validateCurrentEnvironment];
}

- (void)installSSHpass:(id)sender
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    if (manager.sshpassPath.length == 0 && manager.homebrewPath.length == 0) {
        NSURL *homebrewURL = [NSURL URLWithString:@"https://brew.sh/"];
        if (homebrewURL != nil) {
            [[NSWorkspace sharedWorkspace] openURL:homebrewURL];
        }
        [self refreshSystemDependencyStatus];
        self.systemDependencyLabel.toolTip = @"Cerebro opened the official Homebrew installation page. After installing Homebrew, return here and click Install sshpass.";
        return;
    }

    [manager ensureSSHpassInstalledWithCompletion:nil];
    [self refreshSystemDependencyStatus];
}

- (void)runtimeDidChange:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshFromRuntimeAndValidate:NO];
    });
}

- (void)systemDependenciesDidChange:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshSystemDependencyStatus];
    });
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self refreshSystemDependencyStatus];
}

@end
