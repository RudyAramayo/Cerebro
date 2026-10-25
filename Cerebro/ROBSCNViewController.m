#import "ROBSCNViewController.h"
#import "ROBBaseControllerModel.h"
#import "ROBSerialBox.h"
#import "ROBDepthCloudProjection.h"
#import "ROBDepthFloorRectification.h"
#import <QuartzCore/QuartzCore.h>
#import <simd/quaternion.h>
#import "Cerebro-Swift.h"

static NSTimeInterval const ROBControllerDiagnosticStaleInterval = 0.5;
static NSTimeInterval const ROBIRDiagnosticStaleInterval = 0.75;
static NSTimeInterval const ROBLegacyIRWarningDisplayInterval = 3.0;
static NSInteger const ROBIRBlockedDistanceCentimeters = 25;
static CGFloat const ROBDiagnosticMaximumTreadSpeed = 0.9;
static CGFloat const ROBDiagnosticTrackWidth = 0.86;
static NSUInteger const ROBMaximumDisplayedCloudPoints = 20000;
static NSUInteger const ROBMaximumFloorCandidatePoints = 2048;
static NSTimeInterval const ROBFloorNoiseHoldInterval = 0.25;

// Display-only backpressure. Other notification observers and raw camera/vision
// feeds still receive every frame through their existing independent admission.
// No SceneKit access or dispatch occurs while this mailbox lock is held.
@interface ROBSCNDepthCloudDisplayMailbox : NSObject {
    NSLock *_lock;
    ROBDepthCloudFrame *_latestHead;
    ROBDepthCloudFrame *_latestBelly;
    BOOL _mainDrainScheduled;
    BOOL _closed;
}
- (BOOL)offerFrame:(ROBDepthCloudFrame *)frame;
- (NSArray<ROBDepthCloudFrame *> *)takeLatestFrames;
- (void)close;
@end

@implementation ROBSCNDepthCloudDisplayMailbox
- (instancetype)init
{
    self = [super init];
    if (self) _lock = [[NSLock alloc] init];
    return self;
}
- (BOOL)offerFrame:(ROBDepthCloudFrame *)frame
{
    [_lock lock];
    if (_closed) { [_lock unlock]; return NO; }
    if (frame.isBelly) _latestBelly = frame; else _latestHead = frame;
    BOOL schedule = !_mainDrainScheduled;
    _mainDrainScheduled = YES;
    [_lock unlock];
    return schedule;
}
- (NSArray<ROBDepthCloudFrame *> *)takeLatestFrames
{
    [_lock lock];
    ROBDepthCloudFrame *head = _closed ? nil : _latestHead;
    ROBDepthCloudFrame *belly = _closed ? nil : _latestBelly;
    _latestHead = nil; _latestBelly = nil;
    _mainDrainScheduled = NO;
    [_lock unlock];
    if (head && belly) return @[head, belly];
    if (head) return @[head];
    if (belly) return @[belly];
    return @[];
}
- (void)close
{
    [_lock lock];
    _closed = YES;
    _latestHead = nil; _latestBelly = nil;
    _mainDrainScheduled = NO;
    [_lock unlock];
}
@end

// The operator identified the wooden floor as a level reference. Select only
// lower-image points outside the robot's footprint. The candidate height wedge
// must admit every plane allowed by the fitter; a narrow raw-Y band clips a
// tilted floor into a line before its orientation can be estimated. RGB wood
// colour is not evidence that a surface is the floor.
static BOOL ROBFloorCandidateHeightIsPlausible(ROBDepthFloorPoint point)
{
    ROBDepthFloorOptions options = ROBDepthFloorDefaultOptions();
    return fabs(point.y) <= options.maximumVerticalOffsetMeters +
        hypot(point.x, point.z) * tan(options.maximumTiltRadians);
}

static BOOL ROBIsFloorCandidate(ROBDepthFloorPoint point, double opticalDepth,
                               NSInteger x, NSInteger y, NSInteger width, NSInteger height)
{
    double radius = hypot(point.x, point.z);
    return y >= height * 0.55 && x >= width * 0.08 && x <= width * 0.92 &&
        opticalDepth >= 0.35 && opticalDepth <= 4.0 &&
        isfinite(point.x) && isfinite(point.y) && isfinite(point.z) &&
        ROBFloorCandidateHeightIsPlausible(point) && radius >= 0.65 && radius <= 4.0;
}

static NSString *ROBDiagnosticInhibitReason(NSString *reason)
{
    if ([reason isEqualToString:@"operatorDisarmed"]) return @"CONTROL NOT REQUESTED";
    if ([reason isEqualToString:@"deadManReleased"]) return @"BOTH GRIPS REQUIRED";
    if ([reason isEqualToString:@"inputExpired"]) return @"CONTROLLER INPUT EXPIRED";
    if ([reason isEqualToString:@"sceneInactive"]) return @"VISION APP INACTIVE";
    if ([reason isEqualToString:@"controllerDisconnected"]) return @"CONTROLLERS DISCONNECTED";
    if ([reason isEqualToString:@"emergencyStop"]) return @"EMERGENCY STOP";
    if ([reason isEqualToString:@"transportFailure"]) return @"TRANSPORT FAILURE";
    if ([reason isEqualToString:@"robotWatchdog"]) return @"ROBOT WATCHDOG";
    if ([reason isEqualToString:@"disconnected"]) return @"VISION APP DISCONNECTED";
    if ([reason isEqualToString:@"userRequested"]) return @"STOP REQUESTED";
    return nil;
}

