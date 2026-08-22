//
//  ROBPythonSettingsWindowController.m
//  Cerebro
//

#import "ROBPythonSettingsWindowController.h"
#import "ROBMainViewController.h"
#import "ROBSerialBox.h"
#import "ROBPythonRuntime.h"
#import "ROBSystemDependencyManager.h"
#import "ROBSpeechBox.h"
#import "Cerebro-Swift.h"

@interface ROBPythonSettingsWindowController () <NSTextFieldDelegate, NSTextViewDelegate>
@property (nonatomic, strong) NSTextField *pythonPathField;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextView *logTextView;
@property (nonatomic, strong) NSProgressIndicator *progressIndicator;
@property (nonatomic, strong) NSTextField *systemDependencyLabel;
@property (nonatomic, strong) NSPopUpButton *systemPackageManagerPopup;
@property (nonatomic, strong) NSButton *installSSHpassButton;
@property (nonatomic, strong) NSPopUpButton *englishVoicePopup;
@property (nonatomic, strong) NSPopUpButton *japaneseVoicePopup;
@property (nonatomic, strong) NSPopUpButton *spanishVoicePopup;
@property (nonatomic, strong) NSPopUpButton *chineseVoicePopup;
@property (nonatomic, strong) NSTextView *acknowledgementPhrasesTextView;
@property (nonatomic, strong) NSButton *messagesBridgeEnabledToggle;
@property (nonatomic, strong) NSButton *messagesAllowAllSendersToggle;
@property (nonatomic, strong) NSButton *messagesAllowImagesToggle;
@property (nonatomic, strong) NSButton *messagesAllowGeminiImagesToggle;
@property (nonatomic, strong) NSButton *messagesArchiveToggle;
@property (nonatomic, strong) NSButton *messagesViewTranscriptButton;
@property (nonatomic, strong) NSButton *messagesExportTranscriptButton;
@property (nonatomic, strong) NSButton *messagesClearTranscriptButton;
@property (nonatomic, strong) NSTextField *messagesReceivingAccountField;
@property (nonatomic, strong) NSTextView *messagesAllowedSendersTextView;
@property (nonatomic, strong) NSButton *requestMessagesAutomationPermissionButton;
@property (nonatomic, strong) NSButton *requestMusicAutomationPermissionButton;
@property (nonatomic, strong) NSButton *openFullDiskAccessSettingsButton;
@property (nonatomic, strong) NSButton *openAutomationSettingsButton;
@property (nonatomic, strong) NSPopUpButton *baseSerialPopup;
@property (nonatomic, strong) NSPopUpButton *maestroSerialPopup;
@property (nonatomic, strong) NSTextField *baseSerialStatusLabel;
@property (nonatomic, strong) NSTextField *maestroSerialStatusLabel;
@property (nonatomic, strong) NSButton *openBaseConsoleButton;
@property (nonatomic, strong) NSButton *reconnectMaestroButton;
@property (nonatomic, weak) ROBSerialBox *boundSerialBox;
@property (nonatomic, strong) NSArray<NSButton *> *actionButtons;
@property (nonatomic, strong) NSTabView *settingsTabView;
@property (nonatomic, strong) NSTabViewItem *geminiSettingsTab;
@property (nonatomic, strong) NSTabViewItem *insta360SettingsTab;
@property (nonatomic, strong) ROBInsta360ProcessingSettingsViewController *insta360SettingsViewController;
@property (nonatomic, assign) NSUInteger operationGeneration;
@property (nonatomic, assign) BOOL operationInProgress;
- (BOOL)requireAppliedPythonSelection;
- (void)applyPythonSelectionAtPath:(NSString *)selection;
- (void)refreshControlAvailability;
- (void)refreshSystemDependencyStatus;
- (ROBSystemPackageManager)selectedSystemPackageManager;
- (void)updateSSHpassActionAccessibility;
- (void)validateAfterInstallForGeneration:(NSUInteger)generation pipOutput:(NSString *)pipOutput;
- (ROBMainViewController *)mainViewControllerInViewController:(NSViewController *)viewController;
- (void)refreshVoicePopups;
- (void)refreshAcknowledgementPhrasesTextView;
- (void)refreshMessagesSettings;
- (void)refreshSerialHardwareSettings;
- (void)updateSerialHardwareStatus;
- (ROBMainViewController *)activeMainViewController;
- (void)attachGeminiSettingsViewController;
- (void)openPrivacySettings:(NSString *)sectionName;
- (void)openFullDiskAccessSettings:(id)sender;
- (void)openAutomationSettings:(id)sender;
- (void)requestMessagesAutomationPermission:(id)sender;
- (void)requestMusicAutomationPermission:(id)sender;
- (void)handleAutomationPermissionRequest:(nullable NSString *)error
                              forTarget:(NSString *)friendlyName;
@end

@implementation ROBPythonSettingsWindowController

