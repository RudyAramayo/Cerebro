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
- (NSDictionary *)manualArmControlReadinessForUDPPort:(NSInteger)port expectedSessionGeneration:(unsigned long long)generation;
@end
@implementation ROBAmberGatewayClient
+ (instancetype)shared { static id client; if (!client) client = [self new]; return client; }
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
@end
@implementation ROBPythonRuntime
+ (instancetype)sharedRuntime { static id runtime; if (!runtime) runtime = [self new]; return runtime; }
- (NSString *)runPythonWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    self.launches++; self.lastArguments = arguments; return @"fixture; no SDK launched";
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
int main(void) { @autoreleasepool {
    ManualDispatchFixture *dispatch = [ManualDispatchFixture new];
    ROBAmberGatewayClient *gateway = [ROBAmberGatewayClient shared];
    ROBPythonRuntime *runtime = [ROBPythonRuntime sharedRuntime];
    NSDictionary *live = @{@"allowed": @YES, @"reason": @"", @"sessionGeneration": @1};
    NSDictionary *lost = @{@"allowed": @NO, @"reason": @"motor feedback stale", @"sessionGeneration": @1};
    NSArray *args = @[@"fixture.py", @"--port", @"26001", @"--cmd_sleep", @"0.12"];

    gateway.answers = @[lost];
    [dispatch runPythonArguments:args operation:@"cmd_position_input"];
    expect(runtime.launches == 0, @"Missing motor feedback launched an SDK command");

    gateway.calls = 0; gateway.answers = @[live, lost, live];
    [dispatch runPythonArguments:args operation:@"cmd_position_input"];
    expect(runtime.launches == 0 && gateway.calls == 2, @"Delayed command survived a feedback loss");

    gateway.calls = 0;
    gateway.answers = @[live, @{@"allowed": @YES, @"sessionGeneration": @2}];
    [dispatch runPythonArguments:args operation:@"cmd_position_input"];
    expect(runtime.launches == 0, @"Delayed command crossed into a replacement session");

    gateway.calls = 0; gateway.answers = @[live];
    [dispatch runPythonArguments:args operation:@"cmd_position_input"];
    expect(runtime.launches == 1 && gateway.calls >= 3, @"Live delayed request did not recheck feedback");
    expect(gateway.lastPort == 26001, @"Physical-right port changed at admission");
    expect([runtime.lastArguments[4] isEqualToString:@"0"], @"SDK retained an unchecked delay");

    gateway.calls = 0; gateway.answers = @[lost];
    [dispatch runPythonArguments:args operation:@"cmd_deactivate_mode_v2"];
    expect(runtime.launches == 2 && gateway.calls == 0, @"Stale feedback blocked deactivation");
    [dispatch runPythonArguments:args operation:@"watch_position_out"];
    expect(runtime.launches == 3 && gateway.calls == 0, @"Stale feedback blocked a read-only query");

    for (NSString *operation in @[@"cmd_activate_mode_v2", @"zero_position_mode_v2",
         @"cmd_position_mode_v2", @"cmd_current_mode_v2", @"cmd_cartesian_input"]) {
        [dispatch runPythonArguments:args operation:operation];
    }
    expect(runtime.launches == 3, @"An alternate manual motion path bypassed admission");
    gateway.calls = 0; gateway.answers = @[live];
    [dispatch runPythonArguments:@[@"fixture.py", @"--port", @"26002", @"--cmd_sleep", @"61"] operation:@"cmd_position_input"];
    expect(runtime.launches == 3 && gateway.lastPort == 26002, @"Invalid delay launched or changed the left port");
    puts("Manual SDK admission runtime fixtures passed; no hardware accessed");
} return 0; }
'''

with tempfile.TemporaryDirectory(prefix='rob-amber-admission-') as directory:
    root = Path(directory)
    program = root / 'fixture.m'
    binary = root / 'fixture'
    program.write_text(fixture.replace('METHOD', method))
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'AppKit',
                    str(program), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
