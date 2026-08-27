//
//  ROBPersonTrackingPolicy.h
//  Cerebro
//
//  Frame-rate-independent command-space calibration for keeping a normalized
//  Vision person/face bounding box centered in ROB's camera.
//


#ifndef ROBPersonTrackingPolicy_h
#define ROBPersonTrackingPolicy_h

#include "ROBNeckSafetyPolicy.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    // The face tracker used this hardware-calibrated target before recognized
    // face acquisition was routed through the shared neck safety gateway.
    ROBPersonTrackingNeutralUpperTarget = 6869,
    // Tracking may look down from neutral, but never below the known upright
    // upper-neck target. The existing high guard remains deliberately tighter
    // than the physical joint's hard maximum.
    ROBPersonTrackingMinimumUpperTarget = ROBNeckSafetyUprightUpperTarget,
    ROBPersonTrackingMaximumUpperTarget = 7400
};

typedef struct {
    double centerX;
    double centerY;
    double horizontalDeadBand;
    double verticalDeadBand;
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
// image center, and ignores the central 8 percent of each image dimension so
// detector jitter does not make the neck hunt.
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
