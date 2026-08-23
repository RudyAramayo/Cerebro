//
//  GameViewController.m
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//
#import "AppDelegate.h"
#import "ROBMainViewController.h"
#import "ROBSerialBox.h"
#import "ROBBaseSerialConsoleWindowController.h"
#import "ROBBaseControllerModel.h"
#import "ROBSpeechBox.h"
#import "ROBKeyboardControlsViewController.h"
#import "ROBTorsoControlsViewController.h"
#import "ROBSCNViewController.h"

#import "ROBNiTEManager.h"
#import "ROBConsciousness.h"
#import "SimpleUserTrackerTaskController.h"
#import "AudioInputTaskController.h"
#import "JoinWifiTaskController.h"

#import <Vision/Vision.h>
#import <math.h>


#define kMaxFollowingSpeed 50
#define kMAXFOLLOWDISTANCE 1100
#define kTrackingMidpointX -200
#define kTrackingMidpointY 200

static NSTimeInterval const kRobotActionControllerFreshnessSeconds = 3.5;
static NSTimeInterval const kRobotActionApprovalLifetimeSeconds = 30.0;
static NSTimeInterval const kRobotActionExecutionLifetimeSeconds = 60.0;
static NSString * const ROBDevelopmentModeDefaultsKey = @"ROBDevelopmentMode";
static NSString * const ROBShowControllerInputDiagnosticsNotification = @"ROBShowControllerInputDiagnostics";
static NSString * const ROBDevelopmentModeDidChangeNotification = @"ROBDevelopmentModeDidChange";
static NSString * const ROBGeminiVideoSourceSettingsDidChangeNotification = @"ROBGeminiVideoSourceSettingsDidChange";

#import "AVFoundation/AVFoundation.h"
#import "Cerebro-Swift.h"

@implementation ROBAlignedDepthFrame

- (instancetype)initWithMillimetersLittleEndian:(NSData *)millimetersLittleEndian
                                          width:(NSUInteger)width
                                         height:(NSUInteger)height
                                       sequence:(uint64_t)sequence
                           timestampNanoseconds:(uint64_t)timestampNanoseconds
{
    self = [super init];
    if (self) {
        _millimetersLittleEndian = [millimetersLittleEndian copy];
        _width = width;
        _height = height;
        _sequence = sequence;
        _timestampNanoseconds = timestampNanoseconds;
    }
    return self;
}

@end

@interface ROBConversationMessage : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) BOOL fromUser;
@property (nonatomic, strong) NSDate *date;
@end

@implementation ROBConversationMessage
@end

static const NSUInteger ROBConversationLogMaximumMessages = 300;
static const NSTimeInterval ROBConversationLogRetentionInterval = 7 * 24 * 60 * 60;
static const CGFloat ROBConversationBubbleHorizontalTextInset = 16.0;
// The old -3pt baseline adjustment moved glyphs without moving selection.
// Moving the whole label down 8pt preserves selection geometry and places
// the text another 5pt lower while leaving the rounded bubble fixed.
static const CGFloat ROBConversationBubbleTextDownshift = 8.0;

@interface ROBConversationBubbleView : NSTableCellView
@property (nonatomic, strong) NSTextField *senderLabel;
@property (nonatomic, strong) NSView *bubbleBackgroundView;
@property (nonatomic, strong) NSTextField *bubbleLabel;
@property (nonatomic, assign) BOOL fromUser;
@end

@implementation ROBConversationBubbleView

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.senderLabel = [NSTextField labelWithString:@""];
        self.senderLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        self.senderLabel.textColor = NSColor.secondaryLabelColor;
        self.bubbleBackgroundView = [[NSView alloc] initWithFrame:NSZeroRect];
        self.bubbleBackgroundView.wantsLayer = YES;
        self.bubbleBackgroundView.layer.cornerRadius = 14;
        self.bubbleBackgroundView.layer.masksToBounds = YES;
        [self.bubbleBackgroundView setAccessibilityElement:NO];
        self.bubbleLabel = [NSTextField wrappingLabelWithString:@""];
        self.bubbleLabel.font = [NSFont systemFontOfSize:14];
        self.bubbleLabel.selectable = YES;
        self.bubbleLabel.maximumNumberOfLines = 0;
        self.bubbleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.bubbleLabel.cell.wraps = YES;
        self.bubbleLabel.cell.scrollable = NO;
        self.bubbleLabel.drawsBackground = NO;
        [self addSubview:self.bubbleBackgroundView];
        [self addSubview:self.senderLabel];
        [self.bubbleBackgroundView addSubview:self.bubbleLabel];
    }
    return self;
}

- (void)layout
{
    [super layout];
    CGFloat availableWidth = MAX(180, NSWidth(self.bounds) - 28);
    CGFloat bubbleWidth = MIN(availableWidth * 0.78, 430);
    CGFloat x = self.fromUser ? NSWidth(self.bounds) - bubbleWidth - 14 : 14;
    self.senderLabel.alignment = self.fromUser ? NSTextAlignmentRight : NSTextAlignmentLeft;
    self.senderLabel.frame = NSMakeRect(x + 4, NSHeight(self.bounds) - 21, bubbleWidth - 8, 16);
    NSRect bubbleFrame = NSMakeRect(x, 6, bubbleWidth, MAX(34, NSHeight(self.bounds) - 29));
    self.bubbleBackgroundView.frame = bubbleFrame;
    NSRect textFrame = NSInsetRect(self.bubbleBackgroundView.bounds,
                                   ROBConversationBubbleHorizontalTextInset,
                                   0);
    textFrame.origin.y += self.bubbleBackgroundView.isFlipped
        ? ROBConversationBubbleTextDownshift
        : -ROBConversationBubbleTextDownshift;
    self.bubbleLabel.frame = textFrame;
}

@end


@interface ROBMainViewController () <HumanTrackingDelegate, TrackingDelegate, AutoNetServerDataDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, ROBAIDelegate, ROBAutonomyCoordinatorDelegate, ROBStageShowCoordinatorDelegate, ROBGeminiRuntimeControlDelegate>

@property (readwrite, retain) ROBSCNViewController *scnViewController;
@property (readwrite, retain) NSWindowController *controllerDiagnosticsWindowController;
@property (readwrite, retain) NSTimer *niteHeartbeatTimer;

@property (readwrite, retain) IBOutlet SCNView *robo_scnView;
@property (readwrite, retain) NSWindowController *controlsWindowController;
@property (readwrite, retain) NSWindowController *torsoControlsWindowController;
@property (readwrite, retain) ROBTorsoControlsViewController *torsoControlsViewController;

@property (readwrite, retain) NSWindowController *cameraWindowController;
@property (readwrite, retain) CameraViewController *cameraViewController;
@property (readwrite, retain) ROBBellyCameraWindowController *bellyCameraWindowController;
@property (readwrite, retain) ROBBaseSerialConsoleWindowController *baseSerialConsoleWindowController;
@property (atomic, readwrite, strong) ROBAlignedDepthFrame *latestAlignedDepthFrame;

@property (readwrite, retain) NSWindowController *tastsWindowController;
@property (readwrite, retain) NSTimer *speechResponseAttentionTimer;

@property (readwrite, retain) AutoNetServer *autoNetServer;
@property (readwrite, retain) ROBAI *robAI;
@property (readwrite, retain) ROBGeminiSettingsViewController *geminiSettingsViewController;
@property (readwrite, retain) ROBInsta360DiagnosticsWindowController *insta360DiagnosticsWindowController;
@property (readwrite, retain) ROBMessagesWorkspaceViewController *messagesWorkspaceViewController;
@property (readwrite, retain) ROBSystemStatusCoordinator *systemStatusCoordinator;
@property (readwrite, retain) ROBStageShowWindowController *stageShowWindowController;
@property (readwrite, retain) ROBStageShowCoordinator *stageShowCoordinator;
@property (readwrite, retain) ROBAutonomyCoordinator *autonomyCoordinator;
@property (readwrite, assign) NSUInteger saberChoreographyGeneration;
- (void)speakConfiguredAcknowledgementIfNotQueued;
- (void)publishControlAuthorityState;
- (void)ensureMainCameraRuntime;
- (void)synchronizeDevelopmentCameraDiagnostics;
- (void)mainCameraDiagnosticsWindowWillClose:(NSNotification *)notification;
- (void)executeSaberTransforms:(NSArray<ROBSaberTransform *> *)transforms
                         index:(NSUInteger)index
                    generation:(NSUInteger)generation
                   coordinator:(ROBStageShowCoordinator *)coordinator;

// Gemini proposes high-level actions. Normal actions continue through
// ROBController approval. An accepted play_gesture is executed once by
// Cerebro's deterministic Amber executor; the short-lived local arm-debug
// grant remains a separate no-controller development path. Both accept only
// immutable operator-approved named poses.
@property (readwrite, copy) NSString *robotActionSenderID;
@property (readwrite, copy) NSString *robotActionControllerID;
@property (readwrite, retain) NSDate *robotActionControllerLastSeen;
@property (readwrite, assign) BOOL robotActionControllerAcceptsActions;
@property (readwrite, copy) NSArray<NSString *> *robotActionControllerCapabilities;
@property (readwrite, retain) NSMutableDictionary<NSString *, ROBAIRobotToolCall *> *pendingRobotToolCalls;
@property (readwrite, retain) NSMutableDictionary<NSString *, ROBRobotActionMessage *> *pendingRobotActionRequests;
@property (readwrite, retain) NSMutableDictionary<NSString *, ROBRobotActionMessage *> *pendingRobotActionCancellations;
@property (readwrite, retain) NSMutableDictionary<NSString *, NSDate *> *robotActionExecutionDeadlines;
@property (readwrite, retain) NSMutableSet<NSString *> *geminiCancellingRobotToolCallIDs;
@property (readwrite, retain) NSMutableSet<NSString *> *timedOutRobotToolCallIDs;
@property (readwrite, retain) NSTimer *robotActionBridgeTimer;
@property (readwrite, copy) NSString *localAmberGestureCallID;
@property (readwrite, copy) NSString *controllerApprovedAmberGestureCallID;
@property (readwrite, retain) ROBRobotActionMessage *controllerApprovedAmberGestureExecutingStatus;

@property (readwrite, retain) SimpleUserTrackerTaskController *simpleUserTrackerTaskController;
@property (readwrite, retain) AudioInputTaskController *audioInputTaskController;
@property (readwrite, retain) JoinWifiTaskController *joinWifiTaskController;

@property (readwrite, retain) IBOutlet NSTextView *simpleUserTrackerTaskTextView;

@property (readwrite, assign) bool followingMode;
@property (readwrite, assign) BOOL isNeckLifted;
@property (readwrite, assign) bool ignoreText;
@property (readwrite, assign) int currentPersonTrackingID;
@property (readwrite, assign) int followingSpeed;

@property (readwrite, assign) float currentPerson_positionX;
@property (readwrite, assign) float currentPerson_positionY;
@property (readwrite, assign) float currentPerson_positionZ;
@property (readwrite, assign) float currentPerson_pan;
@property (readwrite, assign) float currentPerson_tilt;
@property (readwrite, assign) float currentPerson_upperNeckTilt;

@property (readwrite, assign) int actualValue;
@property (readwrite, assign) int targetValue;
@property (readwrite, retain) NSString *inputLanguage;
@property (readwrite, retain) NSString *outputLanguage;

@property (readwrite, assign) int pulse_count;
@property (readwrite, assign) bool NiTE_IS_ON;
@property (readwrite, assign) BOOL runtimeIsShuttingDown;

@property (readwrite, retain) NSTimer *liftNeckAnimationTimer;
@property (readwrite, retain) NSTableView *conversationTableView;
@property (readwrite, retain) NSMutableArray<ROBConversationMessage *> *conversationMessages;
@property (readwrite, copy) NSString *lastConversationUserText;
@property (readwrite, retain) NSDate *lastConversationUserDate;
@property (readwrite, retain) IBOutlet NSButton *mainAISendButton;
@property (readwrite, retain) IBOutlet NSButton *resetConversationButton;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (void)shutdownCerebroRuntime;
- (BOOL)sendRobotActionMessage:(ROBRobotActionMessage *)message;
- (void)handleRobotActionMessage:(ROBRobotActionMessage *)message;
- (void)robotActionBridgeTick:(NSTimer *)timer;
- (NSString *)robotActionStateString:(ROBRobotActionState)state;
- (BOOL)robotActionMessageIsAddressedToCerebro:(ROBRobotActionMessage *)message;
- (void)cancelPendingGeminiRobotActionsWithReason:(NSString *)reason;
- (BOOL)robotActionControllerIsFreshForRequest:(ROBRobotActionMessage *)request;
- (void)startControllerApprovedAmberGestureForRequest:(ROBRobotActionMessage *)request
                                                 call:(ROBAIRobotToolCall *)call;
- (void)cancelControllerApprovedAmberGestureCallID:(NSString *)callID
                                             reason:(NSString *)reason
                                           timedOut:(BOOL)timedOut;
- (void)finishControllerApprovedAmberGestureCallID:(NSString *)callID
                                             result:(NSDictionary *)result;
- (void)updateGeminiCameraDemand;
- (void)geminiVideoSourceSettingsDidChange:(NSNotification *)notification;
- (void)configureConversationTranscript;
- (void)configureMainWorkspace;
- (void)appendConversationText:(NSString *)text fromUser:(BOOL)fromUser;
- (void)loadConversationLog;
- (void)saveConversationLog;
- (void)pruneConversationLog;
- (NSURL *)conversationLogURL;
- (IBAction)sendROBChatText:(id)sender;
- (IBAction)showSettings:(id)sender;
@end

@implementation ROBMainViewController

- (void)configureConversationTranscript
{
    self.conversationMessages = [NSMutableArray array];
    NSScrollView *scrollView = self.speechTranscriptTextView.enclosingScrollView;
    if (scrollView == nil) { return; }

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:scrollView.contentView.bounds];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"Conversation"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    column.width = scrollView.contentSize.width;
    [tableView addTableColumn:column];
    tableView.headerView = nil;
    tableView.backgroundColor = NSColor.clearColor;
    tableView.gridStyleMask = NSTableViewGridNone;
    tableView.intercellSpacing = NSMakeSize(0, 4);
    tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    tableView.usesAlternatingRowBackgroundColors = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    tableView.autoresizingMask = NSViewWidthSizable;
    scrollView.documentView = tableView;
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    self.conversationTableView = tableView;

    self.speechTextView.font = [NSFont systemFontOfSize:15];
    self.speechTextView.textColor = NSColor.labelColor;
    self.speechTextView.backgroundColor = NSColor.textBackgroundColor;
    self.speechTextView.insertionPointColor = NSColor.controlAccentColor;
    // Give typed chat text a little breathing room below the top edge. The
    // previous inset made the first baseline look unnaturally high.
    self.speechTextView.textContainerInset = NSMakeSize(9, 11);
    self.speechTextView.automaticQuoteSubstitutionEnabled = NO;
    self.speechTextView.automaticDashSubstitutionEnabled = NO;

    [self loadConversationLog];
}

- (NSView *)workspaceCardView
{
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NSColor.separatorColor.CGColor;
    card.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    return card;
}

