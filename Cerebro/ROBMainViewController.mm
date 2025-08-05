//
//  GameViewController.m
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "ROBMainViewController.h"
#import "ROBSerialBox.h"
#import "ROBBaseControllerModel.h"
#import "ROBSpeechBox.h"
#import "ROBKeyboardControlsViewController.h"
#import "ROBTorsoControlsViewController.h"
#import "ROBSCNViewController.h"

#import "ROBNiTEManager.h"
#import "ROBConsciousness.h"
//#import "ROBLeap.h"
#import "SimpleUserTrackerTaskController.h"
#import "ReSpeakerTaskController.h"
#import "RealSenseTaskController.h"
#import "AudioInputTaskController.h"
#import "JoinWifiTaskController.h"

#import <Vision/Vision.h>


#define kMaxFollowingSpeed 50
#define kMAXFOLLOWDISTANCE 1100
#define kTrackingMidpointX -200
#define kTrackingMidpointY 200

#import "AVFoundation/AVFoundation.h"
#import "Cerebro-Swift.h"

@interface ROBMainViewController () <HumanTrackingDelegate, TrackingDelegate, AutoNetServerDataDelegate, NSTextViewDelegate>

//--- Head , Torso, Base SerialBox bindings

@property (readwrite, retain) IBOutlet NSTextView *serialOutputArea_head;
@property (readwrite, retain) IBOutlet NSTextField *serialInputField_head;
@property (readwrite, retain) IBOutlet NSTextView *serialOutputArea_torso;
@property (readwrite, retain) IBOutlet NSTextField *serialInputField_torso;
@property (readwrite, retain) IBOutlet NSTextView *serialOutputArea_base;
@property (readwrite, retain) IBOutlet NSTextField *serialInputField_base;
@property (readwrite, retain) IBOutlet NSTextView *serialOutputArea_maestro;
@property (readwrite, retain) IBOutlet NSTextField *serialInputField_maestro;

@property (readwrite, retain) IBOutlet NSPopUpButton *serialListPullDown_head;
@property (readwrite, retain) IBOutlet NSPopUpButton *serialListPullDown_torso;
@property (readwrite, retain) IBOutlet NSPopUpButton *serialListPullDown_base;
@property (readwrite, retain) IBOutlet NSPopUpButton *serialListPullDown_maestro;
//-----

@property (readwrite, retain) ROBSCNViewController *scnViewController;
@property (readwrite, retain) NSTimer *niteHeartbeatTimer;

//@property (readwrite, retain) ROBLeap *robLeap;
@property (readwrite, retain) IBOutlet SCNView *robo_scnView;
@property (readwrite, retain) NSWindowController *controlsWindowController;
@property (readwrite, retain) NSWindowController *torsoControlsWindowController;
@property (readwrite, retain) ROBTorsoControlsViewController *torsoControlsViewController;

@property (readwrite, retain) NSWindowController *cameraWindowController;
@property (readwrite, retain) ROBTorsoControlsViewController *cameraViewController;

@property (readwrite, retain) NSWindowController *tastsWindowController;
@property (readwrite, retain) NSTimer *speechResponseAttentionTimer;

- (IBAction)sendText_head:(id)sender;
- (IBAction)sendText_torso:(id)sender;
- (IBAction)sendText_base:(id)sender;
- (IBAction)LACT_exitSafeStart:(id)sender;
- (IBAction)serialPortSelected_head: (id) cntrl;
- (IBAction)serialPortSelected_torso: (id) cntrl;
- (IBAction)serialPortSelected_base: (id) cntrl;
- (IBAction)serialPortSelected_maestro: (id) cntrl;


@property (readwrite, retain) AutoNetServer *autoNetServer;
@property (readwrite, retain) ROBAI *robAI;

@property (readwrite, retain) SimpleUserTrackerTaskController *simpleUserTrackerTaskController;
@property (readwrite, retain) ReSpeakerTaskController *reSpeakerTaskController;
@property (readwrite, retain) RealSenseTaskController *realSenseTaskController;
@property (readwrite, retain) AudioInputTaskController *audioInputTaskController;
@property (readwrite, retain) JoinWifiTaskController *joinWifiTaskController;

@property (readwrite, retain) IBOutlet NSTextView *simpleUserTrackerTaskTextView;
@property (readwrite, retain) IBOutlet NSTextView *reSpeakerTaskTextView;
@property (readwrite, retain) IBOutlet NSTextView *realSense_t265_TaskTextView;

@property (readwrite, assign) bool followingMode;
@property (readwrite, assign) bool ignoreText;
@property (readwrite, assign) int currentPersonTrackingID;
@property (readwrite, assign) int followingSpeed;