@interface ROBSCNViewController ()
@property (readwrite, retain) SCNNode *leftControllerNode;
@property (readwrite, retain) SCNNode *rightControllerNode;
@property (readwrite, retain) SCNNode *robotNode;
@property (readwrite, strong) ROBGhostGestureEditor *ghostGestureEditor;
@property (readwrite, retain) SCNNode *leftTreadNode;
@property (readwrite, retain) SCNNode *rightTreadNode;
@property (readwrite, retain) SCNNode *neckPanNode;
@property (readwrite, retain) SCNNode *cameraHeadNode;
@property (readwrite, retain) NSTextField *statusLabel;
@property (readwrite, retain) NSTextField *detailLabel;
@property (readwrite, retain) NSTextField *irStatusLabel;
@property (readwrite, retain) NSTextField *cloudStatusLabel;
@property (readwrite, retain) NSTextField *floorStatusLabel;
@property (readwrite, copy) NSString *headFloorSummary;
@property (readwrite, copy) NSString *bellyFloorSummary;
@property NSTimeInterval lastHeadCloudUptime;
@property NSTimeInterval lastBellyCloudUptime;
@property NSTimeInterval bellyCloudDisplayUntil;
@property BOOL headFloorAlignmentEstablished;
@property BOOL bellyFloorAlignmentEstablished;
@property BOOL headFloorHoldingAcceptedFrame;
@property BOOL headCloudHasCalibratedIntrinsics;
@property BOOL bellyFloorHoldingAcceptedFrame;
@property (copy) NSArray *headFloorCloudContext;
@property (copy) NSArray *bellyFloorCloudContext;
@property NSTimeInterval lastHeadCloudSubmission;
@property NSTimeInterval lastBellyCloudSubmission;
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
@property (readwrite, copy) NSString *motionInhibitReason;
@property (readwrite, assign) BOOL neckCommandIsActive;
@property (readwrite, assign) CGFloat neckPanDemand;
@property (readwrite, assign) CGFloat neckTiltDemand;
@property (readwrite, assign) BOOL gripperCommandIsActive;
@property (readwrite, assign) BOOL leftGripperClosed;
@property (readwrite, assign) BOOL rightGripperClosed;
@property (readwrite, assign) NSTimeInterval lastRobotIntegrationUptime;
@property (readwrite, retain) SCNNode *liveRGBCloudNode;
@property (readwrite, retain) SCNNode *liveBellyRGBCloudNode;
@property (readwrite, strong) dispatch_queue_t cloudQueue;
@property (nonatomic, strong) ROBSCNDepthCloudDisplayMailbox *cloudDisplayMailbox;
@property (readwrite, assign) BOOL cloudUpdatePending;
@property (readwrite, assign) BOOL bellyCloudUpdatePending;
@end

@implementation ROBSCNViewController

