//
//  ROBSerialBox.m
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//
/*
 
 ORBITUSROBOTICS RHAPIv1.0
 
                                            brake  M1   brake  M2   brake  M3    LACT
INPUT: FULL BRAKE Command String         = ~+0001,+0000,+0001,+0000,+0001,+0000,+0000
Release Brakes Command String            = ~+0000,+0000,+0000,+0000,+0000,+0000,+0000
Full Motor Forward String                = ~+0000,+0100,+0000,+0100,+0000,+0000,+0000
Full Motor Backward String               = ~+0000,-0100,+0000,-0100,+0000,+0000,+0000

Turn Right                               = ~+0000,+0100,+0000,-0100,+0000,+0000,+0000
Turn Left                                = ~+0000,-0100,+0000,+0100,+0000,+0000,+0000

Left Motor Command String                = ~+0000,+0100,+0000,+0000,+0000,+0000,+0000
Right Motor Command String               = ~+0000,+0000,+0000,+0100,+0000,+0000,+0000
Flipper forwards MotorCommand String     = ~+0000,+0000,+0000,+0000,+0000,+0100,+0000
Flipper backwards MotorCommand String    = ~+0000,+0000,+0000,+0000,+0000,-0100,+0000
LACT forwards MotorCommand String        = ~+0000,+0000,+0000,+0000,+0000,+0000,+3200
LACT backwards MotorCommand String       = ~+0000,+0000,+0000,+0000,+0000,+0000,-3200


OUTPUT: ir sensor array in cm : (fl, fr, l, r, bl, br) from front left to back right
 
 IMU Pulse
 ax = 2.01 ay = -83.44 az = -1085.94 mg
 gx = -0.13 gy = 0.05 gz = -0.03 deg/s
 mx = -1600 my = -1261 mz = -420 mG
 q0 = 0.05 qx = 0.10 qy = -0.39 qz = 0.91
 Yaw, Pitch, Roll: 175.03, -12.40, -46.15
 Temperature is 28.9 degrees C
 rate = 0.21 Hz

*/

#import "ROBSerialBox.h"
#import "ROBMainViewController.h"
#import "ROBSpeechBox.h"
#import "ROBBaseControllerModel.h"
#import "ROBPythonRuntime.h"
#import "ROBSystemDependencyManager.h"
#import "ROBTaskLaunchGuard.h"
#import "Cerebro-Swift.h"
#include <sys/select.h>
#include <errno.h>
#include <float.h>


#define kRHAPI_BAUDRATE 250000
// This exact line already exists in the long-running Base firmware. Head and Torso use
// their own role names, so Cerebro can identify Base without requiring a show-day flash.
static NSString * const kROBBaseLegacyStartupIdentity = @"BEGIN BASE STARTUP SEQUENCE";
static NSTimeInterval const kROBBaseProbeTimeoutSeconds = 15.0;
static NSTimeInterval const kMaestroReconnectDelaySeconds = 2.0;
static NSInteger const kPololuUSBVendorID = 0x1ffb;
static NSString * const kROBNeckSafetyConfigurationDefaultsKey = @"ROBNeckSafetyConfigurationV3";
static NSString * const kROBNeckSafetyV2ConfigurationDefaultsKey = @"ROBNeckSafetyConfigurationV2";
static NSString * const kROBNeckSafetyLegacyConfigurationDefaultsKey = @"ROBNeckSafetyConfigurationV1";
static NSTimeInterval const kROBNeckManualOverrideSeconds = 2.0;
static NSTimeInterval const kROBNeckVisionAuthoritySeconds = 0.35;
static NSTimeInterval const kROBNeckPanRecenterSeconds = 1.0;
static NSTimeInterval const kROBNeckClearanceSettleSeconds = 0.75;
static NSTimeInterval const kROBNeckSupervisedRecoverySeconds = 5.0;
static NSUInteger const kROBBaseConsoleMaximumCharacters = 256 * 1024;

static double ROBTargetOverflow(double target, double minimum, double maximum)
{
    if (target < minimum) return minimum - target;
    if (target > maximum) return target - maximum;
    return 0.0;
}

static BOOL ROBNeckPanBoundsAreValid(ROBNeckSafetyPanBounds bounds)
{
    return isfinite(bounds.minimumDegrees)
        && isfinite(bounds.maximumDegrees)
        && bounds.minimumDegrees <= bounds.maximumDegrees;
}

static BOOL ROBNeckPanBoundsContain(
    ROBNeckSafetyPanBounds outer,
    ROBNeckSafetyPanBounds inner
)
{
    return ROBNeckPanBoundsAreValid(outer)
        && ROBNeckPanBoundsAreValid(inner)
        && inner.minimumDegrees >= outer.minimumDegrees
        && inner.maximumDegrees <= outer.maximumDegrees;
}

static BOOL ROBNeckPanBoundsIntersect(
    ROBNeckSafetyPanBounds first,
    ROBNeckSafetyPanBounds second,
    ROBNeckSafetyPanBounds *intersectionOut
)
{
    if (!ROBNeckPanBoundsAreValid(first)
        || !ROBNeckPanBoundsAreValid(second)
        || intersectionOut == NULL) {
        return NO;
    }
    ROBNeckSafetyPanBounds intersection = {
        .minimumDegrees = fmax(first.minimumDegrees, second.minimumDegrees),
        .maximumDegrees = fmin(first.maximumDegrees, second.maximumDegrees),
    };
    if (!ROBNeckPanBoundsAreValid(intersection)) return NO;
    *intersectionOut = intersection;
    return YES;
}

static BOOL ROBNeckConservativeUnknownPanBounds(
    const ROBNeckSafetyConfig *configuration,
    ROBNeckSafetyPanBounds *boundsOut
)
{
    if (configuration == NULL || boundsOut == NULL) return NO;
    ROBNeckSafetyPanBounds unknownBounds = {0};
    ROBNeckSafetyPanBounds backwardBounds = {0};
    ROBNeckSafetyPanBounds forwardBounds = {0};
    if (!ROBNeckSafetyAllowedPanBounds(
            configuration,
            ROBNeckSafetyTargetOff,
            &unknownBounds
        )
        || !ROBNeckSafetyAllowedPanBounds(
            configuration,
            configuration->lowerMinimumTarget,
            &backwardBounds
        )
        || !ROBNeckSafetyAllowedPanBounds(
            configuration,
            configuration->lowerForwardRestrictedTarget,
            &forwardBounds
        )) {
        return NO;
    }
    ROBNeckSafetyPanBounds knownExtremes = {0};
    if (!ROBNeckPanBoundsIntersect(
            backwardBounds,
            forwardBounds,
            &knownExtremes
        )) {
        return NO;
    }
    return ROBNeckPanBoundsIntersect(unknownBounds, knownExtremes, boundsOut);
}

static BOOL ROBNeckClampPanResultToBounds(
    const ROBNeckSafetyConfig *configuration,
    ROBNeckSafetyPanBounds bounds,
    ROBNeckSafetyResult *result
)
{
    if (configuration == NULL
        || result == NULL
        || !ROBNeckPanBoundsAreValid(bounds)) {
        return NO;
    }
    result->allowedPanMinimumDegrees = bounds.minimumDegrees;
    result->allowedPanMaximumDegrees = bounds.maximumDegrees;
    if (result->panTarget == ROBNeckSafetyTargetOff) return YES;

    double degrees = NAN;
    if (!ROBNeckSafetyPanTargetToDegrees(configuration, result->panTarget, &degrees)) {
        return NO;
    }
    double boundedDegrees = fmax(
        bounds.minimumDegrees,
        fmin(bounds.maximumDegrees, degrees)
    );
    int32_t boundedTarget = ROBNeckSafetyTargetOff;
    if (!ROBNeckSafetyPanDegreesToTarget(
            configuration,
            boundedDegrees,
            &boundedTarget
        )) {
        return NO;
    }
    if (boundedTarget != result->panTarget) result->panClamped = true;
    result->panTarget = boundedTarget;
    return YES;
}

NSNotificationName const ROBSerialHardwareDidChangeNotification =
    @"ROBSerialHardwareDidChangeNotification";

#define kRHAPI_SERIAL_PORT_BASE     @"/dev/cu.usbmodem21201"


#define kRHAPI_MAESTRO_BAUDRATE 9600

#define kMaxTurnSpeed 100
#define kMaxMovementSpeed 255

// ROBController publishes at 5 Hz. Three missed snapshots expire authority;
// after one neutral/braked write Cerebro stops writing so the Arduino hardware
// deadman can de-energize independently.
static NSTimeInterval const kControllerSnapshotFreshnessSeconds = 0.6;
// The Tic rotating-plate UI permits one 36,800-unit turn in either direction.
// Vision head-following intentionally uses at most the 18,400-unit half-turn.
static int const kROBTicWaistFullTurnPositionUnits = 36800;
static int const kROBTicWaistHeadFollowMaximumUnits = 18400;

#define kBaseSerialContext 2
#define kMaestroSerialContext 3

@interface ROBSerialBox()
{
    bool exitSafeStart_waistRotation;
    bool energize_waistRotation;
}
@property (readwrite, assign) float actualSpeedL;
@property (readwrite, assign) float actualSpeedR;
@property (readwrite, assign) BOOL masterControllerInputWasFresh;
@property (readwrite, assign) NSTimeInterval lastControllerRenderUptime;
@property (readwrite, assign) int lastVisionNeckPanTarget;
@property (readwrite, assign) int lastVisionNeckTiltTarget;
@property (readwrite, assign) NSInteger commandedNeckPanTarget;
@property (readwrite, assign) NSInteger commandedLowerNeckTiltTarget;
@property (readwrite, assign) NSInteger commandedUpperNeckTiltTarget;
@property (readwrite, assign, getter=isNeckPanCommandKnown) BOOL neckPanCommandKnown;
@property (readwrite, assign, getter=isLowerNeckTiltCommandKnown) BOOL lowerNeckTiltCommandKnown;
@property (readwrite, assign, getter=isUpperNeckTiltCommandKnown) BOOL upperNeckTiltCommandKnown;
@property (readwrite, assign) double commandedNeckPanDegrees;
@property (readwrite, assign) double currentNeckPanMinimumDegrees;
@property (readwrite, assign) double currentNeckPanMaximumDegrees;
@property (readwrite, assign, getter=isNeckPanCommandLimited) BOOL neckPanCommandLimited;
@property (readwrite, assign, getter=isUpperNeckCommandCompensated) BOOL upperNeckCommandCompensated;
@property (readwrite, assign, getter=isNeckSafetyCalibrationConfirmed) BOOL neckSafetyCalibrationConfirmed;
@property (readwrite, copy) NSString *neckCommandSource;
@property (readwrite, copy) NSString *neckCommandSafetyStatus;
@property (readwrite, assign) ROBNeckSafetyConfig activeNeckSafetyConfiguration;
@property (readwrite, assign) BOOL neckLevelingReferenceIsValid;
@property (readwrite, assign) int neckLevelingReferenceLowerTarget;
@property (readwrite, assign) int panEnvelopeLowerTarget;
@property (readwrite, assign) BOOL panEnvelopeLowerTargetIsKnown;
@property (readwrite, assign) int pendingPanEnvelopeLowerTarget;
@property (readwrite, assign) NSTimeInterval pendingPanEnvelopeReadyAt;
@property (readwrite, assign) ROBNeckSafetySettleGate panRecenterSettleGate;
@property (readwrite, assign) NSTimeInterval commandedNeckPanTargetReadyAt;
@property (readwrite, assign) NSTimeInterval manualNeckOverrideUntil;
@property (readwrite, assign) NSTimeInterval visionNeckAuthorityUntil;
@property (readwrite, assign) NSTimeInterval gestureNeckAuthorityUntil;
@property (readwrite, assign) BOOL torsoNeckAuthorityRequiresOperatorAction;
@property (readwrite, assign) BOOL lastDesiredUpperNeckTargetIsKnown;
@property (readwrite, assign) int lastDesiredUpperNeckTarget;
@property (readwrite, assign) NSTimeInterval supervisedLowerRecoveryUntil;
@property (readwrite, assign) int supervisedLowerRecoveryPanTarget;
@property (readwrite, assign) int supervisedLowerRecoveryTarget;
@property (readwrite, assign) int supervisedLowerRecoveryUpperTarget;
@property (readwrite, assign) BOOL visionGripperStateIsKnown;
@property (readwrite, assign) BOOL lastVisionLeftGripperClosed;
@property (readwrite, assign) BOOL lastVisionRightGripperClosed;
@property (readwrite, assign) BOOL visionTorsoControlWasActive;
@property (readwrite, assign) int visionTorsoBaselinePosition;
@property (readwrite, assign) int lastVisionTorsoTarget;

@property (readwrite, retain) NSTimer *verbalInputTimer;
@property (readwrite, retain) NSTimer *controllerTimer;

@property (readwrite, retain) NSString *tempTextInput;
@property (readwrite, retain) NSMutableDictionary *controlModelDataDictionary;
@property (readwrite, retain) NSMutableDictionary *treadControlModelDataDictionary;
@property (readwrite, retain) NSMutableData* receivedData_R11_Core;
@property (readwrite, retain) NSMutableData* receivedData_R11_log;
@property (readwrite, retain) NSMutableData* receivedData_L10_Core;
@property (readwrite, retain) NSMutableData* receivedData_L10_log;
@property (readwrite, retain) NSMutableData *baseSerialReceiveBuffer;
@property (readwrite, assign) BOOL baseDetectionInProgress;
@property (readwrite, assign) BOOL maestroConnectionValid;
@property (readwrite, assign) BOOL maestroReconnectScheduled;
@property (readwrite, assign) BOOL maestroReconnectInProgress;
@property (readwrite, assign) BOOL maestroMissingWasReported;
@property (readwrite, copy) NSString *maestroDevicePath;
@property (atomic, readwrite, copy) NSString *baseSerialStatusText;
@property (atomic, readwrite, copy) NSString *maestroSerialStatusText;
@property (readwrite, assign) BOOL core_R11_isOnline;
@property (readwrite, assign) BOOL core_L10_isOnline;
@property (readwrite, retain) NSTask *sshTask_R11_Core;
@property (readwrite, retain) NSTask *sshTask_L10_Core;
@property (readwrite, retain) NSTask *sshTask_R11_log;
@property (readwrite, retain) NSTask *sshTask_L10_log;

- (void)runPythonArguments:(NSArray<NSString *> *)arguments operation:(NSString *)operation;
- (void)runTiccmdArguments:(NSArray<NSString *> *)arguments;
- (void)performSSHpassOperation:(NSString *)operation block:(dispatch_block_t)block;
- (BOOL)launchSSHpassTask:(NSTask *)task operation:(NSString *)operation;
- (void)reportSSHpassError:(NSError *)error operation:(NSString *)operation;
- (void)startSSHIntoAmberMasterAndRunTail_R11;
- (void)startSSHIntoAmberMasterAndRunCore_R11;
- (void)startShutdown_R11_core;
- (void)startSSHIntoAmberMasterAndRunTail_L10;
- (void)startSSHIntoAmberMasterAndRunCore_L10;
- (void)startShutdown_L10_core;
- (void)presentSupervisedAmberGripperControls;

- (NSString *) openSerialPort: (NSString *)serialPortFile baud: (speed_t)baudRate serialFileDescriptor:(int *)serialFileDescriptor contextInt:(int)context;
- (NSArray<NSString *> *)usbSerialPortPaths;
- (NSString *)maestroCommandPortPath;
- (void)attemptMaestroReconnect;
- (void)scheduleMaestroReconnectAfterDelay:(NSTimeInterval)delay;
- (void)markMaestroDisconnectedForErrno:(int)errorNumber;
- (BOOL)writeMaestroBytes:(const void *)bytes length:(size_t)length;
- (BOOL)sendMaestroTarget:(unsigned short)target channel:(unsigned char)channel;
- (BOOL)sendMaestroLowerTarget:(unsigned short)lowerTarget
                   upperTarget:(unsigned short)upperTarget;
- (ROBNeckCommandDisposition)applySafeNeckPanTarget:(int)panTarget
              lowerTiltTarget:(int)lowerTiltTarget
            desiredUpperTarget:(int)desiredUpperTarget
                  includeLower:(BOOL)includeLower
 allowSupervisedLowerRecovery:(BOOL)allowSupervisedLowerRecovery
                        source:(NSString *)source;
- (void)refreshSettledNeckEnvelopeAtTime:(NSTimeInterval)now;
- (void)invalidateNeckCommandStateWithStatus:(NSString *)status;
- (ROBNeckSafetyConfig)loadNeckSafetyConfiguration;
- (void)persistNeckSafetyConfiguration:(ROBNeckSafetyConfig)configuration;
- (void)connectToDetectedBase;
- (BOOL)probeBaseFirmwareAtPath:(NSString *)path fileDescriptor:(int *)matchedFileDescriptor;
- (void)consumeBaseSerialBytes:(const void *)bytes length:(NSUInteger)length;
- (void)handleBaseSerialLine:(NSString *)line;
- (void)renderControllerPrioritized:(BOOL)urgent;

- (void)appendToIncomingText_base: (id) text;


- (void)incomingTextUpdateThread_base: (NSThread *) parentThread;

- (void) refreshSerialList_base: (NSString *) selectedText;
- (void) refreshSerialList_maestro: (NSString *) selectedText;


- (void) writeString: (NSString *)str serialFileDescriptor:(int)serialFileDescriptor;
- (void) writeByte: (uint8_t *)val serialFileDescriptor:(int)serialFileDescriptor;


- (IBAction) refreshAction: (id) cntrl;
- (void) sendText:(id)cntrl serialInputField:(NSTextField *)serialInputField serialFileDescriptor:(int)serialFileDescriptor;

- (void) resetButton: (NSButton *) btn;


- (IBAction)forward:(id)sender;
- (IBAction)backward:(id)sender;
- (IBAction)left:(id)sender;
- (IBAction)right:(id)sender;
- (IBAction)up:(id)sender;
- (IBAction)down:(id)sender;
- (IBAction)leanforward:(id)sender;
- (IBAction)leanback:(id)sender;



@end


typedef enum : NSUInteger {
    head = 0,
    torso,
    base,
    maestro
} SerialContext;



@implementation ROBSerialBox


- (instancetype)init
{
    self = [super init];
    if (self) {
        
    }
    return self;
}

