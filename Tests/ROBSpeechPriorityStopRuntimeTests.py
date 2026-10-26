#!/usr/bin/env python3
"""Run actual local speech policies/dispatch with stub audio and actuator seams."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
speech = (ROOT / "Cerebro/ROBSpeechBox.m").read_text()
main = (ROOT / "Cerebro/ROBMainViewController.mm").read_text()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


matcher = declaration(speech, "BOOL ROBLocalSpeechContainsPriorityStop(")
speech_methods = "\n".join(declaration(speech, marker) for marker in [
    "- (BOOL)consumeLocalPriorityStop:(NSString *)transcription generation:(NSUInteger)generation\n{",
    "- (void)processLocalRecognitionTranscript:(NSString *)transcription isFinal:(BOOL)isFinal generation:(NSUInteger)generation\n{",
    "- (void)processCapturedMicrophoneBuffer:(AVAudioPCMBuffer *)buffer\n{",
])
stop_method = declaration(main, "- (void)didRecognizeLocalPriorityStop:(NSString *)transcript\n{")
operator_stop_method = declaration(main, "- (void)performOperatorPriorityStopWithReason:(NSString *)reason\n{")
controller_stop_method = declaration(main, "- (void)controllerOperatorPriorityStopRequested:(NSNotification *)notification\n{")
observer_selector = main.index("selector:@selector(controllerOperatorPriorityStopRequested:)", main.index("- (void)viewDidLoad"))
observer_start = main.rindex("    [[NSNotificationCenter defaultCenter] addObserver:self", 0, observer_selector)
observer_registration = main[observer_start:main.index("];", observer_selector) + 2]
priority_method = declaration(main, "- (void)applyPrioritySoftwareStopWithReason:(NSString *)reason\n{")
input_method = declaration(main, "- (void) inputText:(NSString *)textInput\n{")
# Execute the original entry prefix, before its unrelated conversation/UI code.
input_prefix = input_method[:input_method.index("    // Only suppress duplicate local transcript turns")]
input_prefix += "    self.ordinaryInputs += 1;\n}"

fixture = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
__MATCHER__
@interface AVAudioPCMBuffer:NSObject @end
@implementation AVAudioPCMBuffer @end
@protocol ROBSpeechDelegate <NSObject>
- (void)inputText:(NSString *)text;
@optional
- (void)didRecognizeLocalPriorityStop:(NSString *)text;
- (BOOL)acceptLocalMicrophoneAuthorization:(NSString *)text;
- (BOOL)shouldFinalizeLocalMicrophoneAuthorization:(NSString *)text;
- (void)didCaptureAudioBuffer:(AVAudioPCMBuffer *)buffer;
@end
@interface Request:NSObject
@property NSUInteger appended,ended;
- (void)appendAudioPCMBuffer:(AVAudioPCMBuffer *)buffer;
- (void)endAudio;
@end
@implementation Request
- (void)appendAudioPCMBuffer:(AVAudioPCMBuffer *)buffer{self.appended+=1;}
- (void)endAudio{self.ended+=1;}
@end
@interface ROBSpeechBox:NSObject
@property id<ROBSpeechDelegate> delegate;
@property BOOL isSpeaking,isShuttingDown,hologramRecordingOwnsMicrophone,localPriorityStopConsumed,recognitionContainsSpeechOutput;
@property NSUInteger recognitionGeneration,localPriorityStopRecognitionGeneration,acknowledgements,speechCancellations;
@property Request *speechRequest;
@property NSTimer *debounceSpeechInputTimer;
@property NSString *currentTextInput,*lastSpoken;
- (void)processLocalRecognitionTranscript:(NSString *)text isFinal:(BOOL)final generation:(NSUInteger)generation;
- (void)processCapturedMicrophoneBuffer:(AVAudioPCMBuffer *)buffer;
- (void)stopIt:(id)sender;
- (void)sayIt:(NSString *)text;
@end
@implementation ROBSpeechBox
__SPEECH_METHODS__
- (void)stopIt:(id)sender{self.speechCancellations+=1;self.isSpeaking=NO;}
- (void)sayIt:(NSString *)text{self.lastSpoken=text;self.acknowledgements+=1;self.isSpeaking=YES;}
@end
@interface ROBShowMotionCoordinator:NSObject
@property NSUInteger cancellations;
+ (instancetype)shared;
- (void)stop;
@end
@implementation ROBShowMotionCoordinator
+ (instancetype)shared{static id value;return value?: (value=[self new]);}
- (void)stop{self.cancellations+=1;}
@end
@interface ROBArmRoutineCoordinator:NSObject
@property NSUInteger cancellations;
+ (instancetype)shared;
- (void)cancelWithReason:(NSString *)reason;
@end
@implementation ROBArmRoutineCoordinator
+ (instancetype)shared{static id value;return value?: (value=[self new]);}
- (void)cancelWithReason:(NSString *)reason{self.cancellations+=1;}
@end
@interface ROBControllerArmApproval:NSObject
+ (instancetype)shared;
@end
@implementation ROBControllerArmApproval
+ (instancetype)shared{static id value;return value?: (value=[self new]);}
@end
@interface ROBAmberGestureExecutor:NSObject
@property NSUInteger cancellations,globalHolds;
+ (instancetype)shared;
- (NSDictionary *)cancelCurrentGestureWithReason:(NSString *)reason;
- (NSDictionary *)requestPriorityHold;
@end
@implementation ROBAmberGestureExecutor
+ (instancetype)shared{static id value;return value?: (value=[self new]);}
- (NSDictionary *)cancelCurrentGestureWithReason:(NSString *)reason{self.cancellations+=1;return @{};}
- (NSDictionary *)requestPriorityHold{self.globalHolds+=1;return @{@"hold_command_ids":@{@"left":@1,@"right":@2}};}
@end
@interface ROBFaceRecognitionService:NSObject
+ (instancetype)shared;
- (BOOL)noteConversationTranscript:(NSString *)text;
@end
@implementation ROBFaceRecognitionService
+ (instancetype)shared{static id value;return value?: (value=[self new]);}
- (BOOL)noteConversationTranscript:(NSString *)text{return NO;}
@end
@interface AI:NSObject
@property NSUInteger cancellations;
- (void)cancelDualDialogue;
@end
@implementation AI
- (void)cancelDualDialogue{self.cancellations+=1;}
@end
@interface Stage:NSObject
@property BOOL isRunning,active;
@property NSUInteger cancellations;
- (void)cancelWithReason:(NSString *)reason;
- (void)stopWithReason:(NSString *)reason;
@end
@implementation Stage
- (void)cancelWithReason:(NSString *)reason{self.cancellations+=1;self.isRunning=NO;}
- (void)stopWithReason:(NSString *)reason{self.cancellations+=1;self.active=NO;}
@end
@interface Serial:NSObject
@property NSUInteger stops;
- (void)stopBaseMotionAndDropHeartbeat;
- (void)switchToMasterControllerID:(NSString *)identifier;
@end
@implementation Serial
- (void)stopBaseMotionAndDropHeartbeat{self.stops+=1;}
- (void)switchToMasterControllerID:(NSString *)identifier{}
@end
@interface Main:NSObject<ROBSpeechDelegate>
@property AI *robAI;
@property ROBSpeechBox *speechBox;
@property Stage *stageShowCoordinator,*autonomyCoordinator,*followPersonCoordinator;
@property Serial *serialBox;
@property NSInteger currentPersonTrackingID;
@property BOOL followingMode;
@property NSUInteger approvals,cloudBuffers,ordinaryInputs;
- (void)applyPrioritySoftwareStopWithReason:(NSString *)reason;
- (void)performOperatorPriorityStopWithReason:(NSString *)reason;
- (void)controllerOperatorPriorityStopRequested:(NSNotification *)notification;
- (void)installStopObserver;
@end
@implementation Main
__OPERATOR_STOP_METHOD__
__STOP_METHOD__
__CONTROLLER_STOP_METHOD__
- (void)installStopObserver{__OBSERVER_REGISTRATION__}
__PRIORITY_METHOD__
__INPUT_PREFIX__
- (void)publishControlAuthorityState{}
- (BOOL)acceptLocalMicrophoneAuthorization:(NSString *)text{self.approvals+=1;return YES;}
- (BOOL)shouldFinalizeLocalMicrophoneAuthorization:(NSString *)text{return NO;}
- (void)didCaptureAudioBuffer:(AVAudioPCMBuffer *)buffer{self.cloudBuffers+=1;}
@end
int main(void){@autoreleasepool{
 NSUInteger checks=0;
 #define CHECK(c,message) do{NSCAssert((c),message);checks++;}while(0)
 CHECK(ROBLocalSpeechContainsPriorityStop(@"ROB, STOP!"),@"Token Stop missing");
 CHECK(ROBLocalSpeechContainsPriorityStop(@"wait"),@"Wait token missing");
 CHECK(ROBLocalSpeechContainsPriorityStop(@"don't move"),@"Contraction missing");
 CHECK(ROBLocalSpeechContainsPriorityStop(@"Don’t move"),@"Curly contraction missing");
 CHECK(ROBLocalSpeechContainsPriorityStop(@"yes proceed but do not move"),@"Negative clause missing");
 CHECK(!ROBLocalSpeechContainsPriorityStop(@"desktop unstoppable waiting"),@"Substring false Stop");
 CHECK(!ROBLocalSpeechContainsPriorityStop(nil),@"Nil transcript interrupted");
 Main *owner=[Main new];owner.robAI=[AI new];owner.stageShowCoordinator=[Stage new];owner.stageShowCoordinator.isRunning=YES;
 owner.autonomyCoordinator=[Stage new];owner.autonomyCoordinator.active=YES;
 owner.followPersonCoordinator=[Stage new];owner.followPersonCoordinator.active=YES;owner.serialBox=[Serial new];
 ROBSpeechBox *box=[ROBSpeechBox new];box.delegate=owner;owner.speechBox=box;
 box.speechRequest=[Request new];box.recognitionGeneration=10;
 AVAudioPCMBuffer *mic=[AVAudioPCMBuffer new];
 box.isSpeaking=YES;[box processCapturedMicrophoneBuffer:mic];
 CHECK(box.speechRequest.appended==1 && owner.cloudBuffers==0,@"TTS must allow local Stop audio but mute cloud audio");
 [box processLocalRecognitionTranscript:@"yes proceed" isFinal:YES generation:10];
 CHECK(owner.approvals==0,@"TTS yielded positive approval");
 box.isSpeaking=NO;
 [box processLocalRecognitionTranscript:@"yes proceed" isFinal:YES generation:10];
 CHECK(owner.approvals==0,@"Delayed final of robot speech became positive authority after TTS");
 box.isSpeaking=YES;
 [box processLocalRecognitionTranscript:@"Stop" isFinal:NO generation:10];
 CHECK(owner.robAI.cancellations==1 && [ROBArmRoutineCoordinator shared].cancellations==1,@"Partial Stop did not immediately cancel local routines");
 CHECK([ROBAmberGestureExecutor shared].globalHolds==1 && [ROBAmberGestureExecutor shared].cancellations==1,@"Partial Stop did not invoke native global hold/cancel dispatch");
 CHECK(owner.stageShowCoordinator.cancellations==1 && owner.serialBox.stops==1,@"Stage Stop skipped native global cancellation");
 CHECK(box.debounceSpeechInputTimer==nil && owner.approvals==0 && owner.ordinaryInputs==0,@"Stop entered approval/LLM/debounce route");
 CHECK(box.speechRequest.ended==1 && box.acknowledgements==1,@"Stop did not endpoint the consumed utterance");
 CHECK(!ROBLocalSpeechContainsPriorityStop(box.lastSpoken),@"Acknowledgement can trigger an endless Stop loop");
 [box processLocalRecognitionTranscript:@"Stop stop" isFinal:YES generation:10];
 [box processLocalRecognitionTranscript:@"yes proceed" isFinal:YES generation:10];
 CHECK([ROBAmberGestureExecutor shared].globalHolds==1 && box.acknowledgements==1 && owner.approvals==0,@"Consumed utterance replayed Stop or later granted approval");
 [box processLocalRecognitionTranscript:@"Stop" isFinal:NO generation:9];
 CHECK([ROBAmberGestureExecutor shared].globalHolds==1,@"Old recognizer callback interrupted current session");
 box.recognitionGeneration=11;box.isSpeaking=NO;box.currentTextInput=@"";box.recognitionContainsSpeechOutput=NO;
 [box processLocalRecognitionTranscript:@"yes proceed" isFinal:NO generation:11];
 CHECK(owner.approvals==0,@"Partial yes became authority");
 [box processLocalRecognitionTranscript:@"yes proceed" isFinal:YES generation:11];
 CHECK(owner.approvals==1,@"Final-only positive path changed");
 box.recognitionGeneration=12;box.currentTextInput=@"";box.isSpeaking=NO;
 [box processLocalRecognitionTranscript:@"ordinary words" isFinal:NO generation:12];
 NSTimer *pending=box.debounceSpeechInputTimer;
 [box processLocalRecognitionTranscript:@"Stop" isFinal:NO generation:12];
 [pending fire];
 CHECK(owner.ordinaryInputs==0 && [ROBAmberGestureExecutor shared].globalHolds==2,@"Stop did not invalidate pending conversational turn");
 box.recognitionGeneration=13;box.currentTextInput=@"";box.isSpeaking=NO;
 [box processLocalRecognitionTranscript:@"ordinary words" isFinal:NO generation:13];
 box.isSpeaking=YES;[box.debounceSpeechInputTimer fire];
 CHECK(owner.ordinaryInputs==0,@"Pending turn forwarded speaker audio during TTS");
 box.isSpeaking=NO;[box processCapturedMicrophoneBuffer:mic];
 CHECK(box.speechRequest.appended==2 && owner.cloudBuffers==1,@"Normal cloud capture did not resume");
 box.isShuttingDown=YES;[box processCapturedMicrophoneBuffer:mic];
 CHECK(box.speechRequest.appended==2,@"Shutdown still accepted microphone buffers");
 [owner inputText:@"Stop and wave your left arm"];
 CHECK(owner.ordinaryInputs==0 && [ROBAmberGestureExecutor shared].globalHolds==3,@"Stop did not preempt addressed arm/conversation routing");
 [owner inputText:@"the desktop is waiting"];
 CHECK(owner.ordinaryInputs==1 && [ROBAmberGestureExecutor shared].globalHolds==3,@"Ordinary words became a Stop");
 [owner installStopObserver];
 [[NSNotificationCenter defaultCenter] postNotificationName:@"ROBControllerOperatorPriorityStop" object:[NSObject new]];
 CHECK([ROBAmberGestureExecutor shared].globalHolds==3,@"Unrelated notification source entered controller Stop");
 [owner controllerOperatorPriorityStopRequested:[NSNotification notificationWithName:@"ROBControllerOperatorPriorityStop" object:[NSObject new]]];
 CHECK([ROBAmberGestureExecutor shared].globalHolds==3,@"Direct untrusted notification entered controller Stop");
 [[NSNotificationCenter defaultCenter] postNotificationName:@"ROBControllerOperatorPriorityStop" object:[ROBControllerArmApproval shared]
     userInfo:@{@"reason":@"Authenticated controller Stop"}];
 CHECK([ROBAmberGestureExecutor shared].globalHolds==4 && [ROBArmRoutineCoordinator shared].cancellations==4,
     @"Authenticated broker Stop did not synchronously reach native cancel/both-arm hold lane");
 CHECK(owner.approvals==1 && owner.ordinaryInputs==1,@"Controller Stop became a voice approval or conversation");
 [[NSNotificationCenter defaultCenter] removeObserver:owner];
 NSLog(@"Speech priority Stop: %lu runtime checks PASS; actual policies/dispatch, stub microphone and actuator seams, no hardware",(unsigned long)checks);
 return 0;
}}
'''
for marker, value in {"__MATCHER__": matcher, "__SPEECH_METHODS__": speech_methods,
                      "__OPERATOR_STOP_METHOD__": operator_stop_method,
                      "__CONTROLLER_STOP_METHOD__": controller_stop_method,
                      "__OBSERVER_REGISTRATION__": observer_registration,
                      "__STOP_METHOD__": stop_method, "__PRIORITY_METHOD__": priority_method,
                      "__INPUT_PREFIX__": input_prefix}.items():
    fixture = fixture.replace(marker, value)

with tempfile.TemporaryDirectory(prefix="rob-speech-stop-", dir="/private/tmp") as directory:
    path = Path(directory)
    (path / "fixture.mm").write_text(fixture)
    subprocess.run(["xcrun", "clang++", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    str(path / "fixture.mm"), "-o", str(path / "fixture")], check=True)
    subprocess.run([str(path / "fixture")], check=True)