- (instancetype)init
{
    NSRect frame = NSMakeRect(0, 0, 720, 640);
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
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(speechVoicesDidChange:)
                                                     name:AVSpeechSynthesisAvailableVoicesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(serialHardwareDidChange:)
                                                     name:ROBSerialHardwareDidChangeNotification
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
    NSView *windowContentView = self.window.contentView;
    NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSInsetRect(windowContentView.bounds, 12.0, 12.0)];
    tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [windowContentView addSubview:tabView];
    self.settingsTabView = tabView;

    NSTabViewItem *runtimeTab = [NSTabViewItem tabViewItemWithViewController:[[NSViewController alloc] init]];
    runtimeTab.label = @"Runtime";
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 580)];
    runtimeTab.view = contentView;
    [tabView addTabViewItem:runtimeTab];

    self.geminiSettingsTab = [NSTabViewItem
        tabViewItemWithViewController:[[NSViewController alloc] init]];
    self.geminiSettingsTab.label = @"Gemini";
    NSView *geminiPlaceholderView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 580)];
    NSTextField *geminiPlaceholderLabel = [self labelWithString:
        @"Open Cerebro's main robot window to configure Gemini."
        frame:NSMakeRect(24, 530, 632, 28)];
    geminiPlaceholderLabel.textColor = NSColor.secondaryLabelColor;
    [geminiPlaceholderView addSubview:geminiPlaceholderLabel];
    self.geminiSettingsTab.view = geminiPlaceholderView;
    [tabView addTabViewItem:self.geminiSettingsTab];

    NSTabViewItem *controllersTab = [NSTabViewItem tabViewItemWithViewController:[[NSViewController alloc] init]];
    controllersTab.label = @"Controllers";
    NSView *controllersView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 580)];
    controllersTab.view = controllersView;
    [tabView addTabViewItem:controllersTab];

    NSTabViewItem *hardwareTab = [NSTabViewItem tabViewItemWithViewController:[[NSViewController alloc] init]];
    hardwareTab.label = @"Hardware";
    NSView *hardwareView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 580)];
    hardwareTab.view = hardwareView;
    [tabView addTabViewItem:hardwareTab];

    NSTabViewItem *speechTab = [NSTabViewItem tabViewItemWithViewController:[[NSViewController alloc] init]];
    speechTab.label = @"Speech";
    NSView *speechView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 580)];
    speechTab.view = speechView;
    [tabView addTabViewItem:speechTab];

    NSTabViewItem *messagesTab = [NSTabViewItem tabViewItemWithViewController:[[NSViewController alloc] init]];
    messagesTab.label = @"Messages";
    NSView *messagesView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 580)];
    messagesTab.view = messagesView;
    [tabView addTabViewItem:messagesTab];

    self.insta360SettingsViewController = [[ROBInsta360ProcessingSettingsViewController alloc] init];
    self.insta360SettingsTab = [NSTabViewItem
        tabViewItemWithViewController:self.insta360SettingsViewController];
    self.insta360SettingsTab.label = @"Perception";
    [tabView addTabViewItem:self.insta360SettingsTab];

    NSTextField *speechHeading = [self labelWithString:@"ROB Voice Preferences"
                                                  frame:NSMakeRect(24, 530, 632, 28)];
    speechHeading.font = [NSFont boldSystemFontOfSize:20.0];
    [speechView addSubview:speechHeading];

    NSTextField *speechExplanation = [self labelWithString:
        @"Cerebro detects English, Spanish, Japanese, and Chinese replies automatically. Choose the exact installed voice ROB should use for each language; changes apply immediately and persist across restarts."
        frame:NSMakeRect(24, 476, 632, 48)];
    speechExplanation.textColor = [NSColor secondaryLabelColor];
    [speechView addSubview:speechExplanation];

    [speechView addSubview:[self labelWithString:@"English voice:"
                                             frame:NSMakeRect(24, 446, 632, 20)]];
    self.englishVoicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 410, 500, 32)
                                                        pullsDown:NO];
    self.englishVoicePopup.target = self;
    self.englishVoicePopup.action = @selector(voiceSelectionChanged:);
    self.englishVoicePopup.accessibilityLabel = @"English speech voice";
    [speechView addSubview:self.englishVoicePopup];

    [speechView addSubview:[self labelWithString:@"Spanish voice:"
                                             frame:NSMakeRect(24, 378, 632, 20)]];
    self.spanishVoicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 342, 500, 32)
                                                        pullsDown:NO];
    self.spanishVoicePopup.target = self;
    self.spanishVoicePopup.action = @selector(voiceSelectionChanged:);
    self.spanishVoicePopup.accessibilityLabel = @"Spanish speech voice";
    [speechView addSubview:self.spanishVoicePopup];

    [speechView addSubview:[self labelWithString:@"Japanese voice:"
                                             frame:NSMakeRect(24, 310, 632, 20)]];
    self.japaneseVoicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 274, 500, 32)
                                                         pullsDown:NO];
    self.japaneseVoicePopup.target = self;
    self.japaneseVoicePopup.action = @selector(voiceSelectionChanged:);
    self.japaneseVoicePopup.accessibilityLabel = @"Japanese speech voice";
    [speechView addSubview:self.japaneseVoicePopup];

    [speechView addSubview:[self labelWithString:@"Chinese voice (Mandarin or Cantonese):"
                                             frame:NSMakeRect(24, 242, 632, 20)]];
    self.chineseVoicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 206, 500, 32)
                                                        pullsDown:NO];
    self.chineseVoicePopup.target = self;
    self.chineseVoicePopup.action = @selector(voiceSelectionChanged:);
    self.chineseVoicePopup.accessibilityLabel = @"Chinese speech voice";
    [speechView addSubview:self.chineseVoicePopup];

    NSTextField *downloadHelp = [self labelWithString:
        @"Premium and Enhanced voices are listed first after you download them in System Settings → Accessibility → Spoken Content → System Voice. Cerebro preserves your exact installed choice and falls back safely if that voice is later removed."
        frame:NSMakeRect(24, 142, 632, 52)];
    downloadHelp.textColor = [NSColor secondaryLabelColor];
    [speechView addSubview:downloadHelp];

    [speechView addSubview:[self labelWithString:
        @"Acknowledgement phrases — one per line; ROB chooses randomly (empty uses “I hear you.”):"
        frame:NSMakeRect(24, 112, 632, 20)]];
    NSScrollView *acknowledgementScrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(24, 20, 632, 84)];
    acknowledgementScrollView.borderType = NSBezelBorder;
    acknowledgementScrollView.hasVerticalScroller = YES;
    acknowledgementScrollView.autohidesScrollers = YES;
    acknowledgementScrollView.drawsBackground = YES;
    self.acknowledgementPhrasesTextView = [[NSTextView alloc]
        initWithFrame:acknowledgementScrollView.contentView.bounds];
    self.acknowledgementPhrasesTextView.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
    self.acknowledgementPhrasesTextView.textColor = NSColor.labelColor;
    self.acknowledgementPhrasesTextView.backgroundColor = NSColor.textBackgroundColor;
    self.acknowledgementPhrasesTextView.textContainerInset = NSMakeSize(5, 5);
    self.acknowledgementPhrasesTextView.richText = NO;
    self.acknowledgementPhrasesTextView.allowsUndo = YES;
    self.acknowledgementPhrasesTextView.verticallyResizable = YES;
    self.acknowledgementPhrasesTextView.horizontallyResizable = NO;
    self.acknowledgementPhrasesTextView.autoresizingMask = NSViewWidthSizable;
    self.acknowledgementPhrasesTextView.textContainer.widthTracksTextView = YES;
    self.acknowledgementPhrasesTextView.delegate = self;
    self.acknowledgementPhrasesTextView.accessibilityLabel = @"ROB acknowledgement phrases";
    self.acknowledgementPhrasesTextView.accessibilityIdentifier = @"ROB.AcknowledgementPhrases";
    self.acknowledgementPhrasesTextView.accessibilityHelp =
        @"Enter one acknowledgement per line. ROB chooses a different phrase at random when possible. Leave every line blank to use I hear you.";
    acknowledgementScrollView.documentView = self.acknowledgementPhrasesTextView;
    [speechView addSubview:acknowledgementScrollView];
    [self refreshVoicePopups];
    [self refreshAcknowledgementPhrasesTextView];

    NSTextField *messagesHeading = [self labelWithString:@"ROB Messages Replies"
                                                    frame:NSMakeRect(24, 530, 632, 28)];
    messagesHeading.font = [NSFont boldSystemFontOfSize:20.0];
    [messagesView addSubview:messagesHeading];

    NSTextField *messagesExplanation = [self labelWithString:
        @"Approved one-to-one text and optional still images use isolated AI sessions. Images can remain local or be explicitly allowed for Gemini. Read-only publisher news and weather lookup are available; robot, music, file, and action tools are not. Replies return only to the originating chat, and ROB never speaks them."
        frame:NSMakeRect(24, 472, 632, 50)];
    messagesExplanation.textColor = [NSColor secondaryLabelColor];
    [messagesView addSubview:messagesExplanation];

    self.messagesBridgeEnabledToggle = [NSButton
        checkboxWithTitle:@"Enable replies received by ROB in Messages"
                   target:self
                   action:@selector(messagesBridgeEnabledChanged:)];
    self.messagesBridgeEnabledToggle.frame = NSMakeRect(24, 438, 632, 28);
    self.messagesBridgeEnabledToggle.accessibilityIdentifier = @"ROB.MessagesBridge.Enabled";
    self.messagesBridgeEnabledToggle.accessibilityHelp =
        @"The bridge remains fail-closed until a receiving account and at least one approved sender are configured.";
    [messagesView addSubview:self.messagesBridgeEnabledToggle];

    self.messagesAllowAllSendersToggle = [NSButton
        checkboxWithTitle:@"Allow messages from any sender (Maker Faire public mode)"
                   target:self
                   action:@selector(messagesAllowAllSendersChanged:)];
    self.messagesAllowAllSendersToggle.frame = NSMakeRect(24, 410, 632, 28);
    self.messagesAllowAllSendersToggle.accessibilityIdentifier = @"ROB.MessagesBridge.AllowAllSenders";
    self.messagesAllowAllSendersToggle.accessibilityHelp =
        @"Allows any sender to text ROB while online and receive replies, overriding the approved senders list.";
    [messagesView addSubview:self.messagesAllowAllSendersToggle];

    self.messagesAllowImagesToggle = [NSButton
        checkboxWithTitle:@"Allow one image from approved Messages senders"
                   target:self
                   action:@selector(messagesAllowImagesChanged:)];
    self.messagesAllowImagesToggle.frame = NSMakeRect(24, 382, 632, 28);
    self.messagesAllowImagesToggle.accessibilityIdentifier = @"ROB.MessagesBridge.AllowImages";
    self.messagesAllowImagesToggle.accessibilityHelp =
        @"Accept one bounded JPEG, PNG, or HEIC image from an otherwise authorized one-to-one Messages chat.";
    [messagesView addSubview:self.messagesAllowImagesToggle];

    self.messagesAllowGeminiImagesToggle = [NSButton
        checkboxWithTitle:@"Allow approved images to be sent to Gemini"
                   target:self
                   action:@selector(messagesAllowGeminiImagesChanged:)];
    self.messagesAllowGeminiImagesToggle.frame = NSMakeRect(24, 354, 632, 28);
    self.messagesAllowGeminiImagesToggle.accessibilityIdentifier = @"ROB.MessagesBridge.AllowGeminiImages";
    self.messagesAllowGeminiImagesToggle.accessibilityHelp =
        @"When enabled, approved Messages images may leave this Mac for Gemini analysis. Otherwise Cerebro uses only Swift MLX followed by Apple Foundation Models.";
    [messagesView addSubview:self.messagesAllowGeminiImagesToggle];

    self.messagesArchiveToggle = [NSButton
        checkboxWithTitle:@"Store encrypted transcript memory"
                   target:self
                   action:@selector(messagesArchiveChanged:)];
    self.messagesArchiveToggle.frame = NSMakeRect(24, 326, 298, 28);
    self.messagesArchiveToggle.accessibilityIdentifier = @"ROB.MessagesBridge.Archive";
    self.messagesArchiveToggle.accessibilityHelp =
        @"Stores accepted Messages transactions in Cerebro's encrypted archive and supplies bounded excerpts only to that same sender's future replies.";
    [messagesView addSubview:self.messagesArchiveToggle];
    self.messagesViewTranscriptButton = [self buttonWithTitle:@"View Transcripts…"
                                                        frame:NSMakeRect(330, 326, 142, 28)
                                                       action:@selector(showMessagesTranscripts:)];
    self.messagesViewTranscriptButton.accessibilityIdentifier = @"ROB.MessagesBridge.ViewTranscripts";
    self.messagesViewTranscriptButton.toolTip =
        @"Open a searchable, locally decrypted view of archived Messages conversations.";
    [messagesView addSubview:self.messagesViewTranscriptButton];
    self.messagesExportTranscriptButton = [self buttonWithTitle:@"Export…"
                                                          frame:NSMakeRect(480, 326, 80, 28)
                                                         action:@selector(exportMessagesTranscript:)];
    self.messagesExportTranscriptButton.accessibilityIdentifier = @"ROB.MessagesBridge.ExportTranscript";
    self.messagesExportTranscriptButton.toolTip =
        @"Export the encrypted archive as a plaintext JSON file at a location you choose.";
    [messagesView addSubview:self.messagesExportTranscriptButton];
    self.messagesClearTranscriptButton = [self buttonWithTitle:@"Clear…"
                                                         frame:NSMakeRect(568, 326, 88, 28)
                                                        action:@selector(clearMessagesTranscript:)];
    self.messagesClearTranscriptButton.accessibilityIdentifier = @"ROB.MessagesBridge.ClearTranscript";
    self.messagesClearTranscriptButton.toolTip =
        @"Permanently delete all stored Messages transcript transactions.";
    [messagesView addSubview:self.messagesClearTranscriptButton];

    [messagesView addSubview:[self labelWithString:@"Local receiving Messages account:"
                                               frame:NSMakeRect(24, 298, 632, 20)]];
    self.messagesReceivingAccountField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(24, 264, 500, 28)];
    self.messagesReceivingAccountField.placeholderString = @"rob@orbitusrobotics.com";
    self.messagesReceivingAccountField.delegate = self;
    self.messagesReceivingAccountField.accessibilityLabel = @"ROB receiving Messages account";
    self.messagesReceivingAccountField.accessibilityIdentifier = @"ROB.MessagesBridge.Account";
    self.messagesReceivingAccountField.accessibilityHelp =
        @"Enter the exact local Messages account on this Mac that receives conversations intended for ROB. This is the destination account, not an allowed remote sender.";
    [messagesView addSubview:self.messagesReceivingAccountField];

    [messagesView addSubview:[self labelWithString:
        @"Approved senders — one exact Messages handle (email or phone) per line (required):"
        frame:NSMakeRect(24, 235, 632, 20)]];
    NSScrollView *allowedSendersScrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(24, 155, 632, 72)];
    allowedSendersScrollView.borderType = NSBezelBorder;
    allowedSendersScrollView.hasVerticalScroller = YES;
    allowedSendersScrollView.autohidesScrollers = YES;
    allowedSendersScrollView.drawsBackground = YES;
    self.messagesAllowedSendersTextView = [[NSTextView alloc]
        initWithFrame:allowedSendersScrollView.contentView.bounds];
    self.messagesAllowedSendersTextView.font = [NSFont monospacedSystemFontOfSize:12.0
                                                                         weight:NSFontWeightRegular];
    self.messagesAllowedSendersTextView.textColor = NSColor.labelColor;
    self.messagesAllowedSendersTextView.backgroundColor = NSColor.textBackgroundColor;
    self.messagesAllowedSendersTextView.textContainerInset = NSMakeSize(5, 5);
    self.messagesAllowedSendersTextView.richText = NO;
    self.messagesAllowedSendersTextView.allowsUndo = YES;
    self.messagesAllowedSendersTextView.verticallyResizable = YES;
    self.messagesAllowedSendersTextView.horizontallyResizable = NO;
    self.messagesAllowedSendersTextView.autoresizingMask = NSViewWidthSizable;
    self.messagesAllowedSendersTextView.textContainer.widthTracksTextView = YES;
    self.messagesAllowedSendersTextView.delegate = self;
    self.messagesAllowedSendersTextView.accessibilityLabel = @"Approved Messages senders";
    self.messagesAllowedSendersTextView.accessibilityIdentifier = @"ROB.MessagesBridge.AllowedSenders";
    self.messagesAllowedSendersTextView.accessibilityHelp =
        @"Enter each sender's exact Messages handle as shown in contact information, one per line. Messages from all other senders and every group chat are ignored.";
    allowedSendersScrollView.documentView = self.messagesAllowedSendersTextView;
    [messagesView addSubview:allowedSendersScrollView];

    NSBox *messagesPermissionsBox = [[NSBox alloc] initWithFrame:NSMakeRect(24, 10, 632, 145)];
    messagesPermissionsBox.title = @"Required macOS Permissions";
    [messagesView addSubview:messagesPermissionsBox];
    NSTextField *messagesPermissions = [self labelWithString:
        @"Inbound: add Cerebro in System Settings → Privacy & Security → Full Disk Access, then restart Cerebro so it can read the local Messages inbox.\n\nOutbound: allow Cerebro to control Messages under Privacy & Security → Automation when macOS prompts on the first reply. The receiving account must also be signed in and enabled in Messages."
        frame:NSMakeRect(14, 88, 604, 44)];
    messagesPermissions.textColor = [NSColor secondaryLabelColor];
    messagesPermissions.selectable = YES;
    [messagesPermissionsBox.contentView addSubview:messagesPermissions];
    self.openFullDiskAccessSettingsButton = [self buttonWithTitle:@"Open Full Disk Access Settings"
                                                          frame:NSMakeRect(14, 54, 250, 28)
                                                         action:@selector(openFullDiskAccessSettings:)];
    self.openFullDiskAccessSettingsButton.toolTip = @"Open System Settings → Privacy & Security → Full Disk Access.";
    self.openAutomationSettingsButton = [self buttonWithTitle:@"Open Automation Settings"
                                                      frame:NSMakeRect(276, 54, 250, 28)
                                                     action:@selector(openAutomationSettings:)];
    self.openAutomationSettingsButton.toolTip = @"Open System Settings → Privacy & Security → Automation.";
    [messagesPermissionsBox.contentView addSubview:self.openFullDiskAccessSettingsButton];
    [messagesPermissionsBox.contentView addSubview:self.openAutomationSettingsButton];
    self.requestMessagesAutomationPermissionButton = [self buttonWithTitle:@"Request Messages Automation Access"
                                                                   frame:NSMakeRect(14, 19, 250, 28)
                                                                  action:@selector(requestMessagesAutomationPermission:)];
    self.requestMessagesAutomationPermissionButton.toolTip =
        @"Check Cerebro's current Messages Automation authorization and request macOS consent when it has not been decided.";
    self.requestMusicAutomationPermissionButton = [self buttonWithTitle:@"Request Music Automation Access"
                                                                frame:NSMakeRect(276, 19, 250, 28)
                                                               action:@selector(requestMusicAutomationPermission:)];
    self.requestMusicAutomationPermissionButton.toolTip =
        @"Run a lightweight Music AppleScript call to trigger the local automation permission prompt.";
    [messagesPermissionsBox.contentView addSubview:self.requestMessagesAutomationPermissionButton];
    [messagesPermissionsBox.contentView addSubview:self.requestMusicAutomationPermissionButton];
    [self refreshMessagesSettings];

    NSTextField *hardwareHeading = [self labelWithString:@"Robot USB Hardware"
                                                    frame:NSMakeRect(24, 530, 632, 28)];
    hardwareHeading.font = [NSFont boldSystemFontOfSize:20.0];
    [hardwareView addSubview:hardwareHeading];

    NSTextField *hardwareExplanation = [self labelWithString:
        @"Cerebro discovers and reconnects these devices automatically at startup. These controls show the live choices away from the main robot workspace; Base retains a supervised manual USB override for diagnostics."
        frame:NSMakeRect(24, 474, 632, 48)];
    hardwareExplanation.textColor = NSColor.secondaryLabelColor;
    [hardwareView addSubview:hardwareExplanation];

    NSBox *baseBox = [[NSBox alloc] initWithFrame:NSMakeRect(24, 286, 632, 170)];
    baseBox.title = @"Base Arduino";
    [hardwareView addSubview:baseBox];
    [baseBox.contentView addSubview:[self labelWithString:@"Base USB selection:"
                                                      frame:NSMakeRect(16, 111, 600, 20)]];
    self.baseSerialPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(14, 74, 470, 30)
            pullsDown:NO];
    self.baseSerialPopup.target = self;
    self.baseSerialPopup.action = @selector(baseSerialSelectionChanged:);
    self.baseSerialPopup.accessibilityLabel = @"Base USB selection";
    self.baseSerialPopup.accessibilityIdentifier = @"ROB.Hardware.BaseUSB";
    self.baseSerialPopup.toolTip = @"Cerebro selects the verified Base automatically. Choosing a USB port here is a supervised diagnostic override.";
    [baseBox.contentView addSubview:self.baseSerialPopup];
    self.baseSerialStatusLabel = [self labelWithString:@"Waiting for the robot runtime…"
                                                  frame:NSMakeRect(16, 49, 600, 18)];
    self.baseSerialStatusLabel.textColor = NSColor.secondaryLabelColor;
    self.baseSerialStatusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [baseBox.contentView addSubview:self.baseSerialStatusLabel];
    self.openBaseConsoleButton = [self buttonWithTitle:@"Open Base Console…"
                                                  frame:NSMakeRect(12, 8, 190, 34)
                                                 action:@selector(openBaseSerialConsole:)];
    self.openBaseConsoleButton.accessibilityIdentifier = @"ROB.Hardware.OpenBaseConsole";
    self.openBaseConsoleButton.accessibilityHelp =
        @"Open optional live Base serial output and command controls in a separate window.";
    [baseBox.contentView addSubview:self.openBaseConsoleButton];

    NSBox *maestroBox = [[NSBox alloc] initWithFrame:NSMakeRect(24, 105, 632, 160)];
    maestroBox.title = @"Pololu Maestro";
    [hardwareView addSubview:maestroBox];
    [maestroBox.contentView addSubview:[self labelWithString:@"Maestro USB selection (automatic):"
                                                         frame:NSMakeRect(16, 101, 600, 20)]];
    self.maestroSerialPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(14, 64, 470, 30)
            pullsDown:NO];
    self.maestroSerialPopup.enabled = NO;
    self.maestroSerialPopup.accessibilityLabel = @"Maestro USB automatic selection";
    self.maestroSerialPopup.accessibilityIdentifier = @"ROB.Hardware.MaestroUSB";
    self.maestroSerialPopup.toolTip =
        @"Cerebro accepts only a USB device verified as a Pololu Maestro command interface.";
    [maestroBox.contentView addSubview:self.maestroSerialPopup];
    self.maestroSerialStatusLabel = [self labelWithString:@"Waiting for the robot runtime…"
                                                     frame:NSMakeRect(16, 39, 600, 18)];
    self.maestroSerialStatusLabel.textColor = NSColor.secondaryLabelColor;
    self.maestroSerialStatusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [maestroBox.contentView addSubview:self.maestroSerialStatusLabel];
    self.reconnectMaestroButton = [self buttonWithTitle:@"Retry Maestro Discovery"
                                                   frame:NSMakeRect(12, 0, 190, 34)
                                                  action:@selector(reconnectMaestro:)];
    self.reconnectMaestroButton.accessibilityIdentifier = @"ROB.Hardware.RetryMaestro";
    [maestroBox.contentView addSubview:self.reconnectMaestroButton];

    NSTextField *consoleNote = [self labelWithString:
        @"The Base console is opt-in: output is rendered only while its window is open. Closing the console never stops telemetry, safety parsing, or automatic USB operation."
        frame:NSMakeRect(24, 44, 632, 44)];
    consoleNote.textColor = NSColor.secondaryLabelColor;
    [hardwareView addSubview:consoleNote];
    [self refreshSerialHardwareSettings];

    NSTextField *controllersHeading = [self labelWithString:@"Paired Control Devices"
                                                       frame:NSMakeRect(24, 530, 632, 28)];
    controllersHeading.font = [NSFont boldSystemFontOfSize:20.0];
    [controllersView addSubview:controllersHeading];

    NSTextField *controllersExplanation = [self labelWithString:
        @"Manage the devices authorized to send remote control commands to ROB. Pair a new controller, review active pairings, or revoke a device that should no longer have access."
        frame:NSMakeRect(24, 470, 632, 48)];
    controllersExplanation.textColor = [NSColor secondaryLabelColor];
    [controllersView addSubview:controllersExplanation];

    NSBox *pairingBox = [[NSBox alloc] initWithFrame:NSMakeRect(24, 350, 632, 100)];
    pairingBox.title = @"Controller Pairing";
    [controllersView addSubview:pairingBox];

    NSButton *managePairingButton = [self buttonWithTitle:@"Manage Paired Devices…"
                                                    frame:NSMakeRect(18, 36, 220, 34)
                                                   action:@selector(managePairedDevices:)];
    managePairingButton.accessibilityHelp = @"Open pairing codes and manage controllers authorized to control ROB.";
    [pairingBox.contentView addSubview:managePairingButton];

    NSTextField *heading = [self labelWithString:@"Python Environment" frame:NSMakeRect(24, 530, 632, 28)];
    heading.font = [NSFont boldSystemFontOfSize:20.0];
    [contentView addSubview:heading];

    NSTextField *explanation = [self labelWithString:
        @"Cerebro uses this interpreter for the DepthAI webcam service and bundled Amber arm scripts. Choose an existing virtualenv/Conda environment, or create a Cerebro-managed environment."
        frame:NSMakeRect(24, 478, 632, 44)];
    explanation.textColor = [NSColor secondaryLabelColor];
    [contentView addSubview:explanation];

    [contentView addSubview:[self labelWithString:@"Python executable or environment directory:"
                                             frame:NSMakeRect(24, 450, 632, 20)]];

    self.pythonPathField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 414, 492, 28)];
    self.pythonPathField.placeholderString = @"/path/to/environment/bin/python3";
    self.pythonPathField.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    [contentView addSubview:self.pythonPathField];

    NSButton *chooseButton = [self buttonWithTitle:@"Choose…"
                                             frame:NSMakeRect(528, 412, 128, 32)
                                            action:@selector(choosePython:)];
    [contentView addSubview:chooseButton];

    NSButton *applyButton = [self buttonWithTitle:@"Use Selected Python"
                                            frame:NSMakeRect(20, 366, 174, 34)
                                           action:@selector(applySelection:)];
    NSButton *detectButton = [self buttonWithTitle:@"Use Auto-Detected"
                                             frame:NSMakeRect(198, 366, 164, 34)
                                            action:@selector(useAutoDetectedPython:)];
    NSButton *managedButton = [self buttonWithTitle:@"Create Managed Environment + Install"
                                              frame:NSMakeRect(366, 366, 294, 34)
                                             action:@selector(createManagedEnvironment:)];
    [contentView addSubview:applyButton];
    [contentView addSubview:detectButton];
    [contentView addSubview:managedButton];

    self.statusLabel = [self labelWithString:@"Checking environment…" frame:NSMakeRect(24, 330, 632, 22)];
    self.statusLabel.font = [NSFont boldSystemFontOfSize:13.0];
    [contentView addSubview:self.statusLabel];

    NSScrollView *logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 196, 632, 126)];
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
    NSTextField *packageLabel = [self labelWithString:packageText frame:NSMakeRect(24, 168, 632, 20)];
    packageLabel.textColor = [NSColor secondaryLabelColor];
    [contentView addSubview:packageLabel];

    NSTextField *systemToolsHeading = [self labelWithString:@"System Tools"
                                                      frame:NSMakeRect(24, 106, 632, 18)];
    systemToolsHeading.font = [NSFont boldSystemFontOfSize:13.0];
    [contentView addSubview:systemToolsHeading];

    self.systemDependencyLabel = [self labelWithString:@"Checking system tools…"
                                                  frame:NSMakeRect(24, 68, 632, 36)];
    self.systemDependencyLabel.textColor = [NSColor secondaryLabelColor];
    self.systemDependencyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.systemDependencyLabel.maximumNumberOfLines = 2;
    self.systemDependencyLabel.selectable = YES;
    self.systemDependencyLabel.accessibilityLabel = @"sshpass status";
    [contentView addSubview:self.systemDependencyLabel];

    NSButton *installButton = [self buttonWithTitle:@"Install Python Packages"
                                              frame:NSMakeRect(20, 128, 210, 34)
                                             action:@selector(installDependencies:)];
    NSButton *checkButton = [self buttonWithTitle:@"Check Python"
                                            frame:NSMakeRect(234, 128, 150, 34)
                                            action:@selector(checkEnvironment:)];

    NSTextField *packageManagerLabel = [self labelWithString:@"Install sshpass with:"
                                                       frame:NSMakeRect(24, 36, 118, 20)];
    [contentView addSubview:packageManagerLabel];
    self.systemPackageManagerPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(144, 28, 172, 30)
            pullsDown:NO];
    [self.systemPackageManagerPopup addItemWithTitle:@"Homebrew"];
    self.systemPackageManagerPopup.lastItem.tag = ROBSystemPackageManagerHomebrew;
    [self.systemPackageManagerPopup addItemWithTitle:@"MacPorts"];
    self.systemPackageManagerPopup.lastItem.tag = ROBSystemPackageManagerMacPorts;
    self.systemPackageManagerPopup.target = self;
    self.systemPackageManagerPopup.action = @selector(systemPackageManagerChanged:);
    self.systemPackageManagerPopup.accessibilityLabel = @"Package manager for installing sshpass";
    [self.systemPackageManagerPopup selectItemWithTag:
        [ROBSystemDependencyManager sharedManager].preferredPackageManager];
    [contentView addSubview:self.systemPackageManagerPopup];

    self.installSSHpassButton = [self buttonWithTitle:@"Install sshpass"
                                                frame:NSMakeRect(324, 26, 286, 34)
                                               action:@selector(installSSHpass:)];
    self.installSSHpassButton.accessibilityLabel = @"Install or recheck sshpass";
    [contentView addSubview:installButton];
    [contentView addSubview:checkButton];
    [contentView addSubview:self.installSSHpassButton];

    self.progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(628, 34, 20, 20)];
    self.progressIndicator.style = NSProgressIndicatorStyleSpinning;
    self.progressIndicator.displayedWhenStopped = NO;
    [contentView addSubview:self.progressIndicator];

    self.actionButtons = @[chooseButton, applyButton, detectButton, managedButton,
                           installButton, checkButton, self.installSSHpassButton];
    [self refreshFromRuntimeAndValidate:NO];
    [self refreshSystemDependencyStatus];
}

