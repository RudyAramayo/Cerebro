//
//  ROBSerialBox.h
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "ROBNeckSafetyPolicy.h"

// import IOKit headers
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <IOKit/IOBSD.h>
#include <IOKit/serial/ioss.h>
#include <sys/ioctl.h>

@class ROBMainViewController;
@class ROBBaseControllerModel;

FOUNDATION_EXPORT NSNotificationName const ROBSerialHardwareDidChangeNotification;

typedef NS_ENUM(NSInteger, ROBNeckCommandDisposition) {
    ROBNeckCommandDispositionRejected = 0,
    ROBNeckCommandDispositionAppliedCommand = 1,
    ROBNeckCommandDispositionHeldForSafety = 2,
};

@interface ROBSerialBox : NSObject
{
    int serialFileDescriptor_base; // file handle to the serial port
    int serialFileDescriptor_maestro;
    
    struct termios gOriginalTTYAttrs; // Hold the original termios attributes so we can reset them on quit ( best practice )
    bool readThreadRunning_base;
    bool readThreadRunning_maestro;
    NSTextStorage *storage;
}
@property (readwrite, retain) NSString *currentIncommingVerbalMessage;

@property (nonatomic, weak) NSTextView *serialOutputArea_base;

@property (nonatomic, weak) NSPopUpButton *serialListPullDown_base;
@property (nonatomic, weak) NSPopUpButton *serialListPullDown_maestro;

/// Last automatic-discovery result shown by the optional Settings UI. Serial
/// discovery and reconnect do not depend on either popup being instantiated.
@property (atomic, readonly, copy) NSString *baseSerialStatusText;
@property (atomic, readonly, copy) NSString *maestroSerialStatusText;

@property (readwrite, retain) ROBMainViewController *delegate;

@property (readwrite, retain) NSString *masterControllerID;

@property (readwrite, retain) NSSlider *waistRotationSlider;
@property (readwrite, assign) NSButton *exitSafeStartWaistRotationButton;
@property (readwrite, assign) NSButton *energizeWaistRotationButton;

@property (readwrite, retain) NSString *amberHostIP;

// These values are meaningful only while their corresponding `...Known`
// property is true. They are commanded targets, not measured shaft positions.
@property (readonly, assign) NSInteger commandedNeckPanTarget;
@property (readonly, assign) NSInteger commandedLowerNeckTiltTarget;
@property (readonly, assign) NSInteger commandedUpperNeckTiltTarget;
@property (readonly, assign, getter=isNeckPanCommandKnown) BOOL neckPanCommandKnown;
@property (readonly, assign, getter=isLowerNeckTiltCommandKnown) BOOL lowerNeckTiltCommandKnown;
@property (readonly, assign, getter=isUpperNeckTiltCommandKnown) BOOL upperNeckTiltCommandKnown;
@property (readonly, assign, getter=isNeckCommandStateKnown) BOOL neckCommandStateKnown;
@property (readonly, assign) double commandedNeckPanDegrees;
@property (readonly, assign) double currentNeckPanMinimumDegrees;
@property (readonly, assign) double currentNeckPanMaximumDegrees;
@property (readonly, assign, getter=isNeckPanCommandLimited) BOOL neckPanCommandLimited;
@property (readonly, assign, getter=isUpperNeckCommandCompensated) BOOL upperNeckCommandCompensated;
@property (readonly, assign, getter=isNeckSafetyCalibrationConfirmed) BOOL neckSafetyCalibrationConfirmed;
@property (readonly, assign, getter=isNeckCameraLevelingEnabled) BOOL neckCameraLevelingEnabled;
@property (readonly, copy) NSString *neckCommandSource;
@property (readonly, copy) NSString *neckCommandSafetyStatus;

- (ROBNeckSafetyConfig)neckSafetyConfiguration;
- (BOOL)applyNeckSafetyConfiguration:(ROBNeckSafetyConfig)configuration;
/// Persists the runtime leveling mode and, when all three active commands are
/// known, reapplies only that neck pose through the shared safety gateway with
/// the current upper target as the new camera demand. Unknown/OFF poses are
/// never energized by this toggle.
- (BOOL)setNeckCameraLevelingEnabled:(BOOL)enabled;

@property (readwrite, retain) NSSlider *arm_R11_force;

@property (readwrite, retain) NSSlider *arm_R11_cmdTime;
@property (readwrite, retain) NSSlider *arm_R11_cmdSleep;
@property (readwrite, retain) NSSlider *arm_R11_positionX;
@property (readwrite, retain) NSSlider *arm_R11_positionY;
@property (readwrite, retain) NSSlider *arm_R11_positionZ;
@property (readwrite, retain) NSSlider *arm_R11_roll;
@property (readwrite, retain) NSSlider *arm_R11_pitch;
@property (readwrite, retain) NSSlider *arm_R11_yaw;

@property (readwrite, retain) NSSlider *arm_R11_position_cmdTime;
@property (readwrite, retain) NSSlider *arm_R11_position_cmdSleep;
@property (readwrite, retain) NSSlider *arm_R11_position_servo1;
@property (readwrite, retain) NSSlider *arm_R11_position_servo2;
@property (readwrite, retain) NSSlider *arm_R11_position_servo3;
@property (readwrite, retain) NSSlider *arm_R11_position_servo4;
@property (readwrite, retain) NSSlider *arm_R11_position_servo5;
@property (readwrite, retain) NSSlider *arm_R11_position_servo6;
@property (readwrite, retain) NSSlider *arm_R11_position_servo7;

