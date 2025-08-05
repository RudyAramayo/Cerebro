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

@end

@implementation ROBKeyboardControlsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
    float delay = -1.0;
    float interval = 0.06;
    [_flipperForward setPeriodicDelay:0.0 interval:interval];
    [_flipperBackward setPeriodicDelay:0.0 interval:interval];
    [_leftButton setPeriodicDelay:0.0 interval:interval];
    [_rightButton setPeriodicDelay:0.0 interval:interval];
    [_forwardButton setPeriodicDelay:0.0 interval:interval];
    [_backwardButton setPeriodicDelay:0.0 interval:interval];
    
    self.robMainViewController.serialBox.exitSafeStartWaistRotationButton = self.exitSafeStartWaistRotationButton;
    self.robMainViewController.serialBox.energizeWaistRotationButton = self.energizeWaistRotationButton;
}


- (IBAction)forward:(id)sender
{
    [self.robMainViewController.serialBox forward:sender];
}


- (IBAction)backward:(id)sender
{
    [self.robMainViewController.serialBox backward:sender];
}


- (IBAction)left:(id)sender
{
    [self.robMainViewController.serialBox left:sender];
}


- (IBAction)right:(id)sender
{
    [self.robMainViewController.serialBox right:sender];
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
