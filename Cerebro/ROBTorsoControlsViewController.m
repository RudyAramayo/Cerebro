//
//  ROBTorsoControlsViewController.m
//  Cerebro
//
//  Created by Rob Makina on 5/10/19.
//  Copyright © 2019 Rob Makina. All rights reserved.
//

#import "ROBTorsoControlsViewController.h"
#import <AppKit/AppKit.h>
#import "ROBMainViewController.h"
#import "ROBSerialBox.h"
#import "ROBSpeechBox.h"
#import "Cerebro-Swift.h"
#import <netdb.h>
#import <arpa/inet.h>
#import <sys/socket.h>

static NSString * const ROBAmberHostIPDefaultsKey = @"ROBAmberHostIP";
static NSTimeInterval const kROBServoRenderIntervalSeconds = 0.1;
static NSTimeInterval const kROBServoRenderToleranceSeconds = 0.01;

static NSTextField *ROBNeckLabel(NSString *text, NSRect frame)
{
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:11.0];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSTextField *ROBNeckNumberField(NSRect frame, NSString *accessibilityLabel)
{
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.allowsFloats = YES;
    formatter.lenient = NO;
    field.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    field.alignment = NSTextAlignmentRight;
    field.continuous = NO;
    field.formatter = formatter;
    field.accessibilityLabel = accessibilityLabel;
    return field;
}

static BOOL ROBNeckReadFiniteNumber(NSTextField *field, double *valueOut)
{
    id value = field.objectValue;
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    if (!isfinite(number)) return NO;
    if (valueOut != NULL) *valueOut = number;
    return YES;
}

@interface ROBTorsoControlsViewController () <NSTextFieldDelegate, NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property (readwrite, retain) NSTimer *renderServoControlsTimer;
@property (readwrite, assign) BOOL is_in_position_mode_R11;
@property (readwrite, assign) BOOL is_in_current_mode_R11;
@property (readwrite, assign) BOOL is_in_speed_mode_R11;
@property (readwrite, assign) BOOL is_in_activated_mode_R11;

@property (readwrite, assign) BOOL is_in_position_mode_L10;
@property (readwrite, assign) BOOL is_in_current_mode_L10;
@property (readwrite, assign) BOOL is_in_speed_mode_L10;
@property (readwrite, assign) BOOL is_in_activated_mode_L10;
@property (nonatomic, strong) NSMutableArray<NSNetServiceBrowser *> *amberServiceBrowsers;
@property (nonatomic, strong) NSMutableSet<NSNetService *> *resolvingAmberServices;
@property (nonatomic, strong) NSButton *reconnectAmberArmsButton;
@property (nonatomic, strong) NSTextField *headPanCommandLabel;
@property (nonatomic, strong) NSTextField *lowerNeckCommandLabel;
@property (nonatomic, strong) NSTextField *upperNeckCommandLabel;
@property (nonatomic, strong) NSButton *neckCameraLevelingButton;
@property (nonatomic, strong) NSTextField *restrictedPanDegreesField;
@property (nonatomic, strong) NSTextField *forwardPanMinimumDegreesField;
@property (nonatomic, strong) NSTextField *forwardPanMaximumDegreesField;
@property (nonatomic, strong) NSTextField *panCenterTargetField;
@property (nonatomic, strong) NSTextField *panTargetsPerDegreeField;
@property (nonatomic, strong) NSTextField *cameraCounterRotationGainField;
@property (nonatomic, strong) NSTextField *neckSafetyConfigurationStatusLabel;
@property (nonatomic, strong) NSPopover *neckSafetyConfigurationPopover;
@property (nonatomic, assign) BOOL pendingNeckOperatorCommandAfterStartup;
@property (nonatomic, assign) BOOL pendingLowerTiltOperatorCommandAfterStartup;
@property (nonatomic, strong) ROBArmPositionControlState *l10PositionControlState;
@property (nonatomic, strong) ROBArmPositionControlState *r11PositionControlState;
- (NSArray<NSSlider *> *)armPositionSlidersForGatewayArm:(NSString *)arm;
- (void)refreshAmberPositionControls;
- (void)armPositionSlidersWereEditedForGatewayArm:(NSString *)arm;
- (void)startAmberHostDiscovery;
- (void)setupAmberReconnectControl;
- (IBAction)reconnectAmberArms:(id)sender;
- (void)amberStackMaintenanceDidChange:(NSNotification *)notification;
- (void)applyDiscoveredAmberHost:(NSString *)host source:(NSString *)source;
- (void)setupNeckCommandReadouts;
- (void)refreshNeckCameraLevelingControl;
- (void)safeNeckStartupCommandDidChange:(NSNotification *)notification;
- (void)servoControlNeckDemandDidChange:(NSNotification *)notification;
- (IBAction)toggleNeckCameraLeveling:(id)sender;
- (void)setupNeckSafetyConfigurationControls;
- (IBAction)showNeckSafetyConfiguration:(id)sender;
- (void)loadNeckSafetyConfigurationControls;
- (void)refreshNeckCommandReadouts;
- (BOOL)synchronizeUneditedNeckSlidersForControl:(NSControl *)control;
- (void)renderServoCommandsOperatorInitiated:(BOOL)operatorInitiated
                  lowerTiltOperatorInitiated:(BOOL)lowerTiltOperatorInitiated;
@end

@implementation ROBTorsoControlsViewController

- (void) viewDidLoad
{
    [super viewDidLoad];
    self.l10PositionControlState = [ROBArmPositionControlState new];
    self.r11PositionControlState = [ROBArmPositionControlState new];
    for (NSString *arm in @[@"left", @"right"]) {
        NSArray<NSSlider *> *sliders = [self armPositionSlidersForGatewayArm:arm];
        for (NSUInteger i = 0; i < sliders.count; i++) {
            sliders[i].continuous = YES;
            sliders[i].accessibilityLabel = [NSString stringWithFormat:@"Robot %@ J%lu position",
                [arm isEqualToString:@"left"] ? @"right" : @"left", (unsigned long)i+1];
        }
    }
    [self refreshAmberPositionControls];
    [self setupNeckCommandReadouts];
    [self setupNeckSafetyConfigurationControls];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(safeNeckStartupCommandDidChange:)
               name:ROBSafeNeckStartupCommandDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(servoControlNeckDemandDidChange:)
               name:ROBServoControlNeckDemandDidChangeNotification
             object:nil];
    // Refresh readouts and advance staged operator demands at 10 Hz. Face/blob
    // centering submits directly through its paced serial gateway; mirrored
    // tracking sliders are not an independent hardware producer.
    self.renderServoControlsTimer = [NSTimer
        timerWithTimeInterval:kROBServoRenderIntervalSeconds
                       target:self
                     selector:@selector(renderServoCommands)
                     userInfo:nil
                      repeats:YES];
    self.renderServoControlsTimer.tolerance = kROBServoRenderToleranceSeconds;
    [[NSRunLoop mainRunLoop] addTimer:self.renderServoControlsTimer
                             forMode:NSRunLoopCommonModes];
    self.amberHostIP_TextField.delegate = self;
    NSString *savedAmberHost = [[NSUserDefaults standardUserDefaults] stringForKey:ROBAmberHostIPDefaultsKey];
    if (savedAmberHost.length > 0) {
        self.amberHostIP_TextField.stringValue = savedAmberHost;
    }
    [self setupAmberReconnectControl];
    [self startAmberHostDiscovery];
    
    NSButton *studio = [NSButton buttonWithTitle:@"Animation Studio…" target:self action:@selector(showAnimationStudio:)];
    studio.frame = NSMakeRect(640, 20, 160, 24);
    studio.accessibilityIdentifier = @"open-animation-studio";
    [self.view addSubview:studio];

}

- (void)safeNeckStartupCommandDidChange:(NSNotification *)notification
{
    if (notification.object != self.robMainViewController.serialBox) return;
    [self refreshNeckCommandReadouts];
}

- (void)servoControlNeckDemandDidChange:(NSNotification *)notification
{
    if (notification.object != self.robMainViewController.serialBox) return;
    NSNumber *panTarget = notification.userInfo[
        ROBServoControlPanTargetUserInfoKey
    ];
    NSNumber *lowerTarget = notification.userInfo[
        ROBServoControlLowerTargetUserInfoKey
    ];
    NSNumber *upperTarget = notification.userInfo[
        ROBServoControlUpperTargetUserInfoKey
    ];
    if (panTarget == nil || lowerTarget == nil || upperTarget == nil) return;

    // These sliders represent operator demand. Mirror the complete table pose
    // immediately, even while the command labels continue to show an earlier
    // safety-staged physical target. The passive render will therefore resume
    // with the requested pose instead of the pre-animation values.
    self.headPan.integerValue = panTarget.integerValue;
    self.headTilt.integerValue = lowerTarget.integerValue;
    self.headUpperNeckTilt.integerValue = upperTarget.integerValue;
    self.headPan_enabled.state = panTarget.integerValue == ROBNeckSafetyTargetOff
        ? NSControlStateValueOff : NSControlStateValueOn;
    self.headTilt_enabled.state = NSControlStateValueOn;
    self.headUpperNeckTilt_enabled.state = NSControlStateValueOn;
    self.pendingNeckOperatorCommandAfterStartup = NO;
    self.pendingLowerTiltOperatorCommandAfterStartup = NO;
    [self refreshNeckCommandReadouts];
}

