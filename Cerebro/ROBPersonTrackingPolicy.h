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
    // The current proven physical tracking speed remains available as the
    // slowest operator setting. New installations start moderately faster.
    ROBPersonTrackingMinimumPanTargetsPerSecond = 250,
    ROBPersonTrackingDefaultPanTargetsPerSecond = 500,
    ROBPersonTrackingMaximumPanTargetsPerSecond = 1500,
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
    double responseExponent;
    double panTargetsPerSecond;
    double upperTargetsPerSecond;
    double maximumElapsedSeconds;
    int32_t panMinimumTarget;
    int32_t panMaximumTarget;
    int32_t upperMinimumTarget;
    int32_t upperMaximumTarget;
} ROBPersonTrackingConfig;

typedef struct {
    int32_t panTarget;
    int32_t upperTarget;
    double horizontalError;
    double verticalError;
    bool panClamped;
    bool upperClamped;
} ROBPersonTrackingResult;

// The default controller samples at no more than 10 Hz, aims at the exact
// image center in the raw main-camera Vision coordinate system, ignores the
// central 12 percent on both axes, and eases corrections as the observation
// approaches that band. The runtime may replace the default horizontal rate
// with the operator's bounded preference.
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
