//
//  ROBNiTEManager.h
//  Cerebro
//
//  Created by Rob Makina on 1/12/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "VisionTrackerProcessor.h"

#import <Foundation/Foundation.h>
#import <Quartz/Quartz.h>

@protocol HumanTrackingDelegate
//return a 3d object with info from the depth camera
- (void) heartbeat_NiTE;
- (void) didTrackHumans:(NSArray *_Nullable)humanObservations;
@end

@protocol TrackingDelegate
- (void) updateTrackingRect_1:(CGRect)rect;
- (void) updateTrackingRect_2:(CGRect)rect;
@end
/*
@interface ROBNiTEManager : NSObject

@property (readwrite, retain) VisionTrackerProcessor * _Nullable visionProcessor;
@property (readwrite, retain) NSImageView * _Nonnull imageView;
@property (readwrite, retain) NSMutableArray * _Nullable objectsToTrack;
@property (readwrite, assign) id<TrackingDelegate, HumanTrackingDelegate> _Nonnull delegate;
@property (readwrite, assign) NSRect viewFrame;

- (void) initializeNiTEManager;
- (void) initializeNiTEOther;
- (void) displayFrame:(nonnull CGImageRef)frame withAffineTransform:(CGAffineTransform)transform rects:(nonnull NSArray *)rects;
- (void) reinitializeTracking;
- (void) shutdownNiTEManager;

@end
*/
