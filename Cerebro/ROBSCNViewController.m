#import "ROBSCNViewController.h"
#import "ROBBaseControllerModel.h"
#import <QuartzCore/QuartzCore.h>
#import <simd/quaternion.h>

static NSTimeInterval const ROBControllerDiagnosticStaleInterval = 0.5;

@interface ROBSCNViewController ()
@property (readwrite, retain) SCNNode *leftControllerNode;
@property (readwrite, retain) SCNNode *rightControllerNode;
@property (readwrite, retain) SCNNode *leftTreadNode;
@property (readwrite, retain) SCNNode *rightTreadNode;
@property (readwrite, retain) SCNNode *statusTextNode;
@property (readwrite, retain) SCNNode *detailTextNode;
@property (readwrite, retain) NSTimer *freshnessTimer;
@property (readwrite, assign) NSTimeInterval lastReceivedUptime;
@property (readwrite, copy) NSString *lastSender;
@property (readwrite, assign) BOOL leftPoseValid;
@property (readwrite, assign) BOOL rightPoseValid;
@end

@implementation ROBSCNViewController

- (instancetype)initWithRobo_scnView:(SCNView *)scnView
{
    self = [super init];
    if (self) {
        self.robo_scnView = scnView;
        self.lastSender = @"No controller";
        [self loadScene];
        self.freshnessTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                               target:self
                                                             selector:@selector(refreshFreshness:)
                                                             userInfo:nil
                                                              repeats:YES];
    }
    return self;
}

- (void)dealloc
{
    [self.freshnessTimer invalidate];
}

- (SCNMaterial *)materialWithColor:(NSColor *)color emission:(CGFloat)emission
{
    SCNMaterial *material = [SCNMaterial material];
    material.diffuse.contents = color;
    material.metalness.contents = @0.25;
    material.roughness.contents = @0.55;
    material.emission.contents = [color colorWithAlphaComponent:emission];
    return material;
}

- (SCNNode *)controllerNodeWithColor:(NSColor *)color
{
    SCNNode *root = [SCNNode node];
    SCNBox *body = [SCNBox boxWithWidth:0.10 height:0.18 length:0.07 chamferRadius:0.025];
    body.materials = @[[self materialWithColor:color emission:0.25]];
    [root addChildNode:[SCNNode nodeWithGeometry:body]];

    SCNCylinder *ray = [SCNCylinder cylinderWithRadius:0.008 height:0.32];
    ray.materials = @[[self materialWithColor:color emission:0.7]];
    SCNNode *rayNode = [SCNNode nodeWithGeometry:ray];
    rayNode.position = SCNVector3Make(0, 0, -0.19);
    rayNode.eulerAngles = SCNVector3Make((float)M_PI_2, 0, 0);
    [root addChildNode:rayNode];
    return root;
}

- (SCNNode *)textNodeWithSize:(CGFloat)size position:(SCNVector3)position
{
    SCNText *text = [SCNText textWithString:@"" extrusionDepth:0.002];
    text.font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightSemibold];
    text.flatness = 0.2;
    text.firstMaterial = [self materialWithColor:NSColor.whiteColor emission:0.35];
    SCNNode *node = [SCNNode nodeWithGeometry:text];
    node.scale = SCNVector3Make(0.01, 0.01, 0.01);
    node.position = position;
    return node;
}

- (void)loadScene
{
    SCNScene *scene = [SCNScene scene];
    scene.background.contents = [NSColor colorWithRed:0.015 green:0.025 blue:0.045 alpha:1];

    SCNNode *cameraNode = [SCNNode node];
    cameraNode.camera = [SCNCamera camera];
    cameraNode.camera.fieldOfView = 52;
    cameraNode.position = SCNVector3Make(0, 1.25, 2.8);
    cameraNode.eulerAngles = SCNVector3Make(-0.22, 0, 0);
    [scene.rootNode addChildNode:cameraNode];

    SCNNode *lightNode = [SCNNode node];
    lightNode.light = [SCNLight light];
    lightNode.light.type = SCNLightTypeOmni;
    lightNode.light.intensity = 1100;
    lightNode.position = SCNVector3Make(0, 2.5, 2);
    [scene.rootNode addChildNode:lightNode];
    scene.lightingEnvironment.intensity = 0.6;

    SCNFloor *floor = [SCNFloor floor];
    floor.reflectivity = 0.08;
    floor.firstMaterial.diffuse.contents = [NSColor colorWithWhite:0.08 alpha:1];
    [scene.rootNode addChildNode:[SCNNode nodeWithGeometry:floor]];

    SCNBox *robotBody = [SCNBox boxWithWidth:0.72 height:0.46 length:0.56 chamferRadius:0.08];
    robotBody.materials = @[[self materialWithColor:[NSColor colorWithWhite:0.18 alpha:1] emission:0.05]];
    SCNNode *bodyNode = [SCNNode nodeWithGeometry:robotBody];
    bodyNode.position = SCNVector3Make(0, 0.34, 0);
    [scene.rootNode addChildNode:bodyNode];

    SCNBox *tread = [SCNBox boxWithWidth:0.17 height:0.26 length:0.78 chamferRadius:0.06];
    self.leftTreadNode = [SCNNode nodeWithGeometry:[tread copy]];
    self.rightTreadNode = [SCNNode nodeWithGeometry:[tread copy]];
    self.leftTreadNode.position = SCNVector3Make(-0.43, 0.22, 0);
    self.rightTreadNode.position = SCNVector3Make(0.43, 0.22, 0);
    [scene.rootNode addChildNode:self.leftTreadNode];
    [scene.rootNode addChildNode:self.rightTreadNode];

    self.leftControllerNode = [self controllerNodeWithColor:NSColor.systemCyanColor];
    self.rightControllerNode = [self controllerNodeWithColor:NSColor.systemGreenColor];
    [scene.rootNode addChildNode:self.leftControllerNode];
    [scene.rootNode addChildNode:self.rightControllerNode];

    self.statusTextNode = [self textNodeWithSize:30 position:SCNVector3Make(-1.1, 1.48, 0)];
    self.detailTextNode = [self textNodeWithSize:17 position:SCNVector3Make(-1.1, 1.30, 0)];
    [scene.rootNode addChildNode:self.statusTextNode];
    [scene.rootNode addChildNode:self.detailTextNode];

    self.robo_scnView.scene = scene;
    self.robo_scnView.allowsCameraControl = YES;
    self.robo_scnView.showsStatistics = YES;
    self.robo_scnView.backgroundColor = NSColor.blackColor;
    [self renderUnavailableState:@"WAITING FOR RECEIVED CONTROLLER DATA"];
}