- (void)setupNeckCommandReadouts
{
    NSView *headPanel = self.headPan.superview;
    if (headPanel == nil) return;

    NSFont *commandFont = [NSFont monospacedDigitSystemFontOfSize:10.0
                                                          weight:NSFontWeightMedium];
    self.headPanCommandLabel = ROBNeckLabel(@"P command —", NSMakeRect(0, 29, 139, 16));
    self.lowerNeckCommandLabel = ROBNeckLabel(@"L —", NSMakeRect(64, 137, 72, 16));
    self.upperNeckCommandLabel = ROBNeckLabel(@"U —", NSMakeRect(64, 227, 72, 16));
    for (NSTextField *label in @[
        self.headPanCommandLabel,
        self.lowerNeckCommandLabel,
        self.upperNeckCommandLabel
    ]) {
        label.font = commandFont;
        label.textColor = NSColor.secondaryLabelColor;
        [headPanel addSubview:label];
    }
    self.headPanCommandLabel.accessibilityLabel = @"Applied neck pan command target";
    self.lowerNeckCommandLabel.accessibilityLabel = @"Applied lower neck tilt command target";
    self.upperNeckCommandLabel.accessibilityLabel = @"Applied upper camera tilt command target";

    self.neckCameraLevelingButton = [NSButton
        checkboxWithTitle:@"Keep upright"
        target:self
        action:@selector(toggleNeckCameraLeveling:)];
    self.neckCameraLevelingButton.frame = NSMakeRect(64, 153, 75, 18);
    // The Head panel is only 139 pt wide. A mini checkbox keeps the explicit
    // user-facing wording visible beside the two vertical sliders.
    self.neckCameraLevelingButton.controlSize = NSControlSizeMini;
    self.neckCameraLevelingButton.font = [NSFont systemFontOfSize:9.0];
    self.neckCameraLevelingButton.accessibilityLabel = @"Keep camera upright";
    self.neckCameraLevelingButton.toolTip =
        @"Counter-rotate the upper camera tilt when the lower neck tilts.";
    [headPanel addSubview:self.neckCameraLevelingButton];
    [self refreshNeckCameraLevelingControl];

    // Checkbox changes are operator actions too; wiring them here prevents the
    // passive 10 Hz renderer from being mistaken for manual authority.
    for (NSButton *button in @[
        self.headPan_enabled,
        self.headTilt_enabled,
        self.headUpperNeckTilt_enabled
    ]) {
        button.target = self;
        button.action = @selector(applyServoCommand:);
    }
}

- (void)refreshNeckCameraLevelingControl
{
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    if (serialBox == nil) {
        self.neckCameraLevelingButton.state = NSControlStateValueOff;
        self.neckCameraLevelingButton.title = @"Keep upright";
        self.neckCameraLevelingButton.enabled = NO;
        self.neckCameraLevelingButton.toolTip = @"Camera leveling is unavailable.";
        return;
    }

    BOOL levelingEnabled = serialBox.neckCameraLevelingEnabled;
    self.neckCameraLevelingButton.state = levelingEnabled
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.neckCameraLevelingButton.title = @"Keep upright";
    self.neckCameraLevelingButton.enabled = YES;
    self.neckCameraLevelingButton.toolTip = levelingEnabled
        ? @"Camera leveling is ON; lower-neck tilt counter-rotates the upper camera tilt."
        : @"Camera leveling is OFF; the upper camera tilt follows its direct command.";
}

- (IBAction)toggleNeckCameraLeveling:(id)sender
{
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    if (serialBox == nil) {
        [self refreshNeckCameraLevelingControl];
        NSBeep();
        return;
    }

    BOOL levelingEnabled = self.neckCameraLevelingButton.state
        == NSControlStateValueOn;
    if (serialBox.upperNeckTiltCommandKnown
        && serialBox.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff) {
        // Either source may have changed the applied camera target. Seed the
        // direct demand from that target on both mode transitions so changing
        // modes cannot reapply an old slider value and jump the camera.
        self.headUpperNeckTilt.integerValue = serialBox.commandedUpperNeckTiltTarget;
    }
    [serialBox setNeckCameraLevelingEnabled:levelingEnabled];
    [self refreshNeckCommandReadouts];
}

- (void)setupNeckSafetyConfigurationControls
{
    NSView *headPanel = self.headPan.superview;
    if (headPanel == nil) return;

    NSButton *safetyButton = [NSButton buttonWithTitle:@"Safety…"
                                               target:self
                                               action:@selector(showNeckSafetyConfiguration:)];
    safetyButton.frame = NSMakeRect(72, 247, 65, 22);
    safetyButton.bezelStyle = NSBezelStyleRounded;
    safetyButton.font = [NSFont systemFontOfSize:10.0];
    safetyButton.toolTip = @"Configure restricted pan, the leveling reference, and camera counter-rotation.";
    safetyButton.accessibilityLabel = @"Configure neck command safety";
    [headPanel addSubview:safetyButton];

    NSViewController *contentController = [[NSViewController alloc] init];
    contentController.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 307, 143)];

    NSBox *box = [[NSBox alloc] initWithFrame:contentController.view.bounds];
    box.title = @"Neck safety (command targets; no position feedback)";
    box.titleFont = [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold];
    box.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    box.toolTip = @"Cerebro can verify the target sent to Maestro, not the physical servo-shaft position.";
    [contentController.view addSubview:box];

    NSTextField *restrictedLabel = ROBNeckLabel(@"Below 5000 pan ±", NSMakeRect(8, 102, 145, 16));
    self.restrictedPanDegreesField = ROBNeckNumberField(
        NSMakeRect(154, 99, 48, 21),
        @"Symmetric pan limit below lower tilt target 5000"
    );
    self.restrictedPanDegreesField.toolTip =
        @"Known lower-neck targets below 5000 use this symmetric pan limit.";
    NSTextField *degreesLabel = ROBNeckLabel(@"°", NSMakeRect(204, 102, 18, 16));

    NSTextField *uprightLabel = ROBNeckLabel(@"Upright targets", NSMakeRect(8, 78, 84, 16));
    NSTextField *lowerUprightLabel = ROBNeckLabel(
        [NSString stringWithFormat:@"L %d", ROBNeckSafetyUprightLowerTarget],
        NSMakeRect(98, 78, 58, 16)
    );
    lowerUprightLabel.accessibilityLabel = @"Lower neck upright target 6011";
    NSTextField *upperUprightLabel = ROBNeckLabel(
        [NSString stringWithFormat:@"U %d", ROBNeckSafetyUprightUpperTarget],
        NSMakeRect(164, 78, 58, 16)
    );
    upperUprightLabel.accessibilityLabel = [NSString stringWithFormat:
        @"Upper neck upright target %d", ROBNeckSafetyUprightUpperTarget];

    NSTextField *forwardLabel = ROBNeckLabel(@"Unknown/off pan", NSMakeRect(8, 54, 96, 16));
    self.forwardPanMinimumDegreesField = ROBNeckNumberField(
        NSMakeRect(106, 51, 48, 21),
        @"Unknown or off lower-neck pan minimum angle"
    );
    self.forwardPanMinimumDegreesField.toolTip =
        @"Fail-safe minimum pan angle when lower-neck position is unknown or off.";
    NSTextField *forwardRangeSeparator = ROBNeckLabel(@"…", NSMakeRect(157, 54, 12, 16));
    self.forwardPanMaximumDegreesField = ROBNeckNumberField(
        NSMakeRect(171, 51, 48, 21),
        @"Unknown or off lower-neck pan maximum angle"
    );
    self.forwardPanMaximumDegreesField.toolTip =
        @"Fail-safe maximum pan angle when lower-neck position is unknown or off.";
    NSTextField *forwardDegreesLabel = ROBNeckLabel(@"°", NSMakeRect(222, 54, 15, 16));

    NSTextField *calibrationLabel = ROBNeckLabel(@"Pan center", NSMakeRect(8, 30, 64, 16));
    self.panCenterTargetField = ROBNeckNumberField(
        NSMakeRect(73, 27, 49, 21),
        @"Pan center Maestro target"
    );
    NSTextField *scaleLabel = ROBNeckLabel(@"targets/°", NSMakeRect(128, 30, 55, 16));
    self.panTargetsPerDegreeField = ROBNeckNumberField(
        NSMakeRect(184, 27, 60, 21),
        @"Pan Maestro targets per degree"
    );

    NSTextField *gainLabel = ROBNeckLabel(@"Camera counter gain", NSMakeRect(8, 6, 108, 16));
    self.cameraCounterRotationGainField = ROBNeckNumberField(
        NSMakeRect(117, 3, 48, 21),
        @"Signed upper camera counter-rotation gain"
    );
    self.neckSafetyConfigurationStatusLabel = ROBNeckLabel(@"Defaults", NSMakeRect(169, 6, 69, 16));
    self.neckSafetyConfigurationStatusLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *applyButton = [NSButton buttonWithTitle:@"Apply"
                                              target:self
                                              action:@selector(applyNeckSafetyConfiguration:)];
    applyButton.frame = NSMakeRect(241, 1, 58, 24);
    applyButton.bezelStyle = NSBezelStyleRounded;
    applyButton.toolTip = @"Validate and atomically save all neck safety values.";

    for (NSView *control in @[
        restrictedLabel, self.restrictedPanDegreesField, degreesLabel,
        uprightLabel, lowerUprightLabel, upperUprightLabel,
        forwardLabel, self.forwardPanMinimumDegreesField,
        forwardRangeSeparator, self.forwardPanMaximumDegreesField,
        forwardDegreesLabel,
        calibrationLabel, self.panCenterTargetField, scaleLabel,
        self.panTargetsPerDegreeField, gainLabel,
        self.cameraCounterRotationGainField,
        self.neckSafetyConfigurationStatusLabel, applyButton
    ]) {
        [box addSubview:control];
    }

    self.neckSafetyConfigurationPopover = [[NSPopover alloc] init];
    self.neckSafetyConfigurationPopover.behavior = NSPopoverBehaviorTransient;
    self.neckSafetyConfigurationPopover.animates = YES;
    self.neckSafetyConfigurationPopover.contentSize = contentController.view.bounds.size;
    self.neckSafetyConfigurationPopover.contentViewController = contentController;
    [self loadNeckSafetyConfigurationControls];
}

- (IBAction)showNeckSafetyConfiguration:(id)sender
{
    NSView *anchor = [sender isKindOfClass:NSView.class] ? sender : self.headPan;
    if (anchor == nil || self.neckSafetyConfigurationPopover == nil) return;
    [self loadNeckSafetyConfigurationControls];
    [self.neckSafetyConfigurationPopover showRelativeToRect:anchor.bounds
                                                     ofView:anchor
                                              preferredEdge:NSRectEdgeMinX];
}

