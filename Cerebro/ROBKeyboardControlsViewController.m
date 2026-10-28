//
//  ROBKeyboardControlsViewController.m
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "ROBKeyboardControlsViewController.h"
#import "ROBMainViewController.h"
#import "ROBSerialBox.h"
#import "Cerebro-Swift.h"

static NSTimeInterval const kROBLocalTreadRampInterval = 0.03;
static NSInteger const kROBLocalTreadMaximumCommand = 255;

@interface ROBMomentaryTreadButton : NSButton

@property (nonatomic, assign, getter=isTreadPressed) BOOL treadPressed;

@end

@implementation ROBMomentaryTreadButton

- (void)mouseDown:(NSEvent *)event
{
    self.treadPressed = YES;
    [self sendAction:self.action to:self.target];

    // Let AppKit retain normal push-button tracking and highlighting without
    // also emitting its historical click/repeat actions; the ramp timer owns
    // command renewal while the press is held.
    id savedTarget = self.target;
    SEL savedAction = self.action;
    self.target = nil;
    self.action = NULL;
    [super mouseDown:event];
    self.target = savedTarget;
    self.action = savedAction;

    // mouseDown: returns for mouse-up even when the pointer was dragged out of
    // the button, so the tread target cannot remain latched by a lost click.
    self.treadPressed = NO;
    [self sendAction:self.action to:self.target];
}

@end


@interface ROBKeyboardControlsViewController ()

@property (readwrite, retain) IBOutlet NSButton *flipperForward;
@property (readwrite, retain) IBOutlet NSButton *flipperBackward;

@property (readwrite, retain) IBOutlet NSButton *leftButton;
@property (readwrite, retain) IBOutlet NSButton *rightButton;
@property (readwrite, retain) IBOutlet NSButton *forwardButton;
@property (readwrite, retain) IBOutlet NSButton *backwardButton;

@property (readwrite, retain) IBOutlet NSButton *lactForward;
@property (readwrite, retain) IBOutlet NSButton *lactBackward;
@property (readwrite, retain) IBOutlet NSSlider *localTreadSpeedSlider;
@property (readwrite, retain) NSPopUpButton *localTreadAcceleration;
@property (readwrite, retain) NSTextField *localTreadOutput;
@property (readwrite, retain) ROBTreadMotionRamp *localTreadRamp;

@property (readwrite, retain) IBOutlet NSSlider *waistRotationSlider;
@property (readwrite, retain) IBOutlet NSButton *exitSafeStartWaistRotationButton;
@property (readwrite, retain) IBOutlet NSButton *energizeWaistRotationButton;
@property (readwrite, retain) NSButton *deenergizeTorsoButton;
@property (readwrite, retain) NSTextField *torsoControlOutput;

@property (readwrite, retain) NSTimer *localTreadRampTimer;
@property (readwrite, assign) NSInteger currentLeftTreadCommand;
@property (readwrite, assign) NSInteger currentRightTreadCommand;
@property (readwrite, assign) NSInteger targetLeftTreadCommand;
@property (readwrite, assign) NSInteger targetRightTreadCommand;
@property (readwrite, weak) ROBMomentaryTreadButton *heldMouseTreadButton;
@property (readwrite, retain) NSMutableOrderedSet<NSNumber *> *heldTreadKeyCodes;
@property (readwrite, retain) id treadKeyEventMonitor;

@end

