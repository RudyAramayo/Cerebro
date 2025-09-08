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

- (void) bindArm_R11_controls
{
    self.robMainViewController.serialBox.arm_R11_cmdTime = self.arm_R11_cmdTime;
    self.robMainViewController.serialBox.arm_R11_cmdSleep = self.arm_R11_cmdSleep;
    self.robMainViewController.serialBox.arm_R11_positionX = self.arm_R11_positionX;
    self.robMainViewController.serialBox.arm_R11_positionY = self.arm_R11_positionY;
    self.robMainViewController.serialBox.arm_R11_positionZ = self.arm_R11_positionZ;
    self.robMainViewController.serialBox.arm_R11_roll = self.arm_R11_roll;
    self.robMainViewController.serialBox.arm_R11_pitch = self.arm_R11_pitch;
    self.robMainViewController.serialBox.arm_R11_yaw = self.arm_R11_yaw;
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

- (IBAction)update_arm_R11_Action:(id)sender {
    
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
    
    //SENDING COMMANDS TOO FAST CAUSES UNEXPECTED BEHAVIOR!!!
    //[self update_arm_R11_SendCommand:sender];
}

- (IBAction)update_arm_R11_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_R11_Action:sender];
}

@end