- (void)loadNeckSafetyConfigurationControls
{
    ROBNeckSafetyConfig configuration = self.robMainViewController.serialBox != nil
        ? [self.robMainViewController.serialBox neckSafetyConfiguration]
        : ROBNeckSafetyDefaultConfig();
    self.restrictedPanDegreesField.doubleValue = configuration.restrictedPanDegrees;
    self.forwardPanMinimumDegreesField.doubleValue = configuration.forwardPanMinimumDegrees;
    self.forwardPanMaximumDegreesField.doubleValue = configuration.forwardPanMaximumDegrees;
    self.panCenterTargetField.integerValue = configuration.panCenterTarget;
    self.panTargetsPerDegreeField.doubleValue = configuration.panTargetsPerDegree;
    self.cameraCounterRotationGainField.doubleValue = configuration.upperCounterRotationGain;
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    if (serialBox == nil) {
        self.neckSafetyConfigurationStatusLabel.stringValue = @"Defaults";
        self.neckSafetyConfigurationStatusLabel.textColor = NSColor.secondaryLabelColor;
        self.neckSafetyConfigurationStatusLabel.toolTip =
            @"Showing built-in defaults because the Maestro command gateway is unavailable.";
    } else if (!serialBox.neckSafetyCalibrationConfirmed) {
        self.neckSafetyConfigurationStatusLabel.stringValue = @"Calibrate";
        self.neckSafetyConfigurationStatusLabel.textColor = NSColor.systemOrangeColor;
        self.neckSafetyConfigurationStatusLabel.toolTip =
            @"Verify the below-5000 pan limit, unknown/off limits, upright targets, pan scale, and signed camera gain, then Apply with all neck servos off.";
    } else {
        self.neckSafetyConfigurationStatusLabel.stringValue = @"Ready";
        self.neckSafetyConfigurationStatusLabel.textColor = NSColor.secondaryLabelColor;
        self.neckSafetyConfigurationStatusLabel.toolTip =
            @"The saved neck safety calibration is confirmed.";
    }
}

- (IBAction)applyNeckSafetyConfiguration:(id)sender
{
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    if (serialBox == nil) {
        self.neckSafetyConfigurationStatusLabel.stringValue = @"Unavailable";
        self.neckSafetyConfigurationStatusLabel.textColor = NSColor.systemRedColor;
        NSBeep();
        return;
    }
    if (!serialBox.neckCommandStateKnown
        || serialBox.commandedNeckPanTarget != ROBNeckSafetyTargetOff
        || serialBox.commandedLowerNeckTiltTarget != ROBNeckSafetyTargetOff
        || serialBox.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff) {
        self.neckSafetyConfigurationStatusLabel.stringValue = @"Not OFF";
        self.neckSafetyConfigurationStatusLabel.textColor = NSColor.systemOrangeColor;
        self.neckSafetyConfigurationStatusLabel.toolTip =
            @"Command all three neck channels OFF in this Maestro session; UNKNOWN is not OFF.";
        NSBeep();
        return;
    }

    double restrictedPanDegrees = 0.0;
    double forwardPanMinimumDegrees = 0.0;
    double forwardPanMaximumDegrees = 0.0;
    double panCenterTarget = 0.0;
    double panTargetsPerDegree = 0.0;
    double cameraCounterRotationGain = 0.0;
    BOOL fieldsAreNumbers =
        ROBNeckReadFiniteNumber(self.restrictedPanDegreesField, &restrictedPanDegrees)
        && ROBNeckReadFiniteNumber(self.forwardPanMinimumDegreesField, &forwardPanMinimumDegrees)
        && ROBNeckReadFiniteNumber(self.forwardPanMaximumDegreesField, &forwardPanMaximumDegrees)
        && ROBNeckReadFiniteNumber(self.panCenterTargetField, &panCenterTarget)
        && ROBNeckReadFiniteNumber(self.panTargetsPerDegreeField, &panTargetsPerDegree)
        && ROBNeckReadFiniteNumber(self.cameraCounterRotationGainField, &cameraCounterRotationGain);
    BOOL rawTargetsAreIntegers =
        panCenterTarget == trunc(panCenterTarget)
        && panCenterTarget >= INT32_MIN
        && panCenterTarget <= INT32_MAX;
    if (!fieldsAreNumbers || !rawTargetsAreIntegers) {
        self.neckSafetyConfigurationStatusLabel.stringValue = @"Invalid";
        self.neckSafetyConfigurationStatusLabel.textColor = NSColor.systemRedColor;
        self.neckSafetyConfigurationStatusLabel.toolTip =
            @"Enter finite numbers; Maestro raw targets must be whole numbers.";
        NSBeep();
        return;
    }

    ROBNeckSafetyConfig configuration = [serialBox neckSafetyConfiguration];
    configuration.restrictedPanDegrees = restrictedPanDegrees;
    configuration.forwardPanMinimumDegrees = forwardPanMinimumDegrees;
    configuration.forwardPanMaximumDegrees = forwardPanMaximumDegrees;
    configuration.panCenterTarget = (int32_t)panCenterTarget;
    configuration.panTargetsPerDegree = panTargetsPerDegree;
    configuration.upperCounterRotationGain = cameraCounterRotationGain;

    if (![serialBox applyNeckSafetyConfiguration:configuration]) {
        self.neckSafetyConfigurationStatusLabel.stringValue = @"Invalid";
        self.neckSafetyConfigurationStatusLabel.textColor = NSColor.systemRedColor;
        self.neckSafetyConfigurationStatusLabel.toolTip =
            @"Check finite unknown/off min/max angles, pan calibration, and gain (−10…+10).";
        NSBeep();
        return;
    }

    [self loadNeckSafetyConfigurationControls];
    self.neckSafetyConfigurationStatusLabel.stringValue = @"Saved";
    self.neckSafetyConfigurationStatusLabel.textColor = NSColor.systemGreenColor;
    self.neckSafetyConfigurationStatusLabel.toolTip = @"Validated and saved as one configuration.";
}

- (void)refreshNeckCommandReadouts
{
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    [self refreshNeckCameraLevelingControl];
    if (serialBox == nil) {
        self.headPanCommandLabel.stringValue = @"P command —";
        self.lowerNeckCommandLabel.stringValue = @"L —";
        self.upperNeckCommandLabel.stringValue = @"U —";
        return;
    }
    BOOL panEnvelopeRestricted = serialBox.isNeckPanEnvelopeRestricted;
    BOOL panNeedsAttention = serialBox.isNeckPanCommandLimited
        || panEnvelopeRestricted;
    BOOL startupOwnsSliderPresentation = serialBox.isSafeNeckStartupInProgress
        || [serialBox.neckCommandSource isEqualToString:@"Torso safe startup"];
    if (startupOwnsSliderPresentation
        && !self.pendingNeckOperatorCommandAfterStartup) {
        // The sliders normally express operator demand, but while the fixed
        // startup sequence owns the axes they must show its accepted targets.
        // Preserve a deliberate edit queued during startup; it will be replayed
        // with operator authority immediately after startup completes.
        if (serialBox.neckPanCommandKnown
            && serialBox.commandedNeckPanTarget != ROBNeckSafetyTargetOff) {
            self.headPan.integerValue = serialBox.commandedNeckPanTarget;
        }
        if (serialBox.lowerNeckTiltCommandKnown
            && serialBox.commandedLowerNeckTiltTarget
                != ROBNeckSafetyTargetOff) {
            self.headTilt.integerValue =
                serialBox.commandedLowerNeckTiltTarget;
        }
        if (serialBox.upperNeckTiltCommandKnown
            && serialBox.commandedUpperNeckTiltTarget
                != ROBNeckSafetyTargetOff) {
            self.headUpperNeckTilt.integerValue =
                serialBox.commandedUpperNeckTiltTarget;
        }
    }

    if (!serialBox.neckPanCommandKnown) {
        self.headPanCommandLabel.stringValue = @"P UNKNOWN";
    } else if (serialBox.commandedNeckPanTarget == ROBNeckSafetyTargetOff) {
        self.headPanCommandLabel.stringValue = @"P OFF";
    } else if (isfinite(serialBox.commandedNeckPanDegrees)) {
        self.headPanCommandLabel.stringValue = [NSString stringWithFormat:@"P %ld  %+.1f°%@",
            (long)serialBox.commandedNeckPanTarget,
            serialBox.commandedNeckPanDegrees,
            panNeedsAttention ? @" !" : @""];
    } else {
        self.headPanCommandLabel.stringValue = [NSString stringWithFormat:@"P %ld raw",
            (long)serialBox.commandedNeckPanTarget];
    }
    self.lowerNeckCommandLabel.stringValue = !serialBox.lowerNeckTiltCommandKnown
        ? @"L UNKNOWN"
        : (serialBox.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff
            ? @"L OFF"
            : [NSString stringWithFormat:@"L %ld", (long)serialBox.commandedLowerNeckTiltTarget]);
    self.upperNeckCommandLabel.stringValue = !serialBox.upperNeckTiltCommandKnown
        ? @"U UNKNOWN"
        : (serialBox.commandedUpperNeckTiltTarget == ROBNeckSafetyTargetOff
            ? @"U OFF"
            : [NSString stringWithFormat:@"U %ld%@",
            (long)serialBox.commandedUpperNeckTiltTarget,
            serialBox.isUpperNeckCommandCompensated ? @" ↺" : @""]);

    NSColor *panColor = !serialBox.neckPanCommandKnown
        ? NSColor.systemOrangeColor
        : panNeedsAttention
        ? NSColor.systemOrangeColor
        : NSColor.secondaryLabelColor;
    self.headPanCommandLabel.textColor = panColor;
    self.lowerNeckCommandLabel.textColor = !serialBox.lowerNeckTiltCommandKnown
        || [serialBox.neckCommandSafetyStatus containsString:@"LOWER HELD"]
        ? NSColor.systemOrangeColor
        : NSColor.secondaryLabelColor;
    self.upperNeckCommandLabel.textColor = !serialBox.upperNeckTiltCommandKnown
        || [serialBox.neckCommandSafetyStatus containsString:@"CAMERA LIMIT"]
        ? NSColor.systemOrangeColor
        : NSColor.secondaryLabelColor;

    NSString *detail = [NSString stringWithFormat:
        @"%@ • LEVEL %@ • %@ • pan envelope %@ %+.1f°…%+.1f° • commanded targets only (no shaft feedback)",
        serialBox.neckCommandSource ?: @"Unknown source",
        serialBox.neckCameraLevelingEnabled ? @"ON" : @"OFF",
        serialBox.neckCommandSafetyStatus ?: @"No safety status",
        panEnvelopeRestricted ? @"RESTRICTED" : @"FULL",
        serialBox.currentNeckPanMinimumDegrees,
        serialBox.currentNeckPanMaximumDegrees];
    self.headPanCommandLabel.toolTip = detail;
    self.lowerNeckCommandLabel.toolTip = detail;
    self.upperNeckCommandLabel.toolTip = detail;
}