@implementation ROBKeyboardControlsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
    float interval = 0.06;
    [_flipperForward setPeriodicDelay:0.0 interval:interval];
    [_flipperBackward setPeriodicDelay:0.0 interval:interval];
    self.heldTreadKeyCodes = [NSMutableOrderedSet orderedSet];
    self.localTreadRamp = [ROBTreadMotionRamp new];
    self.localTreadSpeedSlider.maxValue = 100;
    self.localTreadSpeedSlider.doubleValue = 40;
    [self.localTreadSpeedSlider setAccessibilityLabel:@"Local tread speed percent"];
    self.localTreadAcceleration = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(242, 145, 155, 28) pullsDown:NO];
    [self.localTreadAcceleration addItemsWithTitles:ROBTreadMotionRamp.modeTitles];
    [self.localTreadAcceleration selectItemAtIndex:ROBTreadMotionRamp.selectedMode];
    self.localTreadAcceleration.target = self;
    self.localTreadAcceleration.action = @selector(changeTreadAcceleration:);
    [self.localTreadAcceleration setAccessibilityLabel:@"Local tread acceleration"];
    [self.view addSubview:self.localTreadAcceleration];
    NSTextField *accelerationLabel = [NSTextField labelWithString:@"Tread acceleration"];
    accelerationLabel.frame = NSMakeRect(242, 175, 155, 20);
    [self.view addSubview:accelerationLabel];
    self.localTreadOutput = [NSTextField wrappingLabelWithString:@"Treads stopped · limit 40%"];
    self.localTreadOutput.frame = NSMakeRect(242, 90, 160, 48);
    [self.localTreadOutput setAccessibilityIdentifier:@"ROB.Treads.Output"];
    [self.view addSubview:self.localTreadOutput];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshTreadAcceleration:)
        name:ROBTreadMotionRamp.settingsChanged object:nil];
    for (NSView *view in self.view.subviews) {
        if (![view isKindOfClass:NSButton.class]) continue;
        NSButton *button = (NSButton *)view;
        if (button.action == @selector(tredBrakeLock:)) {
            button.title = @"Stop treads";
            [button setButtonType:NSButtonTypeMomentaryPushIn];
        } else if (button.action == @selector(maxSpeedButton:) || button.action == @selector(speedIncrease:)
            || button.action == @selector(speedDecrease:) || button.action == @selector(speedTenPercent:)) {
            [button setButtonType:NSButtonTypeMomentaryPushIn];
        }
    }

    // Arrow keys are handled as true key-down/key-up events below. Clearing
    // the cell equivalents prevents an extra click-style action on key-down.
    for (NSButton *button in @[
        self.leftButton, self.rightButton, self.forwardButton, self.backwardButton
    ]) {
        button.keyEquivalent = @"";
    }
    
    // Replace the historical absolute-step slider in place. Preserve the
    // storyboard's unrelated controls and use a true release-to-zero lever.
    NSSlider *oldSlider = self.waistRotationSlider;
    ROBTorsoVelocitySlider *lever = [[ROBTorsoVelocitySlider alloc] initWithFrame:oldSlider.frame];
    lever.autoresizingMask = oldSlider.autoresizingMask;
    lever.minValue = -1; lever.maxValue = 1; lever.doubleValue = 0;
    lever.continuous = YES; lever.numberOfTickMarks = 3;
    lever.target = self; lever.action = @selector(waistRotationAction:);
    lever.toolTip = @"Torso turn speed. Arm in Torso Rotation, then hold and slide. Release to stop.";
    [lever setAccessibilityLabel:@"Torso turn speed"];
    [oldSlider.superview addSubview:lever];
    [oldSlider removeFromSuperview];
    self.waistRotationSlider = lever;
    self.exitSafeStartWaistRotationButton.title = @"Torso Rotation…";
    [self.exitSafeStartWaistRotationButton setButtonType:NSButtonTypeMomentaryPushIn];
    self.exitSafeStartWaistRotationButton.font = [NSFont systemFontOfSize:18];
    self.energizeWaistRotationButton.title = @"Energize";
    [self.energizeWaistRotationButton setButtonType:NSButtonTypeMomentaryPushIn];
    self.energizeWaistRotationButton.font = [NSFont systemFontOfSize:18];
    for (NSView *view in self.view.subviews) {
        if ([view isKindOfClass:[NSButton class]] && ((NSButton *)view).action == @selector(waistRotationResetAction:)) {
            self.deenergizeTorsoButton = (NSButton *)view;
            ((NSButton *)view).title = @"De-energize";
            ((NSButton *)view).action = @selector(deenergizeTorso:);
            ((NSButton *)view).font = [NSFont systemFontOfSize:18];
        }
    }
    self.torsoControlOutput = [NSTextField wrappingLabelWithString:@""];
    self.torsoControlOutput.frame = NSMakeRect(242, 39, 750, 44);
    self.torsoControlOutput.font = [NSFont systemFontOfSize:11];
    [self.torsoControlOutput setAccessibilityIdentifier:@"ROB.Torso.KeyboardStatus"];
    [self.view addSubview:self.torsoControlOutput];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshTorsoControl:)
        name:ROBTorsoControlCenter.changed object:ROBTorsoControlCenter.shared];
    [self refreshTorsoControl:nil];

    self.robMainViewController.serialBox.exitSafeStartWaistRotationButton = self.exitSafeStartWaistRotationButton;
    self.robMainViewController.serialBox.energizeWaistRotationButton = self.energizeWaistRotationButton;
    self.robMainViewController.serialBox.waistRotationSlider = self.waistRotationSlider;
}

