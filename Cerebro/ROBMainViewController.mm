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
#import "ROBBaseControllerModel.h"
#import "ROBSpeechBox.h"
#import "ROBKeyboardControlsViewController.h"
#import "ROBTorsoControlsViewController.h"
#import "ROBSCNViewController.h"

#import "ROBNiTEManager.h"
#import "ROBConsciousness.h"
//#import "ROBLeap.h"
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

@interface ROBConversationBubbleView : NSTableCellView
@property (nonatomic, strong) NSTextField *senderLabel;
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
        self.bubbleLabel = [NSTextField wrappingLabelWithString:@""];
        self.bubbleLabel.font = [NSFont systemFontOfSize:14];
        self.bubbleLabel.selectable = YES;
        self.bubbleLabel.drawsBackground = YES;
        self.bubbleLabel.wantsLayer = YES;
        self.bubbleLabel.layer.cornerRadius = 14;
        self.bubbleLabel.layer.masksToBounds = YES;
        [self addSubview:self.senderLabel];
        [self addSubview:self.bubbleLabel];
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
    self.bubbleLabel.frame = NSMakeRect(x, 6, bubbleWidth, MAX(34, NSHeight(self.bounds) - 29));
}

@end


@interface ROBMainViewController () <HumanTrackingDelegate, TrackingDelegate, AutoNetServerDataDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, ROBAIDelegate, ROBAutonomyCoordinatorDelegate, ROBStageShowCoordinatorDelegate, ROBGeminiRuntimeControlDelegate>

//--- Base and Maestro SerialBox bindings

@property (readwrite, retain) IBOutlet NSTextView *serialOutputArea_base;
@property (readwrite, retain) IBOutlet NSTextField *serialInputField_base;

@property (readwrite, retain) IBOutlet NSPopUpButton *serialListPullDown_base;
@property (readwrite, retain) IBOutlet NSPopUpButton *serialListPullDown_maestro;
//-----

@property (readwrite, retain) ROBSCNViewController *scnViewController;
@property (readwrite, retain) NSWindowController *controllerDiagnosticsWindowController;
@property (readwrite, retain) NSTimer *niteHeartbeatTimer;

//@property (readwrite, retain) ROBLeap *robLeap;
@property (readwrite, retain) IBOutlet SCNView *robo_scnView;
@property (readwrite, retain) NSWindowController *controlsWindowController;
@property (readwrite, retain) NSWindowController *torsoControlsWindowController;
@property (readwrite, retain) ROBTorsoControlsViewController *torsoControlsViewController;

@property (readwrite, retain) NSWindowController *cameraWindowController;
@property (readwrite, retain) CameraViewController *cameraViewController;
@property (atomic, readwrite, strong) ROBAlignedDepthFrame *latestAlignedDepthFrame;

@property (readwrite, retain) NSWindowController *tastsWindowController;
@property (readwrite, retain) NSTimer *speechResponseAttentionTimer;

- (IBAction)sendText_base:(id)sender;
- (IBAction)serialPortSelected_base: (id) cntrl;
- (IBAction)serialPortSelected_maestro: (id) cntrl;


@property (readwrite, retain) AutoNetServer *autoNetServer;
@property (readwrite, retain) ROBAI *robAI;
@property (readwrite, retain) ROBGeminiDiagnosticsWindowController *geminiDiagnosticsWindowController;
@property (readwrite, retain) ROBInsta360DiagnosticsWindowController *insta360DiagnosticsWindowController;
@property (readwrite, retain) ROBStageShowWindowController *stageShowWindowController;
@property (readwrite, retain) ROBStageShowCoordinator *stageShowCoordinator;
@property (readwrite, retain) ROBAutonomyCoordinator *autonomyCoordinator;
@property (readwrite, assign) NSUInteger saberChoreographyGeneration;
- (void)executeSaberTransforms:(NSArray<ROBSaberTransform *> *)transforms
                         index:(NSUInteger)index
                    generation:(NSUInteger)generation
                   coordinator:(ROBStageShowCoordinator *)coordinator;