- (IBAction)shutup:(id)sender {
    [self.robMainViewController.speechBox stopIt:nil];
    [self.robMainViewController resetSpeechResponseAttentionTimer];
    self.robMainViewController.speechBox.isSpeaking = false;
}

- (IBAction)restartSpeech:(id)sender {
    [self.robMainViewController.speechBox startRecognizer];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    NSTextField *textField = obj.object;
    if (textField == self.amberHostIP_TextField) {
        NSLog(@"setting amberHostIP to %@", textField.stringValue);
        self.robMainViewController.serialBox.amberHostIP = textField.stringValue;
        [[NSUserDefaults standardUserDefaults] setObject:textField.stringValue
                                                  forKey:ROBAmberHostIPDefaultsKey];
    }
}

#pragma mark - Amber controller recovery and host discovery

- (void)setupAmberReconnectControl
{
    // Place this above the existing host selector without changing the legacy
    // storyboard or its manually positioned servo panels.
    NSView *hostPanel = self.amberHostIP_TextField.superview;
    if (hostPanel == nil) return;
    NSRect hostFrame = [hostPanel convertRect:hostPanel.bounds toView:self.view];
    self.reconnectAmberArmsButton = [NSButton
        buttonWithTitle:@"Reconnect Amber Arms…"
        target:self
        action:@selector(reconnectAmberArms:)];
    self.reconnectAmberArmsButton.frame = NSMakeRect(
        NSMidX(hostFrame) - 85, NSMaxY(hostFrame) + 7, 170, 26);
    self.reconnectAmberArmsButton.controlSize = NSControlSizeSmall;
    self.reconnectAmberArmsButton.font = [NSFont systemFontOfSize:11];
    self.reconnectAmberArmsButton.accessibilityLabel = @"Reconnect both Amber arms";
    self.reconnectAmberArmsButton.toolTip =
        @"Restart both CAN adapters and arm cores, verify traffic, and reconnect telemetry. Opens the restart confirmation and recovery status in Amber Arm Diagnostics.";
    [self.view addSubview:self.reconnectAmberArmsButton];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(amberStackMaintenanceDidChange:)
               name:@"ROBAmberStackMaintenanceDidChange"
             object:[ROBAmberStackMaintenanceController shared]];
    [self amberStackMaintenanceDidChange:nil];
}

- (void)amberStackMaintenanceDidChange:(NSNotification *)notification
{
    BOOL running = [ROBAmberStackMaintenanceController shared].isRunning;
    self.reconnectAmberArmsButton.enabled = !running;
    self.reconnectAmberArmsButton.title = running
        ? @"Reconnecting Amber Arms…" : @"Reconnect Amber Arms…";
}

- (IBAction)reconnectAmberArms:(id)sender
{
    NSString *host = [self.amberHostIP_TextField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Use the diagnostics workflow so its motion interlocks, confirmation,
    // authority revocation, and success-only reconnect remain the single path.
    [[ROBAmberDiagnosticsWindowController shared] reconnectArmsWithHost:host
                                                                sender:sender];
}

- (void)startAmberHostDiscovery
{
    self.resolvingAmberServices = [NSMutableSet set];
    self.amberServiceBrowsers = [NSMutableArray array];

    // Ubuntu normally publishes its .local hostname through Avahi even when it
    // does not have a custom Amber service installed. ROB's controller reports
    // amber-master as its static hostname; retain amber.local as a legacy alias.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *hostName in @[@"amber-master.local", @"amber.local"]) {
            struct addrinfo hints = {0};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            struct addrinfo *results = NULL;
            int status = getaddrinfo(hostName.UTF8String, NULL, &hints, &results);
            BOOL found = NO;
            if (status == 0) {
                for (struct addrinfo *result = results; result != NULL; result = result->ai_next) {
                    struct sockaddr_in *address = (struct sockaddr_in *)result->ai_addr;
                    char buffer[INET_ADDRSTRLEN] = {0};
                    if (inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer)) != NULL) {
                        NSString *host = [NSString stringWithUTF8String:buffer];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self applyDiscoveredAmberHost:host source:hostName];
                        });
                        found = YES;
                        break;
                    }
                }
            }
            if (results != NULL) { freeaddrinfo(results); }
            if (found) { break; }
        }
    });

    // This controller has been verified on ROB's LAN. Probe SSH before using
    // it so an offline/stale address does not replace a working saved value.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int descriptor = socket(AF_INET, SOCK_STREAM, 0);
        if (descriptor < 0) { return; }
        struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(22);
        inet_pton(AF_INET, "10.0.0.26", &address.sin_addr);
        BOOL reachable = connect(descriptor, (struct sockaddr *)&address, sizeof(address)) == 0;
        close(descriptor);
        if (reachable) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self applyDiscoveredAmberHost:@"10.0.0.26" source:@"verified SSH controller"];
            });
        }
    });

    for (NSString *serviceType in @[@"_ssh._tcp.", @"_workstation._tcp."]) {
        NSNetServiceBrowser *browser = [[NSNetServiceBrowser alloc] init];
        browser.delegate = self;
        [self.amberServiceBrowsers addObject:browser];
        [browser searchForServicesOfType:serviceType inDomain:@"local."];
    }
    NSLog(@"Searching the local network for the Amber Ubuntu controller");
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    NSString *identity = [NSString stringWithFormat:@"%@ %@", service.name, service.hostName ?: @""];
    if ([identity rangeOfString:@"amber" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return;
    }
    service.delegate = self;
    [self.resolvingAmberServices addObject:service];
    [service resolveWithTimeout:5.0];
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
    for (NSData *addressData in service.addresses) {
        const struct sockaddr *socketAddress = addressData.bytes;
        if (socketAddress == NULL || socketAddress->sa_family != AF_INET) { continue; }
        const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)socketAddress;
        char buffer[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer)) != NULL) {
            [self applyDiscoveredAmberHost:[NSString stringWithUTF8String:buffer]
                                   source:service.name];
            break;
        }
    }
    [self.resolvingAmberServices removeObject:service];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
    NSLog(@"Could not resolve Amber service %@: %@", service.name, errorDict);
    [self.resolvingAmberServices removeObject:service];
}

- (void)applyDiscoveredAmberHost:(NSString *)host source:(NSString *)source
{
    if (host.length == 0) { return; }
    self.amberHostIP_TextField.stringValue = host;
    self.robMainViewController.serialBox.amberHostIP = host;
    [[NSUserDefaults standardUserDefaults] setObject:host forKey:ROBAmberHostIPDefaultsKey];
    NSLog(@"Discovered Amber controller at %@ via %@", host, source);
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.keyframeNameTextField) {
        [[ROBAnimationStudio shared] legacyNameChanged:self.keyframeNameTextField.stringValue];
    }
    if (obj.object == self.sequenceNameTextField) {
        [[ROBAnimationStudio shared] renameSequence:self.sequenceNameTextField.stringValue];
    }
}

- (IBAction)showAnimationStudio:(id)sender { [[ROBAnimationStudio shared] show]; }
- (IBAction)newSequence:(id)sender { [[ROBAnimationStudio shared] newSequence]; }
- (IBAction)copyNamedKeyframeToCurrentSequence:(id)sender { [[ROBAnimationStudio shared] addSelectedPose]; }
- (IBAction)playCurrentlySelectedKeyframeAnimation:(id)sender { [[ROBAnimationStudio shared] previewPose]; }
- (IBAction)playSelectedSequence:(id)sender { [[ROBAnimationStudio shared] previewSelectedSequence]; }
- (IBAction)captureKeyframe_Torso:(id)sender { [[ROBAnimationStudio shared] recordLegacyControls]; }

- (NSDictionary<NSString *, NSSlider *> *)animationMaestroSliders {
    return @{@"maestro.0":self.headPan, @"maestro.1":self.headTilt, @"maestro.2":self.headUpperNeckTilt,
        @"maestro.4":self.arm_L_Elbow_Pan, @"maestro.5":self.arm_R_Elbow_Pan,
        @"maestro.10":self.arm_R_Wrist_Tilt, @"maestro.11":self.arm_R_Gripper,
        @"maestro.12":self.arm_L_Shoulder_Pan, @"maestro.13":self.arm_L_Shoulder_Tilt,
        @"maestro.14":self.arm_L_Elbow_Tilt, @"maestro.15":self.arm_L_Wrist_Pan,
        @"maestro.16":self.arm_L_Wrist_Tilt, @"maestro.17":self.arm_L_Gripper};
}

- (NSDictionary<NSString *, NSButton *> *)animationMaestroEnables {
    return @{@"maestro.0":self.headPan_enabled, @"maestro.1":self.headTilt_enabled, @"maestro.2":self.headUpperNeckTilt_enabled,
        @"maestro.4":self.arm_L_Elbow_Pan_enabled, @"maestro.5":self.arm_R_Elbow_Pan_enabled,
        @"maestro.10":self.arm_R_Wrist_Tilt_enabled, @"maestro.11":self.arm_R_Gripper_enabled,
        @"maestro.12":self.arm_L_Shoulder_Pan_enabled, @"maestro.13":self.arm_L_Shoulder_Tilt_enabled,
        @"maestro.14":self.arm_L_Elbow_Tilt_enabled, @"maestro.15":self.arm_L_Wrist_Pan_enabled,
        @"maestro.16":self.arm_L_Wrist_Tilt_enabled, @"maestro.17":self.arm_L_Gripper_enabled};
}

