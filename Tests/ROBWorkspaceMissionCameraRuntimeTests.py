#!/usr/bin/env python3
"""Run the actual workspace camera callback with inert controller adapters."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Cerebro/ROBMainViewController.mm").read_text()
start = source.index("workspace.prepareView = ^BOOL(double pan, NSInteger upper) {")
end = source.index("\n    workspace.viewReady", start)
callback = source[start:end].replace("workspace.prepareView =", "BOOL (^prepare)(double, NSInteger) =", 1)

fixture = r'''
#import <Foundation/Foundation.h>
enum { NSControlStateValueOff = 0 };
@interface State : NSObject
@property BOOL active, isRunning, isPreparingPreviewedCanObservation, isArmed, ownsWorkspaceSearchView;
- (void)stopWithReason:(NSString *)reason;
@end
@implementation State
- (void)stopWithReason:(NSString *)reason { self.active = NO; }
@end
#define SINGLETON(Name) \
@interface Name : State + (instancetype)shared; @end \
@implementation Name + (instancetype)shared { static Name *value; if (!value) value = [Name new]; return value; } @end
SINGLETON(ROBLeftArmTrial)
SINGLETON(ROBNeckQRCalibration)
SINGLETON(ROBAmberStackMaintenanceController)
SINGLETON(ROBTorsoControlCenter)
SINGLETON(ROBRecycleMissionCoordinator)
@interface Checkbox : NSObject @property NSInteger state; @end
@implementation Checkbox @end
@interface Controls : NSObject @property Checkbox *headTracking_enabled; @end
@implementation Controls @end
@interface Serial : NSObject
@property NSInteger calls, stops, upper;
@property double pan;
- (void)stopBaseMotionAndDropHeartbeat;
- (BOOL)prepareNeckForWorkspaceSearchWithPanDegrees:(double)pan upperTarget:(NSInteger)upper;
@end
@implementation Serial
- (void)stopBaseMotionAndDropHeartbeat { self.stops++; }
- (BOOL)prepareNeckForWorkspaceSearchWithPanDegrees:(double)pan upperTarget:(NSInteger)upper {
    self.calls++; self.pan = pan; self.upper = upper; return YES;
}
@end
@interface ROBMainViewController : NSObject
@property Serial *serialBox;
@property State *stageShowCoordinator, *autonomyCoordinator, *followPersonCoordinator;
@property NSArray *pendingRobotActionRequests;
@property Controls *torsoControlsViewController;
@end
@implementation ROBMainViewController @end
#define CHECK(value, message) do { if (!(value)) { fprintf(stderr, "%s\n", message); return 1; } } while (0)
int main(void) { @autoreleasepool {
    ROBMainViewController *controller = [ROBMainViewController new];
    controller.serialBox = [Serial new]; controller.stageShowCoordinator = [State new];
    controller.autonomyCoordinator = [State new]; controller.followPersonCoordinator = [State new];
    controller.pendingRobotActionRequests = @[]; controller.torsoControlsViewController = [Controls new];
    controller.torsoControlsViewController.headTracking_enabled = [Checkbox new];
    controller.torsoControlsViewController.headTracking_enabled.state = 1;
    controller.autonomyCoordinator.active = YES; controller.followPersonCoordinator.active = YES;
    __weak ROBMainViewController *weakSelf = controller;
    __block BOOL armViewPreparationStarted = NO;
    CALLBACK
    CHECK(!prepare(-30, 6306) && controller.serialBox.calls == 0, "Ownerless search moved the camera");
    [ROBRecycleMissionCoordinator shared].ownsWorkspaceSearchView = YES;
    CHECK(prepare(-30, 6306), "Active recycling survey could not prepare its camera view");
    CHECK(controller.serialBox.calls == 1 && controller.serialBox.pan == -30 && controller.serialBox.upper == 6306,
          "Survey camera demand was lost or changed");
    CHECK(controller.serialBox.stops == 1 && !controller.autonomyCoordinator.active && !controller.followPersonCoordinator.active
          && controller.torsoControlsViewController.headTracking_enabled.state == 0, "Survey did not stop competing base/head owners");
    CHECK(prepare(0, 6306) && controller.serialBox.stops == 1, "Next survey view repeated control takeover");
    NSInteger accepted = controller.serialBox.calls;
    [ROBRecycleMissionCoordinator shared].ownsWorkspaceSearchView = NO;
    CHECK(!prepare(30, 6306), "Ended mission retained camera control");
    [ROBRecycleMissionCoordinator shared].ownsWorkspaceSearchView = YES;
    controller.stageShowCoordinator.isRunning = YES;
    CHECK(!prepare(30, 6306), "Survey displaced a stage show"); controller.stageShowCoordinator.isRunning = NO;
    controller.pendingRobotActionRequests = @[@1];
    CHECK(!prepare(30, 6306), "Survey bypassed pending operator action"); controller.pendingRobotActionRequests = @[];
    [ROBAmberStackMaintenanceController shared].isRunning = YES;
    CHECK(!prepare(30, 6306), "Survey ran during controller maintenance"); [ROBAmberStackMaintenanceController shared].isRunning = NO;
    [ROBTorsoControlCenter shared].isArmed = YES;
    CHECK(!prepare(30, 6306), "Survey captured during torso control"); [ROBTorsoControlCenter shared].isArmed = NO;
    CHECK(controller.serialBox.calls == accepted, "Rejected survey dispatched a neck command");
    [ROBRecycleMissionCoordinator shared].ownsWorkspaceSearchView = NO;
    [ROBLeftArmTrial shared].isRunning = YES;
    CHECK(prepare(0, 6306), "Existing arm trial lost camera control"); [ROBLeftArmTrial shared].isRunning = NO;
    [ROBNeckQRCalibration shared].isRunning = YES;
    CHECK(prepare(0, 6306), "Existing calibration lost camera control");
    puts("PASS production workspace callback: recycling survey, target delivery, owner expiry, competing owners, maintenance and torso guards; no hardware");
} return 0; }
'''.replace("CALLBACK", callback)

with tempfile.TemporaryDirectory(prefix="rob-mission-camera-") as folder:
    path = Path(folder)
    (path / "fixture.mm").write_text(fixture)
    subprocess.run(["xcrun", "clang++", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    str(path / "fixture.mm"), "-o", str(path / "fixture")], check=True)
    subprocess.run([str(path / "fixture")], check=True)
