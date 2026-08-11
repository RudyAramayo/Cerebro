#import "ROBSCNViewController.h"
#import "ROBBaseControllerModel.h"
#import <QuartzCore/QuartzCore.h>
#import <simd/quaternion.h>
#import "Cerebro-Swift.h"

static NSTimeInterval const ROBControllerDiagnosticStaleInterval = 0.5;
static NSTimeInterval const ROBIRDiagnosticStaleInterval = 0.75;
static NSTimeInterval const ROBLegacyIRWarningDisplayInterval = 3.0;
static NSInteger const ROBIRBlockedDistanceCentimeters = 25;
static CGFloat const ROBDiagnosticMaximumTreadSpeed = 0.9;
static CGFloat const ROBDiagnosticTrackWidth = 0.86;

@interface ROBSCNViewController ()
@property (readwrite, retain) SCNNode *leftControllerNode;
@property (readwrite, retain) SCNNode *rightControllerNode;
@property (readwrite, retain) SCNNode *robotNode;
@property (readwrite, retain) SCNNode *leftTreadNode;
@property (readwrite, retain) SCNNode *rightTreadNode;
@property (readwrite, retain) SCNNode *neckPanNode;
@property (readwrite, retain) SCNNode *cameraHeadNode;
@property (readwrite, retain) SCNNode *statusTextNode;
@property (readwrite, retain) SCNNode *detailTextNode;
@property (readwrite, retain) SCNNode *irTextNode;
@property (readwrite, retain) NSArray<SCNNode *> *irBeamNodes;
@property (readwrite, retain) NSArray<NSValue *> *irBeamOrigins;
@property (readwrite, retain) NSArray<NSValue *> *irBeamDirections;
@property (readwrite, retain) NSArray<NSNumber *> *lastIRDistances;
@property (readwrite, assign) NSTimeInterval lastIRReceivedUptime;
@property (readwrite, assign) NSTimeInterval lastLegacyIRFrontWarningUptime;
@property (readwrite, assign) NSTimeInterval lastLegacyIRBackWarningUptime;
@property (readwrite, assign) BOOL receivedLegacyIRWarning;
@property (readwrite, retain) NSTimer *freshnessTimer;
@property (readwrite, assign) NSTimeInterval lastReceivedUptime;
@property (readwrite, copy) NSString *lastSender;
@property (readwrite, assign) BOOL leftPoseValid;
@property (readwrite, assign) BOOL rightPoseValid;
@property (readwrite, assign) CGFloat leftTreadDemand;
@property (readwrite, assign) CGFloat rightTreadDemand;
@property (readwrite, assign) BOOL treadCommandsAreActive;
@property (readwrite, assign) BOOL neckCommandIsActive;
@property (readwrite, assign) CGFloat neckPanDemand;
@property (readwrite, assign) CGFloat neckTiltDemand;
@property (readwrite, assign) BOOL gripperCommandIsActive;
@property (readwrite, assign) BOOL leftGripperClosed;
@property (readwrite, assign) BOOL rightGripperClosed;
@property (readwrite, assign) NSTimeInterval lastRobotIntegrationUptime;
@property (readwrite, retain) SCNNode *liveRGBCloudNode;
@property (readwrite, strong) dispatch_queue_t cloudQueue;
@property (readwrite, assign) BOOL cloudUpdatePending;
@end

@implementation ROBSCNViewController

- (instancetype)initWithRobo_scnView:(SCNView *)scnView
{
    self = [super init];
    if (self) {
        self.robo_scnView = scnView;
        self.lastSender = @"No controller";
        [self loadScene];
        self.cloudQueue = dispatch_queue_create("com.orbitusrobotics.Cerebro.live-rgb-cloud", DISPATCH_QUEUE_SERIAL);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedDepthCloudFrame:)
                                                     name:@"ROBDepthCloudFrame" object:nil];
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
    [self invalidate];
}

- (void)invalidate
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ROBDepthCloudFrame" object:nil];
    [self.freshnessTimer invalidate];
    self.freshnessTimer = nil;
    self.robo_scnView.playing = NO;
    self.robo_scnView.scene = nil;
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