- (void)configureMainWorkspace
{
    NSScrollView *conversationScrollView = self.speechTranscriptTextView.enclosingScrollView;
    NSScrollView *composerScrollView = self.speechTextView.enclosingScrollView;
    if (conversationScrollView == nil || composerScrollView == nil ||
        self.mainAISendButton == nil || self.resetConversationButton == nil) {
        return;
    }

    [conversationScrollView removeFromSuperview];
    [composerScrollView removeFromSuperview];
    [self.mainAISendButton removeFromSuperview];
    [self.resetConversationButton removeFromSuperview];

    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    background.material = NSVisualEffectMaterialUnderWindowBackground;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:background positioned:NSWindowBelow relativeTo:nil];

    NSImageView *appIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    appIcon.image = [NSImage imageWithSystemSymbolName:@"brain.head.profile"
                             accessibilityDescription:@"Cerebro"];
    appIcon.contentTintColor = NSColor.controlAccentColor;
    appIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:31
                                                                                  weight:NSFontWeightMedium];
    [appIcon.widthAnchor constraintEqualToConstant:42].active = YES;
    [appIcon.heightAnchor constraintEqualToConstant:42].active = YES;

    NSTextField *titleLabel = [NSTextField labelWithString:@"Cerebro"];
    titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    NSTextField *subtitleLabel = [NSTextField
        labelWithString:@"Robot communication center"];
    subtitleLabel.font = [NSFont systemFontOfSize:12];
    subtitleLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *titleStack = [NSStackView stackViewWithViews:@[titleLabel, subtitleLabel]];
    titleStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    titleStack.alignment = NSLayoutAttributeLeading;
    titleStack.spacing = 1;

    NSButton *insta360Button = [NSButton buttonWithTitle:@"360° Live View"
                                                  target:self
                                                  action:@selector(showInsta360Diagnostics:)];
    insta360Button.image = [NSImage imageWithSystemSymbolName:@"viewfinder"
                                     accessibilityDescription:@"Open Insta360 live diagnostics"];
    insta360Button.imagePosition = NSImageLeading;
    insta360Button.bezelStyle = NSBezelStyleTexturedRounded;
    insta360Button.toolTip = @"Open the live stitched panorama, orientation guide, and 360° diagnostics";
    [insta360Button setAccessibilityIdentifier:@"ROB.MainWorkspace.Insta360"];

    NSButton *settingsButton = [NSButton buttonWithTitle:@"Settings"
                                                  target:self
                                                  action:@selector(showSettings:)];
    settingsButton.image = [NSImage imageWithSystemSymbolName:@"gearshape.fill"
                                     accessibilityDescription:@"Open Cerebro Settings"];
    settingsButton.imagePosition = NSImageLeading;
    settingsButton.bezelStyle = NSBezelStyleTexturedRounded;
    settingsButton.toolTip = @"Configure AI providers, Messages, cameras, and robot services";
    [settingsButton setAccessibilityIdentifier:@"ROB.MainWorkspace.Settings"];

    NSView *headerSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    NSStackView *header = [NSStackView stackViewWithViews:@[
        appIcon, titleStack, headerSpacer, insta360Button, settingsButton
    ]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 10;
    [headerSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [settingsButton setContentHuggingPriority:NSLayoutPriorityRequired
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [insta360Button setContentHuggingPriority:NSLayoutPriorityRequired
                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.messagesWorkspaceViewController = [[ROBMessagesWorkspaceViewController alloc] init];
    [self addChildViewController:self.messagesWorkspaceViewController];
    NSView *messagesView = self.messagesWorkspaceViewController.view;
    messagesView.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *aiCard = [self workspaceCardView];
    aiCard.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *aiTitle = [NSTextField labelWithString:@"Main AI"];
    aiTitle.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    NSTextField *aiSubtitle = [NSTextField
        labelWithString:@"Talk directly with ROB’s primary intelligence"];
    aiSubtitle.font = [NSFont systemFontOfSize:11];
    aiSubtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *aiTitleStack = [NSStackView stackViewWithViews:@[aiTitle, aiSubtitle]];
    aiTitleStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    aiTitleStack.alignment = NSLayoutAttributeLeading;
    aiTitleStack.spacing = 1;

    self.resetConversationButton.title = @"Clear";
    self.resetConversationButton.image = [NSImage imageWithSystemSymbolName:@"trash"
                                                   accessibilityDescription:@"Clear Main AI conversation"];
    self.resetConversationButton.imagePosition = NSImageLeading;
    self.resetConversationButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.resetConversationButton.toolTip = @"Clear the local Main AI conversation history";
    NSView *aiHeaderSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    NSStackView *aiHeader = [NSStackView stackViewWithViews:@[
        aiTitleStack, aiHeaderSpacer, self.resetConversationButton
    ]];
    aiHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    aiHeader.alignment = NSLayoutAttributeCenterY;
    aiHeader.spacing = 8;

    conversationScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    conversationScrollView.borderType = NSNoBorder;
    conversationScrollView.wantsLayer = YES;
    conversationScrollView.layer.cornerRadius = 10;
    conversationScrollView.layer.masksToBounds = YES;
    conversationScrollView.layer.backgroundColor =
        [NSColor.textBackgroundColor colorWithAlphaComponent:0.72].CGColor;

    composerScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    composerScrollView.borderType = NSNoBorder;
    composerScrollView.drawsBackground = NO;
    composerScrollView.wantsLayer = YES;
    composerScrollView.layer.cornerRadius = 10;
    composerScrollView.layer.borderWidth = 1;
    composerScrollView.layer.borderColor = NSColor.separatorColor.CGColor;
    self.speechTextView.backgroundColor = NSColor.clearColor;

    self.mainAISendButton.title = @"Send to ROB";
    self.mainAISendButton.bezelStyle = NSBezelStyleRounded;
    self.mainAISendButton.keyEquivalent = @"\r";
    self.mainAISendButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.mainAISendButton.toolTip = @"Send to the Main AI (Command-Return)";
    [self.mainAISendButton setAccessibilityIdentifier:@"ROB.MainWorkspace.SendAI"];

    NSStackView *composerRow = [NSStackView stackViewWithViews:@[
        composerScrollView, self.mainAISendButton
    ]];
    composerRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    composerRow.alignment = NSLayoutAttributeCenterY;
    composerRow.spacing = 10;
    NSTextField *composerHint = [NSTextField
        labelWithString:@"Command-Return sends • Return adds a new line"];
    composerHint.font = [NSFont systemFontOfSize:10];
    composerHint.textColor = NSColor.tertiaryLabelColor;

    for (NSView *subview in @[aiHeader, conversationScrollView, composerRow, composerHint]) {
        subview.translatesAutoresizingMaskIntoConstraints = NO;
        [aiCard addSubview:subview];
    }
    [NSLayoutConstraint activateConstraints:@[
        [aiHeader.topAnchor constraintEqualToAnchor:aiCard.topAnchor constant:14],
        [aiHeader.leadingAnchor constraintEqualToAnchor:aiCard.leadingAnchor constant:16],
        [aiHeader.trailingAnchor constraintEqualToAnchor:aiCard.trailingAnchor constant:-16],
        [conversationScrollView.topAnchor constraintEqualToAnchor:aiHeader.bottomAnchor constant:12],
        [conversationScrollView.leadingAnchor constraintEqualToAnchor:aiCard.leadingAnchor constant:12],
        [conversationScrollView.trailingAnchor constraintEqualToAnchor:aiCard.trailingAnchor constant:-12],
        [composerRow.topAnchor constraintEqualToAnchor:conversationScrollView.bottomAnchor constant:10],
        [composerRow.leadingAnchor constraintEqualToAnchor:aiCard.leadingAnchor constant:12],
        [composerRow.trailingAnchor constraintEqualToAnchor:aiCard.trailingAnchor constant:-12],
        [composerScrollView.heightAnchor constraintEqualToConstant:76],
        [self.mainAISendButton.widthAnchor constraintEqualToConstant:108],
        [composerHint.topAnchor constraintEqualToAnchor:composerRow.bottomAnchor constant:5],
        [composerHint.leadingAnchor constraintEqualToAnchor:composerRow.leadingAnchor constant:4],
        [composerHint.trailingAnchor constraintLessThanOrEqualToAnchor:aiCard.trailingAnchor constant:-12],
        [composerHint.bottomAnchor constraintEqualToAnchor:aiCard.bottomAnchor constant:-11]
    ]];

    NSStackView *workspace = [NSStackView stackViewWithViews:@[messagesView, aiCard]];
    workspace.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    workspace.alignment = NSLayoutAttributeTop;
    workspace.distribution = NSStackViewDistributionFill;
    workspace.spacing = 14;
    workspace.translatesAutoresizingMaskIntoConstraints = NO;
    [messagesView.heightAnchor constraintEqualToAnchor:workspace.heightAnchor].active = YES;
    [aiCard.heightAnchor constraintEqualToAnchor:workspace.heightAnchor].active = YES;
    [messagesView.widthAnchor constraintGreaterThanOrEqualToConstant:440].active = YES;
    NSLayoutConstraint *preferredMessagesWidth =
        [messagesView.widthAnchor constraintEqualToConstant:490];
    preferredMessagesWidth.priority = NSLayoutPriorityDefaultHigh;
    preferredMessagesWidth.active = YES;
    [aiCard.widthAnchor constraintGreaterThanOrEqualToConstant:500].active = YES;

    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    [self.view addSubview:workspace];
    [NSLayoutConstraint activateConstraints:@[
        [background.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [background.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [background.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [background.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [header.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [workspace.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],
        [workspace.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [workspace.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [workspace.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-20]
    ]];
}

- (NSURL *)conversationLogURL
{
    NSURL *applicationSupportURL = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:nil];
    if (applicationSupportURL == nil) { return nil; }

    NSURL *cerebroDirectory = [applicationSupportURL URLByAppendingPathComponent:@"Cerebro" isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:cerebroDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        NSLog(@"Unable to create conversation log directory: %@", directoryError.localizedDescription);
        return nil;
    }
    return [cerebroDirectory URLByAppendingPathComponent:@"ConversationLog.json"];
}

- (void)pruneConversationLog
{
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-ROBConversationLogRetentionInterval];
    NSIndexSet *expiredIndexes = [self.conversationMessages indexesOfObjectsPassingTest:
        ^BOOL(ROBConversationMessage *message, NSUInteger index, BOOL *stop) {
            return message.date == nil || [message.date compare:cutoff] == NSOrderedAscending;
        }];
    if (expiredIndexes.count > 0) {
        [self.conversationMessages removeObjectsAtIndexes:expiredIndexes];
    }
    if (self.conversationMessages.count > ROBConversationLogMaximumMessages) {
        NSUInteger overflow = self.conversationMessages.count - ROBConversationLogMaximumMessages;
        [self.conversationMessages removeObjectsInRange:NSMakeRange(0, overflow)];
    }
}

- (void)loadConversationLog
{
    NSURL *logURL = [self conversationLogURL];
    NSData *data = logURL != nil ? [NSData dataWithContentsOfURL:logURL] : nil;
    if (data.length == 0) { return; }

    NSError *jsonError = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    NSDictionary *document = [jsonObject isKindOfClass:[NSDictionary class]] ? jsonObject : nil;
    NSArray *storedMessages = [document[@"messages"] isKindOfClass:[NSArray class]] ? document[@"messages"] : nil;
    if (storedMessages == nil) {
        NSLog(@"Unable to read conversation log: %@", jsonError.localizedDescription ?: @"invalid format");
        return;
    }

    for (NSDictionary *storedMessage in storedMessages) {
        if (![storedMessage isKindOfClass:[NSDictionary class]]) { continue; }
        NSString *text = [storedMessage[@"text"] isKindOfClass:[NSString class]] ? storedMessage[@"text"] : nil;
        NSNumber *timestamp = [storedMessage[@"timestamp"] isKindOfClass:[NSNumber class]] ? storedMessage[@"timestamp"] : nil;
        NSNumber *fromUser = [storedMessage[@"from_user"] isKindOfClass:[NSNumber class]] ? storedMessage[@"from_user"] : nil;
        if (text.length == 0 || timestamp == nil || fromUser == nil) { continue; }

        ROBConversationMessage *message = [ROBConversationMessage new];
        message.text = text;
        message.fromUser = fromUser.boolValue;
        message.date = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
        [self.conversationMessages addObject:message];
    }
    [self pruneConversationLog];
    [self.conversationTableView reloadData];
    if (self.conversationMessages.count > 0) {
        [self.conversationTableView scrollRowToVisible:self.conversationMessages.count - 1];
    }
    [self saveConversationLog];
}

- (void)saveConversationLog
{
    [self pruneConversationLog];
    NSMutableArray<NSDictionary *> *storedMessages = [NSMutableArray arrayWithCapacity:self.conversationMessages.count];
    for (ROBConversationMessage *message in self.conversationMessages) {
        if (message.text.length == 0 || message.date == nil) { continue; }
        [storedMessages addObject:@{
            @"text": message.text,
            @"from_user": @(message.fromUser),
            @"timestamp": @([message.date timeIntervalSince1970])
        }];
    }

    NSDictionary *document = @{ @"version": @1, @"messages": storedMessages };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:0 error:&jsonError];
    NSURL *logURL = [self conversationLogURL];
    if (data == nil || logURL == nil || ![data writeToURL:logURL options:NSDataWritingAtomic error:&jsonError]) {
        NSLog(@"Unable to save conversation log: %@", jsonError.localizedDescription ?: @"unknown error");
    }
}

- (void)appendConversationText:(NSString *)text fromUser:(BOOL)fromUser
{
    void (^appendBlock)(void) = ^{
        NSString *cleanText = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (cleanText.length == 0) { return; }

        NSDate *now = [NSDate date];
        if (fromUser && self.lastConversationUserDate != nil &&
            [now timeIntervalSinceDate:self.lastConversationUserDate] < 4.0 &&
            [cleanText caseInsensitiveCompare:self.lastConversationUserText] == NSOrderedSame) {
            return;
        }

        ROBConversationMessage *message = [ROBConversationMessage new];
        message.text = cleanText;
        message.fromUser = fromUser;
        message.date = now;
        [self.conversationMessages addObject:message];
        [self pruneConversationLog];
        if (fromUser) {
            self.lastConversationUserText = cleanText;
            self.lastConversationUserDate = now;
        }
        [self.conversationTableView reloadData];
        NSInteger finalRow = self.conversationMessages.count - 1;
        if (finalRow >= 0) {
            [self.conversationTableView scrollRowToVisible:finalRow];
        }
        [self saveConversationLog];
    };
    if (NSThread.isMainThread) appendBlock();
    else dispatch_async(dispatch_get_main_queue(), appendBlock);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return self.conversationMessages.count;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row
{
    ROBConversationMessage *message = self.conversationMessages[row];
    CGFloat textWidth = MIN(MAX(180, tableView.bounds.size.width - 28) * 0.78, 430)
        - (ROBConversationBubbleHorizontalTextInset * 2);
    NSRect textBounds = [message.text boundingRectWithSize:NSMakeSize(textWidth, CGFLOAT_MAX)
                                                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:14] }];
    return MAX(68, ceil(NSHeight(textBounds)) + 47);
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row
{
    ROBConversationBubbleView *view = [tableView makeViewWithIdentifier:@"ConversationBubble" owner:self];
    if (view == nil) {
        view = [[ROBConversationBubbleView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, 68)];
        view.identifier = @"ConversationBubble";
    }
    ROBConversationMessage *message = self.conversationMessages[row];
    view.fromUser = message.fromUser;
    NSString *senderName = message.fromUser ? @"YOU" : @"ROB AI";
    NSString *timestamp = [NSDateFormatter localizedStringFromDate:message.date
                                                         dateStyle:NSDateFormatterShortStyle
                                                         timeStyle:NSDateFormatterShortStyle];
    view.senderLabel.stringValue = [NSString stringWithFormat:@"%@  •  %@", senderName, timestamp];
    NSColor *textColor = message.fromUser ? NSColor.whiteColor : NSColor.labelColor;
    view.bubbleLabel.attributedStringValue = [[NSAttributedString alloc]
        initWithString:message.text
           attributes:@{
               NSFontAttributeName: [NSFont systemFontOfSize:14],
               NSForegroundColorAttributeName: textColor
           }];
    view.bubbleLabel.textColor = textColor;
    NSColor *bubbleColor = message.fromUser
        ? NSColor.systemBlueColor
        : [NSColor.systemPurpleColor colorWithAlphaComponent:0.24];
    view.bubbleBackgroundView.layer.backgroundColor = bubbleColor.CGColor;
    view.toolTip = [NSDateFormatter localizedStringFromDate:message.date
                                                  dateStyle:NSDateFormatterNoStyle
                                                  timeStyle:NSDateFormatterShortStyle];
    view.needsLayout = YES;
    return view;
}

- (void)tableViewColumnDidResize:(NSNotification *)notification
{
    if (notification.object != self.conversationTableView || self.conversationMessages.count == 0) {
        return;
    }
    NSIndexSet *allRows = [NSIndexSet indexSetWithIndexesInRange:
        NSMakeRange(0, self.conversationMessages.count)];
    [self.conversationTableView noteHeightOfRowsWithIndexesChanged:allRows];
}

- (void) didRespond: (NSString *) responseText {
    [self.speechBox sayIt:responseText];
}

#pragma mark - ROBAIDelegate

- (void)robAI:(ROBAI *)robAI didReceiveResponseText:(NSString *)text
{
    NSLog(@"Gemini Robotics response: %@", text);
    [self appendConversationText:text fromUser:NO];
    if (self.audioInputTaskController.textView != nil) {
        self.audioInputTaskController.textView.string =
            [self.audioInputTaskController.textView.string
                stringByAppendingString:[NSString stringWithFormat:@"\nROB: %@\n", text]];
    }
    [self didRespond:text];
}

- (void)robAI:(ROBAI *)robAI
        didReceiveResponseText:(NSString *)text
                    contextID:(NSString *)contextID
{
    if ([contextID hasPrefix:@"stage:"]) {
        // A late stage response is deliberately swallowed after its authored
        // fallback has started; it must not interrupt a later show cue.
        (void)[self.stageShowCoordinator acceptGeminiResponse:text requestID:contextID];
        return;
    }
    [self appendConversationText:text fromUser:NO];
    [self didRespond:text];
}

- (void)robAI:(ROBAI *)robAI didReceiveInputTranscription:(NSString *)text
{
    // This is server-originated confirmation of what Gemini understood, not
    // the separate on-device Apple speech-recognition transcript.
    NSLog(@"Gemini Robotics heard: %@", text);
    [self appendConversationText:text fromUser:YES];
    [self speakConfiguredAcknowledgementIfNotQueued];
}

- (void)speakConfiguredAcknowledgementIfNotQueued
{
    if (self.speechBox.isSpeaking) {
        return;
    }
    [self.speechBox sayItIfNotQueued:ROBResolvedSpeechAcknowledgementPhrase()];
}

- (void)robAI:(ROBAI *)robAI didFailRequestWithDetail:(NSString *)detail
{
    NSLog(@"Gemini Robotics request failed: %@", detail);
    if ([detail containsString:@"turned off"]) {
        return;
    }
    [self.speechBox sayItIfNotQueued:@"I'm still here, but that online request did not finish. Please say ROB and try again."];
}

- (void)robAI:(ROBAI *)robAI
        didFailRequestWithDetail:(NSString *)detail
                       contextID:(NSString *)contextID
{
    NSLog(@"Gemini Robotics request failed for %@: %@", contextID, detail);
    if ([contextID hasPrefix:@"stage:"]) {
        (void)[self.stageShowCoordinator failGeminiTurn:detail requestID:contextID];
        return;
    }
    if ([detail containsString:@"turned off"]) {
        return;
    }
    [self.speechBox sayItIfNotQueued:@"I'm still here, but that online request did not finish. Please say ROB and try again."];
}

- (void)robAI:(ROBAI *)robAI didChangeConnectionState:(NSString *)state detail:(NSString *)detail
{
    if (detail.length > 0) {
        NSLog(@"Gemini Robotics state: %@ (%@)", state, detail);
    } else {
        NSLog(@"Gemini Robotics state: %@", state);
    }
    [self updateGeminiCameraDemand];
}

- (void)robAIRuntimePolicyDidApply:(ROBAI *)robAI
{
    [self updateGeminiCameraDemand];
}

#pragma mark - Gemini Runtime Controls

- (void)setGeminiConnectionEnabled:(BOOL)enabled
{
    if (!enabled) {
        [self cancelPendingGeminiRobotActionsWithReason:
            @"Gemini was turned off; stop or hold safely"];
    }
    [self.robAI setGeminiConnectionEnabled:enabled];
    [self updateGeminiCameraDemand];
}

- (void)setGeminiMicrophoneStreamingEnabled:(BOOL)enabled
{
    [self.robAI setMicrophoneStreamingEnabled:enabled];
}

- (void)setGeminiCameraStreamingEnabled:(BOOL)enabled
{
    [self.robAI setCameraStreamingEnabled:enabled];
    [self updateGeminiCameraDemand];
}

- (void)cancelPendingGeminiRobotActionsWithReason:(NSString *)reason
{
    NSArray<NSString *> *callIDs = [self.pendingRobotActionRequests.allKeys copy];
    BOOL hasLocalAmberGesture = self.localAmberGestureCallID.length > 0;
    if (callIDs.count == 0 && !hasLocalAmberGesture) {
        return;
    }

    // Apply the deterministic local stop before any best-effort network
    // cancellation so turning Gemini off cannot leave motion waiting on I/O.
    [self applyPrioritySoftwareStopWithReason:reason];
    if (hasLocalAmberGesture) {
        (void)[[ROBAmberGestureExecutor shared] cancelCurrentGestureWithReason:reason];
    }

    for (NSString *callID in callIDs) {
        ROBRobotActionMessage *request = self.pendingRobotActionRequests[callID];
        if (request == nil) {
            continue;
        }
        ROBRobotActionMessage *cancellation = self.pendingRobotActionCancellations[callID];
        if (cancellation == nil) {
            cancellation = [ROBRobotActionMessage actionCancelWithCallID:callID
                                                                   reason:reason
                                                                 senderID:self.robotActionSenderID
                                                              recipientID:request.recipientID];
            self.pendingRobotActionCancellations[callID] = cancellation;
        }
        [self.geminiCancellingRobotToolCallIDs addObject:callID];
        [self sendRobotActionMessage:cancellation];
        if ([self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
            [self cancelControllerApprovedAmberGestureCallID:callID
                                                       reason:reason
                                                     timedOut:NO];
        }
    }
}

- (void)updateGeminiCameraDemand
{
    BOOL geminiLiveIsReady = self.robAI.isGeminiConnectionEnabled &&
        self.robAI.isLiveSessionReady;
    BOOL mainCameraIsActive = geminiLiveIsReady &&
        self.robAI.streamsMainCameraVideo;
    BOOL insta360IsActive = geminiLiveIsReady &&
        self.robAI.streamsInsta360Video;
    [self.cameraViewController setGeminiVideoDemandActive:mainCameraIsActive];
    [[ROBInsta360CameraService shared]
        setGeminiVideoDemandActive:insta360IsActive];
}

- (void)geminiVideoSourceSettingsDidChange:(NSNotification *)notification
{
    [self.robAI synchronizeVideoSourceSettings];
    [self updateGeminiCameraDemand];
}

- (void)robAIWasInterrupted:(ROBAI *)robAI
{
    [self.speechBox stopIt:nil];
}

- (void)robAI:(ROBAI *)robAI didReceiveToolCall:(ROBAIRobotToolCall *)call
{
    if (![call.name isEqualToString:@"robot_action"]) {
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"rejected",
                                       @"reason": @"Unsupported tool"
                                   }];
        return;
    }

    NSString *action = [call.arguments[@"action"] isKindOfClass:[NSString class]]
        ? call.arguments[@"action"] : nil;
    if (action.length == 0) {
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"rejected",
                                       @"reason": @"robot_action requires an action"
                                   }];
        return;
    }

    if ([action isEqualToString:@"stop_motion"]) {
        // Stop is a preemptive local safety lane. It does not wait behind the
        // controller ledger. The Amber executor only asks arms already in
        // verified position mode to hold their fresh measured pose; it never
        // activates an arm from this path.
        NSSet *stopArgumentKeys = [NSSet setWithArray:call.arguments.allKeys];
        BOOL stopHasOnlyAction = stopArgumentKeys.count == 1 &&
            [stopArgumentKeys containsObject:@"action"];
        if (self.stageShowCoordinator.isRunning) {
            [self.stageShowCoordinator cancelWithReason:@"Gemini requested stop_motion"];
        } else {
            [self applyPrioritySoftwareStopWithReason:@"Gemini requested stop_motion"];
        }
        (void)[[ROBAmberGestureExecutor shared]
            cancelCurrentGestureWithReason:@"Gemini requested stop_motion"];
        NSDictionary *armResult = [[ROBAmberGestureExecutor shared] requestPriorityHold];
        NSString *armStatus = armResult[@"arm_status"];
        if (armStatus == nil) {
            armStatus = @"unavailable";
        }
        NSString *stopDetail = stopHasOnlyAction
            ? @"Cerebro stopped local coordinators and requested a measured-pose hold for each Amber arm already verified in position mode."
            : @"Cerebro stopped local coordinators and requested a measured-pose hold for each Amber arm already verified in position mode. Unexpected stop_motion arguments were ignored and could not suppress the stop.";
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"partial",
                                       @"base_status": @"software_stopped",
                                       @"arm_status": armStatus,
                                       @"arm_result": armResult,
                                       @"detail": stopDetail
                                   }];
        return;
    }

    // Origin travels with the tool call even if the blocking queue releases it
    // after the stage cue has timed out or the show has stopped. Stage dialogue
    // is never an implicit motion authorization. Stop remains available through
    // the priority lane above.
    if (call.isStageOrigin) {
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"rejected",
                                       @"reason": @"Stage-originated dialogue cannot authorize physical robot actions"
                                   }];
        return;
    }

    // Continue to fail closed for uncorrelated calls while the deterministic
    // stage runner owns the performance, even if they came from another input.
    if (self.stageShowCoordinator.isRunning) {
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"rejected",
                                       @"reason": @"Physical-action tools are disabled while a stage show is running"
                                   }];
        return;
    }

    // This is the only direct Gemini-to-arm path. The local grant expires and
    // is never persisted; the executor resolves the name to an immutable
    // operator-approved pose, limits the measured delta, and waits for fresh
    // position/velocity feedback before returning physical completion.
    if ([action isEqualToString:@"play_gesture"] &&
        [[ROBAmberDebugAuthority shared] authorizesGemini]) {
        NSSet *playGestureArgumentKeys = [NSSet setWithArray:call.arguments.allKeys];
        NSSet *expectedPlayGestureArgumentKeys = [NSSet setWithObjects:@"action", @"gesture", nil];
        if (![playGestureArgumentKeys isEqualToSet:expectedPlayGestureArgumentKeys]) {
            [robAI sendToolResponseWithCallID:call.callID
                                         name:call.name
                                       result:@{
                                           @"status": @"rejected",
                                           @"reason": @"play_gesture accepts only action and an approved gesture name; raw joint or unknown arguments are forbidden"
                                       }];
            return;
        }
        NSString *gesture = [call.arguments[@"gesture"] isKindOfClass:[NSString class]]
            ? call.arguments[@"gesture"] : nil;
        if (gesture.length == 0) {
            [robAI sendToolResponseWithCallID:call.callID
                                         name:call.name
                                       result:@{
                                           @"status": @"rejected",
                                           @"reason": @"play_gesture requires an approved gesture name"
                                       }];
            return;
        }
        if ([self.localAmberGestureCallID isEqualToString:call.callID]) {
            return;
        }
        if (self.localAmberGestureCallID.length > 0 ||
            self.pendingRobotActionRequests.count > 0) {
            [robAI sendToolResponseWithCallID:call.callID
                                         name:call.name
                                       result:@{
                                           @"status": @"rejected",
                                           @"reason": @"Another physical robot action is still active"
                                       }];
            return;
        }
        self.localAmberGestureCallID = call.callID;
        __weak ROBMainViewController *weakSelf = self;
        [[ROBAmberGestureExecutor shared]
            executeApprovedGesture:gesture
            completion:^(NSDictionary *result) {
                ROBMainViewController *strongSelf = weakSelf;
                if (strongSelf == nil ||
                    ![strongSelf.localAmberGestureCallID isEqualToString:call.callID]) {
                    return;
                }
                strongSelf.localAmberGestureCallID = nil;
                [robAI sendToolResponseWithCallID:call.callID
                                             name:call.name
                                           result:result];
            }];
        return;
    }

    // Once the operator activates an autonomy session, the local coordinator
    // owns all bounded robot behavior without per-action controller prompts.
    // Unsupported physical actions fail honestly instead of being presented
    // as though a grasp or trajectory executor exists.
    if (self.autonomyCoordinator.active) {
        NSString *reason = [action isEqualToString:@"request_pick"]
            ? @"Picking is not enabled: the robot still needs calibrated camera-to-arm transforms, IK, collision checking, and joint feedback"
            : @"This action does not yet have a local deterministic executor in autonomy mode";
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"failed",
                                       @"detail": reason
                                   }];
        return;
    }

    // A duplicate delivery reuses its original call ID and request. This is an
    // idempotent retransmission, never a second physical operation.
    ROBRobotActionMessage *existingRequest = self.pendingRobotActionRequests[call.callID];
    if (existingRequest != nil) {
        [self sendRobotActionMessage:existingRequest];
        return;
    }

    // A Live-session reconnect must not erase the robot's physical blocking
    // boundary. Wait for the prior controller action (including a requested
    // cancellation) to reach a terminal state before admitting a new call ID.
    if (self.pendingRobotActionRequests.count > 0) {
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"rejected",
                                       @"reason": @"A previous robot action is still active or awaiting confirmed cancellation"
                                   }];
        return;
    }

    BOOL controllerIsFresh = self.robotActionControllerLastSeen != nil &&
        [[NSDate date] timeIntervalSinceDate:self.robotActionControllerLastSeen] < kRobotActionControllerFreshnessSeconds;
    BOOL controllerSupportsAction = [self.robotActionControllerCapabilities containsObject:action];
    if (!controllerIsFresh || !self.robotActionControllerAcceptsActions ||
        self.robotActionControllerID.length == 0 || !controllerSupportsAction) {
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"rejected",
                                       @"reason": @"No fresh ROBController session is accepting this action"
                                   }];
        return;
    }

    NSMutableDictionary *arguments = [call.arguments mutableCopy];
    [arguments removeObjectForKey:@"action"];
    ROBRobotActionMessage *request =
        [ROBRobotActionMessage actionRequestWithCallID:call.callID
                                                action:action
                                             arguments:arguments
                                              senderID:self.robotActionSenderID
                                           recipientID:self.robotActionControllerID
                                             expiresAt:[NSDate dateWithTimeIntervalSinceNow:kRobotActionApprovalLifetimeSeconds]];
    if (request.validationError.length > 0) {
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"rejected",
                                       @"reason": request.validationError
                                   }];
        return;
    }

    self.pendingRobotToolCalls[call.callID] = call;
    self.pendingRobotActionRequests[call.callID] = request;
    if (![self sendRobotActionMessage:request]) {
        [self.pendingRobotToolCalls removeObjectForKey:call.callID];
        [self.pendingRobotActionRequests removeObjectForKey:call.callID];
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"failed",
                                       @"reason": @"Could not encode or send the ROBController request"
                                   }];
        return;
    }
    NSLog(@"Gemini action %@ (%@) is awaiting ROBController approval", action, call.callID);
}

