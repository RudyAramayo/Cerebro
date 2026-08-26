//
//  ROBNeckSafetyPolicy.h
//  Cerebro
//
//  Dependency-light, command-space safety policy for ROB's three Maestro
//  neck channels. This policy operates on commanded targets; it does not
//  claim to provide measured servo position feedback.
//

#ifndef ROBNeckSafetyPolicy_h
#define ROBNeckSafetyPolicy_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ROBNeckSafetyTargetOff = 0,
    // Operator-confirmed Maestro 24 lower-neck band where the mechanism has
    // complete pan clearance. Values below the band remain symmetrically
    // restricted; values above it use the forward/asymmetric envelope.
    ROBNeckSafetyFullPanLowerThresholdTarget = 5000,
    ROBNeckSafetyFullPanLowerMaximumTarget = 6495,
    // Calibrated collision-clear lift used before recovering an OFF/unknown
    // neck. This is intentionally distinct from the normal resting defaults.
    ROBNeckSafetyUprightLowerTarget = 6011,
    ROBNeckSafetyUprightUpperTarget = 6073,
    // Safe torso-control defaults: forward pan, lower resting toward the rear
    // of the robot, and upper held upright. Startup recovery returns to these
    // values only after the lower neck is lifted and pan settles forward.
    ROBNeckSafetyDefaultForwardPanTarget = 5799,
    ROBNeckSafetyDefaultLowerTarget = 7014,
    ROBNeckSafetyDefaultUpperTarget = ROBNeckSafetyUprightUpperTarget,
    ROBNeckSafetyMaximumMaestroTarget = 16383
};

typedef struct {
    int32_t panMinimumTarget;
    int32_t panCenterTarget;
    int32_t panMaximumTarget;
    double panTargetsPerDegree;

    int32_t lowerMinimumTarget;
    // Legacy fields retained by the V3 settings schema. Upright references
    // and the pan-clearance boundary now use the fixed Maestro 24 calibration
    // constants above.
    int32_t lowerFullPanLowTarget;
    int32_t lowerFullPanHighTarget;
    int32_t lowerForwardRestrictedTarget;
    int32_t lowerMaximumTarget;

    int32_t upperMinimumTarget;
    int32_t upperMaximumTarget;

    double restrictedPanDegrees;
    double forwardPanMinimumDegrees;
    double forwardPanMaximumDegrees;

    // When disabled, the desired upper target is still hard-clamped but is
    // not adjusted in response to lower-neck motion.
    bool cameraLevelingEnabled;

    // Applied in Maestro target units:
    // desiredUpper + gain * (lower - referenceLower). The reference lower
    // target is ROBNeckSafetyUprightLowerTarget. The sign must be calibrated
    // for the physical mounting direction.
    double upperCounterRotationGain;
} ROBNeckSafetyConfig;

typedef struct {
    double minimumDegrees;
    double maximumDegrees;
} ROBNeckSafetyPanBounds;

typedef struct {
    int32_t panTarget;
    int32_t lowerTarget;
    int32_t upperTarget;

    double allowedPanMinimumDegrees;
    double allowedPanMaximumDegrees;

    bool panClamped;
    bool lowerClamped;
    bool upperCompensated;
    bool upperClamped;
} ROBNeckSafetyResult;

// Monotonic, feedback-agnostic settle latch used by the serial gateway before
// it releases a coupled lower-neck move. The caller supplies its clock and
// whether the prerequisite command target is now established.
typedef struct {
    bool active;
    int32_t lowerTarget;
    int32_t coupledTarget;
    double readyAt;
} ROBNeckSafetySettleGate;

void ROBNeckSafetySettleGateReset(ROBNeckSafetySettleGate *gate);

// Returns true while the lower move must remain held. Repeated calls for the
// same targets cannot shorten readyAt. A target change restarts the interval;
// a disabled command path or invalid timing input fails closed.
bool ROBNeckSafetySettleGateShouldHold(
    ROBNeckSafetySettleGate *gate,
    int32_t lowerTarget,
    int32_t coupledTarget,
    bool commandPathEnabled,
    bool prerequisiteTargetEstablished,
    double now,
    double settleDuration
);

// Returns the conservative, currently known command-space calibration.
ROBNeckSafetyConfig ROBNeckSafetyDefaultConfig(void);

// Rejects invalid ordering, non-finite numeric fields, targets outside the
// Maestro's 14-bit range, an impossible restricted envelope, and implausibly
// large counter-rotation gain.
bool ROBNeckSafetyConfigIsValid(const ROBNeckSafetyConfig *config);

// The symmetric full-pan angle supported on both sides of center.
// Returns NAN when config is invalid.
double ROBNeckSafetyFullPanDegrees(const ROBNeckSafetyConfig *config);

// Calibrated upright lower-neck target used as the counter-rotation reference.
// Returns NAN when config is invalid.
double ROBNeckSafetyReferenceLowerTarget(const ROBNeckSafetyConfig *config);

// Returns true when a known active lower-neck target is in the calibrated
// collision-clear band and therefore permits the complete pan range. Target 0
// is off/unknown and never qualifies.
bool ROBNeckSafetyLowerTargetHasFullPanClearance(
    const ROBNeckSafetyConfig *config,
    int32_t lowerTarget
);

// Conservative duration of the Maestro output-value ramp between two raw
// targets under compact-protocol speed/acceleration limits. Speed uses the
// Maestro's (0.25 us)/(10 ms) units; acceleration uses
// (0.25 us)/(10 ms)/(80 ms). A zero limit means unlimited for that dimension.
// Returns NAN for targets or speed outside the 14-bit protocol range.
double ROBNeckSafetyMaestroMotionDuration(
    int32_t fromTarget,
    int32_t toTarget,
    uint16_t speedLimit,
    uint8_t accelerationLimit
);

// Computes the pan envelope for a lower-neck target. Target 0 means the lower
// servo is off or its pose is unknown and therefore returns the tightest
// configured range (the validated forward range). A known target below the
// Maestro 24 e-stop clearance band uses the symmetric restricted range; a
// known target inside the inclusive band receives full pan, and a known target
// above it uses the asymmetric forward range. Inputs outside the configured
// hard range are evaluated at the nearest hard bound. Returns false and writes
// NaN bounds when config or output is invalid.
bool ROBNeckSafetyAllowedPanBounds(
    const ROBNeckSafetyConfig *config,
    int32_t lowerTarget,
    ROBNeckSafetyPanBounds *boundsOut
);

// Exact calibration conversions. Target 0 is an off sentinel, not an angle.
// Conversion fails for invalid config, non-finite/out-of-range input, or a
// null output pointer. Degree-to-target conversion rounds to the nearest
// Maestro target unit.
bool ROBNeckSafetyPanTargetToDegrees(
    const ROBNeckSafetyConfig *config,
    int32_t panTarget,
    double *degreesOut
);

bool ROBNeckSafetyPanDegreesToTarget(
    const ROBNeckSafetyConfig *config,
    double degrees,
    int32_t *panTargetOut
);

// Applies hard joint bounds, the dynamic pan envelope, and upper-servo
// counter-rotation when cameraLevelingEnabled is true. A requested target of
// 0 remains 0 (servo off). If the lower target is 0, pan uses the tightest
// fail-safe range and upper compensation is suppressed.
// Returns false and writes an all-off result if config or output is invalid.
bool ROBNeckSafetyApply(
    const ROBNeckSafetyConfig *config,
    int32_t requestedPanTarget,
    int32_t requestedLowerTarget,
    int32_t desiredUpperTarget,
    ROBNeckSafetyResult *resultOut
);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // ROBNeckSafetyPolicy_h