// Gemini proposes high-level actions; this bridge only coordinates approval,
// cancellation, and operator-confirmed results with ROBController. A future
// deterministic Cerebro motion/safety coordinator must own actual execution;
// this bridge never translates a model request into actuator output.
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
- (void)applicationWillTerminate:(NSNotification *)notification;
- (void)shutdownCerebroRuntime;
- (BOOL)sendRobotActionMessage:(ROBRobotActionMessage *)message;
- (void)handleRobotActionMessage:(ROBRobotActionMessage *)message;
- (void)robotActionBridgeTick:(NSTimer *)timer;
- (NSString *)robotActionStateString:(ROBRobotActionState)state;
- (BOOL)robotActionMessageIsAddressedToCerebro:(ROBRobotActionMessage *)message;
- (void)cancelPendingGeminiRobotActionsWithReason:(NSString *)reason;
- (void)updateGeminiCameraDemand;
- (void)configureConversationTranscript;
- (void)appendConversationText:(NSString *)text fromUser:(BOOL)fromUser;
- (IBAction)sendROBChatText:(id)sender;
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
    tableView.backgroundColor = [NSColor colorWithCalibratedWhite:0.075 alpha:1.0];
    tableView.gridStyleMask = NSTableViewGridNone;
    tableView.intercellSpacing = NSMakeSize(0, 4);
    tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    tableView.usesAlternatingRowBackgroundColors = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    tableView.autoresizingMask = NSViewWidthSizable;
    scrollView.documentView = tableView;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = tableView.backgroundColor;
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
        if (fromUser) {
            self.lastConversationUserText = cleanText;
            self.lastConversationUserDate = now;
        }
        [self.conversationTableView reloadData];
        NSInteger finalRow = self.conversationMessages.count - 1;
        if (finalRow >= 0) {
            [self.conversationTableView scrollRowToVisible:finalRow];
        }
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
    CGFloat bubbleWidth = MIN(MAX(180, tableView.bounds.size.width - 28) * 0.78, 430) - 20;
    NSRect textBounds = [message.text boundingRectWithSize:NSMakeSize(bubbleWidth, CGFLOAT_MAX)
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
    view.senderLabel.stringValue = message.fromUser ? @"YOU" : @"ROB AI";
    NSColor *textColor = message.fromUser ? NSColor.whiteColor : NSColor.labelColor;
    NSMutableParagraphStyle *bubbleStyle = [[NSMutableParagraphStyle alloc] init];
    bubbleStyle.firstLineHeadIndent = 10;
    bubbleStyle.headIndent = 10;
    bubbleStyle.tailIndent = -10;
    view.bubbleLabel.attributedStringValue = [[NSAttributedString alloc]
        initWithString:message.text
           attributes:@{
               NSFontAttributeName: [NSFont systemFontOfSize:14],
               NSForegroundColorAttributeName: textColor,
               NSParagraphStyleAttributeName: bubbleStyle,
               NSBaselineOffsetAttributeName: @(-2.0)
           }];
    view.bubbleLabel.textColor = textColor;
    view.bubbleLabel.backgroundColor = message.fromUser
        ? NSColor.systemBlueColor
        : [NSColor.systemPurpleColor colorWithAlphaComponent:0.24];
    view.toolTip = [NSDateFormatter localizedStringFromDate:message.date
                                                  dateStyle:NSDateFormatterNoStyle
                                                  timeStyle:NSDateFormatterShortStyle];
    view.needsLayout = YES;
    return view;
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
}

- (void)robAI:(ROBAI *)robAI didFailRequestWithDetail:(NSString *)detail
{
    NSLog(@"Gemini Robotics request failed: %@", detail);
    if ([detail containsString:@"turned off"]) {
        return;
    }
    [self.speechBox sayIt:@"I couldn't get a response from Gemini. Please try again."];
}

