//
//  TrackedPolyRect.m
//  NiTECamera
//
//  Created by Rob Makina on 8/2/19.
//  Copyright © 2019 Apple. All rights reserved.
//

#import "TrackedPolyRect.h"
@interface TrackedPolyRect ()
@end

@implementation TrackedPolyRect

//- (NSArray *) cornerPoints{
//    return @[self.topLeft, self.topRight, self.bottomRight, self.bottomLeft];
//}

- (CGRect) boundingBox
{
    CGRect topLeftRect = CGRectMake(self.topLeft.x, self.topLeft.y, 0, 0);
    CGRect topRightRect = CGRectMake(self.topRight.x, self.topRight.y, 0, 0);
    CGRect bottomLeftRect = CGRectMake(self.bottomLeft.x, self.bottomLeft.y, 0, 0);
    CGRect bottomRightRect = CGRectMake(self.bottomRight.x, self.bottomRight.y, 0, 0);
    
    return  CGRectUnion(CGRectUnion(CGRectUnion(topLeftRect, topRightRect), bottomLeftRect), bottomRightRect);
}

- (void) setObservation:(VNDetectedObjectObservation *) observation
                       color:(NSColor *)color {
    [self setCGRect:observation.boundingBox color:color];
}

- (void) setCGRect:(CGRect)cgRect color:(NSColor *)color {
    self.topLeft = CGPointMake(CGRectGetMinX(cgRect), CGRectGetMaxY(cgRect));
    self.topRight = CGPointMake(CGRectGetMaxX(cgRect), CGRectGetMaxY(cgRect));
    self.bottomLeft = CGPointMake(CGRectGetMinX(cgRect), CGRectGetMinY(cgRect));
    self.bottomRight = CGPointMake(CGRectGetMaxX(cgRect), CGRectGetMinY(cgRect));
    self.color = color;
}

@end