- (void)showGeminiSettings:(id)sender
{
    [self showWindow:sender];
    [self.settingsTabView selectTabViewItem:self.geminiSettingsTab];
    ROBGeminiSettingsViewController *settingsViewController =
        (ROBGeminiSettingsViewController *)self.geminiSettingsTab.viewController;
    if ([settingsViewController isKindOfClass:[ROBGeminiSettingsViewController class]]) {
        [settingsViewController refreshSettings];
    }
}

- (void)showInsta360Settings:(id)sender
{
    [self showWindow:sender];
    [self.insta360SettingsViewController refreshSettings];
    [self.settingsTabView selectTabViewItem:self.insta360SettingsTab];
}

- (void)attachGeminiSettingsViewController
{
    ROBMainViewController *mainViewController = [self activeMainViewController];
    NSViewController *settingsViewController =
        [mainViewController geminiProviderSettingsViewController];
    if (settingsViewController != nil &&
        self.geminiSettingsTab.viewController != settingsViewController) {
        self.geminiSettingsTab.viewController = settingsViewController;
    }
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

- (ROBMainViewController *)activeMainViewController
{
    for (NSWindow *window in NSApp.windows) {
        ROBMainViewController *mainViewController =
            [self mainViewControllerInViewController:window.contentViewController];
        if (mainViewController != nil) {
            return mainViewController;
        }
    }
    return nil;
}

- (void)refreshSerialHardwareSettings
{
    ROBSerialBox *serialBox = [self activeMainViewController].serialBox;
    if (self.boundSerialBox != serialBox) {
        if (self.boundSerialBox.serialListPullDown_base == self.baseSerialPopup) {
            self.boundSerialBox.serialListPullDown_base = nil;
        }
        if (self.boundSerialBox.serialListPullDown_maestro == self.maestroSerialPopup) {
            self.boundSerialBox.serialListPullDown_maestro = nil;
        }
        self.boundSerialBox = serialBox;
    }

    BOOL available = serialBox != nil;
    self.baseSerialPopup.enabled = available;
    self.openBaseConsoleButton.enabled = available;
    self.reconnectMaestroButton.enabled = available;
    if (!available) {
        [self.baseSerialPopup removeAllItems];
        [self.baseSerialPopup addItemWithTitle:@"Robot runtime unavailable"];
        [self.maestroSerialPopup removeAllItems];
        [self.maestroSerialPopup addItemWithTitle:@"Robot runtime unavailable"];
        self.baseSerialStatusLabel.stringValue = @"Open Cerebro's main robot window to manage Base USB.";
        self.maestroSerialStatusLabel.stringValue = @"Open Cerebro's main robot window to view Maestro USB.";
        return;
    }

    serialBox.serialListPullDown_base = self.baseSerialPopup;
    serialBox.serialListPullDown_maestro = self.maestroSerialPopup;
    [serialBox refreshSerialPortControls];
    [self updateSerialHardwareStatus];
}

- (void)updateSerialHardwareStatus
{
    ROBSerialBox *serialBox = self.boundSerialBox;
    if (serialBox == nil) {
        return;
    }
    self.baseSerialStatusLabel.stringValue = [NSString stringWithFormat:@"Automatic status: %@",
        serialBox.baseSerialStatusText ?: @"unknown"];
    self.maestroSerialStatusLabel.stringValue = [NSString stringWithFormat:@"Verified automatic status: %@",
        serialBox.maestroSerialStatusText ?: @"unknown"];
}

- (void)serialHardwareDidChange:(NSNotification *)notification
{
    if (notification.object != self.boundSerialBox) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateSerialHardwareStatus];
    });
}