- (SCNNode *)irBeamNodeForLateralDirection:(BOOL)lateral
{
    SCNBox *beam = [SCNBox boxWithWidth:0.025 height:0.025 length:1.0 chamferRadius:0.012];
    beam.firstMaterial = [self materialWithColor:NSColor.systemGrayColor emission:0.15];
    SCNNode *node = [SCNNode nodeWithGeometry:beam];
    node.eulerAngles = lateral ? SCNVector3Make(0, (float)M_PI_2, 0) : SCNVector3Zero;
    node.scale = SCNVector3Make(1, 1, 0.01);
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

    // A simple ground grid makes translation and rotation obvious without requiring robot art.
    SCNMaterial *gridMaterial = [self materialWithColor:[NSColor colorWithWhite:0.22 alpha:1]
                                               emission:0.05];
    for (NSInteger index = -6; index <= 6; index++) {
        SCNBox *lineX = [SCNBox boxWithWidth:6 height:0.004 length:0.008 chamferRadius:0];
        lineX.firstMaterial = gridMaterial;
        SCNNode *lineXNode = [SCNNode nodeWithGeometry:lineX];
        lineXNode.position = SCNVector3Make(0, 0.003, index * 0.5);
        [scene.rootNode addChildNode:lineXNode];

        SCNBox *lineZ = [SCNBox boxWithWidth:0.008 height:0.004 length:6 chamferRadius:0];
        lineZ.firstMaterial = gridMaterial;
        SCNNode *lineZNode = [SCNNode nodeWithGeometry:lineZ];
        lineZNode.position = SCNVector3Make(index * 0.5, 0.003, 0);
        [scene.rootNode addChildNode:lineZNode];
    }

    self.robotNode = [SCNNode node];
    [scene.rootNode addChildNode:self.robotNode];

    self.liveRGBCloudNode = [SCNNode node];
    self.liveRGBCloudNode.name = @"Live OAK RGB point cloud";
    [scene.rootNode addChildNode:self.liveRGBCloudNode];

    SCNBox *robotBody = [SCNBox boxWithWidth:0.72 height:0.46 length:0.56 chamferRadius:0.08];
    robotBody.materials = @[[self materialWithColor:[NSColor colorWithWhite:0.18 alpha:1] emission:0.05]];
    SCNNode *bodyNode = [SCNNode nodeWithGeometry:robotBody];
    bodyNode.position = SCNVector3Make(0, 0.34, 0);
    [self.robotNode addChildNode:bodyNode];

    SCNBox *tread = [SCNBox boxWithWidth:0.17 height:0.26 length:0.78 chamferRadius:0.06];
    self.leftTreadNode = [SCNNode nodeWithGeometry:[tread copy]];
    self.rightTreadNode = [SCNNode nodeWithGeometry:[tread copy]];
    self.leftTreadNode.position = SCNVector3Make(-0.43, 0.22, 0);
    self.rightTreadNode.position = SCNVector3Make(0.43, 0.22, 0);
    [self.robotNode addChildNode:self.leftTreadNode];
    [self.robotNode addChildNode:self.rightTreadNode];

    self.neckPanNode = [SCNNode node];
    self.neckPanNode.position = SCNVector3Make(0, 0.72, 0);
    [self.robotNode addChildNode:self.neckPanNode];
    SCNCylinder *neck = [SCNCylinder cylinderWithRadius:0.08 height:0.28];
    neck.firstMaterial = [self materialWithColor:NSColor.systemOrangeColor emission:0.25];
    SCNNode *neckBody = [SCNNode nodeWithGeometry:neck];
    neckBody.position = SCNVector3Make(0, 0.14, 0);
    [self.neckPanNode addChildNode:neckBody];
    SCNBox *cameraHead = [SCNBox boxWithWidth:0.30 height:0.17 length:0.20 chamferRadius:0.04];
    cameraHead.firstMaterial = [self materialWithColor:NSColor.systemOrangeColor emission:0.45];
    self.cameraHeadNode = [SCNNode nodeWithGeometry:cameraHead];
    self.cameraHeadNode.position = SCNVector3Make(0, 0.34, -0.03);
    [self.neckPanNode addChildNode:self.cameraHeadNode];

    // Sensor order matches the Base firmware telemetry: FL, FR, L, R, BL, BR.
    self.irBeamOrigins = @[
        [NSValue valueWithSCNVector3:SCNVector3Make(-0.22, 0.33, -0.30)],
        [NSValue valueWithSCNVector3:SCNVector3Make( 0.22, 0.33, -0.30)],
        [NSValue valueWithSCNVector3:SCNVector3Make(-0.52, 0.33,  0.00)],
        [NSValue valueWithSCNVector3:SCNVector3Make( 0.52, 0.33,  0.00)],
        [NSValue valueWithSCNVector3:SCNVector3Make(-0.22, 0.33,  0.30)],
        [NSValue valueWithSCNVector3:SCNVector3Make( 0.22, 0.33,  0.30)]
    ];
    self.irBeamDirections = @[
        [NSValue valueWithSCNVector3:SCNVector3Make( 0, 0, -1)],
        [NSValue valueWithSCNVector3:SCNVector3Make( 0, 0, -1)],
        [NSValue valueWithSCNVector3:SCNVector3Make(-1, 0,  0)],
        [NSValue valueWithSCNVector3:SCNVector3Make( 1, 0,  0)],
        [NSValue valueWithSCNVector3:SCNVector3Make( 0, 0,  1)],
        [NSValue valueWithSCNVector3:SCNVector3Make( 0, 0,  1)]
    ];
    NSMutableArray<SCNNode *> *irBeams = [NSMutableArray arrayWithCapacity:6];
    for (NSInteger index = 0; index < 6; index++) {
        BOOL lateral = index == 2 || index == 3;
        SCNNode *beamNode = [self irBeamNodeForLateralDirection:lateral];
        beamNode.position = self.irBeamOrigins[index].SCNVector3Value;
        [self.robotNode addChildNode:beamNode];
        [irBeams addObject:beamNode];
    }
    self.irBeamNodes = irBeams;

    self.leftControllerNode = [self controllerNodeWithColor:NSColor.systemCyanColor];
    self.rightControllerNode = [self controllerNodeWithColor:NSColor.systemGreenColor];
    [scene.rootNode addChildNode:self.leftControllerNode];
    [scene.rootNode addChildNode:self.rightControllerNode];

    self.statusTextNode = [self textNodeWithSize:30 position:SCNVector3Make(-1.1, 1.48, 0)];
    self.detailTextNode = [self textNodeWithSize:17 position:SCNVector3Make(-1.1, 1.30, 0)];
    self.irTextNode = [self textNodeWithSize:17 position:SCNVector3Make(-1.1, 1.10, 0)];
    self.irTextNode.hidden = YES;
    [scene.rootNode addChildNode:self.statusTextNode];
    [scene.rootNode addChildNode:self.detailTextNode];
    [scene.rootNode addChildNode:self.irTextNode];

    self.robo_scnView.scene = scene;
    self.robo_scnView.allowsCameraControl = YES;
    self.robo_scnView.showsStatistics = YES;
    self.robo_scnView.backgroundColor = NSColor.blackColor;
    [self renderUnavailableState:@"WAITING FOR RECEIVED CONTROLLER DATA"];
    [self renderIRUnavailableState:@"IR SENSORS: WAITING FOR BASE TELEMETRY"];
}