- (void)robAI:(ROBAI *)robAI didCancelToolCallIDs:(NSArray<NSString *> *)callIDs
{
    for (NSString *callID in callIDs) {
        if ([self.localAmberGestureCallID isEqualToString:callID]) {
            self.localAmberGestureCallID = nil;
            (void)[[ROBAmberGestureExecutor shared]
                cancelCurrentGestureWithReason:@"Gemini cancelled the Amber gesture"];
            [robAI confirmToolCallCancellation:callID];
            continue;
        }
        ROBRobotActionMessage *request = self.pendingRobotActionRequests[callID];
        if (request == nil) {
            [robAI confirmToolCallCancellation:callID];
            continue;
        }

        [self.geminiCancellingRobotToolCallIDs addObject:callID];
        ROBRobotActionMessage *cancellation =
            [ROBRobotActionMessage actionCancelWithCallID:callID
                                                   reason:@"Gemini cancelled the tool call; stop or hold safely"
                                                 senderID:self.robotActionSenderID
                                              recipientID:request.recipientID];
        self.pendingRobotActionCancellations[callID] = cancellation;
        [self sendRobotActionMessage:cancellation];
        if ([self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
            [self cancelControllerApprovedAmberGestureCallID:callID
                                                       reason:@"Gemini cancelled the controller-approved Amber gesture; stop or hold safely"
                                                     timedOut:NO];
        }
    }
    NSLog(@"Forwarded Gemini robot-action cancellations: %@", callIDs);
}

#pragma mark - ROBController robot-action bridge

- (NSString *)robotActionStateString:(ROBRobotActionState)state
{
    switch (state) {
        case ROBRobotActionStatePending: return @"pending";
        case ROBRobotActionStateAccepted: return @"accepted";
        case ROBRobotActionStateExecuting: return @"executing";
        case ROBRobotActionStateCompleted: return @"completed";
        case ROBRobotActionStateRejected: return @"rejected";
        case ROBRobotActionStateCancelled: return @"cancelled";
        case ROBRobotActionStateFailed: return @"failed";
        case ROBRobotActionStateExpired: return @"expired";
        case ROBRobotActionStateNone: return @"none";
    }
}

- (BOOL)robotActionMessageIsAddressedToCerebro:(ROBRobotActionMessage *)message
{
    return message.recipientID.length == 0 || [message.recipientID isEqualToString:self.robotActionSenderID];
}

- (BOOL)sendRobotActionMessage:(ROBRobotActionMessage *)message
{
    NSData *archive = [ROBRobotActionWireCodec archiveMessage:message legacySender:self.robotActionSenderID];
    if (archive == nil || self.autoNetServer == nil) {
        return NO;
    }
    return [self.autoNetServer sendMessage:archive];
}

- (BOOL)robotActionControllerIsFreshForRequest:(ROBRobotActionMessage *)request
{
    if (request.recipientID.length == 0 ||
        ![request.recipientID isEqualToString:self.robotActionControllerID] ||
        !self.robotActionControllerAcceptsActions ||
        ![self.robotActionControllerCapabilities containsObject:@"play_gesture"] ||
        self.robotActionControllerLastSeen == nil) {
        return NO;
    }
    return [[NSDate date] timeIntervalSinceDate:self.robotActionControllerLastSeen] <
        kRobotActionControllerFreshnessSeconds;
}

- (void)finishControllerApprovedAmberGestureCallID:(NSString *)callID
                                             result:(NSDictionary *)result
{
    ROBRobotActionMessage *request = self.pendingRobotActionRequests[callID];
    ROBAIRobotToolCall *call = self.pendingRobotToolCalls[callID];
    if (request == nil || ![request.action isEqualToString:@"play_gesture"]) {
        return;
    }
    if (self.controllerApprovedAmberGestureCallID.length > 0 &&
        ![self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
        return;
    }

    BOOL wasLocallyExecuting =
        [self.controllerApprovedAmberGestureCallID isEqualToString:callID];
    BOOL timedOut = wasLocallyExecuting &&
        [self.timedOutRobotToolCallIDs containsObject:callID];
    BOOL geminiCancelled = [self.geminiCancellingRobotToolCallIDs containsObject:callID];
    NSMutableDictionary *finalResult = [NSMutableDictionary dictionaryWithDictionary:result ?: @{}];
    NSString *reportedStatus = [finalResult[@"status"] isKindOfClass:[NSString class]]
        ? finalResult[@"status"] : @"failed";
    ROBRobotActionState terminalState = ROBRobotActionStateFailed;
    if (timedOut) {
        finalResult[@"detail"] = @"The controller-approved Amber gesture exceeded its execution deadline and a measured-pose hold was requested.";
        terminalState = ROBRobotActionStateExpired;
    } else if ([reportedStatus isEqualToString:@"completed"]) {
        terminalState = ROBRobotActionStateCompleted;
    } else if ([reportedStatus isEqualToString:@"rejected"]) {
        terminalState = ROBRobotActionStateRejected;
    } else if ([reportedStatus isEqualToString:@"cancelled"]) {
        terminalState = ROBRobotActionStateCancelled;
    } else if ([reportedStatus isEqualToString:@"expired"]) {
        terminalState = ROBRobotActionStateExpired;
    }
    finalResult[@"status"] = [self robotActionStateString:terminalState];
    finalResult[@"execution_owner"] = @"Cerebro";
    finalResult[@"authorization"] = @"controller_approved_one_shot";
    NSString *detail = [finalResult[@"detail"] isKindOfClass:[NSString class]]
        ? finalResult[@"detail"] : @"Cerebro's supervised Amber gesture executor reached a terminal state.";

    // Clear every local ownership record before sending callbacks. A duplicate
    // executor callback or replayed controller packet then has no request to
    // complete and cannot produce a second physical operation or tool result.
    if ([self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
        self.controllerApprovedAmberGestureCallID = nil;
        self.controllerApprovedAmberGestureExecutingStatus = nil;
    }
    [self.pendingRobotToolCalls removeObjectForKey:callID];
    [self.pendingRobotActionRequests removeObjectForKey:callID];
    [self.pendingRobotActionCancellations removeObjectForKey:callID];
    [self.robotActionExecutionDeadlines removeObjectForKey:callID];
    [self.timedOutRobotToolCallIDs removeObject:callID];
    [self.geminiCancellingRobotToolCallIDs removeObject:callID];

    ROBRobotActionMessage *terminal = [ROBRobotActionMessage
        actionStatusWithCallID:callID
                        state:terminalState
                       detail:detail
                       result:finalResult
                     senderID:self.robotActionSenderID
                  recipientID:request.recipientID];
    [self sendRobotActionMessage:terminal];

    if (call == nil) {
        NSLog(@"Controller-approved Amber gesture %@ finished after its Gemini call was released", callID);
    } else if (geminiCancelled) {
        [self.robAI confirmToolCallCancellation:callID];
    } else {
        [self.robAI sendToolResponseWithCallID:callID name:call.name result:finalResult];
    }
}

- (void)cancelControllerApprovedAmberGestureCallID:(NSString *)callID
                                             reason:(NSString *)reason
                                           timedOut:(BOOL)timedOut
{
    if (![self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
        return;
    }
    ROBRobotActionMessage *request = self.pendingRobotActionRequests[callID];
    if (request == nil) {
        return;
    }
    if (timedOut) {
        [self.timedOutRobotToolCallIDs addObject:callID];
    }
    ROBRobotActionMessage *cancellation = self.pendingRobotActionCancellations[callID];
    if (cancellation == nil) {
        cancellation = [ROBRobotActionMessage actionCancelWithCallID:callID
                                                               reason:reason
                                                             senderID:self.robotActionSenderID
                                                          recipientID:request.recipientID];
        self.pendingRobotActionCancellations[callID] = cancellation;
    }
    [self sendRobotActionMessage:cancellation];

    NSDictionary *holdResult = [[ROBAmberGestureExecutor shared]
        cancelCurrentGestureWithReason:reason];
    if ([self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
        // Defensive fallback for an inconsistent executor state. The normal
        // cancellation path invokes the run completion synchronously.
        [self finishControllerApprovedAmberGestureCallID:callID
                                                   result:@{
                                                       @"status": timedOut ? @"expired" : @"cancelled",
                                                       @"detail": reason,
                                                       @"arm_result": holdResult ?: @{}
                                                   }];
    }
}

- (void)startControllerApprovedAmberGestureForRequest:(ROBRobotActionMessage *)request
                                                 call:(ROBAIRobotToolCall *)call
{
    NSString *callID = request.callID;
    if (callID.length == 0 || call == nil ||
        self.pendingRobotActionRequests[callID] != request ||
        self.pendingRobotToolCalls[callID] != call) {
        return;
    }
    if (request.isExpired) {
        [self finishControllerApprovedAmberGestureCallID:callID
                                                   result:@{
                                                       @"status": @"expired",
                                                       @"detail": @"ROBController approval arrived after the play_gesture deadline; no arm trajectory was submitted."
                                                   }];
        return;
    }
    if (self.pendingRobotActionCancellations[callID] != nil) {
        [self finishControllerApprovedAmberGestureCallID:callID
                                                   result:@{
                                                       @"status": @"cancelled",
                                                       @"detail": @"The play_gesture call was cancelled before Cerebro could submit an arm trajectory."
                                                   }];
        return;
    }
    if (![self robotActionControllerIsFreshForRequest:request]) {
        [self finishControllerApprovedAmberGestureCallID:callID
                                                   result:@{
                                                       @"status": @"rejected",
                                                       @"detail": @"The accepting ROBController is no longer the fresh, current action console; no arm trajectory was submitted."
                                                   }];
        return;
    }
    if (self.controllerApprovedAmberGestureCallID.length > 0) {
        [self finishControllerApprovedAmberGestureCallID:callID
                                                   result:@{
                                                       @"status": @"failed",
                                                       @"detail": @"Another controller-approved Amber gesture still owns the executor."
                                                   }];
        return;
    }
    NSString *gesture = [request.arguments[@"gesture"] isKindOfClass:[NSString class]]
        ? request.arguments[@"gesture"] : nil;
    if (gesture.length == 0) {
        [self finishControllerApprovedAmberGestureCallID:callID
                                                   result:@{
                                                       @"status": @"rejected",
                                                       @"detail": @"The approved action did not contain a valid immutable gesture name."
                                                   }];
        return;
    }

    self.robotActionExecutionDeadlines[callID] =
        [NSDate dateWithTimeIntervalSinceNow:kRobotActionExecutionLifetimeSeconds];
    self.controllerApprovedAmberGestureCallID = callID;
    self.controllerApprovedAmberGestureExecutingStatus = [ROBRobotActionMessage
        actionStatusWithCallID:callID
                        state:ROBRobotActionStateExecuting
                       detail:@"Cerebro is executing the controller-approved immutable Amber gesture and awaiting measured completion."
                       result:@{
                           @"gesture": gesture,
                           @"execution_owner": @"Cerebro",
                           @"authorization": @"controller_approved_one_shot"
                       }
                     senderID:self.robotActionSenderID
                  recipientID:request.recipientID];

    __weak ROBMainViewController *weakSelf = self;
    [[ROBAmberGestureExecutor shared]
        executeControllerApprovedGesture:gesture
        completion:^(NSDictionary *result) {
            ROBMainViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf finishControllerApprovedAmberGestureCallID:callID result:result];
        }];

    if (![self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
        return;
    }
    if (![self sendRobotActionMessage:self.controllerApprovedAmberGestureExecutingStatus]) {
        [self cancelControllerApprovedAmberGestureCallID:callID
                                                   reason:@"The accepting ROBController disconnected before Cerebro could report execution; hold safely."
                                                 timedOut:NO];
    }
}

- (void)handleRobotActionMessage:(ROBRobotActionMessage *)message
{
    if (![self robotActionMessageIsAddressedToCerebro:message]) {
        return;
    }

    if (message.kind == ROBRobotActionMessageKindControllerHello) {
        BOOL currentControllerIsFresh = self.robotActionControllerLastSeen != nil &&
            [[NSDate date] timeIntervalSinceDate:self.robotActionControllerLastSeen] < kRobotActionControllerFreshnessSeconds;
        BOOL isCurrentController = [message.senderID isEqualToString:self.robotActionControllerID];
        if (self.robotActionControllerID.length == 0 || !currentControllerIsFresh || isCurrentController) {
            self.robotActionControllerID = message.senderID;
            self.robotActionControllerLastSeen = [NSDate date];
            self.robotActionControllerAcceptsActions = message.acceptsActions;
            self.robotActionControllerCapabilities = message.capabilities;
        }
        return;
    }

    if (message.callID.length == 0) {
        return;
    }

    // Bind every status/cancellation to the controller that received this
    // exact call. The selected controller may legitimately change while an
    // older call is waiting for a physical terminal result, and receipt of
    // this packet is itself fresh evidence from that original controller.
    // The v2 transport authenticates the operator role, but this application
    // sender string remains self-reported. Treat it as correlation, not as the
    // transport identity used by the server's authorization registry.
    ROBRobotActionMessage *request = self.pendingRobotActionRequests[message.callID];
    ROBAIRobotToolCall *call = self.pendingRobotToolCalls[message.callID];
    BOOL senderMatchesRequest = request.recipientID.length > 0 &&
        [message.senderID isEqualToString:request.recipientID];
    if (request == nil || call == nil || !senderMatchesRequest) {
        return;
    }

    BOOL isControllerExecutableGesture = [request.action isEqualToString:@"play_gesture"];
    BOOL isLocallyExecutingGesture = isControllerExecutableGesture &&
        [self.controllerApprovedAmberGestureCallID isEqualToString:message.callID];
    if (isLocallyExecutingGesture) {
        if (message.kind == ROBRobotActionMessageKindActionCancel) {
            [self cancelControllerApprovedAmberGestureCallID:message.callID
                                                       reason:message.detail.length > 0
                                                           ? message.detail
                                                           : @"ROBController cancelled the approved Amber gesture; stop or hold safely"
                                                     timedOut:NO];
            return;
        }
        if (message.kind != ROBRobotActionMessageKindActionStatus) {
            return;
        }
        if (message.state == ROBRobotActionStateAccepted) {
            // An immutable approval may be replayed after packet loss. Report
            // the existing execution; never enter the executor a second time.
            if (self.controllerApprovedAmberGestureExecutingStatus != nil) {
                [self sendRobotActionMessage:self.controllerApprovedAmberGestureExecutingStatus];
            }
            return;
        }
        if (message.isTerminal) {
            // Once accepted, Cerebro owns physical completion. A controller
            // terminal packet is treated as a stop request, never as evidence
            // that the measured arm target or hold was reached.
            NSString *reason = [NSString stringWithFormat:
                @"ROBController reported %@ while Cerebro owned Amber execution; stop or hold safely",
                [self robotActionStateString:message.state]];
            [self cancelControllerApprovedAmberGestureCallID:message.callID
                                                       reason:reason
                                                     timedOut:NO];
            return;
        }
        NSLog(@"Ignored controller-owned %@ status for locally executing play_gesture %@",
              [self robotActionStateString:message.state], message.callID);
        return;
    }

    if (isControllerExecutableGesture &&
        message.kind == ROBRobotActionMessageKindActionStatus) {
        if (message.state == ROBRobotActionStateAccepted) {
            [self startControllerApprovedAmberGestureForRequest:request call:call];
            return;
        }
        if (message.state == ROBRobotActionStateExecuting ||
            message.state == ROBRobotActionStateCompleted) {
            // ROBController approves this action but does not execute it. Do not
            // let a premature remote lifecycle status stand in for Cerebro's
            // gateway ACK and measured completion checks.
            [self finishControllerApprovedAmberGestureCallID:message.callID
                                                       result:@{
                                                           @"status": @"failed",
                                                           @"detail": @"ROBController must explicitly accept play_gesture and let Cerebro own execution and measured completion. No arm trajectory was submitted."
                                                       }];
            return;
        }
    }

    // Only an explicit terminal status can acknowledge physical disposition.
    // A peer-originated cancellation is merely a request and must never free
    // Gemini's blocking action slot.
    if (message.kind != ROBRobotActionMessageKindActionStatus) {
        return;
    }

    if ((message.state == ROBRobotActionStateAccepted || message.state == ROBRobotActionStateExecuting) &&
        self.robotActionExecutionDeadlines[message.callID] == nil) {
        if (request.isExpired) {
            ROBRobotActionMessage *cancellation = self.pendingRobotActionCancellations[message.callID];
            if (cancellation == nil) {
                cancellation = [ROBRobotActionMessage
                    actionCancelWithCallID:message.callID
                                    reason:@"Approval arrived after its deadline; stop or hold safely"
                                  senderID:self.robotActionSenderID
                               recipientID:request.recipientID];
                self.pendingRobotActionCancellations[message.callID] = cancellation;
            }
            [self.timedOutRobotToolCallIDs addObject:message.callID];
            [self sendRobotActionMessage:cancellation];
            return;
        }
        self.robotActionExecutionDeadlines[message.callID] =
            [NSDate dateWithTimeIntervalSinceNow:kRobotActionExecutionLifetimeSeconds];
    }

    if (!message.isTerminal) {
        NSLog(@"ROBController action %@ is %@: %@",
              message.callID, [self robotActionStateString:message.state],
              message.detail.length > 0 ? message.detail : @"");
        return;
    }

    [self.pendingRobotToolCalls removeObjectForKey:message.callID];
    [self.pendingRobotActionRequests removeObjectForKey:message.callID];
    [self.pendingRobotActionCancellations removeObjectForKey:message.callID];
    [self.robotActionExecutionDeadlines removeObjectForKey:message.callID];

    if ([self.geminiCancellingRobotToolCallIDs containsObject:message.callID]) {
        [self.geminiCancellingRobotToolCallIDs removeObject:message.callID];
        [self.timedOutRobotToolCallIDs removeObject:message.callID];
        // The controller's terminal cancellation is the acknowledgement that
        // releases the blocking Gemini tool slot.
        [self.robAI confirmToolCallCancellation:message.callID];
        return;
    }

    NSDictionary *messageResult = message.result != nil ? message.result : @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:messageResult];
    result[@"status"] = [self robotActionStateString:message.state];
    result[@"controller_id"] = message.senderID;
    if (message.detail.length > 0) {
        result[@"detail"] = message.detail;
    }
    if ([self.timedOutRobotToolCallIDs containsObject:message.callID]) {
        [self.timedOutRobotToolCallIDs removeObject:message.callID];
        result[@"status"] = @"expired";
        result[@"detail"] = @"The approved action exceeded its deadline and ROBController confirmed cancellation";
    }
    [self.robAI sendToolResponseWithCallID:message.callID name:call.name result:result];
}

- (void)robotActionBridgeTick:(NSTimer *)timer
{
    NSDate *now = [NSDate date];
    NSArray<NSString *> *callIDs = [self.pendingRobotActionRequests.allKeys copy];
    for (NSString *callID in callIDs) {
        ROBRobotActionMessage *request = self.pendingRobotActionRequests[callID];
        if (request == nil) {
            continue;
        }

        ROBRobotActionMessage *existingCancellation = self.pendingRobotActionCancellations[callID];
        NSDate *executionDeadline = self.robotActionExecutionDeadlines[callID];
        BOOL deadlineExpired = executionDeadline != nil
            ? [now compare:executionDeadline] != NSOrderedAscending
            : request.isExpired;
        if ([self.controllerApprovedAmberGestureCallID isEqualToString:callID]) {
            if (existingCancellation != nil) {
                [self cancelControllerApprovedAmberGestureCallID:callID
                                                           reason:existingCancellation.detail.length > 0
                                                               ? existingCancellation.detail
                                                               : @"The controller-approved Amber gesture was cancelled; stop or hold safely"
                                                         timedOut:[self.timedOutRobotToolCallIDs containsObject:callID]];
                continue;
            }
            if (deadlineExpired) {
                [self cancelControllerApprovedAmberGestureCallID:callID
                                                           reason:@"Cerebro's controller-approved Amber gesture deadline expired; stop or hold safely"
                                                         timedOut:YES];
                continue;
            }
            if (![self robotActionControllerIsFreshForRequest:request]) {
                [self cancelControllerApprovedAmberGestureCallID:callID
                                                           reason:@"The approving ROBController is no longer fresh or current; stop or hold safely"
                                                         timedOut:NO];
                continue;
            }
            if (self.controllerApprovedAmberGestureExecutingStatus != nil) {
                [self sendRobotActionMessage:self.controllerApprovedAmberGestureExecutingStatus];
            }
            continue;
        }

        if (existingCancellation != nil) {
            // Retransmit the exact same immutable cancellation ID after
            // reconnects until a terminal result arrives.
            [self sendRobotActionMessage:existingCancellation];
            continue;
        }

        if (!deadlineExpired) {
            // Reusing both message_id and call_id makes loss recovery
            // idempotent. ROBController replays its latest status/result.
            [self sendRobotActionMessage:request];
            continue;
        }

        ROBRobotActionMessage *cancellation =
            [ROBRobotActionMessage actionCancelWithCallID:callID
                                                   reason:@"Cerebro action deadline expired; stop or hold safely"
                                                 senderID:self.robotActionSenderID
                                              recipientID:request.recipientID];
        self.pendingRobotActionCancellations[callID] = cancellation;
        [self.timedOutRobotToolCallIDs addObject:callID];
        [self sendRobotActionMessage:cancellation];
        // Never free a physical action slot merely because its request or
        // status packet may have been lost. Wait for a terminal controller
        // status, even if Cerebro still believes the state was only pending.
    }

    BOOL controllerIsFresh = self.robotActionControllerLastSeen != nil &&
        [now timeIntervalSinceDate:self.robotActionControllerLastSeen] < kRobotActionControllerFreshnessSeconds;
    if (!controllerIsFresh) {
        self.robotActionControllerAcceptsActions = NO;
    }
}

#pragma mark - ROBSpeechDelegate

- (void) willStartProcessingSpeech
{
    NSLog(@"willStartProcessingSpeech ROBMainViewController");
    [self.robAI sendAudioStreamEnd];
}

- (void) didFinishProcessingSpeech
{
    NSLog(@"didFinishProcessingSpeech ROBMainViewController");
    // Every ROB response suppresses microphone buffers to avoid
    // feeding the speaker output back to Gemini. Explicitly restore capture
    // after the final queued utterance instead of only resetting the text gate.
    [self startListeningAgain];
}

- (void) willSpeakWord:(NSRange)characterRange ofString:(NSString *)string {
    NSLog(@"willSpeakWord ROBMainViewController");
}

- (void)didCaptureAudioBuffer:(AVAudioPCMBuffer *)buffer
{
    [self.robAI sendAudioBuffer:buffer];
}

- (void) inputText:(NSString *)textInput
{
    textInput = [[textInput stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    // Only suppress duplicate local transcript turns while the raw-audio Live
    // session is actually ready. During reconnects, realtime text remains a
    // useful bounded fallback and is queued by ROBAI until setup completes.
    BOOL geminiOwnsMicrophone = self.robAI.isLiveSessionReady && self.robAI.streamsMicrophoneAudio;
    NSArray<NSString *> *addressTokens = [textInput componentsSeparatedByCharactersInSet:
        [[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    BOOL addressesROB = [addressTokens containsObject:@"robbie"] ||
        [addressTokens containsObject:@"rob"] ||
        [addressTokens containsObject:@"robot"];
    BOOL shouldAcknowledgeAcceptedTurn = NO;

    // Safety phrases stay local and effective even when Gemini is unavailable
    // or intentionally turned off.
    if ([textInput containsString:@"stop"] || [textInput containsString:@"wait"] || [textInput containsString:@"don't move"] || [textInput containsString:@"do not move"])
    {
        if (self.stageShowCoordinator.isRunning) {
            [self.stageShowCoordinator cancelWithReason:@"Local spoken stop"];
        } else {
            [self applyPrioritySoftwareStopWithReason:@"Local spoken stop"];
        }
        (void)[[ROBAmberGestureExecutor shared]
            cancelCurrentGestureWithReason:@"Local spoken stop"];
        NSDictionary *armResult = [[ROBAmberGestureExecutor shared] requestPriorityHold];
        NSString *armStatus = [armResult[@"arm_status"] isKindOfClass:[NSString class]]
            ? armResult[@"arm_status"] : @"unavailable";
        NSString *stopResponse = [armStatus isEqualToString:@"hold_requested"]
            ? @"Base motion stopped. I requested an arm hold; use the physical emergency stop if needed."
            : @"Base motion stopped. No verified position-mode arm hold was available.";
        [self.speechBox sayIt:stopResponse];
        return;
    }

    if (addressesROB)
    {
        self.ignoreText = false;
        NSLog(@"Listening for spoken input");
        [self resetSpeechResponseAttentionTimer];
        
        NSArray *greeting_acknowledgements = @[@"Hey there", @"How are you", @"What's up!", @"Greetings"];
        NSString *greeting_acknowledgement = [greeting_acknowledgements objectAtIndex:arc4random_uniform((uint32_t)greeting_acknowledgements.count)];
        
        
        if ([textInput isEqualToString:@"robbie"] || [textInput isEqualToString:@"hey rob"] || [textInput isEqualToString:@"rob"] || [textInput isEqualToString:@"robot"])
        {
            // A wake-only utterance is acknowledged locally and immediately;
            // it must never wait on provider VAD or a network round trip.
            [self.speechBox sayIt:greeting_acknowledgement];
            return;
        } else {
            shouldAcknowledgeAcceptedTurn = YES;
        }
    }
    if (!geminiOwnsMicrophone && [textInput containsString:@"follow"])
    {
        // Do not let the fallback transcript path become a second motion
        // authority. Following must be requested through the future validated
        // ROBController bridge, just like every other physical action.
        self.followingMode = false;
        [self.speechBox sayIt:@"Follow mode requires ROBController authorization"];
        return;
    }
    if (!self.ignoreText) {
        if (geminiOwnsMicrophone) {
            // Do not resend the transcript. It is only a local signal that a
            // raw-audio turn should receive a bounded Gemini response.
            if (!self.speechBox.isSpeaking) {
                [self.robAI noteMicrophoneTurnAwaitingResponseForTranscript:textInput];
                [self speakConfiguredAcknowledgementIfNotQueued];
            }
        } else {
            NSLog(@"textInput = %@", textInput);
            NSInteger speechWordiness = self.torsoControlsViewController.speechWordinessChoice.selectedSegment;
            BOOL accepted = [self.robAI sendText:textInput speechWordiness:speechWordiness];
            if (accepted) {
                [self appendConversationText:textInput fromUser:YES];
            }
            if (accepted && shouldAcknowledgeAcceptedTurn) {
                [self speakConfiguredAcknowledgementIfNotQueued];
            }
        }
    } else if (self.ignoreText) {
        NSLog(@"!!!!!!!!!!!!  IGNORING TEXT !!!!!!!!!!!!!!!");
        NSLog(@"textInput = %@", textInput);
    }
    
    self.audioInputTaskController.textView.string = [self.audioInputTaskController.textView.string stringByAppendingString:[NSString stringWithFormat:@"\n%@\n",textInput]];
}

- (void) resetSpeechResponseAttentionTimer {
    if (self.speechResponseAttentionTimer) {
        [self.speechResponseAttentionTimer invalidate];
    }
    self.speechResponseAttentionTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:NO block:^(NSTimer * _Nonnull timer) {
        NSLog(@"Ignoring spoken input");
        self.ignoreText = true;
    }];
}

- (void) makeTextViewFirstResponder:(NSTextView *)textView {
    [[[self tastsWindowController] window] makeFirstResponder:textView];
}

- (void) clearInputTextMessage
{
    [self.autoNetServer sendString:@"Clear input text message"];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self configureConversationTranscript];
    [self configureMainWorkspace];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminate:)
                                                 name:NSApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showControllerInputDiagnostics:)
                                                 name:ROBShowControllerInputDiagnosticsNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(developmentModeDidChange:)
                                                 name:ROBDevelopmentModeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(geminiVideoSourceSettingsDidChange:)
                                                 name:ROBGeminiVideoSourceSettingsDidChangeNotification
                                               object:nil];
    //-----------------------------
    //---- Setup User Defaults ----
    if (![[NSUserDefaults standardUserDefaults] valueForKey:@"inputLanguage"])
    {
        [[NSUserDefaults standardUserDefaults] setValue:@"en-US" forKey:@"inputLanguage"];
    }
    if (![[NSUserDefaults standardUserDefaults] valueForKey:@"outputLanguage"])
    {
        [[NSUserDefaults standardUserDefaults] setValue:@"en-US" forKey:@"outputLanguage"];
    }
    //-----------------------------
    self.NiTE_IS_ON = false;
    self.actualValue = 0.0;
    self.targetValue = 0.0;
    self.inputLanguage = [[NSUserDefaults standardUserDefaults] valueForKey:@"inputLanguage"];
    self.followingMode = false;
    self.followingSpeed = 0;
    self.currentPersonTrackingID = 1;
    self.ignoreText = true;
    self.isNeckLifted = NO;
    NSString *resolvedHostName = [[NSHost currentHost] name];
    NSString *hostName = resolvedHostName.length > 0 ? resolvedHostName : @"Mac";
    self.robotActionSenderID = [NSString stringWithFormat:@"Cerebro:%@", hostName];
    self.autonomyCoordinator = [[ROBAutonomyCoordinator alloc] initWithRobotID:self.robotActionSenderID];
    self.autonomyCoordinator.delegate = self;
    self.stageShowCoordinator = [[ROBStageShowCoordinator alloc] init];
    self.stageShowCoordinator.delegate = self;
    [self.stageShowCoordinator reloadLocalImprovisationProvider];
    self.robotActionControllerCapabilities = @[];
    self.pendingRobotToolCalls = [NSMutableDictionary dictionary];
    self.pendingRobotActionRequests = [NSMutableDictionary dictionary];
    self.pendingRobotActionCancellations = [NSMutableDictionary dictionary];
    self.robotActionExecutionDeadlines = [NSMutableDictionary dictionary];
    self.geminiCancellingRobotToolCallIDs = [NSMutableSet set];
    self.timedOutRobotToolCallIDs = [NSMutableSet set];
    //-----
    //Initialize AutoNet
    self.autoNetServer = [[AutoNetServer alloc] initWithService:ROBControlPairing.serviceType
                                                          port:12345
                                                  dataDelegate:self];
    NSError *error = nil;
    [self.autoNetServer startAndReturnError:&error];
    if (error != nil) {
        NSLog(@"AutoNetServer Error, %@", [error localizedDescription]);
    }
    self.robotActionBridgeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                   target:self
                                                                 selector:@selector(robotActionBridgeTick:)
                                                                 userInfo:nil
                                                                  repeats:YES];
    //-----
    //Initilze R.O.B.
    self.robAI = [[ROBAI alloc] init];
    self.robAI.delegate = self;
    [[ROBInsta360CameraService shared] setGeminiFrameConsumer:self.robAI];
    
    self.serialBox = [ROBSerialBox new];
    self.serialBox.delegate = self;
    [self.serialBox initialize_connection];
    
    //---------------------------------------------------------
    //Enable one of these to auto allow a controller to take over... otherwise a controller is required to intiate robot control!
    //VRController
    [self.serialBox switchToMasterControllerID:@"Brain"];
    //---------------------------------------------------------
    
    self.speechBox = [ROBSpeechBox new];
    self.speechBox.delegate = self;

    // Start capture in wake-word mode. A recognized ROB/Robbie/Robot address
    // opens the bounded continuation window; unrelated room speech at launch
    // must not be treated as a failed Gemini turn.
    self.ignoreText = YES;
    [self.speechBox startRecognizer];
    
    self.outputLanguage = [[NSUserDefaults standardUserDefaults] valueForKey:@"outputLanguage"];
    [self.speechBox setOutputLanguage:self.outputLanguage];
    [self.robAI start];
    // The Messages bridge owns isolated text-only AI sessions. It never uses
    // this controller's SpeechBox or the embodied room-conversation session.
    [[ROBMessagesBridge shared] start];
    
    [self showROBControls];
    [self showROB_Torso_Controls];
    [self showROBNavigation];
    [self ensureMainCameraRuntime];
    [self synchronizeDevelopmentCameraDiagnostics];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        [[self.tastsWindowController window] makeKeyAndOrderFront:nil];
    });
}

- (void)showControllerInputDiagnostics:(NSNotification *)notification
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        return;
    }
    if (self.controllerDiagnosticsWindowController == nil) {
        SCNView *view = [[SCNView alloc] initWithFrame:NSMakeRect(0, 0, 960, 620)];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 960, 620)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = @"ROB Received VR Controller Diagnostics";
        window.contentView = view;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerDiagnosticsWindowWillClose:)
                                                     name:NSWindowWillCloseNotification
                                                   object:window];
        self.controllerDiagnosticsWindowController = [[NSWindowController alloc] initWithWindow:window];
        self.scnViewController = [[ROBSCNViewController alloc] initWithRobo_scnView:view];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.controllerDiagnosticsWindowController showWindow:self];
}