- (NSDictionary<NSString *, NSNumber *> *)animationControlValues {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *arm in @[@"left", @"right"]) {
        NSArray<NSSlider *> *sliders = [self armPositionSlidersForGatewayArm:arm];
        NSString *physical = [arm isEqualToString:@"left"] ? @"right" : @"left";
        for (NSUInteger i=0; i<sliders.count; i++) {
            values[[NSString stringWithFormat:@"arm.%@.j%lu", physical, (unsigned long)i+1]] = @(sliders[i].doubleValue / 100.0);
        }
    }
    for (NSString *key in [self animationMaestroSliders]) values[key] = @([self animationMaestroSliders][key].doubleValue);
    ROBTorsoControlCenter *torso = [ROBTorsoControlCenter shared];
    if (isfinite(torso.observedHeading)) values[@"torso.heading"] = @(torso.observedHeading);
    if (isfinite(torso.animationPreviewReferenceHeading)) values[@"preview.torsoReference"] = @(torso.animationPreviewReferenceHeading);
    ROBNeckSafetyConfig neck = [self.robMainViewController.serialBox neckSafetyConfiguration];
    values[@"preview.neckPanCenter"] = @(neck.panCenterTarget);
    if (isfinite(neck.panTargetsPerDegree) && neck.panTargetsPerDegree != 0) values[@"preview.neckPanTargetsPerDegree"] = @(neck.panTargetsPerDegree);
    values[@"lact.speed"] = @0;
    return values;
}

- (void)animationMaestroDemand:(NSNotification *)notification {
    NSDictionary *values = notification.userInfo[@"values"];
    for (NSString *key in values) {
        NSSlider *slider = [self animationMaestroSliders][key];
        if (slider == nil) continue;
        slider.doubleValue = [values[key] doubleValue];
        [self animationMaestroEnables][key].state = NSControlStateValueOn;
    }
}

- (NSArray<NSString *> *)animationEnabledChannels {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *side in @[@"right", @"left"]) {
        NSButton *enabled = [side isEqualToString:@"right"] ? self.arm_L10_keyframe_enabled : self.arm_R11_keyframe_enabled;
        if (enabled.state == NSControlStateValueOn) for (NSUInteger j=1;j<=7;j++) [keys addObject:[NSString stringWithFormat:@"arm.%@.j%lu",side,(unsigned long)j]];
    }
    for (NSString *key in [self animationMaestroEnables]) if ([self animationMaestroEnables][key].state == NSControlStateValueOn) [keys addObject:key];
    return keys;
}

- (IBAction)mirrorPosition_R11_to_L10:(id)sender {
    self.arm_L10_position_cmdTime.doubleValue = self.arm_R11_position_cmdTime.doubleValue;
    self.arm_L10_position_cmdSleep.doubleValue = self.arm_R11_position_cmdSleep.doubleValue;
    NSArray<NSNumber *> *values = [ROBArmPoseMirror mirroredJointValues:
        [[self armPositionSlidersForGatewayArm:@"right"] valueForKey:@"doubleValue"]];
    NSArray<NSSlider *> *destination = [self armPositionSlidersForGatewayArm:@"left"];
    if (values.count != 7) return;
    for (NSUInteger i = 0; i < 7; i++) destination[i].doubleValue = values[i].doubleValue;
    [self armPositionSlidersWereEditedForGatewayArm:@"left"];
    [self update_arm_L10_Action:self];
}

- (IBAction)mirrorPosition_L10_to_R11:(id)sender {
    self.arm_R11_position_cmdTime.doubleValue = self.arm_L10_position_cmdTime.doubleValue;
    self.arm_R11_position_cmdSleep.doubleValue = self.arm_L10_position_cmdSleep.doubleValue;
    NSArray<NSNumber *> *values = [ROBArmPoseMirror mirroredJointValues:
        [[self armPositionSlidersForGatewayArm:@"left"] valueForKey:@"doubleValue"]];
    NSArray<NSSlider *> *destination = [self armPositionSlidersForGatewayArm:@"right"];
    if (values.count != 7) return;
    for (NSUInteger i = 0; i < 7; i++) destination[i].doubleValue = values[i].doubleValue;
    [self armPositionSlidersWereEditedForGatewayArm:@"right"];
    [self update_arm_R11_Action:self];
}

- (NSArray<NSSlider *> *)armPositionSlidersForGatewayArm:(NSString *)arm
{
    if ([arm isEqualToString:@"left"]) return @[
        self.arm_L10_position_servo1, self.arm_L10_position_servo2, self.arm_L10_position_servo3,
        self.arm_L10_position_servo4, self.arm_L10_position_servo5, self.arm_L10_position_servo6,
        self.arm_L10_position_servo7];
    return @[
        self.arm_R11_position_servo1, self.arm_R11_position_servo2, self.arm_R11_position_servo3,
        self.arm_R11_position_servo4, self.arm_R11_position_servo5, self.arm_R11_position_servo6,
        self.arm_R11_position_servo7];
}

- (void)refreshAmberPositionControls
{
    ROBAmberGatewayClient *gateway = ROBAmberGatewayClient.shared;
    for (NSString *arm in @[@"left", @"right"]) {
        BOOL l10 = [arm isEqualToString:@"left"];
        ROBArmPositionControlState *state = l10 ? self.l10PositionControlState : self.r11PositionControlState;
        ROBAmberGatewayTelemetry *sample = [gateway telemetryForArm:arm];
        NSArray<NSNumber *> *values = [state nextSliderValuesWithTargetRadians:[gateway targetPositionsForArm:arm]
            measuredRadians:sample.positionsRadians ?: @[]
            feedbackFresh:sample != nil && sample.effectiveSampleAgeMilliseconds <= ROBArmPositionControlState.maximumFeedbackAgeMilliseconds];
        if (values.count != 7) continue;
        NSArray<NSSlider *> *sliders = [self armPositionSlidersForGatewayArm:arm];
        for (NSUInteger i = 0; i < 7; i++) sliders[i].doubleValue = values[i].doubleValue;
        // Update labels only. A passive refresh must never call Send Position.
        if (l10) [self update_arm_L10_Action:self];
        else [self update_arm_R11_Action:self];
    }
}

- (void)armPositionSlidersWereEditedForGatewayArm:(NSString *)arm
{
    ROBArmPositionControlState *state = [arm isEqualToString:@"left"]
        ? self.l10PositionControlState : self.r11PositionControlState;
    [state noteEditedSliderValues:[[self armPositionSlidersForGatewayArm:arm] valueForKey:@"doubleValue"]];
    if (ROBArmRoutineCoordinator.shared.ownsPhysicalMotion) {
        [ROBArmRoutineCoordinator.shared cancelWithReason:@"Operator adjusted an arm position; automatic motion held"];
        [ROBShowMotionCoordinator.shared stop];
    }
    if (ROBAmberGestureExecutor.shared.isExecuting) {
        [ROBAmberGestureExecutor.shared cancelCurrentGestureWithReason:@"Operator adjusted an arm position"];
    }
    if (ROBTorsoControlCenter.shared.isArmed) [ROBTorsoControlCenter.shared stop];
}

- (void) bindArm_controls
{
    for (NSString *key in [self animationMaestroSliders]) {
        NSString *channel = [key componentsSeparatedByString:@"."].lastObject;
        [self animationMaestroSliders][key].accessibilityLabel = [@"Maestro channel " stringByAppendingString:channel];
        if (channel.integerValue > 2) [self animationMaestroEnables][key].title = [@"Ch " stringByAppendingString:channel];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(animationMaestroDemand:) name:@"ROBAnimationMaestroDemand" object:nil];
    __weak typeof(self) weakSelf = self;
    [[ROBAnimationPlayback shared] configureSpeech:^(NSString *text, void (^completion)(BOOL)) {
        ROBSpeechBox *speech = weakSelf.robMainViewController.speechBox;
        if (speech) [speech sayAnimationGreeting:text completion:completion];
        else completion(NO);
    } cancel:^{ [weakSelf.robMainViewController.speechBox stopIt:nil]; }];
    [[ROBAnimationStudio shared] connectWithLibrary:self.keyframeTableView clips:self.keyframeSequenceDetailsTableView
        sequences:self.keyframeSequencesTableView poseName:self.keyframeNameTextField sequenceName:self.sequenceNameTextField
        serial:self.robMainViewController.serialBox capture:^NSDictionary<NSString *, NSNumber *> *{ return [weakSelf animationControlValues] ?: @{}; }
        enabled:^NSArray<NSString *> *{ return [weakSelf animationEnabledChannels] ?: @[]; }];

    self.robMainViewController.serialBox.amberHostIP = self.amberHostIP_TextField.stringValue;
    self.robMainViewController.serialBox.amberMasterCoreOutput_R11 = self.amberMasterCore_R11;
    self.robMainViewController.serialBox.amberMasterCoreOutput_L10 = self.amberMasterCore_L10;
    
    self.robMainViewController.serialBox.arm_R11_force = self.arm_R11_force;
    
    self.robMainViewController.serialBox.arm_R11_cmdTime = self.arm_R11_cmdTime;
    self.robMainViewController.serialBox.arm_R11_cmdSleep = self.arm_R11_cmdSleep;
    self.robMainViewController.serialBox.arm_R11_positionX = self.arm_R11_positionX;
    self.robMainViewController.serialBox.arm_R11_positionY = self.arm_R11_positionY;
    self.robMainViewController.serialBox.arm_R11_positionZ = self.arm_R11_positionZ;
    self.robMainViewController.serialBox.arm_R11_roll = self.arm_R11_roll;
    self.robMainViewController.serialBox.arm_R11_pitch = self.arm_R11_pitch;
    self.robMainViewController.serialBox.arm_R11_yaw = self.arm_R11_yaw;
    
    self.robMainViewController.serialBox.arm_R11_position_cmdTime = self.arm_R11_position_cmdTime;
    self.robMainViewController.serialBox.arm_R11_position_cmdSleep = self.arm_R11_position_cmdSleep;
    self.robMainViewController.serialBox.arm_R11_position_servo1 = self.arm_R11_position_servo1;
    self.robMainViewController.serialBox.arm_R11_position_servo2 = self.arm_R11_position_servo2;
    self.robMainViewController.serialBox.arm_R11_position_servo3 = self.arm_R11_position_servo3;
    self.robMainViewController.serialBox.arm_R11_position_servo4 = self.arm_R11_position_servo4;
    self.robMainViewController.serialBox.arm_R11_position_servo5 = self.arm_R11_position_servo5;
    self.robMainViewController.serialBox.arm_R11_position_servo6 = self.arm_R11_position_servo6;
    self.robMainViewController.serialBox.arm_R11_position_servo7 = self.arm_R11_position_servo7;
    
    self.robMainViewController.serialBox.arm_L10_force = self.arm_L10_force;
    
    self.robMainViewController.serialBox.arm_L10_cartesian_cmdTime = self.arm_L10_cartesian_cmdTime;
    self.robMainViewController.serialBox.arm_L10_cartesian_cmdSleep = self.arm_L10_cartesian_cmdSleep;
    self.robMainViewController.serialBox.arm_L10_cartesian_positionX = self.arm_L10_cartesian_positionX;
    self.robMainViewController.serialBox.arm_L10_cartesian_positionY = self.arm_L10_cartesian_positionY;
    self.robMainViewController.serialBox.arm_L10_cartesian_positionZ = self.arm_L10_cartesian_positionZ;
    self.robMainViewController.serialBox.arm_L10_cartesian_roll = self.arm_L10_cartesian_roll;
    self.robMainViewController.serialBox.arm_L10_cartesian_pitch = self.arm_L10_cartesian_pitch;
    self.robMainViewController.serialBox.arm_L10_cartesian_yaw = self.arm_L10_cartesian_yaw;
    
    self.robMainViewController.serialBox.arm_L10_position_cmdTime = self.arm_L10_position_cmdTime;
    self.robMainViewController.serialBox.arm_L10_position_cmdSleep = self.arm_L10_position_cmdSleep;
    self.robMainViewController.serialBox.arm_L10_position_servo1 = self.arm_L10_position_servo1;
    self.robMainViewController.serialBox.arm_L10_position_servo2 = self.arm_L10_position_servo2;
    self.robMainViewController.serialBox.arm_L10_position_servo3 = self.arm_L10_position_servo3;
    self.robMainViewController.serialBox.arm_L10_position_servo4 = self.arm_L10_position_servo4;
    self.robMainViewController.serialBox.arm_L10_position_servo5 = self.arm_L10_position_servo5;
    self.robMainViewController.serialBox.arm_L10_position_servo6 = self.arm_L10_position_servo6;
    self.robMainViewController.serialBox.arm_L10_position_servo7 = self.arm_L10_position_servo7;

    [self loadNeckSafetyConfigurationControls];
    [self refreshNeckCommandReadouts];
}