- (void)robAI:(ROBAI *)robAI
        didFailRequestWithDetail:(NSString *)detail
                       contextID:(NSString *)contextID
{
    if ([contextID hasPrefix:@"stage:"]) {
        (void)[self.stageShowCoordinator failGeminiTurn:detail requestID:contextID];
        return;
    }
    if ([detail containsString:@"turned off"]) {
        return;
    }
    [self.speechBox sayIt:@"I couldn't get a response from Gemini. Please try again."];
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
    if (callIDs.count == 0) {
        return;
    }

    // Apply the deterministic local stop before any best-effort network
    // cancellation so turning Gemini off cannot leave motion waiting on I/O.
    [self applyPrioritySoftwareStopWithReason:reason];

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
    }
}

- (void)updateGeminiCameraDemand
{
    BOOL geminiVideoIsActive = self.robAI.isGeminiConnectionEnabled &&
        self.robAI.isLiveSessionReady &&
        self.robAI.streamsCameraVideo;
    [self.cameraViewController setGeminiVideoDemandActive:geminiVideoIsActive];
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
        // Stop is a preemptive local safety lane. It must not wait behind the
        // controller approval ledger or imply that the uninstrumented Amber
        // arms have reached a verified hold.
        if (self.stageShowCoordinator.isRunning) {
            [self.stageShowCoordinator cancelWithReason:@"Gemini requested stop_motion"];
        } else {
            [self applyPrioritySoftwareStopWithReason:@"Gemini requested stop_motion"];
        }
        [robAI sendToolResponseWithCallID:call.callID
                                     name:call.name
                                   result:@{
                                       @"status": @"partial",
                                       @"base_status": @"software_stopped",
                                       @"arm_status": @"unverified",
                                       @"detail": @"Cerebro stopped local coordinators, emitted one neutral braked base frame, and dropped the base heartbeat. Amber arm hold cannot yet be observed."
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
        if (existingCancellation != nil) {
            // Retransmit the exact same immutable cancellation ID after
            // reconnects until a terminal result arrives.
            [self sendRobotActionMessage:existingCancellation];
            continue;
        }

        NSDate *executionDeadline = self.robotActionExecutionDeadlines[callID];
        BOOL deadlineExpired = executionDeadline != nil
            ? [now compare:executionDeadline] != NSOrderedAscending
            : request.isExpired;
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
    //TODO: should we reset after so we can keep a conversation going?!?
    [self resetSpeechResponseAttentionTimer];
}

- (void) willSpeakWord:(NSRange)characterRange ofString:(NSString *)string {
    NSLog(@"willSpeakWord ROBMainViewController");
    //somehow then I used this the speech append audio buffer fails?
    //[self resetSpeechResponseAttentionTimer];
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
    BOOL geminiConnectionEnabled = self.robAI.isGeminiConnectionEnabled;
    NSArray<NSString *> *addressTokens = [textInput componentsSeparatedByCharactersInSet:
        [[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    BOOL addressesROB = [addressTokens containsObject:@"robbie"] ||
        [addressTokens containsObject:@"rob"] ||
        [addressTokens containsObject:@"robot"];
    NSString *pendingThinkingAcknowledgement = nil;

    // Safety phrases stay local and effective even when Gemini is unavailable
    // or intentionally turned off.
    if ([textInput containsString:@"stop"] || [textInput containsString:@"wait"] || [textInput containsString:@"don't move"] || [textInput containsString:@"do not move"])
    {
        if (self.stageShowCoordinator.isRunning) {
            [self.stageShowCoordinator cancelWithReason:@"Local spoken stop"];
        } else {
            [self applyPrioritySoftwareStopWithReason:@"Local spoken stop"];
        }
        [self.speechBox sayIt:@"Base motion stopped. Arm hold is not yet verified."];
        return;
    }

    if (addressesROB)
    {
        self.ignoreText = false;
        NSLog(@"Listening for spoken input");
        [self resetSpeechResponseAttentionTimer];
        
        NSArray *thinking_acknowledgements = @[@"let me think", @"I'm thinking", @"hmmmmm, lets see", @"proessing..."];
        NSString *thinking_acknowledgement = [thinking_acknowledgements objectAtIndex:arc4random_uniform((uint32_t)thinking_acknowledgements.count)];
        
        NSArray *greeting_acknowledgements = @[@"Hey there", @"How are you", @"What's up!", @"Greetings"];
        NSString *greeting_acknowledgement = [greeting_acknowledgements objectAtIndex:arc4random_uniform((uint32_t)greeting_acknowledgements.count)];
        
        
        if ([textInput isEqualToString:@"robbie"] || [textInput isEqualToString:@"hey rob"] || [textInput isEqualToString:@"rob"] || [textInput isEqualToString:@"robot"])
        {
            if (!geminiConnectionEnabled) {
                [self.speechBox sayIt:@"Gemini is turned off. Use the Gemini controls to connect."];
            } else if (geminiOwnsMicrophone) {
                if (!self.speechBox.isSpeaking) {
                    [self.robAI noteMicrophoneTurnAwaitingResponse];
                }
            } else {
                [self.speechBox sayIt:greeting_acknowledgement];
            }
            return;
        } else if (!geminiConnectionEnabled) {
            [self.speechBox sayIt:@"Gemini is turned off. Use the Gemini controls to connect."];
            return;
        } else if (!geminiOwnsMicrophone) {
            pendingThinkingAcknowledgement = thinking_acknowledgement;
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
        if (!geminiConnectionEnabled) {
            NSLog(@"Gemini is off; retaining the local transcript without submitting it");
            return;
        }
        if (geminiOwnsMicrophone) {
            // Do not resend the transcript. It is only a local signal that a
            // raw-audio turn should receive a bounded Gemini response.
            if (!self.speechBox.isSpeaking) {
                [self.robAI noteMicrophoneTurnAwaitingResponse];
            }
        } else {
            NSLog(@"textInput = %@", textInput);
            NSInteger speechWordiness = self.torsoControlsViewController.speechWordinessChoice.selectedSegment;
            BOOL accepted = [self.robAI sendText:textInput speechWordiness:speechWordiness];
            if (accepted) {
                [self appendConversationText:textInput fromUser:YES];
            }
            if (accepted && pendingThinkingAcknowledgement.length > 0) {
                [self.speechBox sayIt:pendingThinkingAcknowledgement];
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
    //[textView didChangeText];
}

- (void) clearInputTextMessage
{
    [self.autoNetServer sendString:@"Clear input text message"];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self configureConversationTranscript];
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
    //Leap controller always bugs out and isn't reliable... need to keep leap on the laptop for input instead23
    //self.robLeap = [ROBLeap new];
    //self.robLeap.delegate = self;
    //[self.robLeap run];
//
    //Initilze R.O.B.
    self.robAI = [[ROBAI alloc] init];
    self.robAI.delegate = self;
    
    self.serialBox = [ROBSerialBox new];
    self.serialBox.serialListPullDown_base = self.serialListPullDown_base;
    self.serialBox.serialListPullDown_maestro = self.serialListPullDown_maestro;
    
    self.serialBox.serialOutputArea_base = self.serialOutputArea_base;
    
    self.serialBox.serialInputField_base = self.serialInputField_base;
    
    self.serialBox.delegate = self;
    [self.serialBox initialize_connection];
    
    //---------------------------------------------------------
    //Enable one of these to auto allow a controller to take over... otherwise a controller is required to intiate robot control!
    //Autonomous Algorithms
    //self.serialBox.masterControllerID = @"Autonomous";
    //VRController
    [self.serialBox switchToMasterControllerID:@"Brain"];
    //---------------------------------------------------------
    
    self.speechBox = [ROBSpeechBox new];
    self.speechBox.delegate = self;
    
    [self startListeningAgain];
    
    self.outputLanguage = [[NSUserDefaults standardUserDefaults] valueForKey:@"outputLanguage"];
    [self.speechBox setOutputLanguage:self.outputLanguage];
    [self.robAI start];
    
    [self showROBControls];
    [self showROB_Torso_Controls];
    [self showROBNavigation];
    [self showROB_Camera_View];
    
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
    [self.robAI disconnect];
    if (self.stageShowCoordinator.isRunning) {
        [self.stageShowCoordinator cancelWithReason:@"Cerebro is shutting down"];
    }
    [self.autonomyCoordinator shutdown];
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
    NSLog(@"Priority software stop applied: %@. Amber arm disposition is unverified.", reason);
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
    }
}

- (void)autonomyCoordinatorDidRequestBaseStop:(ROBAutonomyCoordinator *)coordinator
{
    [self.serialBox stopBaseMotionAndDropHeartbeat];
    if ([self.serialBox.masterControllerID isEqualToString:@"Autonomous"]) {
        [self.serialBox switchToMasterControllerID:@"Brain"];
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
    [self resetSpeechResponseAttentionTimer];
}


- (void) beginToIgnore
{
    self.ignoreText = YES;
}

- (void) didSeeNewPeople:(NSArray *)observations {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.autonomyCoordinator updatePersonVisible:observations.count > 0];
        //if (self.isNeckLifted)
            //NSLog(@"neck lifted state is on");
        //if (self.liftNeckAnimationTimer)
            //NSLog(@"liftNeckAnimationTimer %@", self.liftNeckAnimationTimer);
        
        if (!self.isNeckLifted) {
            float targetHeadTilt = 6168.94; //This is the upright neck
            float targetHeadUpperNeckTilt = 6868.81;
            //[[self.torsoControlsViewController headTilt] setFloatValue:self.currentPerson_tilt];
            
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
                    
                    //NSLog(@"about to set tilt from = %f to %f", [self.torsoControlsViewController.headTilt floatValue], [self.torsoControlsViewController.headTilt floatValue] + deltaTilt_finalValue);
                    self.currentPerson_tilt = [self.torsoControlsViewController.headTilt floatValue] + deltaTilt_finalValue;
                    
                    //NSLog(@"about to set upperNeckTilt from = %f to %f", [self.torsoControlsViewController.headUpperNeckTilt floatValue], [self.torsoControlsViewController.headUpperNeckTilt floatValue] + deltaUpperNeckTilt_finalValue);
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
            //NSLog(@"head size = %f, %f", headPosition.size.width, headPosition.size.height);
            [self trackingPerson:userID x:center_x y:center_y z:1.0];
        }
}

- (void) trackingPerson:(NSString *)userID x:(float)x y:(float)y z:(float)z
{
    //if (self.currentPersonTrackingID == [userID intValue])
    {
        self.currentPerson_positionX = x;
        self.currentPerson_positionY = y;
        self.currentPerson_positionZ = z;
        
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            
            self.currentPerson_tilt = 6168.94;

            //NSLog(@"Original values: pan %f, tilt %f, upperTilt %f", self.currentPerson_pan, self.currentPerson_tilt, self.currentPerson_upperNeckTilt);
            
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
            
            //NSLog(@"About to set:    pan %f, tilt %f, upperTilt %f", self.currentPerson_pan, self.currentPerson_tilt, self.currentPerson_upperNeckTilt);
            
            // !!! CLAMP VALUES SO WE DON"T BREAK SOMETHING EXPENSIVE LIKE THE CAMERA ON THE HEAD !!!
            if (self.currentPerson_upperNeckTilt > 7400) {
                self.currentPerson_upperNeckTilt = 7400;
            }
            
            [[self.torsoControlsViewController headPan] setFloatValue:self.currentPerson_pan];
            //[[self.torsoControlsViewController headTilt] setFloatValue:self.currentPerson_tilt];
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
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, 0.0) touchPadPointR:CGPointMake(0.0, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:true lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (y > kTrackingMidpointY + 50)
        {
            //Head Should Look Up
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, 0.0) touchPadPointR:CGPointMake(0.0, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:true lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (x > kTrackingMidpointX + 50)
        {
            controller_LeftStick_reducer = 0.0;
            controller_RightStick_reducer = xOffset_R;
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, xOffset_L) touchPadPointR:CGPointMake(0.0, xOffset_R) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (x < kTrackingMidpointX - 50)
        {
            controller_LeftStick_reducer = xOffset_L;
            controller_RightStick_reducer = 0.0;
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, xOffset_L) touchPadPointR:CGPointMake(0.0, xOffset_R) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (z > kMAXFOLLOWDISTANCE)
        {
            //Send forward commands
            controller_zLeftStick = 0.5;
            controller_zRightStick = 0.5;
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.5, 0.0) touchPadPointR:CGPointMake(0.5, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (z < kMAXFOLLOWDISTANCE - 25)
        {
            //Send backward commands
            controller_zLeftStick = -0.5;
            controller_zRightStick = -0.5;
            
            //[self.serialBox controllerPassthrough:CGPointMake(-0.5, 0.0) touchPadPointR:CGPointMake(-0.5, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed: [self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
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
        //[self.serialBox controllerPassthrough:CGPointMake(-0.5, 0.0) touchPadPointR:CGPointMake(-0.5, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed: [self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        //user1 = 517.31, 174.51, 1825.00
    }
}

#pragma mark - HumanTrackingDelegate

- (void) heartbeat_NiTE
{
    //NSLog(@"pulse");
    //[self.niteHeartbeatTimer invalidate];
    //[self startHeartbeatNiTE_ResetTimer];
    self.pulse_count++;
}


- (void) startHeartbeatNiTE_ResetTimer
{
//    __weak ROBMainViewController * weakSelf = self;
//    
//    self.niteHeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:6 repeats:YES block:^(NSTimer * _Nonnull timer) {
//        NSLog(@"validating %i", self.pulse_count);
//        if (self.pulse_count == 0) //At least 1 pulse in every 5 seconds to check or we reboot vision system
//        {
//            self.pulse_count = 1;
//            self.currentPerson_pan = 5900;
//            self.currentPerson_tilt = 5593;
//            
//            NSLog(@"***** Resetting NiTECamera Capture *****");
//            dispatch_async(dispatch_get_main_queue(), ^{
//                //[self.niteManager shutdownNiTEManager];
//                self.NiTE_IS_ON = false;
//            });
//            
//            //__strong ROBMainViewController * strongSelf = weakSelf;
//            
//            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//                //[self createAndInitializeNiteManager];
//            });
//        }
//        self.pulse_count = 0;
//    }];
}

- (void) didTrackHumans:(NSArray *)humanObservations
{
    for (VNDetectedObjectObservation *observation in humanObservations)
    {
        //NSLog(@"human = (%f, %f) --- %@", observation.boundingBox.origin.x, observation.boundingBox.origin.y, observation.uuid.UUIDString);
            //NSAppleScript *script = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"say %@\"", @"howdy"]];
            //[script executeAndReturnError:nil];
        CGRect boundingBox = observation.boundingBox;
        CGFloat midx = CGRectGetMidX(boundingBox);
        CGFloat midy = CGRectGetMidY(boundingBox);
        NSLog(@"human = (%f, %f) --- %@", midx, midy, observation.uuid.UUIDString);
        //if (trackingMode)
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
        //[self.audioInputTaskController startTask:self withLanguage:language];
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
        if (self.autonomyCoordinator.active) {
            [self.autonomyCoordinator stopWithReason:[NSString stringWithFormat:@"Operator device %@ was revoked", device.deviceName]];
        }
        self.robotActionControllerAcceptsActions = NO;
        self.robotActionControllerLastSeen = nil;
        self.robotActionControllerID = nil;
        self.robotActionControllerCapabilities = @[];
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
    NSError *error = nil;
    id decodedObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error != nil || ![decodedObject isKindOfClass:NSDictionary.class]) {
        NSLog(@"Ignoring malformed authenticated RPLidar telemetry from %@", deviceID);
        return;
    }
    NSDictionary *message = (NSDictionary *)decodedObject;
    if (![[message objectForKey:@"kind"] isEqualToString:@"scan"]) {
        // Map frames are authenticated and bounded by the server, but Cerebro's
        // current local planner consumes the scan representation only.
        return;
    }
    NSString *scanPayload = [message objectForKey:@"scanPayload"];
    if (![scanPayload isKindOfClass:NSString.class]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.autonomyCoordinator updateLidarPayload:scanPayload];
    });
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

    //NSLog(@"sender = %@. message = %@", sender, msg);

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
        return;
    }
    if ([msg isEqualToString:@"ReleaseMasterController"])
    {
        if ([self.serialBox.masterControllerID isEqualToString:sender]) {
            [self.serialBox stopBaseMotionAndDropHeartbeat];
            [self.serialBox switchToMasterControllerID:@"Brain"];
        }
        return;
    }
    
    if ([sender isEqualToString:@"rpLidar"]){
        if (self.autoNetServer.legacyCompatibilityIsActive) {
            [self.autonomyCoordinator updateLidarPayload:msg];
        } else {
            NSLog(@"Ignoring spoofable legacy RPLidar envelope on the v2 control path");
        }
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
        
        //NSLog(@"yaw = %f, pitch = %f, roll = %f", yaw, pitch, roll);
        

        NSArray *touchPadL_array = [[command_components[6] componentsSeparatedByString:@"touchPadL - "][1] componentsSeparatedByString:@","];
        CGPoint touchPadPointL = CGPointMake([touchPadL_array[0] floatValue], [touchPadL_array[1] floatValue]);

        NSArray *touchPadR_array = [[command_components[7] componentsSeparatedByString:@"touchPadR - "][1] componentsSeparatedByString:@","];
        CGPoint touchPadPointR = CGPointMake([touchPadR_array[0] floatValue], [touchPadR_array[1] floatValue]);

        
        
        NSArray *geoPosition_array = [command_components[8] componentsSeparatedByString:@":"];
        float Lat = [geoPosition_array[0] floatValue];
        float Long = [geoPosition_array[1] floatValue];
        
        bool tredBrakeLock = [[command_components[9] componentsSeparatedByString:@"tredBrakeLock="][1] boolValue];
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
        //NSLog(@"textInput = %@", textInput);
        //self.serialBox.currentIncommingVerbalMessage = textInput;
        
        ROBBaseControllerModel *controllerModelData = [ROBBaseControllerModel new];
        controllerModelData.touchPadPointL = touchPadPointL;
        controllerModelData.touchPadPointR = touchPadPointR;
        controllerModelData.Lat = Lat;
        controllerModelData.Long = Long;
        controllerModelData.tredBrakeLock = tredBrakeLock;
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
    
}

- (void) showROB_Camera_View
{
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil]; // get a reference to the storyboard
    self.cameraWindowController = [storyBoard instantiateControllerWithIdentifier:@"CameraWindowController"]; // instantiate your window controller
    [self.cameraWindowController showWindow:self]; // show the window}
    self.cameraViewController = (CameraViewController *)self.cameraWindowController.contentViewController;
    self.cameraViewController.robMainViewController = self;
    [self updateGeminiCameraDemand];
    //[self.cameraViewController bindROBMainViewControllerWithRobMainViewController:self];
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

- (IBAction)sendText_base:(id)sender
{
    [self.serialBox sendBaseCommand:[self.serialInputField_base stringValue]];
}


- (IBAction)serialPortSelected_base: (id) cntrl
{
    [self.serialBox serialPortSelected_base];
}


- (IBAction)serialPortSelected_maestro: (id) cntrl
{
    [self.serialBox serialPortSelected_maestro];
}

- (void) shutdownAudioInput
{
    //[self.audioInputTaskController beginToIgnore];
}

- (void) didOutputSerialResponse_Base:(NSString *)response
{
    //NSLog(@"BASE: %@", response);
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
    if (self.robAI == nil) {
        return;
    }
    if (self.geminiDiagnosticsWindowController == nil) {
        self.geminiDiagnosticsWindowController =
            [[ROBGeminiDiagnosticsWindowController alloc] initWithRobAI:self.robAI];
        self.geminiDiagnosticsWindowController.controlDelegate = self;
    }
    [self.geminiDiagnosticsWindowController showWindow:sender];
}

- (IBAction)showInsta360Diagnostics:(id)sender
{
    if (self.insta360DiagnosticsWindowController == nil) {
        self.insta360DiagnosticsWindowController =
            [[ROBInsta360DiagnosticsWindowController alloc] init];
    }
    [self.insta360DiagnosticsWindowController showWindow:sender];
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
    NSLog(@"show main navigation");
}

@end