- (void)updateBaseIRFrontLeft:(NSInteger)frontLeft
                   frontRight:(NSInteger)frontRight
                         left:(NSInteger)left
                        right:(NSInteger)right
                     backLeft:(NSInteger)backLeft
                    backRight:(NSInteger)backRight
                     received:(NSTimeInterval)receivedAtUptime
{
    [self.scnViewController updateWithIRDistances:@[@(frontLeft), @(frontRight), @(left), @(right), @(backLeft), @(backRight)]
                                  receivedAtUptime:receivedAtUptime];
}

- (void)updateBaseLegacyIRWarningFront:(BOOL)front
                                  back:(BOOL)back
                              received:(NSTimeInterval)receivedAtUptime
{
    [self.scnViewController updateWithLegacyIRWarningFront:front
                                                      back:back
                                          receivedAtUptime:receivedAtUptime];
}

- (void)controllerDiagnosticsWindowWillClose:(NSNotification *)notification
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowWillCloseNotification
                                                  object:notification.object];
    [self.scnViewController invalidate];
    self.scnViewController = nil;
    self.controllerDiagnosticsWindowController = nil;
}

- (void)developmentModeDidChange:(NSNotification *)notification
{
    [self synchronizeDevelopmentCameraDiagnostics];
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        [self.controllerDiagnosticsWindowController close];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self shutdownCerebroRuntime];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self shutdownCerebroRuntime];
}