- (void)updateWithIRDistances:(NSArray<NSNumber *> *)distances receivedAtUptime:(NSTimeInterval)uptime
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateWithIRDistances:distances receivedAtUptime:uptime]; });
        return;
    }
    if (distances.count != 6) { return; }

    self.lastIRDistances = [distances copy];
    self.lastIRReceivedUptime = uptime;
    self.irTextNode.hidden = NO;
    [SCNTransaction begin];
    [SCNTransaction setAnimationDuration:0.12];
    for (NSInteger index = 0; index < 6; index++) {
        NSInteger centimeters = distances[index].integerValue;
        CGFloat displayLength = MIN(MAX(centimeters / 100.0, 0.05), 1.5);
        BOOL blocked = centimeters < ROBIRBlockedDistanceCentimeters;
        SCNVector3 origin = self.irBeamOrigins[index].SCNVector3Value;
        SCNVector3 direction = self.irBeamDirections[index].SCNVector3Value;
        SCNNode *beam = self.irBeamNodes[index];
        beam.position = SCNVector3Make(origin.x + direction.x * displayLength * 0.5,
                                      origin.y,
                                      origin.z + direction.z * displayLength * 0.5);
        beam.scale = SCNVector3Make(1, 1, displayLength);
        NSColor *color = blocked ? NSColor.systemRedColor : NSColor.systemGreenColor;
        beam.geometry.firstMaterial = [self materialWithColor:color emission:blocked ? 0.9 : 0.45];
    }
    [SCNTransaction commit];
    [self refreshIRState];
}