#pragma mark - Servo Commands

- (BOOL)synchronizeUneditedNeckSlidersForControl:(NSControl *)control
{
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    if (serialBox == nil || serialBox.isSafeNeckStartupInProgress
        || self.pendingNeckOperatorCommandAfterStartup) return YES;

    // A manual edit changes only its selected axis. Search/tracking may have
    // changed the other applied targets since these sliders last rendered.
    // Never overwrite the axis being dragged or a deliberate startup queue.
    BOOL editsPan = control == self.headPan || control == (id)self.headPan_enabled;
    BOOL editsLower = control == self.headTilt || control == (id)self.headTilt_enabled;
    BOOL editsUpper = control == self.headUpperNeckTilt
        || control == (id)self.headUpperNeckTilt_enabled;
    BOOL editsEnableToggle = control == (id)self.headPan_enabled
        || control == (id)self.headTilt_enabled
        || control == (id)self.headUpperNeckTilt_enabled;
    BOOL uneditedAxisInactive = NO;
    NSNumber *upperDemand = serialBox.upperNeckOperatorDemandTarget;
    if (!editsUpper && serialBox.upperNeckTiltCommandKnown
        && serialBox.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff
        && upperDemand == nil) return NO;

    if (!editsPan) {
        BOOL active = serialBox.neckPanCommandKnown
            && serialBox.commandedNeckPanTarget != ROBNeckSafetyTargetOff;
        uneditedAxisInactive = uneditedAxisInactive || !active;
        self.headPan_enabled.state = active ? NSControlStateValueOn : NSControlStateValueOff;
        if (active) self.headPan.integerValue = serialBox.commandedNeckPanTarget;
    }
    if (!editsLower) {
        BOOL active = serialBox.lowerNeckTiltCommandKnown
            && serialBox.commandedLowerNeckTiltTarget != ROBNeckSafetyTargetOff;
        uneditedAxisInactive = uneditedAxisInactive || !active;
        self.headTilt_enabled.state = active ? NSControlStateValueOn : NSControlStateValueOff;
        if (active) self.headTilt.integerValue = serialBox.commandedLowerNeckTiltTarget;
    }
    if (!editsUpper) {
        uneditedAxisInactive = uneditedAxisInactive || upperDemand == nil;
        self.headUpperNeckTilt_enabled.state = upperDemand != nil
            ? NSControlStateValueOn : NSControlStateValueOff;
        // The slider is an uncompensated demand. Copying the applied upper
        // output would apply Keep upright's lower-neck adjustment twice.
        if (upperDemand != nil) self.headUpperNeckTilt.integerValue = upperDemand.integerValue;
    }
    // The coupled gateway can recenter/retain supporting axes during an OFF
    // request. A slider-only gesture must not initiate that recovery on an
    // untouched inactive/unknown axis. Deliberate enable/disable toggles retain
    // their original coupled startup/shutdown behavior below.
    return editsEnableToggle || !uneditedAxisInactive;
}

- (IBAction) reconnectMaestro:(id)sender;
{
    [self.robMainViewController.serialBox connectMaestro];
}