@property (readwrite, assign) float currentPerson_positionX;
@property (readwrite, assign) float currentPerson_positionY;
@property (readwrite, assign) float currentPerson_positionZ;
@property (readwrite, assign) float currentPerson_pan;
@property (readwrite, assign) float currentPerson_tilt;

@property (readwrite, assign) int actualValue;
@property (readwrite, assign) int targetValue;
@property (readwrite, retain) NSString *inputLanguage;
@property (readwrite, retain) NSString *outputLanguage;

@property (readwrite, assign) int pulse_count;
@property (readwrite, assign) bool NiTE_IS_ON;

@end

@implementation ROBMainViewController

- (void) didRespond: (NSString *) responseText {
    [self.speechBox sayIt:responseText];
}

- (void) inputText:(NSString *)textInput
{
    textInput = [textInput lowercaseString];
    //@[@"robbie", @"robot", @"hey robbie", @"hey robot", @"rob",  @"robbie one"]
    if ([textInput containsString:@"robbie"] || [textInput containsString:@"hey rob"] || [textInput containsString:@"rob"] || [textInput containsString:@"robot"])
    {
        //The following code does not work.. perhaps another idea would be ideal
        //operhaps heyrob will activate his attention and that allows us to not ignore text for a few minutes
//        [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL URLWithString:@"/System/Applications/Siri.app"] configuration:[[NSWorkspaceOpenConfiguration alloc] init] completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {
//            NSLog(@"didOpenSiri");
//        }];
        self.ignoreText = false;
        NSLog(@"Listening for spoken input");
        if (self.speechResponseAttentionTimer) {
            [self.speechResponseAttentionTimer invalidate];
        }
        self.speechResponseAttentionTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:NO block:^(NSTimer * _Nonnull timer) {
            NSLog(@"Ignoring spoken input");
            self.ignoreText = true;
        }];
        
        NSArray *acknowledgements = @[@"yes", @"go ahead", @"i'm listening", @"can I help you?"];
        NSString *acknowledgement = [acknowledgements objectAtIndex:arc4random_uniform(acknowledgements.count)];
        
        [self.speechBox sayIt:acknowledgement];
        return;
    }
    if ([textInput containsString:@"stop"] || [textInput containsString:@"wait"] || [textInput containsString:@"don't move"] || [textInput containsString:@"do not move"])
    {
        self.currentPersonTrackingID = -1;
        self.followingMode = false;
        [self.speechBox sayIt:[NSString stringWithFormat:@"stopping"]];

    }
    if ([textInput containsString:@"follow"])
    {
        //Enter follow mode to track person
        self.followingMode = true;
        [self.speechBox sayIt:[NSString stringWithFormat:@"Following person %i", self.currentPersonTrackingID]];

    }
    if (!self.ignoreText) {
        //Send to the new foundation models
        //[self.audioInputTaskController queryTextInput: textInput]; //SENDS TEXT TO GOOGLE GEMINI THROUGH PYTHON
        //[self.speechBox inputText:textInput]; //CakeChat input was here
        NSLog(@"textInput = %@", textInput);
        [self.robAI handleInput:textInput completion:^(NSString * _Nonnull response) {
            //NSLog(@"response = %@", response);
            [self.speechBox sayIt:response];
        }];
    }
    
    self.audioInputTaskController.textView.string = [self.audioInputTaskController.textView.string stringByAppendingString:[NSString stringWithFormat:@"\n%@\n",textInput]];
}

- (void) makeTextViewFirstResponder:(NSTextView *)textView {
    [[[self tastsWindowController] window] makeFirstResponder:textView];
    //[textView didChangeText];
}

- (void) clearInputTextMessage
{
    [self.autoNetServer sendString:@"Clear input text message"];
}


