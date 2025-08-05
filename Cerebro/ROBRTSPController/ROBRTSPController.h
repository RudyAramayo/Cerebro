//
//  ROBRTSPController.h
//  Encoder Demo
//
//  Created by Rodolfo Aramayo on 8/6/19.
//  Copyright © 2019 Geraint Davies. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ROBRTSPController : NSObject

+ (ROBRTSPController *) server;
- (void) startup;
- (void) shutdown;
- (NSString*) getURL;
- (void) encodeFrame:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
