//
//  TrackedPolyRect.h
//  NiTECamera
//
//  Created by Rob Makina on 8/2/19.
//  Copyright © 2019 Apple. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Vision/Vision.h>

@interface TrackedPolyRect : NSObject

@property (readwrite, assign) CGPoint topLeft;
@property (readwrite, assign) CGPoint topRight;
@property (readwrite, assign) CGPoint bottomLeft;
@property (readwrite, assign) CGPoint bottomRight;
@property (readwrite, retain) NSColor *color;
@property (readwrite, retain) NSString *uuid;


- (CGRect) boundingBox;

- (void) setObservation:(VNDetectedObjectObservation *) observation
                  color:(NSColor *)color;
- (void) setCGRect:(CGRect)cgRect color:(NSColor *)color;

@end