- (void)viewDidLoad
{
    [super viewDidLoad];
    //-----------------------------
    //---- Setup User Defaults ----
    if (![[NSUserDefaults standardUserDefaults] valueForKey:@"inputLanguage"])
    {
        [[NSUserDefaults standardUserDefaults] setValue:@"en-US" forKey:@"inputLanguage"];
    }
    if (![[NSUserDefaults standardUserDefaults] valueForKey:@"outputLanguage"])
    {
        [[NSUserDefaults standardUserDefaults] setValue:@"en-US" forKey:@"outputLanguage"];
    }
    //-----------------------------
    self.NiTE_IS_ON = false;
    self.actualValue = 0.0;
    self.targetValue = 0.0;
    self.inputLanguage = [[NSUserDefaults standardUserDefaults] valueForKey:@"inputLanguage"];
    self.followingMode = false;
    self.followingSpeed = 0;
    self.currentPersonTrackingID = 1;
    self.ignoreText = true;
    //-----
    //Initialize AutoNet
    self.autoNetServer = [[AutoNetServer alloc] initWithService:@"_roboNet._tcp" port:12345 dataDelegate:self];
    NSError *error = nil;
    [self.autoNetServer startAndReturnError:&error];
    if (error != nil) {
        NSLog(@"AutoNetServer Error, %@", [error localizedDescription]);
    }
    //-----
    //Leap controller always bugs out and isn't reliable... need to keep leap on the laptop for input instead23
    //self.robLeap = [ROBLeap new];
    //self.robLeap.delegate = self;
    //[self.robLeap run];
//
    //Initilze R.O.B.
    self.robAI = [[ROBAI alloc] init];
    
    self.serialBox = [ROBSerialBox new];
    self.serialBox.serialListPullDown_head = self.serialListPullDown_head;
    self.serialBox.serialListPullDown_torso = self.serialListPullDown_torso;
    self.serialBox.serialListPullDown_base = self.serialListPullDown_base;
    self.serialBox.serialListPullDown_maestro = self.serialListPullDown_maestro;
    
    self.serialBox.serialOutputArea_head = self.serialOutputArea_head;
    self.serialBox.serialOutputArea_torso = self.serialOutputArea_torso;
    self.serialBox.serialOutputArea_base = self.serialOutputArea_base;
    self.serialBox.serialOutputArea_maestro = self.serialOutputArea_maestro;
    
    self.serialBox.serialInputField_head = self.serialInputField_head;
    self.serialBox.serialInputField_torso = self.serialInputField_torso;
    self.serialBox.serialInputField_base = self.serialInputField_base;
    self.serialBox.serialInputField_maestro = self.serialInputField_maestro;
    
    self.serialBox.delegate = self;
    [self.serialBox initialize_connection];
    
    //---------------------------------------------------------
    //Enable one of these to auto allow a controller to take over... otherwise a controller is required to intiate robot control!
    //Autonomous Algorithms
    //self.serialBox.masterControllerID = @"Autonomous";
    //VRController
    self.serialBox.masterControllerID = @"Brain";
    //---------------------------------------------------------
    
    self.speechBox = [ROBSpeechBox new];
    self.speechBox.delegate = self;
    self.outputLanguage = [[NSUserDefaults standardUserDefaults] valueForKey:@"outputLanguage"];
    [self.speechBox setOutputLanguage:self.outputLanguage];    
    
    [self showROBControls];
    [self showROB_Torso_Controls];
    [self showROBNavigation];
    [self showROB_Camera_View];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        [[self.tastsWindowController window] makeKeyAndOrderFront:nil];
    });
}


- (void) startListeningAgain
{
    self.ignoreText = NO;
}


- (void) beginToIgnore
{
    self.ignoreText = YES;
}

- (void) didSeeNewPerson:(NSString *)userID
{
    [self.speechBox didSeeNewPerson:userID];
    if (self.followingMode)
    {
        self.currentPersonTrackingID = [userID intValue];
    }
}


- (void) lostSightOfPerson:(NSString*)userID
{
    [self.speechBox lostSightOfPerson:userID];
    
}


- (void) leashHandPosition:(SCNVector3)position
{
    
    
    //float xOffset_L = 0;//(position.x > 0) ? 1.0 : -1.0;
    //float xOffset_R = 0;//(position.x > 0) ? -1.0 : 1.0;
    [self animateToValue];
    //[self.serialBox controllerPassthrough:CGPointMake(self.actualValue, xOffset_L) touchPadPointR:CGPointMake(self.actualValue, xOffset_R) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:100 speed_playPause:false speed_forward_reverse:false textInput:@""];

}

- (void) animateToValue
{
    if (self.actualValue < self.targetValue)
    {
        self.actualValue += 0.1;
    }
    if (self.actualValue > self.targetValue)
    {
        self.actualValue -= 0.1;
    }
}


- (void) trackingPerson:(NSString *)userID position:(NSString *)position
{
    NSArray *positionComponents = [position componentsSeparatedByString:@","];
    float x = [positionComponents[0] floatValue];
    float y = [positionComponents[1] floatValue];
    float z = [positionComponents[2] floatValue];
    
    [self trackingPerson:userID x:x y:y z:z];
}


