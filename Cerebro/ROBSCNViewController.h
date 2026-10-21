//
//  ROBSCNViewController.h
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>

@class ROBBaseControllerModel;
@class ROBSerialBox;

@interface ROBSCNViewController : NSObject

@property (readwrite, retain) SCNView *robo_scnView;
@property (readonly, strong) NSView *ghostGesturePanel;
@property (weak) ROBSerialBox *serialBox;

- (instancetype)initWithRobo_scnView:(SCNView *)scnView;
- (void)updateWithControllerModel:(ROBBaseControllerModel *)model sender:(NSString *)sender;
- (void)updateWithIRDistances:(NSArray<NSNumber *> *)distances receivedAtUptime:(NSTimeInterval)uptime;
- (void)updateWithLegacyIRWarningFront:(BOOL)front back:(BOOL)back receivedAtUptime:(NSTimeInterval)uptime;
- (void)invalidate;
- (void)reviewGhostPreset:(NSString *)name;

@end