- (void)viewDidAppear
{
    [super viewDidAppear];
    [self installTreadKeyMonitor];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardControlWindowDidResignKey:)
                                                 name:NSWindowDidResignKeyNotification
                                               object:self.view.window];
}

- (void)viewWillDisappear
{
    [self removeTreadKeyMonitor];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidResignKeyNotification
                                                  object:self.view.window];
    [self stopLocalTreadsImmediately];
    [[ROBTorsoControlCenter shared] releaseLever];
    [super viewWillDisappear];
}

- (void)dealloc
{
    [self removeTreadKeyMonitor];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.localTreadRampTimer invalidate];
}


- (void)handleMouseTreadButton:(ROBMomentaryTreadButton *)button
                          left:(NSInteger)left
                         right:(NSInteger)right
{
    if (button.isTreadPressed) {
        self.heldMouseTreadButton = button;
        [self setLocalTreadTargetLeft:left * self.localTreadSpeedSlider.doubleValue / 100
                              right:right * self.localTreadSpeedSlider.doubleValue / 100];
    } else if (self.heldMouseTreadButton == button) {
        self.heldMouseTreadButton = nil;
        [self refreshLocalTreadTargetFromHeldKeys];
    }
}


- (IBAction)forward:(id)sender
{
    [self handleMouseTreadButton:sender
                            left:kROBLocalTreadMaximumCommand
                           right:kROBLocalTreadMaximumCommand];
}


- (IBAction)backward:(id)sender
{
    [self handleMouseTreadButton:sender
                            left:-kROBLocalTreadMaximumCommand
                           right:-kROBLocalTreadMaximumCommand];
}


- (IBAction)left:(id)sender
{
    [self handleMouseTreadButton:sender
                            left:-kROBLocalTreadMaximumCommand
                           right:kROBLocalTreadMaximumCommand];
}


- (IBAction)right:(id)sender
{
    [self handleMouseTreadButton:sender
                            left:kROBLocalTreadMaximumCommand
                           right:-kROBLocalTreadMaximumCommand];
}


- (void)setLocalTreadTargetLeft:(NSInteger)left right:(NSInteger)right
{
    if (left != 0 || right != 0) {
        [[ROBRecycleMissionCoordinator shared] stopWithReason:@"Local tread control took over"];
    }
    self.targetLeftTreadCommand = MAX(
        -kROBLocalTreadMaximumCommand,
        MIN(kROBLocalTreadMaximumCommand, left)
    );
    self.targetRightTreadCommand = MAX(
        -kROBLocalTreadMaximumCommand,
        MIN(kROBLocalTreadMaximumCommand, right)
    );
    [self ensureLocalTreadRampTimer];
    [self updateLocalTreadRamp];
}

- (void)ensureLocalTreadRampTimer
{
    if (self.localTreadRampTimer != nil) return;

    self.localTreadRampTimer = [NSTimer timerWithTimeInterval:kROBLocalTreadRampInterval
                                                       target:self
                                                     selector:@selector(updateLocalTreadRamp)
                                                     userInfo:nil
                                                      repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.localTreadRampTimer
                              forMode:NSRunLoopCommonModes];
}

- (void)updateLocalTreadRamp
{
    if (![self.localTreadRamp advanceToLeft:self.targetLeftTreadCommand right:self.targetRightTreadCommand
            mode:ROBTreadMotionRamp.selectedMode now:NSProcessInfo.processInfo.systemUptime]) {
        [self stopLocalTreadsImmediately];
        self.localTreadOutput.stringValue = @"Treads stopped — controller timing gap";
        return;
    }
    self.currentLeftTreadCommand = self.localTreadRamp.leftCommand;
    self.currentRightTreadCommand = self.localTreadRamp.rightCommand;
    [self refreshTreadOutput];

    BOOL stopped = self.localTreadRamp.isStopped;
    if (stopped && self.targetLeftTreadCommand == 0
        && self.targetRightTreadCommand == 0) {
        // Ordinary release decelerates with the selected profile; Stop is immediate.
        [self.robMainViewController.serialBox
            sendBaseCommand:@"~+0001,+0000,+0001,+0000,+0000,+0000,+0000"];
        [self.localTreadRampTimer invalidate];
        self.localTreadRampTimer = nil;
        [self.localTreadRamp reset];
        return;
    }

    NSString *(^motorField)(NSInteger) = ^NSString *(NSInteger command) {
        return [NSString stringWithFormat:@"%@%04ld",
            command < 0 ? @"-" : @"+", labs(command)];
    };
    NSString *command = [NSString stringWithFormat:
        @"~+0000,%@,+0000,%@,+0000,+0000,+0000",
        motorField(self.currentLeftTreadCommand),
        motorField(self.currentRightTreadCommand)];
    [self.robMainViewController.serialBox sendBaseCommand:command];
}

