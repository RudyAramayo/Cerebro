//
//  ROBSerialBox.h
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

// import IOKit headers
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <IOKit/IOBSD.h>
#include <IOKit/serial/ioss.h>
#include <sys/ioctl.h>

@class ROBMainViewController;
@class ROBBaseControllerModel;

@interface ROBSerialBox : NSObject
{
    int serialFileDescriptor_head; // file handle to the serial port
    int serialFileDescriptor_torso; // file handle to the serial port
    int serialFileDescriptor_base; // file handle to the serial port
    int serialFileDescriptor_maestro;
    
    struct termios gOriginalTTYAttrs; // Hold the original termios attributes so we can reset them on quit ( best practice )
    bool readThreadRunning_head;
    bool readThreadRunning_torso;
    bool readThreadRunning_base;
    bool readThreadRunning_maestro;
    NSTextStorage *storage;
}
@property (readwrite, retain) NSString *currentIncommingVerbalMessage;

@property (readwrite, retain) NSTextView *serialOutputArea_head;
@property (readwrite, retain) NSTextField *serialInputField_head;
@property (readwrite, retain) NSTextView *serialOutputArea_torso;
@property (readwrite, retain) NSTextField *serialInputField_torso;
@property (readwrite, retain) NSTextView *serialOutputArea_base;
@property (readwrite, retain) NSTextField *serialInputField_base;
@property (readwrite, retain) NSTextView *serialOutputArea_maestro;
@property (readwrite, retain) NSTextField *serialInputField_maestro;


@property (readwrite, retain) NSPopUpButton *serialListPullDown_head;
@property (readwrite, retain) NSPopUpButton *serialListPullDown_torso;
@property (readwrite, retain) NSPopUpButton *serialListPullDown_base;
@property (readwrite, retain) NSPopUpButton *serialListPullDown_maestro;

@property (readwrite, retain) ROBMainViewController *delegate;

@property (readwrite, retain) NSString *masterControllerID;

@property (readwrite, retain) NSSlider *waistRotationSlider;
@property (readwrite, assign) NSButton *exitSafeStartWaistRotationButton;
@property (readwrite, assign) NSButton *energizeWaistRotationButton;

- (void) serialPortSelected_head;
- (void) serialPortSelected_torso;
- (void) serialPortSelected_base;
- (void) serialPortSelected_maestro;

- (void) sendHeadCommand:(NSString *)command;
- (void) sendTorsoCommand:(NSString *)command;
- (void) sendBaseCommand:(NSString *)command;
- (void) sendMaestroCommand:(NSString *)command;
- (void) maestro_getErrors_command;

- (void) LACT_exitSafeStart;
- (void) initialize_connection;
- (void) connectMaestro;


- (IBAction)forward:(id)sender;
- (IBAction)backward:(id)sender;
- (IBAction)left:(id)sender;
- (IBAction)right:(id)sender;
- (IBAction)flipperForwardPush:(id)sender;
- (IBAction)flipperBackwardPush:(id)sender;
- (IBAction)leanforward:(id)sender;
- (IBAction)leanback:(id)sender;

- (IBAction)tredBrakeLock:(id)sender;
- (IBAction)flipperBrakeLock:(id)sender;
- (IBAction)relaxFlipperBrake:(id)sender;
- (IBAction)LACTGravityButton:(id)sender;

- (IBAction)rewindButton:(id)sender;
- (IBAction)fastforwardButton:(id)sender;
- (IBAction)playPauseAnimateButton:(id)sender;
- (IBAction)maxSpeedButton:(id)sender;
- (IBAction)speedIncrease:(id)sender;
- (IBAction)speedDecrease:(id)sender;
- (IBAction)speedTenPercent:(id)sender;
- (IBAction)speedSliderAction:(id)sender;
- (IBAction)waistRotationResetAction:(id)sender;
- (IBAction)waistRotationSliderAction:(NSSlider *)sender;
- (IBAction)exitSafeStartWaistRotationToggle:(id)sender;
- (IBAction)energizeToggle:(id)sender;

- (void) controllerId:(NSString *)controllerId controllerModelData:(ROBBaseControllerModel *)controllerModelData;

- (IBAction)controllerPassthrough:(CGPoint)touchPadPointL
                   touchPadPointR:(CGPoint)touchPadPointR
                              Lat:(float)Lat
                             Long:(float)Long
                    tredBrakeLock:(bool)tredBrakeLock
                         flipperForwardIsDown:(bool)flipperForwardIsDown
                flipperRelaxBrake:(bool)flipperRelaxBrake
                         flipperBackwardIsDown:(bool)flipperBackwardIsDown
                         flipperBrakeLock:(bool)flipperBrakeLock
                            lact1:(bool)lact1
                            lact2:(bool)lact2
                            lact3:(bool)lact3
                            speed:(float)speed
                  speed_playPause:(bool)speed_playPause
            speed_forward_reverse:(bool)speed_forward_reverse
                        textInput:(NSString *)textInput;

- (void) torso_controllerPassthrough_head_pan:(NSString *)head_pan
                                    head_tilt:(NSString *)head_tilt
                           head_upperNeckTilt:(NSString *)head_upperNeckTilt
                           arm_R_shoulder_pan:(NSString *)arm_R_shoulder_pan
                          arm_R_shoulder_tilt:(NSString *)arm_R_shoulder_tilt
                              arm_R_elbow_pan:(NSString *)arm_R_elbow_pan
                             arm_R_elbow_tilt:(NSString *)arm_R_elbow_tilt
                              arm_R_wrist_pan:(NSString *)arm_R_wrist_pan
                             arm_R_wrist_tilt:(NSString *)arm_R_wrist_tilt
                                arm_R_gripper:(NSString *)arm_R_gripper
                           arm_L_shoulder_pan:(NSString *)arm_L_shoulder_pan
                          arm_L_shoulder_tilt:(NSString *)arm_L_shoulder_tilt
                              arm_L_elbow_pan:(NSString *)arm_L_elbow_pan
                             arm_L_elbow_tilt:(NSString *)arm_L_elbow_tilt
                              arm_L_wrist_pan:(NSString *)arm_L_wrist_pan
                             arm_L_wrist_tilt:(NSString *)arm_L_wrist_tilt
                                arm_L_gripper:(NSString *)arm_L_gripper;
@end