- (void)baseSerialSelectionChanged:(NSPopUpButton *)sender
{
    if (self.boundSerialBox == nil) {
        NSBeep();
        return;
    }
    [self.boundSerialBox selectBaseSerialPort:sender.titleOfSelectedItem];
}

- (void)reconnectMaestro:(id)sender
{
    if (self.boundSerialBox == nil) {
        NSBeep();
        return;
    }
    [self.boundSerialBox connectMaestro];
}

- (void)openBaseSerialConsole:(id)sender
{
    ROBMainViewController *mainViewController = [self activeMainViewController];
    if (mainViewController == nil || mainViewController.serialBox == nil) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Base console is unavailable";
        alert.informativeText = @"Open Cerebro's main robot window, then try again.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    [mainViewController showBaseSerialConsole:sender];
}

- (IBAction)managePairedDevices:(id)sender
{
    for (NSWindow *window in NSApp.windows) {
        ROBMainViewController *mainViewController =
            [self mainViewControllerInViewController:window.contentViewController];
        if (mainViewController != nil) {
            [mainViewController showControlPairingCode:sender];
            return;
        }
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Controller pairing is unavailable";
    alert.informativeText = @"Open Cerebro's main robot window, then try managing paired devices again.";
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)showWindow:(id)sender
{
    [self attachGeminiSettingsViewController];
    [super showWindow:sender];
    [self.window makeKeyAndOrderFront:sender];
    [[ROBSystemDependencyManager sharedManager] refreshSSHpassAvailability];
    [self refreshSystemDependencyStatus];
    [self refreshFromRuntimeAndValidate:!self.operationInProgress];
    [self refreshVoicePopups];
    [self refreshAcknowledgementPhrasesTextView];
    [self refreshMessagesSettings];
    [self refreshSerialHardwareSettings];
}

- (NSString *)qualityNameForVoice:(AVSpeechSynthesisVoice *)voice
{
    if (voice.quality == AVSpeechSynthesisVoiceQualityPremium) { return @"Premium"; }
    if (voice.quality == AVSpeechSynthesisVoiceQualityEnhanced) { return @"Enhanced"; }
    return @"Default";
}

- (AVSpeechSynthesisVoice *)bestInstalledVoiceForLanguage:(NSString *)language
{
    AVSpeechSynthesisVoice *bestVoice = [AVSpeechSynthesisVoice voiceWithLanguage:language];
    if (![bestVoice.language isEqualToString:language]) {
        bestVoice = nil;
    }
    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        if (![voice.language isEqualToString:language]) { continue; }
        if (bestVoice == nil || voice.quality > bestVoice.quality) {
            bestVoice = voice;
        }
    }
    return bestVoice;
}