- (void)updateWithLegacyIRWarningFront:(BOOL)front back:(BOOL)back receivedAtUptime:(NSTimeInterval)uptime
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateWithLegacyIRWarningFront:front back:back receivedAtUptime:uptime];
        });
        return;
    }
    if (front) { self.lastLegacyIRFrontWarningUptime = uptime; }
    if (back) { self.lastLegacyIRBackWarningUptime = uptime; }
    self.receivedLegacyIRWarning = YES;
    self.irTextNode.hidden = NO;
    [self refreshIRState];
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
    self.leftTreadDemand = MAX(-0.5, MIN(0.5, model.touchPadPointL.y));
    self.rightTreadDemand = MAX(-0.5, MIN(0.5, model.touchPadPointR.y));
    self.treadCommandsAreActive = !model.tredBrakeLock
        && model.touchPadPointL.y > -999
        && model.touchPadPointR.y > -999;

    if (model.neckControlActive) {
        self.neckCommandIsActive = YES;
        self.neckPanDemand = model.neckPan;
        self.neckTiltDemand = model.neckTilt;
        self.neckPanNode.eulerAngles = SCNVector3Make(0, model.neckPan * (float)(M_PI / 3.0), 0);
        self.cameraHeadNode.eulerAngles = SCNVector3Make(-model.neckTilt * (float)M_PI_4, 0, 0);
    } else {
        self.neckCommandIsActive = NO;
    }
    self.gripperCommandIsActive = model.gripperControlActive;
    self.leftGripperClosed = model.leftGripperClosed;
    self.rightGripperClosed = model.rightGripperClosed;

    [self integrateRobotAtUptime:model.receivedAtUptime];

    [SCNTransaction begin];
    [SCNTransaction setAnimationDuration:0.08];
    [self applyModel:model toNode:self.leftControllerNode left:YES];
    [self applyModel:model toNode:self.rightControllerNode left:NO];
    [self updateTreadNode:self.leftTreadNode demand:self.leftTreadDemand * 2.0 color:NSColor.systemCyanColor];
    [self updateTreadNode:self.rightTreadNode demand:self.rightTreadDemand * 2.0 color:NSColor.systemGreenColor];
    [SCNTransaction commit];
    [self refreshFreshness:nil];
}

- (void)integrateRobotAtUptime:(NSTimeInterval)uptime
{
    NSTimeInterval previous = self.lastRobotIntegrationUptime;
    self.lastRobotIntegrationUptime = uptime;
    if (!self.treadCommandsAreActive || previous <= 0 || uptime <= previous) { return; }

    // Clamp integration time so a delayed packet can never teleport the diagnostic robot.
    NSTimeInterval deltaTime = MIN(uptime - previous, ROBControllerDiagnosticStaleInterval);
    CGFloat leftVelocity = self.leftTreadDemand * 2.0 * ROBDiagnosticMaximumTreadSpeed;
    CGFloat rightVelocity = self.rightTreadDemand * 2.0 * ROBDiagnosticMaximumTreadSpeed;
    CGFloat linearVelocity = (leftVelocity + rightVelocity) * 0.5;
    // SceneKit's local forward direction is -Z and positive yaw rotates it toward -X.
    // A faster left tread therefore produces positive SceneKit yaw.
    CGFloat angularVelocity = (leftVelocity - rightVelocity) / ROBDiagnosticTrackWidth;
    CGFloat previousHeading = self.robotNode.eulerAngles.y;
    CGFloat headingDelta = angularVelocity * deltaTime;
    CGFloat midpointHeading = previousHeading + headingDelta * 0.5;
    CGFloat heading = previousHeading + headingDelta;
    SCNVector3 position = self.robotNode.position;
    // Integrating at the midpoint heading follows the differential-drive arc instead of
    // translating along the final angle for the entire packet interval.
    position.x -= sin(midpointHeading) * linearVelocity * deltaTime;
    position.z -= cos(midpointHeading) * linearVelocity * deltaTime;

    [SCNTransaction begin];
    [SCNTransaction setAnimationDuration:MIN(deltaTime, 0.1)];
    self.robotNode.position = position;
    self.robotNode.eulerAngles = SCNVector3Make(0, heading, 0);
    [SCNTransaction commit];
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
    [self refreshIRState];
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
    NSString *driveState = self.treadCommandsAreActive ? @"DRIVE ACTIVE" : @"BRAKED";
    NSString *neckState = self.neckCommandIsActive
        ? [NSString stringWithFormat:@"HEAD %+.2f / %+.2f", self.neckPanDemand, self.neckTiltDemand]
        : @"HEAD HELD";
    NSString *gripperState = self.gripperCommandIsActive
        ? [NSString stringWithFormat:@"GRIP CMD L:%@ R:%@",
           self.leftGripperClosed ? @"CLOSED" : @"OPEN",
           self.rightGripperClosed ? @"CLOSED" : @"OPEN"]
        : @"GRIP HELD";
    detail.string = [NSString stringWithFormat:@"%@  •  %.0f ms  •  %@  •  %@  •  %@  •  TREADS %+.2f / %+.2f  •  L:%@  R:%@",
                     self.lastSender, age * 1000.0,
                     driveState, neckState, gripperState, self.leftTreadDemand, self.rightTreadDemand,
                     self.leftPoseValid ? @"POSE" : @"NO POSE",
                     self.rightPoseValid ? @"POSE" : @"NO POSE"];
}