- (ROBNeckSafetyConfig)loadNeckSafetyConfiguration
{
    ROBNeckSafetyConfig configuration = ROBNeckSafetyDefaultConfig();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *saved = [defaults
        dictionaryForKey:kROBNeckSafetyConfigurationDefaultsKey];
    NSInteger storedVersion = 3;
    if (saved == nil) {
        storedVersion = 2;
        saved = [defaults
            dictionaryForKey:kROBNeckSafetyV2ConfigurationDefaultsKey];
    }
    if (saved == nil) {
        storedVersion = 1;
        saved = [defaults
            dictionaryForKey:kROBNeckSafetyLegacyConfigurationDefaultsKey];
    }

    NSNumber *expectedVersion = @(storedVersion);
    NSArray<NSString *> *requiredCommonNumberKeys = @[
        @"panMinimumTarget", @"panCenterTarget", @"panMaximumTarget",
        @"panTargetsPerDegree", @"lowerMinimumTarget",
        @"lowerFullPanLowTarget", @"lowerFullPanHighTarget",
        @"lowerMaximumTarget", @"upperMinimumTarget", @"upperMaximumTarget",
        @"restrictedPanDegrees", @"upperCounterRotationGain"
    ];
    if (![saved[@"version"] isEqual:expectedVersion]
        || ![saved[@"calibrationConfirmed"] isKindOfClass:NSNumber.class]) {
        self.neckSafetyCalibrationConfirmed = NO;
        return configuration;
    }
    for (NSString *key in requiredCommonNumberKeys) {
        if (![saved[key] isKindOfClass:NSNumber.class]) {
            self.neckSafetyCalibrationConfirmed = NO;
            return configuration;
        }
    }
    if (storedVersion >= 2) {
        for (NSString *key in @[
            @"lowerForwardRestrictedTarget",
            @"forwardPanMinimumDegrees",
            @"forwardPanMaximumDegrees"
        ]) {
            if (![saved[key] isKindOfClass:NSNumber.class]) {
                self.neckSafetyCalibrationConfirmed = NO;
                return configuration;
            }
        }
    }
    if (storedVersion == 3
        && ![saved[@"cameraLevelingEnabled"] isKindOfClass:NSNumber.class]) {
        self.neckSafetyCalibrationConfirmed = NO;
        return configuration;
    }

    configuration.panMinimumTarget = [saved[@"panMinimumTarget"] intValue];
    configuration.panCenterTarget = [saved[@"panCenterTarget"] intValue];
    configuration.panMaximumTarget = [saved[@"panMaximumTarget"] intValue];
    configuration.panTargetsPerDegree = [saved[@"panTargetsPerDegree"] doubleValue];
    configuration.lowerMinimumTarget = [saved[@"lowerMinimumTarget"] intValue];
    configuration.lowerFullPanLowTarget = [saved[@"lowerFullPanLowTarget"] intValue];
    configuration.lowerFullPanHighTarget = [saved[@"lowerFullPanHighTarget"] intValue];
    configuration.lowerMaximumTarget = [saved[@"lowerMaximumTarget"] intValue];
    configuration.upperMinimumTarget = [saved[@"upperMinimumTarget"] intValue];
    configuration.upperMaximumTarget = [saved[@"upperMaximumTarget"] intValue];
    configuration.restrictedPanDegrees = [saved[@"restrictedPanDegrees"] doubleValue];
    if (storedVersion >= 2) {
        configuration.lowerForwardRestrictedTarget =
            [saved[@"lowerForwardRestrictedTarget"] intValue];
        configuration.forwardPanMinimumDegrees =
            [saved[@"forwardPanMinimumDegrees"] doubleValue];
        configuration.forwardPanMaximumDegrees =
            [saved[@"forwardPanMaximumDegrees"] doubleValue];
    } else {
        // V1 had no asymmetric forward envelope. Clip the shipped values to
        // its preserved restricted-pan magnitude.
        configuration.forwardPanMinimumDegrees =
            -fmin(15.0, configuration.restrictedPanDegrees);
        configuration.forwardPanMaximumDegrees =
            fmin(2.1, configuration.restrictedPanDegrees);
    }
    configuration.upperCounterRotationGain = [saved[@"upperCounterRotationGain"] doubleValue];
    if (storedVersion == 3) {
        configuration.cameraLevelingEnabled =
            [saved[@"cameraLevelingEnabled"] boolValue];
    } else {
        // V3 widens the verified full-pan band. Adopt it for migrated settings
        // only when it fits the preserved lower hard stops; otherwise retain
        // the legacy band and let normal validation decide its safety.
        const int32_t shippedFullPanLowTarget = 5300;
        const int32_t shippedFullPanHighTarget = 6822;
        BOOL shippedFullPanBandFits =
            shippedFullPanLowTarget > configuration.lowerMinimumTarget
            && shippedFullPanHighTarget > shippedFullPanLowTarget
            && shippedFullPanHighTarget < configuration.lowerMaximumTarget;
        if (shippedFullPanBandFits) {
            configuration.lowerFullPanLowTarget = shippedFullPanLowTarget;
            configuration.lowerFullPanHighTarget = shippedFullPanHighTarget;
        }

        // Any lower target above 6822 must use the tight forward envelope.
        // Adopt that boundary when it fits the preserved hard stops, or use
        // the forward hard stop as a final valid transition endpoint.
        const int32_t shippedForwardAnchor = 6823;
        configuration.lowerForwardRestrictedTarget =
            shippedForwardAnchor > configuration.lowerFullPanHighTarget
                && shippedForwardAnchor <= configuration.lowerMaximumTarget
            ? shippedForwardAnchor
            : configuration.lowerMaximumTarget;
        configuration.cameraLevelingEnabled = true;
    }
    if (!ROBNeckSafetyConfigIsValid(&configuration)) {
        self.neckSafetyCalibrationConfirmed = NO;
        return ROBNeckSafetyDefaultConfig();
    }
    // V1/V2 never confirmed the widened full-pan band or leveling toggle.
    // Preserve compatible calibration fields, but require V3 confirmation.
    self.neckSafetyCalibrationConfirmed = storedVersion == 3
        && [saved[@"calibrationConfirmed"] boolValue];
    return configuration;
}

- (void)persistNeckSafetyConfiguration:(ROBNeckSafetyConfig)configuration
{
    NSDictionary *saved = @{
        @"version": @3,
        @"calibrationConfirmed": @(self.neckSafetyCalibrationConfirmed),
        @"panMinimumTarget": @(configuration.panMinimumTarget),
        @"panCenterTarget": @(configuration.panCenterTarget),
        @"panMaximumTarget": @(configuration.panMaximumTarget),
        @"panTargetsPerDegree": @(configuration.panTargetsPerDegree),
        @"lowerMinimumTarget": @(configuration.lowerMinimumTarget),
        @"lowerFullPanLowTarget": @(configuration.lowerFullPanLowTarget),
        @"lowerFullPanHighTarget": @(configuration.lowerFullPanHighTarget),
        @"lowerForwardRestrictedTarget": @(configuration.lowerForwardRestrictedTarget),
        @"lowerMaximumTarget": @(configuration.lowerMaximumTarget),
        @"upperMinimumTarget": @(configuration.upperMinimumTarget),
        @"upperMaximumTarget": @(configuration.upperMaximumTarget),
        @"restrictedPanDegrees": @(configuration.restrictedPanDegrees),
        @"forwardPanMinimumDegrees": @(configuration.forwardPanMinimumDegrees),
        @"forwardPanMaximumDegrees": @(configuration.forwardPanMaximumDegrees),
        @"cameraLevelingEnabled": @(configuration.cameraLevelingEnabled),
        @"upperCounterRotationGain": @(configuration.upperCounterRotationGain)
    };
    [[NSUserDefaults standardUserDefaults] setObject:saved
                                              forKey:kROBNeckSafetyConfigurationDefaultsKey];
}

- (ROBNeckSafetyConfig)neckSafetyConfiguration
{
    if (!ROBNeckSafetyConfigIsValid(&_activeNeckSafetyConfiguration)) {
        self.activeNeckSafetyConfiguration = [self loadNeckSafetyConfiguration];
    }
    return self.activeNeckSafetyConfiguration;
}

- (BOOL)isNeckCameraLevelingEnabled
{
    @synchronized (self) {
        return [self neckSafetyConfiguration].cameraLevelingEnabled;
    }
}

- (BOOL)setNeckCameraLevelingEnabled:(BOOL)enabled
{
    @synchronized (self) {
        ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
        if (configuration.cameraLevelingEnabled == enabled) return YES;

        configuration.cameraLevelingEnabled = enabled;
        if (!ROBNeckSafetyConfigIsValid(&configuration)) return NO;

        // The toggle owns a short manual lease and prevents passive torso
        // sliders, Vision, or a gesture from immediately overwriting the
        // explicitly preserved neck pose.
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        self.manualNeckOverrideUntil = now + kROBNeckManualOverrideSeconds;
        self.visionNeckAuthorityUntil = 0;
        self.gestureNeckAuthorityUntil = 0;
        self.torsoNeckAuthorityRequiresOperatorAction = YES;

        self.activeNeckSafetyConfiguration = configuration;
        BOOL activePoseIsKnown = self.neckCommandStateKnown
            && self.commandedNeckPanTarget != ROBNeckSafetyTargetOff
            && self.commandedLowerNeckTiltTarget != ROBNeckSafetyTargetOff
            && self.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff;
        if (enabled && activePoseIsKnown) {
            self.neckLevelingReferenceLowerTarget =
                (int)self.commandedLowerNeckTiltTarget;
            self.neckLevelingReferenceIsValid = YES;
        } else {
            self.neckLevelingReferenceIsValid = NO;
        }
        if (self.upperNeckTiltCommandKnown
            && self.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff) {
            self.lastDesiredUpperNeckTarget =
                (int)self.commandedUpperNeckTiltTarget;
            self.lastDesiredUpperNeckTargetIsKnown = YES;
            self.lastVisionNeckTiltTarget =
                (int)self.commandedUpperNeckTiltTarget;
        } else {
            self.lastDesiredUpperNeckTargetIsKnown = NO;
        }
        if (self.neckPanCommandKnown
            && self.commandedNeckPanTarget != ROBNeckSafetyTargetOff) {
            self.lastVisionNeckPanTarget = (int)self.commandedNeckPanTarget;
        }
        self.upperNeckCommandCompensated = NO;
        [self persistNeckSafetyConfiguration:configuration];

        if (!activePoseIsKnown) {
            self.neckCommandSafetyStatus = enabled
                ? @"Camera leveling enabled; no active known pose was moved."
                : @"Camera leveling disabled; no active known pose was moved.";
            return YES;
        }

        // Reapply only the three known neck channels through the shared
        // gateway. The already-applied upper target becomes the new desired
        // camera pose, preventing an ON/OFF transition jump without touching
        // any arm output.
        ROBNeckCommandDisposition disposition = [self
            applySafeNeckPanTarget:(int)self.commandedNeckPanTarget
            lowerTiltTarget:(int)self.commandedLowerNeckTiltTarget
            desiredUpperTarget:(int)self.commandedUpperNeckTiltTarget
            includeLower:YES
            allowSupervisedLowerRecovery:NO
            source:@"Torso leveling toggle"];
        self.torsoNeckAuthorityRequiresOperatorAction = YES;
        return disposition != ROBNeckCommandDispositionRejected;
    }
}

- (BOOL)isNeckCommandStateKnown
{
    return self.neckPanCommandKnown
        && self.lowerNeckTiltCommandKnown
        && self.upperNeckTiltCommandKnown;
}

- (BOOL)applyNeckSafetyConfiguration:(ROBNeckSafetyConfig)configuration
{
    @synchronized (self) {
    // Live calibration changes can otherwise jump an already compensated
    // upper target. Require a deliberate all-off state, then re-establish all
    // command-space references under the new configuration.
    if (!ROBNeckSafetyConfigIsValid(&configuration)
        || !self.neckCommandStateKnown
        || self.commandedNeckPanTarget != ROBNeckSafetyTargetOff
        || self.commandedLowerNeckTiltTarget != ROBNeckSafetyTargetOff
        || self.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff) {
        return NO;
    }
    self.activeNeckSafetyConfiguration = configuration;
    self.neckSafetyCalibrationConfirmed = YES;
    [self persistNeckSafetyConfiguration:configuration];

    // Re-establish both command-space references conservatively. The next
    // accepted neck request starts without an upper-servo jump, while pan
    // remains in the tightest conservative window until the lower target has
    // settled.
    self.neckLevelingReferenceIsValid = NO;
    self.panEnvelopeLowerTargetIsKnown = NO;
    self.pendingPanEnvelopeLowerTarget = ROBNeckSafetyTargetOff;
    self.pendingPanEnvelopeReadyAt = 0;
    self.panRecenterSettleGate = (ROBNeckSafetySettleGate){0};
    self.commandedNeckPanTargetReadyAt = 0;
    self.supervisedLowerRecoveryUntil = 0;
    ROBNeckSafetyPanBounds conservativeBounds = {0};
    if (!ROBNeckConservativeUnknownPanBounds(
            &configuration,
            &conservativeBounds
        )) {
        return NO;
    }
    self.currentNeckPanMinimumDegrees = conservativeBounds.minimumDegrees;
    self.currentNeckPanMaximumDegrees = conservativeBounds.maximumDegrees;
    self.neckCommandSafetyStatus = [NSString stringWithFormat:
        @"Safety configuration saved; lower clearance is unverified, pan held %.1f°…%+.1f°.",
        conservativeBounds.minimumDegrees,
        conservativeBounds.maximumDegrees];
    return YES;
    }
}

- (void)invalidateNeckCommandStateWithStatus:(NSString *)status
{
    @synchronized (self) {
    self.commandedNeckPanTarget = ROBNeckSafetyTargetOff;
    self.commandedLowerNeckTiltTarget = ROBNeckSafetyTargetOff;
    self.commandedUpperNeckTiltTarget = ROBNeckSafetyTargetOff;
    self.neckPanCommandKnown = NO;
    self.lowerNeckTiltCommandKnown = NO;
    self.upperNeckTiltCommandKnown = NO;
    self.commandedNeckPanDegrees = NAN;
    ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
    ROBNeckSafetyPanBounds conservativeBounds = {0};
    if (!ROBNeckConservativeUnknownPanBounds(
            &configuration,
            &conservativeBounds
        )) {
        conservativeBounds.minimumDegrees = 0.0;
        conservativeBounds.maximumDegrees = 0.0;
    }
    self.currentNeckPanMinimumDegrees = conservativeBounds.minimumDegrees;
    self.currentNeckPanMaximumDegrees = conservativeBounds.maximumDegrees;
    self.neckPanCommandLimited = NO;
    self.upperNeckCommandCompensated = NO;
    self.neckCommandSource = @"Unknown pose";
    self.neckCommandSafetyStatus = status ?: @"Neck command pose is unknown.";
    self.neckLevelingReferenceIsValid = NO;
    self.panEnvelopeLowerTargetIsKnown = NO;
    self.pendingPanEnvelopeLowerTarget = ROBNeckSafetyTargetOff;
    self.pendingPanEnvelopeReadyAt = 0;
    self.panRecenterSettleGate = (ROBNeckSafetySettleGate){0};
    self.commandedNeckPanTargetReadyAt = 0;
    self.lastDesiredUpperNeckTargetIsKnown = NO;
    self.supervisedLowerRecoveryUntil = 0;
    self.manualNeckOverrideUntil = 0;
    self.visionNeckAuthorityUntil = 0;
    self.gestureNeckAuthorityUntil = 0;
    self.torsoNeckAuthorityRequiresOperatorAction = YES;
    }
}


// executes after everything in the xib/nib is initiallized
- (void)initialize_connection {
    // we don't have a serial port open yet
    self.amberHostIP = [[NSUserDefaults standardUserDefaults] stringForKey:@"ROBAmberHostIP"] ?: @"10.0.0.26";
    serialFileDescriptor_base = -1;
    serialFileDescriptor_maestro = -1;
    self.maestroConnectionValid = NO;
    self.actualSpeedL = 0;
    self.actualSpeedR = 0;
    self.lastVisionNeckPanTarget = 6000;
    self.lastVisionNeckTiltTarget = 6045;
    self.activeNeckSafetyConfiguration = [self loadNeckSafetyConfiguration];
    [self invalidateNeckCommandStateWithStatus:@"No neck target has been sent; physical pose is unknown."];
    self.neckCommandSource = @"None";
    readThreadRunning_base = FALSE;
    readThreadRunning_maestro = FALSE;

    exitSafeStart_waistRotation = false;
    energize_waistRotation = false;
    
    self.currentIncommingVerbalMessage = @"";
    self.baseSerialReceiveBuffer = [NSMutableData data];
    // Base is the only Arduino role presently installed.
    self.baseSerialStatusText = @"Detecting Base firmware…";
    self.maestroSerialStatusText = @"Discovering Maestro by USB identity…";
    [self refreshSerialList_base:@"Detecting Base firmware…"];
    [self refreshSerialList_maestro:@"Discovering Maestro by USB identity…"];
    self.controlModelDataDictionary = [NSMutableDictionary new];
    self.treadControlModelDataDictionary = [NSMutableDictionary new];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self connectToDetectedBase];
    });
    [self connectMaestro];
    
    self.controllerTimer = [NSTimer timerWithTimeInterval:0.1
                                                  target:self
                                                selector:@selector(renderController)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.controllerTimer forMode:NSRunLoopCommonModes];
    
    //give the master controller a few seconds to boot up first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sshIntoAmberMasterAndRunTail_L10:self];
        [self sshIntoAmberMasterAndRunTail_R11:self];
    });
}

