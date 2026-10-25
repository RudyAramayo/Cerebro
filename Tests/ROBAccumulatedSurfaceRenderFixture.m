#import "ROBAccumulatedSurfaceRenderer.h"
#include <assert.h>

@interface FixtureLabel : NSObject
@property(copy) NSString *stringValue;
@end
@implementation FixtureLabel @end
@interface FixtureButton : NSObject
@property NSInteger state;
@end
@implementation FixtureButton @end
@interface FixtureRobot : NSObject
@property SCNMatrix4 worldTransform;
@property(strong) FixtureRobot *presentationNode;
@end
@implementation FixtureRobot @end
@interface ROBScanVisualModel : NSObject
+ (float)presentationScale;
@end
@implementation ROBScanVisualModel
+ (float)presentationScale {return 1.2f;}
@end
@interface ROBDepthCloudFrame : NSObject
@property CVPixelBufferRef rgbPixelBuffer;
@property BOOL isBelly,hasCalibratedIntrinsics;
@property NSInteger width,height;
@property(copy) NSString *captureStreamID;
@property uint64_t sequence;
@property double capturedUptime;
@property(strong) NSData *millimetersLittleEndian;
@end
@implementation ROBDepthCloudFrame @end
@interface ROBLeftArmTrial : NSObject
@property BOOL isRunning,isNeckOnlyInspection;
+ (instancetype)shared;
@end
@implementation ROBLeftArmTrial
+ (instancetype)shared { static id instance; if(!instance) instance=[self new];return instance; }
@end
@interface ROBArmRoutineCoordinator : ROBLeftArmTrial @end
@implementation ROBArmRoutineCoordinator
+ (instancetype)shared { static id instance; if(!instance) instance=[self new];return instance; }
@end
@interface FixtureGhostGestureEditor : NSObject
@property(copy) NSString *depthProjectionIdentity;
@end
@implementation FixtureGhostGestureEditor @end
@interface ROBFixedHeadBodyMotionIdentity : NSObject
+ (NSString *)currentIdentity;
+ (void)setFixtureIdentity:(NSString *)identity;
@end
@implementation ROBFixedHeadBodyMotionIdentity
static NSString *fixtureBodyIdentity;
+ (NSString *)currentIdentity { return fixtureBodyIdentity ?: @"body-initial"; }
+ (void)setFixtureIdentity:(NSString *)identity { fixtureBodyIdentity=[identity copy]; }
@end
@interface Harness : NSObject
@property(strong) FixtureRobot *robotNode;
@property(strong) SCNView *robo_scnView;
@property(strong) dispatch_queue_t cloudQueue;
@property(strong) SCNNode *liveRGBCloudNode,*liveBellyRGBCloudNode;
@property(strong) FixtureGhostGestureEditor *ghostGestureEditor;
@property BOOL treadCommandsAreActive;
__CONTROLLER_PROPERTIES__
__SOURCE_CONTEXT_PROPERTIES__
@end
@implementation Harness
__CONTROLLER_METHODS__
@end