- (NSArray<AVSpeechSynthesisVoice *> *)voicesWithLanguagePrefixes:(NSArray<NSString *> *)prefixes
{
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(AVSpeechSynthesisVoice *voice, NSDictionary *bindings) {
        for (NSString *prefix in prefixes) {
            if ([voice.language hasPrefix:prefix]) { return YES; }
        }
        return NO;
    }];
    NSArray<AVSpeechSynthesisVoice *> *voices = [AVSpeechSynthesisVoice.speechVoices filteredArrayUsingPredicate:predicate];
    return [voices sortedArrayUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *left, AVSpeechSynthesisVoice *right) {
        if (left.quality != right.quality) {
            return left.quality > right.quality ? NSOrderedAscending : NSOrderedDescending;
        }
        NSComparisonResult languageOrder =
            [left.language localizedCaseInsensitiveCompare:right.language];
        if (languageOrder != NSOrderedSame) { return languageOrder; }
        return [left.name localizedCaseInsensitiveCompare:right.name];
    }];
}

- (void)populateVoicePopup:(NSPopUpButton *)popup
          languagePrefixes:(NSArray<NSString *> *)prefixes
          preferredLanguage:(NSString *)preferredLanguage
               defaultsKey:(NSString *)defaultsKey
{
    [popup removeAllItems];
    NSArray<AVSpeechSynthesisVoice *> *voices = [self voicesWithLanguagePrefixes:prefixes];
    for (AVSpeechSynthesisVoice *voice in voices) {
        NSString *title = [NSString stringWithFormat:@"%@ — %@ (%@)",
                           voice.name, [self qualityNameForVoice:voice], voice.language];
        [popup addItemWithTitle:title];
        popup.lastItem.representedObject = voice.identifier;
    }
    popup.enabled = voices.count > 0;
    if (voices.count == 0) {
        [popup addItemWithTitle:@"No installed voice available"];
        return;
    }

    NSString *savedIdentifier = [[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey];
    NSInteger savedIndex = [popup indexOfItemWithRepresentedObject:savedIdentifier];
    if (savedIndex < 0 && [defaultsKey isEqualToString:ROBEnglishVoiceIdentifierDefaultsKey]) {
        savedIndex = [popup indexOfItemWithRepresentedObject:@"com.apple.voice.enhanced.en-GB.Oliver"];
    }
    if (savedIndex < 0) {
        AVSpeechSynthesisVoice *preferredVoice =
            [self bestInstalledVoiceForLanguage:preferredLanguage];
        savedIndex = [popup indexOfItemWithRepresentedObject:preferredVoice.identifier];
    }
    [popup selectItemAtIndex:savedIndex >= 0 ? savedIndex : 0];
}

- (void)refreshVoicePopups
{
    [self populateVoicePopup:self.englishVoicePopup
            languagePrefixes:@[@"en-"]
            preferredLanguage:@"en-GB"
                 defaultsKey:ROBEnglishVoiceIdentifierDefaultsKey];
    [self populateVoicePopup:self.spanishVoicePopup
            languagePrefixes:@[@"es-"]
            preferredLanguage:@"es-ES"
                 defaultsKey:ROBSpanishVoiceIdentifierDefaultsKey];
    [self populateVoicePopup:self.japaneseVoicePopup
            languagePrefixes:@[@"ja-"]
            preferredLanguage:@"ja-JP"
                 defaultsKey:ROBJapaneseVoiceIdentifierDefaultsKey];
    [self populateVoicePopup:self.chineseVoicePopup
            languagePrefixes:@[@"zh-", @"yue-"]
            preferredLanguage:@"zh-CN"
                 defaultsKey:ROBChineseVoiceIdentifierDefaultsKey];
}

- (void)refreshAcknowledgementPhrasesTextView
{
    self.acknowledgementPhrasesTextView.string =
        [ROBResolvedSpeechAcknowledgementPhrases() componentsJoinedByString:@"\n"];
}

- (void)refreshMessagesSettings
{
    self.messagesBridgeEnabledToggle.state = [ROBMessagesBridge configuredEnabled]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.messagesAllowAllSendersToggle.state = [ROBMessagesBridge configuredAllowAllSenders]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.messagesAllowImagesToggle.state = [ROBMessagesBridge configuredAllowsImages]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.messagesAllowGeminiImagesToggle.state = [ROBMessagesBridge configuredAllowsGeminiImages]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.messagesArchiveToggle.state = [ROBMessagesBridge configuredArchivesTranscripts]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.messagesAllowGeminiImagesToggle.enabled =
        self.messagesAllowImagesToggle.state == NSControlStateValueOn;
    self.messagesReceivingAccountField.stringValue =
        [ROBMessagesBridge configuredAccountIdentifier] ?: @"rob@orbitusrobotics.com";
    self.messagesAllowedSendersTextView.string =
        [ROBMessagesBridge configuredAllowedSendersText] ?: @"";
}

- (BOOL)messagesAllowlistContainsSender
{
    NSString *value = self.messagesAllowedSendersTextView.string ?: @"";
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\n\r,"];
    for (NSString *candidate in [value componentsSeparatedByCharactersInSet:separators]) {
        NSString *trimmed = [candidate
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) {
            return YES;
        }
    }
    return NO;
}

- (void)messagesBridgeEnabledChanged:(NSButton *)sender
{
    // Commit an in-progress account or allowlist edit before evaluating the
    // fail-closed enable requirement. Editing does not repeatedly restart the
    // bridge on every keystroke.
    [self.window makeFirstResponder:nil];
    BOOL shouldEnable = sender.state == NSControlStateValueOn;
    if (shouldEnable && ![ROBMessagesBridge configuredAllowAllSenders] && ![self messagesAllowlistContainsSender]) {
        sender.state = NSControlStateValueOff;
        [ROBMessagesBridge setConfiguredEnabled:NO];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Add an approved Messages sender first";
        alert.informativeText =
            @"ROB will not read or answer Messages until at least one exact sender email address or phone number is listed, or unless you enable 'Allow messages from any sender'.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    [ROBMessagesBridge setConfiguredEnabled:shouldEnable];
    if (shouldEnable) {
        [self requestMessagesAutomationPermission:self.requestMessagesAutomationPermissionButton];
    }
}

- (void)messagesAllowAllSendersChanged:(NSButton *)sender
{
    BOOL allowAll = sender.state == NSControlStateValueOn;
    if (!allowAll) {
        [ROBMessagesBridge setConfiguredAllowAllSenders:NO];
        if ([ROBMessagesBridge configuredEnabled] && ![self messagesAllowlistContainsSender]) {
            [ROBMessagesBridge setConfiguredEnabled:NO];
            self.messagesBridgeEnabledToggle.state = NSControlStateValueOff;
        }
        return;
    }

    // Keep the persisted setting fail-closed until the operator explicitly
    // acknowledges that every one-to-one sender can consume AI resources and
    // provide text to the isolated Messages responder.
    sender.state = NSControlStateValueOff;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"Allow Messages from anyone?";
    alert.informativeText =
        @"Public mode lets any one-to-one sender reaching ROB's Messages account submit text to the AI and receive replies. This can create abuse, cost, and privacy exposure. Enable it only while the account is actively supervised.";
    [alert addButtonWithTitle:@"Allow Any Sender"];
    [alert addButtonWithTitle:@"Cancel"];

    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        BOOL confirmed = returnCode == NSAlertFirstButtonReturn;
        strongSelf.messagesAllowAllSendersToggle.state = confirmed
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        [ROBMessagesBridge setConfiguredAllowAllSenders:confirmed];
    }];
}

