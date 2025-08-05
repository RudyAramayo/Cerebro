//
//  ROBNiTEManager.m
//  Cerebro
//
//  Created by Rob Makina on 1/12/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//
#include "NiTE.h"

#import "ROBNiTEManager.h"
//#import "FreenectPCL.h"


/*
#define MAX_USERS 10
bool g_visibleUsers[MAX_USERS] = {false};
nite::SkeletonState g_skeletonStates[MAX_USERS] = {nite::SKELETON_NONE};


#define USER_MESSAGE(msg) \
{printf("[%08llu] User #%d:\t%s\n",ts, user.getId(),msg);}

void updateUserState(const nite::UserData& user, unsigned long long ts)
{
    if (user.isNew())
        USER_MESSAGE("New")
        else if (user.isVisible() && !g_visibleUsers[user.getId()])
            USER_MESSAGE("Visible")
            else if (!user.isVisible() && g_visibleUsers[user.getId()])
                USER_MESSAGE("Out of Scene")
                else if (user.isLost())
                    USER_MESSAGE("Lost")
                    
                    g_visibleUsers[user.getId()] = user.isVisible();
    
    
    if(g_skeletonStates[user.getId()] != user.getSkeleton().getState())
    {
        switch(g_skeletonStates[user.getId()] = user.getSkeleton().getState())
        {
            case nite::SKELETON_NONE:
                USER_MESSAGE("Stopped tracking.")
                break;
            case nite::SKELETON_CALIBRATING:
                USER_MESSAGE("Calibrating...")
                break;
            case nite::SKELETON_TRACKED:
                USER_MESSAGE("Tracking!")
                break;
            case nite::SKELETON_CALIBRATION_ERROR_NOT_IN_POSE:
            case nite::SKELETON_CALIBRATION_ERROR_HANDS:
            case nite::SKELETON_CALIBRATION_ERROR_LEGS:
            case nite::SKELETON_CALIBRATION_ERROR_HEAD:
            case nite::SKELETON_CALIBRATION_ERROR_TORSO:
                USER_MESSAGE("Calibration Failed... :-|")
                break;
        }
    }
}
*/

@interface ROBNiTEManager ()
{
    //FreenectPCL *_freenectPCLServer;
    
}
@property (readwrite, retain) NSTask *task;
@property (readwrite, retain) NSPipe *pipe;
@end

@implementation ROBNiTEManager


- (void) initializeNiTEOther
{
    
    //******
    //IN THE END>... GET THE NSTASK TO LAUNCH SOME OTHER STUFF FOR ME!!!!!
    //AND TAP THE CONSOLE FOR LOCATION OF USERS AND SUCH....
    
    //edit: don't forget the s.ini file for hand data that needs to be in the executable path!!!
    //******
    [self initializeNiTEManager];
    
    /*
    nite::UserTracker userTracker;
    nite::Status niteRc;
    
    nite::NiTE::initialize();
    
    openni::Device  devDevice;
    if( devDevice.open( openni::ANY_DEVICE ) != openni::STATUS_OK )
    {
        NSLog(@"Can't Open Device: \n");
    }
    

    
    niteRc = userTracker.create(&devDevice);
    if (niteRc != nite::STATUS_OK)
    {
        printf("Couldn't create user tracker\n");
    }
    printf("\nStart moving around to get detected...\n(PSI pose may be required for skeleton calibration, depending on the configuration)\n");
    
    nite::UserTrackerFrameRef userTrackerFrame;
    */
    return;
    
    
    
    
    
    //int pid = [[NSProcessInfo processInfo] processIdentifier];
    self.pipe = [NSPipe pipe];
    NSFileHandle *file = self.pipe.fileHandleForReading;
    
    self.task = [[NSTask alloc] init];
    self.task.launchPath = @"/libs/NiTE/Samples/Bin/SimpleUserTracker";
    
    /*
    if (![self.previousInputText isEqualToString:@""])
    {
        //[\'anger\', \'joy\', \'neutral\', \'sadness\', \'fear\']'}
        task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-e", @"joy", @"-f", @"localhost", @"-p", @"8001", @"-c", self.previousInputText, @"-c", self.previousInputAnswer, @"-c", inputText];
    }
    else
    {
        task.arguments = @[@"/Users/rob/Desktop/cakechat/tools/test_api.py", @"-f", @"localhost", @"-p", @"8001", @"-c", inputText];
    }
    */
    self.task.standardOutput = self.pipe;
    [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleDataAvailableNotification object:self.pipe.fileHandleForReading queue:nil usingBlock:^(NSNotification *note){
        NSString *outputConsole = [[NSString alloc] initWithData:self.pipe.fileHandleForReading.availableData encoding:NSUTF8StringEncoding];
        NSLog(@"output - %@", outputConsole);
    }];
    
    [file waitForDataInBackgroundAndNotify];
    
    [self.task launch];
    [self.task waitUntilExit];
    
    
    /*
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSData *data = [file availableData];
        NSLog(@"data = %@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        [file closeFile];
    });
    
    */
    
}


- (void) initializeNiTEManager
{
    //_freenectPCLServer = [FreenectPCL new];
    //_freenectPCLServer.renderer = _renderer;
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(void){
        //Background Thread
        //[_freenectPCLServer beginCapture];
    });
}

@end
