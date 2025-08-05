//
//  ROBLeap.h
//  Cerebro
//
//  Created by Rob Makina on 5/17/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ROBMainViewController;

@interface ROBLeap : NSObject

@property (readwrite, retain) ROBMainViewController *delegate;
- (void)run;

@end