- (void)messagesAllowImagesChanged:(NSButton *)sender
{
    BOOL enabled = sender.state == NSControlStateValueOn;
    [ROBMessagesBridge setConfiguredAllowsImages:enabled];
    self.messagesAllowGeminiImagesToggle.enabled = enabled;
    if (!enabled) {
        self.messagesAllowGeminiImagesToggle.state = NSControlStateValueOff;
    }
}

- (void)messagesAllowGeminiImagesChanged:(NSButton *)sender
{
    if (sender.state != NSControlStateValueOn) {
        [ROBMessagesBridge setConfiguredAllowsGeminiImages:NO];
        return;
    }
    if (![ROBMessagesBridge configuredAllowsImages]) {
        sender.state = NSControlStateValueOff;
        [ROBMessagesBridge setConfiguredAllowsGeminiImages:NO];
        return;
    }

    sender.state = NSControlStateValueOff;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"Send approved Messages images to Gemini?";
    alert.informativeText =
        @"An image accepted from an approved sender will leave this Mac and be processed by Gemini. If you keep this off, Cerebro uses the on-device Swift MLX vision model and passes only its text analysis to Apple Foundation Models.";
    [alert addButtonWithTitle:@"Allow Gemini Images"];
    [alert addButtonWithTitle:@"Keep Images Local"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        BOOL confirmed = response == NSAlertFirstButtonReturn;
        strongSelf.messagesAllowGeminiImagesToggle.state = confirmed
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        [ROBMessagesBridge setConfiguredAllowsGeminiImages:confirmed];
    }];
}

- (void)messagesArchiveChanged:(NSButton *)sender
{
    if (sender.state != NSControlStateValueOn) {
        [ROBMessagesBridge setConfiguredArchivesTranscripts:NO];
        return;
    }

    sender.state = NSControlStateValueOff;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"Keep an encrypted Messages transcript?";
    alert.informativeText =
        @"Cerebro will retain accepted inbound messages and generated replies until you clear the archive. Text and identifying metadata are AES-GCM encrypted with a key kept in this Mac's login Keychain; image pixels are never stored. Only excerpts for the exact same sender and receiving account are used as memory. When Gemini answers, relevant excerpts may be sent to Gemini. A manual export is plaintext.";
    [alert addButtonWithTitle:@"Enable Encrypted Archive"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        BOOL confirmed = response == NSAlertFirstButtonReturn;
        strongSelf.messagesArchiveToggle.state = confirmed
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        [ROBMessagesBridge setConfiguredArchivesTranscripts:confirmed];
    }];
}

