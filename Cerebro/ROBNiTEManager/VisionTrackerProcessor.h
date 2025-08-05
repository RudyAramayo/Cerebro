//
//  VisionTrackerProcessor.h
//  NiTECamera
//
//  Created by Rob Makina on 8/2/19.
//  Copyright © 2019 Apple. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VisionTrackerProcessorDelegate <NSObject>
- (void) displayFrame:(CGImageRef) frame withAffineTransform:(CGAffineTransform)transform rects:(NSArray *)rects;
- (void) didTrackHuman:(NSArray *) humanObservations;
@end

@interface VisionTrackerProcessor : NSObject

@property (readwrite, assign) id<VisionTrackerProcessorDelegate> delegate;
@property (readwrite, retain) NSMutableArray *objectsToTrack;

- (void) initializeVisionProcessor;
- (void) initializeTracking:(CGImageRef)frame;
- (void) performTracking:(CGImageRef)frame;
- (void) performImageAnalysis:(CGImageRef)frame;


@end

NS_ASSUME_NONNULL_END
