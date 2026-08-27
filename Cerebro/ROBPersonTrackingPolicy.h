//
//  ROBPersonTrackingPolicy.h
//  Cerebro
//
//  Frame-rate-independent command-space calibration for keeping a normalized
//  Vision person/face bounding box centered in ROB's camera.
//


#ifndef ROBPersonTrackingPolicy_h
#define ROBPersonTrackingPolicy_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ROBPersonTrackingMinimumPanTargetsPerSecond = 1500,
    ROBPersonTrackingDefaultPanTargetsPerSecond = 3000,
    ROBPersonTrackingMaximumPanTargetsPerSecond = 6000,
    ROBPersonTrackingMinimumVerticalTargetsPerSecond = 400,
    ROBPersonTrackingDefaultVerticalTargetsPerSecond = 800,
    ROBPersonTrackingMaximumVerticalTargetsPerSecond = 2000,
    ROBPersonTrackingFullPanLowerMinimumTarget = 5000,
    ROBPersonTrackingFullPanLowerMaximumTarget = 6495,
    // Reviewed camera band for controller-authorized full-pan follow
    // preparation. Ordinary face/blob acquisition instead centers a narrow
    // runtime band on the currently accepted upper-camera target.
    ROBPersonTrackingNeutralUpperTarget = 7375,
    ROBPersonTrackingMinimumUpperTarget = 7350,
    // Retain the existing high guard below the physical joint maximum. This
    // leaves only 25 raw targets of travel on either side of neutral.
    ROBPersonTrackingMaximumUpperTarget = 7400
};

typedef struct {
    double centerX;
    double centerY;
    double horizontalDeadBand;
    double verticalDeadBand;
    bool mirrorHorizontalCoordinate;
    bool lowerClearanceEnabled;
    double responseExponent;
    double panTargetsPerSecond;
    double upperTargetsPerSecond;
    double upperDownTargetsPerSecond;
    double maximumElapsedSeconds;
    int32_t panMinimumTarget;
    int32_t panMaximumTarget;
    int32_t lowerMinimumTarget;
    int32_t lowerFullPanMinimumTarget;
    int32_t lowerFullPanMaximumTarget;
    int32_t lowerMaximumTarget;
    int32_t upperMinimumTarget;
    int32_t upperMaximumTarget;
} ROBPersonTrackingConfig;

typedef struct {
    int32_t panTarget;
    int32_t lowerTarget;
    int32_t upperTarget;
    double horizontalError;
    double verticalError;
    bool panClamped;
    bool upperClamped;
    bool lowerClearanceActive;
} ROBPersonTrackingResult;

// The default controller samples at no more than 10 Hz, aims at the exact
// image center in the raw main-camera Vision coordinate system, ignores the
// central 12 percent on both axes, and eases corrections as the observation
// approaches that band. The runtime may replace the default horizontal rate
// with the operator's bounded preference. The runtime may independently set
// the bounded vertical rate. Automatic lower-neck clearance is fail-closed by
// default and must be enabled only when calibrated camera leveling can
// counter-rotate the upper joint.
ROBPersonTrackingConfig ROBPersonTrackingDefaultConfig(void);

bool ROBPersonTrackingConfigIsValid(
    const ROBPersonTrackingConfig *configuration
);

// Applies one proportional tracking step. Normalized coordinates outside the
// image are clipped to 0...1, and long observation gaps are limited so a
// reacquired face cannot cause a large one-frame jump.
bool ROBPersonTrackingApply(
    const ROBPersonTrackingConfig *configuration,
    int32_t currentPanTarget,
    int32_t currentLowerTarget,
    int32_t currentUpperTarget,
    double normalizedX,
    double normalizedY,
    double elapsedSeconds,
    ROBPersonTrackingResult *resultOut
);

#ifdef __cplusplus
}
#endif

#endif /* ROBPersonTrackingPolicy_h */
