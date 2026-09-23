#!/usr/bin/env python3
"""Run production neck gateway/startup code with a fake clock and byte recorder.

No app or serial port is opened, and Cerebro preferences are not modified.
Only the transport, clock, startup catalog and timer scheduling are substituted.
"""

from pathlib import Path
import re
import subprocess
import tempfile

from ROBNeckSafetyStaticTests import mask_c_comments_and_literals

ROOT = Path(__file__).resolve().parents[1]
serial = (ROOT / "Cerebro/ROBSerialBox.m").read_text()
header = (ROOT / "Cerebro/ROBSerialBox.h").read_text()
masked = mask_c_comments_and_literals(serial)


def method(selector):
    for match in re.finditer(r"(?m)^-\s*\([^\n)]+\)\s*" + re.escape(selector), masked):
        opening = masked.index("{", match.end())
        semicolon = masked.find(";", match.end())
        if 0 <= semicolon < opening:
            continue
        depth = 0
        for end in range(opening, len(masked)):
            depth += (masked[end] == "{") - (masked[end] == "}")
            if depth == 0:
                return serial[match.start():end + 1]
    raise AssertionError(selector)


selectors = [
    "isNeckCommandStateKnown", "neckSafetyConfiguration",
    "invalidateNeckCommandStateWithStatus:", "cancelPersonTrackingPostureSequence",
    "sendMaestroTarget:", "sendMaestroLowerTarget:", "traceNeckWriteForSource:",
    "maestroMotionDurationFromTarget:", "refreshSettledNeckEnvelopeAtTime:",
    "refreshPersonTrackingUprightTransitionAtTime:", "neckCommandReadyAtUptime",
    "personTrackingMayUpdateNeck", "personTrackingCorrectionReadyAtUptime",
    "requestPersonTrackingPanTarget:", "requestOperatorNeckPosePanTarget:",
    "applySafeNeckPanTarget:", "startSafeNeckStartup",
    "advanceSafeNeckStartupForGeneration:", "cancelSafeNeckStartup",
    "prepareNeckForPersonFollow", "prepareNeckForArmInspection",
    "torso_controllerPassthrough_head_pan:",
]
methods = [method(selector) for selector in selectors]
production = "\n".join(methods)
used = set(re.findall(r"self\.(\w+)", production))
properties = {}
for declaration in re.findall(r"@property\s*\([^;]+?\)\s*[^;]+;", header + "\n" + serial):
    name = re.search(r"(\w+)\s*;$", declaration).group(1)
    if name in used or "is" + name[0].upper() + name[1:] in used:
        properties[name] = declaration

constants = serial[serial.index("static NSTimeInterval const kROBNeckManualOverrideSeconds"):
                   serial.index("static double ROBTargetOverflow")]
helpers = serial[serial.index("static double ROBTargetOverflow"):
                 serial.index("NSNotificationName const ROBSerialHardwareDidChangeNotification")]
notifications = serial[serial.index("NSNotificationName const ROBSerialHardwareDidChangeNotification"):
                       serial.index("#define kRHAPI_SERIAL_PORT_BASE")]