- (void)shutdownCerebroRuntime
{
    if (self.runtimeIsShuttingDown) {
        return;
    }
    self.runtimeIsShuttingDown = YES;
    [self.robotActionBridgeTimer invalidate];
    self.robotActionBridgeTimer = nil;

    for (NSString *callID in self.pendingRobotActionRequests.allKeys) {
        ROBRobotActionMessage *request = self.pendingRobotActionRequests[callID];
        ROBRobotActionMessage *cancellation =
            [ROBRobotActionMessage actionCancelWithCallID:callID
                                                   reason:@"Cerebro is shutting down; stop or hold safely"
                                                 senderID:self.robotActionSenderID
                                              recipientID:request.recipientID];
        [self sendRobotActionMessage:cancellation];
    }
    self.localAmberGestureCallID = nil;
    (void)[[ROBAmberGestureExecutor shared]
        cancelCurrentGestureWithReason:@"Cerebro is shutting down"];
    (void)[[ROBAmberGestureExecutor shared] requestPriorityHold];
    [[ROBAmberDebugAuthority shared] revoke];
    [[ROBAmberGatewayTunnel shared] disconnect];
    [[ROBMessagesBridge shared] stop];
    [self.baseSerialConsoleWindowController close];
    self.baseSerialConsoleWindowController = nil;
    [[ROBInsta360CameraService shared] setGeminiVideoDemandActive:NO];
    [[ROBInsta360CameraService shared] setGeminiFrameConsumer:nil];
    [self.robAI disconnect];
    if (self.stageShowCoordinator.isRunning) {
        [self.stageShowCoordinator cancelWithReason:@"Cerebro is shutting down"];
    }
    [self.autonomyCoordinator shutdown];
    [self.bellyCameraWindowController setNavigationDemandActive:NO];
    [self.speechBox shutdown];
}

#pragma mark - Controller-authorized autonomy

- (void)applyPrioritySoftwareStopWithReason:(NSString *)reason
{
    self.currentPersonTrackingID = -1;
    self.followingMode = false;
    [self.speechBox stopIt:nil];
    if (self.autonomyCoordinator.active) {
        [self.autonomyCoordinator stopWithReason:reason];
    }
    [self.serialBox stopBaseMotionAndDropHeartbeat];
    [self.serialBox switchToMasterControllerID:@"Brain"];
    [self publishControlAuthorityState];
    NSLog(@"Priority software stop applied: %@. Amber hold is handled by the explicit arm stop lane.", reason);
}

#pragma mark - Stage show coordinator

- (void)stageShowCoordinator:(ROBStageShowCoordinator *)coordinator
                       speak:(NSString *)text
                       cueID:(NSString *)cueID
{
    __weak ROBStageShowCoordinator *weakCoordinator = coordinator;
    [self.speechBox sayStageShowText:text completion:^(BOOL finished) {
        ROBStageShowCoordinator *strongCoordinator = weakCoordinator;
        if (strongCoordinator == nil) {
            return;
        }
        // A cancellation is still a terminal synthesizer event. If the show
        // itself was stopped, speechDidFinish safely ignores this callback.
        [strongCoordinator speechDidFinish];
    }];
}

- (void)stageShowCoordinator:(ROBStageShowCoordinator *)coordinator
           requestGeminiTurn:(NSString *)prompt
                       cueID:(NSString *)cueID
                   requestID:(NSString *)requestID
                     timeout:(NSTimeInterval)timeout
{
    if (self.robAI.isLiveSessionReady) {
        [self.robAI sendText:prompt contextID:requestID];
    } else {
        (void)[coordinator failGeminiTurn:@"Gemini Live is unavailable" requestID:requestID];
    }
}

- (void)stageShowCoordinator:(ROBStageShowCoordinator *)coordinator
            cancelGeminiTurn:(NSString *)requestID
{
    [self.robAI cancelTextTurnWithContextID:requestID];
}

- (void)stageShowCoordinator:(ROBStageShowCoordinator *)coordinator
              requestGesture:(NSString *)name
                       cueID:(NSString *)cueID
                     timeout:(NSTimeInterval)timeout
{
    NSArray<ROBSaberTransform *> *transforms =
        [[ROBSaberChoreographyCatalog shared] transformsForGesture:name];
    if (transforms == nil) {
        (void)[coordinator completeGestureWithSuccess:NO
                                                detail:@"Gesture is not in the calibrated Stage Show choreography catalog"];
        return;
    }
    if (![ROBSaberSafetyGate shared].isArmed) {
        (void)[coordinator completeGestureWithSuccess:NO
                                                detail:@"Supervised saber choreography is not armed by the operator"];
        return;
    }
    if (self.serialBox == nil) {
        (void)[coordinator completeGestureWithSuccess:NO detail:@"Amber arm controller is unavailable"];
        return;
    }
    NSTimeInterval sequenceDuration = 0;
    for (ROBSaberTransform *transform in transforms) sequenceDuration += transform.duration;
    if (sequenceDuration > timeout) {
        (void)[coordinator completeGestureWithSuccess:NO detail:@"Gesture cue is shorter than its bounded choreography"];
        return;
    }
    self.saberChoreographyGeneration += 1;
    [self executeSaberTransforms:transforms index:0
                      generation:self.saberChoreographyGeneration coordinator:coordinator];
}

- (void)executeSaberTransforms:(NSArray<ROBSaberTransform *> *)transforms
                         index:(NSUInteger)index
                    generation:(NSUInteger)generation
                   coordinator:(ROBStageShowCoordinator *)coordinator
{
    if (generation != self.saberChoreographyGeneration || ![ROBSaberSafetyGate shared].isArmed) return;
    if (index >= transforms.count) {
        (void)[coordinator completeGestureWithSuccess:YES detail:@"Supervised saber choreography completed"];
        return;
    }
    ROBSaberTransform *transform = transforms[index];
    BOOL accepted = [self.serialBox commandRightAmberSaberX:transform.x y:transform.y z:transform.z
                                                       roll:transform.roll pitch:transform.pitch yaw:transform.yaw
                                                   duration:transform.duration];
    if (!accepted) {
        (void)[coordinator completeGestureWithSuccess:NO detail:@"Saber transform failed the actuator-side bounds check"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(transform.duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self executeSaberTransforms:transforms index:index + 1 generation:generation coordinator:coordinator];
    });
}

- (void)stageShowCoordinatorDidRequestStop:(ROBStageShowCoordinator *)coordinator
{
    self.saberChoreographyGeneration += 1;
    [ROBSaberSafetyGate shared].isArmed = NO;
    [self applyPrioritySoftwareStopWithReason:@"Stage show stopped"];
}

