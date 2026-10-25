#!/usr/bin/env python3
"""Run the production display mailbox under actual Objective-C concurrency."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / 'Cerebro/ROBSCNViewController.m').read_text()
start = source.index('@interface ROBSCNDepthCloudDisplayMailbox : NSObject')
implementation = source.index('@implementation ROBSCNDepthCloudDisplayMailbox', start)
helper = source[start:source.index('@end', implementation) + len('@end')]
observer_start = source.index('- (void)receivedDepthCloudFrame:(NSNotification *)notification')
consumer_start = source.index('- (void)displayDepthCloudFrame:(ROBDepthCloudFrame *)frame', observer_start)
observer = source[observer_start:consumer_start]
assert 'offerFrame:frame' in observer and 'takeLatestFrames' in observer
assert observer.index('offerFrame:frame') < observer.index('dispatch_async(dispatch_get_main_queue()')
assert '[self receivedDepthCloudFrame:notification]' not in observer
assert '[self.cloudDisplayMailbox close];' in source[source.index('- (void)invalidate'):]
consumer = source[consumer_start:source.index('- (SCNGeometry *)pointGeometry:', consumer_start)]
assert 'ROBLeftArmTrial.shared.isRunning || ROBArmRoutineCoordinator.shared.isRunning' in consumer
assert 'isNeckOnlyInspection' not in consumer
assert '(trialBusy ? 0.5 : 0.125)' in consumer
# Display retains the original independent source/pose/freshness gates.
for required in ('self.bellyCloudUpdatePending : self.cloudUpdatePending',
                 'frame.capturedUptime >= serial.neckCommandReadyAtUptime',
                 'now - frame.capturedUptime > 0.7', '(!belly && !settled)',
                 'self.ghostGestureEditor.depthProjectionIdentity',
                 'robotTransform:robot cameraTransform:camera neckTargets:targets'):
    assert required in consumer, required
assert 'ROBArmRoutineVision' not in helper + observer + consumer
assert 'cameraGeneration' not in helper + observer + consumer

fixture = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
@interface ROBDepthCloudFrame : NSObject
@property BOOL isBelly;
@property uint64_t sourceSequence;
@property NSTimeInterval capturedUptime;
@end
@implementation ROBDepthCloudFrame
@end
/* ACTUAL_HELPER */
static ROBDepthCloudFrame *frame(BOOL belly, uint64_t sequence) {
    ROBDepthCloudFrame *f = [ROBDepthCloudFrame new];
    f.isBelly = belly; f.sourceSequence = sequence; f.capturedUptime = sequence * 0.5;
    return f;
}
static void require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); abort(); }
}
int main(void) {
    @autoreleasepool {
        ROBSCNDepthCloudDisplayMailbox *mailbox = [ROBSCNDepthCloudDisplayMailbox new];
        __block NSUInteger schedules = 0;
        dispatch_queue_t producer = dispatch_queue_create("fixture-producer", DISPATCH_QUEUE_SERIAL);
        dispatch_sync(producer, ^{
            @autoreleasepool {
                for (uint64_t index = 1; index <= 1000; index++) {
                    if ([mailbox offerFrame:frame(NO, index)]) schedules++;
                    if ([mailbox offerFrame:frame(YES, index + 1000)]) schedules++;
                }
            }
        });
        require(schedules == 1, "A blocked main queue must have only one scheduled drain");
        NSArray<ROBDepthCloudFrame *> *latest = [mailbox takeLatestFrames];
        require(latest.count == 2, "Mailbox retains only the two latest role frames");
        require(!latest[0].isBelly && latest[0].sourceSequence == 1000 && latest[0].capturedUptime == 500,
                "Latest head source identity/time changed or was lost");
        require(latest[1].isBelly && latest[1].sourceSequence == 2000 && latest[1].capturedUptime == 1000,
                "Latest belly source identity/time changed or was lost");
        require([mailbox takeLatestFrames].count == 0, "A drained mailbox must release queued frames");
        require([mailbox offerFrame:frame(NO, 2001)], "Offer after a drain must schedule a new drain");
        require(![mailbox offerFrame:frame(YES, 2002)], "Roles share one bounded main drain");
        require([mailbox takeLatestFrames].count == 2, "A new offer during consumption must survive");

        // Concurrent producers cannot independently schedule duplicate drains.
        ROBSCNDepthCloudDisplayMailbox *concurrent = [ROBSCNDepthCloudDisplayMailbox new];
        NSLock *countLock = [NSLock new]; __block NSUInteger concurrentSchedules = 0;
        dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            @autoreleasepool {
                if ([concurrent offerFrame:frame(index % 2, index + 1)]) {
                    [countLock lock]; concurrentSchedules++; [countLock unlock];
                }
            }
        });
        require(concurrentSchedules == 1, "Concurrent producers scheduled duplicate main drains");
        NSArray<ROBDepthCloudFrame *> *raced = [concurrent takeLatestFrames];
        require(raced.count == 2 && !raced[0].isBelly && raced[1].isBelly,
                "Concurrent offers lost one camera role");
        for (ROBDepthCloudFrame *f in raced)
            require(f.capturedUptime == f.sourceSequence * 0.5, "Source capture time was fabricated");

        // Superseded frames and close-on-invalidate do not retain camera buffers.
        ROBSCNDepthCloudDisplayMailbox *closing = [ROBSCNDepthCloudDisplayMailbox new];
        __weak ROBDepthCloudFrame *oldFrame;
        @autoreleasepool {
            ROBDepthCloudFrame *first = frame(NO, 1); oldFrame = first;
            require([closing offerFrame:first], "First queued drain was not scheduled");
            require(![closing offerFrame:frame(NO, 2)], "Replacement scheduled another drain");
        }
        require(oldFrame == nil, "Mailbox retained a superseded frame");
        [closing close];
        require([closing takeLatestFrames].count == 0, "Invalidated queued drain must be ignored");
        require(![closing offerFrame:frame(YES, 3)], "Invalidated observer accepted another frame");
        require([closing takeLatestFrames].count == 0, "Closed mailbox retained a late camera frame");
        printf("Display mailbox runtime passed: 2000 deferred and1000 concurrent offers; one drain, latest per-role source IDs/times, superseded release and invalidation; source/vision feeds unchanged\n");
    }
    return 0;
}
'''.replace('/* ACTUAL_HELPER */', helper)
with tempfile.TemporaryDirectory(prefix='rob-cloud-mailbox-', dir='/private/tmp') as directory:
    path = Path(directory)
    unit = path / 'fixture.m'; executable = path / 'fixture'
    unit.write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    '-Wall', '-Wextra', '-Werror', str(unit), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