- (void)refreshIRState
{
    if (self.lastIRDistances.count != 6 && self.receivedLegacyIRWarning) {
        [self refreshLegacyIRWarningState];
        return;
    }
    NSTimeInterval age = self.lastIRReceivedUptime > 0
        ? NSProcessInfo.processInfo.systemUptime - self.lastIRReceivedUptime
        : DBL_MAX;
    if (age > ROBIRDiagnosticStaleInterval || self.lastIRDistances.count != 6) {
        [self renderIRUnavailableState:self.lastIRReceivedUptime > 0 ? @"IR SENSORS: DATA STALE" : @"IR SENSORS: WAITING FOR BASE TELEMETRY"];
        return;
    }

    NSArray<NSString *> *names = @[@"FL", @"FR", @"L", @"R", @"BL", @"BR"];
    NSMutableArray<NSString *> *readings = [NSMutableArray arrayWithCapacity:6];
    BOOL anyBlocked = NO;
    for (NSInteger index = 0; index < 6; index++) {
        NSInteger centimeters = self.lastIRDistances[index].integerValue;
        BOOL blocked = centimeters < ROBIRBlockedDistanceCentimeters;
        anyBlocked |= blocked;
        [readings addObject:[NSString stringWithFormat:@"%@:%ldcm%@", names[index], (long)centimeters, blocked ? @"!" : @""]];
    }
    SCNText *text = (SCNText *)self.irTextNode.geometry;
    text.string = [NSString stringWithFormat:@"IR %@  •  %@  •  %.0f ms",
                   anyBlocked ? @"BLOCKED" : @"PATH CLEAR",
                   [readings componentsJoinedByString:@"  "], age * 1000.0];
    text.firstMaterial.diffuse.contents = anyBlocked ? NSColor.systemRedColor : NSColor.systemGreenColor;
}

- (void)refreshLegacyIRWarningState
{
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL frontRecent = self.lastLegacyIRFrontWarningUptime > 0 &&
        now - self.lastLegacyIRFrontWarningUptime <= ROBLegacyIRWarningDisplayInterval;
    BOOL backRecent = self.lastLegacyIRBackWarningUptime > 0 &&
        now - self.lastLegacyIRBackWarningUptime <= ROBLegacyIRWarningDisplayInterval;

    NSColor *frontColor = frontRecent ? NSColor.systemRedColor : NSColor.systemGrayColor;
    NSColor *backColor = backRecent ? NSColor.systemRedColor : NSColor.systemGrayColor;
    for (NSInteger index = 0; index < self.irBeamNodes.count; index++) {
        NSColor *color = NSColor.systemGrayColor;
        if (index == 0 || index == 1) { color = frontColor; }
        if (index == 4 || index == 5) { color = backColor; }
        BOOL warningBeam = ((index == 0 || index == 1) && frontRecent) ||
            ((index == 4 || index == 5) && backRecent);
        CGFloat length = warningBeam ? 0.55 : 0.01;
        SCNVector3 origin = self.irBeamOrigins[index].SCNVector3Value;
        SCNVector3 direction = self.irBeamDirections[index].SCNVector3Value;
        SCNNode *beam = self.irBeamNodes[index];
        beam.position = SCNVector3Make(origin.x + direction.x * length * 0.5,
                                      origin.y,
                                      origin.z + direction.z * length * 0.5);
        beam.scale = SCNVector3Make(1, 1, length);
        beam.geometry.firstMaterial =
            [self materialWithColor:color emission:(frontRecent || backRecent) ? 0.8 : 0.1];
    }

    SCNText *text = (SCNText *)self.irTextNode.geometry;
    if (frontRecent || backRecent) {
        NSString *location = frontRecent && backRecent ? @"FRONT + BACK" : (frontRecent ? @"FRONT" : @"BACK");
        text.string = [NSString stringWithFormat:@"IR OBSTACLE WARNING: %@  •  ADVISORY ONLY", location];
        text.firstMaterial.diffuse.contents = NSColor.systemRedColor;
    } else {
        text.string = @"IR: NO RECENT WARNING  •  CLEARANCE UNKNOWN  •  USE RPLIDAR FOR PATHS";
        text.firstMaterial.diffuse.contents = NSColor.systemOrangeColor;
    }
}