- (void)autonomyCoordinator:(ROBAutonomyCoordinator *)coordinator
             applyLeftTread:(double)leftTread
                 rightTread:(double)rightTread
                 speedScale:(double)speedScale
{
    if (!coordinator.active || self.serialBox == nil) {
        return;
    }

    ROBBaseControllerModel *model = [ROBBaseControllerModel new];
    model.touchPadPointL = CGPointMake(0.0, MAX(-0.25, MIN(0.25, leftTread)));
    model.touchPadPointR = CGPointMake(0.0, MAX(-0.25, MIN(0.25, rightTread)));
    model.Lat = 0;
    model.Long = 0;
    model.tredBrakeLock = false;
    model.flipperForwardIsDown = false;
    model.flipperRelaxBrake = false;
    model.flipperBackwardIsDown = false;
    model.flipperBrakeLock = true;
    model.lact1 = false;
    model.lact2 = false;
    model.lact3 = false;
    model.speed = MAX(5.0, MIN(35.0, speedScale * 100.0));
    model.speed_playPause = false;
    model.speed_forward_reverse = true;
    model.textInput = @"";
    [self.serialBox controllerId:@"Autonomous" controllerModelData:model];
    if (![self.serialBox.masterControllerID isEqualToString:@"Autonomous"]) {
        [self.serialBox switchToMasterControllerID:@"Autonomous"];
        [self publishControlAuthorityState];
    }
}

- (void)autonomyCoordinatorDidRequestBaseStop:(ROBAutonomyCoordinator *)coordinator
{
    [self.serialBox stopBaseMotionAndDropHeartbeat];
    if ([self.serialBox.masterControllerID isEqualToString:@"Autonomous"]) {
        [self.serialBox switchToMasterControllerID:@"Brain"];
        [self publishControlAuthorityState];
    }
}

- (void)autonomyCoordinator:(ROBAutonomyCoordinator *)coordinator
              publishStatus:(ROBAutonomySessionMessage *)status
{
    NSData *archive = [ROBAutonomySessionWireCodec archiveMessage:status
                                                     legacySender:self.robotActionSenderID];
    if (archive != nil) {
        [self.autoNetServer sendMessage:archive];
    }
}

- (void)autonomyCoordinator:(ROBAutonomyCoordinator *)coordinator
   requestConversationPrompt:(NSString *)prompt
{
    NSInteger wordiness = self.torsoControlsViewController.speechWordinessChoice.selectedSegment;
    [self.robAI sendText:prompt speechWordiness:wordiness];
}


- (void) startListeningAgain
{
    self.ignoreText = NO;
    [self.speechBox startRecognizer];
    [self resetSpeechResponseAttentionTimer];
}


- (void) beginToIgnore
{
    self.ignoreText = YES;
}

- (void) didSeeNewPeople:(NSArray *)observations {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.autonomyCoordinator updatePersonVisible:observations.count > 0];
        if (!self.isNeckLifted) {
            float targetHeadTilt = 6168.94; //This is the upright neck
            float targetHeadUpperNeckTilt = 6868.81;
            if (self.liftNeckAnimationTimer == nil) {
                self.liftNeckAnimationTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
                    //exit condition
                    if (self.currentPerson_tilt >= targetHeadTilt-1 && self.currentPerson_tilt <= targetHeadTilt+1 &&
                        self.currentPerson_upperNeckTilt >= targetHeadUpperNeckTilt-1 && self.currentPerson_upperNeckTilt <= targetHeadUpperNeckTilt+1) {
                        self.isNeckLifted = YES;
                        [self.liftNeckAnimationTimer invalidate];
                        self.liftNeckAnimationTimer = nil;
                        return;
                    }
                    float currentHeadTilt = [self.torsoControlsViewController.headTilt floatValue];
                    float currentHeadUpperNeckTilt = [self.torsoControlsViewController.headUpperNeckTilt floatValue];
                    float deltaHeadTilt = targetHeadTilt - currentHeadTilt;
                    float deltaHeadUpperNeckTilt = targetHeadUpperNeckTilt - currentHeadUpperNeckTilt;
                    float deltaTilt_finalValue = 0.0;
                    
                    float neckSpeed = 50.0;
                    if (deltaHeadTilt > neckSpeed) {
                        deltaTilt_finalValue = neckSpeed;
                    }
                    if (deltaHeadTilt < -neckSpeed) {
                        deltaTilt_finalValue = -neckSpeed;
                    }
                    if (deltaHeadTilt > -neckSpeed && deltaHeadTilt <= neckSpeed) {
                        deltaTilt_finalValue = deltaHeadTilt;
                    }
                    
                    float upperNeckSpeed = 50.0;
                    float deltaUpperNeckTilt_finalValue = 0.0;
                    if (deltaHeadUpperNeckTilt > upperNeckSpeed) {
                        deltaUpperNeckTilt_finalValue = upperNeckSpeed;
                    }
                    if (deltaHeadUpperNeckTilt < -upperNeckSpeed) {
                        deltaUpperNeckTilt_finalValue = -upperNeckSpeed;
                    }
                    if (deltaHeadUpperNeckTilt > -upperNeckSpeed && deltaHeadUpperNeckTilt <= upperNeckSpeed) {
                        deltaUpperNeckTilt_finalValue = deltaHeadUpperNeckTilt;
                    }
                    
                    self.currentPerson_tilt = [self.torsoControlsViewController.headTilt floatValue] + deltaTilt_finalValue;
                    self.currentPerson_upperNeckTilt = [self.torsoControlsViewController.headUpperNeckTilt floatValue] + deltaUpperNeckTilt_finalValue;
                    
                    [[self.torsoControlsViewController headTilt] setFloatValue:self.currentPerson_tilt];
                    [[self.torsoControlsViewController headUpperNeckTilt] setFloatValue:self.currentPerson_upperNeckTilt];
                }];
            }
            return;
        } else {
            self.currentPerson_pan = [self.torsoControlsViewController.headPan floatValue];
            self.currentPerson_tilt = [self.torsoControlsViewController.headTilt floatValue];
            self.currentPerson_upperNeckTilt = [self.torsoControlsViewController.headUpperNeckTilt floatValue];
            
            id observation = observations.firstObject;
            
            for (id observation in observations) {
                //detectFaceRequest = <VNFaceObservation: 0x81403ce00> 82B411FB-A8EF-45B1-8545-FB0FEC8F978B
                // VNDetectFaceRectanglesRequestRevision3
                // confidence=0.713637
                // boundingBox=[0.847449, 0.470797, 0.175094, 0.311277]
                
                [observation boundingBox];
                if ([observation confidence] > 0.6) {
                    [self trackingPerson:@"1" position:[observation boundingBox]];
                }
            }
        }
    });

}

- (void)didCaptureCameraSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    [self.robAI sendVideoSampleBuffer:sampleBuffer];
}

- (void)didCaptureAlignedDepthData:(NSData *)depthData
                             width:(NSUInteger)width
                            height:(NSUInteger)height
                          sequence:(uint64_t)sequence
              timestampNanoseconds:(uint64_t)timestampNanoseconds
{
    if (width == 0 || height == 0 || width > NSUIntegerMax / height) {
        return;
    }
    NSUInteger pixels = width * height;
    if (pixels > NSUIntegerMax / sizeof(uint16_t) ||
        depthData.length != pixels * sizeof(uint16_t)) {
        return;
    }
    self.latestAlignedDepthFrame = [[ROBAlignedDepthFrame alloc]
        initWithMillimetersLittleEndian:depthData
                                 width:width
                                height:height
                              sequence:sequence
                  timestampNanoseconds:timestampNanoseconds];
}

- (void)clearAlignedDepthFrame
{
    self.latestAlignedDepthFrame = nil;
}

- (void) trackingPerson:(NSString *)userID position:(NSRect)headPosition
{
    //Is tracking enabled?
    
        if (self.torsoControlsViewController.headTracking_enabled.state == NSControlStateValueOn) {
            float center_x = headPosition.origin.x + headPosition.size.width/2.0;
            float center_y = headPosition.origin.y + headPosition.size.height/2.0;
            [self trackingPerson:userID x:center_x y:center_y z:1.0];
        }
}

- (void) trackingPerson:(NSString *)userID x:(float)x y:(float)y z:(float)z
{
    {
        self.currentPerson_positionX = x;
        self.currentPerson_positionY = y;
        self.currentPerson_positionZ = z;
        
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            
            self.currentPerson_tilt = 6168.94;

            float pan_speed = 100;
            float upperNeckTilt_speed = 60;
            
            if (x > 0.55)
                self.currentPerson_pan = self.currentPerson_pan - (pan_speed * (x-0.55));
            if (x < 0.45)
                self.currentPerson_pan = self.currentPerson_pan + (pan_speed * (0.45-x));
            if (y > 0.55)
                self.currentPerson_upperNeckTilt = self.currentPerson_upperNeckTilt + (upperNeckTilt_speed * (y-0.55));
            if (y < 0.45)
                self.currentPerson_upperNeckTilt = self.currentPerson_upperNeckTilt - (upperNeckTilt_speed * (0.45-y));
            
            // !!! CLAMP VALUES SO WE DON"T BREAK SOMETHING EXPENSIVE LIKE THE CAMERA ON THE HEAD !!!
            if (self.currentPerson_upperNeckTilt > 7400) {
                self.currentPerson_upperNeckTilt = 7400;
            }
            
            [[self.torsoControlsViewController headPan] setFloatValue:self.currentPerson_pan];
            [[self.torsoControlsViewController headUpperNeckTilt] setFloatValue:self.currentPerson_upperNeckTilt];
        });
    }
    
    return;
    
    
    if (self.followingMode)
    {
        float xOffset_L = (x > kTrackingMidpointX) ? 0.8 : -0.8;
        float xOffset_R = (x > kTrackingMidpointX) ? -0.8 : 0.8;
        
        float controller_LeftStick_reducer = 0.0;
        float controller_RightStick_reducer = 0.0;
        float controller_zLeftStick = 0.0;
        float controller_zRightStick = 0.0;
        
        
        if (y < kTrackingMidpointY - 50)
        {
            //Head Should Look Down
        }
        else if (y > kTrackingMidpointY + 50)
        {
            //Head Should Look Up
        }
        else if (x > kTrackingMidpointX + 50)
        {
            controller_LeftStick_reducer = 0.0;
            controller_RightStick_reducer = xOffset_R;
        }
        else if (x < kTrackingMidpointX - 50)
        {
            controller_LeftStick_reducer = xOffset_L;
            controller_RightStick_reducer = 0.0;
        }
        else if (z > kMAXFOLLOWDISTANCE)
        {
            //Send forward commands
            controller_zLeftStick = 0.5;
            controller_zRightStick = 0.5;
        }
        else if (z < kMAXFOLLOWDISTANCE - 25)
        {
            //Send backward commands
            controller_zLeftStick = -0.5;
            controller_zRightStick = -0.5;
        }
        
        
        
        
        //Send backwards commandss
        ROBBaseControllerModel *controllerModelData = [ROBBaseControllerModel new];
        controllerModelData.touchPadPointL = CGPointMake(controller_zLeftStick, controller_LeftStick_reducer);
        controllerModelData.touchPadPointR = CGPointMake(controller_zRightStick, controller_RightStick_reducer);
        controllerModelData.Lat = 0;
        controllerModelData.Long = 0;
        controllerModelData.tredBrakeLock = false;
        controllerModelData.flipperForwardIsDown = false;
        controllerModelData.flipperRelaxBrake = false;
        controllerModelData.flipperBackwardIsDown = false;
        controllerModelData.flipperBrakeLock = false;
        controllerModelData.lact1 = true;
        controllerModelData.lact2 = false;
        controllerModelData.lact3 = false;
        controllerModelData.speed = kMaxFollowingSpeed;
        controllerModelData.speed_playPause = false;
        controllerModelData.speed_forward_reverse = false;
        controllerModelData.textInput = @"";
        
        [self.serialBox controllerId:@"Autonomous" controllerModelData:controllerModelData];
        //user1 = 517.31, 174.51, 1825.00
    }
}

#pragma mark - HumanTrackingDelegate

- (void) heartbeat_NiTE
{
    self.pulse_count++;
}


- (void) startHeartbeatNiTE_ResetTimer
{
}

- (void) didTrackHumans:(NSArray *)humanObservations
{
    for (VNDetectedObjectObservation *observation in humanObservations)
    {
        CGRect boundingBox = observation.boundingBox;
        CGFloat midx = CGRectGetMidX(boundingBox);
        CGFloat midy = CGRectGetMidY(boundingBox);
        NSLog(@"human = (%f, %f) --- %@", midx, midy, observation.uuid.UUIDString);
        [self trackingPerson:@"person1" x:midx y:midy z:1];
        break;
    }
}

#pragma mark - AudioInputMethods - NSTextViewDelegate

- (IBAction)resetTranscript:(id)sender
{
    [self.conversationMessages removeAllObjects];
    self.lastConversationUserText = nil;
    self.lastConversationUserDate = nil;
    [self.conversationTableView reloadData];
    [self saveConversationLog];
    [self.audioInputTaskController resetTranscript];
    
}

- (IBAction)sendROBChatText:(id)sender
{
    NSString *text = [self.speechTextView.string
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        NSBeep();
        return;
    }
    if (!self.robAI.isGeminiConnectionEnabled) {
        [self.speechBox sayIt:@"Gemini is turned off. Use the Gemini controls to connect."];
        return;
    }

    NSInteger wordiness = self.torsoControlsViewController.speechWordinessChoice.selectedSegment;
    if ([self.robAI sendText:text speechWordiness:wordiness]) {
        [self appendConversationText:text fromUser:YES];
        self.speechTextView.string = @"";
        [self.view.window makeFirstResponder:self.speechTextView];
    } else {
        NSBeep();
    }
}

- (void)textDidChange:(NSNotification *)notification {
    // The lower editor is a message composer. Text is submitted only by the
    // Send button so partial keystrokes never become separate ROB AI turns.
}

#pragma mark -


- (void) setVolume:(int)volume
{
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"set volume output volume %i --100%", volume]];
    [script executeAndReturnError:nil];
}


- (void) setROBInputLanguage:(NSString *)language
{
    if (self.inputLanguage != language)
    {
        [[NSUserDefaults standardUserDefaults] setValue:language forKey:@"inputLanguage"];
        self.inputLanguage = language;
    }
}


- (void) setROBOutputLanguage:(NSString *)language
{
    if (self.outputLanguage != language)
    {
        [[NSUserDefaults standardUserDefaults] setValue:language forKey:@"outputLanguage"];
        self.outputLanguage = language;
        [self.speechBox setOutputLanguage:language];
    }
}



- (void) joinWifi:(NSString *)wifiCredentials
{
    // Using airport private framework app
    // @"/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport -s -x"
    
    // List all Networks
    // @"/usr/sbin/networksetup -listnetworkserviceorder"
    
    // Join Network Example
    // @"/usr/sbin/networksetup -setairportnetwork en0 Internet"
    
    NSArray *wifiElements = [wifiCredentials componentsSeparatedByString:@":"];
    
    NSString *ssid = wifiElements[0];
    NSString *password = wifiElements[1];
    
    NSString *joining_wifiString = [NSString stringWithFormat:@"Joining %@", ssid];
    [self.speechBox sayIt:joining_wifiString];
    
    self.joinWifiTaskController = [JoinWifiTaskController new];
    self.joinWifiTaskController.delegate = self;
    [self.joinWifiTaskController startTask:self withDevice:@"en1" ssid:ssid password:password];
}