- (NSArray<NSString *> *)usbSerialPortPaths
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching(kIOSerialBSDServiceValue),
        &iterator
    );
    if (result != KERN_SUCCESS) {
        return paths;
    }

    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(
            service,
            CFSTR(kIOCalloutDeviceKey),
            kCFAllocatorDefault,
            0
        );
        if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
            NSString *path = CFBridgingRelease(value);
            // Limit probing to USB callout devices. Never touch Bluetooth, network, or dial-in
            // channels, and never send a probe byte that another controller could interpret.
            if ([path hasPrefix:@"/dev/cu.usbmodem"] || [path hasPrefix:@"/dev/cu.usbserial"]) {
                [paths addObject:path];
            }
        } else if (value != NULL) {
            CFRelease(value);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return [paths sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

static CFTypeRef ROBRegistryProperty(io_object_t service, CFStringRef key)
{
    return IORegistryEntrySearchCFProperty(service,
                                           kIOServicePlane,
                                           key,
                                           kCFAllocatorDefault,
                                           kIORegistryIterateRecursively | kIORegistryIterateParents);
}

- (NSString *)maestroCommandPortPath
{
    NSMutableArray<NSDictionary<NSString *, id> *> *matches = [NSMutableArray array];
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                         IOServiceMatching(kIOSerialBSDServiceValue),
                                                         &iterator);
    if (result != KERN_SUCCESS) {
        return nil;
    }

    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef pathValue = IORegistryEntryCreateCFProperty(service,
                                                               CFSTR(kIOCalloutDeviceKey),
                                                               kCFAllocatorDefault,
                                                               0);
        CFTypeRef vendorValue = ROBRegistryProperty(service, CFSTR("idVendor"));
        CFTypeRef productValue = ROBRegistryProperty(service, CFSTR("USB Product Name"));
        if (productValue == NULL) {
            productValue = ROBRegistryProperty(service, CFSTR("Product Name"));
        }
        CFTypeRef interfaceNameValue = ROBRegistryProperty(service, CFSTR("USB Interface Name"));
        CFTypeRef interfaceNumberValue = ROBRegistryProperty(service, CFSTR("bInterfaceNumber"));

        NSString *path = (pathValue != NULL && CFGetTypeID(pathValue) == CFStringGetTypeID())
            ? (__bridge NSString *)pathValue : nil;
        NSNumber *vendor = (vendorValue != NULL && CFGetTypeID(vendorValue) == CFNumberGetTypeID())
            ? (__bridge NSNumber *)vendorValue : nil;
        NSString *product = (productValue != NULL && CFGetTypeID(productValue) == CFStringGetTypeID())
            ? (__bridge NSString *)productValue : @"";
        NSString *interfaceName = (interfaceNameValue != NULL && CFGetTypeID(interfaceNameValue) == CFStringGetTypeID())
            ? (__bridge NSString *)interfaceNameValue : @"";
        NSNumber *interfaceNumber = (interfaceNumberValue != NULL && CFGetTypeID(interfaceNumberValue) == CFNumberGetTypeID())
            ? (__bridge NSNumber *)interfaceNumberValue : nil;

        BOOL isPololuMaestro = vendor.integerValue == kPololuUSBVendorID
            && [product rangeOfString:@"Maestro" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (path.length > 0 && isPololuMaestro) {
            BOOL namedCommandPort = [interfaceName rangeOfString:@"Command" options:NSCaseInsensitiveSearch].location != NSNotFound;
            BOOL primaryInterface = interfaceNumber != nil && interfaceNumber.integerValue == 0;
            NSInteger priority = namedCommandPort ? 0 : (primaryInterface ? 1 : 2);
            [matches addObject:@{ @"path": path, @"priority": @(priority) }];
        }

        if (pathValue != NULL) CFRelease(pathValue);
        if (vendorValue != NULL) CFRelease(vendorValue);
        if (productValue != NULL) CFRelease(productValue);
        if (interfaceNameValue != NULL) CFRelease(interfaceNameValue);
        if (interfaceNumberValue != NULL) CFRelease(interfaceNumberValue);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    [matches sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult priorityOrder = [left[@"priority"] compare:right[@"priority"]];
        return priorityOrder != NSOrderedSame
            ? priorityOrder
            : [left[@"path"] localizedStandardCompare:right[@"path"]];
    }];
    return matches.firstObject[@"path"];
}

- (void)connectToDetectedBase
{
    @synchronized (self) {
        if (self.baseDetectionInProgress) {
            [self appendToIncomingText_base:@"\nBase firmware detection is already running.\n"];
            return;
        }
        self.baseDetectionInProgress = YES;
    }

    NSArray<NSString *> *paths = [self usbSerialPortPaths];
    for (NSString *path in paths) {
        int candidateFileDescriptor = -1;
        [self appendToIncomingText_base:[NSString stringWithFormat:@"\nDetecting Base firmware on %@…\n", path]];
        if ([self probeBaseFirmwareAtPath:path fileDescriptor:&candidateFileDescriptor]) {
            serialFileDescriptor_base = candidateFileDescriptor;
            [self.baseSerialReceiveBuffer setLength:0];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self refreshSerialList_base:path];
            });
            [self appendToIncomingText_base:[NSString stringWithFormat:@"Base firmware verified on %@\n", path]];
            [self performSelectorInBackground:@selector(incomingTextUpdateThread_base:)
                                   withObject:[NSThread currentThread]];
            @synchronized (self) { self.baseDetectionInProgress = NO; }
            return;
        }
        if (candidateFileDescriptor != -1) {
            close(candidateFileDescriptor);
        }
    }

    NSString *message = paths.count == 0
        ? @"No USB serial devices were found. Connect the Base Arduino and refresh."
        : @"No USB serial device emitted the existing Base startup response. Check its power/IMU startup, then refresh or choose a port manually.";
    [self appendToIncomingText_base:[@"\n" stringByAppendingString:message]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshSerialList_base:message];
    });
    @synchronized (self) { self.baseDetectionInProgress = NO; }
}

- (BOOL)probeBaseFirmwareAtPath:(NSString *)path fileDescriptor:(int *)matchedFileDescriptor
{
    int candidateFileDescriptor = -1;
    NSString *error = [self openSerialPort:path
                                      baud:kRHAPI_BAUDRATE
                      serialFileDescriptor:&candidateFileDescriptor
                                contextInt:kBaseSerialContext];
    if (error != nil) {
        return NO;
    }

    // Opening an Arduino serial device commonly resets it, but make the reset pulse explicit so
    // the already-flashed sketch reliably reprints its existing role-specific startup line.
    // This changes no firmware and sends no serial command bytes.
    ioctl(candidateFileDescriptor, TIOCSDTR);
    struct timespec resetPulse = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
    nanosleep(&resetPulse, NULL);
    ioctl(candidateFileDescriptor, TIOCCDTR);

    NSData *identity = [kROBBaseLegacyStartupIdentity dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *received = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kROBBaseProbeTimeoutSeconds];
    while (deadline.timeIntervalSinceNow > 0) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(candidateFileDescriptor, &readSet);
        NSTimeInterval remaining = MAX(0, deadline.timeIntervalSinceNow);
        struct timeval timeout = {
            .tv_sec = (time_t)remaining,
            .tv_usec = (suseconds_t)((remaining - floor(remaining)) * 1000000.0)
        };
        int ready = select(candidateFileDescriptor + 1, &readSet, NULL, NULL, &timeout);
        if (ready <= 0) {
            break;
        }

        uint8_t bytes[256];
        ssize_t count = read(candidateFileDescriptor, bytes, sizeof(bytes));
        if (count <= 0) {
            break;
        }
        [received appendBytes:bytes length:(NSUInteger)count];
        if ([received rangeOfData:identity options:0 range:NSMakeRange(0, received.length)].location != NSNotFound) {
            *matchedFileDescriptor = candidateFileDescriptor;
            return YES;
        }
        if (received.length > 8192) {
            [received replaceBytesInRange:NSMakeRange(0, received.length - 4096)
                                withBytes:NULL
                                   length:0];
        }
    }
    close(candidateFileDescriptor);
    return NO;
}

- (void) connectMaestro
{
    [self attemptMaestroReconnect];
}

- (void)attemptMaestroReconnect
{
    @synchronized (self) {
        self.maestroReconnectScheduled = NO;
        if (self.maestroConnectionValid || self.maestroReconnectInProgress) return;
        self.maestroReconnectInProgress = YES;
    }

    NSString *path = [self maestroCommandPortPath];
    NSString *error = nil;
    if (path.length > 0) {
        error = [self openSerialPort:path
                                baud:kRHAPI_MAESTRO_BAUDRATE
                serialFileDescriptor:&serialFileDescriptor_maestro
                          contextInt:kMaestroSerialContext];
    }

    @synchronized (self) {
        self.maestroReconnectInProgress = NO;
        self.maestroConnectionValid = path.length > 0 && error == nil && serialFileDescriptor_maestro >= 0;
        if (self.maestroConnectionValid) {
            self.maestroDevicePath = path;
            self.maestroMissingWasReported = NO;
            [self invalidateNeckCommandStateWithStatus:
                @"Maestro connected; neck pose must be re-established conservatively."];
        }
    }

    if (self.maestroConnectionValid) {
        NSLog(@"Maestro connected on %@", path);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshSerialList_maestro:path];
        });
        return;
    }

    @synchronized (self) {
        if (!self.maestroMissingWasReported) {
            NSLog(@"Maestro is unavailable; servo output is suppressed while Cerebro reconnects.");
            self.maestroMissingWasReported = YES;
        }
    }
    [self refreshSerialList_maestro:@"Maestro not detected; retrying automatically…"];
    [self scheduleMaestroReconnectAfterDelay:kMaestroReconnectDelaySeconds];
}

- (void)scheduleMaestroReconnectAfterDelay:(NSTimeInterval)delay
{
    @synchronized (self) {
        if (self.maestroReconnectScheduled || self.maestroConnectionValid) return;
        self.maestroReconnectScheduled = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self attemptMaestroReconnect];
    });
}

- (void)markMaestroDisconnectedForErrno:(int)errorNumber
{
    BOOL transitioned = NO;
    @synchronized (self) {
        if (self.maestroConnectionValid || serialFileDescriptor_maestro >= 0) {
            transitioned = YES;
        }
        self.maestroConnectionValid = NO;
        self.maestroDevicePath = nil;
        if (serialFileDescriptor_maestro >= 0) close(serialFileDescriptor_maestro);
        serialFileDescriptor_maestro = -1;
        [self invalidateNeckCommandStateWithStatus:
            @"Maestro disconnected; all neck pose assumptions were cleared."];
    }
    if (transitioned) {
        NSLog(@"Maestro disconnected (%s); servo output paused.", strerror(errorNumber));
    }
    [self refreshSerialList_maestro:@"Maestro disconnected; retrying automatically…"];
    [self scheduleMaestroReconnectAfterDelay:kMaestroReconnectDelaySeconds];
}

- (BOOL)writeMaestroBytes:(const void *)bytes length:(size_t)length
{
    int descriptor = -1;
    @synchronized (self) {
        if (!self.maestroConnectionValid || serialFileDescriptor_maestro < 0) {
            [self scheduleMaestroReconnectAfterDelay:kMaestroReconnectDelaySeconds];
            return NO;
        }
        descriptor = serialFileDescriptor_maestro;
    }

    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = write(descriptor, cursor, remaining);
        if (count > 0) {
            cursor += count;
            remaining -= (size_t)count;
            continue;
        }
        int writeError = count < 0 ? errno : EIO;
        if (writeError == EINTR) continue;
        if (writeError == EBADF || writeError == EIO || writeError == ENXIO || writeError == ENODEV) {
            [self markMaestroDisconnectedForErrno:writeError];
        }
        return NO;
    }
    return YES;
}

- (BOOL)sendMaestroTarget:(unsigned short)target channel:(unsigned char)channel
{
    unsigned char command[] = { 0x84, channel, target & 0x7F, (target >> 7) & 0x7F };
    return [self writeMaestroBytes:command length:sizeof(command)];
}

- (BOOL)sendMaestroLowerTarget:(unsigned short)lowerTarget
                   upperTarget:(unsigned short)upperTarget
{
    // Mini Maestro compact protocol: update contiguous lower/upper neck
    // channels with one command so a coupled move is parsed as one unit.
    unsigned char command[] = {
        0x9F,
        2,
        1,
        lowerTarget & 0x7F,
        (lowerTarget >> 7) & 0x7F,
        upperTarget & 0x7F,
        (upperTarget >> 7) & 0x7F,
    };
    return [self writeMaestroBytes:command length:sizeof(command)];
}

- (void)refreshSettledNeckEnvelopeAtTime:(NSTimeInterval)now
{
    if (self.pendingPanEnvelopeLowerTarget != ROBNeckSafetyTargetOff
        && now >= self.pendingPanEnvelopeReadyAt
        && self.lowerNeckTiltCommandKnown
        && self.commandedLowerNeckTiltTarget == self.pendingPanEnvelopeLowerTarget) {
        ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
        ROBNeckSafetyPanBounds settledBounds = {0};
        if (!ROBNeckSafetyAllowedPanBounds(
                &configuration,
                self.pendingPanEnvelopeLowerTarget,
                &settledBounds
            )) {
            return;
        }
        self.panEnvelopeLowerTarget = self.pendingPanEnvelopeLowerTarget;
        self.panEnvelopeLowerTargetIsKnown = YES;
        self.currentNeckPanMinimumDegrees = settledBounds.minimumDegrees;
        self.currentNeckPanMaximumDegrees = settledBounds.maximumDegrees;
        self.pendingPanEnvelopeLowerTarget = ROBNeckSafetyTargetOff;
        self.pendingPanEnvelopeReadyAt = 0;
    }
}