static void drain(Harness *h) {
    double deadline=NSProcessInfo.processInfo.systemUptime+5;
    while (h.surfaceUpdatePending && NSProcessInfo.processInfo.systemUptime<deadline)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(!h.surfaceUpdatePending);
}
static void submit(Harness *h, NSData *samples, ROBDepthCloudFrame *frame, ROBSurfaceDepthView view, BOOL projectionReady) {
    h.lastHeadSurfaceSubmission=0;h.lastBellySurfaceSubmission=0;
    frame.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    [h updateDepthCloudStream:frame];
    [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:h.robotNode.worldTransform
        projectionReady:projectionReady projectionIdentity:h.ghostGestureEditor.depthProjectionIdentity];
}
static void offer(Harness *h, NSData *samples, ROBDepthCloudFrame *frame, ROBSurfaceDepthView view) {
    submit(h,samples,frame,view,YES);
    drain(h);
}
static SCNNode *rebuildHead(Harness *h, NSData *samples, ROBDepthCloudFrame *frame, ROBSurfaceDepthView view) {
    frame.sequence++;offer(h,samples,frame,view);
    frame.sequence++;offer(h,samples,frame,view);
    frame.sequence++;offer(h,samples,frame,view);
    SCNNode *map=h.headSurfaceNode.childNodes.firstObject;
    assert(map.childNodes.count>=4 && h.headUsesSurfaces);
    return map;
}
static void assertEmptyHistory(Harness *h) {
    assert(!h.headSurfaceNode.childNodes.count && !h.bellySurfaceNode.childNodes.count);
    assert(!h.headSurfaceAccumulator && !h.bellySurfaceAccumulator && !h.headUsesSurfaces && !h.bellyUsesSurfaces);
}
static void assertEmptyHeadHistory(Harness *h) {
    assert(!h.headSurfaceNode.childNodes.count && !h.headSurfaceAccumulator && !h.headUsesSurfaces);
}
static ROBDepthCloudFrame *copyFrame(ROBDepthCloudFrame *frame) {
    ROBDepthCloudFrame *copy=[ROBDepthCloudFrame new];
    copy.isBelly=frame.isBelly;copy.hasCalibratedIntrinsics=frame.hasCalibratedIntrinsics;
    copy.width=frame.width;copy.height=frame.height;copy.captureStreamID=frame.captureStreamID;
    copy.sequence=frame.sequence;copy.capturedUptime=frame.capturedUptime;
    copy.millimetersLittleEndian=frame.millimetersLittleEndian;copy.rgbPixelBuffer=frame.rgbPixelBuffer;
    return copy;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    Harness *h=[Harness new];h.robotNode=[FixtureRobot new];h.robotNode.presentationNode=h.robotNode;
    h.robotNode.worldTransform=SCNMatrix4Identity;h.robo_scnView=[SCNView new];h.robo_scnView.scene=[SCNScene scene];
    h.surfaceMode=(NSButton *)(id)[FixtureButton new];h.surfaceMode.state=NSControlStateValueOn;
    h.surfaceStatusLabel=(NSTextField *)(id)[FixtureLabel new];
    h.headSurfaceNode=[SCNNode node];h.bellySurfaceNode=[SCNNode node];
    h.liveRGBCloudNode=[SCNNode node];h.liveBellyRGBCloudNode=[SCNNode node];
    h.ghostGestureEditor=[FixtureGhostGestureEditor new];h.ghostGestureEditor.depthProjectionIdentity=@"projection-initial";
    h.cloudQueue=dispatch_queue_create("surface.fixture",DISPATCH_QUEUE_SERIAL);
    ROBSurfaceSample p[10000];size_t n=0;
    for (int x=0;x<60;x++) for (int z=0;z<50;z++) {
        if (x>=20 && x<30 && z>=20 && z<30) continue;
        p[n++]=(ROBSurfaceSample){{-.6+(x+.5)*.02,.75,-1-(z+.5)*.02},x<30 ? 0xD02010FF : 0x1030D0FF};
    }
    for (int x=0;x<60;x++) for (int y=0;y<60;y++)
        p[n++]=(ROBSurfaceSample){{-.6+(x+.5)*.02,(y+.5)*.02,-2.5},0x909898FF};
    for (int y=0;y<12;y++) for (int a=0;a<24;a++) {
        double angle=3.14159265358979323846*a/23;
        p[n++]=(ROBSurfaceSample){{.2+.033*cos(angle),.758+y*.009,-1.5+.033*sin(angle)},0xDD1020FF};
    }
    NSData *samples=[NSData dataWithBytes:p length:n*sizeof(*p)];
    ROBDepthCloudFrame *frame=[ROBDepthCloudFrame new];frame.captureStreamID=@"fixture-head-1";
    frame.sequence=1;frame.hasCalibratedIntrinsics=YES;frame.width=frame.height=32;
    frame.millimetersLittleEndian=[NSMutableData dataWithLength:32*32*2];
    ROBSurfaceDepthView view={32,32,frame.millimetersLittleEndian.bytes,30,30,16,16,{1,0,0,0,0,-1,0,1.5,0,0,-1,0}};
    /* HEAD projection can be ready from an explicit calibrated camera pose.
       No unrelated per-frame floor fit is supplied by this fixture. */
    submit(h,samples,frame,view,YES);drain(h);assert([h.headSurfaceSummary containsString:@"1 frames"]);
    frame.sequence++;offer(h,samples,frame,view);assert([h.headSurfaceSummary containsString:@"2 frames"]);
    SCNNode *map=h.headSurfaceNode.childNodes.firstObject;assert(map.childNodes.count>=4 && h.liveRGBCloudNode.hidden && h.headUsesSurfaces);
    assert([h.surfaceStatusLabel.stringValue containsString:@"cyan = inferred"] && [h.headSurfaceSummary containsString:@"1 inferred cans"]);
    size_t triangles=0;
    for (SCNNode *node in map.childNodes) if ([node.name hasPrefix:@"Observed plane"]) {
        SCNGeometrySource *vertices=[node.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
        SCNGeometrySource *uv=[node.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
        assert(vertices.bytesPerComponent==4 && vertices.dataStride==12 && uv.dataStride==8);
        triangles+=node.geometry.geometryElements.firstObject.primitiveCount;assert(node.geometry.firstMaterial.diffuse.contents);
    }
    assert(triangles>0 && triangles<100);
    double captured=h.lastHeadSurfaceCapture;offer(h,samples,frame,view);
    assert(h.headSurfaceNode.childNodes.firstObject==map && h.lastHeadSurfaceCapture==captured);
    /* A capture/calibration stream change invalidates only its camera. */
    frame.isBelly=YES;frame.captureStreamID=@"fixture-belly-1";frame.sequence=1;offer(h,samples,frame,view);
    assert(h.headSurfaceNode.childNodes.firstObject==map && h.bellySurfaceAccumulator && h.headSurfaceAccumulator!=h.bellySurfaceAccumulator);
    frame.sequence=2;offer(h,samples,frame,view);assert(h.bellySurfaceNode.childNodes.firstObject.childNodes.count>=4);
    SCNNode *bellyMap=h.bellySurfaceNode.childNodes.firstObject;
    ROBSurfaceAccumulator *bellyAccumulator=h.bellySurfaceAccumulator;
    frame.isBelly=NO;frame.captureStreamID=@"fixture-head-reconnected";frame.sequence=1;offer(h,samples,frame,view);
    assertEmptyHeadHistory(h);assert([h.headSurfaceSummary containsString:@"after Reset"]);
    assert(h.bellySurfaceNode.childNodes.firstObject==bellyMap && h.bellySurfaceAccumulator==bellyAccumulator);
    frame.sequence=2;offer(h,samples,frame,view);assert([h.headSurfaceSummary containsString:@"1 frames"]);
    frame.sequence=3;offer(h,samples,frame,view);map=h.headSurfaceNode.childNodes.firstObject;
    ROBSurfaceAccumulator *before=h.headSurfaceAccumulator;
    ROBLeftArmTrial.shared.isRunning=YES;frame.sequence++;offer(h,samples,frame,view);
    assert(h.headSurfaceAccumulator==before && h.headSurfaceNode.childNodes.firstObject==map && [h.headSurfaceSummary containsString:@"paused"]);
    ROBLeftArmTrial.shared.isRunning=NO;
    submit(h,samples,frame,view,NO);
    assert(h.headSurfaceNode.childNodes.firstObject==map && [h.headSurfaceSummary containsString:@"previous scan retained"]);
    assert([h.headSurfaceSummary isEqualToString:@"waiting for an explicit camera pose or fresh floor alignment; previous scan retained"]);
    /* Losing projection readiness cannot retain another stream/profile/body context. */
    NSUInteger generation=h.surfaceGeneration;
    frame.captureStreamID=@"fixture-head-floor-occluded-reconnect";submit(h,samples,frame,view,NO);
    assertEmptyHeadHistory(h);assert(h.surfaceGeneration>generation);
    assert(h.bellySurfaceNode.childNodes.firstObject==bellyMap && h.bellySurfaceAccumulator==bellyAccumulator);
    map=rebuildHead(h,samples,frame,view);generation=h.surfaceGeneration;
    h.ghostGestureEditor.depthProjectionIdentity=@"projection-after-profile-reload";
    submit(h,samples,frame,view,NO);assertEmptyHistory(h);assert(h.surfaceGeneration>generation);
    map=rebuildHead(h,samples,frame,view);generation=h.surfaceGeneration;
    [ROBFixedHeadBodyMotionIdentity setFixtureIdentity:@"body-after-movement"];
    submit(h,samples,frame,view,NO);assertEmptyHistory(h);assert(h.surfaceGeneration>generation);
    map=rebuildHead(h,samples,frame,view);
    /* Hold the real worker queue so each context change happens after submission. */
    captured=h.lastHeadSurfaceCapture;
    dispatch_suspend(h.cloudQueue);frame.sequence++;submit(h,samples,frame,view,YES);
    assert(h.surfaceUpdatePending);
    h.ghostGestureEditor.depthProjectionIdentity=@"projection-changed-during-worker";
    dispatch_resume(h.cloudQueue);drain(h);
    assert(h.headSurfaceNode.childNodes.firstObject==map && h.lastHeadSurfaceCapture==captured);
    submit(h,samples,frame,view,NO);assertEmptyHistory(h);map=rebuildHead(h,samples,frame,view);
    captured=h.lastHeadSurfaceCapture;
    dispatch_suspend(h.cloudQueue);frame.sequence++;submit(h,samples,frame,view,YES);
    assert(h.surfaceUpdatePending);
    [ROBFixedHeadBodyMotionIdentity setFixtureIdentity:@"body-changed-during-worker"];
    dispatch_resume(h.cloudQueue);drain(h);
    assert(h.headSurfaceNode.childNodes.firstObject==map && h.lastHeadSurfaceCapture==captured);
    submit(h,samples,frame,view,NO);assertEmptyHistory(h);map=rebuildHead(h,samples,frame,view);
    captured=h.lastHeadSurfaceCapture;
    dispatch_suspend(h.cloudQueue);frame.sequence++;submit(h,samples,frame,view,YES);
    assert(h.surfaceUpdatePending);ROBLeftArmTrial.shared.isRunning=YES;
    dispatch_resume(h.cloudQueue);drain(h);
    assert(h.headSurfaceNode.childNodes.firstObject==map && h.lastHeadSurfaceCapture==captured);
    ROBLeftArmTrial.shared.isRunning=NO;
    /* A same-K source change cannot publish an old result, clear a newer
       pending flag, or cancel the other camera's existing history. */
    ROBDepthCloudFrame *bellyFrame=copyFrame(frame);bellyFrame.isBelly=YES;
    bellyFrame.captureStreamID=@"fixture-belly-preserved-during-head-runtime-change";bellyFrame.sequence=1;
    offer(h,samples,bellyFrame,view);bellyFrame.sequence++;offer(h,samples,bellyFrame,view);
    bellyFrame.sequence++;offer(h,samples,bellyFrame,view);
    bellyMap=h.bellySurfaceNode.childNodes.firstObject;bellyAccumulator=h.bellySurfaceAccumulator;
    assert(bellyMap.childNodes.count>=4 && h.headSurfaceNode.childNodes.firstObject==map);
    dispatch_semaphore_t gate=dispatch_semaphore_create(0);
    __block BOOL oldCompletionDrained=NO;
    dispatch_suspend(h.cloudQueue);frame.sequence++;submit(h,samples,frame,view,YES);
    assert(h.headSurfaceUpdatePending);
    dispatch_async(h.cloudQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{oldCompletionDrained=YES;});
        dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);
    });
    ROBDepthCloudFrame *newFrame=copyFrame(frame);
    newFrame.captureStreamID=@"fixture-head-new-runtime-same-K";newFrame.sequence=1;
    [h updateDepthCloudStream:newFrame];
    assertEmptyHeadHistory(h);assert(!h.headSurfaceUpdatePending);
    assert(h.bellySurfaceAccumulator==bellyAccumulator && h.bellySurfaceNode.childNodes.firstObject==bellyMap);
    newFrame.sequence++;submit(h,samples,newFrame,view,YES);assert(h.headSurfaceUpdatePending);
    dispatch_resume(h.cloudQueue);
    double oldDeadline=NSProcessInfo.processInfo.systemUptime+5;
    while (!oldCompletionDrained && NSProcessInfo.processInfo.systemUptime<oldDeadline)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
    assert(oldCompletionDrained && h.headSurfaceUpdatePending && h.surfaceUpdatePending);
    assert(!h.headSurfaceNode.childNodes.count && h.bellySurfaceNode.childNodes.firstObject==bellyMap);
    dispatch_semaphore_signal(gate);drain(h);
    assert([h.headSurfaceSummary containsString:@"1 frames"] && !h.headSurfaceNode.childNodes.firstObject.childNodes.count);
    newFrame.sequence++;offer(h,samples,newFrame,view);frame=newFrame;
    map=h.headSurfaceNode.childNodes.firstObject;assert(map.childNodes.count>=4);
    /* A belly restart likewise leaves a pending head observation intact. */
    dispatch_suspend(h.cloudQueue);frame.sequence++;submit(h,samples,frame,view,YES);
    assert(h.headSurfaceUpdatePending);
    ROBDepthCloudFrame *newBelly=copyFrame(bellyFrame);newBelly.captureStreamID=@"fixture-belly-new-runtime-same-K";
    [h updateDepthCloudStream:newBelly];
    assert(h.headSurfaceUpdatePending && h.headSurfaceNode.childNodes.firstObject==map);
    assert(!h.bellySurfaceNode.childNodes.count && !h.bellySurfaceAccumulator);
    dispatch_resume(h.cloudQueue);drain(h);
    assert(h.headSurfaceNode.childNodes.firstObject.childNodes.count>=4);
    /* A reset while a worker is pending prevents its old result publishing. */
    h.lastHeadSurfaceSubmission=0;frame.sequence++;frame.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:SCNMatrix4Identity projectionReady:YES
        projectionIdentity:h.ghostGestureEditor.depthProjectionIdentity];
    [h resetAccumulatedSurfaces:nil];
    dispatch_sync(h.cloudQueue,^{});[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    assert(!h.headSurfaceNode.childNodes.count && !h.headSurfaceAccumulator);
    [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:SCNMatrix4Identity projectionReady:YES
        projectionIdentity:h.ghostGestureEditor.depthProjectionIdentity];
    assert(!h.headSurfaceAccumulator && [h.headSurfaceSummary containsString:@"after Reset"]);
    frame.sequence++;offer(h,samples,frame,view);frame.sequence++;offer(h,samples,frame,view);
    map=h.headSurfaceNode.childNodes.firstObject;
    /* Expiry accepts the overlapping view, but replacement voxels need another
       observation. Its empty production mesh must restore raw-frame building. */
    for (int cameraIndex=0;cameraIndex<2;cameraIndex++) {
        BOOL belly=cameraIndex==1;
        frame.isBelly=belly;
        if (belly) {
            frame.captureStreamID=@"fixture-belly-empty-transition";frame.sequence=1;
            offer(h,samples,frame,view);frame.sequence++;offer(h,samples,frame,view);
            frame.sequence++;offer(h,samples,frame,view);
        }
        SCNNode *surfaceRoot=belly ? h.bellySurfaceNode : h.headSurfaceNode;
        SCNNode *populated=surfaceRoot.childNodes.firstObject;
        assert(populated.childNodes.count>=4 && (belly ? h.bellyUsesSurfaces : h.headUsesSurfaces));
        double previousCapture=belly ? h.lastBellySurfaceCapture : h.lastHeadSurfaceCapture;
        frame.sequence++;frame.capturedUptime=previousCapture+91;
        h.lastHeadSurfaceSubmission=0;h.lastBellySurfaceSubmission=0;
        [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:SCNMatrix4Identity projectionReady:YES
            projectionIdentity:h.ghostGestureEditor.depthProjectionIdentity];
        drain(h);
        assert(surfaceRoot.childNodes.count==1 && surfaceRoot.childNodes.firstObject!=populated);
        assert(!surfaceRoot.childNodes.firstObject.childNodes.count);
        assert(!(belly ? h.bellyUsesSurfaces : h.headUsesSurfaces));
        assert((belly ? h.lastBellySurfaceCapture : h.lastHeadSurfaceCapture)==frame.capturedUptime);
        assert([(belly ? h.bellySurfaceSummary : h.headSurfaceSummary) containsString:@"0 stable voxels"]);
    }
    [h resetAccumulatedSurfaces:nil];frame.isBelly=NO;frame.captureStreamID=@"fixture-head-final-render";
    map=rebuildHead(h,samples,frame,view);
    /* The actual production renderer, with a visible hole and inferred can. */
    SCNScene *scene=[SCNScene scene];scene.background.contents=[NSColor colorWithWhite:.07 alpha:1];
    [map removeFromParentNode];[scene.rootNode addChildNode:map];
    SCNNode *camera=[SCNNode node];camera.camera=[SCNCamera camera];camera.camera.fieldOfView=35;
    camera.position=SCNVector3Make(2,2.5,1.3);[camera lookAt:SCNVector3Make(0,.6,-1.7)];[scene.rootNode addChildNode:camera];
    SCNRenderer *renderer=[SCNRenderer rendererWithDevice:nil options:nil];renderer.scene=scene;renderer.pointOfView=camera;
    if (argc>1) {
        NSImage *image=[renderer snapshotAtTime:0 withSize:CGSizeMake(1100,800) antialiasingMode:SCNAntialiasingModeMultisampling4X];
        NSBitmapImageRep *bitmap=[NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
        assert(bitmap && [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES]);
    }
    printf("Production surface renderer/integration passed: explicit HEAD projection without unrelated floor proof, packed float vertices/UVs, textured planes, inferred cylinder, separate cameras, duplicate capture rejection, stream/profile/body resets without projection readiness, motion pause, retained history, stale-worker reset/profile/body/arm rejection and accepted empty-mesh raw fallback for both cameras (%zu triangles).\n",triangles);
} }