- (IBAction) applyServoCommand:(NSControl *)slider
{
    ROBBubbleRuntime *bubbles = [ROBBubbleRuntime shared];
    if (slider == (id)self.arm_R_Shoulder_Pan_enabled
        || slider == (id)self.arm_R_Shoulder_Tilt_enabled) {
        BOOL enabled = ((NSButton *)slider).state == NSControlStateValueOn;
        // These checkboxes control the coupled mount together. A slider must
        // never silently restore pulses after the operator has released it.
        self.arm_R_Shoulder_Pan_enabled.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        self.arm_R_Shoulder_Tilt_enabled.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        if (!enabled) [bubbles releaseMount];
        else [bubbles manualPan:self.arm_R_Shoulder_Tilt.integerValue tilt:self.arm_R_Shoulder_Pan.integerValue];
        return;
    }
    if (slider == self.arm_R_Shoulder_Pan || slider == self.arm_R_Shoulder_Tilt) {
        if (self.arm_R_Shoulder_Pan_enabled.state == NSControlStateValueOn
            && self.arm_R_Shoulder_Tilt_enabled.state == NSControlStateValueOn) {
            [bubbles manualPan:self.arm_R_Shoulder_Tilt.integerValue tilt:self.arm_R_Shoulder_Pan.integerValue];
        }
        return;
    }
    if (slider == self.arm_R_Elbow_Tilt || slider == (id)self.arm_R_Elbow_Tilt_enabled) {
        [bubbles legacyMotorControlWithFan:YES on:self.arm_R_Elbow_Tilt_enabled.state == NSControlStateValueOn && self.arm_R_Elbow_Tilt.integerValue > 4000];
        return;
    }
    if (slider == self.arm_R_Wrist_Pan || slider == (id)self.arm_R_Wrist_Pan_enabled) {
        [bubbles legacyMotorControlWithFan:NO on:self.arm_R_Wrist_Pan_enabled.state == NSControlStateValueOn && self.arm_R_Wrist_Pan.integerValue > 4000];
        return;
    }
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    BOOL neckSliderAction = slider == self.headPan
        || slider == self.headTilt
        || slider == self.headUpperNeckTilt;
    BOOL neckOperatorAction = slider == self.headPan
        || slider == self.headTilt
        || slider == self.headUpperNeckTilt
        || slider == (id)self.headPan_enabled
        || slider == (id)self.headTilt_enabled
        || slider == (id)self.headUpperNeckTilt_enabled;
    if (neckOperatorAction && ![self synchronizeUneditedNeckSlidersForControl:slider]) {
        [self refreshNeckCommandReadouts];
        NSBeep();
        return;
    }
    BOOL allNeckAxesEnabled = self.headPan_enabled.state == NSControlStateValueOn
        && self.headTilt_enabled.state == NSControlStateValueOn
        && self.headUpperNeckTilt_enabled.state == NSControlStateValueOn;
    BOOL neckNeedsSafeStartup = serialBox != nil
        && (!serialBox.neckCommandStateKnown
            || serialBox.commandedNeckPanTarget == ROBNeckSafetyTargetOff
            || serialBox.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff
            || serialBox.commandedUpperNeckTiltTarget == ROBNeckSafetyTargetOff);
    BOOL neckActivationAction = (slider == self.headPan
            && self.headPan_enabled.state == NSControlStateValueOn)
        || (slider == self.headTilt
            && self.headTilt_enabled.state == NSControlStateValueOn)
        || (slider == self.headUpperNeckTilt
            && self.headUpperNeckTilt_enabled.state == NSControlStateValueOn)
        || (slider == (id)self.headPan_enabled
            && self.headPan_enabled.state == NSControlStateValueOn)
        || (slider == (id)self.headTilt_enabled
            && self.headTilt_enabled.state == NSControlStateValueOn)
        || (slider == (id)self.headUpperNeckTilt_enabled
            && self.headUpperNeckTilt_enabled.state == NSControlStateValueOn);
    BOOL neckDeactivationAction = (slider == (id)self.headPan_enabled
            && self.headPan_enabled.state == NSControlStateValueOff)
        || (slider == (id)self.headTilt_enabled
            && self.headTilt_enabled.state == NSControlStateValueOff)
        || (slider == (id)self.headUpperNeckTilt_enabled
            && self.headUpperNeckTilt_enabled.state == NSControlStateValueOff);
    BOOL neckEnableToggleAction = (slider == (id)self.headPan_enabled
            && self.headPan_enabled.state == NSControlStateValueOn)
        || (slider == (id)self.headTilt_enabled
            && self.headTilt_enabled.state == NSControlStateValueOn)
        || (slider == (id)self.headUpperNeckTilt_enabled
            && self.headUpperNeckTilt_enabled.state == NSControlStateValueOn);
    if (neckNeedsSafeStartup && neckActivationAction
        && (allNeckAxesEnabled || neckEnableToggleAction)) {
        // Recover the neck as one coupled unit; never energize only the first
        // checkbox an operator happens to switch back on. A slider-only edit
        // must not reactivate an untouched OFF or unknown axis.
        self.headPan_enabled.state = NSControlStateValueOn;
        self.headTilt_enabled.state = NSControlStateValueOn;
        self.headUpperNeckTilt_enabled.state = NSControlStateValueOn;
        allNeckAxesEnabled = YES;
    } else if (neckNeedsSafeStartup && neckDeactivationAction) {
        // From an unknown pose, an OFF action must also remain atomic: do not
        // energize either of the two still-checked axes as a side effect.
        self.headPan_enabled.state = NSControlStateValueOff;
        self.headTilt_enabled.state = NSControlStateValueOff;
        self.headUpperNeckTilt_enabled.state = NSControlStateValueOff;
        allNeckAxesEnabled = NO;
    }
    ROBNeckSafetyConfig neckSafetyConfiguration =
        [serialBox neckSafetyConfiguration];
    // A deliberate pan gesture may re-establish the exact enabled lower
    // slider demand only inside the fixed full-clearance band. The gateway
    // still recenters, stages the coupled upper axis, writes lower, and waits
    // for command-space settling before it widens pan.
    BOOL panRequestsSafeLowerRecovery = slider == self.headPan
        && self.headTilt_enabled.state == NSControlStateValueOn
        && ROBNeckSafetyLowerTargetHasFullPanClearance(
            &neckSafetyConfiguration,
            (int)lround(self.headTilt.doubleValue)
        );
    BOOL lowerTiltOperatorAction = slider == self.headTilt
        || slider == (id)self.headTilt_enabled
        || panRequestsSafeLowerRecovery;

    if (neckOperatorAction
        && serialBox.isSafeNeckStartupInProgress
        && !allNeckAxesEnabled) {
        // An explicit OFF action wins immediately and drops any deferred move.
        self.pendingNeckOperatorCommandAfterStartup = NO;
        self.pendingLowerTiltOperatorCommandAfterStartup = NO;
        [serialBox cancelSafeNeckStartup];
    } else if (neckOperatorAction
               && serialBox.isSafeNeckStartupInProgress) {
        // Keep the controls live while the physical neck completes its staged
        // clearance move. The last slider values are sent as one deliberate
        // operator command by the timer immediately after startup completes.
        if (neckSliderAction) {
            self.pendingNeckOperatorCommandAfterStartup = YES;
            self.pendingLowerTiltOperatorCommandAfterStartup =
                self.pendingLowerTiltOperatorCommandAfterStartup
                || lowerTiltOperatorAction;
        }
        [self refreshNeckCommandReadouts];
        return;
    }
    if (neckOperatorAction
        && allNeckAxesEnabled
        && neckNeedsSafeStartup) {
        NSInteger requestedPan = self.headPan.integerValue;
        NSInteger requestedLowerTilt = self.headTilt.integerValue;
        NSInteger requestedUpperTilt = self.headUpperNeckTilt.integerValue;
        self.pendingNeckOperatorCommandAfterStartup = NO;
        self.pendingLowerTiltOperatorCommandAfterStartup = NO;
        // Restore the original operator-calibrated resting defaults. The
        // serial gateway first uses 6011 only as a temporary clearance lift.
        self.headPan.integerValue = ROBNeckSafetyDefaultForwardPanTarget;
        self.headTilt.integerValue = ROBNeckSafetyDefaultLowerTarget;
        self.headUpperNeckTilt.integerValue = ROBNeckSafetyDefaultUpperTarget;
        ROBNeckCommandDisposition disposition = [serialBox startSafeNeckStartup];
        if (disposition == ROBNeckCommandDispositionRejected) NSBeep();
        if (neckSliderAction) {
            // The startup sequence uses fixed safe targets internally, so the
            // UI can retain the operator's first request without affecting it.
            self.headPan.integerValue = requestedPan;
            self.headTilt.integerValue = requestedLowerTilt;
            self.headUpperNeckTilt.integerValue = requestedUpperTilt;
            if (serialBox.isSafeNeckStartupInProgress) {
                self.pendingNeckOperatorCommandAfterStartup = YES;
                self.pendingLowerTiltOperatorCommandAfterStartup =
                    lowerTiltOperatorAction;
            }
        }
        [self refreshNeckCommandReadouts];
        return;
    }
    if (neckOperatorAction) {
        // A live gesture after completion supersedes anything the timer was
        // about to replay from the startup window.
        self.pendingNeckOperatorCommandAfterStartup = NO;
        self.pendingLowerTiltOperatorCommandAfterStartup = NO;
    }
    [self renderServoCommandsOperatorInitiated:neckOperatorAction
                    lowerTiltOperatorInitiated:lowerTiltOperatorAction];
}


- (void) renderServoCommands
{
    [self refreshAmberPositionControls];
    ROBSerialBox *serialBox = self.robMainViewController.serialBox;
    if (self.pendingNeckOperatorCommandAfterStartup
        && !serialBox.isSafeNeckStartupInProgress) {
        BOOL lowerTiltOperatorInitiated =
            self.pendingLowerTiltOperatorCommandAfterStartup;
        self.pendingNeckOperatorCommandAfterStartup = NO;
        self.pendingLowerTiltOperatorCommandAfterStartup = NO;
        [self renderServoCommandsOperatorInitiated:YES
                        lowerTiltOperatorInitiated:lowerTiltOperatorInitiated];
        return;
    }
    [self renderServoCommandsOperatorInitiated:NO
                    lowerTiltOperatorInitiated:NO];
}

- (void)renderServoCommandsOperatorInitiated:(BOOL)operatorInitiated
                  lowerTiltOperatorInitiated:(BOOL)lowerTiltOperatorInitiated
{
    int offValue = 0;
    [self.robMainViewController.serialBox
     torso_controllerPassthrough_head_pan:[NSString stringWithFormat:@"%.f", self.headPan_enabled.state == NSControlStateValueOn? self.headPan.floatValue : offValue]
     head_tilt:[NSString stringWithFormat:@"%.f", self.headTilt_enabled.state == NSControlStateValueOn? self.headTilt.floatValue : offValue]
     head_upperNeckTilt:[NSString stringWithFormat:@"%.f", self.headUpperNeckTilt_enabled.state == NSControlStateValueOn? self.headUpperNeckTilt.floatValue : offValue]
     arm_R_shoulder_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Shoulder_Pan_enabled.state == NSControlStateValueOn? self.arm_R_Shoulder_Pan.floatValue: offValue]
     arm_R_shoulder_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Shoulder_Tilt_enabled.state == NSControlStateValueOn? self.arm_R_Shoulder_Tilt.floatValue: offValue]
     arm_R_elbow_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Elbow_Pan_enabled.state == NSControlStateValueOn? self.arm_R_Elbow_Pan.floatValue : offValue]
     arm_R_elbow_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Elbow_Tilt_enabled.state == NSControlStateValueOn? self.arm_R_Elbow_Tilt.floatValue : offValue]
     arm_R_wrist_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Wrist_Pan_enabled.state == NSControlStateValueOn? self.arm_R_Wrist_Pan.floatValue : offValue]
     arm_R_wrist_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Wrist_Tilt_enabled.state == NSControlStateValueOn? self.arm_R_Wrist_Tilt.floatValue : offValue]
     arm_R_gripper:[NSString stringWithFormat:@"%.f", self.arm_R_Gripper_enabled.state == NSControlStateValueOn? self.arm_R_Gripper.floatValue : offValue]
     arm_L_shoulder_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Shoulder_Pan_enabled.state == NSControlStateValueOn? self.arm_L_Shoulder_Pan.floatValue : offValue]
     arm_L_shoulder_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Shoulder_Tilt_enabled.state == NSControlStateValueOn? self.arm_L_Shoulder_Tilt.floatValue : offValue]
     arm_L_elbow_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Elbow_Pan_enabled.state == NSControlStateValueOn? self.arm_L_Elbow_Pan.floatValue : offValue]
     arm_L_elbow_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Elbow_Tilt_enabled.state == NSControlStateValueOn? self.arm_L_Elbow_Tilt.floatValue : offValue]
     arm_L_wrist_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Wrist_Pan_enabled.state == NSControlStateValueOn? self.arm_L_Wrist_Pan.floatValue : offValue]
     arm_L_wrist_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Wrist_Tilt_enabled.state == NSControlStateValueOn? self.arm_L_Wrist_Tilt.floatValue : offValue]
     arm_L_gripper:[NSString stringWithFormat:@"%.f", self.arm_L_Gripper_enabled.state == NSControlStateValueOn? self.arm_L_Gripper.floatValue : offValue]
     operatorInitiated:operatorInitiated
     lowerTiltOperatorInitiated:lowerTiltOperatorInitiated
     ];
    [self refreshNeckCommandReadouts];
}

- (IBAction)sshIntoAmberMasterAndRunTail_R11:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunTail_R11:self];
    });
}

- (IBAction)sshIntoAmberMasterAndRunTail_L10:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunTail_L10:self];
    });
}

- (IBAction)sshIntoAmberMasterAndRunCore_L10:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunCore_L10:self];
    });
}

- (IBAction)sshIntoAmberMasterAndRunCore_R11:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunCore_R11:self];
    });
}

- (IBAction) watchPositionOut_R11:(id)sender {
    [self.robMainViewController.serialBox watch_position_out_R11:self];
}

- (IBAction) watchPositionOut_L10:(id)sender {
    [self.robMainViewController.serialBox watch_position_out_L10:self];
}


