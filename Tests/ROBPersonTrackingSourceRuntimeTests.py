#!/usr/bin/env python3
"""Exercise production face/pose arbitration and centering without hardware.

The clock, main-queue dispatch, depth lookup, controls and serial sink are fakes.
Camera selection and the proportional controller run their production code.
"""

from pathlib import Path
import re
import subprocess
import tempfile

from ROBNeckSafetyStaticTests import objective_c_method

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Cerebro/ROBMainViewController.mm").read_text()
header = (ROOT / "Cerebro/ROBMainViewController.h").read_text()
methods = [objective_c_method(source, name) for name in (
    "didSeeNewPeople:", "trackFaceBoundingBox:", "didTrackHumanPoses:",
    "trackingPerson:(NSString *)userID x:",
)]
# The old, unreachable tracking implementation below the unconditional return
# is unrelated to the live controller and references legacy UI/network types.
methods[-1] = methods[-1].split("\n    return;\n", 1)[0] + "\n}\n"
production = "\n".join(methods)
used = set(re.findall(r"self\.(\w+)", production))
properties = {}
for declaration in re.findall(r"@property\s*\([^;]+?\)\s*[^;]+;", header + "\n" + source):
    name = re.search(r"(\w+)\s*;$", declaration).group(1)
    if name in used:
        properties[name] = declaration
constants = "\n".join(re.findall(
    r"^static (?:NSTimeInterval|double|int) const kROB(?:PersonTracking|TrainingSword)\w+ = [\d.]+;",
    source, re.MULTILINE,
))
helpers = source[source.index("static double ROBPersonTrackingFilterCoordinate("):
                 source.index("static int ROBCompareUInt16(")]