- (void) trackingPerson:(NSString *)userID x:(float)x y:(float)y z:(float)z
{
    //if (self.currentPersonTrackingID == [userID intValue])
    {
        self.currentPerson_positionX = x;
        self.currentPerson_positionY = y;
        self.currentPerson_positionZ = z;
        
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            
            if (x > 0.55)
                self.currentPerson_pan = self.currentPerson_pan - (1000 * (x-0.55));
            if (x < 0.45)
                self.currentPerson_pan = self.currentPerson_pan + (1000 * (0.45-x));
            if (y > 0.55)
                self.currentPerson_tilt = self.currentPerson_tilt - (500 * (y-0.55));
            if (y < 0.45)
                self.currentPerson_tilt = self.currentPerson_tilt + (500 * (0.45-y));
            
            [[self.torsoControlsViewController headPan] setFloatValue:self.currentPerson_pan];
            [[self.torsoControlsViewController headTilt] setFloatValue:self.currentPerson_tilt];
            
            //[[self.torsoControlsViewController headPan] setFloatValue:5900 + (x*200)]; // SimpleUserTracker Values
            //[[self.torsoControlsViewController headTilt] setFloatValue:5400 - (y*200)]; // SimpleUserTracker Values
        });
    }
    
    if (self.followingMode)
    {
        float xOffset_L = (x > kTrackingMidpointX) ? 0.8 : -0.8;
        float xOffset_R = (x > kTrackingMidpointX) ? -0.8 : 0.8;
        
        float controller_LeftStick_reducer = 0.0;
        float controller_RightStick_reducer = 0.0;
        float controller_zLeftStick = 0.0;
        float controller_zRightStick = 0.0;
        
        
        if (y < kTrackingMidpointY - 50)
        {
            //Head Should Look Down
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, 0.0) touchPadPointR:CGPointMake(0.0, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:true lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (y > kTrackingMidpointY + 50)
        {
            //Head Should Look Up
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, 0.0) touchPadPointR:CGPointMake(0.0, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:true lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (x > kTrackingMidpointX + 50)
        {
            controller_LeftStick_reducer = 0.0;
            controller_RightStick_reducer = xOffset_R;
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, xOffset_L) touchPadPointR:CGPointMake(0.0, xOffset_R) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (x < kTrackingMidpointX - 50)
        {
            controller_LeftStick_reducer = xOffset_L;
            controller_RightStick_reducer = 0.0;
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.0, xOffset_L) touchPadPointR:CGPointMake(0.0, xOffset_R) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (z > kMAXFOLLOWDISTANCE)
        {
            //Send forward commands
            controller_zLeftStick = 0.5;
            controller_zRightStick = 0.5;
            
            //[self.serialBox controllerPassthrough:CGPointMake(0.5, 0.0) touchPadPointR:CGPointMake(0.5, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:[self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        else if (z < kMAXFOLLOWDISTANCE - 25)
        {
            //Send backward commands
            controller_zLeftStick = -0.5;
            controller_zRightStick = -0.5;
            
            //[self.serialBox controllerPassthrough:CGPointMake(-0.5, 0.0) touchPadPointR:CGPointMake(-0.5, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed: [self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        }
        
        
        
        
        //Send backwards commandss
        ROBBaseControllerModel *controllerModelData = [ROBBaseControllerModel new];
        controllerModelData.touchPadPointL = CGPointMake(controller_zLeftStick, controller_LeftStick_reducer);
        controllerModelData.touchPadPointR = CGPointMake(controller_zRightStick, controller_RightStick_reducer);
        controllerModelData.Lat = 0;
        controllerModelData.Long = 0;
        controllerModelData.tredBrakeLock = false;
        controllerModelData.flipperForwardIsDown = false;
        controllerModelData.flipperRelaxBrake = false;
        controllerModelData.flipperBackwardIsDown = false;
        controllerModelData.flipperBrakeLock = false;
        controllerModelData.lact1 = true;
        controllerModelData.lact2 = false;
        controllerModelData.lact3 = false;
        controllerModelData.speed = kMaxFollowingSpeed;
        controllerModelData.speed_playPause = false;
        controllerModelData.speed_forward_reverse = false;
        controllerModelData.textInput = @"";
        
        [self.serialBox controllerId:@"Autonomous" controllerModelData:controllerModelData];
        //[self.serialBox controllerPassthrough:CGPointMake(-0.5, 0.0) touchPadPointR:CGPointMake(-0.5, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed: [self getFollowingSpeed] speed_playPause:false speed_forward_reverse:false textInput:@""];
        //user1 = 517.31, 174.51, 1825.00
    }
}

- (IBAction)reconnectMaestroLink:(id)sender
{
    [self.serialBox maestro_getErrors_command];
    [self.serialBox connectMaestro];
}

#pragma mark - HumanTrackingDelegate

- (void) heartbeat_NiTE
{
    //NSLog(@"pulse");
    //[self.niteHeartbeatTimer invalidate];
    //[self startHeartbeatNiTE_ResetTimer];
    self.pulse_count++;
}


- (void) startHeartbeatNiTE_ResetTimer
{
//    __weak ROBMainViewController * weakSelf = self;
//    
//    self.niteHeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:6 repeats:YES block:^(NSTimer * _Nonnull timer) {
//        NSLog(@"validating %i", self.pulse_count);
//        if (self.pulse_count == 0) //At least 1 pulse in every 5 seconds to check or we reboot vision system
//        {
//            self.pulse_count = 1;
//            self.currentPerson_pan = 5900;
//            self.currentPerson_tilt = 5593;
//            
//            NSLog(@"***** Resetting NiTECamera Capture *****");
//            dispatch_async(dispatch_get_main_queue(), ^{
//                //[self.niteManager shutdownNiTEManager];
//                self.NiTE_IS_ON = false;
//            });
//            
//            //__strong ROBMainViewController * strongSelf = weakSelf;
//            
//            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//                //[self createAndInitializeNiteManager];
//            });
//        }
//        self.pulse_count = 0;
//    }];
}

- (void) didTrackHumans:(NSArray *)humanObservations
{
    for (VNDetectedObjectObservation *observation in humanObservations)
    {
        //NSLog(@"human = (%f, %f) --- %@", observation.boundingBox.origin.x, observation.boundingBox.origin.y, observation.uuid.UUIDString);
            //NSAppleScript *script = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"say %@\"", @"howdy"]];
            //[script executeAndReturnError:nil];
        CGRect boundingBox = observation.boundingBox;
        CGFloat midx = CGRectGetMidX(boundingBox);
        CGFloat midy = CGRectGetMidY(boundingBox);
        NSLog(@"human = (%f, %f) --- %@", midx, midy, observation.uuid.UUIDString);
        //if (trackingMode)
        [self trackingPerson:@"person1" x:midx y:midy z:1];
        break;
    }
}

#pragma mark - AudioInputMethods - NSTextViewDelegate

- (IBAction)resetTranscript:(id)sender
{
    //NSLog(@"%@", self.audioInputTaskController);
    
    [self.audioInputTaskController resetTranscript];
    
}

- (void)textDidChange:(NSNotification *)notification {
    NSTextView *textView = [notification object];
    NSLog(@"text = %@", textView.string);
    
    [self.audioInputTaskController queryTextInput: textView.string];
}

#pragma mark -


- (void) setVolume:(int)volume
{
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"set volume output volume %i --100%", volume]];
    [script executeAndReturnError:nil];
}


- (void) setROBInputLanguage:(NSString *)language
{
    if (self.inputLanguage != language)
    {
        [[NSUserDefaults standardUserDefaults] setValue:language forKey:@"inputLanguage"];
        self.inputLanguage = language;
        //[self.audioInputTaskController startTask:self withLanguage:language];
    }
}


- (void) setROBOutputLanguage:(NSString *)language
{
    if (self.outputLanguage != language)
    {
        [[NSUserDefaults standardUserDefaults] setValue:language forKey:@"outputLanguage"];
        self.outputLanguage = language;
        [self.speechBox setOutputLanguage:language];
    }
}


- (IBAction) maestro_getErrors_command:(id)sender
{
    [self.serialBox maestro_getErrors_command];
}


- (void) joinWifi:(NSString *)wifiCredentials
{
    // Using airport private framework app
    // @"/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport -s -x"
    
    // List all Networks
    // @"/usr/sbin/networksetup -listnetworkserviceorder"
    
    // Join Network Example
    // @"/usr/sbin/networksetup -setairportnetwork en0 Internet"
    
    // Working join wifi network command
    //@"/usr/sbin/networksetup -setairportnetwork en1 ATT9m78y5D 24+h592n4?x2"
    //@"/usr/sbin/networksetup -setairportnetwork en4 "SUPA ROBONET" 7!G3R&@7M"
    
    NSArray *wifiElements = [wifiCredentials componentsSeparatedByString:@":"];
    
    NSString *ssid = wifiElements[0];
    NSString *password = wifiElements[1];
    
    NSString *joining_wifiString = [NSString stringWithFormat:@"Joining %@", ssid];
    [self.speechBox sayIt:joining_wifiString];
    
    self.joinWifiTaskController = [JoinWifiTaskController new];
    self.joinWifiTaskController.delegate = self;
    [self.joinWifiTaskController startTask:self withDevice:@"en1" ssid:ssid password:password];
}

- (IBAction) joinSupaRobonet_WIFI:(id)sender
{
     //@"/usr/sbin/networksetup -setairportnetwork en4 "SUPA ROBONET" 7!G3R&@7M"
    self.joinWifiTaskController = [JoinWifiTaskController new];
    self.joinWifiTaskController.delegate = self;
    [self.joinWifiTaskController startTask:self withDevice:@"en1" ssid:@"SUPA ROBONET" password:@"7!G3R&@7M"];
}


- (IBAction) joinATT9m78y5D:(id)sender
{
    //@"/usr/sbin/networksetup -setairportnetwork en4 "SUPA ROBONET" 7!G3R&@7M"
    self.joinWifiTaskController = [JoinWifiTaskController new];
    self.joinWifiTaskController.delegate = self;
    [self.joinWifiTaskController startTask:self withDevice:@"en1" ssid:@"ATT9m78y5D" password:@"24+h592n4?x2"];
}

- (void) didReceiveData:(NSData *)data {
    NSError *error = nil;
    NSSet *classSet = [NSSet setWithObjects:[NSDictionary class], [NSString class], [NSData class], nil];
    NSDictionary *messageDictionary = (NSDictionary*) [NSKeyedUnarchiver unarchivedObjectOfClasses:classSet
                                                                                          fromData:data error:&error];
    NSString *msg = [messageDictionary valueForKey:@"message"];
    NSString *sender = [messageDictionary valueForKey:@"sender"];

    //NSLog(@"sender = %@. message = %@", sender, msg);

    if (error != nil) {
        NSLog(@"Error data recieved: %@", [error localizedDescription]);
    }
    
    if ([msg hasPrefix:@"JoinWifi:"])
    {
        NSString *wifiCredentials = [msg stringByReplacingOccurrencesOfString:@"JoinWifi:" withString:@""];
        [self joinWifi:wifiCredentials];
        return;
    }
    
    if ([msg hasPrefix:@"SetInputLanguage:"])
    {
        NSString *language = [msg stringByReplacingOccurrencesOfString:@"SetInputLanguage:" withString:@""];
        [self setROBInputLanguage:language];
        return;
    }
    if ([msg hasPrefix:@"SetOutputLanguage:"])
    {
        NSString *language = [msg stringByReplacingOccurrencesOfString:@"SetOutputLanguage:" withString:@""];
        [self setROBOutputLanguage:language];
        return;
    }
    if ([msg hasPrefix:@"SetVolume:"])
    {
        NSString *volume = [msg stringByReplacingOccurrencesOfString:@"SetVolume:" withString:@""];
        [self setVolume:volume.intValue];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Anger"])
    {
        [self.speechBox switchMood_anger];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Joy"])
    {
        [self.speechBox switchMood_joy];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Neutral"])
    {
        [self.speechBox switchMood_neutral];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Sadness"])
    {
        [self.speechBox switchMood_sadness];
        return;
    }
    if ([msg hasPrefix:@"SwitchMood_Fear"])
    {
        [self.speechBox switchMood_fear];
        return;
    }
    
    if ([msg isEqualToString:@"PermitAutonomousMasterController"])
    {
        [self.serialBox setMasterControllerID:@"Autonomous"];
        return;
    }
    if ([msg isEqualToString:@"RequestToBeMasterController"])
    {
        [self.serialBox setMasterControllerID:sender];
        return;
    }
    
    if ([sender isEqualToString:@"rpLidar"]){
        return;
    }
    /*
    0.32,-0.90,-0.28,                   Matrix row 1
    0.94,0.27,0.21,                     Matrix row 2
    -0.11,-0.33,0.94,                   Matrix row 3
    yaw=-1.292633
    pitch=0.211758
    roll=0.292573
    touchPad - -1.000000,-1.000000
    (Lat,Long):30.646698:-96.321426
    tredBrakeLock=0
    flipper=0,0,0,0
    lact=0,0,0
    speed=50.000000,play=0,forward-reverse=1
    TEXT=Testing testing 123
    */
    
    NSArray *command_components = [msg componentsSeparatedByString:@"\n"];
    
    if (command_components.count == 14)
    {
        
        NSArray *matrixRow1_array = [command_components[0] componentsSeparatedByString:@","];
        NSArray *matrixRow2_array = [command_components[1] componentsSeparatedByString:@","];
        NSArray *matrixRow3_array = [command_components[2] componentsSeparatedByString:@","];
        float m11 = [matrixRow1_array[0] floatValue];
        float m12 = [matrixRow1_array[1] floatValue];
        float m13 = [matrixRow1_array[2] floatValue];
        
        float m21 = [matrixRow2_array[0] floatValue];
        float m22 = [matrixRow2_array[1] floatValue];
        float m23 = [matrixRow2_array[2] floatValue];
        
        float m31 = [matrixRow3_array[0] floatValue];
        float m32 = [matrixRow3_array[1] floatValue];
        float m33 = [matrixRow3_array[2] floatValue];
        
        float yaw = [[command_components[3] componentsSeparatedByString:@"yaw="][1] floatValue];
        float pitch = [[command_components[4] componentsSeparatedByString:@"pitch="][1] floatValue];
        float roll = [[command_components[5] componentsSeparatedByString:@"roll="][1] floatValue];
        
        //NSLog(@"yaw = %f, pitch = %f, roll = %f", yaw, pitch, roll);
        

        NSArray *touchPadL_array = [[command_components[6] componentsSeparatedByString:@"touchPadL - "][1] componentsSeparatedByString:@","];
        CGPoint touchPadPointL = CGPointMake([touchPadL_array[0] floatValue], [touchPadL_array[1] floatValue]);

        NSArray *touchPadR_array = [[command_components[7] componentsSeparatedByString:@"touchPadR - "][1] componentsSeparatedByString:@","];
        CGPoint touchPadPointR = CGPointMake([touchPadR_array[0] floatValue], [touchPadR_array[1] floatValue]);

        
        
        NSArray *geoPosition_array = [command_components[8] componentsSeparatedByString:@":"];
        float Lat = [geoPosition_array[0] floatValue];
        float Long = [geoPosition_array[1] floatValue];
        
        bool tredBrakeLock = [[command_components[9] componentsSeparatedByString:@"tredBrakeLock="][1] boolValue];
        NSArray *flipper1_array = [[command_components[10] componentsSeparatedByString:@"flipper="][1] componentsSeparatedByString:@","];
        
        bool flipperForwardIsDown = [flipper1_array[0] boolValue];
        bool flipperRelaxBrake = [flipper1_array[1] boolValue];
        bool flipperBackwardIsDown = [flipper1_array[2] boolValue];
        
        bool flipperBrakeLock = [flipper1_array[3] boolValue];
        
        
        NSArray *lact_array = [[command_components[11] componentsSeparatedByString:@"lact="][1] componentsSeparatedByString:@","];
        
        bool lact1 = [lact_array[0] boolValue];
        bool lact2 = [lact_array[1] boolValue];
        bool lact3 = [lact_array[2] boolValue];
        
        NSArray *speed_array = [[command_components[12] componentsSeparatedByString:@"speed="][1] componentsSeparatedByString:@","];

        float speed = [speed_array[0] floatValue];
        bool speed_playPause = [[speed_array[1] componentsSeparatedByString:@"play="][1]  boolValue];
        bool speed_forward_reverse = [[speed_array[2] componentsSeparatedByString:@"forward-reverse="][1] boolValue] ;
        
        NSString *textInput = [command_components[13] componentsSeparatedByString:@"TEXT="][1];
        //NSLog(@"textInput = %@", textInput);
        //self.serialBox.currentIncommingVerbalMessage = textInput;
        
        ROBBaseControllerModel *controllerModelData = [ROBBaseControllerModel new];
        controllerModelData.touchPadPointL = touchPadPointL;
        controllerModelData.touchPadPointR = touchPadPointR;
        controllerModelData.Lat = Lat;
        controllerModelData.Long = Long;
        controllerModelData.tredBrakeLock = tredBrakeLock;
        controllerModelData.flipperForwardIsDown = flipperForwardIsDown;
        controllerModelData.flipperRelaxBrake = flipperRelaxBrake;
        controllerModelData.flipperBackwardIsDown = flipperBackwardIsDown;
        controllerModelData.flipperBrakeLock = flipperBrakeLock;
        controllerModelData.lact1 = lact1;
        controllerModelData.lact2 = lact2;
        controllerModelData.lact3 = lact3;
        controllerModelData.speed = speed;
        controllerModelData.speed_playPause = speed_playPause;
        controllerModelData.speed_forward_reverse = speed_forward_reverse;
        controllerModelData.textInput = textInput;
        
        [self.serialBox controllerId:sender controllerModelData:controllerModelData];
        
        NSDictionary *messageDict = @{@"message": @"Hey I got your message",
                                      @"sender":[[NSHost currentHost] name]};
        NSError *error = nil;
        [self.autoNetServer sendMessage:[NSKeyedArchiver archivedDataWithRootObject:messageDict requiringSecureCoding:false error:&error]]; //ACK acknowledge receipt to controller
    }
    else
    {
        NSLog(@"COMMAND PARSER ERROR!!!" );
    }
}

#pragma mark -

- (void) showROBNavigation
{
    
}

- (void) showROB_Camera_View
{
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil]; // get a reference to the storyboard
    self.cameraWindowController = [storyBoard instantiateControllerWithIdentifier:@"CameraWindowController"]; // instantiate your window controller
    [self.cameraWindowController showWindow:self]; // show the window}
    self.cameraViewController = (ROBTorsoControlsViewController *)self.torsoControlsWindowController.contentViewController;
    //[self.cameraViewController setRobMainViewController:self];
}

- (void) showROB_Torso_Controls
{
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil]; // get a reference to the storyboard
    self.torsoControlsWindowController = [storyBoard instantiateControllerWithIdentifier:@"TorsoControlsWindowController"]; // instantiate your window controller
    [self.torsoControlsWindowController showWindow:self]; // show the window}
    self.torsoControlsViewController = (ROBTorsoControlsViewController *)self.torsoControlsWindowController.contentViewController;
    [self.torsoControlsViewController setRobMainViewController:self];
}


- (void) showROBControls
{
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil]; // get a reference to the storyboard
    self.controlsWindowController = [storyBoard instantiateControllerWithIdentifier:@"ControlsWindowController"]; // instantiate your window controller
    [self.controlsWindowController showWindow:self]; // show the window}
    
    [(ROBKeyboardControlsViewController *)self.controlsWindowController.contentViewController setRobMainViewController:self];
}

- (IBAction)sendText_head:(id)sender
{
    [self.serialBox sendHeadCommand:[self.serialInputField_head stringValue]];
}


- (IBAction)sendText_torso:(id)sender
{
    [self.serialBox sendTorsoCommand:[self.serialInputField_torso stringValue]];
}


- (IBAction)sendText_base:(id)sender
{
    [self.serialBox sendBaseCommand:[self.serialInputField_base stringValue]];
}

- (IBAction)sendText_maestro:(id)sender
{
    [self.serialBox sendMaestroCommand:[self.serialInputField_maestro stringValue]];
}


- (IBAction)serialPortSelected_head: (id) cntrl
{
    [self.serialBox serialPortSelected_head];
}


- (IBAction)serialPortSelected_torso: (id) cntrl
{
    [self.serialBox serialPortSelected_torso];
}


- (IBAction)serialPortSelected_base: (id) cntrl
{
    [self.serialBox serialPortSelected_base];
}


- (IBAction)serialPortSelected_maestro: (id) cntrl
{
    [self.serialBox serialPortSelected_maestro];
}


- (void) shutdownAudioInput
{
    //[self.audioInputTaskController beginToIgnore];
}

- (void) willStartProcessingSpeech
{
    //[self.audioInputTaskController beginToIgnore];
}

- (void) didFinishProcessingSpeech
{
    //[self.audioInputTaskController startTask:self];
    //[self.audioInputTaskController startListeningAgain];
    
    //self.speechTextView.editable = YES;
    //[[[self tastsWindowController] window] makeFirstResponder:self.speechTextView];
    //[self.speechTextView becomeFirstResponder];

}


- (void) didOutputSerialResponse_Head:(NSString *)response
{
    //NSLog(@"HEAD: %@", response);
    if ([response containsString:@"MOTION DETECTED"] && !self.audioInputTaskController.isListening)
    {
        //THis will say 1000 times endlessly... need to say it once only when timer is bored
        //[self.speechBox sayIt:@"Hey"];
        //[self.audioInputTaskController startTask:self withLanguage:self.inputLanguage];
    }
}


- (void) didOutputSerialResponse_Torso:(NSString *)response
{
    //NSLog(@"TORSO: %@", response);
}


- (void) didOutputSerialResponse_Base:(NSString *)response
{
    //NSLog(@"BASE: %@", response);
}


- (void) didOutputSerialResponse_Maestro:(NSString *)response
{
    //NSLog(@"MAESTRO: %@", response);
}


- (IBAction)LACT_exitSafeStart:(id)sender
{
    [self.serialBox LACT_exitSafeStart];
}


- (IBAction)showControls:(id)sender
{
    NSLog(@"show controls");
}


- (IBAction)showSerialDebug:(id)sender
{
    NSLog(@"show serial debug");
}


- (IBAction)showMainNavigation:(id)sender
{
    NSLog(@"show main navigation");
}

@end

