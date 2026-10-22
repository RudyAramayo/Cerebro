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
method = source[source.index("- (void)processDepthFrame:"):source.rindex("\n@end")]
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
@property BOOL hidden;
@end
@implementation FixtureNode @end
@interface Harness : NSObject
@property(strong) FixtureNode *robotNode, *liveRGBCloudNode, *liveBellyRGBCloudNode;
@property(strong) ROBSerialBox *serialBox;
@property BOOL cloudUpdatePending, bellyCloudUpdatePending;
@property double lastHeadCloudUptime, lastBellyCloudUptime;
@property(copy) NSString *headFloorSummary, *bellyFloorSummary;
@property(strong) NSArray<NSValue *> *capturedPoints;
@property(strong) NSArray<NSNumber *> *capturedColors;
- (void)processDepthFrame:(ROBDepthCloudFrame *)frame robotTransform:(SCNMatrix4)robot cameraTransform:(ROBDepthCloudTransform)camera neckTargets:(NSArray<NSNumber *> *)targets;
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
    while (h.cloudUpdatePending && NSProcessInfo.processInfo.systemUptime<end)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(!h.cloudUpdatePending);
}
static ROBDepthCloudFrame *frame(void) {
    ROBDepthCloudFrame *f=[ROBDepthCloudFrame new]; f.width=160; f.height=160;
    f.hasCalibratedIntrinsics=YES; f.cameraFX=f.cameraFY=100; f.cameraCX=79.5; f.cameraCY=20;
    NSMutableData *d=[NSMutableData dataWithLength:160*160*2]; uint16_t *mm=d.mutableBytes;
    CVPixelBufferRef rgb=NULL; assert(CVPixelBufferCreate(NULL,160,160,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess); f.rgbPixelBuffer=rgb;
    CVPixelBufferLockBaseAddress(f.rgbPixelBuffer,0);
    for (int y=0;y<160;y++) for(int x=0;x<160;x++) {
        double height=(y>=64 && y<=76 && x>=64 && x<=92) ? .3 : 0;
        double z=y>20 ? (1-height)/((y-20)/100.) : 0;
        mm[y*160+x]=z>=.15 && z<=10 ? lround(z*1000) : 0;
        uint8_t *p=(uint8_t *)CVPixelBufferGetBaseAddress(f.rgbPixelBuffer)+y*CVPixelBufferGetBytesPerRow(f.rgbPixelBuffer)+4*x;
        p[0]=(x+y)%256; p[1]=y; p[2]=x; p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(f.rgbPixelBuffer,0); f.millimetersLittleEndian=d; return f;
}
int main(void) { @autoreleasepool {
    Harness *h=[Harness new]; h.robotNode=[FixtureNode new]; h.robotNode.presentationNode=h.robotNode;
    h.liveRGBCloudNode=[FixtureNode new]; h.liveBellyRGBCloudNode=[FixtureNode new]; h.serialBox=[ROBSerialBox new];
    h.serialBox.isNeckCommandStateKnown=YES; h.serialBox.commandedLowerNeckTiltTarget=6011;
    h.serialBox.commandedNeckPanTarget=6000; h.serialBox.commandedUpperNeckTiltTarget=6306;
    NSArray *targets=@[@6011,@6000,@6306]; double a=8*M_PI/180, c=cos(a), s=sin(a), scale=ROBScanVisualModel.presentationScale;
    double rows[12]={scale,0,0,0, 0,-scale*c,-scale*s,scale*(c+.08), 0,-scale*s,scale*c,scale*s};
    ROBDepthCloudTransform camera=ROBDepthCloudMakeTransform(rows);
    SCNMatrix4 world=SCNMatrix4MakeRotation(.4,0,1,0); world.m41=3; world.m42=5; world.m43=-2; h.robotNode.worldTransform=world;
    ROBDepthCloudFrame *f=frame(); f.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
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
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:targets]; h.serialBox.commandedUpperNeckTiltTarget++; drain(h);
    assert(h.liveRGBCloudNode.hidden && !h.liveRGBCloudNode.geometry); h.serialBox.commandedUpperNeckTiltTarget--;
    f.capturedUptime=NSProcessInfo.processInfo.systemUptime-1; h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:targets]; drain(h); assert(h.liveRGBCloudNode.hidden);
    f.millimetersLittleEndian=[NSMutableData dataWithLength:160*160*2]; f.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:f robotTransform:world cameraTransform:camera neckTargets:targets]; drain(h);
    assert(h.capturedPoints.count==0 && h.capturedColors.count==0 && [h.headFloorSummary containsString:@"raw cloud"]);
    ROBDepthCloudFrame *cap=[ROBDepthCloudFrame new]; cap.width=566; cap.height=565;
    NSMutableData *dense=[NSMutableData dataWithLength:566*565*2]; for(int i=0;i<566*565;i++) ((uint16_t *)dense.mutableBytes)[i]=1000;
    cap.millimetersLittleEndian=dense; cap.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:cap robotTransform:world cameraTransform:camera neckTargets:targets];
    assert(h.capturedPoints.count>0 && h.capturedPoints.count<=20000 && h.capturedPoints.count==h.capturedColors.count);
    drain(h);
    h.liveRGBCloudNode.geometry=nil; cap.capturedUptime=NSProcessInfo.processInfo.systemUptime; h.cloudUpdatePending=YES;
    [h processDepthFrame:cap robotTransform:world cameraTransform:camera neckTargets:targets]; SCNMatrix4 moved=world; moved.m41++; h.robotNode.worldTransform=moved; drain(h);
    assert(!h.liveRGBCloudNode.geometry);
    CVPixelBufferRelease(f.rgbPixelBuffer); puts("Production depth-floor integration passed: scaled rigid floor/object heights, RGB pairing, 20k cap, changed-pose/base and stale rejection, sparse fallback");
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
