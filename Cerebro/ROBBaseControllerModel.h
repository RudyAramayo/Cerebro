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

@end
