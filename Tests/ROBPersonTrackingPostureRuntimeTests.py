#!/usr/bin/env python3
"""Exercise production posture callbacks with a recording serial fake; no hardware."""

from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Cerebro/ROBMainViewController.mm").read_text()


def method(signature: str) -> str:
    start = SOURCE.rindex(signature)
    opening = SOURCE.index("{", start)
    depth = 0
    for end in range(opening, len(SOURCE)):
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        if depth == 0:
            return SOURCE[start : end + 1]
    raise AssertionError(signature)


methods = "\n".join(method(signature) for signature in (
    "- (void)updatePersonTrackingPostureForDistance:",
    "- (void)updatePersonTrackingUprightRestAtUptime:",
    "- (void)updatePersonTrackingAttentionAtUptime:",
))
constants = "\n".join(re.findall(
    r"^static (?:NSTimeInterval|double|int) const kROBPersonTracking\w+ = [\d.]+;",
    SOURCE, re.MULTILINE,
))

harness = r'''
#import <Cocoa/Cocoa.h>
#import "ROBPersonTrackingPreferences.h"
#import "ROBNeckSafetyPolicy.h"
#include <assert.h>

typedef NS_ENUM(NSInteger, ROBNeckCommandDisposition) {
    ROBNeckCommandDispositionRejected,
    ROBNeckCommandDispositionAppliedCommand,
    ROBNeckCommandDispositionHeldForSafety,
};

@interface RecordingSerial : NSObject
@property BOOL lowerNeckTiltCommandKnown;
@property NSInteger commandedLowerNeckTiltTarget;
@property BOOL personTrackingUprightTransitionActive;
@property BOOL personTrackingPostureSequenceActive;
@property BOOL safeNeckStartupInProgress;
@property(copy) NSString *neckCommandSafetyStatus;
@property NSInteger requests;
@property(copy) NSArray<NSString *> *lastSequence;
- (ROBNeckCommandDisposition)requestPersonTrackingPostureSequence:(NSArray *)sequence;
- (ROBNeckCommandDisposition)requestPersonTrackingLeanForwardRest;
@end
@implementation RecordingSerial
- (ROBNeckCommandDisposition)requestPersonTrackingPostureSequence:(NSArray *)sequence {
    self.requests++;
    self.lastSequence = sequence;
    return ROBNeckCommandDispositionAppliedCommand;
}
- (ROBNeckCommandDisposition)requestPersonTrackingLeanForwardRest {
    self.requests++;
    return ROBNeckCommandDispositionAppliedCommand;
}
@end

@interface TrackingToggle : NSObject
@property NSInteger state;
@end
@implementation TrackingToggle
@end
@interface Torso : NSObject
@property(strong) TrackingToggle *headTracking_enabled;
@end
@implementation Torso
@end

@interface Tracking : NSObject
@property(strong) RecordingSerial *serialBox;
@property(strong) Torso *torsoControlsViewController;
@property BOOL personTrackingUprightPostureActive;
@property BOOL personTrackingHasAcquiredSubject;
@property BOOL personTrackingFilterInitialized;
@property NSInteger personTrackingUpperBaselineTarget;
@property NSInteger personTrackingDistanceBand;
@property(copy) NSString *personTrackingSourceID;
@property NSTimeInterval personTrackingDistanceBandEnteredUptime;
@property NSTimeInterval lastPersonTrackingUpdateUptime;
@property NSTimeInterval personTrackingLostSinceUptime;
@property NSTimeInterval lastPersonTrackingAttentionReturnUptime;
@property NSTimeInterval lastFaceTrackingObservationUptime;
@property NSTimeInterval lastMainPoseTrackingObservationUptime;
@property NSTimeInterval lastInstaPoseTrackingObservationUptime;
@end
@implementation Tracking
/* PRODUCTION_METHODS */
@end

int main(void) { @autoreleasepool {
    // The fixture executable has its own defaults domain, never Cerebro's.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:ROBPersonTrackingAutomaticPostureChangesDefaultsKey];
    assert(!ROBPersonTrackingAutomaticPostureChangesEnabledFromDefaults(defaults));
    assert(ROBPersonTrackingPanTargetsPerSecondFromDefaults(defaults) == 1500);
    assert(ROBPersonTrackingVerticalTargetsPerSecondFromDefaults(defaults) == 400);
    RecordingSerial *serial = [RecordingSerial new];
    serial.lowerNeckTiltCommandKnown = YES;
    serial.commandedLowerNeckTiltTarget = ROBNeckSafetyUprightLowerTarget;
    Tracking *tracking = [Tracking new];
    tracking.serialBox = serial;
    tracking.torsoControlsViewController = [Torso new];
    tracking.torsoControlsViewController.headTracking_enabled = [TrackingToggle new];
    tracking.torsoControlsViewController.headTracking_enabled.state = NSControlStateValueOn;
    tracking.personTrackingUprightPostureActive = YES;
    tracking.personTrackingHasAcquiredSubject = YES;
    tracking.lastPersonTrackingUpdateUptime = 1;

    // Ten minutes of close/far changes every two seconds, including long idle
    // gaps, must never request a lean gesture in the default upright mode.
    for (int sample = 0; sample < 6000; sample++) {
        double now = 100 + sample * 0.1;
        double distance = (sample / 20) % 2 ? 0.4 : 4.0;
        [tracking updatePersonTrackingPostureForDistance:distance atUptime:now];
        [tracking updatePersonTrackingUprightRestAtUptime:now];
        [tracking updatePersonTrackingAttentionAtUptime:now];
    }
    assert(serial.requests == 0);
    assert(tracking.personTrackingDistanceBand == 0);
    assert(tracking.personTrackingDistanceBandEnteredUptime == 0);

    // Explicit scan mode retains the existing near/far sequences and dwell.
    [defaults setBool:YES forKey:ROBPersonTrackingAutomaticPostureChangesDefaultsKey];
    [tracking updatePersonTrackingPostureForDistance:0.4 atUptime:800];
    assert(serial.requests == 0);
    [tracking updatePersonTrackingPostureForDistance:0.4 atUptime:801];
    assert(serial.requests == 1);
    assert(([serial.lastSequence isEqualToArray:@[@"upright", @"lean_back"]]));
    [tracking updatePersonTrackingPostureForDistance:4.0 atUptime:802];
    [tracking updatePersonTrackingPostureForDistance:4.0 atUptime:803];
    assert(serial.requests == 2);
    assert(([serial.lastSequence isEqualToArray:@[@"upright", @"lean_forward"]]));

    // Disabling scan resets any partially collected distance dwell.
    [defaults setBool:NO forKey:ROBPersonTrackingAutomaticPostureChangesDefaultsKey];
    [tracking updatePersonTrackingPostureForDistance:0.4 atUptime:804];
    [tracking updatePersonTrackingUprightRestAtUptime:900];
    [tracking updatePersonTrackingAttentionAtUptime:900];
    assert(serial.requests == 2);
    [defaults setBool:YES forKey:ROBPersonTrackingAutomaticPostureChangesDefaultsKey];
    [tracking updatePersonTrackingPostureForDistance:0.4 atUptime:901];
    assert(serial.requests == 2);
    [tracking updatePersonTrackingPostureForDistance:0.4 atUptime:902];
    assert(serial.requests == 3);
    [defaults removeObjectForKey:ROBPersonTrackingAutomaticPostureChangesDefaultsKey];
    puts("ROB upright lookaround runtime fixtures passed (6000 observations)");
} }
'''
harness = harness.replace("/* PRODUCTION_METHODS */", methods)
harness = harness.replace("@interface RecordingSerial", constants + "\n@interface RecordingSerial", 1)
with tempfile.TemporaryDirectory(prefix="rob-upright-tests-") as directory:
    source = Path(directory) / "fixture.m"
    binary = Path(directory) / "ROBUprightTrackingFixture"
    source.write_text(harness)
    subprocess.run([
        "clang", "-fobjc-arc", "-framework", "Cocoa",
        "-I", str(ROOT / "Cerebro"), str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