- (void)renderIRUnavailableState:(NSString *)message
{
    SCNText *text = (SCNText *)self.irTextNode.geometry;
    text.string = message;
    text.firstMaterial.diffuse.contents = NSColor.systemOrangeColor;
    for (SCNNode *beam in self.irBeamNodes) {
        beam.geometry.firstMaterial = [self materialWithColor:NSColor.systemGrayColor emission:0.1];
    }
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
    self.treadCommandsAreActive = NO;
    [self updateTreadNode:self.leftTreadNode demand:0 color:NSColor.systemCyanColor];
    [self updateTreadNode:self.rightTreadNode demand:0 color:NSColor.systemGreenColor];
}

- (void)receivedDepthCloudFrame:(NSNotification *)notification
{
    ROBDepthCloudFrame *frame = [notification.object isKindOfClass:ROBDepthCloudFrame.class]
        ? notification.object : nil;
    if (frame == nil || self.cloudUpdatePending) return;
    self.cloudUpdatePending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        SCNMatrix4 robotTransform = self.robotNode.presentationNode.worldTransform;
        dispatch_async(self.cloudQueue, ^{
            [self processDepthFrame:frame robotTransform:robotTransform];
        });
    });
}

- (SCNGeometry *)pointGeometry:(NSArray<NSValue *> *)points colors:(NSArray<NSNumber *> *)colors pointSize:(CGFloat)size
{
    if (points.count == 0) return nil;
    // SCNVector3 uses three 64-bit CGFloat values on macOS (24 bytes), while
    // this geometry source explicitly advertises three 32-bit floats. Packing
    // the vertices removes the stride mismatch that rendered surfaces as a
    // small number of vertical pixel columns.
    typedef struct { float x, y, z; } ROBPackedPoint3;
    NSMutableData *vertexData = [NSMutableData dataWithLength:points.count * sizeof(ROBPackedPoint3)];
    ROBPackedPoint3 *vertices = vertexData.mutableBytes;
    NSMutableData *indexData = [NSMutableData dataWithLength:points.count * sizeof(uint32_t)];
    uint32_t *indices = indexData.mutableBytes;
    NSMutableData *colorData = [NSMutableData dataWithLength:points.count * 4];
    uint8_t *packedColors = colorData.mutableBytes;
    for (NSUInteger index = 0; index < points.count; index++) {
        SCNVector3 point = points[index].SCNVector3Value;
        vertices[index] = (ROBPackedPoint3){(float)point.x, (float)point.y, (float)point.z};
        indices[index] = (uint32_t)index;
        uint32_t rgba = index < colors.count ? colors[index].unsignedIntValue : 0xFFFFFFFF;
        packedColors[index * 4] = (rgba >> 24) & 0xFF;
        packedColors[index * 4 + 1] = (rgba >> 16) & 0xFF;
        packedColors[index * 4 + 2] = (rgba >> 8) & 0xFF;
        packedColors[index * 4 + 3] = rgba & 0xFF;
    }
    SCNGeometrySource *source = [SCNGeometrySource geometrySourceWithData:vertexData
                                                                 semantic:SCNGeometrySourceSemanticVertex
                                                              vectorCount:points.count
                                                          floatComponents:YES
                                                      componentsPerVector:3
                                                        bytesPerComponent:sizeof(float)
                                                               dataOffset:0
                                                               dataStride:sizeof(ROBPackedPoint3)];
    SCNGeometrySource *colorSource = [SCNGeometrySource geometrySourceWithData:colorData
                                                                      semantic:SCNGeometrySourceSemanticColor
                                                                   vectorCount:points.count
                                                               floatComponents:NO
                                                           componentsPerVector:4
                                                             bytesPerComponent:1
                                                                    dataOffset:0
                                                                    dataStride:4];
    SCNGeometryElement *element = [SCNGeometryElement geometryElementWithData:indexData
                                                                primitiveType:SCNGeometryPrimitiveTypePoint
                                                               primitiveCount:points.count
                                                                bytesPerIndex:sizeof(uint32_t)];
    element.pointSize = size;
    element.minimumPointScreenSpaceRadius = 1;
    element.maximumPointScreenSpaceRadius = 4;
    SCNGeometry *geometry = [SCNGeometry geometryWithSources:@[source, colorSource] elements:@[element]];
    SCNMaterial *material = [SCNMaterial material];
    material.diffuse.contents = NSColor.whiteColor;
    material.lightingModelName = SCNLightingModelConstant;
    geometry.firstMaterial = material;
    return geometry;
}

