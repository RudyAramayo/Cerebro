//
//  ROBRTSPController.m
//  Encoder Demo
//
//  Created by Rodolfo Aramayo on 8/6/19.
//  Copyright © 2019 Geraint Davies. All rights reserved.
//

#import "ROBRTSPController.h"
#import "AVEncoder.h"
#import "RTSPServer.h"

static ROBRTSPController* theServer;

@interface ROBRTSPController  ()
{
    AVEncoder* _encoder;
    RTSPServer* _rtsp;
}
@end


@implementation ROBRTSPController

+ (void) initialize
{
    // test recommended to avoid duplicate init via subclass
    if (self == [ROBRTSPController class])
    {
        theServer = [[ROBRTSPController alloc] init];
    }
}

+ (ROBRTSPController *) server
{
    return theServer;
}

- (void) startup //ROB: create an encoder
{
    if (_encoder == nil)
    {
        NSLog(@"Starting up server");
        
        _encoder = [AVEncoder encoderForHeight:480 andWidth:720];
        [_encoder encodeWithBlock:^int(NSArray* data, double pts) {
            if (self->_rtsp != nil)
            {
                self->_rtsp.bitrate = self->_encoder.bitspersecond;
                [self->_rtsp onVideoData:data time:pts];
            }
            return 0;
        } onParams:^int(NSData *data) {
            self->_rtsp = [RTSPServer setupListener:data];
            return 0;
        }];
    }
}

- (void) encodeFrame:(CMSampleBufferRef)sampleBuffer
{
    [_encoder encodeFrame:sampleBuffer]; //ROB: feed frames like this
}


- (void) shutdown //ROB: Shutdown encoder
{
    NSLog(@"shutting down server");
    if (_rtsp)
    {
        [_rtsp shutdownServer];
    }
    if (_encoder)
    {
        [ _encoder shutdown];
    }
}

- (NSString*) getURL //ROB: getURL
{
    NSString* ipaddr = [RTSPServer getIPAddress];
    NSString* url = [NSString stringWithFormat:@"rtsp://%@/", ipaddr];
    return url;
}


@end