- (instancetype)initWithRobo_scnView:(SCNView *)scnView
{
    self = [super init];
    if (self) {
        self.robo_scnView = scnView;
        self.lastSender = @"No controller";
        [self loadScene];
        self.ghostGestureEditor = [[ROBGhostGestureEditor alloc] initWithSceneView:scnView originalRobot:self.robotNode];
        self.cloudQueue = dispatch_queue_create("com.orbitusrobotics.Cerebro.live-rgb-cloud", DISPATCH_QUEUE_SERIAL);
        self.cloudDisplayMailbox = [[ROBSCNDepthCloudDisplayMailbox alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedDepthCloudFrame:)
                                                     name:@"ROBDepthCloudFrame" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(armTrialViewPrepared:)
                                                     name:@"ROBLeftArmTrialViewPrepared" object:nil];
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
    [self.cloudDisplayMailbox close];
    [self.ghostGestureEditor invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ROBDepthCloudFrame" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ROBLeftArmTrialViewPrepared" object:nil];
    [self.freshnessTimer invalidate];
    self.freshnessTimer = nil;
    self.robo_scnView.playing = NO;
    self.robo_scnView.scene = nil;
}

- (NSView *)ghostGesturePanel
{
    return self.ghostGestureEditor.panelView;
}

- (void)reviewGhostPreset:(NSString *)name
{
    [self.ghostGestureEditor reviewPresetNamed:name];
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

- (NSTextField *)hudLabelWithSize:(CGFloat)size weight:(NSFontWeight)weight
{
    NSTextField *label = [NSTextField wrappingLabelWithString:@""];
    label.font = [NSFont monospacedSystemFontOfSize:size weight:weight];
    label.textColor = NSColor.whiteColor;
    label.maximumNumberOfLines = 2;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)installBottomHUD
{
    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    background.material = NSVisualEffectMaterialHUDWindow;
    background.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    background.state = NSVisualEffectStateActive;
    background.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = [self hudLabelWithSize:15 weight:NSFontWeightBold];
    self.detailLabel = [self hudLabelWithSize:11 weight:NSFontWeightMedium];
    self.irStatusLabel = [self hudLabelWithSize:11 weight:NSFontWeightMedium];
    self.cloudStatusLabel = [self hudLabelWithSize:10 weight:NSFontWeightRegular];
    self.cloudStatusLabel.stringValue = @"HEAD DEPTH: waiting for a settled neck command";
    self.floorStatusLabel = [self hudLabelWithSize:10 weight:NSFontWeightRegular];
    self.floorStatusLabel.maximumNumberOfLines = 4;
    self.floorStatusLabel.stringValue = @"FLAT FLOOR REFERENCE: waiting for sufficient visible floor";
    NSStackView *stack = [NSStackView stackViewWithViews:@[self.statusLabel, self.detailLabel, self.irStatusLabel, self.cloudStatusLabel, self.floorStatusLabel]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 3;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:stack];
    [self.robo_scnView addSubview:background positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [background.leadingAnchor constraintEqualToAnchor:self.robo_scnView.leadingAnchor],
        [background.trailingAnchor constraintEqualToAnchor:self.robo_scnView.trailingAnchor],
        [background.bottomAnchor constraintEqualToAnchor:self.robo_scnView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-14],
        [stack.topAnchor constraintEqualToAnchor:background.topAnchor constant:9],
        [stack.bottomAnchor constraintEqualToAnchor:background.bottomAnchor constant:-10]
    ]];
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
    cameraNode.camera.wantsHDR = YES;
    cameraNode.camera.exposureOffset = -1;
    cameraNode.position = SCNVector3Make(1.6, 1.45, -3.1);
    [cameraNode lookAt:SCNVector3Make(0, 0.85, 0)];
    [scene.rootNode addChildNode:cameraNode];

    SCNNode *lightNode = [SCNNode node];
    lightNode.light = [SCNLight light];
    lightNode.light.type = SCNLightTypeOmni;
    lightNode.light.intensity = 800;
    lightNode.position = SCNVector3Make(1, 2.5, -2);
    [scene.rootNode addChildNode:lightNode];
    scene.lightingEnvironment.intensity = 0.6;
    SCNNode *fillLight = [SCNNode node];
    fillLight.light = [SCNLight light];
    fillLight.light.type = SCNLightTypeAmbient;
    fillLight.light.intensity = 120;
    [scene.rootNode addChildNode:fillLight];

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

    self.robotNode = [ROBScanVisualModel makeRobot];
    [scene.rootNode addChildNode:self.robotNode];

    self.liveRGBCloudNode = [SCNNode node];
    self.liveRGBCloudNode.name = @"Live OAK RGB point cloud";
    [scene.rootNode addChildNode:self.liveRGBCloudNode];

    self.liveBellyRGBCloudNode = [SCNNode node];
    self.liveBellyRGBCloudNode.name = @"Live Belly RGB point cloud";
    [scene.rootNode addChildNode:self.liveBellyRGBCloudNode];

    // All three products consume the same scan-informed mesh hierarchy.
    self.leftTreadNode = [self.robotNode childNodeWithName:@"Left Tri-Wheel Tread" recursively:YES];
    self.rightTreadNode = [self.robotNode childNodeWithName:@"Right Tri-Wheel Tread" recursively:YES];
    self.neckPanNode = [self.robotNode childNodeWithName:@"Neck Pan" recursively:YES];
    self.cameraHeadNode = [self.robotNode childNodeWithName:@"Camera Head Pivot" recursively:YES];
    for (SCNNode *tread in @[self.leftTreadNode, self.rightTreadNode]) {
        // Each captured tread needs an independent demand highlight.
        tread.geometry.firstMaterial = [tread.geometry.firstMaterial copy];
        [tread enumerateChildNodesUsingBlock:^(SCNNode *child, BOOL *stop) {
            if ([child.name containsString:@"Tread Shoe"]) {
                child.geometry.firstMaterial = [child.geometry.firstMaterial copy];
            }
        }];
    }
    // Flippers remain at the reference pose: this controller stream has no
    // measured flipper angle. Do not portray open-loop demands as telemetry.

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

    self.robo_scnView.scene = scene;
    self.robo_scnView.pointOfView = cameraNode;
    self.robo_scnView.allowsCameraControl = YES;
    self.robo_scnView.preferredFramesPerSecond = 30;
    self.robo_scnView.rendersContinuously = YES;
    self.robo_scnView.playing = YES;
    self.robo_scnView.defaultCameraController.target = SCNVector3Make(0, 0.78, 0);
    self.robo_scnView.showsStatistics = YES;
    self.robo_scnView.backgroundColor = NSColor.blackColor;
    [self installBottomHUD];
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
    self.irStatusLabel.hidden = NO;
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
    self.irStatusLabel.hidden = NO;
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
    BOOL leftTreadIsActive = model.touchPadPointL.y > -999;
    BOOL rightTreadIsActive = model.touchPadPointR.y > -999;
    self.leftTreadDemand = leftTreadIsActive
        ? MAX(-0.5, MIN(0.5, model.touchPadPointL.y)) : 0;
    self.rightTreadDemand = rightTreadIsActive
        ? MAX(-0.5, MIN(0.5, model.touchPadPointR.y)) : 0;
    self.treadCommandsAreActive = !model.tredBrakeLock
        && leftTreadIsActive
        && rightTreadIsActive;
    self.motionInhibitReason = model.motionInhibitReason;

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
    // Highlight tread demand without stretching ROB's physical silhouette.
    node.geometry.firstMaterial.emission.contents = fabs(bounded) < 0.02
        ? NSColor.blackColor : [color colorWithAlphaComponent:fabs(bounded) * 0.65];
    [node enumerateChildNodesUsingBlock:^(SCNNode *child, BOOL *stop) {
        if ([child.name containsString:@"Tread Shoe"]) {
            SCNMaterial *material = child.geometry.firstMaterial;
            material.emission.contents = fabs(bounded) < 0.02
                ? NSColor.blackColor : [color colorWithAlphaComponent:fabs(bounded) * 0.65];
        }
    }];
}

- (void)refreshFreshness:(NSTimer *)timer
{
    [self refreshIRState];
    [self refreshHeadModelEstimate];
    NSTimeInterval cloudNow = NSProcessInfo.processInfo.systemUptime;
    [self refreshFloorCloudVisibilityAtUptime:cloudNow];
    [self refreshFloorStatus];
    NSTimeInterval age = self.lastReceivedUptime > 0
        ? NSProcessInfo.processInfo.systemUptime - self.lastReceivedUptime
        : DBL_MAX;
    if (age > ROBControllerDiagnosticStaleInterval) {
        [self renderUnavailableState:self.lastReceivedUptime > 0 ? @"CONTROLLER DATA STALE" : @"NO CONTROLLER DATA RECEIVED"];
        return;
    }
    self.statusLabel.stringValue = @"RECEIVING VR CONTROLLER INPUT";
    self.statusLabel.textColor = NSColor.systemGreenColor;
    NSString *inhibitReason = ROBDiagnosticInhibitReason(self.motionInhibitReason);
    NSString *driveState = self.treadCommandsAreActive
        ? @"DRIVE ACTIVE"
        : (inhibitReason.length > 0
            ? [NSString stringWithFormat:@"BRAKED: %@", inhibitReason]
            : @"BRAKED");
    NSString *neckState = self.neckCommandIsActive
        ? [NSString stringWithFormat:@"HEAD %+.2f / %+.2f", self.neckPanDemand, self.neckTiltDemand]
        : @"HEAD COMMAND IDLE";
    NSString *gripperState = self.gripperCommandIsActive
        ? [NSString stringWithFormat:@"GRIP CMD L:%@ R:%@",
           self.leftGripperClosed ? @"CLOSED" : @"OPEN",
           self.rightGripperClosed ? @"CLOSED" : @"OPEN"]
        : @"GRIP COMMAND IDLE";
    NSString *treadState = self.treadCommandsAreActive
        ? [NSString stringWithFormat:@"TREADS %+.2f / %+.2f", self.leftTreadDemand, self.rightTreadDemand]
        : @"TREADS INACTIVE";
    self.detailLabel.stringValue = [NSString stringWithFormat:@"%@  •  %.0f ms  •  %@  •  %@  •  %@  •  %@  •  L:%@  R:%@",
                     self.lastSender, age * 1000.0,
                     driveState, neckState, gripperState, treadState,
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
    self.irStatusLabel.stringValue = [NSString stringWithFormat:@"IR %@  •  %@  •  %.0f ms",
                   anyBlocked ? @"BLOCKED" : @"PATH CLEAR",
                   [readings componentsJoinedByString:@"  "], age * 1000.0];
    self.irStatusLabel.textColor = anyBlocked ? NSColor.systemRedColor : NSColor.systemGreenColor;
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

    if (frontRecent || backRecent) {
        NSString *location = frontRecent && backRecent ? @"FRONT + BACK" : (frontRecent ? @"FRONT" : @"BACK");
        self.irStatusLabel.stringValue = [NSString stringWithFormat:@"IR OBSTACLE WARNING: %@  •  ADVISORY ONLY", location];
        self.irStatusLabel.textColor = NSColor.systemRedColor;
    } else {
        self.irStatusLabel.stringValue = @"IR: NO RECENT WARNING  •  CLEARANCE UNKNOWN  •  USE RPLIDAR FOR PATHS";
        self.irStatusLabel.textColor = NSColor.systemOrangeColor;
    }
}

- (void)renderIRUnavailableState:(NSString *)message
{
    self.irStatusLabel.stringValue = message;
    self.irStatusLabel.textColor = NSColor.systemOrangeColor;
    for (SCNNode *beam in self.irBeamNodes) {
        beam.geometry.firstMaterial = [self materialWithColor:NSColor.systemGrayColor emission:0.1];
    }
}

- (void)renderUnavailableState:(NSString *)message
{
    self.statusLabel.stringValue = message;
    self.statusLabel.textColor = NSColor.systemRedColor;
    self.detailLabel.stringValue = [NSString stringWithFormat:@"%@  •  expected packet interval < 500 ms", self.lastSender];
    self.leftControllerNode.hidden = YES;
    self.rightControllerNode.hidden = YES;
    self.treadCommandsAreActive = NO;
    [self updateTreadNode:self.leftTreadNode demand:0 color:NSColor.systemCyanColor];
    [self updateTreadNode:self.rightTreadNode demand:0 color:NSColor.systemGreenColor];
}

- (void)refreshHeadModelEstimate
{
    ROBSerialBox *serial = self.serialBox;
    ROBNeckSafetyConfig config = serial ? [serial neckSafetyConfiguration] : ROBNeckSafetyDefaultConfig();
    double pan = 0;
    BOOL known = serial.isNeckCommandStateKnown &&
        ROBNeckSafetyPanTargetToDegrees(&config, (int32_t)serial.commandedNeckPanTarget, &pan);
    // Use accepted targets and the operator-observed display reference once.
    // Driver safety/clearance positions do not calibrate camera geometry.
    // Optional leveling gains and old cloud frames do not define this pose.
    ROBHeadCameraPoseEstimator *pose = [ROBHeadCameraPoseEstimator estimateDisplayPanRadians:pan * M_PI / 180.0
        lowerTarget:serial.commandedLowerNeckTiltTarget upperTarget:serial.commandedUpperNeckTiltTarget
        known:known];
    [self.ghostGestureEditor setRawHeadPanTarget:serial.commandedNeckPanTarget lowerTarget:serial.commandedLowerNeckTiltTarget
        upperTarget:serial.commandedUpperNeckTiltTarget known:known];
    [self.ghostGestureEditor setHeadCommandEstimate:pose];
}

- (void)refreshFloorStatus
{
    NSString *head = self.headFloorSummary ?: @"HEAD: acquiring floor";
    NSString *belly = self.bellyFloorSummary ?: @"BELLY: acquiring floor";
    double now = NSProcessInfo.processInfo.systemUptime;
    if (self.liveRGBCloudNode.hidden) {
        head = [head stringByAppendingString:@" · CLOUD HIDDEN"];
        self.cloudStatusLabel.stringValue = @"HEAD DEPTH HIDDEN: waiting for a fresh settled view";
    }
    else if (self.headFloorHoldingAcceptedFrame) {
        head = [head stringByAppendingFormat:@" · HELD %.1f s old at capture pose", MAX(0, now-self.lastHeadCloudUptime)];
        self.cloudStatusLabel.stringValue = [NSString stringWithFormat:
            @"HEAD DEPTH HELD: %.1f s old · fixed at capture pose · display history",
            MAX(0, now-self.lastHeadCloudUptime)];
    } else {
        self.cloudStatusLabel.stringValue = [NSString stringWithFormat:
            @"HEAD DEPTH: live captured view · %@ intrinsics · %@",
            self.headCloudHasCalibratedIntrinsics ? @"calibrated" : @"estimated",self.ghostGestureEditor.headDisplayPoseDescription];
    }
    if (self.liveBellyRGBCloudNode.hidden) belly = [belly stringByAppendingString:@" · CLOUD HIDDEN"];
    else if (self.bellyFloorHoldingAcceptedFrame) belly = [belly stringByAppendingFormat:@" · last aligned frame %.0f ms old", (now-self.lastBellyCloudUptime)*1000];
    self.floorStatusLabel.stringValue = [NSString stringWithFormat:@"FLAT FLOOR REFERENCE · %@\n%@", head, belly];
}

- (void)armTrialViewPrepared:(NSNotification *)notification
{
    // Update live accepted head geometry without taking a control-thread snapshot.
    if (!NSThread.isMainThread || !self.serialBox.isNeckCommandStateKnown ||
        NSProcessInfo.processInfo.systemUptime < self.serialBox.neckCommandReadyAtUptime) return;
    [self refreshHeadModelEstimate];
    [self.ghostGestureEditor refreshPreparedHeadPreview];
}

- (void)receivedDepthCloudFrame:(NSNotification *)notification
{
    ROBDepthCloudFrame *frame = [notification.object isKindOfClass:ROBDepthCloudFrame.class] ? notification.object : nil;
    if (frame == nil || ![self.cloudDisplayMailbox offerFrame:frame]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (ROBDepthCloudFrame *latest in [self.cloudDisplayMailbox takeLatestFrames]) {
            [self displayDepthCloudFrame:latest];
        }
    });
}

// The mailbox hands off only the latest role frame. All existing freshness,
// pending-job, pose and projection admission remains on the main thread.
- (void)displayDepthCloudFrame:(ROBDepthCloudFrame *)frame
{
    if (frame == nil || self.robo_scnView.scene == nil) return;
    BOOL belly = frame.isBelly;
    if (belly ? self.bellyCloudUpdatePending : self.cloudUpdatePending) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    // Keep display live with one pending background job per camera. Reduce
    // publication during all trials, including neck scans; capture/watchdogs are separate.
    BOOL trialBusy = ROBLeftArmTrial.shared.isRunning || ROBArmRoutineCoordinator.shared.isRunning;
    if (now - (belly ? self.lastBellyCloudSubmission : self.lastHeadCloudSubmission) < (trialBusy ? 0.5 : 0.125)) return;
    if (belly) self.lastBellyCloudSubmission = now; else self.lastHeadCloudSubmission = now;
    [self refreshHeadModelEstimate];
    NSArray<NSNumber *> *affine = [self.ghostGestureEditor depthCloudCameraTransform:belly];
    NSString *projectionIdentity = self.ghostGestureEditor.depthProjectionIdentity;
    BOOL explicitCameraPose = [self.ghostGestureEditor depthCloudUsesExplicitCameraPose:belly];
    if (!belly && self.headFloorCloudContext) {
        double f = (double)frame.width / (2.0 * tan(69.0 * M_PI / 360.0));
        NSArray *k = @[@(frame.hasCalibratedIntrinsics ? frame.cameraFX : f),
            @(frame.hasCalibratedIntrinsics ? frame.cameraFY : f),
            @(frame.hasCalibratedIntrinsics ? frame.cameraCX : (frame.width-1)/2.0),
            @(frame.hasCalibratedIntrinsics ? frame.cameraCY : (frame.height-1)/2.0)];
        BOOL changed = self.headFloorCloudContext.count<5 ||
            ![self.headFloorCloudContext[2] isEqual:k] || ![self.headFloorCloudContext[4] isEqual:projectionIdentity];
        if (!changed && affine.count==12) {
            double candidate[12];for(int i=0;i<12;i++) candidate[i]=affine[i].doubleValue;
            changed = ![self.headFloorCloudContext[3] isEqual:[NSData dataWithBytes:candidate length:sizeof(candidate)]];
        }
        if (changed) {
            self.liveRGBCloudNode.geometry=nil;self.liveRGBCloudNode.hidden=YES;
            self.headFloorAlignmentEstablished=NO;self.headFloorHoldingAcceptedFrame=NO;self.headFloorCloudContext=nil;
        }
    }
    ROBSerialBox *serial = self.serialBox;
    BOOL settled = serial.isNeckCommandStateKnown && frame.capturedUptime >= serial.neckCommandReadyAtUptime;
    if (affine.count != 12 || now - frame.capturedUptime > 0.7 || (!belly && !settled)) {
        if (belly) { self.liveBellyRGBCloudNode.hidden = YES; self.liveBellyRGBCloudNode.geometry = nil; }
        else [self retainHeadCloudForDisplayAtUptime:now];
        return;
    }
    double rows[12];
    for (int i=0;i<12;i++) rows[i] = affine[i].doubleValue;
    ROBNeckSafetyConfig config = serial ? [serial neckSafetyConfiguration] : ROBNeckSafetyDefaultConfig();
    double pan = 0;
    if (!belly && !ROBNeckSafetyPanTargetToDegrees(&config, (int32_t)serial.commandedNeckPanTarget, &pan)) return;
    ROBDepthCloudTransform camera = ROBDepthCloudMakeTransform(rows);
    if (!camera.valid) return;
    NSArray<NSNumber *> *targets = @[@(serial.commandedLowerNeckTiltTarget), @(serial.commandedNeckPanTarget), @(serial.commandedUpperNeckTiltTarget)];
    if (belly) self.bellyCloudUpdatePending = YES; else self.cloudUpdatePending = YES;
    SCNMatrix4 robot = self.robotNode.presentationNode.worldTransform;
    dispatch_async(self.cloudQueue, ^{ [self processDepthFrame:frame robotTransform:robot cameraTransform:camera neckTargets:targets projectionIdentity:projectionIdentity explicitCameraPose:explicitCameraPose]; });
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
    typedef struct { float r, g, b, a; } ROBPackedColor4;
    NSMutableData *colorData = [NSMutableData dataWithLength:points.count * sizeof(ROBPackedColor4)];
    ROBPackedColor4 *packedColors = colorData.mutableBytes;
    for (NSUInteger index = 0; index < points.count; index++) {
        SCNVector3 point = points[index].SCNVector3Value;
        vertices[index] = (ROBPackedPoint3){(float)point.x, (float)point.y, (float)point.z};
        indices[index] = (uint32_t)index;
        uint32_t rgba = index < colors.count ? colors[index].unsignedIntValue : 0xFFFFFFFF;
        packedColors[index] = (ROBPackedColor4){
            (float)((rgba >> 24) & 0xFF) / 255.0f,
            (float)((rgba >> 16) & 0xFF) / 255.0f,
            (float)((rgba >> 8) & 0xFF) / 255.0f,
            (float)(rgba & 0xFF) / 255.0f
        };
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
                                                               floatComponents:YES
                                                           componentsPerVector:4
                                                             bytesPerComponent:sizeof(float)
                                                                    dataOffset:0
                                                                    dataStride:sizeof(ROBPackedColor4)];
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

- (void)refreshFloorCloudVisibilityAtUptime:(NSTimeInterval)now
{
    SCNMatrix4 robot = self.robotNode.presentationNode.worldTransform;
    ROBSerialBox *serial = self.serialBox;
    NSArray *neck = @[@(serial.commandedLowerNeckTiltTarget), @(serial.commandedNeckPanTarget),
        @(serial.commandedUpperNeckTiltTarget), @(serial.neckCommandReadyAtUptime)];
    BOOL headBaseChanged = self.headFloorCloudContext &&
        !SCNMatrix4EqualToMatrix4([self.headFloorCloudContext[0] SCNMatrix4Value], robot);
    BOOL headNeckChanged = self.headFloorCloudContext && ![self.headFloorCloudContext[1] isEqual:neck];
    BOOL headProjectionChanged = self.headFloorCloudContext &&
        (self.headFloorCloudContext.count<5 || ![self.headFloorCloudContext[4] isEqual:self.ghostGestureEditor.depthProjectionIdentity]);
    BOOL bellyPoseChanged = self.bellyFloorCloudContext &&
        !SCNMatrix4EqualToMatrix4([self.bellyFloorCloudContext[0] SCNMatrix4Value], robot);
    if (headBaseChanged || headProjectionChanged || self.liveRGBCloudNode.geometry == nil) {
        self.liveRGBCloudNode.hidden = YES;
        self.liveRGBCloudNode.geometry = nil;
        self.headFloorHoldingAcceptedFrame = NO;
        if (headProjectionChanged) {self.headFloorAlignmentEstablished=NO;self.headFloorCloudContext=nil;}
    } else if (headNeckChanged || !serial.isNeckCommandStateKnown || serial.neckCommandReadyAtUptime > now ||
               now-self.lastHeadCloudUptime > 0.7) {
        self.headFloorHoldingAcceptedFrame = self.liveRGBCloudNode.geometry != nil;
    }
    if (bellyPoseChanged || now > self.bellyCloudDisplayUntil) {
        self.liveBellyRGBCloudNode.hidden = YES;
        self.liveBellyRGBCloudNode.geometry = nil;
        self.bellyCloudDisplayUntil = 0;
        self.bellyFloorHoldingAcceptedFrame = NO;
    }
}

- (void)retainHeadCloudForDisplayAtUptime:(NSTimeInterval)now
{
    // These vertices are already placed in the scene's world frame. Retain
    // the captured geometry, never reproject it using a newer neck command.
    // Display history has no age timeout. Failed input cannot renew its capture
    // timestamp or context; changed base placement still clears it immediately.
    [self refreshFloorCloudVisibilityAtUptime:now];
    self.headFloorHoldingAcceptedFrame = self.liveRGBCloudNode.geometry != nil;
    [self refreshFloorStatus];
}

- (void)processDepthFrame:(ROBDepthCloudFrame *)frame robotTransform:(SCNMatrix4)robotTransform
          cameraTransform:(ROBDepthCloudTransform)camera neckTargets:(NSArray<NSNumber *> *)targets projectionIdentity:(NSString *)projectionIdentity explicitCameraPose:(BOOL)explicitCameraPose
{
    if (frame.width <= 0 || frame.height <= 0 || frame.width > 8192 || frame.height > 8192 ||
        frame.millimetersLittleEndian.length < (NSUInteger)frame.width * (NSUInteger)frame.height * 2) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (frame.isBelly) { self.bellyCloudUpdatePending = NO; self.liveBellyRGBCloudNode.hidden = YES; self.liveBellyRGBCloudNode.geometry = nil; }
            else { self.cloudUpdatePending = NO; [self retainHeadCloudForDisplayAtUptime:NSProcessInfo.processInfo.systemUptime]; }
        });
        return;
    }
    BOOL isBelly = NO;
    if ([frame respondsToSelector:@selector(isBelly)]) {
        isBelly = frame.isBelly;
    }
    
    const uint8_t *bytes = frame.millimetersLittleEndian.bytes;
    NSInteger width = frame.width, height = frame.height;
    float focal = (float)width / (2.0f * tanf(69.0f * (float)M_PI / 360.0f));
    double fx = frame.hasCalibratedIntrinsics ? frame.cameraFX : focal;
    double fy = frame.hasCalibratedIntrinsics ? frame.cameraFY : focal;
    double cx = frame.hasCalibratedIntrinsics ? frame.cameraCX : (double)(width - 1) / 2;
    double cy = frame.hasCalibratedIntrinsics ? frame.cameraCY : (double)(height - 1) / 2;
    // Fit in physical metres, before the diagnostic base's world translation
    // and yaw. The captured model's 1.2 presentation scale is display-only.
    double presentationScale = ROBScanVisualModel.presentationScale;
    NSInteger step = MAX(4, (NSInteger)ceil(sqrt((double)width * height / ROBMaximumDisplayedCloudPoints)));
    while (((width + step - 1) / step) * ((height + step - 1) / step) > ROBMaximumDisplayedCloudPoints) step++;
    NSUInteger capacity = ((width + step - 1) / step) * ((height + step - 1) / step);
    NSMutableData *metricPoints = [NSMutableData dataWithCapacity:capacity * sizeof(ROBDepthFloorPoint)];
    NSMutableData *floorCandidates = [NSMutableData dataWithCapacity:ROBMaximumFloorCandidatePoints * sizeof(ROBDepthFloorPoint)];
    NSUInteger candidatesSeen = 0, imageCandidates = 0, heightCandidates = 0;
    uint32_t floorSampleState = 0x9E3779B9;
    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:capacity];
    NSMutableArray<NSNumber *> *colors = [NSMutableArray arrayWithCapacity:capacity];
    CVPixelBufferRef rgb = frame.rgbPixelBuffer;
    if (rgb != NULL) CVPixelBufferLockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly);
    uint8_t *rgbBase = rgb != NULL ? CVPixelBufferGetBaseAddress(rgb) : NULL;
    size_t rgbRowBytes = rgb != NULL ? CVPixelBufferGetBytesPerRow(rgb) : 0;
    size_t rgbWidth = rgb != NULL ? CVPixelBufferGetWidth(rgb) : 0;
    size_t rgbHeight = rgb != NULL ? CVPixelBufferGetHeight(rgb) : 0;

    for (NSInteger y = 0; y < height; y += step) {
        for (NSInteger x = 0; x < width; x += step) {
            NSInteger offset = (y * width + x) * 2;
            uint16_t mm = bytes[offset] | ((uint16_t)bytes[offset + 1] << 8);
            if (mm < 150 || mm > 10000) continue;
            double z = (double)mm / 1000.0;
            ROBDepthPoint projected = ROBDepthCloudProject(camera, (x - cx) * z / fx, (y - cy) * z / fy, z);
            ROBDepthFloorPoint metric = {projected.x / presentationScale, projected.y / presentationScale, projected.z / presentationScale};
            if (!isfinite(metric.x) || !isfinite(metric.y) || !isfinite(metric.z)) continue;
            [metricPoints appendBytes:&metric length:sizeof(metric)];
            if (y >= height * 0.55 && x >= width * 0.08 && x <= width * 0.92 && z >= 0.35 && z <= 4.0) {
                imageCandidates++;
                if (ROBFloorCandidateHeightIsPlausible(metric)) heightCandidates++;
            }
            if (ROBIsFloorCandidate(metric, z, x, y, width, height)) {
                candidatesSeen++;
                if (candidatesSeen <= ROBMaximumFloorCandidatePoints) {
                    [floorCandidates appendBytes:&metric length:sizeof(metric)];
                } else {
                    // Deterministic reservoir sampling spans the full image;
                    // taking only the first points would bias the fitted plane.
                    floorSampleState = floorSampleState * 1664525u + 1013904223u;
                    NSUInteger slot = floorSampleState % candidatesSeen;
                    if (slot < ROBMaximumFloorCandidatePoints)
                        ((ROBDepthFloorPoint *)floorCandidates.mutableBytes)[slot] = metric;
                }
            }
            uint32_t rgba = 0x80D8FFFF;
            if (rgbBase != NULL && x < rgbWidth && y < rgbHeight) {
                uint8_t *pixel = rgbBase + y * rgbRowBytes + x * 4;
                rgba = ((uint32_t)pixel[2] << 24) | ((uint32_t)pixel[1] << 16) |
                       ((uint32_t)pixel[0] << 8) | 0xFF;
            }
            [colors addObject:@(rgba)];
        }
    }
    if (rgb != NULL) CVPixelBufferUnlockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly);
    // This is a fresh per-frame display correction, never a persisted camera,
    // URDF or collision calibration. No old correction survives a changed view.
    ROBDepthFloorOptions floorOptions = ROBDepthFloorDefaultOptions();
    // The observed wooden-floor residual is 9.0–9.1 mm. Give the display a
    // 10 mm noise budget; the plane's geometry/support bounds stay unchanged.
    floorOptions.maximumRMSMeters = 0.010;
    ROBDepthFloorModel floor = ROBDepthFloorFit(floorCandidates.bytes,
        floorCandidates.length / sizeof(ROBDepthFloorPoint), floorOptions);
    const ROBDepthFloorPoint *metric = metricPoints.bytes;
    for (NSUInteger index = 0; index < metricPoints.length / sizeof(ROBDepthFloorPoint); index++) {
        // An explicit camera pose already defines the display frame for its mesh
        // and raw rays. Report floor residuals without applying another pose.
        // Legacy previews still align the whole cloud rigidly, preserving shape.
        ROBDepthFloorPoint aligned = explicitCameraPose ? metric[index] : ROBDepthFloorRectify(floor, metric[index], false);
        SCNVector3 local = SCNVector3Make(aligned.x * presentationScale, aligned.y * presentationScale, aligned.z * presentationScale);
        SCNVector3 world = SCNVector3Make(
            robotTransform.m11 * local.x + robotTransform.m21 * local.y + robotTransform.m31 * local.z + robotTransform.m41,
            robotTransform.m12 * local.x + robotTransform.m22 * local.y + robotTransform.m32 * local.z + robotTransform.m42,
            robotTransform.m13 * local.x + robotTransform.m23 * local.y + robotTransform.m33 * local.z + robotTransform.m43);
        [points addObject:[NSValue valueWithSCNVector3:world]];
    }
    NSString *floorSummary = floor.valid ? [NSString stringWithFormat:explicitCameraPose ? @"raw depth · %.0f%% floor support · %.1f mm RMS · %.1f° residual (not corrected)" : @"aligned · %.0f%% support · %.1f mm RMS · %.1f° correction",
        floor.inlierFraction * 100, floor.rmsMeters * 1000, floor.tiltRadians * 180 / M_PI]
        : [NSString stringWithFormat:@"fit rejected · %s · candidates %lu/%lu/%lu (image/height/range)",
            ROBDepthFloorRejectionName(floor.rejection), (unsigned long)imageCandidates,
            (unsigned long)heightCandidates, (unsigned long)candidatesSeen];
    if (!floor.valid && floor.inlierCount > 0) {
        floorSummary = [floorSummary stringByAppendingFormat:@" · %zu inliers · span %.2f×%.2f m · width %.2f m · %u cells · %.1f mm RMS",
            floor.inlierCount, floor.spanXMeters, floor.spanZMeters, floor.minorRMSMeters,
            floor.coveredCells, floor.rmsMeters * 1000];
    }
    SCNGeometry *geometry = [self pointGeometry:points colors:colors pointSize:2];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *displaySummary = floorSummary;
        double now = NSProcessInfo.processInfo.systemUptime;
        [self refreshFloorCloudVisibilityAtUptime:now];
        SCNNode *node = isBelly ? self.liveBellyRGBCloudNode : self.liveRGBCloudNode;
        if (isBelly) self.bellyCloudUpdatePending = NO; else self.cloudUpdatePending = NO;
        if (![projectionIdentity isEqual:self.ghostGestureEditor.depthProjectionIdentity]) return;
        ROBSerialBox *serial = self.serialBox;
        BOOL sameNeck = serial.isNeckCommandStateKnown &&
            serial.commandedLowerNeckTiltTarget == targets[0].integerValue &&
            serial.commandedNeckPanTarget == targets[1].integerValue &&
            serial.commandedUpperNeckTiltTarget == targets[2].integerValue &&
            frame.capturedUptime >= serial.neckCommandReadyAtUptime;
        if (!SCNMatrix4EqualToMatrix4(robotTransform, self.robotNode.presentationNode.worldTransform)) {
            node.hidden = YES;
            node.geometry = nil;
            return;
        }
        if ((!isBelly && !sameNeck) || now-frame.capturedUptime > 0.7) {
            if (isBelly) { node.hidden = YES; node.geometry = nil; }
            else [self retainHeadCloudForDisplayAtUptime:now];
            return;
        }
        if (!isBelly && geometry == nil) {
            self.headFloorSummary = [@"HEAD: " stringByAppendingString:displaySummary];
            [self retainHeadCloudForDisplayAtUptime:now];
            return;
        }
        NSArray *context = @[[NSValue valueWithSCNMatrix4:robotTransform],
            isBelly ? @[] : [targets arrayByAddingObject:@(serial.neckCommandReadyAtUptime)],
            @[@(fx), @(fy), @(cx), @(cy)], [NSData dataWithBytes:camera.m length:sizeof(camera.m)],projectionIdentity];
        NSArray *previous = isBelly ? self.bellyFloorCloudContext : self.headFloorCloudContext;
        BOOL changedProjection = !isBelly && previous &&
            (previous.count != context.count || ![previous[2] isEqual:context[2]] || ![previous[3] isEqual:context[3]] ||
             ![previous[4] isEqual:context[4]]);
        if (changedProjection) {
            node.geometry = nil; node.hidden = YES;
            self.headFloorAlignmentEstablished = NO; self.headFloorHoldingAcceptedFrame = NO;
        }
        if (isBelly && ![previous isEqual:context]) { node.geometry = nil; node.hidden = YES; }
        BOOL alignedBefore = isBelly ? self.bellyFloorAlignmentEstablished : self.headFloorAlignmentEstablished;
        double acceptedAt = isBelly ? self.lastBellyCloudUptime : self.lastHeadCloudUptime;
        BOOL hold = !explicitCameraPose && !floor.valid && alignedBefore && node.geometry != nil &&
            (!isBelly || (floor.rejection == ROBDepthFloorExcessNoise && now-acceptedAt <= ROBFloorNoiseHoldInterval));
        double displayUntil = 0;
        if (explicitCameraPose || floor.valid || !alignedBefore) {
            node.geometry = geometry;
            node.hidden = NO;
            if (isBelly) displayUntil = frame.capturedUptime + 0.7;
            if (!floor.valid) displaySummary = [@"raw cloud · " stringByAppendingString:floorSummary];
            if (isBelly) self.lastBellyCloudUptime = frame.capturedUptime;
            else {
                self.lastHeadCloudUptime = frame.capturedUptime;
                self.headCloudHasCalibratedIntrinsics = frame.hasCalibratedIntrinsics;
            }
        } else {
            // Once alignment is established, never alternate back to raw.
            // Keep HEAD display history until a usable replacement arrives.
            // BELLY keeps only its bounded noise hold. No old plane is applied
            // to new points and no rejected frame advances the capture time.
            node.hidden = !hold;
            if (hold) {
                if (isBelly) displayUntil = acceptedAt + ROBFloorNoiseHoldInterval;
            } else node.geometry = nil;
        }
        if (isBelly) {
            self.bellyFloorCloudContext = context;
            self.bellyFloorAlignmentEstablished = !explicitCameraPose && (alignedBefore || floor.valid);
            self.bellyFloorHoldingAcceptedFrame = hold;
            self.bellyCloudDisplayUntil = displayUntil;
            self.bellyFloorSummary = [@"BELLY: " stringByAppendingString:displaySummary];
        } else {
            if (explicitCameraPose || floor.valid || !alignedBefore) self.headFloorCloudContext = context;
            self.headFloorAlignmentEstablished = !explicitCameraPose && (alignedBefore || floor.valid);
            self.headFloorHoldingAcceptedFrame = hold;
            self.headFloorSummary = [@"HEAD: " stringByAppendingString:displaySummary];
        }
        [self refreshFloorStatus];
    });
}

@end
