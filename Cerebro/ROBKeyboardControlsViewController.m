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

static NSTimeInterval const kROBLocalTreadRampInterval = 0.03;
static NSInteger const kROBLocalTreadMaximumCommand = 100;
static NSInteger const kROBLocalTreadRampStep = 20;

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

@property (readwrite, retain) IBOutlet NSSlider *waistRotationSlider;
@property (readwrite, retain) IBOutlet NSButton *exitSafeStartWaistRotationButton;
@property (readwrite, retain) IBOutlet NSButton *energizeWaistRotationButton;

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

    // Arrow keys are handled as true key-down/key-up events below. Clearing
    // the cell equivalents prevents an extra click-style action on key-down.
    for (NSButton *button in @[
        self.leftButton, self.rightButton, self.forwardButton, self.backwardButton
    ]) {
        button.keyEquivalent = @"";
    }
    
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
        [self setLocalTreadTargetLeft:left right:right];
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

- (NSInteger)nextTreadCommandFrom:(NSInteger)current target:(NSInteger)target
{
    // A reversal always reaches zero before applying torque in the opposite
    // direction. This avoids a single-frame forward/reverse shock.
    NSInteger effectiveTarget = current * target < 0 ? 0 : target;
    NSInteger delta = effectiveTarget - current;
    if (labs(delta) <= kROBLocalTreadRampStep) return effectiveTarget;
    return current + (delta > 0 ? kROBLocalTreadRampStep : -kROBLocalTreadRampStep);
}

- (void)updateLocalTreadRamp
{
    self.currentLeftTreadCommand = [self nextTreadCommandFrom:self.currentLeftTreadCommand
                                                       target:self.targetLeftTreadCommand];
    self.currentRightTreadCommand = [self nextTreadCommandFrom:self.currentRightTreadCommand
                                                        target:self.targetRightTreadCommand];

    BOOL stopped = self.currentLeftTreadCommand == 0
        && self.currentRightTreadCommand == 0;
    if (stopped && self.targetLeftTreadCommand == 0
        && self.targetRightTreadCommand == 0) {
        // Brake only after the short deceleration ramp reaches zero.
        [self.robMainViewController.serialBox
            sendBaseCommand:@"~+0001,+0000,+0001,+0000,+0000,+0000,+0000"];
        [self.localTreadRampTimer invalidate];
        self.localTreadRampTimer = nil;
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
    [self.localTreadRampTimer invalidate];
    self.localTreadRampTimer = nil;
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
    if (![self isTreadArrowKeyCode:keyCode]) return event;

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
    NSNumber *keyCode = self.heldTreadKeyCodes.lastObject;
    switch (keyCode.integerValue) {
        case 126:
            [self setLocalTreadTargetLeft:kROBLocalTreadMaximumCommand
                                    right:kROBLocalTreadMaximumCommand];
            break;
        case 125:
            [self setLocalTreadTargetLeft:-kROBLocalTreadMaximumCommand
                                    right:-kROBLocalTreadMaximumCommand];
            break;
        case 123:
            [self setLocalTreadTargetLeft:-kROBLocalTreadMaximumCommand
                                    right:kROBLocalTreadMaximumCommand];
            break;
        case 124:
            [self setLocalTreadTargetLeft:kROBLocalTreadMaximumCommand
                                    right:-kROBLocalTreadMaximumCommand];
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
    [self.robMainViewController.serialBox tredBrakeLock:sender];
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
    [self.robMainViewController.serialBox maxSpeedButton:sender];
}


- (IBAction)speedIncrease:(id)sender
{
    [self.robMainViewController.serialBox speedIncrease:sender];
}


- (IBAction)speedDecrease:(id)sender
{
    [self.robMainViewController.serialBox speedDecrease:sender];
}


- (IBAction)speedTenPercent:(id)sender
{
    [self.robMainViewController.serialBox speedTenPercent:sender];
}


- (IBAction)speedSliderAction:(id)sender
{
    [self.robMainViewController.serialBox speedSliderAction:sender];
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

@end