harness = r'''
#import <Cocoa/Cocoa.h>
#import "ROBNeckSafetyPolicy.h"
#import "ROBPersonTrackingPolicy.h"
#include <assert.h>
#include <float.h>

static double fixtureNow = 100;
typedef NS_ENUM(NSInteger, ROBNeckCommandDisposition) {
    ROBNeckCommandDispositionRejected,
    ROBNeckCommandDispositionAppliedCommand,
    ROBNeckCommandDispositionHeldForSafety,
};
/* CONSTANTS */
/* HELPERS */
/* NOTIFICATIONS */
@interface ROBArmRoutineCoordinator : NSObject
@property BOOL ownsPhysicalMotion;
+ (instancetype)shared;
@end
@implementation ROBArmRoutineCoordinator
+ (instancetype)shared {
    static ROBArmRoutineCoordinator *coordinator;
    if (!coordinator) coordinator = [self new];
    return coordinator;
}
@end
@class ROBServoCameraPosition;
@interface ROBServoSequencePhase : NSObject
@property NSInteger phaseIndex, panTarget, lowerTarget, upperTarget;
@property double holdSeconds;
@end
@implementation ROBServoSequencePhase
@end
@interface ROBServoControlStore : NSObject
+ (instancetype)shared;
- (ROBServoSequencePhase *)startupPhaseAtIndex:(NSInteger)index;
@end
@implementation ROBServoControlStore
+ (instancetype)shared { return [self new]; }
- (ROBServoSequencePhase *)startupPhaseAtIndex:(NSInteger)index {
    ROBServoSequencePhase *phase = [ROBServoSequencePhase new];
    phase.phaseIndex = index + 1;
    phase.panTarget = index == 0 ? 0 : 5799;
    phase.lowerTarget = index == 2 ? 7014 : 6011;
    phase.upperTarget = index == 2 ? 7698 : 6906;
    return phase;
}
@end

@interface NeckFixture : NSObject
/* PROPERTIES */
@property(strong) NSMutableArray<NSData *> *writes;
@property NSInteger failWriteNumber, attempts;
@property double scheduledAt;
/* DECLARATIONS */
- (BOOL)writeMaestroBytes:(const void *)bytes length:(size_t)length;
- (ROBNeckSafetyConfig)loadNeckSafetyConfiguration;
- (void)scheduleSafeNeckStartupAdvanceForGeneration:(NSUInteger)generation atTime:(double)time;
@end
@implementation NeckFixture
- (BOOL)writeMaestroBytes:(const void *)bytes length:(size_t)length {
    self.attempts++;
    if (self.failWriteNumber == self.attempts) return NO;
    [self.writes addObject:[NSData dataWithBytes:bytes length:length]];
    return YES;
}
- (ROBNeckSafetyConfig)loadNeckSafetyConfiguration { return ROBNeckSafetyDefaultConfig(); }
- (void)scheduleSafeNeckStartupAdvanceForGeneration:(NSUInteger)generation atTime:(double)time {
    self.scheduledAt = time;
}
/* PRODUCTION */
@end

static NeckFixture *unknownNeck(void) {
    NeckFixture *box = [NeckFixture new];
    box.writes = [NSMutableArray array];
    box.maestroConnectionValid = YES;
    box.maestroServoSmoothingEnabled = YES;
    box.maestroServoSpeedLimit = 20;
    box.maestroServoAccelerationLimit = 2;
    [box invalidateNeckCommandStateWithStatus:@"fixture reconnect"];
    return box;
}
static void settle(NeckFixture *box) {
    fixtureNow = fmax(fixtureNow, box.neckCommandReadyAtUptime + 0.001);
    [box refreshSettledNeckEnvelopeAtTime:fixtureNow];
}
static NeckFixture *activeNeck(void) {
    NeckFixture *box = unknownNeck();
    box.neckSafetyCalibrationConfirmed = YES;
    box.neckPanCommandKnown = box.lowerNeckTiltCommandKnown = box.upperNeckTiltCommandKnown = YES;
    box.commandedNeckPanTarget = 6000;
    box.commandedLowerNeckTiltTarget = 6011;
    box.commandedUpperNeckTiltTarget = 6906;
    box.panEnvelopeLowerTarget = 6011;
    box.panEnvelopeLowerTargetIsKnown = YES;
    box.currentNeckPanMinimumDegrees = -60;
    box.currentNeckPanMaximumDegrees = 60;
    box.torsoNeckAuthorityRequiresOperatorAction = NO;
    return box;
}
static NSArray<NSArray<NSNumber *> *> *neckPackets(NeckFixture *box) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSData *packet in box.writes) {
        const uint8_t *bytes = packet.bytes;
        if (bytes[0] == 0x84 && bytes[1] <= 2) {
            [result addObject:@[@(bytes[1]), @(bytes[2] | bytes[3] << 7)]];
        } else if (bytes[0] == 0x9F && bytes[2] <= 2) {
            assert(packet.length == 7 && bytes[1] == 2 && bytes[2] == 1);
            [result addObject:@[@1, @(bytes[3] | bytes[4] << 7), @(bytes[5] | bytes[6] << 7)]];
        }
    }
    return result;
}
static void render(NeckFixture *box, int pan, int lower, int upper, BOOL manual) {
    [box torso_controllerPassthrough_head_pan:@(pan).stringValue
        head_tilt:@(lower).stringValue head_upperNeckTilt:@(upper).stringValue
        arm_R_shoulder_pan:@"0" arm_R_shoulder_tilt:@"0" arm_R_elbow_pan:@"0"
        arm_R_elbow_tilt:@"0" arm_R_wrist_pan:@"0" arm_R_wrist_tilt:@"0" arm_R_gripper:@"0"
        arm_L_shoulder_pan:@"0" arm_L_shoulder_tilt:@"0" arm_L_elbow_pan:@"0"
        arm_L_elbow_tilt:@"0" arm_L_wrist_pan:@"0" arm_L_wrist_tilt:@"0" arm_L_gripper:@"0"
        operatorInitiated:manual lowerTiltOperatorInitiated:manual];
}

int main(void) { @autoreleasepool {
    // Inspection survives the stale torso slider renderer throughout both
    // camera ramps; explicit manual intervention retains its normal priority.
    NeckFixture *inspection = activeNeck();
    assert(![inspection prepareNeckForArmInspection]);
    assert(inspection.commandedUpperNeckTiltTarget == 7375);
    render(inspection, 6000, 6011, 6807, NO);
    assert(inspection.commandedUpperNeckTiltTarget == 7375);
    settle(inspection);
    assert(![inspection prepareNeckForArmInspection]);
    assert(inspection.commandedUpperNeckTiltTarget == 5650);
    for (int tick = 0; tick < 100; tick++) render(inspection, 6000, 6011, 6807, NO);
    assert(inspection.commandedUpperNeckTiltTarget == 5650);
    settle(inspection);
    assert([inspection prepareNeckForArmInspection]);
    render(inspection, 6000, 6011, 6807, YES);
    assert(inspection.commandedUpperNeckTiltTarget == 6807);
    assert(![inspection prepareNeckForArmInspection]);

    // Each startup phase reaches the wire once despite passive renders and
    // face detections throughout the staged movement.
    NeckFixture *box = unknownNeck();
    assert([box startSafeNeckStartup] == ROBNeckCommandDispositionAppliedCommand);
    assert(neckPackets(box).count == 2);
    for (int phase = 0; phase < 3; phase++) {
        NSUInteger before = neckPackets(box).count;
        for (int tick = 0; tick < 100; tick++) {
            assert(!box.personTrackingMayUpdateNeck);
            assert([box requestPersonTrackingPanTarget:6200 desiredUpperTarget:6950]
                == ROBNeckCommandDispositionHeldForSafety);
            render(box, 6200, 7014, 6100, NO);
        }
        assert(neckPackets(box).count == before);
        fixtureNow = box.scheduledAt + 0.001;
        [box advanceSafeNeckStartupForGeneration:box.safeNeckStartupGeneration];
    }
    assert(!box.safeNeckStartupInProgress);
    assert(([neckPackets(box) isEqualToArray:@[@[@0, @0], @[@1, @6011, @6906],
                                               @[@0, @5799], @[@1, @7014, @7698]]]));
    for (int i = 0; i < 100; i++) render(box, 5799, 7014, 7698, NO);
    assert(neckPackets(box).count == 4);

    // A pan-only correction emits one packet. 100 competing observations and
    // stale UI renders during its ramp cannot reverse it or restart its clock.
    box = activeNeck();
    double startedAt = fixtureNow;
    assert([box requestPersonTrackingPanTarget:6066 desiredUpperTarget:6906]
        == ROBNeckCommandDispositionAppliedCommand);
    assert(([neckPackets(box) isEqualToArray:@[@[@0, @6066]]]));
    double readyAt = box.personTrackingCorrectionReadyAtUptime;
    double expectedWait = ROBNeckSafetyMaestroMotionDuration(6000, 6066, 20, 2) + 0.1;
    assert(fabs(readyAt - startedAt - expectedWait) < 0.000001);
    for (int tick = 0; tick < 100; tick++) {
        fixtureNow = startedAt + (readyAt - startedAt) * tick / 100.0;
        assert([box requestPersonTrackingPanTarget:5900 desiredUpperTarget:6910]
            == ROBNeckCommandDispositionHeldForSafety);
        render(box, 5800, 7014, 6100, NO);
    }
    assert(neckPackets(box).count == 1);
    assert(box.personTrackingCorrectionReadyAtUptime == readyAt);
    fixtureNow = readyAt + 0.001;
    assert([box requestPersonTrackingPanTarget:6066 desiredUpperTarget:6906]
        == ROBNeckCommandDispositionAppliedCommand);
    assert(neckPackets(box).count == 1); // steady pose writes nothing
    assert(box.personTrackingCorrectionReadyAtUptime == readyAt);
    assert([box requestPersonTrackingPanTarget:6066 desiredUpperTarget:6920]
        == ROBNeckCommandDispositionAppliedCommand);
    assert(([neckPackets(box).lastObject isEqualToArray:@[@2, @6920]]));

    // Manual changes bypass the tracking cadence immediately. Tracking cannot
    // steal any owner or issue a deferred command when that owner releases.
    render(box, 6030, 6011, 6920, YES);
    assert(box.commandedNeckPanTarget == 6030);
    assert(!box.personTrackingMayUpdateNeck);
    NSUInteger manualCount = neckPackets(box).count;
    assert([box requestPersonTrackingPanTarget:5900 desiredUpperTarget:6906]
        == ROBNeckCommandDispositionHeldForSafety);
    assert(neckPackets(box).count == manualCount);
    fixtureNow = box.manualNeckOverrideUntil + 1;
    settle(box);
    for (NSString *lease in @[@"gestureNeckAuthorityUntil", @"visionNeckAuthorityUntil",
                              @"manualNeckOverrideUntil"]) {
        [box setValue:@(fixtureNow + 1) forKey:lease];
        assert(!box.personTrackingMayUpdateNeck);
        [box setValue:@0 forKey:lease];
    }
    for (NSString *flag in @[@"safeNeckStartupInProgress", @"personTrackingUprightTransitionActive",
                             @"personTrackingPostureSequenceActive", @"torsoNeckAuthorityRequiresOperatorAction"]) {
        [box setValue:@YES forKey:flag];
        assert(!box.personTrackingMayUpdateNeck);
        [box setValue:@NO forKey:flag];
    }
    assert(box.personTrackingMayUpdateNeck);
    [ROBArmRoutineCoordinator shared].ownsPhysicalMotion = YES;
    assert(!box.personTrackingMayUpdateNeck);
    NSUInteger beforeRoutine = neckPackets(box).count;
    assert([box requestPersonTrackingPanTarget:5900 desiredUpperTarget:6906]
        == ROBNeckCommandDispositionHeldForSafety);
    render(box, 5800, 7014, 6100, NO);
    assert(neckPackets(box).count == beforeRoutine);
    [ROBArmRoutineCoordinator shared].ownsPhysicalMotion = NO;
    assert(box.personTrackingMayUpdateNeck);
    box.neckCommandSource = kROBFollowTrackingClearanceSource;
    assert(!box.personTrackingMayUpdateNeck);
    box.personFollowTrackingPrepared = YES;
    assert(box.personTrackingMayUpdateNeck);
    assert(neckPackets(box).count == manualCount);
    assert([box requestPersonTrackingPanTarget:0 desiredUpperTarget:6906]
        == ROBNeckCommandDispositionRejected);

    // A failed second packet invalidates every cached target. Reconnect/unknown
    // startup must resend even targets successfully written before the failure.
    box = activeNeck();
    box.failWriteNumber = 2;
    assert([box requestPersonTrackingPanTarget:6070 desiredUpperTarget:6930]
        == ROBNeckCommandDispositionRejected);
    assert(!box.neckCommandStateKnown && !box.personTrackingMayUpdateNeck);
    box.failWriteNumber = 0;
    NSUInteger beforeRecovery = neckPackets(box).count;
    assert([box startSafeNeckStartup] == ROBNeckCommandDispositionAppliedCommand);
    assert(neckPackets(box).count == beforeRecovery + 2);

    // OFF and a changed lower pose retain the coupled safety path. Repeated
    // exact requests must not keep sending either channel or extend settling.
    box = activeNeck();
    assert([box requestOperatorNeckPosePanTarget:6000 lowerTarget:6100 upperTarget:6900]
        == ROBNeckCommandDispositionAppliedCommand);
    assert(([neckPackets(box) isEqualToArray:@[@[@1, @6100, @6900]]]));
    double settleAt = box.neckCommandReadyAtUptime;
    for (int i = 0; i < 100; i++) {
        [box requestOperatorNeckPosePanTarget:6000 lowerTarget:6100 upperTarget:6900];
    }
    assert(neckPackets(box).count == 1 && box.neckCommandReadyAtUptime == settleAt);
    settle(box);
    render(box, 0, 0, 0, YES);
    settle(box);
    render(box, 0, 0, 0, YES);
    assert(box.neckCommandStateKnown);
    assert(box.commandedNeckPanTarget == 0 && box.commandedLowerNeckTiltTarget == 0
           && box.commandedUpperNeckTiltTarget == 0);
    assert(!box.personTrackingMayUpdateNeck);
    NSUInteger offCount = neckPackets(box).count;
    render(box, 0, 0, 0, NO);
    assert(neckPackets(box).count == offCount);
    puts("ROB neck output runtime fixtures passed: startup, pacing, deduplication, ownership, recovery, OFF");
} }
'''