- (IBAction) zeroPosition_R11:(id)sender {
    [self.arm_R11_position_servo1 setFloatValue:0.0];
    [self.arm_R11_position_servo1_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo2 setFloatValue:0.0];
    [self.arm_R11_position_servo2_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo3 setFloatValue:0.0];
    [self.arm_R11_position_servo3_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo4 setFloatValue:0.0];
    [self.arm_R11_position_servo4_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo5 setFloatValue:0.0];
    [self.arm_R11_position_servo5_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo6 setFloatValue:0.0];
    [self.arm_R11_position_servo6_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo7 setFloatValue:0.0];
    [self.arm_R11_position_servo7_label setStringValue:@"0.0"];
    
    [self.robMainViewController.serialBox zeroPosition_R11:sender];
}

- (IBAction)calibrateGripper_R11:(id)sender {
    [self.robMainViewController.serialBox calibrateGripper_R11:sender];
}

- (IBAction) openGripper_R11:(id)sender {
    [self.robMainViewController.serialBox openGripper_R11:sender];
}

- (IBAction) closeGripper_R11:(id)sender {
    [self.robMainViewController.serialBox closeGripper_R11:sender];
}

- (IBAction)update_arm_R11_Action:(id)sender {
    if ([[self armPositionSlidersForGatewayArm:@"right"] containsObject:sender]) {
        [self armPositionSlidersWereEditedForGatewayArm:@"right"];
    }
    
    int force = [self.arm_R11_force intValue];
    self.arm_R11_force_label.stringValue = [NSString stringWithFormat:@"%i", force];
    
    //-----
    
    double cmdTime = [self.arm_R11_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_R11_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_R11_positionX doubleValue]/100.0;
    double posY = [self.arm_R11_positionY doubleValue]/100.0;
    double posZ = [self.arm_R11_positionZ doubleValue]/100.0;
    double roll = [self.arm_R11_roll doubleValue]/100.0;
    double pitch = [self.arm_R11_pitch doubleValue]/100.0;
    double yaw = [self.arm_R11_yaw doubleValue]/100.0;
    
    self.arm_R11_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime];
    self.arm_R11_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep];
    self.arm_R11_positionX_label.stringValue = [NSString stringWithFormat:@"%f", posX];
    self.arm_R11_positionY_label.stringValue = [NSString stringWithFormat:@"%f", posY];
    self.arm_R11_positionZ_label.stringValue = [NSString stringWithFormat:@"%f", posZ];
    self.arm_R11_roll_label.stringValue = [NSString stringWithFormat:@"%f", roll];
    self.arm_R11_pitch_label.stringValue = [NSString stringWithFormat:@"%f", pitch];
    self.arm_R11_yaw_label.stringValue = [NSString stringWithFormat:@"%f", yaw];
    
    //-----
    
    double cmdTime_pos = [self.arm_R11_position_cmdTime doubleValue]/10.0;
    double cmdSleep_pos = [self.arm_R11_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_R11_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_R11_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_R11_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_R11_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_R11_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_R11_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_R11_position_servo7 doubleValue]/100.0;
    
    self.arm_R11_position_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime_pos];
    self.arm_R11_position_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep_pos];
    self.arm_R11_position_servo1_label.stringValue = [NSString stringWithFormat:@"%f", servo1];
    self.arm_R11_position_servo2_label.stringValue = [NSString stringWithFormat:@"%f", servo2];
    self.arm_R11_position_servo3_label.stringValue = [NSString stringWithFormat:@"%f", servo3];
    self.arm_R11_position_servo4_label.stringValue = [NSString stringWithFormat:@"%f", servo4];
    self.arm_R11_position_servo5_label.stringValue = [NSString stringWithFormat:@"%f", servo5];
    self.arm_R11_position_servo6_label.stringValue = [NSString stringWithFormat:@"%f", servo6];
    self.arm_R11_position_servo7_label.stringValue = [NSString stringWithFormat:@"%f", servo7];
}

- (IBAction) zeroPosition_L10:(id)sender {
    [self.arm_L10_position_servo1 setFloatValue:0.0];
    [self.arm_L10_position_servo1_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo2 setFloatValue:0.0];
    [self.arm_L10_position_servo2_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo3 setFloatValue:0.0];
    [self.arm_L10_position_servo3_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo4 setFloatValue:0.0];
    [self.arm_L10_position_servo4_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo5 setFloatValue:0.0];
    [self.arm_L10_position_servo5_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo6 setFloatValue:0.0];
    [self.arm_L10_position_servo6_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo7 setFloatValue:0.0];
    [self.arm_L10_position_servo7_label setStringValue:@"0.0"];
    
    [self.robMainViewController.serialBox zeroPosition_L10:sender];
}

- (IBAction)calibrateGripper_L10:(id)sender {
    [self.robMainViewController.serialBox calibrateGripper_L10:sender];
}

- (IBAction) openGripper_L10:(id)sender {
    [self.robMainViewController.serialBox openGripper_L10:sender];
}

- (IBAction) closeGripper_L10:(id)sender {
    [self.robMainViewController.serialBox closeGripper_L10:sender];
}

- (IBAction)update_arm_L10_Action:(id)sender {
    if ([[self armPositionSlidersForGatewayArm:@"left"] containsObject:sender]) {
        [self armPositionSlidersWereEditedForGatewayArm:@"left"];
    }
    int force = [self.arm_L10_force intValue];
    self.arm_L10_force_label.stringValue = [NSString stringWithFormat:@"%i", force];
    
    //-----
    
    double cmdTime = [self.arm_L10_cartesian_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_L10_cartesian_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_L10_cartesian_positionX doubleValue]/100.0;
    double posY = [self.arm_L10_cartesian_positionY doubleValue]/100.0;
    double posZ = [self.arm_L10_cartesian_positionZ doubleValue]/100.0;
    double roll = [self.arm_L10_cartesian_roll doubleValue]/100.0;
    double pitch = [self.arm_L10_cartesian_pitch doubleValue]/100.0;
    double yaw = [self.arm_L10_cartesian_yaw doubleValue]/100.0;
    
    self.arm_L10_cartesian_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime];
    self.arm_L10_cartesian_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep];
    self.arm_L10_cartesian_positionX_label.stringValue = [NSString stringWithFormat:@"%f", posX];
    self.arm_L10_cartesian_positionY_label.stringValue = [NSString stringWithFormat:@"%f", posY];
    self.arm_L10_cartesian_positionZ_label.stringValue = [NSString stringWithFormat:@"%f", posZ];
    self.arm_L10_cartesian_roll_label.stringValue = [NSString stringWithFormat:@"%f", roll];
    self.arm_L10_cartesian_pitch_label.stringValue = [NSString stringWithFormat:@"%f", pitch];
    self.arm_L10_cartesian_yaw_label.stringValue = [NSString stringWithFormat:@"%f", yaw];
    
    //-----
    
    double cmdTime_pos = [self.arm_L10_position_cmdTime doubleValue]/10.0;
    double cmdSleep_pos = [self.arm_L10_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_L10_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_L10_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_L10_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_L10_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_L10_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_L10_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_L10_position_servo7 doubleValue]/100.0;
    
    self.arm_L10_position_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime_pos];
    self.arm_L10_position_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep_pos];
    self.arm_L10_position_servo1_label.stringValue = [NSString stringWithFormat:@"%f", servo1];
    self.arm_L10_position_servo2_label.stringValue = [NSString stringWithFormat:@"%f", servo2];
    self.arm_L10_position_servo3_label.stringValue = [NSString stringWithFormat:@"%f", servo3];
    self.arm_L10_position_servo4_label.stringValue = [NSString stringWithFormat:@"%f", servo4];
    self.arm_L10_position_servo5_label.stringValue = [NSString stringWithFormat:@"%f", servo5];
    self.arm_L10_position_servo6_label.stringValue = [NSString stringWithFormat:@"%f", servo6];
    self.arm_L10_position_servo7_label.stringValue = [NSString stringWithFormat:@"%f", servo7];
}
#pragma mark - R11 arm

- (IBAction)set_position_mode_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = YES;
    self.is_in_current_mode_R11 = NO;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = YES;
    [self.robMainViewController.serialBox set_position_mode_R11:sender];
}

- (IBAction)set_current_mode_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = NO;
    self.is_in_current_mode_R11 = YES;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = YES;
    [self.robMainViewController.serialBox set_current_mode_R11:sender];
}

- (IBAction)update_arm_R11_cartesian_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_R11_cartesian_Action:sender];
}

- (IBAction)update_arm_R11_position_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_R11_position_Action:sender];
}

- (IBAction)activate_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = NO;
    self.is_in_current_mode_R11 = NO;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = YES;
    [self.robMainViewController.serialBox activate_R11:sender];
}

- (IBAction)deactivate_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = NO;
    self.is_in_current_mode_R11 = NO;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = NO;
    [self.robMainViewController.serialBox deactivate_R11:sender];
}

#pragma mark - L10 arm

- (IBAction)set_position_mode_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = YES;
    self.is_in_current_mode_L10 = NO;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = YES;
    [self.robMainViewController.serialBox set_position_mode_L10:sender];
}

- (IBAction)set_current_mode_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = NO;
    self.is_in_current_mode_L10 = YES;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = YES;
    [self.robMainViewController.serialBox set_current_mode_L10:sender];
}

- (IBAction)update_arm_L10_cartesian_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_L10_cartesian_Action:sender];
}

- (IBAction)update_arm_L10_position_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_L10_position_Action:sender];
}

- (IBAction)activate_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = NO;
    self.is_in_current_mode_L10 = NO;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = YES;
    [self.robMainViewController.serialBox activate_L10:sender];
}

- (IBAction)deactivate_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = NO;
    self.is_in_current_mode_L10 = NO;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = NO;
    [self.robMainViewController.serialBox deactivate_L10:sender];
}

- (IBAction) shutdown_R11_core:(id)sender {
    [self.robMainViewController.serialBox shutdown_R11_core:sender];
}

- (IBAction) shutdown_L10_core:(id)sender {
    [self.robMainViewController.serialBox shutdown_L10_core:sender];
}



@end