@property (readwrite, retain) NSSlider *arm_L10_force;

@property (readwrite, retain) NSSlider *arm_L10_cartesian_cmdTime;
@property (readwrite, retain) NSSlider *arm_L10_cartesian_cmdSleep;
@property (readwrite, retain) NSSlider *arm_L10_cartesian_positionX;
@property (readwrite, retain) NSSlider *arm_L10_cartesian_positionY;
@property (readwrite, retain) NSSlider *arm_L10_cartesian_positionZ;
@property (readwrite, retain) NSSlider *arm_L10_cartesian_roll;
@property (readwrite, retain) NSSlider *arm_L10_cartesian_pitch;
@property (readwrite, retain) NSSlider *arm_L10_cartesian_yaw;

@property (readwrite, retain) NSSlider *arm_L10_position_cmdTime;
@property (readwrite, retain) NSSlider *arm_L10_position_cmdSleep;
@property (readwrite, retain) NSSlider *arm_L10_position_servo1;
@property (readwrite, retain) NSSlider *arm_L10_position_servo2;
@property (readwrite, retain) NSSlider *arm_L10_position_servo3;
@property (readwrite, retain) NSSlider *arm_L10_position_servo4;
@property (readwrite, retain) NSSlider *arm_L10_position_servo5;
@property (readwrite, retain) NSSlider *arm_L10_position_servo6;
@property (readwrite, retain) NSSlider *arm_L10_position_servo7;

@property (readwrite, retain) NSTextView *amberMasterCoreOutput_R11;
@property (readwrite, retain) NSTextView *amberMasterCoreOutput_L10;

- (void) serialPortSelected_base;
- (void) serialPortSelected_maestro;
- (void)selectBaseSerialPort:(NSString *)path;

- (void) sendBaseCommand:(NSString *)command;

- (void) initialize_connection;
- (void) connectMaestro;
- (void)refreshSerialPortControls;


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
- (void)applyVisionNeckPan:(float)pan tilt:(float)tilt;
/// Typed ingress for autonomous neck gestures. Pan is calibrated degrees;
/// lower/upper are Maestro command targets because those axes do not yet have
/// verified degree calibration. Acceptance reports a commanded (unverified)
/// result, never physical arrival. Renew the short lease while a gesture runs.
- (ROBNeckCommandDisposition)requestNeckGesturePanDegrees:(double)panDegrees
                                      lowerTiltRawTarget:(NSInteger)lowerTiltRawTarget
                                     cameraTiltRawTarget:(NSInteger)cameraTiltRawTarget
                                           leaseDuration:(NSTimeInterval)leaseDuration
                                                   source:(NSString *)source;
- (void)cancelNeckGestureAuthority;
- (void)applyVisionGrippersActive:(BOOL)active leftClosed:(BOOL)leftClosed rightClosed:(BOOL)rightClosed;
- (void)applyVisionTorsoActive:(BOOL)active rotation:(float)rotation;
- (void)switchToMasterControllerID:(NSString *)controllerID;
- (void)stopBaseMotionAndDropHeartbeat;

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
                                arm_L_gripper:(NSString *)arm_L_gripper
                            operatorInitiated:(BOOL)operatorInitiated
                   lowerTiltOperatorInitiated:(BOOL)lowerTiltOperatorInitiated;

- (IBAction) shutdown_R11_core:(id)sender;
- (IBAction) shutdown_L10_core:(id)sender;

- (IBAction) sshIntoAmberMasterAndRunCore_R11:(id)sender;
- (IBAction) sshIntoAmberMasterAndRunCore_L10:(id)sender;

- (IBAction) watch_position_out_R11:(id)sender;
- (IBAction) watch_position_out_L10:(id)sender;

#pragma mark - R11 actions

- (IBAction)sshIntoAmberMasterAndRunTail_R11:(id)sender;
- (IBAction)zeroPosition_R11:(id)sender;
- (IBAction)calibrateGripper_R11:(id)sender;
- (IBAction)openGripper_R11:(id)sender;
- (IBAction)closeGripper_R11:(id)sender;
- (IBAction)set_position_mode_R11:(id)sender;
- (IBAction)set_current_mode_R11:(id)sender;
- (IBAction)update_arm_R11_cartesian_Action:(id)sender;
- (IBAction)update_arm_R11_position_Action:(id)sender;
- (IBAction)activate_R11:(id)sender;
- (IBAction)deactivate_R11:(id)sender;

#pragma mark - L10 actions

- (IBAction)sshIntoAmberMasterAndRunTail_L10:(id)sender;
- (IBAction)zeroPosition_L10:(id)sender;
- (IBAction)calibrateGripper_L10:(id)sender;
- (IBAction)openGripper_L10:(id)sender;
- (IBAction)closeGripper_L10:(id)sender;
- (IBAction)set_position_mode_L10:(id)sender;
- (IBAction)set_current_mode_L10:(id)sender;
- (IBAction)update_arm_L10_cartesian_Action:(id)sender;
- (IBAction)update_arm_L10_position_Action:(id)sender;
- (IBAction)activate_L10:(id)sender;
- (IBAction)deactivate_L10:(id)sender;

/// Narrow Stage Show bridge. Callers must supply an allow-listed, prevalidated
/// choreography transform; this method performs a second bounds check.
- (BOOL)commandRightAmberSaberX:(double)x y:(double)y z:(double)z
                           roll:(double)roll pitch:(double)pitch yaw:(double)yaw
                       duration:(NSTimeInterval)duration;

@end
