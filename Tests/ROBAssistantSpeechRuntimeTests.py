#!/usr/bin/env python3
"""Execute shipping assistant-speech methods with inert audio and input sinks."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Cerebro/ROBSpeechBox.m").read_text()


def method(marker):
    start = source.index(marker)
    opening = source.index("{", start)
    cursor, depth = opening + 1, 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


methods = "\n".join(method(marker) for marker in [
    "- (BOOL)sayAssistantStatus:(NSString *)text completion:",
    "- (void)finishAssistantStatusInputSuppression\n{",
    "- (void)finishSpeechQueueIfIdle\n{",
    "- (void)cancelPendingSpeech\n{",
    "- (void)teardownSpeechRecognition\n{",
    "- (void)processCapturedMicrophoneBuffer:(AVAudioPCMBuffer *)buffer\n{",
    "- (void)processLocalRecognitionTranscript:(NSString *)transcription isFinal:(BOOL)isFinal generation:(NSUInteger)generation\n{",
    "- (BOOL)consumeLocalPriorityStop:(NSString *)transcription generation:(NSUInteger)generation\n{",
])
# Skip the private declaration and extract the implemented callback.
finish_start = source.index("- (void)finishSpeechEventForSynthesizer:", source.index("#pragma mark - AVSpeechSynthesizer delegate"))
saved = source
source = source[finish_start:]
methods += "\n" + method("- (void)finishSpeechEventForSynthesizer:")
source = saved
matcher = method("BOOL ROBLocalSpeechContainsPriorityStop(")

fixture = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
__MATCHER__
@interface AVAudioPCMBuffer:NSObject @end
@implementation AVAudioPCMBuffer @end
@interface AVSpeechUtterance:NSObject
@property NSString *speechString;
@property id voice;
+ (instancetype)speechUtteranceWithString:(NSString *)text;
@end
@implementation AVSpeechUtterance
+ (instancetype)speechUtteranceWithString:(NSString *)text {AVSpeechUtterance *v=[self new];v.speechString=text;return v;}
@end
enum {AVSpeechBoundaryImmediate=0};
@interface AVSpeechSynthesizer:NSObject
- (void)stopSpeakingAtBoundary:(NSInteger)boundary;
@end
@implementation AVSpeechSynthesizer
- (void)stopSpeakingAtBoundary:(NSInteger)boundary {}
@end
@interface Sink:NSObject
@property NSUInteger input,stop,approval,cloud,wake,appended;
- (void)inputText:(NSString *)text;
- (void)didRecognizeLocalPriorityStop:(NSString *)text;
- (BOOL)acceptLocalMicrophoneAuthorization:(NSString *)text;
- (BOOL)shouldFinalizeLocalMicrophoneAuthorization:(NSString *)text;
- (void)didCaptureAudioBuffer:(AVAudioPCMBuffer *)buffer;
- (void)didFinishProcessingSpeech;
- (void)appendAudioPCMBuffer:(AVAudioPCMBuffer *)buffer;
- (void)endAudio;
- (void)cancel;
@end
@implementation Sink
- (void)inputText:(NSString *)text {self.input++;}
- (void)didRecognizeLocalPriorityStop:(NSString *)text {self.stop++;}
- (BOOL)acceptLocalMicrophoneAuthorization:(NSString *)text {self.approval++;return YES;}
- (BOOL)shouldFinalizeLocalMicrophoneAuthorization:(NSString *)text {return NO;}
- (void)didCaptureAudioBuffer:(AVAudioPCMBuffer *)buffer {self.cloud++;}
- (void)didFinishProcessingSpeech {self.wake++;}
- (void)appendAudioPCMBuffer:(AVAudioPCMBuffer *)buffer {self.appended++;}
- (void)endAudio {}
- (void)cancel {}
@end
@interface Box:NSObject
@property BOOL isSpeaking,isShuttingDown,hologramRecordingOwnsMicrophone,assistantStatusInputSuppressed;
@property BOOL assistantStatusResumeRecognition,microphoneTapInstalled,recognizerStartInProgress;
@property BOOL recognitionContainsSpeechOutput,speechQueueCancellationInProgress,localPriorityStopConsumed;
@property NSUInteger assistantStatusGeneration,recognitionGeneration,localPriorityStopRecognitionGeneration,restarts;
@property Sink *delegate,*speechRequest,*task;
@property NSString *currentTextInput;
@property NSTimer *debounceSpeechInputTimer;
@property NSMutableArray *pendingSpeechUtterances;
@property NSMapTable *utteranceCompletions;
@property AVSpeechSynthesizer *avSpeechSynthesizer;
- (BOOL)sayAssistantStatus:(NSString *)text completion:(void(^)(BOOL))completion;
- (void)finishAssistantStatusInputSuppression;
- (void)finishSpeechQueueIfIdle;
- (void)cancelPendingSpeech;
- (void)startRecognizer;
- (void)enqueueSpeechUtterance:(AVSpeechUtterance *)utterance;
- (id)voiceForText:(NSString *)text;
- (void)teardownSpeechRecognition;
- (void)finishSpeechEventForSynthesizer:(AVSpeechSynthesizer *)s utterance:(AVSpeechUtterance *)u finished:(BOOL)finished;
@end
@implementation Box
- (instancetype)init {if((self=[super init])) {self.delegate=[Sink new];self.speechRequest=[Sink new];self.task=[Sink new];
 self.pendingSpeechUtterances=[NSMutableArray array];self.utteranceCompletions=[NSMapTable strongToStrongObjectsMapTable];
 self.avSpeechSynthesizer=[AVSpeechSynthesizer new];self.microphoneTapInstalled=YES;}return self;}
- (void)startRecognizer {self.restarts++;self.speechRequest=[Sink new];self.task=[Sink new];}
- (void)enqueueSpeechUtterance:(AVSpeechUtterance *)utterance {self.isSpeaking=YES;[self.pendingSpeechUtterances addObject:utterance];}
- (id)voiceForText:(NSString *)text {return nil;}
__METHODS__
@end
static NSUInteger checks=0;
#define CHECK(v) do {checks++;if(!(v)){NSLog(@"FAIL line %d",__LINE__);exit(1);}}while(0)
static void pump(double seconds) {NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(end.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];}
int main(){@autoreleasepool{
 Box *b=[Box new]; AVAudioPCMBuffer *mic=[AVAudioPCMBuffer new];
 b.recognitionGeneration=10;
 [b processLocalRecognitionTranscript:@"ordinary words" isFinal:NO generation:10];
 NSTimer *oldTimer=b.debounceSpeechInputTimer;
 __block NSUInteger completed=0,cancelled=0;
 CHECK([b sayAssistantStatus:@"Stop is a quoted status, yes proceed." completion:^(BOOL ok){if(ok)completed++;else cancelled++;}]);
 CHECK(b.assistantStatusInputSuppressed && b.speechRequest==nil && b.task==nil && !oldTimer.valid);
 [oldTimer fire];
 [b processLocalRecognitionTranscript:@"stop" isFinal:YES generation:10];
 [b processLocalRecognitionTranscript:@"yes proceed" isFinal:YES generation:b.recognitionGeneration];
 [b processCapturedMicrophoneBuffer:mic];
 CHECK(b.delegate.stop==0 && b.delegate.approval==0 && b.delegate.input==0 && b.delegate.cloud==0);
 AVSpeechUtterance *first=b.pendingSpeechUtterances.firstObject;
 [b finishSpeechEventForSynthesizer:b.avSpeechSynthesizer utterance:first finished:YES];pump(0.1);
 CHECK(completed==1 && b.assistantStatusInputSuppressed && b.restarts==0);
 // New status during the old acoustic tail must invalidate the old resume.
 CHECK([b sayAssistantStatus:@"Second status" completion:^(BOOL ok){if(ok)completed++;else cancelled++;}]);
 pump(0.5);CHECK(b.assistantStatusInputSuppressed && b.restarts==0);
 [b cancelPendingSpeech];pump(0.1);
 CHECK(cancelled==1 && b.assistantStatusInputSuppressed);
 pump(0.5);CHECK(!b.assistantStatusInputSuppressed && b.restarts==1 && b.delegate.wake==0);
 [b processCapturedMicrophoneBuffer:mic];CHECK(b.delegate.cloud==1 && b.speechRequest.appended==1);
 // Normal robot speech still permits local priority Stop and mutes cloud.
 b.isSpeaking=YES;[b processLocalRecognitionTranscript:@"stop" isFinal:NO generation:b.recognitionGeneration];
 CHECK(b.delegate.stop==1);
 Box *silent=[Box new];silent.microphoneTapInstalled=NO;
 CHECK([silent sayAssistantStatus:@"No microphone preference changes" completion:nil]);
 [silent cancelPendingSpeech];pump(0.6);CHECK(silent.restarts==0 && !silent.assistantStatusInputSuppressed && silent.delegate.wake==0);
 Box *shutdown=[Box new];CHECK([shutdown sayAssistantStatus:@"Shutdown" completion:nil]);
 [shutdown cancelPendingSpeech];pump(0.1);shutdown.isShuttingDown=YES;pump(0.5);CHECK(shutdown.restarts==0);
 Box *busy=[Box new];[busy enqueueSpeechUtterance:[AVSpeechUtterance speechUtteranceWithString:@"Ordinary response"]];
 CHECK(![busy sayAssistantStatus:@"Do not interrupt" completion:nil] && !busy.assistantStatusInputSuppressed);
 [busy cancelPendingSpeech];pump(0.1);CHECK(busy.delegate.wake==1);
 busy.hologramRecordingOwnsMicrophone=YES;CHECK(![busy sayAssistantStatus:@"Reject recording" completion:nil]);
 NSLog(@"PASS %lu assistant speech checks: both input sinks, stale transcripts, cancellation, overlapping tails, wake state and normal Stop; inert audio only",(unsigned long)checks);
 return 0;
}}
'''.replace("__MATCHER__", matcher).replace("__METHODS__", methods)
with tempfile.TemporaryDirectory(prefix="rob-assistant-speech-", dir="/private/tmp") as directory:
    path = Path(directory)
    (path / "fixture.m").write_text(fixture)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    str(path / "fixture.m"), "-o", str(path / "fixture")], check=True)
    subprocess.run([str(path / "fixture")], check=True)
