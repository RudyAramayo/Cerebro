//
//  ROBOBaseControllerInput.m
//  Cerebro
//
//  Created by Rob Makina on 5/10/19.
//  Copyright © 2019 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface ROBBaseControllerModel:NSObject

@property (readwrite, assign) CGPoint touchPadPointL;
@property (readwrite, assign) CGPoint touchPadPointR;
@property (readwrite, assign) float Lat;
@property (readwrite, assign) float Long;
@property (readwrite, assign) bool tredBrakeLock;
@property (readwrite, assign) bool flipperForwardIsDown;
@property (readwrite, assign) bool flipperRelaxBrake;
@property (readwrite, assign) bool flipperBackwardIsDown;
@property (readwrite, assign) bool flipperBrakeLock;
@property (readwrite, assign) bool lact1;
@property (readwrite, assign) bool lact2;
@property (readwrite, assign) bool lact3;
@property (readwrite, assign) float speed;
@property (readwrite, assign) bool speed_playPause;
@property (readwrite, assign) bool speed_forward_reverse;
@property (readwrite, retain) NSString *textInput;
// visionOS world-space controller poses. Values are accepted only after strict finite/range
// validation. They are inputs for a future calibrated IK layer and never drive arm hardware
// directly from this model.
@property (readwrite, assign) bool leftControllerPoseValid;
@property (readwrite, assign) float leftControllerPositionX;
@property (readwrite, assign) float leftControllerPositionY;
@property (readwrite, assign) float leftControllerPositionZ;
@property (readwrite, assign) float leftControllerOrientationX;
@property (readwrite, assign) float leftControllerOrientationY;
@property (readwrite, assign) float leftControllerOrientationZ;
@property (readwrite, assign) float leftControllerOrientationW;
@property (readwrite, assign) double leftControllerPoseTimestamp;
@property (readwrite, assign) bool rightControllerPoseValid;
@property (readwrite, assign) float rightControllerPositionX;
@property (readwrite, assign) float rightControllerPositionY;
@property (readwrite, assign) float rightControllerPositionZ;
@property (readwrite, assign) float rightControllerOrientationX;
@property (readwrite, assign) float rightControllerOrientationY;
@property (readwrite, assign) float rightControllerOrientationZ;
@property (readwrite, assign) float rightControllerOrientationW;
@property (readwrite, assign) double rightControllerPoseTimestamp;
// Monotonic receive time assigned by ROBSerialBox. A controller snapshot is
// never replayed indefinitely after its transport disappears.
@property (readwrite, assign) NSTimeInterval receivedAtUptime;

@end