- (ROBNeckCommandDisposition)applySafeNeckPanTarget:(int)panTarget
              lowerTiltTarget:(int)lowerTiltTarget
            desiredUpperTarget:(int)desiredUpperTarget
                  includeLower:(BOOL)includeLower
 allowSupervisedLowerRecovery:(BOOL)allowSupervisedLowerRecovery
                        source:(NSString *)source
{
    @synchronized (self) {
    ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
    BOOL calibrationConfirmed = self.neckSafetyCalibrationConfirmed;
    ROBNeckSafetyConfig effectiveConfiguration = configuration;
    if (!calibrationConfirmed) {
        // Unknown counter-rotation polarity must never be energized by a
        // guessed default. Pan remains in the conservative restricted band
        // until the operator validates and saves the calibration.
        effectiveConfiguration.upperCounterRotationGain = 0.0;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    [self refreshSettledNeckEnvelopeAtTime:now];

    ROBNeckSafetyResult boundedJoints = {0};
    int requestedLower = includeLower
        ? lowerTiltTarget
        : (int)self.commandedLowerNeckTiltTarget;
    if (!ROBNeckSafetyApply(
            &effectiveConfiguration,
            ROBNeckSafetyTargetOff,
            requestedLower,
            ROBNeckSafetyTargetOff,
            &boundedJoints
        )) {
        self.neckCommandSafetyStatus = @"Neck command rejected: invalid safety configuration.";
        return ROBNeckCommandDispositionRejected;
    }
    int boundedLower = boundedJoints.lowerTarget;

    BOOL supervisedManualCommand = [source isEqualToString:@"Torso manual"];
    BOOL torsoCommand = [source hasPrefix:@"Torso "];
    BOOL directSupervisedLowerRecovery = supervisedManualCommand
        && allowSupervisedLowerRecovery
        && includeLower
        && boundedLower != ROBNeckSafetyTargetOff;
    if (directSupervisedLowerRecovery) {
        // A lower-axis action authorizes only this exact composite demand. The
        // short latch survives the pan staging interval and passive renderer
        // ticks, but cannot be reused for a different tracking/slider target.
        self.supervisedLowerRecoveryPanTarget = panTarget;
        self.supervisedLowerRecoveryTarget = boundedLower;
        self.supervisedLowerRecoveryUpperTarget = desiredUpperTarget;
        self.supervisedLowerRecoveryUntil = now
            + kROBNeckSupervisedRecoverySeconds;
    } else if (allowSupervisedLowerRecovery
               && boundedLower == ROBNeckSafetyTargetOff) {
        self.supervisedLowerRecoveryUntil = 0;
    }
    BOOL supervisedLowerRecovery = torsoCommand
        && includeLower
        && now <= self.supervisedLowerRecoveryUntil
        && panTarget == self.supervisedLowerRecoveryPanTarget
        && boundedLower == self.supervisedLowerRecoveryTarget
        && desiredUpperTarget == self.supervisedLowerRecoveryUpperTarget;
    if (torsoCommand
        && includeLower
        && self.supervisedLowerRecoveryUntil > 0
        && !supervisedLowerRecovery) {
        self.supervisedLowerRecoveryUntil = 0;
    }
    BOOL lowerChangeRequested = includeLower
        && (!self.lowerNeckTiltCommandKnown
            || boundedLower != self.commandedLowerNeckTiltTarget);
    BOOL knownLowerIsActive = self.lowerNeckTiltCommandKnown
        && self.commandedLowerNeckTiltTarget != ROBNeckSafetyTargetOff;
    BOOL lowerTurningOff = knownLowerIsActive
        && boundedLower == ROBNeckSafetyTargetOff;
    BOOL allNeckOffRequested = includeLower
        && panTarget == ROBNeckSafetyTargetOff
        && boundedLower == ROBNeckSafetyTargetOff
        && desiredUpperTarget == ROBNeckSafetyTargetOff;

    int effectivePanTarget = panTarget;
    int effectiveDesiredUpperTarget = desiredUpperTarget;
    BOOL panOffHeldForActiveLower = knownLowerIsActive
        && !lowerTurningOff
        && effectivePanTarget == ROBNeckSafetyTargetOff;
    BOOL upperOffHeldForActiveLower = knownLowerIsActive
        && !lowerTurningOff
        && effectiveDesiredUpperTarget == ROBNeckSafetyTargetOff;
    if (panOffHeldForActiveLower) {
        effectivePanTarget = self.neckPanCommandKnown
            && self.commandedNeckPanTarget != ROBNeckSafetyTargetOff
            ? (int)self.commandedNeckPanTarget
            : effectiveConfiguration.panCenterTarget;
    } else if (lowerTurningOff
               && effectivePanTarget == ROBNeckSafetyTargetOff) {
        // Recenter before releasing lower torque; a later render can send pan
        // OFF after the lower channel is confirmed OFF.
        effectivePanTarget = effectiveConfiguration.panCenterTarget;
    }
    if (upperOffHeldForActiveLower) {
        if (self.upperNeckTiltCommandKnown
            && self.commandedUpperNeckTiltTarget == ROBNeckSafetyTargetOff) {
            // This is possible only in the explicitly supervised,
            // uncompensated calibration path. Keeping OFF must not invent and
            // energize an upper target.
            effectiveDesiredUpperTarget = ROBNeckSafetyTargetOff;
        } else if (self.lastDesiredUpperNeckTargetIsKnown) {
            // Preserve the uncompensated camera demand. Feeding the already
            // compensated applied output back through the policy would apply
            // the lower-neck adjustment again on every render.
            effectiveDesiredUpperTarget = self.lastDesiredUpperNeckTarget;
        } else {
            self.neckCommandSafetyStatus =
                @"UPPER OFF HELD: prior uncompensated camera demand is unknown.";
            return ROBNeckCommandDispositionHeldForSafety;
        }
    }

    BOOL levelingRequired = effectiveConfiguration.cameraLevelingEnabled
        && fabs(effectiveConfiguration.upperCounterRotationGain) > DBL_EPSILON;
    BOOL lowerHeldForDisabledUpper = lowerChangeRequested
        && boundedLower != ROBNeckSafetyTargetOff
        && levelingRequired
        && effectiveDesiredUpperTarget == ROBNeckSafetyTargetOff;
    BOOL lowerHeldForCalibration = lowerChangeRequested
        && boundedLower != ROBNeckSafetyTargetOff
        && !calibrationConfirmed
        && !supervisedLowerRecovery;
    BOOL lowerHeldForRecovery = lowerChangeRequested
        && boundedLower != ROBNeckSafetyTargetOff
        && (!self.lowerNeckTiltCommandKnown
            || self.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff)
        && !supervisedLowerRecovery;
    BOOL supervisedLowerReferenceRecovery = lowerChangeRequested
        && boundedLower != ROBNeckSafetyTargetOff
        && (!self.lowerNeckTiltCommandKnown
            || self.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff)
        && supervisedLowerRecovery;
    BOOL coupledUpperPoseIsUnknown = lowerChangeRequested
        && boundedLower != ROBNeckSafetyTargetOff
        && levelingRequired
        && (!self.upperNeckTiltCommandKnown
            || self.commandedUpperNeckTiltTarget == ROBNeckSafetyTargetOff)
        && effectiveDesiredUpperTarget != ROBNeckSafetyTargetOff;

    ROBNeckSafetyPanBounds conservativeUnknownBounds = {0};
    if (!ROBNeckConservativeUnknownPanBounds(
            &effectiveConfiguration,
            &conservativeUnknownBounds
        )) {
        self.neckCommandSafetyStatus = @"Neck command rejected: invalid conservative pan bounds.";
        return ROBNeckCommandDispositionRejected;
    }
    ROBNeckSafetyPanBounds currentEnvelopeBounds = {
        .minimumDegrees = self.currentNeckPanMinimumDegrees,
        .maximumDegrees = self.currentNeckPanMaximumDegrees,
    };
    if (!calibrationConfirmed || !ROBNeckPanBoundsAreValid(currentEnvelopeBounds)) {
        currentEnvelopeBounds = conservativeUnknownBounds;
    }
    ROBNeckSafetyPanBounds requestedEnvelopeBounds = conservativeUnknownBounds;
    if (calibrationConfirmed
        && boundedLower != ROBNeckSafetyTargetOff
        && !ROBNeckSafetyAllowedPanBounds(
            &effectiveConfiguration,
            boundedLower,
            &requestedEnvelopeBounds
        )) {
        self.neckCommandSafetyStatus = @"Neck command rejected: invalid requested pan bounds.";
        return ROBNeckCommandDispositionRejected;
    }

    // Tighten each edge immediately. Widen either edge only after the lower
    // target settles. Persisting this explicit intersection is essential for
    // cross-branch moves whose envelopes are not nested (for example,
    // symmetric -45...+45 to forward -50...+40 remains -45...+40).
    ROBNeckSafetyPanBounds activeEnvelopeBounds = currentEnvelopeBounds;
    if (includeLower
        && !ROBNeckPanBoundsIntersect(
            currentEnvelopeBounds,
            requestedEnvelopeBounds,
            &activeEnvelopeBounds
        )) {
        self.neckCommandSafetyStatus = @"Neck command rejected: pan envelopes do not intersect.";
        return ROBNeckCommandDispositionRejected;
    }
    BOOL requestedEnvelopeIsContained = ROBNeckPanBoundsContain(
        currentEnvelopeBounds,
        requestedEnvelopeBounds
    );

    int envelopeLower = calibrationConfirmed && self.panEnvelopeLowerTargetIsKnown
        ? self.panEnvelopeLowerTarget
        : ROBNeckSafetyTargetOff;
    if (includeLower && boundedLower == ROBNeckSafetyTargetOff) {
        // OFF has no shaft feedback. Keep the current/unknown intersection and
        // never grant a wider pan range merely because torque was released.
        self.panEnvelopeLowerTargetIsKnown = NO;
        self.pendingPanEnvelopeLowerTarget = ROBNeckSafetyTargetOff;
        self.pendingPanEnvelopeReadyAt = 0;
        envelopeLower = ROBNeckSafetyTargetOff;
    } else if (calibrationConfirmed
               && includeLower
               && boundedLower != ROBNeckSafetyTargetOff
               && requestedEnvelopeIsContained) {
        self.panEnvelopeLowerTarget = boundedLower;
        self.panEnvelopeLowerTargetIsKnown = YES;
        self.pendingPanEnvelopeLowerTarget = ROBNeckSafetyTargetOff;
        self.pendingPanEnvelopeReadyAt = 0;
        envelopeLower = boundedLower;
    }
    if (!calibrationConfirmed) {
        self.panEnvelopeLowerTargetIsKnown = NO;
        self.pendingPanEnvelopeLowerTarget = ROBNeckSafetyTargetOff;
        self.pendingPanEnvelopeReadyAt = 0;
        activeEnvelopeBounds = conservativeUnknownBounds;
        envelopeLower = ROBNeckSafetyTargetOff;
    }

    // Before a lower move (including active -> OFF), establish pan inside the
    // destination envelope. The pure-C latch keeps its original monotonic
    // deadline across repeated continuous-slider events.
    BOOL lowerHeldForPanRecenter = NO;
    ROBNeckSafetySettleGate panGate = self.panRecenterSettleGate;
    BOOL bypassSequencingForUnknownAllOff = allNeckOffRequested
        && !self.lowerNeckTiltCommandKnown;
    if (lowerChangeRequested
        && !bypassSequencingForUnknownAllOff
        && !lowerHeldForDisabledUpper
        && !lowerHeldForCalibration
        && !lowerHeldForRecovery) {
        ROBNeckSafetyResult candidatePan = {0};
        if (!ROBNeckSafetyApply(
            &effectiveConfiguration,
            self.neckPanCommandKnown
                ? (int)self.commandedNeckPanTarget
                : ROBNeckSafetyTargetOff,
            calibrationConfirmed ? boundedLower : ROBNeckSafetyTargetOff,
            ROBNeckSafetyTargetOff,
            &candidatePan
        )) {
            self.neckCommandSafetyStatus = @"Neck command rejected by the pan safety envelope.";
            return ROBNeckCommandDispositionRejected;
        }
        ROBNeckSafetyResult stagedPan = {0};
        if (!ROBNeckSafetyApply(
                &effectiveConfiguration,
                effectivePanTarget,
                envelopeLower,
                ROBNeckSafetyTargetOff,
                &stagedPan
            )
            || !ROBNeckClampPanResultToBounds(
                &effectiveConfiguration,
                activeEnvelopeBounds,
                &stagedPan
            )) {
            self.neckCommandSafetyStatus = @"Neck command rejected by the staged pan envelope.";
            return ROBNeckCommandDispositionRejected;
        }
        BOOL panPoseIsUnknown =
            !self.neckPanCommandKnown
            || self.commandedNeckPanTarget == ROBNeckSafetyTargetOff;
        BOOL currentPanIsOutsideCandidateEnvelope =
            !panPoseIsUnknown
            && candidatePan.panTarget != self.commandedNeckPanTarget;
        BOOL requestedPanWillChange = !self.neckPanCommandKnown
            || stagedPan.panTarget != self.commandedNeckPanTarget;
        BOOL priorPanTargetIsStillSettling = self.neckPanCommandKnown
            && now < self.commandedNeckPanTargetReadyAt;
        BOOL sequencingRequired = panPoseIsUnknown
            || currentPanIsOutsideCandidateEnvelope
            || requestedPanWillChange
            || priorPanTargetIsStillSettling
            || coupledUpperPoseIsUnknown
            || panGate.active;
        if (sequencingRequired) {
            lowerHeldForPanRecenter = ROBNeckSafetySettleGateShouldHold(
                &panGate,
                boundedLower,
                stagedPan.panTarget,
                effectivePanTarget != ROBNeckSafetyTargetOff,
                !panPoseIsUnknown
                    && !currentPanIsOutsideCandidateEnvelope
                    && !requestedPanWillChange
                    && !priorPanTargetIsStillSettling
                    && !coupledUpperPoseIsUnknown,
                now,
                kROBNeckPanRecenterSeconds
            );
        } else {
            ROBNeckSafetySettleGateReset(&panGate);
        }
    } else {
        ROBNeckSafetySettleGateReset(&panGate);
    }
    self.panRecenterSettleGate = panGate;

    BOOL upperOffStagedForLowerShutdown = lowerTurningOff
        && lowerHeldForPanRecenter
        && desiredUpperTarget == ROBNeckSafetyTargetOff
        && self.upperNeckTiltCommandKnown
        && self.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff;
    if (upperOffStagedForLowerShutdown) {
        if (!self.lastDesiredUpperNeckTargetIsKnown) {
            self.neckCommandSafetyStatus =
                @"LOWER OFF HELD: prior uncompensated camera demand is unknown.";
            return ROBNeckCommandDispositionHeldForSafety;
        }
        effectiveDesiredUpperTarget = self.lastDesiredUpperNeckTarget;
    }

    ROBNeckSafetyResult panResult = {0};
    if (!ROBNeckSafetyApply(
            &effectiveConfiguration,
            effectivePanTarget,
            envelopeLower,
            ROBNeckSafetyTargetOff,
            &panResult
        )
        || !ROBNeckClampPanResultToBounds(
            &effectiveConfiguration,
            activeEnvelopeBounds,
            &panResult
        )) {
        self.neckCommandSafetyStatus = @"Neck command rejected by the pan safety envelope.";
        return ROBNeckCommandDispositionRejected;
    }

    BOOL panTargetChanged = !self.neckPanCommandKnown
        || panResult.panTarget != self.commandedNeckPanTarget;
    BOOL panWriteSucceeded = [self sendMaestroTarget:(unsigned short)panResult.panTarget
                                              channel:0];
    if (!panWriteSucceeded) {
        [self invalidateNeckCommandStateWithStatus:
            @"NECK OUTPUT FAILED; physical pose and prior targets are unknown."];
        return ROBNeckCommandDispositionRejected;
    }
    self.commandedNeckPanTarget = panResult.panTarget;
    self.neckPanCommandKnown = YES;
    if (panTargetChanged) {
        self.commandedNeckPanTargetReadyAt = now + kROBNeckPanRecenterSeconds;
    }
    self.currentNeckPanMinimumDegrees = panResult.allowedPanMinimumDegrees;
    self.currentNeckPanMaximumDegrees = panResult.allowedPanMaximumDegrees;
    self.neckPanCommandLimited = panResult.panClamped;
    double degrees = NAN;
    self.commandedNeckPanDegrees = ROBNeckSafetyPanTargetToDegrees(
        &effectiveConfiguration,
        panResult.panTarget,
        &degrees
    ) ? degrees : NAN;

    int lowerForLeveling = (lowerChangeRequested
                            && !lowerHeldForDisabledUpper
                            && !lowerHeldForPanRecenter)
        ? boundedLower
        : (int)self.commandedLowerNeckTiltTarget;
    if (lowerForLeveling == ROBNeckSafetyTargetOff && boundedLower != ROBNeckSafetyTargetOff) {
        lowerForLeveling = boundedLower;
    }

    if (levelingRequired
        && self.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff
        && lowerForLeveling != ROBNeckSafetyTargetOff) {
        // Until the first lower target is actually issued, keep rebasing the
        // desired upper target so no compensation accumulates against an
        // unknown physical lower pose.
        self.neckLevelingReferenceLowerTarget = lowerForLeveling;
        self.neckLevelingReferenceIsValid = YES;
    } else if (levelingRequired
        && !self.neckLevelingReferenceIsValid
        && lowerForLeveling != ROBNeckSafetyTargetOff
        && effectiveDesiredUpperTarget != ROBNeckSafetyTargetOff) {
        self.neckLevelingReferenceLowerTarget = lowerForLeveling;
        self.neckLevelingReferenceIsValid = YES;
    }

    // The upper slider/controller value stays an uncompensated camera demand.
    // Shift that demand into the policy's configured reference frame so the
    // first accepted command never causes an automatic leveling jump.
    int adjustedDesiredUpper = effectiveDesiredUpperTarget;
    if (effectiveDesiredUpperTarget != ROBNeckSafetyTargetOff
        && lowerForLeveling != ROBNeckSafetyTargetOff
        && levelingRequired
        && self.neckLevelingReferenceIsValid) {
        double configuredReference = ROBNeckSafetyReferenceLowerTarget(&effectiveConfiguration);
        double referenceAdjustment = effectiveConfiguration.upperCounterRotationGain
            * (configuredReference - self.neckLevelingReferenceLowerTarget);
        double adjusted = (double)effectiveDesiredUpperTarget + referenceAdjustment;
        adjusted = fmax((double)INT32_MIN, fmin((double)INT32_MAX, adjusted));
        adjustedDesiredUpper = (int)lround(adjusted);
    }

    ROBNeckSafetyResult leveledResult = {0};
    if (!ROBNeckSafetyApply(
            &effectiveConfiguration,
            ROBNeckSafetyTargetOff,
            lowerForLeveling,
            adjustedDesiredUpper,
            &leveledResult
        )) {
        self.neckCommandSafetyStatus = @"Neck command rejected by camera-leveling safety.";
        return ROBNeckCommandDispositionRejected;
    }

    // If the requested lower move would exhaust the upper camera joint, keep
    // the lower joint where it is. Recompute the upper command for that held
    // lower pose so a rejected move does not unnecessarily drive the camera
    // into its stop.
    double configuredLowerReference = ROBNeckSafetyReferenceLowerTarget(
        &effectiveConfiguration
    );
    double requestedUnclampedUpper = (double)adjustedDesiredUpper;
    if (levelingRequired
        && lowerForLeveling != ROBNeckSafetyTargetOff) {
        requestedUnclampedUpper += effectiveConfiguration.upperCounterRotationGain
            * ((double)lowerForLeveling - configuredLowerReference);
    }
    double currentUnclampedUpper = (double)adjustedDesiredUpper;
    if (levelingRequired
        && self.lowerNeckTiltCommandKnown
        && self.commandedLowerNeckTiltTarget != ROBNeckSafetyTargetOff) {
        currentUnclampedUpper += effectiveConfiguration.upperCounterRotationGain
            * ((double)self.commandedLowerNeckTiltTarget - configuredLowerReference);
    }
    double requestedUpperOverflow = ROBTargetOverflow(
        requestedUnclampedUpper,
        effectiveConfiguration.upperMinimumTarget,
        effectiveConfiguration.upperMaximumTarget
    );
    double currentUpperOverflow = ROBTargetOverflow(
        currentUnclampedUpper,
        effectiveConfiguration.upperMinimumTarget,
        effectiveConfiguration.upperMaximumTarget
    );
    BOOL cameraLimitMoveImprovesRecovery = requestedUpperOverflow + 0.5
        < currentUpperOverflow;
    BOOL lowerHeldForCameraLimit = lowerChangeRequested
        && boundedLower != ROBNeckSafetyTargetOff
        && levelingRequired
        && !lowerHeldForDisabledUpper
        && !lowerHeldForCalibration
        && !lowerHeldForRecovery
        && !lowerHeldForPanRecenter
        && leveledResult.upperClamped
        && !cameraLimitMoveImprovesRecovery;
    BOOL requestedCameraLimitWasReached = leveledResult.upperClamped;
    if (lowerHeldForCameraLimit) {
        lowerForLeveling = (int)self.commandedLowerNeckTiltTarget;
        if (!ROBNeckSafetyApply(
                &effectiveConfiguration,
                ROBNeckSafetyTargetOff,
                lowerForLeveling,
                adjustedDesiredUpper,
                &leveledResult
            )) {
            self.neckCommandSafetyStatus = @"Neck command rejected by camera-leveling safety.";
            return ROBNeckCommandDispositionRejected;
        }
    }

    BOOL mayMoveLower = includeLower
        && !lowerHeldForDisabledUpper
        && !lowerHeldForCalibration
        && !lowerHeldForRecovery
        && !lowerHeldForPanRecenter
        && !lowerHeldForCameraLimit;
    BOOL lowerWriteSucceeded = NO;
    BOOL upperWriteSucceeded = NO;
    if (mayMoveLower) {
        // Once pan/unknown-pose staging has cleared, channels 1 and 2 receive
        // their lower and counter-rotated upper targets together. This keeps
        // an established camera from being pre-tilted to its final endpoint
        // before lower motion starts. The installed joints use matching
        // servos; with the calibrated -1 gain, equal and opposite target
        // deltas are issued together for nominally matched travel.
        BOOL coupledWriteSucceeded = [self
            sendMaestroLowerTarget:(unsigned short)boundedLower
            upperTarget:(unsigned short)leveledResult.upperTarget];
        lowerWriteSucceeded = coupledWriteSucceeded;
        upperWriteSucceeded = coupledWriteSucceeded;
    } else {
        // A held lower joint still permits an upper target to be established,
        // which is needed when that coupled axis was previously unknown/off.
        upperWriteSucceeded = [self
            sendMaestroTarget:(unsigned short)leveledResult.upperTarget
            channel:2];
    }
    if (!upperWriteSucceeded || (mayMoveLower && !lowerWriteSucceeded)) {
        [self invalidateNeckCommandStateWithStatus:
            @"NECK OUTPUT PARTIAL; physical pose and prior targets are unknown."];
        return ROBNeckCommandDispositionRejected;
    }
    self.commandedUpperNeckTiltTarget = leveledResult.upperTarget;
    self.upperNeckTiltCommandKnown = YES;
    self.lastDesiredUpperNeckTargetIsKnown =
        effectiveDesiredUpperTarget != ROBNeckSafetyTargetOff;
    self.lastDesiredUpperNeckTarget = MAX(
        effectiveConfiguration.upperMinimumTarget,
        MIN(effectiveConfiguration.upperMaximumTarget, effectiveDesiredUpperTarget)
    );
    double runtimeAdjustment = levelingRequired
        && self.neckLevelingReferenceIsValid
        ? effectiveConfiguration.upperCounterRotationGain
            * (lowerForLeveling - self.neckLevelingReferenceLowerTarget)
        : 0.0;
    self.upperNeckCommandCompensated =
        leveledResult.upperTarget != ROBNeckSafetyTargetOff
        && fabs(runtimeAdjustment) >= 0.5;
    if (leveledResult.upperTarget == ROBNeckSafetyTargetOff) {
        self.neckLevelingReferenceIsValid = NO;
    }

    if (mayMoveLower) {
        self.commandedLowerNeckTiltTarget = boundedLower;
        self.lowerNeckTiltCommandKnown = YES;
        self.supervisedLowerRecoveryUntil = 0;
        self.panRecenterSettleGate = (ROBNeckSafetySettleGate){0};
        if (boundedLower == ROBNeckSafetyTargetOff) {
            self.panEnvelopeLowerTargetIsKnown = NO;
            self.pendingPanEnvelopeLowerTarget = ROBNeckSafetyTargetOff;
            self.pendingPanEnvelopeReadyAt = 0;
            self.neckLevelingReferenceIsValid = NO;
            if (panTarget == ROBNeckSafetyTargetOff
                && panResult.panTarget != ROBNeckSafetyTargetOff) {
                if (![self sendMaestroTarget:ROBNeckSafetyTargetOff channel:0]) {
                    [self invalidateNeckCommandStateWithStatus:
                        @"NECK OUTPUT PARTIAL; physical pose and prior targets are unknown."];
                    return ROBNeckCommandDispositionRejected;
                }
                self.commandedNeckPanTarget = ROBNeckSafetyTargetOff;
                self.neckPanCommandKnown = YES;
                self.commandedNeckPanTargetReadyAt = now
                    + kROBNeckPanRecenterSeconds;
                self.commandedNeckPanDegrees = NAN;
                self.neckPanCommandLimited = NO;
            }
        } else if (calibrationConfirmed
                   && !requestedEnvelopeIsContained) {
            if (self.pendingPanEnvelopeLowerTarget != boundedLower
                || self.pendingPanEnvelopeReadyAt <= 0) {
                // One or both destination edges widen only after settling.
                // Identical periodic/gesture demands must not postpone this
                // deadline forever; only a new lower target restarts it.
                self.pendingPanEnvelopeLowerTarget = boundedLower;
                self.pendingPanEnvelopeReadyAt = now
                    + kROBNeckClearanceSettleSeconds;
            }
        } else if (calibrationConfirmed) {
            self.panEnvelopeLowerTarget = boundedLower;
            self.panEnvelopeLowerTargetIsKnown = YES;
        }
    }

    self.neckCommandSource = source ?: @"Unknown";

    NSMutableArray<NSString *> *status = [NSMutableArray array];
    if (!calibrationConfirmed) {
        [status addObject:[NSString stringWithFormat:
            @"CALIBRATION REQUIRED: AUTOMATIC LOWER MOTION HELD; PAN %.1f°…%+.1f°",
            panResult.allowedPanMinimumDegrees,
            panResult.allowedPanMaximumDegrees]];
    }
    if (panResult.panClamped) {
        [status addObject:[NSString stringWithFormat:
            @"PAN LIMITED %.1f°…%+.1f°",
            panResult.allowedPanMinimumDegrees,
            panResult.allowedPanMaximumDegrees]];
    }
    if (boundedJoints.lowerClamped) [status addObject:@"LOWER CLAMPED"];
    if (self.upperNeckCommandCompensated) [status addObject:@"CAMERA COUNTER-ROTATED"];
    if (requestedCameraLimitWasReached) [status addObject:@"CAMERA LIMIT REACHED"];
    if (lowerHeldForDisabledUpper) [status addObject:@"LOWER HELD: UPPER SERVO OFF"];
    if (lowerHeldForCalibration) [status addObject:@"LOWER HELD: CALIBRATION REQUIRED (USE SUPERVISED MANUAL JOG)"];
    if (lowerHeldForRecovery) [status addObject:@"LOWER HELD: MANUAL POSE RECOVERY REQUIRED"];
    if (supervisedLowerReferenceRecovery) [status addObject:@"SUPERVISED LOWER REFERENCE RECOVERY (NO SHAFT FEEDBACK)"];
    if (lowerHeldForPanRecenter) [status addObject:@"LOWER HELD: ESTABLISHING SAFE PAN/CAMERA TARGETS"];
    if (lowerHeldForCameraLimit) [status addObject:@"LOWER HELD: CAMERA COMPENSATION LIMIT"];
    if (panOffHeldForActiveLower) [status addObject:@"PAN OFF HELD: LOWER SERVO ACTIVE"];
    if (upperOffHeldForActiveLower) [status addObject:@"UPPER OFF HELD: LOWER SERVO ACTIVE"];
    if (upperOffStagedForLowerShutdown) [status addObject:@"UPPER OFF STAGED UNTIL PAN RECENTERS"];
    if (self.pendingPanEnvelopeLowerTarget != ROBNeckSafetyTargetOff) {
        [status addObject:@"CLEARANCE SETTLING"];
    }
    if (status.count == 0) [status addObject:@"Within configured command envelope"];
    self.neckCommandSafetyStatus = [status componentsJoinedByString:@" • "];
    return (lowerHeldForDisabledUpper
            || lowerHeldForCalibration
            || lowerHeldForRecovery
            || lowerHeldForPanRecenter
            || lowerHeldForCameraLimit)
        ? ROBNeckCommandDispositionHeldForSafety
        : ROBNeckCommandDispositionAppliedCommand;
    }
}


// open the serial port
//   - nil is returned on success
//   - an error message is returned otherwise
- (NSString *) openSerialPort: (NSString *)serialPortFile baud: (speed_t)baudRate serialFileDescriptor:(int *)serialFileDescriptor contextInt:(int)contextInt{
    int success;
    
    // close the pousrt if it is already open
    if ((*serialFileDescriptor) != -1) {
        close((*serialFileDescriptor));
        (*serialFileDescriptor) = -1;
        
        switch (contextInt) {
            case 2:
                while(readThreadRunning_base);
                break;
            case 3:
                while(readThreadRunning_maestro);
                break;
                
            default:
                break;
        }
        
        // wait for the reading thread to die
        
        
        // re-opening the same port REALLY fast will fail spectacularly... better to sleep a sec
        sleep(0.5);
    }
    
    // c-string path to serial-port file
    const char *bsdPath = [serialPortFile cStringUsingEncoding:NSUTF8StringEncoding];
    
    // Hold the original termios attributes we are setting
    struct termios options;
    
    // receive latency ( in microseconds )
    unsigned long mics = 3;
    
    // error message string
    NSString *errorMessage = nil;
    
    // open the port
    //     O_NONBLOCK causes the port to open without any delay (we'll block with another call)
    (*serialFileDescriptor) = open(bsdPath, O_RDWR | O_NOCTTY | O_EXLOCK | O_NONBLOCK );
    
    if ((*serialFileDescriptor) == -1) {
        // check if the port opened correctly
        errorMessage = @"Error: couldn't open serial port";
    } else {
        // TIOCEXCL causes blocking of non-root processes on this serial-port
        success = ioctl((*serialFileDescriptor), TIOCEXCL);
        if ( success == -1) {
            errorMessage = @"Error: couldn't obtain lock on serial port";
        } else {
            success = fcntl((*serialFileDescriptor), F_SETFL, 0);
            if ( success == -1) {
                // clear the O_NONBLOCK flag; all calls from here on out are blocking for non-root processes
                errorMessage = @"Error: couldn't obtain lock on serial port";
            } else {
                // Get the current options and save them so we can restore the default settings later.
                success = tcgetattr((*serialFileDescriptor), &gOriginalTTYAttrs);
                if ( success == -1) {
                    errorMessage = @"Error: couldn't get serial attributes";
                } else {
                    // copy the old termios settings into the current
                    //   you want to do this so that you get all the control characters assigned
                    options = gOriginalTTYAttrs;
                    
                    /*
                     cfmakeraw(&options) is equivilent to:
                     options->c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
                     options->c_oflag &= ~OPOST;
                     options->c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
                     options->c_cflag &= ~(CSIZE | PARENB);
                     options->c_cflag |= CS8;
                     */
                    cfmakeraw(&options);
                    
                    // set tty attributes (raw-mode in this case)
                    success = tcsetattr((*serialFileDescriptor), TCSANOW, &options);
                    if ( success == -1) {
                        errorMessage = @"Error: coudln't set serial attributes";
                    } else {
                        // Set baud rate (any arbitrary baud rate can be set this way)
                        success = ioctl((*serialFileDescriptor), IOSSIOSPEED, &baudRate);
                        if ( success == -1) {
                            errorMessage = @"Error: Baud Rate out of bounds";
                        } else {
                            // Set the receive latency (a.k.a. don't wait to buffer data)
                            success = ioctl((*serialFileDescriptor), IOSSDATALAT, &mics);
                            if ( success == -1) {
                                errorMessage = @"Error: coudln't set serial latency";
                            }
                        }
                    }
                }
            }
        }
    }
    
    // make sure the port is closed if a problem happens
    if (((*serialFileDescriptor) != -1) && (errorMessage != nil)) {
        close((*serialFileDescriptor));
        (*serialFileDescriptor) = -1;
    }
    
    return errorMessage;
}

// updates the textarea for incoming text by appending text
- (void)appendToIncomingText_base: (id) text{
    // Give every appended run a semantic foreground. A bare attributed
    // string otherwise receives a fixed default that can remain dark when the
    // app moves into Dark Mode.
    NSString *outputText = [text isKindOfClass:[NSString class]]
        ? [(NSString *)text copy]
        : [[text description] copy];
    //TODO: DISPATCH GET MAIN THREAD HERE FOR USING TEXTSTORAGE
    dispatch_async(dispatch_get_main_queue(), ^(){
        [self.delegate didOutputSerialResponse_Base:outputText];
        // The console is intentionally opt-in. Serial parsing and robot state
        // continue headlessly, but output is not retained or rendered while
        // its separate diagnostics window is closed.
        NSTextView *outputArea = self.serialOutputArea_base;
        if (outputArea == nil) {
            return;
        }
        NSAttributedString *attrString = [[NSAttributedString alloc]
            initWithString:outputText
                 attributes:@{NSForegroundColorAttributeName: NSColor.labelColor}];
        NSTextStorage *textStorage = outputArea.textStorage;
        [textStorage beginEditing];
        [textStorage appendAttributedString:attrString];
        if (textStorage.length > kROBBaseConsoleMaximumCharacters) {
            NSUInteger excess = textStorage.length - kROBBaseConsoleMaximumCharacters;
            NSRange trimRange = [textStorage.string
                rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, excess)];
            [textStorage deleteCharactersInRange:trimRange];
        }
        [textStorage endEditing];
        
        // scroll to the bottom
        NSRange myRange;
        myRange.length = 0;
        myRange.location = [textStorage length];
        [outputArea scrollRangeToVisible:myRange];
    });
}

