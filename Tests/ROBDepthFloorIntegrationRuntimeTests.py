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
@interface Harness : NSObject
@property(strong) FixtureNode *robotNode;
@property(strong) SCNNode *liveRGBCloudNode, *liveBellyRGBCloudNode;
@property(strong) ROBSerialBox *serialBox;
@property BOOL cloudUpdatePending, bellyCloudUpdatePending;
@property double lastHeadCloudUptime, lastBellyCloudUptime;
@property double headCloudDisplayUntil, bellyCloudDisplayUntil;
@property BOOL headFloorAlignmentEstablished, bellyFloorAlignmentEstablished;
@property BOOL headFloorHoldingAcceptedFrame, bellyFloorHoldingAcceptedFrame;
@property(copy) NSArray *headFloorCloudContext, *bellyFloorCloudContext;
@property(copy) NSString *headFloorSummary, *bellyFloorSummary;
@property(strong) NSArray<NSValue *> *capturedPoints;
@property(strong) NSArray<NSNumber *> *capturedColors;
- (void)processDepthFrame:(ROBDepthCloudFrame *)frame robotTransform:(SCNMatrix4)robot cameraTransform:(ROBDepthCloudTransform)camera neckTargets:(NSArray<NSNumber *> *)targets;
- (void)refreshFloorCloudVisibilityAtUptime:(NSTimeInterval)now;
@end
@implementation Harness
- (SCNGeometry *)pointGeometry:(NSArray *)p colors:(NSArray *)c pointSize:(CGFloat)s {
    self.capturedPoints=p; self.capturedColors=c; return (SCNGeometry *)[NSObject new];
}
- (void)refreshFloorStatus {}
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
    h.robotNode.worldTransform=world; return h;
}
static void publish(Harness *h, ROBDepthCloudFrame *f, ROBDepthCloudTransform camera, NSArray *targets) {
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    if(f.isBelly) h.bellyCloudUpdatePending=YES; else h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:h.robotNode.worldTransform cameraTransform:camera neckTargets:targets]; drain(h);
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
    double acceptedBeforeTable=h.lastHeadCloudUptime;
    publish(h,table,ROBDepthCloudMakeTransform(tableRows),targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.headFloorAlignmentEstablished &&
        h.lastHeadCloudUptime==acceptedBeforeTable && ![h.headFloorSummary containsString:@"raw cloud"]);
    CVPixelBufferRelease(table.rgbPixelBuffer);

    // Once this view has aligned, a noisy fit never publishes fresh raw points.
    // Hold the actual accepted geometry, with its original capture timestamp.
    camera=tiltedCamera(8);
    // The production display allows10mm RMS while the pure fitter retains its
    // default9mm limit. This real processor case exercises the added1mm budget.
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
    publish(h,f,camera,targets);
    id acceptedGeometry=h.liveRGBCloudNode.geometry;
    double acceptedAt=h.lastHeadCloudUptime;
    publish(h,noise,camera,targets);
    assert(h.headFloorHoldingAcceptedFrame && !h.liveRGBCloudNode.hidden && h.liveRGBCloudNode.geometry==acceptedGeometry &&
        h.lastHeadCloudUptime==acceptedAt && fabs(h.headCloudDisplayUntil-(acceptedAt+.25))<1e-9 &&
        [h.headFloorSummary containsString:@"floor residual noise is too high"] && ![h.headFloorSummary containsString:@"raw cloud"]);
    publish(h,noise,camera,targets);
    assert(h.liveRGBCloudNode.geometry==acceptedGeometry && h.lastHeadCloudUptime==acceptedAt &&
        fabs(h.headCloudDisplayUntil-(acceptedAt+.25))<1e-9);
    // Timer-only expiry works when no further camera frame arrives.
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.28]];
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && !h.headFloorHoldingAcceptedFrame &&
        h.lastHeadCloudUptime==acceptedAt && h.headFloorAlignmentEstablished);
    publish(h,noise,camera,targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==acceptedAt &&
        ![h.headFloorSummary containsString:@"raw cloud"]);

    // Non-noise rejection removes the held picture immediately. Subsequent
    // noise cannot resurrect it, even within the old quarter-second window.
    ROBDepthCloudFrame *empty=frameAtHeight(1,0,NO);
    empty.millimetersLittleEndian=[NSMutableData dataWithLength:160*160*2];
    publish(h,f,camera,targets); acceptedAt=h.lastHeadCloudUptime;
    publish(h,noise,camera,targets); assert(h.headFloorHoldingAcceptedFrame);
    publish(h,empty,camera,targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && !h.headFloorHoldingAcceptedFrame &&
        h.lastHeadCloudUptime==acceptedAt && h.headFloorAlignmentEstablished && ![h.headFloorSummary containsString:@"raw cloud"]);
    publish(h,noise,camera,targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==acceptedAt);

    // Head and belly retain independent accepted pictures and histories.
    publish(h,f,camera,targets);
    f.isBelly=YES; publish(h,f,camera,targets); f.isBelly=NO;
    id acceptedBelly=h.liveBellyRGBCloudNode.geometry;
    double bellyAcceptedAt=h.lastBellyCloudUptime;
    assert(acceptedBelly && h.bellyFloorAlignmentEstablished);
    publish(h,noise,camera,targets);
    assert(h.headFloorHoldingAcceptedFrame && h.liveBellyRGBCloudNode.geometry==acceptedBelly &&
        !h.liveBellyRGBCloudNode.hidden && h.lastBellyCloudUptime==bellyAcceptedAt);
    // A new settling epoch invalidates the old head picture even if all raw
    // targets are identical; the fixed belly view is unaffected.
    acceptedAt=h.lastHeadCloudUptime;
    h.serialBox.neckCommandReadyAtUptime=NSProcessInfo.processInfo.systemUptime-.001;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==acceptedAt &&
        h.liveBellyRGBCloudNode.geometry==acceptedBelly && !h.liveBellyRGBCloudNode.hidden && h.headFloorAlignmentEstablished);
    publish(h,noise,camera,targets);
    assert(!h.liveRGBCloudNode.geometry && ![h.headFloorSummary containsString:@"raw cloud"]);
    h.serialBox.neckCommandReadyAtUptime=0;
    publish(h,f,camera,targets);
    SCNMatrix4 moved=world; moved.m41++;
    h.robotNode.worldTransform=moved;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(!h.liveRGBCloudNode.geometry && !h.liveBellyRGBCloudNode.geometry &&
        h.headFloorAlignmentEstablished && h.bellyFloorAlignmentEstablished);
    h.robotNode.worldTransform=world;

    // A changed intrinsic calibration or optical mount must not borrow an old
    // accepted frame while the newly fitted floor is noise-rejected.
    publish(h,f,camera,targets); acceptedAt=h.lastHeadCloudUptime;
    noise.cameraFX++;
    publish(h,noise,camera,targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==acceptedAt);
    noise.cameraFX--;
    publish(h,f,camera,targets); acceptedAt=h.lastHeadCloudUptime;
    ROBDepthCloudTransform changedCamera=camera; changedCamera.m[3]+=.01;
    publish(h,noise,changedCamera,targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==acceptedAt);

    publish(h,f,camera,targets); acceptedAt=h.lastHeadCloudUptime;
    ROBDepthCloudFrame *invalid=[ROBDepthCloudFrame new]; invalid.width=160; invalid.height=160;
    invalid.millimetersLittleEndian=[NSData data];
    publish(h,invalid,camera,targets);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.lastHeadCloudUptime==acceptedAt);
    publish(h,noise,camera,targets); assert(!h.liveRGBCloudNode.geometry && ![h.headFloorSummary containsString:@"raw cloud"]);
    publish(h,f,camera,targets);
    h.serialBox.isNeckCommandStateKnown=NO;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry && h.headFloorAlignmentEstablished);
    h.serialBox.isNeckCommandStateKnown=YES;
    publish(h,f,camera,targets);
    f.isBelly=YES; publish(h,f,camera,targets); f.isBelly=NO;
    ROBLeftArmTrial.shared.isRunning=YES;
    [h refreshFloorCloudVisibilityAtUptime:NSProcessInfo.processInfo.systemUptime];
    assert(!h.liveRGBCloudNode.geometry && !h.liveBellyRGBCloudNode.geometry &&
        h.headFloorAlignmentEstablished && h.bellyFloorAlignmentEstablished);
    ROBLeftArmTrial.shared.isRunning=NO;

    publish(h,f,camera,targets);
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:targets]; h.serialBox.commandedUpperNeckTiltTarget++; drain(h);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry); h.serialBox.commandedUpperNeckTiltTarget--;
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime-1; h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:targets]; drain(h); assert(h.liveRGBCloudNode.hidden);
    f.millimetersLittleEndian=[NSMutableData dataWithLength:160*160*2]; f.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:targets]; drain(h);
    assert(h.capturedPoints.count==0 && h.capturedColors.count==0 && h.liveRGBCloudNode.hidden &&
        !h.liveRGBCloudNode.geometry && ![h.headFloorSummary containsString:@"raw cloud"]);
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
    CVPixelBufferRelease(f.rgbPixelBuffer); puts("Production depth-floor integration passed:8/25/29degree floor bootstrap, rigid0.3m object height, tabletop rejection,9.5mm display budget acceptance,11mm rejection/250ms hold/timer expiry, no raw resurrection, independent cameras, pose/epoch/intrinsic/mount invalidation, RGB pairing,20k cap and stale rejection");
} return 0; }
'''


def main():
    with tempfile.TemporaryDirectory(prefix="cerebro-depth-floor-integration-") as folder:
        harness = Path(folder) / "integration.m"
        harness.write_text(HARNESS.replace("__HELPERS__", helpers).replace("__METHOD__", method))
        binary = Path(folder) / "integration"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", "-framework", "SceneKit", "-framework", "CoreVideo", "-I", str(ROOT / "Cerebro"), str(harness), "-o", str(binary)], check=True, timeout=120)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