- (NSString *)pairingDeviceNameWithDefault:(NSString *)defaultName
                                      role:(NSString *)roleDescription
{
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Name this %@", roleDescription];
    alert.informativeText = @"Use a name that identifies one physical device. Cerebro issues a unique credential so this device can be revoked independently.";
    NSTextField *nameField = [NSTextField textFieldWithString:defaultName];
    nameField.frame = NSMakeRect(0, 0, 420, 24);
    alert.accessoryView = nameField;
    [alert addButtonWithTitle:@"Issue Credential"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return nil;
    }
    NSString *name = [nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length > 0 ? name : defaultName;
}

- (void)showPairingCode:(NSString *)pairingCode
                  title:(NSString *)title
            destination:(NSString *)destination
{
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = [NSString stringWithFormat:@"On %@, open Pairing and enter this one-device code. Treat it like a password; it is never logged or advertised over Bonjour.", destination];
    NSTextField *codeField = [NSTextField labelWithString:pairingCode];
    codeField.selectable = YES;
    codeField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    codeField.frame = NSMakeRect(0, 0, 560, 110);
    codeField.lineBreakMode = NSLineBreakByCharWrapping;
    codeField.maximumNumberOfLines = 0;
    alert.accessoryView = codeField;
    [alert addButtonWithTitle:@"Done"];
    [alert runModal];
}

- (void)showPairingFailure:(NSError *)error
{
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"Robot-control pairing failed";
    alert.informativeText = error.localizedDescription ?: @"Cerebro could not update its pairing registry in Keychain.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)revokePairedDevice
{
    NSArray<ROBControlPairedDevice *> *allDevices = [ROBControlPairing pairedDevices];
    NSMutableArray<ROBControlPairedDevice *> *devices = [NSMutableArray array];
    for (ROBControlPairedDevice *device in allDevices) {
        if (!device.isRevoked) {
            [devices addObject:device];
        }
    }
    if (devices.count == 0) {
        NSAlert *emptyAlert = [NSAlert new];
        emptyAlert.messageText = @"No active paired devices";
        emptyAlert.informativeText = @"Revoked devices remain as tombstones, but there is no active credential to revoke.";
        [emptyAlert addButtonWithTitle:@"OK"];
        [emptyAlert runModal];
        return;
    }

    NSPopUpButton *devicePicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 480, 28) pullsDown:NO];
    for (ROBControlPairedDevice *device in devices) {
        NSString *title = [NSString stringWithFormat:@"%@ — %@ — %@", device.deviceName, device.roleName, device.deviceID];
        [devicePicker addItemWithTitle:title];
        NSMenuItem *item = devicePicker.itemArray.lastObject;
        item.representedObject = device;
    }

    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Revoke a paired device";
    alert.informativeText = @"Revocation is persistent and disconnects the selected device immediately. Re-enrollment requires a newly issued credential.";
    alert.accessoryView = devicePicker;
    [alert addButtonWithTitle:@"Revoke"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    ROBControlPairedDevice *device = devicePicker.selectedItem.representedObject;
    if (device == nil) {
        return;
    }
    NSError *error = nil;
    if (![ROBControlPairing revokeDeviceWithDeviceID:device.deviceID error:&error]) {
        [self showPairingFailure:error];
        return;
    }

    if ([device.roleName isEqualToString:@"operatorController"]) {
        // Revoking control authority ends motion and any session that authority
        // approved. The Arduino tread heartbeat remains an independent deadman.
        [self.serialBox stopBaseMotionAndDropHeartbeat];
        [self.serialBox switchToMasterControllerID:@"Brain"];
        [self publishControlAuthorityState];
        if (self.autonomyCoordinator.active) {
            [self.autonomyCoordinator stopWithReason:[NSString stringWithFormat:@"Operator device %@ was revoked", device.deviceName]];
        }
        self.robotActionControllerAcceptsActions = NO;
        self.robotActionControllerLastSeen = nil;
        self.robotActionControllerID = nil;
        self.robotActionControllerCapabilities = @[];
        if (self.controllerApprovedAmberGestureCallID.length > 0) {
            [self cancelControllerApprovedAmberGestureCallID:self.controllerApprovedAmberGestureCallID
                                                       reason:@"The approving operator credential was revoked; stop or hold safely"
                                                     timedOut:NO];
        }
    } else if (self.autonomyCoordinator.active) {
        // A manual controller remains usable, but autonomous motion must not
        // continue after its obstacle source is revoked.
        [self.autonomyCoordinator stopWithReason:[NSString stringWithFormat:@"RPLidar device %@ was revoked", device.deviceName]];
    }
}

- (IBAction)showControlPairingCode:(id)sender
{
    NSAlert *menu = [NSAlert new];
    menu.messageText = @"Manage Paired Devices";
    menu.informativeText = @"Issue a unique role-limited credential for one device, or revoke an existing device without affecting the others.";
    [menu addButtonWithTitle:@"Pair ROBController"];
    [menu addButtonWithTitle:@"Pair RPLidar"];
    [menu addButtonWithTitle:@"Revoke Device…"];
    [menu addButtonWithTitle:@"Cancel"];
    NSModalResponse choice = [menu runModal];

    if (choice == NSAlertThirdButtonReturn) {
        [self revokePairedDevice];
        return;
    }
    if (choice != NSAlertFirstButtonReturn && choice != NSAlertSecondButtonReturn) {
        return;
    }

    BOOL isLidar = choice == NSAlertSecondButtonReturn;
    NSString *deviceName = [self pairingDeviceNameWithDefault:(isLidar ? @"RPLidar" : @"ROBController")
                                                         role:(isLidar ? @"RPLidar publisher" : @"ROBController")];
    if (deviceName == nil) {
        return;
    }

    NSError *error = nil;
    NSString *pairingCode = isLidar
        ? [ROBControlPairing issueLidarPairingCodeWithDeviceName:deviceName error:&error]
        : [ROBControlPairing issueOperatorPairingCodeWithDeviceName:deviceName error:&error];
    if (pairingCode.length == 0) {
        [self showPairingFailure:error];
        return;
    }
    [self showPairingCode:pairingCode
                    title:(isLidar ? @"Pair RPLidar" : @"Pair ROBController")
              destination:(isLidar ? @"the RPLidar publisher" : @"ROBController")];
}

- (void)didReceiveLidarTelemetry:(NSData *)data deviceID:(NSString *)deviceID
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.autonomyCoordinator updateLidarScanData:data];
    });
}

- (void)publishControlAuthorityState
{
    NSString *activeControllerID = self.serialBox.masterControllerID;
    if (activeControllerID.length == 0) {
        activeControllerID = @"Brain";
    }
    NSDictionary *messageDictionary = @{
        @"message": @"ROBControlAuthorityStateV1",
        @"sender": @"Cerebro",
        @"control.authority.version": @"1",
        @"control.authority.controller_id": activeControllerID,
    };
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:messageDictionary
                                         requiringSecureCoding:YES
                                                         error:&error];
    if (data == nil || error != nil) {
        NSLog(@"Unable to publish ROB control authority state: %@", error.localizedDescription);
        return;
    }
    [self.autoNetServer sendMessage:data];
}

- (void) didReceiveData:(NSData *)data {
    ROBAutonomySessionMessage *autonomyMessage = [ROBAutonomySessionWireCodec decodeEnvelopeData:data];
    if (autonomyMessage != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.autonomyCoordinator handleSessionMessage:autonomyMessage];
        });
        return;
    }

    ROBRobotActionMessage *robotActionMessage = [ROBRobotActionWireCodec decodeEnvelopeData:data];
    if (robotActionMessage != nil) {
        if ([NSThread isMainThread]) {
            [self handleRobotActionMessage:robotActionMessage];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleRobotActionMessage:robotActionMessage];
            });
        }
        return;
    }

    NSError *error = nil;
    NSSet *classSet = [NSSet setWithObjects:[NSDictionary class], [NSString class], [NSData class], nil];
    NSDictionary *messageDictionary = (NSDictionary*) [NSKeyedUnarchiver unarchivedObjectOfClasses:classSet
                                                                                          fromData:data error:&error];
    NSString *msg = [messageDictionary valueForKey:@"message"];
    NSString *sender = [messageDictionary valueForKey:@"sender"];
    NSString *motionVersion = messageDictionary[@"controller.motion.version"];
    NSString *motionState = messageDictionary[@"controller.motion.state"];
    NSString *motionInhibitReason = messageDictionary[@"controller.motion.inhibit_reason"];
    NSSet<NSString *> *validMotionInhibitReasons = [NSSet setWithArray:@[
        @"disconnected", @"operatorDisarmed", @"deadManReleased", @"inputExpired",
        @"sceneInactive", @"controllerDisconnected", @"emergencyStop",
        @"transportFailure", @"userRequested", @"robotWatchdog"
    ]];
    BOOL hasMotionMetadata = motionVersion != nil || motionState != nil || motionInhibitReason != nil;
    BOOL motionMetadataValid = !hasMotionMetadata || (
        [motionVersion isEqualToString:@"1"]
        && ([motionState isEqualToString:@"drive"] || [motionState isEqualToString:@"stopped"])
        && (motionInhibitReason == nil || [validMotionInhibitReasons containsObject:motionInhibitReason])
        && (![motionState isEqualToString:@"drive"] || motionInhibitReason == nil)
    );

    if ([msg isEqualToString:@"ROBControllerTreadSnapshotV1"])
    {
        BOOL (^parseFiniteTreadDouble)(id, double *) = ^BOOL(id rawValue, double *output) {
            if (![rawValue isKindOfClass:NSString.class] || [(NSString *)rawValue length] == 0) {
                return NO;
            }
            NSScanner *scanner = [NSScanner scannerWithString:(NSString *)rawValue];
            double parsed = 0;
            if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed)) {
                return NO;
            }
            *output = parsed;
            return YES;
        };
        BOOL (^isWireBoolean)(id) = ^BOOL(id value) {
            return [value isEqualToString:@"0"] || [value isEqualToString:@"1"];
        };

        double leftX = 0;
        double leftY = 0;
        double rightX = 0;
        double rightY = 0;
        double speed = 0;
        NSString *leftActiveText = messageDictionary[@"controller.tread.left.active"];
        NSString *rightActiveText = messageDictionary[@"controller.tread.right.active"];
        NSString *brakeText = messageDictionary[@"controller.tread.brake_lock"];
        NSString *playText = messageDictionary[@"controller.tread.play"];
        NSString *forwardText = messageDictionary[@"controller.tread.forward"];
        NSString *sequenceText = messageDictionary[@"controller.tread.sequence"];
        NSString *sentAtText = messageDictionary[@"controller.tread.sent_at_ms"];
        unsigned long long sequence = 0;
        unsigned long long sentAtMilliseconds = 0;
        NSScanner *sequenceScanner = [sequenceText isKindOfClass:NSString.class]
            ? [NSScanner scannerWithString:sequenceText]
            : nil;
        NSScanner *sentAtScanner = [sentAtText isKindOfClass:NSString.class]
            ? [NSScanner scannerWithString:sentAtText]
            : nil;
        BOOL sequenceIsValid = sequenceScanner != nil
            && [sequenceScanner scanUnsignedLongLong:&sequence]
            && sequenceScanner.isAtEnd
            && sequence > 0;
        BOOL timestampIsValid = sentAtScanner != nil
            && [sentAtScanner scanUnsignedLongLong:&sentAtMilliseconds]
            && sentAtScanner.isAtEnd
            && sentAtMilliseconds > 0;
        BOOL valid = error == nil
            && [messageDictionary[@"controller.tread.version"] isEqualToString:@"1"]
            && [sender isKindOfClass:NSString.class] && sender.length > 0 && sender.length <= 128
            && sequenceIsValid && timestampIsValid
            && isWireBoolean(leftActiveText) && isWireBoolean(rightActiveText)
            && isWireBoolean(brakeText) && isWireBoolean(playText) && isWireBoolean(forwardText)
            && parseFiniteTreadDouble(messageDictionary[@"controller.tread.left.x"], &leftX)
            && parseFiniteTreadDouble(messageDictionary[@"controller.tread.left.y"], &leftY)
            && parseFiniteTreadDouble(messageDictionary[@"controller.tread.right.x"], &rightX)
            && parseFiniteTreadDouble(messageDictionary[@"controller.tread.right.y"], &rightY)
            && parseFiniteTreadDouble(messageDictionary[@"controller.tread.speed"], &speed)
            && leftX >= -1.0 && leftX <= 1.0 && leftY >= -1.0 && leftY <= 1.0
            && rightX >= -1.0 && rightX <= 1.0 && rightY >= -1.0 && rightY <= 1.0
            && speed >= 0.0 && speed <= 100.0;
        if (!valid) {
            NSLog(@"Ignoring malformed prioritized tread snapshot");
            return;
        }

        BOOL leftActive = [leftActiveText isEqualToString:@"1"];
        BOOL rightActive = [rightActiveText isEqualToString:@"1"];
        CGPoint leftPoint = leftActive
            ? CGPointMake(leftX, leftY)
            : CGPointMake(-1000.0, -1000.0);
        CGPoint rightPoint = rightActive
            ? CGPointMake(rightX, rightY)
            : CGPointMake(-1000.0, -1000.0);
        [self.serialBox controllerId:sender
                         treadPointL:leftPoint
                         treadPointR:rightPoint
                       tredBrakeLock:[brakeText isEqualToString:@"1"]
                                speed:(float)speed
                      speedPlayPause:[playText isEqualToString:@"1"]
                  speedForwardReverse:[forwardText isEqualToString:@"1"]];
        return;
    }

    BOOL (^parseControllerPose)(id, double[8]) = ^BOOL(id rawValue, double output[8]) {
        if (![rawValue isKindOfClass:NSString.class]) {
            return NO;
        }
        NSArray<NSString *> *parts = [(NSString *)rawValue componentsSeparatedByString:@","];
        if (parts.count != 8) {
            return NO;
        }
        for (NSUInteger index = 0; index < parts.count; index++) {
            NSScanner *scanner = [NSScanner scannerWithString:parts[index]];
            if (![scanner scanDouble:&output[index]] || !scanner.isAtEnd || !isfinite(output[index])) {
                return NO;
            }
        }
        if (fabs(output[0]) > 20 || fabs(output[1]) > 20 || fabs(output[2]) > 20 || output[7] < 0) {
            return NO;
        }
        double quaternionMagnitude = sqrt(
            output[3] * output[3] + output[4] * output[4]
                + output[5] * output[5] + output[6] * output[6]
        );
        if (quaternionMagnitude <= 0.5 || quaternionMagnitude >= 1.5) {
            return NO;
        }
        for (NSUInteger index = 3; index <= 6; index++) {
            output[index] /= quaternionMagnitude;
        }
        return YES;
    };
    double leftControllerPose[8] = {0};
    double rightControllerPose[8] = {0};
    BOOL controllerPoseVersionIsValid = [messageDictionary[@"controller.pose.version"] isEqualToString:@"1"];
    BOOL leftControllerPoseValid = controllerPoseVersionIsValid
        && parseControllerPose(messageDictionary[@"controller.pose.left"], leftControllerPose);
    BOOL rightControllerPoseValid = controllerPoseVersionIsValid
        && parseControllerPose(messageDictionary[@"controller.pose.right"], rightControllerPose);
    BOOL gripperControlVersionIsValid = [messageDictionary[@"gripper.control.version"] isEqualToString:@"1"];
    NSString *leftGripperClosedText = messageDictionary[@"gripper.left.closed"];
    NSString *rightGripperClosedText = messageDictionary[@"gripper.right.closed"];
    BOOL gripperControlValid = gripperControlVersionIsValid
        && ([leftGripperClosedText isEqualToString:@"0"] || [leftGripperClosedText isEqualToString:@"1"])
        && ([rightGripperClosedText isEqualToString:@"0"] || [rightGripperClosedText isEqualToString:@"1"]);
    NSString *torsoRotationText = messageDictionary[@"torso.rotation.normalized"];
    double torsoRotation = 0;
    NSScanner *torsoScanner = [torsoRotationText isKindOfClass:NSString.class]
        ? [NSScanner scannerWithString:torsoRotationText]
        : nil;
    BOOL torsoControlValid = [messageDictionary[@"torso.control.version"] isEqualToString:@"1"]
        && torsoScanner != nil
        && [torsoScanner scanDouble:&torsoRotation]
        && torsoScanner.isAtEnd
        && isfinite(torsoRotation)
        && torsoRotation >= -1.0
        && torsoRotation <= 1.0;

    if (error != nil) {
        NSLog(@"Error data recieved: %@", [error localizedDescription]);
    }

    if ([msg isEqualToString:@"ROBWatchVoiceText"])
    {
        id rawWatchText = [messageDictionary valueForKey:@"watch.text"];
        if (![rawWatchText isKindOfClass:[NSString class]]) {
            NSLog(@"Ignoring malformed Watch voice message");
            return;
        }
        NSString *watchText = [(NSString *)rawWatchText
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (watchText.length == 0 || watchText.length > 1024) {
            NSLog(@"Ignoring empty or oversized Watch voice message");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Dictation is explicit operator input. Submit it directly so the
            // Live API microphone's duplicate-transcript suppression cannot
            // discard it; ROBAI responses still speak through SpeechBox.
            [self startListeningAgain];
            NSInteger wordiness = self.torsoControlsViewController.speechWordinessChoice.selectedSegment;
            if ([self.robAI sendText:watchText speechWordiness:wordiness]) {
                [self appendConversationText:watchText fromUser:YES];
            }
            self.audioInputTaskController.textView.string =
                [self.audioInputTaskController.textView.string
                    stringByAppendingString:[NSString stringWithFormat:@"\n%@\n", watchText]];
        });
        return;
    }

    if ([msg isEqualToString:@"ROBOperatorTextV1"])
    {
        NSString *version = messageDictionary[@"operator.text.version"];
        NSString *mode = messageDictionary[@"operator.text.mode"];
        id rawText = messageDictionary[@"operator.text.value"];
        NSString *operatorText = [rawText isKindOfClass:NSString.class]
            ? [(NSString *)rawText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            : nil;
        NSCharacterSet *forbiddenControls = [[NSCharacterSet controlCharacterSet] mutableCopy];
        [(NSMutableCharacterSet *)forbiddenControls removeCharactersInString:@"\n\t"];
        BOOL valid = [version isEqualToString:@"1"]
            && [sender isKindOfClass:NSString.class] && sender.length > 0 && sender.length <= 128
            && operatorText.length > 0 && operatorText.length <= 1024
            && [operatorText rangeOfCharacterFromSet:forbiddenControls].location == NSNotFound
            && ([mode isEqualToString:@"command"] || [mode isEqualToString:@"puppetSpeech"]);
        if (!valid) {
            NSLog(@"Ignoring malformed Vision Pro operator text");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([mode isEqualToString:@"puppetSpeech"]) {
                [self.speechBox sayIt:operatorText];
            } else {
                [self inputText:operatorText];
            }
            self.audioInputTaskController.textView.string =
                [self.audioInputTaskController.textView.string
                    stringByAppendingString:[NSString stringWithFormat:@"\nVision Pro (%@): %@\n", mode, operatorText]];
        });
        return;
    }

    if ([msg isEqualToString:@"ROBWatchDriveSnapshotV1"])
    {
        NSString *version = messageDictionary[@"watch.drive.version"];
        NSString *leftText = messageDictionary[@"watch.drive.left"];
        NSString *rightText = messageDictionary[@"watch.drive.right"];
        NSString *speedText = messageDictionary[@"watch.drive.speed"];
        NSString *brakeText = messageDictionary[@"watch.drive.brake"];
        BOOL (^parseFiniteDouble)(NSString *, double *) = ^BOOL(NSString *value, double *output) {
            if (![value isKindOfClass:[NSString class]] || value.length == 0) {
                return NO;
            }
            NSScanner *scanner = [NSScanner scannerWithString:value];
            double parsed = 0;
            if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed)) {
                return NO;
            }
            *output = parsed;
            return YES;
        };

        double left = 0;
        double right = 0;
        double speed = 0;
        BOOL valid = [version isEqualToString:@"1"] &&
            [sender isKindOfClass:[NSString class]] && sender.length > 0 && sender.length <= 128 &&
            parseFiniteDouble(leftText, &left) && left >= -1.0 && left <= 1.0 &&
            parseFiniteDouble(rightText, &right) && right >= -1.0 && right <= 1.0 &&
            parseFiniteDouble(speedText, &speed) && speed >= 5.0 && speed <= 35.0 &&
            ([brakeText isEqualToString:@"0"] || [brakeText isEqualToString:@"1"]);
        if (!valid) {
            NSLog(@"Ignoring malformed Watch drive snapshot");
            return;
        }

        BOOL brake = [brakeText isEqualToString:@"1"];
        ROBBaseControllerModel *controller = [ROBBaseControllerModel new];
        controller.touchPadPointL = brake ? CGPointMake(-1000.0, -1000.0) : CGPointMake(0.0, left * 0.5);
        controller.touchPadPointR = brake ? CGPointMake(-1000.0, -1000.0) : CGPointMake(0.0, right * 0.5);
        controller.Lat = 0;
        controller.Long = 0;
        controller.tredBrakeLock = brake;
        controller.flipperForwardIsDown = false;
        controller.flipperRelaxBrake = false;
        controller.flipperBackwardIsDown = false;
        controller.flipperBrakeLock = true;
        controller.lact1 = false;
        controller.lact2 = false;
        controller.lact3 = false;
        controller.speed = speed;
        controller.speed_playPause = false;
        controller.speed_forward_reverse = true;
        controller.textInput = @"";
        [self.serialBox controllerId:sender controllerModelData:controller];
        return;
    }
    
    if ([msg hasPrefix:@"JoinWifi:"])
    {
        NSString *wifiCredentials = [msg stringByReplacingOccurrencesOfString:@"JoinWifi:" withString:@""];
        [self joinWifi:wifiCredentials];
        return;
    }
    
    if ([msg hasPrefix:@"SetInputLanguage:"])
    {
        NSString *language = [msg stringByReplacingOccurrencesOfString:@"SetInputLanguage:" withString:@""];
        [self setROBInputLanguage:language];
        return;
    }
    if ([msg hasPrefix:@"SetOutputLanguage:"])
    {
        NSString *language = [msg stringByReplacingOccurrencesOfString:@"SetOutputLanguage:" withString:@""];
        [self setROBOutputLanguage:language];
        return;
    }
    if ([msg hasPrefix:@"ShutUp"])
    {
        [self.speechBox stopIt:nil];
        return;
    }
    if ([msg hasPrefix:@"SetVolume:"])
    {
        NSString *volume = [msg stringByReplacingOccurrencesOfString:@"SetVolume:" withString:@""];
        [self setVolume:volume.intValue];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Anger"])
    {
        [self.speechBox switchMood_anger];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Joy"])
    {
        [self.speechBox switchMood_joy];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Neutral"])
    {
        [self.speechBox switchMood_neutral];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Sadness"])
    {
        [self.speechBox switchMood_sadness];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Fear"])
    {
        [self.speechBox switchMood_fear];
        return;
    }
    
    if ([msg isEqualToString:@"PermitAutonomousMasterController"])
    {
        // V2 autonomy uses a versioned session message. Never grant persistent
        // motion authority from this legacy unauthenticated string.
        NSLog(@"Ignoring deprecated PermitAutonomousMasterController message");
        return;
    }
    if ([msg isEqualToString:@"RequestToBeMasterController"])
    {
        if (self.autonomyCoordinator.active) {
            [self.autonomyCoordinator stopWithReason:@"Manual controller requested motion authority"];
        }
        [self.serialBox switchToMasterControllerID:sender];
        [self publishControlAuthorityState];
        return;
    }
    if ([msg isEqualToString:@"ReleaseMasterController"])
    {
        if ([self.serialBox.masterControllerID isEqualToString:sender]) {
            [self.serialBox stopBaseMotionAndDropHeartbeat];
            [self.serialBox switchToMasterControllerID:@"Brain"];
            [self publishControlAuthorityState];
        }
        return;
    }
    
    if ([sender isEqualToString:@"rpLidar"]){
        NSLog(@"Ignoring obsolete text RPLidar envelope; binary frame 7 is required");
        return;
    }
    /*
    0.32,-0.90,-0.28,                   Matrix row 1
    0.94,0.27,0.21,                     Matrix row 2
    -0.11,-0.33,0.94,                   Matrix row 3
    yaw=-1.292633
    pitch=0.211758
    roll=0.292573
    touchPad - -1.000000,-1.000000
    (Lat,Long):30.646698:-96.321426
    tredBrakeLock=0
    flipper=0,0,0,0
    lact=0,0,0
    speed=50.000000,play=0,forward-reverse=1
    TEXT=Testing testing 123
    */
    
    NSArray *command_components = [msg componentsSeparatedByString:@"\n"];
    
    if (command_components.count == 14)
    {
        
        NSArray *matrixRow1_array = [command_components[0] componentsSeparatedByString:@","];
        NSArray *matrixRow2_array = [command_components[1] componentsSeparatedByString:@","];
        NSArray *matrixRow3_array = [command_components[2] componentsSeparatedByString:@","];
        float m11 = [matrixRow1_array[0] floatValue];
        float m12 = [matrixRow1_array[1] floatValue];
        float m13 = [matrixRow1_array[2] floatValue];
        
        float m21 = [matrixRow2_array[0] floatValue];
        float m22 = [matrixRow2_array[1] floatValue];
        float m23 = [matrixRow2_array[2] floatValue];
        
        float m31 = [matrixRow3_array[0] floatValue];
        float m32 = [matrixRow3_array[1] floatValue];
        float m33 = [matrixRow3_array[2] floatValue];
        
        float yaw = [[command_components[3] componentsSeparatedByString:@"yaw="][1] floatValue];
        float pitch = [[command_components[4] componentsSeparatedByString:@"pitch="][1] floatValue];
        float roll = [[command_components[5] componentsSeparatedByString:@"roll="][1] floatValue];
        
        NSArray *touchPadL_array = [[command_components[6] componentsSeparatedByString:@"touchPadL - "][1] componentsSeparatedByString:@","];
        CGPoint touchPadPointL = CGPointMake([touchPadL_array[0] floatValue], [touchPadL_array[1] floatValue]);

        NSArray *touchPadR_array = [[command_components[7] componentsSeparatedByString:@"touchPadR - "][1] componentsSeparatedByString:@","];
        CGPoint touchPadPointR = CGPointMake([touchPadR_array[0] floatValue], [touchPadR_array[1] floatValue]);

        
        
        NSArray *geoPosition_array = [command_components[8] componentsSeparatedByString:@":"];
        float Lat = [geoPosition_array[0] floatValue];
        float Long = [geoPosition_array[1] floatValue];
        
        bool tredBrakeLock = [[command_components[9] componentsSeparatedByString:@"tredBrakeLock="][1] boolValue];
        if (!motionMetadataValid
            || ([motionState isEqualToString:@"drive"] && tredBrakeLock)
            || ([motionState isEqualToString:@"stopped"] && !tredBrakeLock)) {
            NSLog(@"Ignoring controller snapshot with contradictory motion metadata");
            return;
        }
        NSArray *flipper1_array = [[command_components[10] componentsSeparatedByString:@"flipper="][1] componentsSeparatedByString:@","];
        
        bool flipperForwardIsDown = [flipper1_array[0] boolValue];
        bool flipperRelaxBrake = [flipper1_array[1] boolValue];
        bool flipperBackwardIsDown = [flipper1_array[2] boolValue];
        
        bool flipperBrakeLock = [flipper1_array[3] boolValue];
        
        
        NSArray *lact_array = [[command_components[11] componentsSeparatedByString:@"lact="][1] componentsSeparatedByString:@","];
        
        bool lact1 = [lact_array[0] boolValue];
        bool lact2 = [lact_array[1] boolValue];
        bool lact3 = [lact_array[2] boolValue];
        
        NSArray *speed_array = [[command_components[12] componentsSeparatedByString:@"speed="][1] componentsSeparatedByString:@","];

        float speed = [speed_array[0] floatValue];
        bool speed_playPause = [[speed_array[1] componentsSeparatedByString:@"play="][1]  boolValue];
        bool speed_forward_reverse = [[speed_array[2] componentsSeparatedByString:@"forward-reverse="][1] boolValue] ;
        
        NSString *textInput = [command_components[13] componentsSeparatedByString:@"TEXT="][1];
        ROBBaseControllerModel *controllerModelData = [ROBBaseControllerModel new];
        controllerModelData.touchPadPointL = touchPadPointL;
        controllerModelData.touchPadPointR = touchPadPointR;
        controllerModelData.Lat = Lat;
        controllerModelData.Long = Long;
        controllerModelData.tredBrakeLock = tredBrakeLock;
        controllerModelData.motionInhibitReason = motionInhibitReason;
        controllerModelData.flipperForwardIsDown = flipperForwardIsDown;
        controllerModelData.flipperRelaxBrake = flipperRelaxBrake;
        controllerModelData.flipperBackwardIsDown = flipperBackwardIsDown;
        controllerModelData.flipperBrakeLock = flipperBrakeLock;
        controllerModelData.lact1 = lact1;
        controllerModelData.lact2 = lact2;
        controllerModelData.lact3 = lact3;
        controllerModelData.speed = speed;
        controllerModelData.speed_playPause = speed_playPause;
        controllerModelData.speed_forward_reverse = speed_forward_reverse;
        controllerModelData.textInput = textInput;
        controllerModelData.neckControlActive = isfinite(yaw) && isfinite(pitch)
            && yaw >= -1.0f && yaw <= 1.0f
            && pitch >= -1.0f && pitch <= 1.0f
            && roll >= 0.5f;
        controllerModelData.neckPan = controllerModelData.neckControlActive ? yaw : 0;
        controllerModelData.neckTilt = controllerModelData.neckControlActive ? pitch : 0;
        controllerModelData.gripperControlActive = gripperControlValid;
        controllerModelData.leftGripperClosed = gripperControlValid && [leftGripperClosedText isEqualToString:@"1"];
        controllerModelData.rightGripperClosed = gripperControlValid && [rightGripperClosedText isEqualToString:@"1"];
        controllerModelData.torsoControlActive = torsoControlValid;
        controllerModelData.torsoRotation = torsoControlValid ? (float)torsoRotation : 0;
        controllerModelData.leftControllerPoseValid = leftControllerPoseValid;
        controllerModelData.leftControllerPositionX = (float)leftControllerPose[0];
        controllerModelData.leftControllerPositionY = (float)leftControllerPose[1];
        controllerModelData.leftControllerPositionZ = (float)leftControllerPose[2];
        controllerModelData.leftControllerOrientationX = (float)leftControllerPose[3];
        controllerModelData.leftControllerOrientationY = (float)leftControllerPose[4];
        controllerModelData.leftControllerOrientationZ = (float)leftControllerPose[5];
        controllerModelData.leftControllerOrientationW = (float)leftControllerPose[6];
        controllerModelData.leftControllerPoseTimestamp = leftControllerPose[7];
        controllerModelData.rightControllerPoseValid = rightControllerPoseValid;
        controllerModelData.rightControllerPositionX = (float)rightControllerPose[0];
        controllerModelData.rightControllerPositionY = (float)rightControllerPose[1];
        controllerModelData.rightControllerPositionZ = (float)rightControllerPose[2];
        controllerModelData.rightControllerOrientationX = (float)rightControllerPose[3];
        controllerModelData.rightControllerOrientationY = (float)rightControllerPose[4];
        controllerModelData.rightControllerOrientationZ = (float)rightControllerPose[5];
        controllerModelData.rightControllerOrientationW = (float)rightControllerPose[6];
        controllerModelData.rightControllerPoseTimestamp = rightControllerPose[7];
        
        [self.serialBox controllerId:sender controllerModelData:controllerModelData];
        [self.scnViewController updateWithControllerModel:controllerModelData sender:sender];
        
        NSDictionary *messageDict = @{@"message": @"Hey I got your message",
                                      @"sender":[[NSHost currentHost] name]};
        NSError *error = nil;
        [self.autoNetServer sendMessage:[NSKeyedArchiver archivedDataWithRootObject:messageDict requiringSecureCoding:false error:&error]]; //ACK acknowledge receipt to controller
    }
}

#pragma mark -

- (void) showROBNavigation
{
    // Keep RGB-D perception alive without requiring a diagnostics window.
    [self ensureBellyCameraRuntime];
    [self.bellyCameraWindowController setNavigationDemandActive:YES];
}

- (void)ensureMainCameraRuntime
{
    if (self.cameraWindowController != nil && self.cameraViewController != nil) {
        return;
    }
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    self.cameraWindowController = [storyBoard instantiateControllerWithIdentifier:@"CameraWindowController"];
    (void)self.cameraWindowController.window;
    self.cameraViewController = (CameraViewController *)self.cameraWindowController.contentViewController;
    (void)self.cameraViewController.view;
    self.cameraViewController.robMainViewController = self;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(mainCameraDiagnosticsWindowWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:self.cameraWindowController.window];
    [self updateGeminiCameraDemand];
}

- (void)ensureBellyCameraRuntime
{
    if (self.bellyCameraWindowController != nil) {
        return;
    }
    self.bellyCameraWindowController = [[ROBBellyCameraWindowController alloc] init];
}

- (IBAction)showMainCameraDiagnostics:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        return;
    }
    [self ensureMainCameraRuntime];
    [self.cameraViewController setDiagnosticsPreviewVisible:YES];
    [self.cameraWindowController showWindow:sender];
}

- (void)mainCameraDiagnosticsWindowWillClose:(NSNotification *)notification
{
    [self.cameraViewController setDiagnosticsPreviewVisible:NO];
}

- (IBAction)showCameraDiagnostics:(id)sender
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        return;
    }
    [self showMainCameraDiagnostics:sender];
    [self showInsta360Diagnostics:sender];
    [self ensureBellyCameraRuntime];
    [self.bellyCameraWindowController showWindow:sender];
}

