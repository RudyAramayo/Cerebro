#!/usr/bin/env python3
"""Run the production cloud processor on synthetic depth, without robot or UI.

Only app services and geometry publication are inert substitutes. The candidate
gate and complete processing method are extracted verbatim from the controller.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Cerebro/ROBSCNViewController.m").read_text()
helpers = source[source.index("static NSUInteger const ROBMaximumDisplayedCloudPoints"):source.index("static NSString *ROBDiagnosticInhibitReason")]
status_method = source[source.index("- (void)refreshFloorStatus\n"):source.index("- (void)armTrialViewPrepared:")]
method = source[source.index("- (void)refreshFloorCloudVisibilityAtUptime:"):source.rindex("\n@end")]
HARNESS = r'''
#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>
#import <CoreVideo/CoreVideo.h>
#import "ROBDepthCloudProjection.h"
#import "ROBDepthFloorRectification.h"
#include <assert.h>
__HELPERS__
@interface ROBScanVisualModel : NSObject
+ (float)presentationScale;
@end
@implementation ROBScanVisualModel
+ (float)presentationScale { return 1.2f; }
@end
@interface ROBDepthCloudFrame : NSObject
@property NSInteger width, height;
@property BOOL isBelly, hasCalibratedIntrinsics;
@property double cameraFX, cameraFY, cameraCX, cameraCY, capturedUptime;
@property(strong) NSData *millimetersLittleEndian;
@property CVPixelBufferRef rgbPixelBuffer;
@end
@implementation ROBDepthCloudFrame @end
@interface ROBSerialBox : NSObject
@property BOOL isNeckCommandStateKnown;
@property NSInteger commandedLowerNeckTiltTarget, commandedNeckPanTarget, commandedUpperNeckTiltTarget;
@property double neckCommandReadyAtUptime;
@end
@implementation ROBSerialBox @end
@interface ROBLeftArmTrial : NSObject
@property BOOL isRunning;
+ (instancetype)shared;
@end
@implementation ROBLeftArmTrial
+ (instancetype)shared { static id v; if (!v) v=[self new]; return v; }
@end
@interface ROBArmRoutineCoordinator : ROBLeftArmTrial @end
@implementation ROBArmRoutineCoordinator
+ (instancetype)shared { static id v; if (!v) v=[self new]; return v; }
@end
@interface FixtureNode : NSObject
@property SCNMatrix4 worldTransform;
@property(strong) FixtureNode *presentationNode;
@property(strong) id geometry;
@property(getter=isHidden) BOOL hidden;
@end
@implementation FixtureNode @end
@interface FixtureGeometry : NSObject
@property(copy) NSArray<NSValue *> *points;
@property(copy) NSArray<NSNumber *> *colors;
@end
@implementation FixtureGeometry @end
@interface FixtureLabel : NSObject
@property(copy) NSString *stringValue;
@end
@implementation FixtureLabel @end
@interface Harness : NSObject
@property(strong) FixtureNode *robotNode;
@property(strong) SCNNode *liveRGBCloudNode, *liveBellyRGBCloudNode;
@property(strong) ROBSerialBox *serialBox;
@property BOOL cloudUpdatePending, bellyCloudUpdatePending;
@property double lastHeadCloudUptime, lastBellyCloudUptime;
@property double bellyCloudDisplayUntil;
@property BOOL headFloorAlignmentEstablished, bellyFloorAlignmentEstablished;
@property BOOL headFloorHoldingAcceptedFrame, bellyFloorHoldingAcceptedFrame;
@property BOOL headCloudHasCalibratedIntrinsics;
@property(copy) NSArray *headFloorCloudContext, *bellyFloorCloudContext;
@property(copy) NSString *headFloorSummary, *bellyFloorSummary;
@property(strong) NSArray<NSValue *> *capturedPoints;
@property(strong) NSArray<NSNumber *> *capturedColors;
@property(strong) FixtureLabel *cloudStatusLabel, *floorStatusLabel;
- (void)processDepthFrame:(ROBDepthCloudFrame *)frame robotTransform:(SCNMatrix4)robot cameraTransform:(ROBDepthCloudTransform)camera neckTargets:(NSArray<NSNumber *> *)targets;
- (void)refreshFloorCloudVisibilityAtUptime:(NSTimeInterval)now;
- (void)retainHeadCloudForDisplayAtUptime:(NSTimeInterval)now;
- (void)refreshFloorStatus;
@end
@implementation Harness
- (SCNGeometry *)pointGeometry:(NSArray *)p colors:(NSArray *)c pointSize:(CGFloat)s {
    self.capturedPoints=p; self.capturedColors=c;
    if(p.count==0) return nil;
    FixtureGeometry *g=[FixtureGeometry new]; g.points=p; g.colors=c; return (SCNGeometry *)(id)g;
}
__STATUS_METHOD__
__METHOD__
@end
static void drain(Harness *h) {
    double end=NSProcessInfo.processInfo.systemUptime+2;
    while ((h.cloudUpdatePending || h.bellyCloudUpdatePending) && NSProcessInfo.processInfo.systemUptime<end)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(!h.cloudUpdatePending && !h.bellyCloudUpdatePending);
}
static ROBDepthCloudFrame *frameAtHeight(double cameraHeight, double surfaceHeight, BOOL includeObject) {
    ROBDepthCloudFrame *f=[ROBDepthCloudFrame new]; f.width=160; f.height=160;
    f.hasCalibratedIntrinsics=YES; f.cameraFX=f.cameraFY=100; f.cameraCX=79.5; f.cameraCY=20;
    NSMutableData *d=[NSMutableData dataWithLength:160*160*2]; uint16_t *mm=d.mutableBytes;
    CVPixelBufferRef rgb=NULL; assert(CVPixelBufferCreate(NULL,160,160,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess); f.rgbPixelBuffer=rgb;
    CVPixelBufferLockBaseAddress(f.rgbPixelBuffer,0);
    for (int y=0;y<160;y++) for(int x=0;x<160;x++) {
        double height=surfaceHeight+(includeObject && y>=64 && y<=76 && x>=64 && x<=92 ? .3 : 0);
        double z=y>20 ? (cameraHeight-height)/((y-20)/100.) : 0;
        mm[y*160+x]=z>=.15 && z<=10 ? lround(z*1000) : 0;
        uint8_t *p=(uint8_t *)CVPixelBufferGetBaseAddress(f.rgbPixelBuffer)+y*CVPixelBufferGetBytesPerRow(f.rgbPixelBuffer)+4*x;
        p[0]=(x+y)%256; p[1]=y; p[2]=x; p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(f.rgbPixelBuffer,0); f.millimetersLittleEndian=d; return f;
}
static Harness *newHarness(SCNMatrix4 world) {
    Harness *h=[Harness new]; h.robotNode=[FixtureNode new]; h.robotNode.presentationNode=h.robotNode;
    // Typed as the production API; the dynamic objects remain inert geometry
    // holders so no SceneKit node/renderer is constructed by this fixture.
    h.liveRGBCloudNode=(SCNNode *)(id)[FixtureNode new]; h.liveBellyRGBCloudNode=(SCNNode *)(id)[FixtureNode new]; h.serialBox=[ROBSerialBox new];
    h.serialBox.isNeckCommandStateKnown=YES; h.serialBox.commandedLowerNeckTiltTarget=6011;
    h.serialBox.commandedNeckPanTarget=6000; h.serialBox.commandedUpperNeckTiltTarget=6306;
    h.cloudStatusLabel=[FixtureLabel new]; h.floorStatusLabel=[FixtureLabel new];
    h.robotNode.worldTransform=world; return h;
}
static void publish(Harness *h, ROBDepthCloudFrame *f, ROBDepthCloudTransform camera, NSArray *targets) {
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    if(f.isBelly) h.bellyCloudUpdatePending=YES; else h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:h.robotNode.worldTransform cameraTransform:camera neckTargets:targets]; drain(h);
}
static void assertHeadRetained(Harness *h, id geometry, double capturedAt, NSArray *context) {
    assert(!h.liveRGBCloudNode.hidden && h.liveRGBCloudNode.geometry==geometry && h.headFloorHoldingAcceptedFrame &&
        h.lastHeadCloudUptime==capturedAt &&
        [h.headFloorCloudContext isEqual:context]);
}
static void assertHeadAgeLabel(Harness *h, double minimumAge) {
    [h refreshFloorStatus];
    NSString *label=h.cloudStatusLabel.stringValue;
    NSString *prefix=@"HEAD DEPTH HELD: ";
    assert([label hasPrefix:prefix] && [label containsString:@"s old"] &&
        [label containsString:@"fixed at capture pose"] && [label containsString:@"display history"]);
    double reportedAge=[[label substringFromIndex:prefix.length] doubleValue];
    assert(reportedAge>=minimumAge && reportedAge<minimumAge+2);
    assert([h.floorStatusLabel.stringValue containsString:@"HELD"] &&
        [h.floorStatusLabel.stringValue containsString:@"s old at capture pose"]);
}
static ROBDepthCloudTransform tiltedCamera(double degrees) {
    double a=degrees*M_PI/180, c=cos(a), s=sin(a), scale=ROBScanVisualModel.presentationScale;
    double rows[12]={scale,0,0,0, 0,-scale*c,-scale*s,scale*(c+.08), 0,-scale*s,scale*c,scale*s};
    return ROBDepthCloudMakeTransform(rows);
}
static ROBDepthCloudFrame *noisyFrame(double noiseStepMeters) {
    ROBDepthCloudFrame *f=frameAtHeight(1,0,NO);
    NSMutableData *d=[f.millimetersLittleEndian mutableCopy]; uint16_t *mm=d.mutableBytes;
    for(int y=0;y<160;y++) for(int x=0;x<160;x++) {
        // .001m steps produce11mm fitted RMS; .0008m steps produce9.5mm.
        double height=(((x*197+y*179+x*y*11)%41)-20)*noiseStepMeters;
        double z=y>20 ? (1-height)/((y-20)/100.) : 0;
        mm[y*160+x]=z>=.15 && z<=10 ? lround(z*1000) : 0;
    }
    f.millimetersLittleEndian=d; return f;
}
int main(void) { @autoreleasepool {
    NSArray *targets=@[@6011,@6000,@6306]; double scale=ROBScanVisualModel.presentationScale;
    ROBDepthCloudTransform camera;
    SCNMatrix4 world=SCNMatrix4MakeRotation(.4,0,1,0); world.m41=3; world.m42=5; world.m43=-2;
    Harness *h=newHarness(world);
    // Before the first capture, absent geometry is hidden rather than shown
    // as a live or retained depth view merely because no age deadline exists.
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    [h refreshFloorStatus];
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && !h.headFloorHoldingAcceptedFrame && h.lastHeadCloudUptime==0);
    assert([h.cloudStatusLabel.stringValue hasPrefix:@"HEAD DEPTH HIDDEN:"] &&
        ![h.cloudStatusLabel.stringValue containsString:@"HELD"] &&
        ![h.cloudStatusLabel.stringValue containsString:@"live captured view"] &&
        [h.floorStatusLabel.stringValue containsString:@"CLOUD HIDDEN"]);
    ROBDepthCloudFrame *f=frameAtHeight(1,0,YES);
    // The old fixed +/-0.30m candidate-height gate passed8degrees but clipped
    // the25degree floor to0.16m depth coverage, making a valid floor unfit.
    // Exercise the complete production selector, fitter and geometry path.
    const double tilts[]={8,25,29};
    for (NSUInteger trial=0;trial<sizeof(tilts)/sizeof(tilts[0]);trial++) {
        camera=tiltedCamera(tilts[trial]);
        f.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
        [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:targets]; drain(h);
        assert(!h.liveRGBCloudNode.hidden && h.liveRGBCloudNode.geometry && [h.headFloorSummary containsString:@"aligned"]);
        NSUInteger index=0, floorCount=0; double floorError=0, floorSquared=0, objectError=0;
        const uint16_t *mm=f.millimetersLittleEndian.bytes;
        for(int y=0;y<160;y+=4) for(int x=0;x<160;x+=4) if(mm[y*160+x]>=150 && mm[y*160+x]<=10000) {
            assert(index<h.capturedPoints.count); SCNVector3 p=h.capturedPoints[index].SCNVector3Value;
            double height=(y>=64 && y<=76 && x>=64 && x<=92) ? .3 : 0;
            double error=fabs(p.y-(5+scale*height)); if(height) objectError=fmax(objectError,error); else { floorError=fmax(floorError,error); floorSquared+=error*error; floorCount++; }
            uint32_t color=((uint32_t)x<<24)|((uint32_t)y<<16)|((uint32_t)((x+y)%256)<<8)|255;
            assert(h.capturedColors[index].unsignedIntValue==color); index++;
        }
        assert(index==h.capturedPoints.count && index==h.capturedColors.count && floorError<.004 && sqrt(floorSquared/floorCount)<.0015 && objectError<.002);
    }
    // A normal-height tabletop has ample lower-image/range candidates, but
    // remains outside the fitter's floor-height bound even after bootstrapping.
    ROBDepthCloudFrame *table=frameAtHeight(1.8,.75,NO);
    double tableRows[12]={scale,0,0,0, 0,-scale,0,scale*1.8, 0,0,scale,0};
    Harness *raw=newHarness(world);
    publish(raw,table,ROBDepthCloudMakeTransform(tableRows),targets);
    assert(raw.capturedPoints.count>500 && [raw.headFloorSummary containsString:@"raw cloud"] &&
        [raw.headFloorSummary containsString:@"no plane within floor tilt/height bounds"] && !raw.headFloorAlignmentEstablished);
    for(NSValue *value in raw.capturedPoints) assert(fabs(value.SCNVector3Value.y-(5+scale*.75))<.002);
    id acceptedGeometry=h.liveRGBCloudNode.geometry;
    double acceptedAt=h.lastHeadCloudUptime;
    NSArray *acceptedContext=h.headFloorCloudContext;
    NSArray *acceptedWorldPoints=[((FixtureGeometry *)(id)acceptedGeometry).points copy];
    publish(h,table,ROBDepthCloudMakeTransform(tableRows),targets);
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    assert(h.headFloorAlignmentEstablished && ![h.headFloorSummary containsString:@"raw cloud"]);

    // Retain a previously published raw HEAD frame too, before the first floor
    // alignment. Invalid input cannot replace it with nil or renew its age.
    ROBDepthCloudFrame *invalid=[ROBDepthCloudFrame new]; invalid.width=160; invalid.height=160;
    invalid.millimetersLittleEndian=[NSData data];
    id rawGeometry=raw.liveRGBCloudNode.geometry;
    double rawAt=raw.lastHeadCloudUptime; NSArray *rawContext=raw.headFloorCloudContext;
    publish(raw,invalid,ROBDepthCloudMakeTransform(tableRows),targets);
    assertHeadRetained(raw,rawGeometry,rawAt,rawContext);
    assert(!raw.headFloorAlignmentEstablished);
    ROBDepthCloudFrame *missing=[ROBDepthCloudFrame new]; missing.width=160; missing.height=160;
    missing.millimetersLittleEndian=[NSMutableData dataWithLength:160*160*2];
    publish(raw,missing,ROBDepthCloudMakeTransform(tableRows),targets);
    assertHeadRetained(raw,rawGeometry,rawAt,rawContext);
    for(NSNumber *age in @[@4,@60,@86400]) {
        [raw refreshFloorCloudVisibilityAtUptime:rawAt+age.doubleValue];
        assertHeadRetained(raw,rawGeometry,rawAt,rawContext);
    }
    // Seed an old captured timestamp to exercise the actual HUD without a
    // wall-clock delay. Geometry/context remain the same accepted raw frame.
    rawAt=NSProcessInfo.processInfo.systemUptime-86400; raw.lastHeadCloudUptime=rawAt;
    publish(raw,invalid,ROBDepthCloudMakeTransform(tableRows),targets);
    assertHeadRetained(raw,rawGeometry,rawAt,rawContext);
    assertHeadAgeLabel(raw,86400);
    assert(!raw.headFloorAlignmentEstablished);
    publish(raw,f,camera,targets);
    assert(raw.liveRGBCloudNode.geometry!=rawGeometry && !raw.liveRGBCloudNode.hidden &&
        !raw.headFloorHoldingAcceptedFrame && raw.headFloorAlignmentEstablished && raw.lastHeadCloudUptime==f.capturedUptime);
    CVPixelBufferRelease(table.rgbPixelBuffer);

    camera=tiltedCamera(8);
    // The display allows10mm fitted RMS; the pure fitter keeps its9mm default.
    assert(ROBDepthFloorDefaultOptions().maximumRMSMeters==.009);
    ROBDepthCloudFrame *nearBudget=noisyFrame(.0008);
    publish(h,nearBudget,camera,targets);
    assert(!h.liveRGBCloudNode.hidden && h.liveRGBCloudNode.geometry && !h.headFloorHoldingAcceptedFrame &&
        h.lastHeadCloudUptime==nearBudget.capturedUptime && [h.headFloorSummary containsString:@"aligned"]);
    NSRange rmsSuffix=[h.headFloorSummary rangeOfString:@" mm RMS"];
    assert(rmsSuffix.location!=NSNotFound);
    NSString *rmsPrefix=[h.headFloorSummary substringToIndex:rmsSuffix.location];
    double reportedRMS=[[rmsPrefix componentsSeparatedByString:@" · "].lastObject doubleValue];
    assert(reportedRMS>=9.3 && reportedRMS<=9.7);
    ROBDepthCloudFrame *noise=noisyFrame(.001);
    ROBDepthCloudFrame *empty=frameAtHeight(1,0,NO);
    empty.millimetersLittleEndian=[NSMutableData dataWithLength:160*160*2];
    empty.hasCalibratedIntrinsics=NO;
    publish(h,f,camera,targets);
    acceptedGeometry=h.liveRGBCloudNode.geometry; acceptedAt=h.lastHeadCloudUptime;
    acceptedContext=h.headFloorCloudContext;
    acceptedWorldPoints=[((FixtureGeometry *)(id)acceptedGeometry).points copy];
    for(ROBDepthCloudFrame *rejected in @[noise,empty,invalid,noise]) {
        publish(h,rejected,camera,targets);
        assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
        assert([((FixtureGeometry *)(id)acceptedGeometry).points isEqual:acceptedWorldPoints]);
        assert(h.headCloudHasCalibratedIntrinsics && "Rejected input relabeled a calibrated retained frame");
    }
    assert([h.headFloorSummary containsString:@"floor residual noise is too high"] && ![h.headFloorSummary containsString:@"raw cloud"]);

    // Current neck commands never reproject old world vertices. Settling,
    // unknown state, epochs and wrong-target inputs retain the captured frame.
    h.serialBox.commandedUpperNeckTiltTarget++;
    h.serialBox.neckCommandReadyAtUptime=NSProcessInfo.processInfo.systemUptime+1;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    publish(h,f,camera,targets); // Fresh image, but wrong current target.
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    NSArray *newTargets=@[@6011,@6000,@6307];
    publish(h,f,camera,newTargets); // Matching target, captured before settling.
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    h.serialBox.isNeckCommandStateKnown=NO;
    publish(h,f,camera,newTargets);
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    h.serialBox.isNeckCommandStateKnown=YES;
    h.serialBox.neckCommandReadyAtUptime=NSProcessInfo.processInfo.systemUptime-.001;
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime-1; h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:newTargets]; drain(h);
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    assert([((FixtureGeometry *)(id)acceptedGeometry).points isEqual:acceptedWorldPoints]);
    publish(h,f,camera,newTargets); // A genuinely fresh, settled frame replaces it.
    assert(h.liveRGBCloudNode.geometry!=acceptedGeometry && !h.headFloorHoldingAcceptedFrame &&
        h.lastHeadCloudUptime==f.capturedUptime &&
        ![h.headFloorCloudContext isEqual:acceptedContext]);
    h.serialBox.commandedUpperNeckTiltTarget--; h.serialBox.neckCommandReadyAtUptime=0;
    publish(h,f,camera,targets);
    acceptedGeometry=h.liveRGBCloudNode.geometry; acceptedAt=h.lastHeadCloudUptime; acceptedContext=h.headFloorCloudContext;

    // New intrinsics/mount with a rejected fit do not mutate the retained
    // accepted world geometry or its capture context.
    noise.cameraFX++;
    publish(h,noise,camera,targets); assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    noise.cameraFX--;
    ROBDepthCloudTransform changedCamera=camera; changedCamera.m[3]+=.01;
    publish(h,noise,changedCamera,targets); assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    [h refreshFloorCloudVisibilityAtUptime:acceptedAt+.8];
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    for(NSNumber *age in @[@4,@60,@86400]) {
        [h refreshFloorCloudVisibilityAtUptime:acceptedAt+age.doubleValue];
        assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
        assert([((FixtureGeometry *)(id)acceptedGeometry).points isEqual:acceptedWorldPoints]);
    }
    // Rejected fits retain even a day-old captured aligned frame and must not
    // renew its original timestamp, change context, or relabel it as live.
    acceptedAt=NSProcessInfo.processInfo.systemUptime-86400; h.lastHeadCloudUptime=acceptedAt;
    publish(h,noise,camera,targets);
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    assert([((FixtureGeometry *)(id)acceptedGeometry).points isEqual:acceptedWorldPoints]);
    assertHeadAgeLabel(h,86400);
    assert(![h.headFloorSummary containsString:@"raw cloud"]);
    publish(h,f,camera,targets);
    assert(h.liveRGBCloudNode.geometry!=acceptedGeometry && !h.liveRGBCloudNode.hidden &&
        !h.headFloorHoldingAcceptedFrame && h.lastHeadCloudUptime==f.capturedUptime && h.lastHeadCloudUptime>acceptedAt);
    [h refreshFloorStatus];
    assert([h.cloudStatusLabel.stringValue containsString:@"live captured view"] &&
        ![h.cloudStatusLabel.stringValue containsString:@"HELD"]);

    // BELLY keeps its existing250ms noise-only hold and700ms normal freshness.
    Harness *belly=newHarness(world);
    f.isBelly=YES; noise.isBelly=YES; empty.isBelly=YES;
    publish(belly,f,camera,targets);
    id bellyGeometry=belly.liveBellyRGBCloudNode.geometry; double bellyAt=belly.lastBellyCloudUptime;
    publish(belly,noise,camera,targets);
    assert(!belly.liveBellyRGBCloudNode.hidden && belly.liveBellyRGBCloudNode.geometry==bellyGeometry &&
        belly.bellyFloorHoldingAcceptedFrame && belly.lastBellyCloudUptime==bellyAt &&
        fabs(belly.bellyCloudDisplayUntil-(bellyAt+.25))<1e-9);
    [belly refreshFloorCloudVisibilityAtUptime:bellyAt+.251];
    assert(belly.liveBellyRGBCloudNode.hidden && !belly.liveBellyRGBCloudNode.geometry && belly.lastBellyCloudUptime==bellyAt);
    publish(belly,noise,camera,targets); assert(!belly.liveBellyRGBCloudNode.geometry && ![belly.bellyFloorSummary containsString:@"raw cloud"]);
    publish(belly,f,camera,targets); bellyAt=belly.lastBellyCloudUptime;
    publish(belly,noise,camera,targets); assert(belly.bellyFloorHoldingAcceptedFrame);
    publish(belly,empty,camera,targets);
    assert(belly.liveBellyRGBCloudNode.hidden && !belly.liveBellyRGBCloudNode.geometry &&
        !belly.bellyFloorHoldingAcceptedFrame && belly.lastBellyCloudUptime==bellyAt);
    publish(belly,noise,camera,targets); assert(!belly.liveBellyRGBCloudNode.geometry);
    publish(belly,f,camera,targets); bellyAt=belly.lastBellyCloudUptime;
    [belly refreshFloorCloudVisibilityAtUptime:bellyAt+.701];
    assert(!belly.liveBellyRGBCloudNode.geometry && belly.lastBellyCloudUptime==bellyAt);
    f.isBelly=NO; noise.isBelly=NO; empty.isBelly=NO;

    // Per-camera histories are independent: the HEAD snapshot persists after
    // BELLY expires; neck moves do not alter the belly's fixed captured points.
    publish(h,f,camera,targets);
    acceptedGeometry=h.liveRGBCloudNode.geometry; acceptedAt=h.lastHeadCloudUptime; acceptedContext=h.headFloorCloudContext;
    f.isBelly=YES; publish(h,f,camera,targets); f.isBelly=NO;
    bellyGeometry=h.liveBellyRGBCloudNode.geometry; bellyAt=h.lastBellyCloudUptime;
    h.serialBox.neckCommandReadyAtUptime=NSProcessInfo.processInfo.systemUptime+1;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    assert(h.liveBellyRGBCloudNode.geometry==bellyGeometry && !h.liveBellyRGBCloudNode.hidden);
    [h refreshFloorCloudVisibilityAtUptime:fmax(acceptedAt,bellyAt)+.8];
    assertHeadRetained(h,acceptedGeometry,acceptedAt,acceptedContext);
    assert(!h.liveBellyRGBCloudNode.geometry);
    h.serialBox.neckCommandReadyAtUptime=0;

    // Base movement invalidates world placement. Arm operation flags alone do
    // not blank the display or prevent genuinely fresh clouds from publishing.
    // Neither time, retained histories nor rejected input can resurrect a
    // cleared cloud; only a genuinely fresh settled frame may replace it.
    publish(h,f,camera,targets);
    acceptedAt=h.lastHeadCloudUptime;
    SCNMatrix4 moved=world; moved.m41++; h.robotNode.worldTransform=moved;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(!h.liveRGBCloudNode.geometry && !h.liveBellyRGBCloudNode.geometry && h.headFloorAlignmentEstablished);
    [h retainHeadCloudForDisplayAtUptime:acceptedAt+86400];
    publish(h,noise,camera,targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && !h.headFloorHoldingAcceptedFrame && h.lastHeadCloudUptime==acceptedAt);
    h.robotNode.worldTransform=world;
    publish(h,noise,camera,targets);
    assert(!h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==acceptedAt);
    publish(h,f,camera,targets);
    assert(!h.liveRGBCloudNode.hidden && h.liveRGBCloudNode.geometry && !h.headFloorHoldingAcceptedFrame && h.lastHeadCloudUptime==f.capturedUptime);
    acceptedAt=h.lastHeadCloudUptime;
    f.isBelly=YES; publish(h,f,camera,targets); f.isBelly=NO;
    ROBLeftArmTrial.shared.isRunning=YES;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(h.liveRGBCloudNode.geometry && h.liveBellyRGBCloudNode.geometry);
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    publish(h,f,camera,targets);
    assert(!h.liveRGBCloudNode.hidden && h.lastHeadCloudUptime==f.capturedUptime);
    ROBLeftArmTrial.shared.isRunning=NO;
    publish(h,f,camera,targets);
    assert(!h.liveRGBCloudNode.hidden && h.liveRGBCloudNode.geometry && !h.headFloorHoldingAcceptedFrame && h.lastHeadCloudUptime==f.capturedUptime);
    acceptedAt=h.lastHeadCloudUptime;
    ROBArmRoutineCoordinator.shared.isRunning=YES;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(h.liveRGBCloudNode.geometry);
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    publish(h,f,camera,targets);
    assert(!h.liveRGBCloudNode.hidden && h.lastHeadCloudUptime==f.capturedUptime);
    ROBArmRoutineCoordinator.shared.isRunning=NO;
    publish(h,f,camera,targets);
    assert(!h.liveRGBCloudNode.hidden && h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==f.capturedUptime);
    ROBDepthCloudFrame *cap=[ROBDepthCloudFrame new]; cap.width=566; cap.height=565;
    NSMutableData *dense=[NSMutableData dataWithLength:566*565*2]; for(int i=0;i<566*565;i++) ((uint16_t *)dense.mutableBytes)[i]=1000;
    cap.millimetersLittleEndian=dense; cap.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:cap robotTransform:world cameraTransform:camera neckTargets:targets];
    assert(h.capturedPoints.count>0 && h.capturedPoints.count<=20000 && h.capturedPoints.count==h.capturedColors.count);
    drain(h);
    h.liveRGBCloudNode.geometry=nil; cap.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:cap robotTransform:world cameraTransform:camera neckTargets:targets]; h.robotNode.worldTransform=moved; drain(h);
    assert(!h.liveRGBCloudNode.geometry);
    CVPixelBufferRelease(nearBudget.rgbPixelBuffer); CVPixelBufferRelease(noise.rgbPixelBuffer); CVPixelBufferRelease(empty.rgbPixelBuffer);
    CVPixelBufferRelease(f.rgbPixelBuffer); puts("Production depth-floor integration passed:8/25/29degree floor bootstrap, rigid0.3m object height, tabletop rejection,9.5mm acceptance, HEAD captured-world retention with age labels and fresh replacement during arm operations, unchanged BELLY250ms noise hold/700ms freshness, no resurrection after base clears, independent cameras, RGB pairing and20k cap");
} return 0; }
'''


def main():
    with tempfile.TemporaryDirectory(prefix="cerebro-depth-floor-integration-") as folder:
        harness = Path(folder) / "integration.m"
        harness.write_text(HARNESS.replace("__HELPERS__", helpers).replace("__STATUS_METHOD__", status_method).replace("__METHOD__", method))
        binary = Path(folder) / "integration"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", "-framework", "SceneKit", "-framework", "CoreVideo", "-I", str(ROOT / "Cerebro"), str(harness), "-o", str(binary)], check=True, timeout=120)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
