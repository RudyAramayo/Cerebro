//
//  ROBTorsoControlsViewController.h
//  Cerebro
//
//  Created by Rob Makina on 5/10/19.
//  Copyright © 2019 Rob Makina. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class ROBMainViewController;


@interface ROBTorsoControlsViewController : NSViewController


- (IBAction) reconnectMaestro:(id)sender;

@property (readwrite, retain) ROBMainViewController *robMainViewController;

@property (readwrite, retain) IBOutlet NSSlider *headPan;
@property (readwrite, retain) IBOutlet NSButton *headPan_enabled;
@property (readwrite, retain) IBOutlet NSSlider *headTilt;
@property (readwrite, retain) IBOutlet NSButton *headTilt_enabled;
@property (readwrite, retain) IBOutlet NSSlider *headUpperNeckTilt;
@property (readwrite, retain) IBOutlet NSButton *headUpperNeckTilt_enabled;

@property (readwrite, retain) IBOutlet NSSlider *arm_R_Shoulder_Pan;
@property (readwrite, retain) IBOutlet NSButton *arm_R_Shoulder_Pan_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_R_Shoulder_Tilt;
@property (readwrite, retain) IBOutlet NSButton *arm_R_Shoulder_Tilt_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_R_Elbow_Pan;
@property (readwrite, retain) IBOutlet NSSlider *arm_R_Elbow_Tilt;
@property (readwrite, retain) IBOutlet NSButton *arm_R_Elbow_Pan_enabled;
@property (readwrite, retain) IBOutlet NSButton *arm_R_Elbow_Tilt_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_R_Wrist_Pan;
@property (readwrite, retain) IBOutlet NSButton *arm_R_Wrist_Pan_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_R_Wrist_Tilt;
@property (readwrite, retain) IBOutlet NSButton *arm_R_Wrist_Tilt_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_R_Gripper;
@property (readwrite, retain) IBOutlet NSButton *arm_R_Gripper_enabled;

@property (readwrite, retain) IBOutlet NSSlider *arm_L_Shoulder_Pan;
@property (readwrite, retain) IBOutlet NSButton *arm_L_Shoulder_Pan_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_L_Shoulder_Tilt;
@property (readwrite, retain) IBOutlet NSButton *arm_L_Shoulder_Tilt_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_L_Elbow_Pan;
@property (readwrite, retain) IBOutlet NSSlider *arm_L_Elbow_Tilt;
@property (readwrite, retain) IBOutlet NSButton *arm_L_Elbow_Pan_enabled;
@property (readwrite, retain) IBOutlet NSButton *arm_L_Elbow_Tilt_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_L_Wrist_Pan;
@property (readwrite, retain) IBOutlet NSButton *arm_L_Wrist_Pan_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_L_Wrist_Tilt;
@property (readwrite, retain) IBOutlet NSButton *arm_L_Wrist_Tilt_enabled;
@property (readwrite, retain) IBOutlet NSSlider *arm_L_Gripper;
@property (readwrite, retain) IBOutlet NSButton *arm_L_Gripper_enabled;


@property (readwrite, retain) IBOutlet NSTextField *amberHostIP_TextField;
@property (readwrite, retain) IBOutlet NSTextField *keyframeNameTextField;
@property (readwrite, retain) IBOutlet NSButton *arm_R11_keyframe_enabled;
@property (readwrite, retain) IBOutlet NSButton *arm_R11_cartesian_keyframe_enabled;
@property (readwrite, retain) IBOutlet NSButton *arm_L10_keyframe_enabled;
@property (readwrite, retain) IBOutlet NSButton *arm_L10_cartesian_keyframe_enabled;
@property (readwrite, retain) IBOutlet NSTableView *keyframeTableView;

- (IBAction)playCurrentlySelectedKeyframeAnimation:(id)sender;
- (IBAction)mirrorPosition_R11_to_L10:(id)sender;
- (IBAction)mirrorPosition_L10_to_R11:(id)sender;


#pragma mark - R11

@property (readwrite, retain) IBOutlet NSSlider *arm_R11_force;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_force_label;
- (IBAction) openGripper_R11:(id)sender;
- (IBAction) closeGripper_R11:(id)sender;

@property (readwrite, retain) IBOutlet NSSlider *arm_R11_cmdTime;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_cmdSleep;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_positionX;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_positionY;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_positionZ;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_roll;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_pitch;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_yaw;

@property (readwrite, retain) IBOutlet NSTextField *arm_R11_cmdTime_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_cmdSleep_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_positionX_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_positionY_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_positionZ_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_roll_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_pitch_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_yaw_label;

//-----

@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_cmdTime;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_cmdSleep;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_servo1;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_servo2;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_servo3;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_servo4;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_servo5;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_servo6;
@property (readwrite, retain) IBOutlet NSSlider *arm_R11_position_servo7;

@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_cmdTime_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_cmdSleep_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_servo1_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_servo2_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_servo3_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_servo4_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_servo5_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_servo6_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_R11_position_servo7_label;

#pragma mark - L10

@property (readwrite, retain) IBOutlet NSSlider *arm_L10_force;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_force_label;
- (IBAction) openGripper_L10:(id)sender;
- (IBAction) closeGripper_L10:(id)sender;

@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_cmdTime;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_cmdSleep;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_positionX;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_positionY;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_positionZ;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_roll;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_pitch;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_cartesian_yaw;

@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_cmdTime_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_cmdSleep_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_positionX_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_positionY_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_positionZ_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_roll_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_pitch_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_cartesian_yaw_label;

//-----

@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_cmdTime;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_cmdSleep;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_servo1;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_servo2;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_servo3;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_servo4;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_servo5;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_servo6;
@property (readwrite, retain) IBOutlet NSSlider *arm_L10_position_servo7;

@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_cmdTime_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_cmdSleep_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_servo1_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_servo2_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_servo3_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_servo4_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_servo5_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_servo6_label;
@property (readwrite, retain) IBOutlet NSTextField *arm_L10_position_servo7_label;

@property (readwrite, retain) IBOutlet NSTextView *amberMasterCore_R11;
@property (readwrite, retain) IBOutlet NSTextView *amberMasterCore_L10;

- (void) bindArm_controls;

@end