- (void)processDepthFrame:(ROBDepthCloudFrame *)frame robotTransform:(SCNMatrix4)robotTransform
{
    const uint8_t *bytes = frame.millimetersLittleEndian.bytes;
    NSInteger width = frame.width, height = frame.height;
    float focal = (float)width / (2.0f * tanf(69.0f * (float)M_PI / 360.0f));
    float cx = (float)(width - 1) / 2.0f, cy = (float)(height - 1) / 2.0f;
    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:(width / 4) * (height / 4)];
    NSMutableArray<NSNumber *> *colors = [NSMutableArray arrayWithCapacity:(width / 4) * (height / 4)];
    CVPixelBufferRef rgb = frame.rgbPixelBuffer;
    if (rgb != NULL) CVPixelBufferLockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly);
    uint8_t *rgbBase = rgb != NULL ? CVPixelBufferGetBaseAddress(rgb) : NULL;
    size_t rgbRowBytes = rgb != NULL ? CVPixelBufferGetBytesPerRow(rgb) : 0;
    size_t rgbWidth = rgb != NULL ? CVPixelBufferGetWidth(rgb) : 0;
    size_t rgbHeight = rgb != NULL ? CVPixelBufferGetHeight(rgb) : 0;

    for (NSInteger y = 0; y < height; y += 4) {
        for (NSInteger x = 0; x < width; x += 4) {
            NSInteger offset = (y * width + x) * 2;
            uint16_t mm = bytes[offset] | ((uint16_t)bytes[offset + 1] << 8);
            if (mm < 150 || mm > 10000) continue;
            float z = (float)mm / 1000.0f;
            SCNVector3 local = SCNVector3Make(((float)x - cx) * z / focal,
                                              1.05f - ((float)y - cy) * z / focal,
                                              -z);
            SCNVector3 world = SCNVector3Make(
                robotTransform.m11 * local.x + robotTransform.m21 * local.y + robotTransform.m31 * local.z + robotTransform.m41,
                robotTransform.m12 * local.x + robotTransform.m22 * local.y + robotTransform.m32 * local.z + robotTransform.m42,
                robotTransform.m13 * local.x + robotTransform.m23 * local.y + robotTransform.m33 * local.z + robotTransform.m43
            );
            uint32_t rgba = 0x80D8FFFF;
            if (rgbBase != NULL && x < rgbWidth && y < rgbHeight) {
                uint8_t *pixel = rgbBase + y * rgbRowBytes + x * 4;
                rgba = ((uint32_t)pixel[2] << 24) | ((uint32_t)pixel[1] << 16) |
                       ((uint32_t)pixel[0] << 8) | 0xFF;
            }
            [points addObject:[NSValue valueWithSCNVector3:world]];
            [colors addObject:@(rgba)];
        }
    }
    if (rgb != NULL) CVPixelBufferUnlockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly);
    SCNGeometry *geometry = [self pointGeometry:points colors:colors pointSize:2];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.liveRGBCloudNode.geometry = geometry;
        self.cloudUpdatePending = NO;
    });
}

@end
