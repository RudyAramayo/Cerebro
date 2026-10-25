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
@interface Harness : NSObject
@property(strong) FixtureRobot *robotNode;
@property(strong) SCNView *robo_scnView;
@property(strong) dispatch_queue_t cloudQueue;
@property(strong) SCNNode *liveRGBCloudNode,*liveBellyRGBCloudNode;
@property BOOL treadCommandsAreActive;
__CONTROLLER_PROPERTIES__
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
static void offer(Harness *h, NSData *samples, ROBDepthCloudFrame *frame, ROBSurfaceDepthView view) {
    h.lastHeadSurfaceSubmission=0;h.lastBellySurfaceSubmission=0;
    frame.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:h.robotNode.worldTransform floorValid:YES];
    drain(h);
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    Harness *h=[Harness new];h.robotNode=[FixtureRobot new];h.robotNode.presentationNode=h.robotNode;
    h.robotNode.worldTransform=SCNMatrix4Identity;h.robo_scnView=[SCNView new];h.robo_scnView.scene=[SCNScene scene];
    h.surfaceMode=(NSButton *)(id)[FixtureButton new];h.surfaceMode.state=NSControlStateValueOn;
    h.surfaceStatusLabel=(NSTextField *)(id)[FixtureLabel new];
    h.headSurfaceNode=[SCNNode node];h.bellySurfaceNode=[SCNNode node];
    h.liveRGBCloudNode=[SCNNode node];h.liveBellyRGBCloudNode=[SCNNode node];
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
    offer(h,samples,frame,view);assert([h.headSurfaceSummary containsString:@"1 frames"]);
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
    /* Two camera histories are independent; a stream change clears both. */
    frame.isBelly=YES;frame.captureStreamID=@"fixture-belly-1";frame.sequence=1;offer(h,samples,frame,view);
    assert(h.headSurfaceNode.childNodes.firstObject==map && h.bellySurfaceAccumulator && h.headSurfaceAccumulator!=h.bellySurfaceAccumulator);
    frame.sequence=2;offer(h,samples,frame,view);assert(h.bellySurfaceNode.childNodes.firstObject.childNodes.count>=4);
    frame.isBelly=NO;frame.captureStreamID=@"fixture-head-reconnected";frame.sequence=1;offer(h,samples,frame,view);
    assert(!h.bellySurfaceNode.childNodes.count && [h.headSurfaceSummary containsString:@"1 frames"]);
    frame.sequence=2;offer(h,samples,frame,view);map=h.headSurfaceNode.childNodes.firstObject;
    ROBSurfaceAccumulator *before=h.headSurfaceAccumulator;
    ROBLeftArmTrial.shared.isRunning=YES;frame.sequence++;offer(h,samples,frame,view);
    assert(h.headSurfaceAccumulator==before && h.headSurfaceNode.childNodes.firstObject==map && [h.headSurfaceSummary containsString:@"paused"]);
    ROBLeftArmTrial.shared.isRunning=NO;
    [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:SCNMatrix4Identity floorValid:NO];
    assert(h.headSurfaceNode.childNodes.firstObject==map && [h.headSurfaceSummary containsString:@"previous scan retained"]);
    /* A reset while a worker is pending prevents its old result publishing. */
    h.lastHeadSurfaceSubmission=0;frame.sequence++;frame.capturedUptime=NSProcessInfo.processInfo.systemUptime;
    [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:SCNMatrix4Identity floorValid:YES];
    [h resetAccumulatedSurfaces:nil];
    dispatch_sync(h.cloudQueue,^{});[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    assert(!h.headSurfaceNode.childNodes.count && !h.headSurfaceAccumulator);
    [h offerAccumulatedSurfaceSamples:samples frame:frame view:view robotTransform:SCNMatrix4Identity floorValid:YES];
    assert(!h.headSurfaceAccumulator && [h.headSurfaceSummary containsString:@"after Reset"]);
    frame.sequence++;offer(h,samples,frame,view);frame.sequence++;offer(h,samples,frame,view);
    map=h.headSurfaceNode.childNodes.firstObject;
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
    printf("Production surface renderer/integration passed: packed float vertices/UVs, textured planes, inferred cylinder, separate cameras, duplicate capture rejection, stream reset, motion pause, rejected-floor history and stale-worker reset (%zu triangles).\n",triangles);
} }
