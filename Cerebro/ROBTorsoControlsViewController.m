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


@interface ROBTorsoControlsViewController ()

@property (readwrite, retain) NSTimer *renderServoControlsTimer;
@property (readwrite, retain) NSTimer *maestroGetErrorsTimer;


@end

@implementation ROBTorsoControlsViewController

- (void) viewDidLoad
{
    self.renderServoControlsTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                                     target:self
                                                                   selector:@selector(renderServoCommands)
                                                                   userInfo:nil
                                                                    repeats:YES];
    self.maestroGetErrorsTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                                     target:self
                                                                   selector:@selector(maestro_getErrors_command)
                                                                   userInfo:nil
                                                                    repeats:YES];
    
}

- (void) bindArm_controls
{
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
    
}


- (void) maestro_getErrors_command
{
    [self.robMainViewController.serialBox maestro_getErrors_command];
}


- (IBAction) reconnectMaestro:(id)sender;
{
    [self.robMainViewController.serialBox connectMaestro];
}


- (IBAction) applyServoCommand:(NSSlider *)slider
{
    [self renderServoCommands];
}


- (void) renderServoCommands
{
    int offValue = 0;
    //[self.robMainViewController.serialBox connectMaestro];
    [self.robMainViewController.serialBox
     torso_controllerPassthrough_head_pan:[NSString stringWithFormat:@"%.f", self.headPan_enabled.state == NSOnState? self.headPan.floatValue : offValue]
     head_tilt:[NSString stringWithFormat:@"%.f", self.headTilt_enabled.state == NSOnState? self.headTilt.floatValue : offValue]
     head_upperNeckTilt:[NSString stringWithFormat:@"%.f", self.headUpperNeckTilt_enabled.state == NSOnState? self.headUpperNeckTilt.floatValue : offValue]
     arm_R_shoulder_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Shoulder_Pan_enabled.state == NSOnState? self.arm_R_Shoulder_Pan.floatValue: offValue]
     arm_R_shoulder_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Shoulder_Tilt_enabled.state == NSOnState? self.arm_R_Shoulder_Tilt.floatValue: offValue]
     arm_R_elbow_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Elbow_Pan_enabled.state == NSOnState? self.arm_R_Elbow_Pan.floatValue : offValue]
     arm_R_elbow_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Elbow_Tilt_enabled.state == NSOnState? self.arm_R_Elbow_Tilt.floatValue : offValue]
     arm_R_wrist_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Wrist_Pan_enabled.state == NSOnState? self.arm_R_Wrist_Pan.floatValue : offValue]
     arm_R_wrist_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Wrist_Tilt_enabled.state == NSOnState? self.arm_R_Wrist_Tilt.floatValue : offValue]
     arm_R_gripper:[NSString stringWithFormat:@"%.f", self.arm_R_Gripper_enabled.state == NSOnState? self.arm_R_Gripper.floatValue : offValue]
     arm_L_shoulder_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Shoulder_Pan_enabled.state == NSOnState? self.arm_L_Shoulder_Pan.floatValue : offValue]
     arm_L_shoulder_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Shoulder_Tilt_enabled.state == NSOnState? self.arm_L_Shoulder_Tilt.floatValue : offValue]
     arm_L_elbow_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Elbow_Pan_enabled.state == NSOnState? self.arm_L_Elbow_Pan.floatValue : offValue]
     arm_L_elbow_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Elbow_Tilt_enabled.state == NSOnState? self.arm_L_Elbow_Tilt.floatValue : offValue]
     arm_L_wrist_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Wrist_Pan_enabled.state == NSOnState? self.arm_L_Wrist_Pan.floatValue : offValue]
     arm_L_wrist_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Wrist_Tilt_enabled.state == NSOnState? self.arm_L_Wrist_Tilt.floatValue : offValue]
     arm_L_gripper:[NSString stringWithFormat:@"%.f", self.arm_L_Gripper_enabled.state == NSOnState? self.arm_L_Gripper.floatValue : offValue]
     ];
}

- (IBAction) zeroPosition_R11:(id)sender {
    [self.robMainViewController.serialBox zeroPosition_R11:sender];
}

- (IBAction) openGripper_R11:(id)sender {
    [self.robMainViewController.serialBox openGripper_R11:sender];
}

- (IBAction) closeGripper_R11:(id)sender {
    [self.robMainViewController.serialBox closeGripper_R11:sender];
}

- (IBAction)update_arm_R11_Action:(id)sender {
    
    double force = [self.arm_R11_force doubleValue];
    self.arm_R11_force_label.stringValue = [NSString stringWithFormat:@"%f", force];
    
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
    [self.robMainViewController.serialBox zeroPosition_L10:sender];
}

- (IBAction) openGripper_L10:(id)sender {
    [self.robMainViewController.serialBox openGripper_L10:sender];
}

- (IBAction) closeGripper_L10:(id)sender {
    [self.robMainViewController.serialBox closeGripper_L10:sender];
}

- (IBAction)update_arm_L10_Action:(id)sender {
    double force = [self.arm_L10_force doubleValue];
    self.arm_L10_force_label.stringValue = [NSString stringWithFormat:@"%f", force];
    
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



//#pragma mark - R11 actions
//
//- (IBAction)set_position_mode_R11:(id)sender;
//- (IBAction)set_current_mode_R11:(id)sender;
//- (IBAction)update_arm_R11_cartesian_Action:(id)sender;
//- (IBAction)update_arm_R11_position_Action:(id)sender;
//- (IBAction)deactivate_R11:(id)sender;
//
//#pragma mark - L10 actions
//
//- (IBAction)set_position_mode_L10:(id)sender;
//- (IBAction)set_current_mode_L10:(id)sender;
//- (IBAction)update_arm_L10_cartesian_Action:(id)sender;
//- (IBAction)update_arm_L10_position_Action:(id)sender;
//- (IBAction)deactivate_L10:(id)sender;


#pragma mark - R11 arm

- (IBAction)set_position_mode_R11_SendCommand:(id)sender {
    [self.robMainViewController.serialBox set_position_mode_R11:sender];
}

- (IBAction)set_current_mode_R11_SendCommand:(id)sender {
    [self.robMainViewController.serialBox set_current_mode_R11:sender];
}

- (IBAction)update_arm_R11_cartesian_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_R11_cartesian_Action:sender];
}

- (IBAction)update_arm_R11_position_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_R11_position_Action:sender];
}

- (IBAction)deactivate_R11_SendCommand:(id)sender {
    [self.robMainViewController.serialBox deactivate_R11:sender];
}

#pragma mark - L10 arm

- (IBAction)set_position_mode_L10_SendCommand:(id)sender {
    [self.robMainViewController.serialBox set_position_mode_L10:sender];
}

- (IBAction)set_current_mode_L10_SendCommand:(id)sender {
    [self.robMainViewController.serialBox set_current_mode_L10:sender];
}

- (IBAction)update_arm_L10_cartesian_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_L10_cartesian_Action:sender];
}

- (IBAction)update_arm_L10_position_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_L10_position_Action:sender];
}

- (IBAction)deactivate_L10_SendCommand:(id)sender {
    [self.robMainViewController.serialBox deactivate_L10:sender];
}




@end