replacements = {
    "CONSTANTS": constants, "HELPERS": helpers, "NOTIFICATIONS": notifications,
    "PROPERTIES": "\n".join(properties.values()),
    "DECLARATIONS": "\n".join(m[:m.index("{")].strip() + ";" for m in methods),
    "PRODUCTION": production.replace("NSProcessInfo.processInfo.systemUptime", "fixtureNow"),
}
for key, value in replacements.items():
    harness = harness.replace("/* " + key + " */", value)

with tempfile.TemporaryDirectory(prefix="rob-neck-output-") as directory:
    source = Path(directory) / "fixture.m"
    binary = Path(directory) / "ROBNeckOutputFixture"
    source.write_text(harness)
    subprocess.run([
        "clang", "-fobjc-arc", "-framework", "Cocoa", "-I", str(ROOT / "Cerebro"),
        str(source), str(ROOT / "Cerebro/ROBNeckSafetyPolicy.c"), "-o", str(binary),
    ], check=True)
    result = subprocess.run(
        [str(binary), "-ROBNeckCommandTrace", "YES"], capture_output=True, text=True,
    )
    if result.returncode:
        print(result.stdout + result.stderr)
        result.check_returncode()
    assert "Neck TX" in result.stderr
    assert "source=Torso face tracking channel=0 targets=6066" in result.stderr
    assert "channel=1 targets=6011,6906" in result.stderr
    print(result.stdout, end="")