- (void)incomingTextUpdateThread_base: (NSThread *) parentThread{
    
    // mark that the thread is running
    readThreadRunning_base = TRUE;
    [NSThread sleepForTimeInterval:1];
    const int BUFFER_SIZE = 100;
    char byte_buffer[BUFFER_SIZE]; // buffer for holding incoming data
    long numBytes=0; // number of bytes read during read
    
    // assign a high priority to this thread
    [NSThread setThreadPriority:1.0];
    
    // this will loop unitl the serial port closes
    while(TRUE) {
        // read() blocks until some data is available or the port is closed
        numBytes = read(serialFileDescriptor_base, byte_buffer, BUFFER_SIZE); // read up to the size of the buffer
        if(numBytes>0) {
            [self consumeBaseSerialBytes:byte_buffer length:(NSUInteger)numBytes];
        } else {
            break; // Stop the thread if there is an error
        }
    }
    
    // make sure the serial port is closed
    if (serialFileDescriptor_base != -1) {
        close(serialFileDescriptor_base);
        serialFileDescriptor_base = -1;
    }
    
    // mark that the thread has quit
    readThreadRunning_base = FALSE;
    
}

- (void)consumeBaseSerialBytes:(const void *)bytes length:(NSUInteger)length
{
    [self.baseSerialReceiveBuffer appendBytes:bytes length:length];
    const uint8_t newline = '\n';
    while (self.baseSerialReceiveBuffer.length > 0) {
        NSRange newlineRange = [self.baseSerialReceiveBuffer rangeOfData:[NSData dataWithBytes:&newline length:1]
                                                                 options:0
                                                                   range:NSMakeRange(0, self.baseSerialReceiveBuffer.length)];
        if (newlineRange.location == NSNotFound) {
            // Malformed or noisy devices cannot grow the receive buffer without bound.
            if (self.baseSerialReceiveBuffer.length > 4096) {
                [self.baseSerialReceiveBuffer replaceBytesInRange:NSMakeRange(0, self.baseSerialReceiveBuffer.length - 2048)
                                                        withBytes:NULL
                                                           length:0];
            }
            return;
        }

        NSData *lineData = [self.baseSerialReceiveBuffer subdataWithRange:NSMakeRange(0, newlineRange.location)];
        [self.baseSerialReceiveBuffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(newlineRange))
                                                withBytes:NULL
                                                   length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line != nil) {
            [self handleBaseSerialLine:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        }
    }
}

- (void)handleBaseSerialLine:(NSString *)line
{
    if (line.length > 0) {
        [self appendToIncomingText_base:[line stringByAppendingString:@"\n"]];
    }

    BOOL frontWarning = [line containsString:@"WARNING! FRONT"] ||
        [line containsString:@"OBSTACLE IS BLOCKING FRONT"];
    BOOL backWarning = [line containsString:@"WARNING! BACK"] ||
        [line containsString:@"OBSTACLE IS BLOCKING BACK"];
    if (frontWarning || backWarning) {
        NSTimeInterval received = NSProcessInfo.processInfo.systemUptime;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate updateBaseLegacyIRWarningFront:frontWarning
                                                     back:backWarning
                                                 received:received];
        });
        return;
    }

    static NSString * const prefix = @"ROB:IR=";
    if (![line hasPrefix:prefix]) { return; }

    NSArray<NSString *> *fields = [[line substringFromIndex:prefix.length] componentsSeparatedByString:@","];
    if (fields.count != 6) { return; }
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:6];
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    for (NSString *field in fields) {
        if (field.length == 0 || [field rangeOfCharacterFromSet:nonDigits].location != NSNotFound) { return; }
        NSInteger value = field.integerValue;
        if (value > 1000) { return; }
        [values addObject:@(value)];
    }

    NSTimeInterval received = NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate updateBaseIRFrontLeft:values[0].integerValue
                                  frontRight:values[1].integerValue
                                        left:values[2].integerValue
                                       right:values[3].integerValue
                                    backLeft:values[4].integerValue
                                   backRight:values[5].integerValue
                                    received:received];
    });
}



- (void) refreshSerialList_base: (NSString *) selectedText {
    self.baseSerialStatusText = selectedText.length > 0
        ? selectedText
        : @"Base USB status unavailable";
    NSArray<NSString *> *paths = [self usbSerialPortPaths];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPopUpButton *popup = self.serialListPullDown_base;
        if (popup != nil) {
            [popup removeAllItems];
            [popup addItemWithTitle:self.baseSerialStatusText];
            popup.itemArray.firstObject.enabled =
                [self.baseSerialStatusText hasPrefix:@"/dev/cu.usb"];
            for (NSString *path in paths) {
                if (![path isEqualToString:self.baseSerialStatusText]) {
                    [popup addItemWithTitle:path];
                }
            }
            [popup selectItemAtIndex:0];
        }
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ROBSerialHardwareDidChangeNotification
                          object:self];
    });
}

- (void) refreshSerialList_maestro: (NSString *) selectedText {
    self.maestroSerialStatusText = selectedText.length > 0
        ? selectedText
        : @"Maestro USB status unavailable";
    NSArray<NSString *> *paths = [self usbSerialPortPaths];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPopUpButton *popup = self.serialListPullDown_maestro;
        if (popup != nil) {
            [popup removeAllItems];
            [popup addItemWithTitle:self.maestroSerialStatusText];
            for (NSString *path in paths) {
                if (![path isEqualToString:self.maestroSerialStatusText]) {
                    [popup addItemWithTitle:path];
                }
            }
            [popup selectItemAtIndex:0];
        }
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ROBSerialHardwareDidChangeNotification
                          object:self];
    });
}

- (void)refreshSerialPortControls
{
    [self refreshSerialList_base:self.baseSerialStatusText ?: @"Detecting Base firmware…"];
    [self refreshSerialList_maestro:self.maestroSerialStatusText ?: @"Discovering Maestro by USB identity…"];
}

// send a string to the serial port
- (void) writeString: (NSString *) str serialFileDescriptor:(int)serialFileDescriptor {
    if(serialFileDescriptor!=-1) {
        write(serialFileDescriptor, [str cStringUsingEncoding:NSUTF8StringEncoding], [str length]);
    } else {
        // make sure the user knows they should select a serial port
        [self appendToIncomingText_base:@"\n ERROR: Base Arduino is not connected\n"];
    }
}

// send a byte to the serial port
- (void) writeByte: (uint8_t *) val serialFileDescriptor:(int)serialFileDescriptor{
    if(serialFileDescriptor!=-1) {
        write(serialFileDescriptor, val, 1);
    } else {
        // make sure the user knows they should select a serial port
        [self appendToIncomingText_base:@"\n ERROR: Base Arduino is not connected\n"];
    }
}

- (void) serialPortSelected_base
{
    [self selectBaseSerialPort:self.serialListPullDown_base.titleOfSelectedItem];
}

- (void)selectBaseSerialPort:(NSString *)path
{
    NSString *selectedPath = [path copy] ?: @"";
    if (![selectedPath hasPrefix:@"/dev/cu.usb"] ||
        ![[self usbSerialPortPaths] containsObject:selectedPath]) {
        NSBeep();
        [self refreshSerialPortControls];
        return;
    }
    @synchronized (self) {
        if (self.baseDetectionInProgress) {
            NSBeep();
            [self appendToIncomingText_base:
                @"\nAutomatic Base USB detection is still running; try the override again when it finishes.\n"];
            return;
        }
        if (serialFileDescriptor_base >= 0) {
            // Never replace the descriptor underneath the live reader thread.
            // A manual choice is a recovery override only when automatic Base
            // discovery has not already established a connection.
            if (![self.baseSerialStatusText isEqualToString:selectedPath]) {
                NSBeep();
                [self appendToIncomingText_base:
                    @"\nBase is already connected; manual USB override was not applied.\n"];
            }
            [self refreshSerialPortControls];
            return;
        }
    }
    // open the serial port
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *error = [self openSerialPort:selectedPath baud:kRHAPI_BAUDRATE serialFileDescriptor:&serialFileDescriptor_base contextInt:kBaseSerialContext];
        
        if(error!=nil) {
            [self refreshSerialList_base:error];
            [self appendToIncomingText_base:error];
        } else {
            [self refreshSerialList_base:selectedPath];
            [self performSelectorInBackground:@selector(incomingTextUpdateThread_base:) withObject:[NSThread currentThread]];
        }
    });
}

- (void) serialPortSelected_maestro
{
}

// action from refresh button
- (IBAction) refreshAction: (id) cntrl {
    [self refreshSerialList_base:@"Select a Serial Port"];
    [self refreshSerialList_maestro:@"Select a Serial Port"];
    // close serial port if open
    if (serialFileDescriptor_base != -1) {
        close(serialFileDescriptor_base);
        serialFileDescriptor_base = -1;
    }

    [self refreshSerialList_base:@"Detecting Base firmware\u2026"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self connectToDetectedBase];
    });
    
}

// action from send button and on return in the text field
- (void) sendText:(id)cntrl serialInputField:(NSTextField *)serialInputField serialFileDescriptor:(int)serialFileDescriptor{
    // send the text to the Arduino
    
    [self writeString:[serialInputField stringValue] serialFileDescriptor:serialFileDescriptor];
    
    // blank the field
    serialInputField.stringValue = @"";
}

- (float) animateLeftToTargetSpeed:(float)newTargetSpeed //0-100
{
    float targetSpeed_x5 = newTargetSpeed * 10;
    //animate the target value gently to the other value with steady fixed increments per animation point
    if (self.actualSpeedL < targetSpeed_x5)
        self.actualSpeedL += 1;
    
    if (self.actualSpeedL > targetSpeed_x5)
        self.actualSpeedL -= 1;
    
    //Testing to see what happens here!!!
    self.actualSpeedL = targetSpeed_x5;
    
    return self.actualSpeedL/10;
}

- (float) animateRightToTargetSpeed:(float)newTargetSpeed //0-100
{
    float targetSpeed_x5 = newTargetSpeed * 10;
    //animate the target value gently to the other value with steady fixed increments per animation point
    if (self.actualSpeedR < targetSpeed_x5)
        self.actualSpeedR += 1;
    
    if (self.actualSpeedR > targetSpeed_x5)
        self.actualSpeedR -= 1;
    //Testing to see what happens here!!!
    self.actualSpeedR = targetSpeed_x5;
    
    return self.actualSpeedR/10;
}


