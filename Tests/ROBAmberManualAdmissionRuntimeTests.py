#!/usr/bin/env python3
"""Run the actual Objective-C manual dispatch method with no hardware or SDK."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Cerebro/ROBSerialBox.m').read_text()
begin = source.rindex('- (void)runPythonArguments:')
end = source.index('\n- (void) watch_position_out:', begin)
method = source[begin:end]

fixture = r'''
#import <AppKit/AppKit.h>
#import <math.h>

@interface ROBAmberGatewayClient : NSObject
@property NSArray<NSDictionary *> *answers;
@property NSUInteger calls;
@property NSInteger lastPort;
+ (instancetype)shared;
- (NSDictionary *)connectionSnapshot;
- (unsigned long long)priorityHoldForArm:(NSString *)arm;
- (NSDictionary *)manualArmControlReadinessForUDPPort:(NSInteger)port expectedSessionGeneration:(unsigned long long)generation;
@end
@implementation ROBAmberGatewayClient
+ (instancetype)shared { static id client; if (!client) client = [self new]; return client; }
- (NSDictionary *)connectionSnapshot { return @{@"sessionGeneration": @1}; }
- (unsigned long long)priorityHoldForArm:(NSString *)arm { return 1; }
- (NSDictionary *)manualArmControlReadinessForUDPPort:(NSInteger)port expectedSessionGeneration:(unsigned long long)generation {
    self.lastPort = port;
    NSDictionary *answer = self.answers[MIN(self.calls++, self.answers.count - 1)];
    if (generation && generation != [answer[@"sessionGeneration"] unsignedLongLongValue]) {
        return @{@"allowed": @NO, @"reason": @"session changed"};
    }
    return answer;
}
@end

@interface ROBPythonRuntime : NSObject
@property NSUInteger launches;
@property NSArray<NSString *> *lastArguments;
+ (instancetype)sharedRuntime;
- (NSString *)runPythonWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error;
- (NSTask *)newTaskWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error;
@end
@implementation ROBPythonRuntime
+ (instancetype)sharedRuntime { static id runtime; if (!runtime) runtime = [self new]; return runtime; }
- (NSString *)runPythonWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    self.launches++; self.lastArguments = arguments; return @"fixture; no SDK launched";
}
- (NSTask *)newTaskWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    self.launches++; self.lastArguments = arguments;
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/true"];
    return task;
}
@end

static BOOL ROBLaunchTaskSafely(NSTask *task, NSError **error) { return [task launchAndReturnError:error]; }

// The production broker is tested separately. This console seam makes an
// explicit fixture decision, then exercises the actual SDK dispatch closure.
@interface ROBControllerArmApproval : NSObject
@property BOOL approve;
@property BOOL cancelSoon;
@property BOOL active;
@property dispatch_semaphore_t completed;
+ (instancetype)shared;
- (void)requestWithOperation:(NSString *)operation arm:(NSString *)arm summary:(NSString *)summary
                    execute:(void (^)(void (^)(NSDictionary *)))execute cancel:(void (^)(void))cancel
                 completion:(void (^)(NSDictionary *))completion;
@end
@implementation ROBControllerArmApproval
+ (instancetype)shared { static ROBControllerArmApproval *b; if (!b) { b = [self new]; b.approve = YES; } return b; }
- (void)requestWithOperation:(NSString *)operation arm:(NSString *)arm summary:(NSString *)summary
                    execute:(void (^)(void (^)(NSDictionary *)))execute cancel:(void (^)(void))cancel
                 completion:(void (^)(NSDictionary *))completion {
    if (!self.approve) { completion(@{@"status": @"rejected", @"detail": @"Fixture rejected"}); dispatch_semaphore_signal(self.completed); return; }
    self.active = YES;
    void (^finish)(NSDictionary *) = ^(NSDictionary *result) {
        if (!self.active) return;
        self.active = NO; completion(result); dispatch_semaphore_signal(self.completed);
    };
    execute(finish);
    if (self.cancelSoon) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            cancel(); finish(@{@"status": @"cancelled", @"detail": @"Fixture cancelled"});
        });
    }
}
@end

@interface ManualDispatchFixture : NSObject
@property NSTextView *amberMasterCoreOutput_L10;
@property NSTextView *amberMasterCoreOutput_R11;
- (void)runPythonArguments:(NSArray<NSString *> *)arguments operation:(NSString *)operation;
@end
@implementation ManualDispatchFixture
METHOD
@end

static void expect(BOOL value, NSString *message) {
    if (!value) { NSLog(@"FAIL: %@", message); exit(1); }
}
static void perform(ManualDispatchFixture *dispatcher, NSArray *arguments, NSString *operation) {
    ROBControllerArmApproval *broker = ROBControllerArmApproval.shared;
    broker.completed = dispatch_semaphore_create(0);
    [dispatcher runPythonArguments:arguments operation:operation];
    expect(dispatch_semaphore_wait(broker.completed, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
           @"Manual approval dispatch never finished");
}
int main(void) {
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
    ManualDispatchFixture *dispatch = [ManualDispatchFixture new];
    ROBAmberGatewayClient *gateway = [ROBAmberGatewayClient shared];
    ROBPythonRuntime *runtime = [ROBPythonRuntime sharedRuntime];
    NSDictionary *live = @{@"allowed": @YES, @"reason": @"", @"sessionGeneration": @1};
    NSDictionary *lost = @{@"allowed": @NO, @"reason": @"motor feedback stale", @"sessionGeneration": @1};
    NSArray *args = @[@"fixture.py", @"--port", @"26001", @"--cmd_sleep", @"0.12"];

    gateway.answers = @[lost];
    perform(dispatch, args, @"cmd_position_input");
    expect(runtime.launches == 0, @"Missing motor feedback launched an SDK command");

    gateway.calls = 0; gateway.answers = @[live, lost, live];
    perform(dispatch, args, @"cmd_position_input");
    expect(runtime.launches == 0 && gateway.calls == 2, @"Delayed command survived a feedback loss");

    gateway.calls = 0;
    gateway.answers = @[live, @{@"allowed": @YES, @"sessionGeneration": @2}];
    perform(dispatch, args, @"cmd_position_input");
    expect(runtime.launches == 0, @"Delayed command crossed into a replacement session");

    gateway.calls = 0; gateway.answers = @[live];
    perform(dispatch, args, @"cmd_position_input");
    expect(runtime.launches == 1 && gateway.calls >= 3, @"Live delayed request did not recheck feedback");
    expect(gateway.lastPort == 26001, @"Physical-right port changed at admission");
    expect([runtime.lastArguments[4] isEqualToString:@"0"], @"SDK retained an unchecked delay");

    gateway.calls = 0; gateway.answers = @[lost];
    perform(dispatch, args, @"cmd_deactivate_mode_v2");
    expect(runtime.launches == 1 && gateway.calls == 1, @"Deactivation bypassed feedback admission");
    [dispatch runPythonArguments:args operation:@"watch_position_out"];
    expect(runtime.launches == 2 && gateway.calls == 1, @"Read-only query incorrectly requested admission");

    for (NSString *operation in @[@"cmd_activate_mode_v2", @"zero_position_mode_v2",
         @"cmd_position_mode_v2", @"cmd_current_mode_v2", @"cmd_cartesian_input"]) {
        perform(dispatch, args, operation);
    }
    expect(runtime.launches == 2, @"An alternate manual motion path bypassed admission");
    gateway.calls = 0; gateway.answers = @[live];
    perform(dispatch, @[@"fixture.py", @"--port", @"26002", @"--cmd_sleep", @"61"], @"cmd_position_input");
    expect(runtime.launches == 2, @"Invalid delay launched the SDK");
    ROBControllerArmApproval *broker = ROBControllerArmApproval.shared;
    broker.approve = NO;
    perform(dispatch, args, @"cmd_activate_mode_v2");
    expect(runtime.launches == 2, @"Rejected controller approval launched a mode change");
    broker.approve = YES; broker.cancelSoon = YES;
    perform(dispatch, args, @"cmd_position_input");
    [NSThread sleepForTimeInterval:0.2];
    expect(runtime.launches == 2, @"Cancelled delay still launched an SDK command");
    broker.cancelSoon = NO;
    perform(dispatch, @[@"fixture.py", @"--port", @"26002", @"--cmd_sleep", @"0"], @"cmd_position_input");
    expect(runtime.launches == 3 && gateway.lastPort == 26002, @"Physical-left routing changed");
    puts("Manual SDK approval/admission fixtures passed; no hardware or SDK accessed");
    exit(0);
} }); dispatch_main(); }
'''

with tempfile.TemporaryDirectory(prefix='rob-amber-admission-') as directory:
    root = Path(directory)
    program = root / 'fixture.m'
    binary = root / 'fixture'
    program.write_text(fixture.replace('METHOD', method))
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'AppKit',
                    str(program), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