harness = r'''
#import <Cocoa/Cocoa.h>
#import "ROBPersonTrackingPolicy.h"
#import "ROBPersonTrackingPreferences.h"
#import "ROBNeckSafetyPolicy.h"
#include <assert.h>

static double fixtureNow = 100;
static void fixtureDispatch(dispatch_queue_t queue, dispatch_block_t block) { block(); }
#define VNFaceObservation FixtureFaceObservation
/* CONSTANTS */
/* HELPERS */
typedef NS_ENUM(NSInteger, ROBNeckCommandDisposition) {
    ROBNeckCommandDispositionRejected,
    ROBNeckCommandDispositionAppliedCommand,
    ROBNeckCommandDispositionHeldForSafety,
};
@interface VNFaceObservation : NSObject
@property float confidence;
@property CGRect boundingBox;
@end
@implementation VNFaceObservation
@end
@interface ROBPersonTrackingObservation : NSObject
@property double confidence, headX, headY, boundsX, boundsY, boundsWidth, boundsHeight;
@property double capturedAtUptime;
@end
@implementation ROBPersonTrackingObservation
@end
@interface ROBAutonomyCoordinator : NSObject
- (void)updatePersonVisible:(BOOL)visible;
@end
@implementation ROBAutonomyCoordinator
- (void)updatePersonVisible:(BOOL)visible {}
@end
@interface FixtureControl : NSObject
@property NSInteger state;
@property double doubleValue, minValue, maxValue;
@property NSInteger integerValue;
@end
@implementation FixtureControl
- (NSInteger)integerValue { return lround(self.doubleValue); }
- (void)setIntegerValue:(NSInteger)value { self.doubleValue = value; }
@end
@interface ROBTorsoControlsViewController : NSObject
@property(strong) FixtureControl *headTracking_enabled, *headPan_enabled;
@property(strong) FixtureControl *headTilt_enabled, *headUpperNeckTilt_enabled;
@property(strong) FixtureControl *headPan, *headTilt, *headUpperNeckTilt;
@end
@implementation ROBTorsoControlsViewController
@end
@interface ROBServoCameraPosition : NSObject
@property NSInteger panTarget, lowerTarget, upperTarget;
@property(copy) NSString *name;
@end
@implementation ROBServoCameraPosition
@end
@interface ROBServoControlStore : NSObject
+ (instancetype)shared;
- (ROBServoCameraPosition *)cameraPositionNamed:(NSString *)name;
@end
@implementation ROBServoControlStore
+ (instancetype)shared { return [self new]; }
- (ROBServoCameraPosition *)cameraPositionNamed:(NSString *)name {
    ROBServoCameraPosition *pose = [ROBServoCameraPosition new];
    pose.name = name;
    pose.panTarget = [name isEqualToString:@"fully_upright_right"] ? 4000 : 7652;
    pose.lowerTarget = 6011; pose.upperTarget = 6906;
    return pose;
}
@end
@interface ROBSerialBox : NSObject
@property BOOL personTrackingMayUpdateNeck, neckPanCommandKnown;
@property BOOL lowerNeckTiltCommandKnown, upperNeckTiltCommandKnown;
@property BOOL personTrackingUprightTransitionActive, personTrackingPostureSequenceActive;
@property NSInteger commandedNeckPanTarget, commandedLowerNeckTiltTarget, commandedUpperNeckTiltTarget;
@property double personTrackingCorrectionReadyAtUptime;
@property double currentNeckPanMinimumDegrees, currentNeckPanMaximumDegrees;
@property(copy) NSString *neckCommandSafetyStatus;
@property(strong) NSMutableArray *requests;
- (ROBNeckSafetyConfig)neckSafetyConfiguration;
- (ROBNeckCommandDisposition)requestPersonTrackingPanTarget:(NSInteger)pan desiredUpperTarget:(NSInteger)upper;
- (ROBNeckCommandDisposition)requestPersonTrackingUprightPanTarget:(NSInteger)pan lowerTarget:(NSInteger)lower upperTarget:(NSInteger)upper;
@end
@implementation ROBSerialBox
- (ROBNeckSafetyConfig)neckSafetyConfiguration { return ROBNeckSafetyDefaultConfig(); }
- (ROBNeckCommandDisposition)requestPersonTrackingPanTarget:(NSInteger)pan desiredUpperTarget:(NSInteger)upper {
    [self.requests addObject:@[@(pan), @(upper)]];
    self.commandedNeckPanTarget = pan;
    self.commandedUpperNeckTiltTarget = upper;
    self.personTrackingCorrectionReadyAtUptime = fixtureNow + 0.25;
    return ROBNeckCommandDispositionAppliedCommand;
}
- (ROBNeckCommandDisposition)requestPersonTrackingUprightPanTarget:(NSInteger)pan lowerTarget:(NSInteger)lower upperTarget:(NSInteger)upper {
    assert(!"These fixtures must retain the established upright lower pose");
    return ROBNeckCommandDispositionRejected;
}
@end
@interface Tracking : NSObject
/* PROPERTIES */
/* DECLARATIONS */
- (double)personTrackingDistanceMetersInNormalizedRect:(CGRect)rect;
- (void)updatePersonTrackingPostureForDistance:(double)distance atUptime:(double)now;
- (BOOL)updatePersonTrackingHighPoseAtUptime:(double)now source:(NSString *)source;
@end
@implementation Tracking
- (double)personTrackingDistanceMetersInNormalizedRect:(CGRect)rect { return NAN; }
- (void)updatePersonTrackingPostureForDistance:(double)distance atUptime:(double)now {}
- (BOOL)updatePersonTrackingHighPoseAtUptime:(double)now source:(NSString *)source { return NO; }
/* PRODUCTION */
@end

static Tracking *controller(void) {
    Tracking *tracking = [Tracking new];
    ROBSerialBox *serial = [ROBSerialBox new];
    serial.personTrackingMayUpdateNeck = YES;
    serial.neckPanCommandKnown = serial.lowerNeckTiltCommandKnown = serial.upperNeckTiltCommandKnown = YES;
    serial.commandedNeckPanTarget = 6000;
    serial.commandedLowerNeckTiltTarget = 6011;
    serial.commandedUpperNeckTiltTarget = 6906;
    serial.currentNeckPanMinimumDegrees = -60;
    serial.currentNeckPanMaximumDegrees = 60;
    serial.requests = [NSMutableArray array];
    tracking.serialBox = serial;
    ROBTorsoControlsViewController *torso = [ROBTorsoControlsViewController new];
    for (NSString *key in @[@"headTracking_enabled", @"headPan_enabled", @"headTilt_enabled", @"headUpperNeckTilt_enabled"]) {
        FixtureControl *control = [FixtureControl new]; control.state = NSControlStateValueOn;
        [torso setValue:control forKey:key];
    }
    NSArray *names = @[@"headPan", @"headTilt", @"headUpperNeckTilt"];
    NSArray *values = @[@6000, @6011, @6906];
    for (NSUInteger i = 0; i < names.count; i++) {
        FixtureControl *control = [FixtureControl new];
        control.doubleValue = [values[i] doubleValue];
        control.minValue = i == 0 ? 4000 : (i == 1 ? 4375 : 4300);
        control.maxValue = i == 0 ? 8000 : (i == 1 ? 7675 : 7790);
        [torso setValue:control forKey:names[i]];
    }
    tracking.torsoControlsViewController = torso;
    return tracking;
}
static VNFaceObservation *face(void) {
    VNFaceObservation *face = [VNFaceObservation new];
    face.confidence = 0.9;
    face.boundingBox = CGRectMake(0.4, 0.41, 0.2, 0.36);
    return face;
}
static ROBPersonTrackingObservation *body(double y) {
    ROBPersonTrackingObservation *pose = [ROBPersonTrackingObservation new];
    pose.headX = 0.5; pose.headY = y; pose.confidence = 0.9;
    pose.boundsX = 0.3; pose.boundsY = 0; pose.boundsWidth = 0.4; pose.boundsHeight = 0.8;
    pose.capturedAtUptime = fixtureNow;
    return pose;
}
int main(void) { @autoreleasepool {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:ROBPersonTrackingAutomaticPostureChangesDefaultsKey];
    Tracking *tracking = controller();

    // A fresh face remains the aim even when body-pose head estimates disagree.
    // Repeated identical face boxes are fresh data, not evidence of a frozen tracker.
    for (int tick = 0; tick < 8; tick++) {
        [tracking didSeeNewPeople:@[face()]];
        NSUInteger faceRequests = tracking.serialBox.requests.count;
        fixtureNow += 0.3; // beyond cadence and the fake pulse ramp
        [tracking didTrackHumanPoses:@[body(0.02)]];
        assert(tracking.serialBox.requests.count == faceRequests);
        fixtureNow += 0.3;
    }
    assert(tracking.serialBox.commandedUpperNeckTiltTarget >= 6906);
    assert(tracking.lastMainPoseTrackingObservation != nil); // still retained for depth/association

    // Identity tracking also keeps the face aim when a matching pose is cached.
    tracking.faceIdentityTrackingActive = YES;
    fixtureNow += 0.3;
    [tracking trackFaceBoundingBox:face().boundingBox];
    assert(fabs(tracking.filteredPersonTrackingY - 0.59) < 0.000001);

    // Empty detection results can clear both flags between valid face frames.
    // The legacy human-box producer must still wait for the fresh face lease.
    fixtureNow += 0.3;
    tracking.faceIdentityTrackingActive = NO;
    [tracking didSeeNewPeople:@[]];
    NSUInteger beforeMissedFace = tracking.serialBox.requests.count;
    [tracking trackingPerson:@"person1" x:0.2 y:0.02 z:-1];
    assert(tracking.serialBox.requests.count == beforeMissedFace);

    // Body pose can take over only after the face observation actually expires.
    fixtureNow += 1.1;
    NSUInteger beforeFallback = tracking.serialBox.requests.count;
    [tracking didTrackHumanPoses:@[body(0.15)]];
    assert(tracking.serialBox.requests.count == beforeFallback + 1);

    tracking = controller();
    fixtureNow += 0.3;
    [tracking trackingPerson:@"recognized-face" x:0.7 y:0.7 z:-1];
    fixtureNow += 0.3;
    [tracking trackingPerson:@"detected-face" x:0.9 y:0.9 z:-1];
    assert(fabs(tracking.filteredPersonTrackingY - 0.75) < 0.000001);

    // Alternating main-camera detector labels must not walk the upper band
    // beyond the acquisition limit or reinitialize the filter every correction.
    tracking = controller();
    NSArray *sources = @[@"recognized-face", @"detected-face", @"main-camera-face-pose", @"main-camera-pose", @"person1"];
    for (int tick = 0; tick < 80; tick++) {
        fixtureNow += 0.3;
        [tracking trackingPerson:sources[tick % sources.count] x:0.5 y:1 z:-1];
    }
    assert(tracking.personTrackingUpperBaselineTarget == 6906);
    assert(tracking.serialBox.commandedUpperNeckTiltTarget <= 7106);
    assert(tracking.serialBox.commandedUpperNeckTiltTarget > 6906);

    // A manual/sequence ownership interruption still rebases on its accepted pose.
    tracking.serialBox.personTrackingMayUpdateNeck = NO;
    fixtureNow += 0.3;
    NSUInteger beforeManual = tracking.serialBox.requests.count;
    [tracking trackingPerson:@"recognized-face" x:0.8 y:0.8 z:-1];
    assert(tracking.serialBox.requests.count == beforeManual);
    tracking.serialBox.personTrackingMayUpdateNeck = YES;
    tracking.serialBox.commandedUpperNeckTiltTarget = 7000;
    tracking.torsoControlsViewController.headUpperNeckTilt.integerValue = 7000;
    fixtureNow += 0.3;
    [tracking trackingPerson:@"recognized-face" x:0.5 y:0.5 z:-1];
    assert(tracking.personTrackingUpperBaselineTarget == 7000);
    puts("ROB tracking source runtime fixtures passed: face ownership, pose fallback, stable acquisition, manual handoff");
} }
'''

for key, value in {
    "CONSTANTS": constants, "HELPERS": helpers,
    "PROPERTIES": "\n".join(properties.values()),
    "DECLARATIONS": "\n".join(m[:m.index("{")].strip() + ";" for m in methods),
    "PRODUCTION": production.replace("NSProcessInfo.processInfo.systemUptime", "fixtureNow")
        .replace("dispatch_async(dispatch_get_main_queue(),", "fixtureDispatch(dispatch_get_main_queue(),"),
}.items():
    harness = harness.replace("/* " + key + " */", value)

with tempfile.TemporaryDirectory(prefix="rob-tracking-source-") as directory:
    fixture = Path(directory) / "fixture.m"
    binary = Path(directory) / "ROBTrackingSourceFixture"
    fixture.write_text(harness)
    subprocess.run([
        "clang", "-fobjc-arc", "-framework", "Cocoa", "-I", str(ROOT / "Cerebro"),
        str(fixture), str(ROOT / "Cerebro/ROBPersonTrackingPolicy.c"),
        str(ROOT / "Cerebro/ROBNeckSafetyPolicy.c"), "-o", str(binary),
    ], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    if result.returncode:
        print(result.stdout + result.stderr)
        result.check_returncode()
    print(result.stdout, end="")