- (IBAction)controllerPassthrough:(CGPoint)touchPadPointL
                   touchPadPointR:(CGPoint)touchPadPointR
                              Lat:(float)Lat
                             Long:(float)Long
                    tredBrakeLock:(bool)tredBrakeLock
             flipperForwardIsDown:(bool)flipperForwardIsDown
                flipperRelaxBrake:(bool)flipperRelaxBrake
            flipperBackwardIsDown:(bool)flipperBackwardIsDown
                 flipperBrakeLock:(bool)flipperBrakeLock
                            lact1:(bool)lact1
                            lact2:(bool)lact2
                            lact3:(bool)lact3
                            speed:(float)speed
                  speed_playPause:(bool)speed_playPause
            speed_forward_reverse:(bool)speed_forward_reverse
                        textInput:(NSString *)textInput
{
    //0 - 320 limit on touchPadPoint
    //Do we need independent brakes for each tred? or if its on only animate the tred that is asking for commands...
    //Can we make a tred lock pulse pattern to allow the robot to travel slowly downhill
    //Can we do this once we get interrupts working and tested for the speed controllers?!?!? lots of resoldering required
    int tredBrakeLockL = tredBrakeLock;
    int tredBrakeLockR = tredBrakeLock;
    
    float speedMagnitudeL = 0;
    float speedMagnitudeR = 0;
    NSString *motorDirection_forwardBackward_M1L = @"+";
    NSString *motorDirection_forwardBackward_M2R = @"+";
    NSString *actual_tred_speed_M1L = @"0000";
    NSString *actual_tred_speed_M2R = @"0000";
    
    int actual_speed_M1L = 0;
    int actual_speed_M2R = 0;
    
    ///------- DUPLICATED BLOCK IN ROBSerialBox.m ---------
    
    NSString *deltaText = [textInput stringByReplacingOccurrencesOfString:self.currentIncommingVerbalMessage withString:@""];
    
    if (![self.currentIncommingVerbalMessage isEqualToString:textInput] && ![self.tempTextInput isEqualToString:deltaText])
    {
        
        
        if (![self.tempTextInput isEqualToString:deltaText]) {
            //Only invalidate if the text is updated
            [self.verbalInputTimer invalidate];
            self.verbalInputTimer = nil;
            self.tempTextInput = deltaText;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^(){
            if (self.verbalInputTimer) {
                [self.verbalInputTimer invalidate];
                self.verbalInputTimer = nil;
            }
            self.verbalInputTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:false block:^(NSTimer *timer){
                if (deltaText != nil && ![deltaText isEqualToString:@""] && ![deltaText isEqualToString:@"(null)"])
                {
                    NSLog(@"heSaid: %@", deltaText);
                    [self.delegate resetSpeechResponseAttentionTimer];
                    [self.delegate inputText:deltaText];
                    [self.delegate clearInputTextMessage];
                    self.currentIncommingVerbalMessage = textInput;
                }
            }];
        });
        
    }
    //-----------------------------------------------------
    
    
    if (touchPadPointL.x > -999 && touchPadPointL.y > -999)
    {
        speedMagnitudeL = sqrt(touchPadPointL.x * touchPadPointL.x + touchPadPointL.y * touchPadPointL.y);
        float angleL = atan(touchPadPointL.y/touchPadPointL.x);
        float actualSpeedL = [self animateLeftToTargetSpeed:speed];
        
        //Set MotorDirection
        motorDirection_forwardBackward_M1L = (touchPadPointL.y > 0 ) ? @"+" : @"-";
        
        //Magnitude is between -0.5 and 0.5 so If we want 255 we have to multiply 0.5 * 2 for speed value
        actual_speed_M1L = (kMaxMovementSpeed*speedMagnitudeL*2)*actualSpeedL/100;
        actual_speed_M1L = (actual_speed_M1L > 255) ? 255 : actual_speed_M1L;
        
        actual_tred_speed_M1L = [NSString stringWithFormat:@"%04d", actual_speed_M1L];
        
        tredBrakeLockL = false;
        //  Animate target_speed to the actual_speed values 0-255
        
        //replace255 with touchPadPointMagnitude --- speed is from 0-100
    }
    
    //Right Tred Code
    
    if (touchPadPointR.x > -999 && touchPadPointR.y > -999)
    {
        speedMagnitudeR = sqrt(touchPadPointR.x * touchPadPointR.x + touchPadPointR.y * touchPadPointR.y);
        
        float angleR = atan(touchPadPointR.y/touchPadPointR.x);
        float actualSpeedR = [self animateRightToTargetSpeed:speed];
        
        //Set MotorDirection
        motorDirection_forwardBackward_M2R = (touchPadPointR.y > 0 ) ? @"+" : @"-";
        
        //Magnitude is between -0.5 and 0.5 so If we want 255 we have to multiply 0.5 * 2 for speed value
        actual_speed_M2R = (kMaxMovementSpeed*speedMagnitudeR*2)*actualSpeedR/100;
        actual_speed_M2R = (actual_speed_M2R > 255) ? 255 : actual_speed_M2R;
        actual_tred_speed_M2R = [NSString stringWithFormat:@"%04d", actual_speed_M2R];
        
        tredBrakeLockR = false;
        //  Animate target_speed to the actual_speed values 0-255
        
        //replace255 with touchPadPointMagnitude --- speed is from 0-100
    }
    
    if (speed_playPause)
    {
        int actual_speed_M1L = (kMaxMovementSpeed)*speed/100;
        int actual_speed_M2R = (kMaxMovementSpeed)*speed/100;
        
        actual_tred_speed_M1L = [NSString stringWithFormat:@"%04d", actual_speed_M1L];
        actual_tred_speed_M2R = [NSString stringWithFormat:@"%04d", actual_speed_M2R];
        
        motorDirection_forwardBackward_M1L = (speed_forward_reverse) ? @"+" : @"-";
        motorDirection_forwardBackward_M2R = (speed_forward_reverse) ? @"+" : @"-";
        
        tredBrakeLockL = false;
        tredBrakeLockR = false;
    }
    
    
    int actual_speed_flipper = 0;
    NSString *flipper_direction = (flipperForwardIsDown) ? @"+" : @"-";
    actual_speed_flipper = (flipperForwardIsDown || flipperBackwardIsDown) ? 255 : 0 ;
    NSString *actual_flipper_speed = [NSString stringWithFormat:@"%04d", actual_speed_flipper];
    
    if (actual_speed_flipper > 0 || flipperRelaxBrake)
        flipperBrakeLock = false;
    
    NSString *lactDirection = (lact1) ? @"-" : @"+";
    NSString *lactSpeed = (lact1 || lact3) ? @"3200" : @"0000";
    
    
    NSString *base_command = [NSString stringWithFormat:@"~+000%i,%@%@,+000%i,%@%@,+000%i,%@%@,%@%@", (int)tredBrakeLockL,
                              motorDirection_forwardBackward_M1L, actual_tred_speed_M1L, (int)tredBrakeLockR, motorDirection_forwardBackward_M2R,
                              actual_tred_speed_M2R, (int)flipperBrakeLock, flipper_direction, actual_flipper_speed, lactDirection, lactSpeed];
    
    [self writeString:base_command serialFileDescriptor:serialFileDescriptor_base];
}


- (void) torso_controllerPassthrough_head_pan:(NSString *)head_pan
                                    head_tilt:(NSString *)head_tilt
                           head_upperNeckTilt:(NSString *)head_upperNeckTilt
                           arm_R_shoulder_pan:(NSString *)arm_R_shoulder_pan
                          arm_R_shoulder_tilt:(NSString *)arm_R_shoulder_tilt
                              arm_R_elbow_pan:(NSString *)arm_R_elbow_pan
                             arm_R_elbow_tilt:(NSString *)arm_R_elbow_tilt
                              arm_R_wrist_pan:(NSString *)arm_R_wrist_pan
                             arm_R_wrist_tilt:(NSString *)arm_R_wrist_tilt
                                arm_R_gripper:(NSString *)arm_R_gripper
                           arm_L_shoulder_pan:(NSString *)arm_L_shoulder_pan
                          arm_L_shoulder_tilt:(NSString *)arm_L_shoulder_tilt
                              arm_L_elbow_pan:(NSString *)arm_L_elbow_pan
                             arm_L_elbow_tilt:(NSString *)arm_L_elbow_tilt
                              arm_L_wrist_pan:(NSString *)arm_L_wrist_pan
                             arm_L_wrist_tilt:(NSString *)arm_L_wrist_tilt
                                arm_L_gripper:(NSString *)arm_L_gripper
                            operatorInitiated:(BOOL)operatorInitiated
                   lowerTiltOperatorInitiated:(BOOL)lowerTiltOperatorInitiated

{
    //---
    //7790 max for upperNeckTilt, 4300 min for uppperNeckTilt
    //7675 max for headTilt, 4375 max for the headTilt

    if (!self.maestroConnectionValid) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (operatorInitiated) {
        self.manualNeckOverrideUntil = now + kROBNeckManualOverrideSeconds;
        self.gestureNeckAuthorityUntil = 0;
        self.torsoNeckAuthorityRequiresOperatorAction = NO;
    }
    BOOL gestureOwnsNeck = !operatorInitiated
        && now >= self.manualNeckOverrideUntil
        && now < self.gestureNeckAuthorityUntil;
    BOOL visionOwnsNeck = !operatorInitiated
        && !gestureOwnsNeck
        && now >= self.manualNeckOverrideUntil
        && now < self.visionNeckAuthorityUntil;
    BOOL torsoMayResumeNeck = operatorInitiated
        || !self.torsoNeckAuthorityRequiresOperatorAction;
    if (!gestureOwnsNeck && !visionOwnsNeck && torsoMayResumeNeck) {
        NSString *source = (operatorInitiated || now < self.manualNeckOverrideUntil)
            ? @"Torso manual"
            : @"Torso tracking";
        [self applySafeNeckPanTarget:[head_pan intValue]
                    lowerTiltTarget:[head_tilt intValue]
                  desiredUpperTarget:[head_upperNeckTilt intValue]
                        includeLower:YES
       allowSupervisedLowerRecovery:lowerTiltOperatorInitiated
                              source:source];
    }

    [self sendMaestroTarget:[arm_L_elbow_pan intValue] channel:4];
    [self sendMaestroTarget:[arm_R_elbow_pan intValue] channel:5];

    [self sendMaestroTarget:[arm_R_shoulder_pan intValue] channel:6];
    [self sendMaestroTarget:[arm_R_shoulder_tilt intValue] channel:7];
    [self sendMaestroTarget:[arm_R_elbow_tilt intValue] channel:8];
    [self sendMaestroTarget:[arm_R_wrist_pan intValue] channel:9];
    [self sendMaestroTarget:[arm_R_wrist_tilt intValue] channel:10];
    [self sendMaestroTarget:[arm_R_gripper intValue] channel:11];
    [self sendMaestroTarget:[arm_L_shoulder_pan intValue] channel:12];
    [self sendMaestroTarget:[arm_L_shoulder_tilt intValue] channel:13];
    [self sendMaestroTarget:[arm_L_elbow_tilt intValue] channel:14];
    [self sendMaestroTarget:[arm_L_wrist_pan intValue] channel:15];
    [self sendMaestroTarget:[arm_L_wrist_tilt intValue] channel:16];
    [self sendMaestroTarget:[arm_L_gripper intValue] channel:17];
    
}

- (void)applyVisionNeckPan:(float)pan tilt:(float)tilt
{
    if (!isfinite(pan)
        || !isfinite(tilt)
        || !self.maestroConnectionValid
        || !self.neckSafetyCalibrationConfirmed
        || !self.neckCommandStateKnown
        || self.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff) {
        return;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < self.manualNeckOverrideUntil
        || now < self.gestureNeckAuthorityUntil) {
        return;
    }
    BOOL acquiringVisionAuthority = now >= self.visionNeckAuthorityUntil;
    if (acquiringVisionAuthority) {
        ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
        self.lastVisionNeckPanTarget = self.commandedNeckPanTarget != ROBNeckSafetyTargetOff
            ? (int)self.commandedNeckPanTarget
            : configuration.panCenterTarget;
        if (self.lastDesiredUpperNeckTargetIsKnown) {
            self.lastVisionNeckTiltTarget = self.lastDesiredUpperNeckTarget;
        } else if (self.commandedUpperNeckTiltTarget != ROBNeckSafetyTargetOff) {
            self.lastVisionNeckTiltTarget = (int)self.commandedUpperNeckTiltTarget;
        } else {
            self.lastVisionNeckTiltTarget = 6045;
        }
    }
    self.visionNeckAuthorityUntil = now + kROBNeckVisionAuthoritySeconds;
    self.torsoNeckAuthorityRequiresOperatorAction = YES;
    // Normalized Vision Pro demands are converted only here, behind Cerebro's
    // fresh-master-controller gate. Channel 0 is neck pan and channel 2 is the
    // upper camera tilt used by the existing face tracker.
    float boundedPan = MAX(-1.0f, MIN(1.0f, pan));
    float boundedTilt = MAX(-1.0f, MIN(1.0f, tilt));
    ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
    int32_t requestedPanTarget = configuration.panCenterTarget;
    double requestedPanDegrees = boundedPan
        * ROBNeckSafetyFullPanDegrees(&configuration);
    if (!ROBNeckSafetyPanDegreesToTarget(
            &configuration,
            requestedPanDegrees,
            &requestedPanTarget
        )) {
        return;
    }
    int requestedPan = requestedPanTarget;
    int requestedTilt = (int)lroundf(6045.0f - boundedTilt * 1745.0f);
    // renderController runs at 10 Hz. Limit each accepted step so a tracking
    // discontinuity or rapid head turn cannot command a full-range servo jump.
    int maximumStep = 80;
    int panDelta = MAX(-maximumStep, MIN(maximumStep, requestedPan - self.lastVisionNeckPanTarget));
    int tiltDelta = MAX(-maximumStep, MIN(maximumStep, requestedTilt - self.lastVisionNeckTiltTarget));
    self.lastVisionNeckPanTarget += panDelta;
    self.lastVisionNeckTiltTarget += tiltDelta;
    [self applySafeNeckPanTarget:self.lastVisionNeckPanTarget
                lowerTiltTarget:ROBNeckSafetyTargetOff
              desiredUpperTarget:self.lastVisionNeckTiltTarget
                    includeLower:NO
   allowSupervisedLowerRecovery:NO
                          source:@"Vision controller"];
    // Keep Vision's slew baseline at the applied safe pan target. If the
    // lower neck later clears the arms, pan expands at the existing 80-target
    // step instead of jumping from the edge of the restricted envelope.
    if (self.commandedNeckPanTarget != ROBNeckSafetyTargetOff) {
        self.lastVisionNeckPanTarget = (int)self.commandedNeckPanTarget;
    }
}

- (BOOL)prepareNeckForPersonFollow
{
    if (![NSThread isMainThread]
        || !self.maestroConnectionValid
        || !self.neckSafetyCalibrationConfirmed
        || !self.neckCommandStateKnown
        || self.commandedNeckPanTarget == ROBNeckSafetyTargetOff
        || self.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff
        || self.commandedUpperNeckTiltTarget == ROBNeckSafetyTargetOff) {
        self.neckCommandSafetyStatus =
            @"Follow tracking pose is waiting for a connected, calibrated, known active neck state.";
        return NO;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < self.manualNeckOverrideUntil || now < self.gestureNeckAuthorityUntil) {
        self.neckCommandSafetyStatus =
            @"Follow tracking pose is waiting for the current manual or gesture neck lease to end.";
        return NO;
    }

    ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
    if (self.commandedLowerNeckTiltTarget >= configuration.lowerFullPanLowTarget
        && self.commandedLowerNeckTiltTarget <= configuration.lowerFullPanHighTarget) {
        return YES;
    }

    // The policy may first recenter pan, then move lower tilt, then settle.
    // Repeated calls are intentional and remain fully mediated by the shared
    // collision gateway. Upper tilt is preserved so "upright" camera pose is
    // not confused with the old, restricted lower-neck crouch value.
    int lowerReference = (int)lround(ROBNeckSafetyReferenceLowerTarget(&configuration));
    int upperTarget = self.lastDesiredUpperNeckTargetIsKnown
        ? self.lastDesiredUpperNeckTarget
        : (int)self.commandedUpperNeckTiltTarget;
    ROBNeckCommandDisposition disposition = [self
        applySafeNeckPanTarget:configuration.panCenterTarget
        lowerTiltTarget:lowerReference
        desiredUpperTarget:upperTarget
        includeLower:YES
        allowSupervisedLowerRecovery:NO
        source:@"Follow tracking pose"];
    if (disposition == ROBNeckCommandDispositionRejected) {
        return NO;
    }
    return self.commandedLowerNeckTiltTarget >= configuration.lowerFullPanLowTarget
        && self.commandedLowerNeckTiltTarget <= configuration.lowerFullPanHighTarget;
}

- (ROBNeckCommandDisposition)requestNeckGesturePanDegrees:(double)panDegrees
                                      lowerTiltRawTarget:(NSInteger)lowerTiltRawTarget
                                     cameraTiltRawTarget:(NSInteger)cameraTiltRawTarget
                                           leaseDuration:(NSTimeInterval)leaseDuration
                                                   source:(NSString *)source
{
    ROBNeckSafetyConfig configuration = [self neckSafetyConfiguration];
    if (![NSThread isMainThread]
        || !self.maestroConnectionValid
        || !self.neckSafetyCalibrationConfirmed
        || !self.neckCommandStateKnown
        || self.commandedNeckPanTarget == ROBNeckSafetyTargetOff
        || self.commandedLowerNeckTiltTarget == ROBNeckSafetyTargetOff
        || self.commandedUpperNeckTiltTarget == ROBNeckSafetyTargetOff
        || !isfinite(panDegrees)
        || !isfinite(leaseDuration)
        || leaseDuration < 0.1
        || leaseDuration > 2.0
        || source.length == 0
        || lowerTiltRawTarget < configuration.lowerMinimumTarget
        || lowerTiltRawTarget > configuration.lowerMaximumTarget
        || cameraTiltRawTarget < configuration.upperMinimumTarget
        || cameraTiltRawTarget > configuration.upperMaximumTarget) {
        self.neckCommandSafetyStatus =
            @"Gesture request rejected: connection, calibration, thread, target, or lease is invalid.";
        return ROBNeckCommandDispositionRejected;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < self.manualNeckOverrideUntil) {
        self.neckCommandSafetyStatus = @"Gesture request rejected: manual neck control owns the lease.";
        return ROBNeckCommandDispositionRejected;
    }

    int32_t panTarget = ROBNeckSafetyTargetOff;
    if (!ROBNeckSafetyPanDegreesToTarget(&configuration, panDegrees, &panTarget)) {
        self.neckCommandSafetyStatus = @"Gesture request rejected: pan angle is outside calibration.";
        return ROBNeckCommandDispositionRejected;
    }

    self.visionNeckAuthorityUntil = 0;
    self.gestureNeckAuthorityUntil = now + leaseDuration;
    self.torsoNeckAuthorityRequiresOperatorAction = YES;
    NSString *commandSource = [@"Gesture: " stringByAppendingString:source];
    ROBNeckCommandDisposition disposition = [self
        applySafeNeckPanTarget:panTarget
        lowerTiltTarget:(int)lowerTiltRawTarget
        desiredUpperTarget:(int)cameraTiltRawTarget
        includeLower:YES
        allowSupervisedLowerRecovery:NO
        source:commandSource];
    if (disposition == ROBNeckCommandDispositionRejected) {
        self.gestureNeckAuthorityUntil = 0;
    }
    return disposition;
}