- (void)showMessagesTranscripts:(id)sender
{
    [ROBMessagesTranscriptWindowController showMessagesTranscriptWindow:sender];
}

- (void)exportMessagesTranscript:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"Cerebro-Messages-Transcript.json";
    panel.canCreateDirectories = YES;
    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || panel.URL == nil) { return; }
        NSString *error = [ROBMessagesBridge exportMessagesTranscriptTo:panel.URL];
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (error.length == 0) {
            [strongSelf setLogText:[NSString stringWithFormat:
                @"Exported plaintext Messages transcript to %@", panel.URL.path]];
            return;
        }
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleCritical;
        alert.messageText = @"Messages transcript export failed";
        alert.informativeText = error;
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:strongSelf.window completionHandler:nil];
    }];
}

- (void)clearMessagesTranscript:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"Permanently clear the Messages archive?";
    alert.informativeText =
        @"This deletes every stored Messages transaction and removes that history from future AI replies. This cannot be undone unless you previously made a plaintext export.";
    [alert addButtonWithTitle:@"Clear Archive"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) { return; }
        NSString *error = [ROBMessagesBridge deleteMessagesTranscript];
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (error.length == 0) {
            [strongSelf setLogText:@"Cleared the encrypted Messages transcript archive."];
            return;
        }
        NSAlert *failure = [[NSAlert alloc] init];
        failure.alertStyle = NSAlertStyleCritical;
        failure.messageText = @"Messages transcript could not be cleared";
        failure.informativeText = error;
        [failure addButtonWithTitle:@"OK"];
        [failure beginSheetModalForWindow:strongSelf.window completionHandler:nil];
    }];
}

- (void)openPrivacySettings:(NSString *)sectionName
{
    NSString *urlString = [NSString stringWithFormat:
        @"x-apple.systempreferences:com.apple.preference.security?%@",
        sectionName
    ];
    NSString *extensionURL = [NSString stringWithFormat:
        @"x-apple.systempreferences:com.apple.preference.security.extension?%@",
        sectionName
    ];
    NSArray<NSString *> *candidates = @[
        [NSString stringWithFormat:
            @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?%@", sectionName],
        @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        urlString,
        extensionURL
    ];

    for (NSString *candidate in candidates) {
        NSURL *settingsURL = [NSURL URLWithString:candidate];
        if (settingsURL == nil) {
            continue;
        }
        if ([[NSWorkspace sharedWorkspace] openURL:settingsURL]) {
            [self setLogText:
                @"Opening System Settings for privacy permissions. Grant the requested access and return here."];
            return;
        }
    }

    if (urlString.length == 0) {
        [self setLogText:@"Unable to open the requested System Settings pane."];
    } else {
        [self setLogText:@"Unable to open System Settings Privacy & Security pane."];
    }
}

- (void)openFullDiskAccessSettings:(id)sender
{
    [self openPrivacySettings:@"Privacy_AllFiles"];
}

- (void)openAutomationSettings:(id)sender
{
    [self openPrivacySettings:@"Privacy_Automation"];
}

- (void)handleAutomationPermissionRequest:(NSString *)error
                              forTarget:(NSString *)friendlyName
{
    BOOL granted = error.length == 0;
    if (granted) {
        [self setLogText:[NSString stringWithFormat:
            @"%@ automation permission is currently granted.",
            friendlyName]];
    } else {
        [self setLogText:[NSString stringWithFormat:
            @"%@ automation permission is not granted yet: %@",
            friendlyName,
            error]];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = granted ? NSAlertStyleInformational : NSAlertStyleWarning;
    alert.messageText = granted
        ? [NSString stringWithFormat:@"%@ Automation Access Granted", friendlyName]
        : [NSString stringWithFormat:@"%@ Automation Access Required", friendlyName];
    alert.informativeText = granted
        ? [NSString stringWithFormat:
            @"Cerebro is authorized to control %@ for automated replies.",
            friendlyName]
        : (error.length > 0
            ? error
            : [NSString stringWithFormat:
                @"Enable Cerebro → %@ in System Settings → Privacy & Security → Automation.",
                friendlyName]);
    [alert addButtonWithTitle:granted ? @"OK" : @"Open Automation Settings"];
    if (!granted) {
        [alert addButtonWithTitle:@"Cancel"];
    }

    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (!granted && response == NSAlertFirstButtonReturn) {
            [weakSelf openAutomationSettings:weakSelf];
        }
    }];
}

- (void)requestMessagesAutomationPermission:(id)sender
{
    NSButton *button = [sender isKindOfClass:NSButton.class]
        ? (NSButton *)sender
        : self.requestMessagesAutomationPermissionButton;
    button.enabled = NO;
    [self setLogText:@"Checking Messages Automation permission…"];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = [ROBMessagesBridge requestMessagesAutomationPermission];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            button.enabled = YES;
            [strongSelf handleAutomationPermissionRequest:error forTarget:@"Messages"];
            if (error.length == 0) {
                [[ROBMessagesBridge shared] reloadConfiguration];
            }
        });
    });
}

- (void)requestMusicAutomationPermission:(id)sender
{
    [self handleAutomationPermissionRequest:[ROBAppleMusicPermissions requestAutomationPermission]
                                  forTarget:@"Music"];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
    if (notification.object == self.messagesReceivingAccountField) {
        [ROBMessagesBridge setConfiguredAccountIdentifier:
            self.messagesReceivingAccountField.stringValue ?: @""];
        self.messagesReceivingAccountField.stringValue =
            [ROBMessagesBridge configuredAccountIdentifier] ?: @"rob@orbitusrobotics.com";
    }
}