- (void)synchronizeDevelopmentCameraDiagnostics
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:ROBDevelopmentModeDefaultsKey]) {
        [self showCameraDiagnostics:self];
    } else {
        [self.cameraViewController setDiagnosticsPreviewVisible:NO];
        [self.cameraWindowController close];
        [self.insta360DiagnosticsWindowController close];
        [self.bellyCameraWindowController close];
    }
}

- (void) showROB_Torso_Controls
{
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil]; // get a reference to the storyboard
    self.torsoControlsWindowController = [storyBoard instantiateControllerWithIdentifier:@"TorsoControlsWindowController"]; // instantiate your window controller
    [self.torsoControlsWindowController showWindow:self]; // show the window}
    self.torsoControlsViewController = (ROBTorsoControlsViewController *)self.torsoControlsWindowController.contentViewController;
    [self.torsoControlsViewController setRobMainViewController:self];
    [self.torsoControlsViewController bindArm_controls];
}


- (void) showROBControls
{
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil]; // get a reference to the storyboard
    self.controlsWindowController = [storyBoard instantiateControllerWithIdentifier:@"ControlsWindowController"]; // instantiate your window controller
    [self.controlsWindowController showWindow:self]; // show the window}
    
    [(ROBKeyboardControlsViewController *)self.controlsWindowController.contentViewController setRobMainViewController:self];
}

- (IBAction)showBaseSerialConsole:(id)sender
{
    if (self.baseSerialConsoleWindowController == nil) {
        self.baseSerialConsoleWindowController =
            [[ROBBaseSerialConsoleWindowController alloc] initWithSerialBox:self.serialBox];
    } else {
        [self.baseSerialConsoleWindowController bindSerialBox:self.serialBox];
    }
    [self.baseSerialConsoleWindowController showWindow:sender];
}

- (void) shutdownAudioInput
{
}

- (void) didOutputSerialResponse_Base:(NSString *)response
{
}




- (IBAction)showControls:(id)sender
{
    NSLog(@"show controls");
}


- (IBAction)showSerialDebug:(id)sender
{
    NSLog(@"show serial debug");
}

- (IBAction)showGeminiDiagnostics:(id)sender
{
    id appDelegate = NSApp.delegate;
    if ([appDelegate respondsToSelector:@selector(showGeminiSettings:)]) {
        [appDelegate showGeminiSettings:sender];
    }
}

- (IBAction)showSettings:(id)sender
{
    id appDelegate = NSApp.delegate;
    if ([appDelegate respondsToSelector:@selector(showPythonSettings:)]) {
        [appDelegate showPythonSettings:sender];
    }
}

- (NSViewController *)geminiProviderSettingsViewController
{
    if (self.robAI == nil) {
        return nil;
    }
    if (self.geminiSettingsViewController == nil) {
        self.geminiSettingsViewController =
            [[ROBGeminiSettingsViewController alloc] initWithRobAI:self.robAI];
        self.geminiSettingsViewController.controlDelegate = self;
    }
    return self.geminiSettingsViewController;
}

- (IBAction)showInsta360Diagnostics:(id)sender
{
    if (self.insta360DiagnosticsWindowController == nil) {
        self.insta360DiagnosticsWindowController =
            [[ROBInsta360DiagnosticsWindowController alloc] init];
    }
    [self.insta360DiagnosticsWindowController showWindow:sender];
}

- (IBAction)showSystemStatus:(id)sender
{
    if (self.systemStatusCoordinator == nil) {
        self.systemStatusCoordinator = [[ROBSystemStatusCoordinator alloc]
            initWithRobAI:self.robAI
            cameraViewController:self.cameraViewController
            autoNetServer:self.autoNetServer
            stageShowCoordinator:self.stageShowCoordinator];
    }
    [self.systemStatusCoordinator showWindow:sender];
}

- (IBAction)showStageShow:(id)sender
{
    if (self.stageShowCoordinator == nil) {
        return;
    }
    if (self.stageShowWindowController == nil) {
        self.stageShowWindowController =
            [[ROBStageShowWindowController alloc] initWithStageShowCoordinator:self.stageShowCoordinator];
    }
    [self.stageShowWindowController showWindow:sender];
}


- (IBAction)showMainNavigation:(id)sender
{
    [self ensureBellyCameraRuntime];
    [self.bellyCameraWindowController showWindow:sender];
}

@end