- (void)updateWithControllerModel:(ROBBaseControllerModel *)model sender:(NSString *)sender
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateWithControllerModel:model sender:sender]; });
        return;
    }
    self.lastReceivedUptime = model.receivedAtUptime;
    self.lastSender = sender.length > 0 ? sender : @"Unknown controller";
    self.leftPoseValid = model.leftControllerPoseValid;
    self.rightPoseValid = model.rightControllerPoseValid;

    [SCNTransaction begin];
    [SCNTransaction setAnimationDuration:0.08];
    [self applyModel:model toNode:self.leftControllerNode left:YES];
    [self applyModel:model toNode:self.rightControllerNode left:NO];
    [self updateTreadNode:self.leftTreadNode demand:model.touchPadPointL.x color:NSColor.systemCyanColor];
    [self updateTreadNode:self.rightTreadNode demand:model.touchPadPointR.x color:NSColor.systemGreenColor];
    [SCNTransaction commit];
    [self refreshFreshness:nil];
}

- (void)applyModel:(ROBBaseControllerModel *)model toNode:(SCNNode *)node left:(BOOL)left
{
    BOOL valid = left ? model.leftControllerPoseValid : model.rightControllerPoseValid;
    node.hidden = !valid;
    if (!valid) { return; }
    node.position = SCNVector3Make(left ? model.leftControllerPositionX : model.rightControllerPositionX,
                                  (left ? model.leftControllerPositionY : model.rightControllerPositionY) + 0.45,
                                  left ? model.leftControllerPositionZ : model.rightControllerPositionZ);
    simd_float3 vector = {
        left ? model.leftControllerOrientationX : model.rightControllerOrientationX,
        left ? model.leftControllerOrientationY : model.rightControllerOrientationY,
        left ? model.leftControllerOrientationZ : model.rightControllerOrientationZ
    };
    float scalar = left ? model.leftControllerOrientationW : model.rightControllerOrientationW;
    node.simdOrientation = simd_quaternion(scalar, vector);
}

- (void)updateTreadNode:(SCNNode *)node demand:(CGFloat)demand color:(NSColor *)color
{
    CGFloat bounded = MAX(-1.0, MIN(1.0, demand));
    NSColor *stateColor = fabs(bounded) < 0.02 ? NSColor.darkGrayColor : color;
    node.geometry.firstMaterial = [self materialWithColor:stateColor emission:fabs(bounded) * 0.8];
    node.scale = SCNVector3Make(1, 1, 1.0 + fabs(bounded) * 0.18);
}

- (void)refreshFreshness:(NSTimer *)timer
{
    NSTimeInterval age = self.lastReceivedUptime > 0
        ? NSProcessInfo.processInfo.systemUptime - self.lastReceivedUptime
        : DBL_MAX;
    if (age > ROBControllerDiagnosticStaleInterval) {
        [self renderUnavailableState:self.lastReceivedUptime > 0 ? @"CONTROLLER DATA STALE" : @"NO CONTROLLER DATA RECEIVED"];
        return;
    }
    SCNText *status = (SCNText *)self.statusTextNode.geometry;
    status.string = @"RECEIVING VR CONTROLLER INPUT";
    status.firstMaterial.diffuse.contents = NSColor.systemGreenColor;
    SCNText *detail = (SCNText *)self.detailTextNode.geometry;
    detail.string = [NSString stringWithFormat:@"%@  •  %.0f ms  •  L:%@  R:%@",
                     self.lastSender, age * 1000.0,
                     self.leftPoseValid ? @"POSE" : @"NO POSE",
                     self.rightPoseValid ? @"POSE" : @"NO POSE"];
}

- (void)renderUnavailableState:(NSString *)message
{
    SCNText *status = (SCNText *)self.statusTextNode.geometry;
    status.string = message;
    status.firstMaterial.diffuse.contents = NSColor.systemRedColor;
    SCNText *detail = (SCNText *)self.detailTextNode.geometry;
    detail.string = [NSString stringWithFormat:@"%@  •  expected packet interval < 500 ms", self.lastSender];
    self.leftControllerNode.hidden = YES;
    self.rightControllerNode.hidden = YES;
    [self updateTreadNode:self.leftTreadNode demand:0 color:NSColor.systemCyanColor];
    [self updateTreadNode:self.rightTreadNode demand:0 color:NSColor.systemGreenColor];
}

@end