- (void)cancelNeckGestureAuthority
{
    self.gestureNeckAuthorityUntil = 0;
    self.torsoNeckAuthorityRequiresOperatorAction = YES;
    self.neckCommandSafetyStatus =
        @"Gesture authority released; holding the last commanded targets.";
}

- (void)applyVisionGrippersActive:(BOOL)active leftClosed:(BOOL)leftClosed rightClosed:(BOOL)rightClosed
{
    if (!active) {
        // Preserve the legacy controller-view edge semantics. This compatibility
        // route is render-only and never owns or commands a physical gripper.
        self.visionGripperStateIsKnown = NO;
        return;
    }
    BOOL updateLeft = !self.visionGripperStateIsKnown
        || leftClosed != self.lastVisionLeftGripperClosed;
    BOOL updateRight = !self.visionGripperStateIsKnown
        || rightClosed != self.lastVisionRightGripperClosed;
    self.visionGripperStateIsKnown = YES;
    self.lastVisionLeftGripperClosed = leftClosed;
    self.lastVisionRightGripperClosed = rightClosed;

    // Legacy snapshots remain available to the renderer for visual
    // compatibility only. Physical gripper control is exclusively owned by
    // the typed rob-gripper-control/1 path, which enforces its session,
    // sequence, lease, and dead-man requirements before reaching the gateway.
    if (updateLeft || updateRight) {
        NSLog(@"Legacy Vision gripper compatibility state updated (left=%@, right=%@); no actuator command was sent.",
              leftClosed ? @"closed" : @"open",
              rightClosed ? @"closed" : @"open");
    }
}

- (void)applyVisionTorsoActive:(BOOL)active rotation:(float)rotation
{
    if (!active || !isfinite(rotation)) {
        if (self.visionTorsoControlWasActive) {
            self.visionTorsoControlWasActive = NO;
            exitSafeStart_waistRotation = false;
            energize_waistRotation = false;
            [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOff];
            [self.energizeWaistRotationButton setState:NSControlStateValueOff];
            [self runTiccmdArguments:@[@"--enter-safe-start", @"--deenergize"]];
        }
        return;
    }

    float boundedRotation = MAX(-1.0f, MIN(1.0f, rotation));
    BOOL justActivated = !self.visionTorsoControlWasActive;
    if (!self.visionTorsoControlWasActive) {
        self.visionTorsoControlWasActive = YES;
        self.visionTorsoBaselinePosition = self.waistRotationSlider != nil
            ? self.waistRotationSlider.intValue
            : self.lastVisionTorsoTarget;
        self.lastVisionTorsoTarget = self.visionTorsoBaselinePosition;
        exitSafeStart_waistRotation = true;
        energize_waistRotation = true;
        [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOn];
        [self.energizeWaistRotationButton setState:NSControlStateValueOn];
    }

    int minimumPosition = self.waistRotationSlider != nil
        ? (int)self.waistRotationSlider.minValue
        : -kROBTicWaistFullTurnPositionUnits;
    int maximumPosition = self.waistRotationSlider != nil
        ? (int)self.waistRotationSlider.maxValue
        : kROBTicWaistFullTurnPositionUnits;
    int requested = self.visionTorsoBaselinePosition
        + (int)lroundf(boundedRotation * kROBTicWaistHeadFollowMaximumUnits);
    requested = MAX(minimumPosition, MIN(maximumPosition, requested));
    // At the 10 Hz controller render rate, this limits target movement to 6000
    // Tic position units per second. The Tic's configured motor limits remain authoritative.
    int maximumStep = 600;
    int delta = MAX(-maximumStep, MIN(maximumStep, requested - self.lastVisionTorsoTarget));
    int target = self.lastVisionTorsoTarget + delta;
    if (!justActivated && target == self.lastVisionTorsoTarget && self.waistRotationSlider.intValue == target) {
        return;
    }
    self.lastVisionTorsoTarget = target;
    [self.waistRotationSlider setIntValue:target];
    [self runTiccmdArguments:@[
        @"--exit-safe-start", @"--energize", @"-p", [NSString stringWithFormat:@"%d", target]
    ]];
}

- (IBAction)forward:(id)sender
{
    [self writeString:@"~+0000,+0100,+0000,+0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)backward:(id)sender
{
    [self writeString:@"~+0000,-0100,+0000,-0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)left:(id)sender
{
    [self writeString:@"~+0000,-0100,+0000,+0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)right:(id)sender
{
    [self writeString:@"~+0000,+0100,+0000,-0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}


- (IBAction)flipperForwardPush:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,+0255,+0000" serialFileDescriptor:serialFileDescriptor_base];
}


- (IBAction)flipperBackwardPush:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,-0255,+0000" serialFileDescriptor:serialFileDescriptor_base];
}


- (IBAction)leanforward:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,+0000,+3200" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)leanback:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,+0000,-3200" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)speedSliderAction:(id)sender
{
    //we need to control a local speed value that is going to compete with the controller. who overrides who?
}

- (void)runTiccmdArguments:(NSArray<NSString *> *)arguments
{
    NSString *configuredPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"ROBTiccmdExecutablePath"];
    NSString *selection = configuredPath.length > 0
        ? configuredPath
        : @"/Applications/Pololu Tic Stepper Motor Controller.app/Contents/MacOS/ticcmd";
    NSString *ticcmdPath = [[selection stringByExpandingTildeInPath] stringByStandardizingPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:ticcmdPath]) {
        NSLog(@"Pololu ticcmd is unavailable at %@. Install the Pololu Tic software or set ROBTiccmdExecutablePath.", ticcmdPath);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *ticcmd = [[NSTask alloc] init];
        ticcmd.executableURL = [NSURL fileURLWithPath:ticcmdPath];
        ticcmd.arguments = arguments;
        NSPipe *pipe = [NSPipe pipe];
        ticcmd.standardOutput = pipe;
        ticcmd.standardError = pipe;

        NSError *launchError = nil;
        if (!ROBLaunchTaskSafely(ticcmd, &launchError)) {
            NSLog(@"Pololu ticcmd could not start: %@", launchError.localizedDescription);
            return;
        }
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        // EOF only guarantees that ticcmd closed its output descriptors. The
        // process can still be running briefly, and terminationStatus raises
        // NSInvalidArgumentException until NSTask has observed its exit.
        // Drain first to avoid a full-pipe deadlock, then establish the
        // termination barrier before inspecting process status.
        [ticcmd waitUntilExit];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        int terminationStatus = ticcmd.terminationStatus;
        if (terminationStatus != 0 || output.length > 0) {
            NSLog(@"Pololu ticcmd exited with status %d: %@", terminationStatus, output);
        }
    });
}

- (IBAction)waistRotationResetAction:(id)sender
{
    [self runTiccmdArguments:@[@"--reset"]];
}

- (IBAction)waistRotationSliderAction:(NSSlider *)sender
{
    NSLog(@"waistRotationSlider = %i", [sender intValue]);
    NSString *waistRotationValue = [NSString stringWithFormat:@"%i", [sender intValue]];
    NSMutableArray *arguments = @[].mutableCopy;
    if (exitSafeStart_waistRotation) {
        [arguments addObject:@"--exit-safe-start"];
    } else {
        [arguments addObject:@"--enter-safe-start"];
    }
    
    if (energize_waistRotation) {
        [arguments addObject:@"--energize"];
    } else {
        [arguments addObject:@"--deenergize"];
    }
    
    [arguments addObject:@"-p"];
    [arguments addObject:waistRotationValue];
    
    [self runTiccmdArguments:arguments];
}

- (IBAction)exitSafeStartWaistRotationToggle:(id)sender
{
    exitSafeStart_waistRotation = !exitSafeStart_waistRotation;
    if (exitSafeStart_waistRotation) {
        [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOn];
    } else {
        [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOff];
    }
}

- (IBAction)energizeToggle:(id)sender
{
    energize_waistRotation = !energize_waistRotation;
    if (energize_waistRotation) {
        [self.energizeWaistRotationButton setState:NSControlStateValueOn];
    } else {
        [self.energizeWaistRotationButton setState:NSControlStateValueOff];
    }
}

- (void)performSSHpassOperation:(NSString *)operation block:(dispatch_block_t)block
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    if (manager.sshpassPath.length == 0) {
        NSString *managerName = ROBSystemPackageManagerDisplayName(manager.preferredPackageManager);
        NSError *error = [NSError errorWithDomain:ROBSystemDependencyErrorDomain
                                             code:ROBSystemDependencyErrorToolUnavailable
                                         userInfo:@{
            NSLocalizedDescriptionKey: @"sshpass is not installed.",
            NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:
                @"Open Cerebro Settings and explicitly install sshpass with %@.", managerName]
        }];
        [self reportSSHpassError:error operation:operation];
        return;
    }
    block();
}

- (BOOL)launchSSHpassTask:(NSTask *)task operation:(NSString *)operation
{
    NSError *error = nil;
    if (![[ROBSystemDependencyManager sharedManager] launchSSHpassTask:task
                                                              password:@"a"
                                                                 error:&error]) {
        [self reportSSHpassError:error operation:operation];
        return NO;
    }
    return YES;
}

- (void)reportSSHpassError:(NSError *)error operation:(NSString *)operation
{
    NSString *suggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey];
    NSString *message = suggestion.length > 0
        ? [NSString stringWithFormat:@"%@ unavailable: %@ %@\n",
            operation,
            error.localizedDescription ?: @"unknown SSH error",
            suggestion]
        : [NSString stringWithFormat:@"%@ unavailable: %@\n",
            operation,
            error.localizedDescription ?: @"unknown SSH error"];
    NSLog(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.amberMasterCoreOutput_R11 != nil) {
            self.amberMasterCoreOutput_R11.string =
                [self.amberMasterCoreOutput_R11.string stringByAppendingString:message];
            [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
        }
        if (self.amberMasterCoreOutput_L10 != nil) {
            self.amberMasterCoreOutput_L10.string =
                [self.amberMasterCoreOutput_L10.string stringByAppendingString:message];
            [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
        }
    });
}

#pragma mark - R11 actions

- (IBAction) sshIntoAmberMasterAndRunTail_R11:(id)sender {
    if (self.sshTask_R11_log.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"R11 log connection" block:^{
        [self startSSHIntoAmberMasterAndRunTail_R11];
    }];
}

- (void)startSSHIntoAmberMasterAndRunTail_R11
{
    if (self.sshTask_R11_log.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_R11_log = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"tail", @"-n", @"+1", @"-f", @"/home/amber/R-11/core.log"
        ]
        error:&taskError];
    if (self.sshTask_R11_log == nil) {
        [self reportSSHpassError:taskError operation:@"R11 log connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_R11_log.standardOutput = pipe;
    self.sshTask_R11_log.standardError = pipe;
    
    self.receivedData_R11_log = [NSMutableData new];
    
    NSFileHandle *readFileHandle_R11 = [pipe fileHandleForReading];
    readFileHandle_R11.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_R11_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_R11_log encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });

        } else {
            // Append the new data to our storage.
            self.core_R11_isOnline = true;
            [self.receivedData_R11_log appendData:data];
            
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_R11_log operation:@"R11 log connection"]) {
        readFileHandle_R11.readabilityHandler = nil;
        self.sshTask_R11_log = nil;
    }
}

- (IBAction) sshIntoAmberMasterAndRunCore_R11:(id)sender {
    if (self.sshTask_R11_Core.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"R11 core connection" block:^{
        [self startSSHIntoAmberMasterAndRunCore_R11];
    }];
}

- (void)startSSHIntoAmberMasterAndRunCore_R11
{
    if (self.sshTask_R11_Core.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_R11_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"cd", @"/home/amber/R-11/;", @"./amber_core_R"
        ]
        error:&taskError];
    if (self.sshTask_R11_Core == nil) {
        [self reportSSHpassError:taskError operation:@"R11 core connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_R11_Core.standardOutput = pipe;
    self.sshTask_R11_Core.standardError = pipe;
    
    self.receivedData_R11_Core = [NSMutableData new];
    
    NSFileHandle *readFileHandle_R11 = [pipe fileHandleForReading];
    readFileHandle_R11.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_R11_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_R11_Core encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });
        } else {
            self.core_R11_isOnline = true;
            // Append the new data to our storage.
            [self.receivedData_R11_Core appendData:data];
            
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_R11_Core operation:@"R11 core connection"]) {
        readFileHandle_R11.readabilityHandler = nil;
        self.sshTask_R11_Core = nil;
    }
}

- (IBAction) shutdown_R11_core:(id)sender {
    if (self.sshTask_R11_Core.isRunning) {
        [self.sshTask_R11_Core terminate];
    }
    self.sshTask_R11_Core = nil;
    [self performSSHpassOperation:@"R11 core shutdown" block:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self startShutdown_R11_core];
        });
    }];
}

- (void)startShutdown_R11_core
{
    NSError *taskError = nil;
    NSTask *sshTask_kill_R11_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"echo", @"a", @"|", @"sudo", @"-S", @"killall", @"amber_core_R"
        ]
        error:&taskError];
    if (sshTask_kill_R11_Core == nil) {
        [self reportSSHpassError:taskError operation:@"R11 core shutdown"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    sshTask_kill_R11_Core.standardOutput = pipe;
    sshTask_kill_R11_Core.standardError = pipe;

    if (![self launchSSHpassTask:sshTask_kill_R11_Core operation:@"R11 core shutdown"]) {
        return;
    }
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"sshTask_kill_R11_Core: %@", output);
}

- (IBAction)zeroPosition_R11:(id)sender {
    [self zeroPosition:sender port:26002];
}

- (void)presentSupervisedAmberGripperControls
{
    dispatch_async(dispatch_get_main_queue(), ^{
        ROBAmberDiagnosticsWindowController *controller = [ROBAmberDiagnosticsWindowController shared];
        [controller showWindow:nil];
        [controller.window makeKeyAndOrderFront:nil];
        NSLog(@"Legacy Amber gripper control was redirected to the supervised diagnostics panel.");
    });
}

- (IBAction)calibrateGripper_R11:(id)sender {
    [self presentSupervisedAmberGripperControls];
}

- (IBAction)openGripper_R11:(id)sender {
    [self presentSupervisedAmberGripperControls];
}

- (IBAction)closeGripper_R11:(id)sender {
    [self presentSupervisedAmberGripperControls];
}

- (IBAction) watch_position_out_R11:(id)sender {
    [self watch_position_out:sender port:26002];
}

- (IBAction)set_position_mode_R11:(id)sender {
    [self set_position_mode_v2:sender port: 26002];
}

- (IBAction)set_current_mode_R11:(id)sender {
    [self set_current_mode_v2:sender port: 26002];
}

- (IBAction)update_arm_R11_cartesian_Action:(id)sender {
    double cmdTime = [self.arm_R11_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_R11_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_R11_positionX doubleValue]/100.0;
    double posY = [self.arm_R11_positionY doubleValue]/100.0;
    double posZ = [self.arm_R11_positionZ doubleValue]/100.0;
    double roll = [self.arm_R11_roll doubleValue]/100.0;
    double pitch = [self.arm_R11_pitch doubleValue]/100.0;
    double yaw = [self.arm_R11_yaw doubleValue]/100.0;
    
    [self update_arm_cartesian_v1:sender
                             port:26002
                          cmdTime:cmdTime
                         cmdSleep:cmdSleep
                             posX:posX
                             posY:posY
                             posZ:posZ
                             roll:roll
                            pitch:pitch
                              yaw:yaw];
}

- (IBAction)update_arm_R11_position_Action:(id)sender {
    double cmdTime = [self.arm_R11_position_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_R11_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_R11_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_R11_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_R11_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_R11_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_R11_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_R11_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_R11_position_servo7 doubleValue]/100.0;
    
    [self update_arm_position_v1:sender
                            port:26002
                         cmdTime:cmdTime
                        cmdSleep:cmdSleep
                          servo1:servo1
                          servo2:servo2
                          servo3:servo3
                          servo4:servo4
                          servo5:servo5
                          servo6:servo6
                          servo7:servo7];
}

- (IBAction)activate_R11:(id)sender {
    [self activate:(id)sender port: 26002];
}

- (IBAction)deactivate_R11:(id)sender {
    [self deactivate:(id)sender port: 26002];
}

#pragma mark - L10 actions

- (IBAction) sshIntoAmberMasterAndRunTail_L10:(id)sender {
    if (self.sshTask_L10_log.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"L10 log connection" block:^{
        [self startSSHIntoAmberMasterAndRunTail_L10];
    }];
}

- (void)startSSHIntoAmberMasterAndRunTail_L10
{
    if (self.sshTask_L10_log.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_L10_log = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"tail", @"-n", @"+1", @"-f", @"/home/amber/L-10/core.log"
        ]
        error:&taskError];
    if (self.sshTask_L10_log == nil) {
        [self reportSSHpassError:taskError operation:@"L10 log connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_L10_log.standardOutput = pipe;
    self.sshTask_L10_log.standardError = pipe;
    
    self.receivedData_L10_log = [NSMutableData new];
    
    NSFileHandle *readFileHandle_L10 = [pipe fileHandleForReading];
    readFileHandle_L10.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_L10_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_L10_log encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });

        } else {
            // Append the new data to our storage.
            self.core_L10_isOnline = true;
            [self.receivedData_L10_log appendData:data];
            
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_L10_log operation:@"L10 log connection"]) {
        readFileHandle_L10.readabilityHandler = nil;
        self.sshTask_L10_log = nil;
    }
}

- (IBAction) sshIntoAmberMasterAndRunCore_L10:(id)sender {
    if (self.sshTask_L10_Core.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"L10 core connection" block:^{
        [self startSSHIntoAmberMasterAndRunCore_L10];
    }];
}

- (void)startSSHIntoAmberMasterAndRunCore_L10
{
    if (self.sshTask_L10_Core.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_L10_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"cd", @"/home/amber/L-10/;", @"./amber_core_L"
        ]
        error:&taskError];
    if (self.sshTask_L10_Core == nil) {
        [self reportSSHpassError:taskError operation:@"L10 core connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_L10_Core.standardOutput = pipe;
    self.sshTask_L10_Core.standardError = pipe;
    
    self.receivedData_L10_Core = [NSMutableData new];
    
    NSFileHandle *readFileHandle_L10 = [pipe fileHandleForReading];
    readFileHandle_L10.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_L10_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_L10_Core encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });

        } else {
            // Append the new data to our storage.
            self.core_L10_isOnline = true;
            [self.receivedData_L10_Core appendData:data];
            
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_L10_Core operation:@"L10 core connection"]) {
        readFileHandle_L10.readabilityHandler = nil;
        self.sshTask_L10_Core = nil;
    }
}

- (IBAction) shutdown_L10_core:(id)sender {
    if (self.sshTask_L10_Core.isRunning) {
        [self.sshTask_L10_Core terminate];
    }
    self.sshTask_L10_Core = nil;
    [self performSSHpassOperation:@"L10 core shutdown" block:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self startShutdown_L10_core];
        });
    }];
}

