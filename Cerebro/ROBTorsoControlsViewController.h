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

@end