- (void)stopLocalTreadsImmediately
{
    BOOL hadLocalTreadActivity = self.localTreadRampTimer != nil
        || self.currentLeftTreadCommand != 0
        || self.currentRightTreadCommand != 0
        || self.targetLeftTreadCommand != 0
        || self.targetRightTreadCommand != 0;
    self.heldMouseTreadButton = nil;
    [self.heldTreadKeyCodes removeAllObjects];
    self.targetLeftTreadCommand = 0;
    self.targetRightTreadCommand = 0;
    self.currentLeftTreadCommand = 0;
    self.currentRightTreadCommand = 0;
    [self.localTreadRamp reset];
    [self.localTreadRampTimer invalidate];
    self.localTreadRampTimer = nil;
    [self refreshTreadOutput];
    if (hadLocalTreadActivity) {
        [self.robMainViewController.serialBox
            sendBaseCommand:@"~+0001,+0000,+0001,+0000,+0000,+0000,+0000"];
    }
}

- (void)keyboardControlWindowDidResignKey:(NSNotification *)notification
{
    [self stopLocalTreadsImmediately];
}

- (void)installTreadKeyMonitor
{
    if (self.treadKeyEventMonitor != nil) return;
    __weak typeof(self) weakSelf = self;
    self.treadKeyEventMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
        handler:^NSEvent * _Nullable(NSEvent *event) {
            return [weakSelf handleTreadKeyEvent:event];
        }];
}

- (void)removeTreadKeyMonitor
{
    if (self.treadKeyEventMonitor == nil) return;
    [NSEvent removeMonitor:self.treadKeyEventMonitor];
    self.treadKeyEventMonitor = nil;
}

- (NSEvent *)handleTreadKeyEvent:(NSEvent *)event
{
    if (event.window != self.view.window || !self.view.window.isKeyWindow) return event;
    if ((event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask)
        & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        return event;
    }

    NSNumber *keyCode = @(event.keyCode);
    if (event.type == NSEventTypeKeyDown && event.keyCode == 53) {
        [self stopLocalTreadsImmediately];
        return nil;
    }
    if (![self isTreadArrowKeyCode:keyCode]) return event;
    if (event.type == NSEventTypeKeyDown && event.isARepeat) return nil;

    if (event.type == NSEventTypeKeyDown) {
        if (!event.isARepeat) {
            [self.heldTreadKeyCodes removeObject:keyCode];
            [self.heldTreadKeyCodes addObject:keyCode];
        }
    } else if (event.type == NSEventTypeKeyUp) {
        [self.heldTreadKeyCodes removeObject:keyCode];
    }
    if (self.heldMouseTreadButton == nil) {
        [self refreshLocalTreadTargetFromHeldKeys];
    }
    return nil;
}

- (BOOL)isTreadArrowKeyCode:(NSNumber *)keyCode
{
    // Hardware-independent virtual key codes for left, right, down, and up.
    return [@[@123, @124, @125, @126] containsObject:keyCode];
}

- (void)refreshLocalTreadTargetFromHeldKeys
{
    NSInteger demand = lround(255 * self.localTreadSpeedSlider.doubleValue / 100);
    NSNumber *keyCode = self.heldTreadKeyCodes.lastObject;
    switch (keyCode.integerValue) {
        case 126:
            [self setLocalTreadTargetLeft:demand right:demand];
            break;
        case 125:
            [self setLocalTreadTargetLeft:-demand right:-demand];
            break;
        case 123:
            [self setLocalTreadTargetLeft:-demand right:demand];
            break;
        case 124:
            [self setLocalTreadTargetLeft:demand right:-demand];
            break;
        default:
            [self setLocalTreadTargetLeft:0 right:0];
            break;
    }
}


- (IBAction)flipperForwardPush:(id)sender
{
    [self.robMainViewController.serialBox flipperForwardPush:sender];
}


- (IBAction)flipperBackwardPush:(id)sender
{
    [self.robMainViewController.serialBox flipperBackwardPush:sender];
}


- (IBAction)leanforward:(id)sender
{
    [self.robMainViewController.serialBox leanforward:sender];
}


- (IBAction)leanback:(id)sender
{
    [self.robMainViewController.serialBox leanback:sender];
}


- (IBAction)tredBrakeLock:(id)sender
{
    [self stopLocalTreadsImmediately];
}