- (void)textDidChange:(NSNotification *)notification
{
    if (notification.object == self.messagesAllowedSendersTextView) {
        return;
    }
    if (notification.object != self.acknowledgementPhrasesTextView) {
        return;
    }
    NSString *value = self.acknowledgementPhrasesTextView.string ?: @"";
    NSString *trimmed = [value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (trimmed.length > 0) {
        [defaults setObject:value forKey:ROBSpeechAcknowledgementPhraseDefaultsKey];
    } else {
        [defaults removeObjectForKey:ROBSpeechAcknowledgementPhraseDefaultsKey];
    }
}

- (void)textDidEndEditing:(NSNotification *)notification
{
    if (notification.object == self.acknowledgementPhrasesTextView) {
        [self refreshAcknowledgementPhrasesTextView];
    } else if (notification.object == self.messagesAllowedSendersTextView) {
        [ROBMessagesBridge setConfiguredAllowedSendersText:
            self.messagesAllowedSendersTextView.string ?: @""];
        self.messagesAllowedSendersTextView.string =
            [ROBMessagesBridge configuredAllowedSendersText] ?: @"";
    }
}

- (void)voiceSelectionChanged:(NSPopUpButton *)sender
{
    NSString *defaultsKey = ROBEnglishVoiceIdentifierDefaultsKey;
    if (sender == self.spanishVoicePopup) {
        defaultsKey = ROBSpanishVoiceIdentifierDefaultsKey;
    } else if (sender == self.japaneseVoicePopup) {
        defaultsKey = ROBJapaneseVoiceIdentifierDefaultsKey;
    } else if (sender == self.chineseVoicePopup) {
        defaultsKey = ROBChineseVoiceIdentifierDefaultsKey;
    }
    NSString *identifier = sender.selectedItem.representedObject;
    if (identifier.length == 0) { return; }
    [[NSUserDefaults standardUserDefaults] setObject:identifier forKey:defaultsKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:ROBSpeechVoicePreferencesDidChangeNotification
                                                        object:self];
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
    self.systemPackageManagerPopup.enabled = !self.operationInProgress && !manager.isInstallingSSHpass;
    self.pythonPathField.enabled = !self.operationInProgress;
    if (self.operationInProgress || manager.isInstallingSSHpass) {
        self.progressIndicator.accessibilityLabel = manager.isInstallingSSHpass
            ? [NSString stringWithFormat:@"Installing sshpass with %@",
                ROBSystemPackageManagerDisplayName(manager.installingPackageManager)]
            : @"Python environment operation in progress";
        [self.progressIndicator startAnimation:nil];
    } else {
        [self.progressIndicator stopAnimation:nil];
    }
}

- (ROBSystemPackageManager)selectedSystemPackageManager
{
    NSInteger selectedTag = self.systemPackageManagerPopup.selectedTag;
    if (selectedTag == ROBSystemPackageManagerHomebrew ||
        selectedTag == ROBSystemPackageManagerMacPorts) {
        return (ROBSystemPackageManager)selectedTag;
    }
    return [ROBSystemDependencyManager sharedManager].preferredPackageManager;
}

- (void)updateSSHpassActionAccessibility
{
    self.installSSHpassButton.accessibilityLabel = self.installSSHpassButton.title;
    self.installSSHpassButton.accessibilityHelp =
        self.systemDependencyLabel.toolTip ?: self.systemDependencyLabel.stringValue;
}

- (void)refreshSystemDependencyStatus
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    [self refreshControlAvailability];
    ROBSystemPackageManager selectedManager = [self selectedSystemPackageManager];
    NSString *managerName = ROBSystemPackageManagerDisplayName(selectedManager);
    NSString *managerPath = [manager pathForPackageManager:selectedManager];
    self.systemPackageManagerPopup.accessibilityHelp = managerPath.length > 0
        ? [NSString stringWithFormat:@"%@ detected at %@", managerName, managerPath]
        : [NSString stringWithFormat:@"%@ is not currently available", managerName];
    NSString *sshpassPath = manager.sshpassPath;
    if (sshpassPath.length > 0) {
        self.systemDependencyLabel.stringValue =
            [NSString stringWithFormat:@"System tool: sshpass ready — %@", sshpassPath];
        self.systemDependencyLabel.textColor = [NSColor systemGreenColor];
        self.systemDependencyLabel.toolTip = sshpassPath;
        self.installSSHpassButton.title = @"Recheck sshpass";
        [self updateSSHpassActionAccessibility];
        return;
    }
    if (manager.isInstallingSSHpass) {
        NSString *installingName = ROBSystemPackageManagerDisplayName(manager.installingPackageManager);
        self.systemDependencyLabel.stringValue =
            [NSString stringWithFormat:@"System tool: installing sshpass with %@…", installingName];
        self.systemDependencyLabel.textColor = [NSColor systemOrangeColor];
        self.systemDependencyLabel.toolTip = nil;
        self.installSSHpassButton.title = @"Installing sshpass…";
        [self updateSSHpassActionAccessibility];
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
        [self updateSSHpassActionAccessibility];
        return;
    }
    if (managerPath.length == 0) {
        NSError *validationError = selectedManager == ROBSystemPackageManagerMacPorts
            ? manager.macPortsValidationError
            : nil;
        self.systemDependencyLabel.stringValue = validationError != nil
            ? @"System tool: the MacPorts installation failed security validation."
            : [NSString stringWithFormat:@"System tool: sshpass missing — %@ is not installed.", managerName];
        self.systemDependencyLabel.textColor = [NSColor systemRedColor];
        self.systemDependencyLabel.toolTip = validationError != nil
            ? [self messageForError:validationError
                             output:validationError.userInfo[@"commandOutput"] ?: @""]
            : manager.lastSSHpassError.localizedDescription;
        self.installSSHpassButton.title = validationError != nil
            ? @"Open MacPorts Repair Help…"
            : [NSString stringWithFormat:@"Get %@…", managerName];
    } else {
        BOOL externalAuthorization =
            [manager requiresExternalAuthorizationForPackageManager:selectedManager];
        self.systemDependencyLabel.stringValue = externalAuthorization
            ? [NSString stringWithFormat:@"System tool: sshpass missing — %@ command is ready.", managerName]
            : [NSString stringWithFormat:@"System tool: sshpass missing — %@ install is available.", managerName];
        self.systemDependencyLabel.textColor = [NSColor systemOrangeColor];
        self.systemDependencyLabel.toolTip =
            [manager sshpassInstallCommandForPackageManager:selectedManager];
        self.installSSHpassButton.title = externalAuthorization
            ? [NSString stringWithFormat:@"Install with %@ in Terminal…", managerName]
            : [NSString stringWithFormat:@"Install with %@…", managerName];
    }
    [self updateSSHpassActionAccessibility];
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

- (void)systemPackageManagerChanged:(id)sender
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    ROBSystemPackageManager selectedManager = [self selectedSystemPackageManager];
    manager.preferredPackageManager = selectedManager;
    [self refreshSystemDependencyStatus];

    NSString *managerName = ROBSystemPackageManagerDisplayName(selectedManager);
    NSString *managerPath = [manager pathForPackageManager:selectedManager];
    NSString *message = managerPath.length > 0
        ? [NSString stringWithFormat:@"Selected %@ at %@ for sshpass installation.", managerName, managerPath]
        : [NSString stringWithFormat:@"Selected %@. Install it first, then return to Cerebro Settings.", managerName];
    [self setLogText:message];
}

- (void)installSSHpass:(id)sender
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    if (manager.sshpassPath.length > 0) {
        [self refreshSystemDependencyStatus];
        [self setLogText:[NSString stringWithFormat:@"sshpass is ready at %@", manager.sshpassPath]];
        return;
    }

    ROBSystemPackageManager selectedManager = [self selectedSystemPackageManager];
    manager.preferredPackageManager = selectedManager;
    NSString *managerName = ROBSystemPackageManagerDisplayName(selectedManager);
    NSString *managerPath = [manager pathForPackageManager:selectedManager];
    if (managerPath.length == 0) {
        NSError *validationError = selectedManager == ROBSystemPackageManagerMacPorts
            ? manager.macPortsValidationError
            : nil;
        NSString *URLString = selectedManager == ROBSystemPackageManagerMacPorts
            ? @"https://www.macports.org/install.php"
            : @"https://brew.sh/";
        NSURL *installationURL = [NSURL URLWithString:URLString];
        if (installationURL != nil) {
            [[NSWorkspace sharedWorkspace] openURL:installationURL];
        }
        [self refreshSystemDependencyStatus];
        NSString *message = validationError != nil
            ? [self messageForError:validationError
                             output:validationError.userInfo[@"commandOutput"] ?: @""]
            : [NSString stringWithFormat:
                @"Cerebro opened the official %@ installation page. Cerebro will not install the package manager itself. After installing %@, return here and install sshpass.",
                managerName, managerName];
        self.systemDependencyLabel.toolTip = message;
        [self setLogText:message];
        return;
    }

    NSString *command = [manager sshpassInstallCommandForPackageManager:selectedManager
                                                          executablePath:managerPath];
    if (command.length == 0) {
        [self setLogText:[NSString stringWithFormat:@"Cerebro could not construct the %@ installation command.", managerName]];
        return;
    }

    BOOL externalAuthorization =
        [manager requiresExternalAuthorizationForPackageManager:selectedManager];
    NSAlert *confirmation = [[NSAlert alloc] init];
    confirmation.alertStyle = NSAlertStyleInformational;
    confirmation.messageText = [NSString stringWithFormat:@"Install sshpass with %@?", managerName];
    confirmation.informativeText = externalAuthorization
        ? [NSString stringWithFormat:
            @"MacPorts normally requires administrator authorization. Cerebro will copy this command and open Terminal; paste it there and macOS will request authorization. Cerebro never receives the administrator password.\n\n%@",
            command]
        : [NSString stringWithFormat:
            @"Cerebro will run this command only after you confirm:\n\n%@",
            command];
    [confirmation addButtonWithTitle:externalAuthorization
        ? @"Copy Command and Open Terminal"
        : @"Install"];
    [confirmation addButtonWithTitle:@"Cancel"];

    [confirmation beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }

        if (externalAuthorization) {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard setString:command forType:NSPasteboardTypeString];

            NSArray<NSString *> *terminalPaths = @[
                @"/System/Applications/Utilities/Terminal.app",
                @"/Applications/Utilities/Terminal.app"
            ];
            NSString *terminalPath = nil;
            for (NSString *candidate in terminalPaths) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                    terminalPath = candidate;
                    break;
                }
            }
            BOOL openedTerminal = terminalPath.length > 0 &&
                [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:terminalPath]];
            NSString *result = openedTerminal
                ? [NSString stringWithFormat:@"Copied to the clipboard and opened Terminal:\n\n%@\n\nPaste the command, press Return, and return to Cerebro when MacPorts finishes. Cerebro will recheck sshpass when it becomes active.", command]
                : [NSString stringWithFormat:@"Copied to the clipboard. Open Terminal and run:\n\n%@\n\nReturn to Cerebro when MacPorts finishes.", command];
            [self setLogText:result];
            self.systemDependencyLabel.toolTip = result;
            return;
        }

        [self setLogText:[NSString stringWithFormat:@"Running:\n\n%@", command]];
        [manager installSSHpassWithPackageManager:selectedManager
                           expectedExecutablePath:managerPath
                                       completion:^(BOOL success, NSString *output, NSError *error) {
            [self refreshSystemDependencyStatus];
            [self setLogText:success ? output : [self messageForError:error output:output]];
        }];
        [self refreshSystemDependencyStatus];
    }];
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
    [[ROBSystemDependencyManager sharedManager] refreshSSHpassAvailability];
    [self refreshSystemDependencyStatus];
    [self refreshVoicePopups];
    [self refreshSerialHardwareSettings];
}

- (void)speechVoicesDidChange:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshVoicePopups];
    });
}

@end