- (void)startShutdown_L10_core
{
    NSError *taskError = nil;
    NSTask *sshTask_kill_L10_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"echo", @"a", @"|", @"sudo", @"-S", @"killall", @"amber_core_L"
        ]
        error:&taskError];
    if (sshTask_kill_L10_Core == nil) {
        [self reportSSHpassError:taskError operation:@"L10 core shutdown"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    sshTask_kill_L10_Core.standardOutput = pipe;
    sshTask_kill_L10_Core.standardError = pipe;

    if (![self launchSSHpassTask:sshTask_kill_L10_Core operation:@"L10 core shutdown"]) {
        return;
    }
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"sshTask_kill_L10_Core: %@", output);
}

- (IBAction)zeroPosition_L10:(id)sender {
    [self zeroPosition:sender port:26001];
}

- (IBAction)calibrateGripper_L10:(id)sender {
    [self presentSupervisedAmberGripperControls];
}

- (IBAction)openGripper_L10:(id)sender {
    [self presentSupervisedAmberGripperControls];
}

- (IBAction)closeGripper_L10:(id)sender {
    [self presentSupervisedAmberGripperControls];
}

- (IBAction) watch_position_out_L10:(id)sender {
    [self watch_position_out:sender port:26001];
}

- (IBAction)set_position_mode_L10:(id)sender {
    [self set_position_mode_v2:sender port: 26001];
}

- (IBAction)set_current_mode_L10:(id)sender {
    [self set_current_mode_v2:sender port: 26001];
}

- (IBAction)update_arm_L10_cartesian_Action:(id)sender {
    double cmdTime = [self.arm_L10_cartesian_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_L10_cartesian_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_L10_cartesian_positionX doubleValue]/100.0;
    double posY = [self.arm_L10_cartesian_positionY doubleValue]/100.0;
    double posZ = [self.arm_L10_cartesian_positionZ doubleValue]/100.0;
    double roll = [self.arm_L10_cartesian_roll doubleValue]/100.0;
    double pitch = [self.arm_L10_cartesian_pitch doubleValue]/100.0;
    double yaw = [self.arm_L10_cartesian_yaw doubleValue]/100.0;
    
    [self update_arm_cartesian_v1:sender
                             port:26001
                          cmdTime:cmdTime
                         cmdSleep:cmdSleep
                             posX:posX
                             posY:posY
                             posZ:posZ
                             roll:roll
                            pitch:pitch
                              yaw:yaw];
}

- (IBAction)update_arm_L10_position_Action:(id)sender {
    double cmdTime = [self.arm_L10_position_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_L10_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_L10_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_L10_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_L10_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_L10_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_L10_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_L10_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_L10_position_servo7 doubleValue]/100.0;
    
    [self update_arm_position_v1:sender
                            port:26001
                         cmdTime:cmdTime
                        cmdSleep:cmdSleep
                          servo1:servo1
                          servo2:servo2
                          servo3:servo3
                          servo4:servo4
                          servo5:servo5
                          servo6:servo6
                          servo7:servo7];
}

- (IBAction)activate_L10:(id)sender {
    [self activate:(id)sender port: 26001];
}

- (IBAction)deactivate_L10:(id)sender {
    [self deactivate:(id)sender port: 26001];
}

#pragma mark -

- (void)runPythonArguments:(NSArray<NSString *> *)arguments operation:(NSString *)operation
{
    NSError *error = nil;
    NSString *output = [[ROBPythonRuntime sharedRuntime] runPythonWithArguments:arguments error:&error];
    if (error != nil) {
        NSLog(@"%@: %@", operation, error.localizedDescription);
        return;
    }
    NSLog(@"%@: %@", operation, output ?: @"");
}

- (void) watch_position_out:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *watch_position_out = [[NSBundle mainBundle] pathForResource:@"watch_position_out" ofType:@"py"];
        //cmd_deactivate_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:watch_position_out];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"watch_position_out"];
    });
}

- (void) deactivate:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_deactivate_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_deactivate_mode_v2" ofType:@"py"];
        //cmd_deactivate_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_deactivate_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_deactivate_mode_v2"];
    });
}


- (void) activate:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_activate_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_activate_mode_v2" ofType:@"py"];
        //cmd_activate_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_activate_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_activate_mode_v2"];
    });
}

- (void) zeroPosition:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *zero_position_mode_v2 = [[NSBundle mainBundle] pathForResource:@"zero_position_mode_v2" ofType:@"py"];
        //zero_position_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:zero_position_mode_v2];
        
        [arguments addObject:@"--cmd_time"];
        [arguments addObject:[NSString stringWithFormat:@"%f", 2.0]];
        
        [arguments addObject:@"--cmd_sleep"];
        [arguments addObject:[NSString stringWithFormat:@"%f", 0.0]];

        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"zero_position_mode_v2"];
    });
}

- (void)set_position_mode_v2:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_position_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_position_mode_v2" ofType:@"py"];
        //cmd_position_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_position_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_position_mode_v2"];
    });
}

- (void)set_current_mode_v2:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_current_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_current_mode_v2" ofType:@"py"];
        //cmd_current_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_current_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_current_mode_v2"];
    });
    
}

- (void) update_arm_position_v1:(id)sender port:(int)port cmdTime:(double)cmdTime cmdSleep:(double)cmdSleep servo1:(double)servo1  servo2:(double)servo2 servo3:(double)servo3 servo4:(double)servo4 servo5:(double)servo5 servo6:(double)servo6 servo7:(double)servo7 {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSLog(@"arm_R11_servo1 = %f", servo1);
        NSLog(@"arm_R11_servo2 = %f", servo2);
        NSLog(@"arm_R11_servo3 = %f", servo3);
        NSLog(@"arm_R11_servo4 = %f", servo4);
        NSLog(@"arm_R11_servo5 = %f", servo5);
        NSLog(@"arm_R11_servo6 = %f", servo6);
        NSLog(@"arm_R11_servo7 = %f", servo7);
        
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_position_input = [[NSBundle mainBundle] pathForResource:@"cmd_position_input_v2" ofType:@"py"];
        //cmd_cartesian_input.py --ip 10.0.0.5 --port 26002 --cmd_time 2 --cmd_sleep 2 --pos_x 0.1 --pos_y -0.33 --pos_z 0.2 --roll 0.0 --pitch -1.5 --yaw 0.5
        
        [arguments addObject:cmd_position_input];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        [arguments addObject:@"--cmd_time"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdTime]];
        
        [arguments addObject:@"--cmd_sleep"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdSleep]];
        
        [arguments addObject:@"--servo1"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo1]];
        
        [arguments addObject:@"--servo2"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo2]];
        
        [arguments addObject:@"--servo3"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo3]];
        
        [arguments addObject:@"--servo4"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo4]];
        
        [arguments addObject:@"--servo5"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo5]];
        
        [arguments addObject:@"--servo6"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo6]];
        
        [arguments addObject:@"--servo7"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo7]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_position_input"];
    });
}

- (void) update_arm_cartesian_v1:(id)sender port:(int)port cmdTime:(double)cmdTime cmdSleep:(double)cmdSleep posX:(double)posX posY:(double)posY posZ:(double)posZ roll:(double)roll pitch:(double)pitch yaw:(double)yaw {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSLog(@"arm_R11_cmdTime = %f", cmdTime);
        NSLog(@"arm_R11_cmdSleep = %f", cmdSleep);
        NSLog(@"arm_R11_positionX = %f", posX);
        NSLog(@"arm_R11_positionY = %f", posY);
        NSLog(@"arm_R11_positionZ = %f", posZ);
        NSLog(@"arm_R11_roll = %f", roll);
        NSLog(@"arm_R11_pitch = %f", pitch);
        NSLog(@"arm_R11_yaw = %f", yaw);
        
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_cartesian_input = [[NSBundle mainBundle] pathForResource:@"cmd_cartesian_input" ofType:@"py"];
        //cmd_cartesian_input.py --ip 10.0.0.5 --port 26002 --cmd_time 2 --cmd_sleep 2 --pos_x 0.1 --pos_y -0.33 --pos_z 0.2 --roll 0.0 --pitch -1.5 --yaw 0.5
        
        [arguments addObject:cmd_cartesian_input];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        [arguments addObject:@"--cmd_time"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdTime]];
        
        [arguments addObject:@"--cmd_sleep"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdSleep]];
        
        [arguments addObject:@"--pos_x"];
        [arguments addObject:[NSString stringWithFormat:@"%f", posX]];
        
        [arguments addObject:@"--pos_y"];
        [arguments addObject:[NSString stringWithFormat:@"%f", posY]];
        
        [arguments addObject:@"--pos_z"];
        [arguments addObject:[NSString stringWithFormat:@"%f", posZ]];
        
        [arguments addObject:@"--roll"];
        [arguments addObject:[NSString stringWithFormat:@"%f", roll]];
        
        [arguments addObject:@"--pitch"];
        [arguments addObject:[NSString stringWithFormat:@"%f", pitch]];
        
        [arguments addObject:@"--yaw"];
        [arguments addObject:[NSString stringWithFormat:@"%f", yaw]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_cartesian_input"];
    });
}

- (BOOL)commandRightAmberSaberX:(double)x y:(double)y z:(double)z
                           roll:(double)roll pitch:(double)pitch yaw:(double)yaw
                       duration:(NSTimeInterval)duration
{
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) || !isfinite(roll) ||
        !isfinite(pitch) || !isfinite(yaw) || !isfinite(duration) ||
        x < -0.18 || x > 0.18 || y < -0.38 || y > -0.18 ||
        z < 0.12 || z > 0.38 || fabs(roll) > 1.2 ||
        pitch < -1.8 || pitch > -0.7 || fabs(yaw) > 1.0 ||
        duration < 0.65 || duration > 2.0) {
        NSLog(@"Rejected out-of-bounds supervised saber transform");
        return NO;
    }
    [self update_arm_cartesian_v1:nil port:26002 cmdTime:duration cmdSleep:0
                             posX:x posY:y posZ:z roll:roll pitch:pitch yaw:yaw];
    return YES;
}

#pragma mark -

- (void) sendBaseCommand:(NSString *)command
{
    [self writeString:command serialFileDescriptor:serialFileDescriptor_base];
}


// action from the reset button
- (void) resetButton: (NSButton *) btn{
    // set and clear DTR to reset an arduino
    struct timespec interval = {0,100000000}, remainder;
    if(serialFileDescriptor_base!=-1) {
        ioctl(serialFileDescriptor_base, TIOCSDTR);
        nanosleep(&interval, &remainder); // wait 0.1 seconds
        ioctl(serialFileDescriptor_base, TIOCCDTR);
    }
}




- (void)renderController
{
    [self renderControllerPrioritized:NO];
}

- (void)renderControllerPrioritized:(BOOL)urgent
{
    //render should fire the code [below here:]
    ROBBaseControllerModel *controllerModelData = [self.controlModelDataDictionary valueForKey:self.masterControllerID];
    ROBBaseControllerModel *treadModelData = [self.treadControlModelDataDictionary valueForKey:self.masterControllerID];
    
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!urgent && self.lastControllerRenderUptime > 0
        && now - self.lastControllerRenderUptime < 0.075) {
        return;
    }
    BOOL snapshotIsFresh = controllerModelData != nil &&
        controllerModelData.receivedAtUptime > 0 &&
        now - controllerModelData.receivedAtUptime <= kControllerSnapshotFreshnessSeconds;
    BOOL treadSnapshotIsFresh = treadModelData != nil &&
        treadModelData.receivedAtUptime > 0 &&
        now - treadModelData.receivedAtUptime <= kControllerSnapshotFreshnessSeconds;

    if (snapshotIsFresh || treadSnapshotIsFresh)
    {
        ROBBaseControllerModel *treads = treadSnapshotIsFresh ? treadModelData : controllerModelData;
        //MasterControllerId data should go through
        [self controllerPassthrough:treads.touchPadPointL
                     touchPadPointR:treads.touchPadPointR
                                Lat:snapshotIsFresh ? controllerModelData.Lat : 0
                               Long:snapshotIsFresh ? controllerModelData.Long : 0
                      tredBrakeLock:treads.tredBrakeLock
               flipperForwardIsDown:snapshotIsFresh ? controllerModelData.flipperForwardIsDown : false
                  flipperRelaxBrake:snapshotIsFresh ? controllerModelData.flipperRelaxBrake : false
              flipperBackwardIsDown:snapshotIsFresh ? controllerModelData.flipperBackwardIsDown : false
                   flipperBrakeLock:snapshotIsFresh ? controllerModelData.flipperBrakeLock : true
                              lact1:snapshotIsFresh ? controllerModelData.lact1 : false
                              lact2:snapshotIsFresh ? controllerModelData.lact2 : false
                              lact3:snapshotIsFresh ? controllerModelData.lact3 : false
                              speed:treads.speed
                    speed_playPause:treads.speed_playPause
              speed_forward_reverse:treads.speed_forward_reverse
                          textInput:snapshotIsFresh ? controllerModelData.textInput : @""];
        if (snapshotIsFresh && controllerModelData.neckControlActive) {
            [self applyVisionNeckPan:controllerModelData.neckPan tilt:controllerModelData.neckTilt];
        }
        // Mirror legacy gripper intent into render compatibility state only;
        // this method deliberately has no actuator authority.
        [self applyVisionGrippersActive:snapshotIsFresh && controllerModelData.gripperControlActive
                             leftClosed:snapshotIsFresh && controllerModelData.leftGripperClosed
                            rightClosed:snapshotIsFresh && controllerModelData.rightGripperClosed];
        [self applyVisionTorsoActive:snapshotIsFresh && controllerModelData.torsoControlActive
                           rotation:snapshotIsFresh ? controllerModelData.torsoRotation : 0];
        self.masterControllerInputWasFresh = YES;
        self.lastControllerRenderUptime = now;
    }
    else if (self.masterControllerInputWasFresh)
    {
        [self stopBaseMotionAndDropHeartbeat];
        self.lastControllerRenderUptime = now;
    }
}

- (void)stopBaseMotionAndDropHeartbeat
{
    [self applyVisionTorsoActive:NO rotation:0];
    // Values below -999 bypass joystick processing so the requested tread
    // brake bits remain set. This is written exactly once; renderController
    // then stays silent until a fresh authorized snapshot arrives.
    [self controllerPassthrough:CGPointMake(-1000.0, -1000.0)
                  touchPadPointR:CGPointMake(-1000.0, -1000.0)
                             Lat:0
                            Long:0
                   tredBrakeLock:true
            flipperForwardIsDown:false
               flipperRelaxBrake:false
           flipperBackwardIsDown:false
                flipperBrakeLock:true
                           lact1:false
                           lact2:false
                           lact3:false
                           speed:0.0
                 speed_playPause:false
           speed_forward_reverse:false
                       textInput:@""];
    self.masterControllerInputWasFresh = NO;
}


//Sent by the controller to authorize autonomous mode or become the masterController input
- (void) switchToMasterControllerID:(NSString *)controllerID
{
    if (![self.masterControllerID isEqualToString:controllerID] && self.masterControllerInputWasFresh) {
        [self stopBaseMotionAndDropHeartbeat];
    }
    self.masterControllerID = controllerID;
}


- (void) controllerId:(NSString *)controllerId controllerModelData:(ROBBaseControllerModel *)controllerModelData
{
    ROBBaseControllerModel *previous = [self.controlModelDataDictionary valueForKey:controllerId];
    BOOL previousLeftActive = previous != nil && previous.touchPadPointL.x > -999.0
        && previous.touchPadPointL.y > -999.0;
    BOOL previousRightActive = previous != nil && previous.touchPadPointR.x > -999.0
        && previous.touchPadPointR.y > -999.0;
    BOOL leftActive = controllerModelData.touchPadPointL.x > -999.0
        && controllerModelData.touchPadPointL.y > -999.0;
    BOOL rightActive = controllerModelData.touchPadPointR.x > -999.0
        && controllerModelData.touchPadPointR.y > -999.0;
    BOOL urgent = previous == nil
        || previousLeftActive != leftActive
        || previousRightActive != rightActive
        || previous.tredBrakeLock != controllerModelData.tredBrakeLock
        || previous.speed_playPause != controllerModelData.speed_playPause
        || previous.speed_forward_reverse != controllerModelData.speed_forward_reverse;
    //store the control model data in the dictionary of data
    controllerModelData.receivedAtUptime = NSProcessInfo.processInfo.systemUptime;
    [self.controlModelDataDictionary setValue:controllerModelData forKey:controllerId];
    [[ROBRecordingCoordinator shared]
        recordTreadCommandWithControllerID:controllerId
                                     model:controllerModelData
                              activeMaster:[self.masterControllerID isEqualToString:controllerId]];
    // Full Vision snapshots are the authoritative tread path. Render the
    // current master immediately just like the dedicated tread path; the
    // shared 75 ms limiter still bounds serial traffic, while brake/active
    // transitions bypass it so releasing the dead-man stops without delay.
    if ([self.masterControllerID isEqualToString:controllerId]) {
        [self renderControllerPrioritized:urgent];
    }
}

- (void)controllerId:(NSString *)controllerId
        treadPointL:(CGPoint)treadPointL
        treadPointR:(CGPoint)treadPointR
      tredBrakeLock:(bool)tredBrakeLock
               speed:(float)speed
     speedPlayPause:(bool)speedPlayPause
 speedForwardReverse:(bool)speedForwardReverse
{
    ROBBaseControllerModel *previous = [self.treadControlModelDataDictionary valueForKey:controllerId];
    BOOL previousLeftActive = previous != nil && previous.touchPadPointL.x > -999.0
        && previous.touchPadPointL.y > -999.0;
    BOOL previousRightActive = previous != nil && previous.touchPadPointR.x > -999.0
        && previous.touchPadPointR.y > -999.0;
    BOOL leftActive = treadPointL.x > -999.0 && treadPointL.y > -999.0;
    BOOL rightActive = treadPointR.x > -999.0 && treadPointR.y > -999.0;
    BOOL urgent = previous == nil
        || previousLeftActive != leftActive
        || previousRightActive != rightActive
        || previous.tredBrakeLock != tredBrakeLock
        || previous.speed_playPause != speedPlayPause
        || previous.speed_forward_reverse != speedForwardReverse;
    ROBBaseControllerModel *treadModel = [ROBBaseControllerModel new];
    treadModel.touchPadPointL = treadPointL;
    treadModel.touchPadPointR = treadPointR;
    treadModel.tredBrakeLock = tredBrakeLock;
    treadModel.speed = speed;
    treadModel.speed_playPause = speedPlayPause;
    treadModel.speed_forward_reverse = speedForwardReverse;
    treadModel.receivedAtUptime = NSProcessInfo.processInfo.systemUptime;
    [self.treadControlModelDataDictionary setValue:treadModel forKey:controllerId];
    [[ROBRecordingCoordinator shared]
        recordTreadCommandWithControllerID:controllerId
                                     model:treadModel
                              activeMaster:[self.masterControllerID isEqualToString:controllerId]];
    if ([self.masterControllerID isEqualToString:controllerId]) {
        [self renderControllerPrioritized:urgent];
    }
}


@end