- (IBAction)flipperBrakeLock:(id)sender
{
    [self.robMainViewController.serialBox flipperBrakeLock:sender];
}


- (IBAction)relaxFlipperBrake:(id)sender
{
    [self.robMainViewController.serialBox relaxFlipperBrake:sender];
}


- (IBAction)LACTGravityButton:(id)sender
{
    [self.robMainViewController.serialBox LACTGravityButton:sender];
}

- (IBAction)rewindButton:(id)sender
{
    [self.robMainViewController.serialBox rewindButton:sender];
}


- (IBAction)fastforwardButton:(id)sender
{
    [self.robMainViewController.serialBox fastforwardButton:sender];
}


- (IBAction)playPauseAnimateButton:(id)sender
{
    [self.robMainViewController.serialBox playPauseAnimateButton:sender];
}


- (IBAction)maxSpeedButton:(id)sender
{
    self.localTreadSpeedSlider.doubleValue = 100;
    [self speedSliderAction:self.localTreadSpeedSlider];
}


- (IBAction)speedIncrease:(id)sender
{
    self.localTreadSpeedSlider.doubleValue = MIN(100, self.localTreadSpeedSlider.doubleValue + 10);
    [self speedSliderAction:self.localTreadSpeedSlider];
}


- (IBAction)speedDecrease:(id)sender
{
    self.localTreadSpeedSlider.doubleValue = MAX(0, self.localTreadSpeedSlider.doubleValue - 10);
    [self speedSliderAction:self.localTreadSpeedSlider];
}


- (IBAction)speedTenPercent:(id)sender
{
    self.localTreadSpeedSlider.doubleValue = 10;
    [self speedSliderAction:self.localTreadSpeedSlider];
}


- (IBAction)speedSliderAction:(id)sender
{
    if (self.heldMouseTreadButton != nil) {
        [self.heldMouseTreadButton sendAction:self.heldMouseTreadButton.action to:self];
    } else if (self.heldTreadKeyCodes.count > 0) {
        [self refreshLocalTreadTargetFromHeldKeys];
    }
    [self refreshTreadOutput];
}

- (void)refreshTreadOutput
{
    NSString *motion = self.currentLeftTreadCommand == 0 && self.currentRightTreadCommand == 0
        ? @"Treads stopped" : [NSString stringWithFormat:@"L %+.0f%% · R %+.0f%%",
            100.0 * self.currentLeftTreadCommand / 255, 100.0 * self.currentRightTreadCommand / 255];
    self.localTreadOutput.stringValue = [NSString stringWithFormat:@"%@ · limit %.0f%%", motion, self.localTreadSpeedSlider.doubleValue];
}

- (void)changeTreadAcceleration:(NSPopUpButton *)sender
{
    ROBTreadMotionRamp.selectedMode = sender.indexOfSelectedItem;
}

- (void)refreshTreadAcceleration:(NSNotification *)notification
{
    [self.localTreadAcceleration selectItemAtIndex:ROBTreadMotionRamp.selectedMode];
}

- (IBAction)waistRotationResetAction:(id)sender
{
    [self.robMainViewController.serialBox waistRotationResetAction:sender];
}

- (IBAction)waistRotationAction:(NSSlider *)sender
{
    [self.robMainViewController.serialBox waistRotationSliderAction:sender];
}

- (IBAction)exitSafeStartToggle:(id)sender
{
    [self.robMainViewController.serialBox exitSafeStartWaistRotationToggle:sender];
}

- (IBAction)energizeToggle:(id)sender
{
    [self.robMainViewController.serialBox energizeToggle:sender];
}

- (void)deenergizeTorso:(id)sender
{
    [[ROBTorsoControlCenter shared] deenergize];
}

- (void)refreshTorsoControl:(NSNotification *)notification
{
    ROBTorsoControlCenter *center = ROBTorsoControlCenter.shared;
    self.waistRotationSlider.enabled = center.isArmed;
    if (!center.isArmed) self.waistRotationSlider.doubleValue = 0;
    self.energizeWaistRotationButton.enabled = center.canEnergize;
    self.deenergizeTorsoButton.enabled = center.usesHardware;
    NSString *detail = center.compactControlDetail;
    if (![self.torsoControlOutput.stringValue isEqualToString:detail]) self.torsoControlOutput.stringValue = detail;
    self.waistRotationSlider.toolTip = center.isArmed
        ? @"Turn speed: hold and slide; release to slow to a stop."
        : center.compactControlDetail;
}

@end
