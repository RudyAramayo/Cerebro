//
//  ROBPersonTrackingPolicy.c
//  Cerebro
//


#include "ROBPersonTrackingPolicy.h"

#include <limits.h>
#include <math.h>
#include <stddef.h>

static double ROBPersonTrackingClampDouble(
    double value,
    double minimum,
    double maximum
) {
    return fmax(minimum, fmin(maximum, value));
}

static int32_t ROBPersonTrackingClampTarget(
    int32_t target,
    int32_t minimum,
    int32_t maximum
) {
    if (target < minimum) return minimum;
    if (target > maximum) return maximum;
    return target;
}

static double ROBPersonTrackingErrorBeyondDeadBand(
    double coordinate,
    double center,
    double deadBand
) {
    const double error = coordinate - center;
    if (fabs(error) <= deadBand) return 0.0;
    return error - copysign(deadBand, error);
}

static int32_t ROBPersonTrackingRoundedTarget(double value) {
    if (value <= (double)INT32_MIN) return INT32_MIN;
    if (value >= (double)INT32_MAX) return INT32_MAX;
    return (int32_t)lround(value);
}

ROBPersonTrackingConfig ROBPersonTrackingDefaultConfig(void) {
    const ROBPersonTrackingConfig configuration = {
        .centerX = 0.5,
        .centerY = 0.5,
        .horizontalDeadBand = 0.04,
        .verticalDeadBand = 0.04,
        .panTargetsPerSecond = 400.0,
        .upperTargetsPerSecond = 300.0,
        .maximumElapsedSeconds = 0.1,
        .panMinimumTarget = 4000,
        .panMaximumTarget = 8000,
        .upperMinimumTarget = ROBPersonTrackingMinimumUpperTarget,
        .upperMaximumTarget = ROBPersonTrackingMaximumUpperTarget
    };
    return configuration;
}

bool ROBPersonTrackingConfigIsValid(
    const ROBPersonTrackingConfig *configuration
) {
    if (configuration == NULL
        || !isfinite(configuration->centerX)
        || !isfinite(configuration->centerY)
        || !isfinite(configuration->horizontalDeadBand)
        || !isfinite(configuration->verticalDeadBand)
        || !isfinite(configuration->panTargetsPerSecond)
        || !isfinite(configuration->upperTargetsPerSecond)
        || !isfinite(configuration->maximumElapsedSeconds)) {
        return false;
    }
    return configuration->centerX >= 0.0
        && configuration->centerX <= 1.0
        && configuration->centerY >= 0.0
        && configuration->centerY <= 1.0
        && configuration->horizontalDeadBand >= 0.0
        && configuration->horizontalDeadBand
            < fmin(configuration->centerX, 1.0 - configuration->centerX)
        && configuration->verticalDeadBand >= 0.0
        && configuration->verticalDeadBand
            < fmin(configuration->centerY, 1.0 - configuration->centerY)
        && configuration->panTargetsPerSecond > 0.0
        && configuration->upperTargetsPerSecond > 0.0
        && configuration->maximumElapsedSeconds > 0.0
        && configuration->panMinimumTarget < configuration->panMaximumTarget
        && configuration->upperMinimumTarget
            <= ROBPersonTrackingNeutralUpperTarget
        && configuration->upperMaximumTarget
            >= ROBPersonTrackingNeutralUpperTarget;
}

bool ROBPersonTrackingApply(
    const ROBPersonTrackingConfig *configuration,
    int32_t currentPanTarget,
    int32_t currentUpperTarget,
    double normalizedX,
    double normalizedY,
    double elapsedSeconds,
    ROBPersonTrackingResult *resultOut
) {
    if (resultOut == NULL) return false;
    *resultOut = (ROBPersonTrackingResult){0};
    if (!ROBPersonTrackingConfigIsValid(configuration)
        || !isfinite(normalizedX)
        || !isfinite(normalizedY)
        || !isfinite(elapsedSeconds)
        || elapsedSeconds <= 0.0) {
        return false;
    }

    const double x = ROBPersonTrackingClampDouble(normalizedX, 0.0, 1.0);
    const double y = ROBPersonTrackingClampDouble(normalizedY, 0.0, 1.0);
    const double elapsed = fmin(
        elapsedSeconds,
        configuration->maximumElapsedSeconds
    );
    resultOut->horizontalError = ROBPersonTrackingErrorBeyondDeadBand(
        x,
        configuration->centerX,
        configuration->horizontalDeadBand
    );
    resultOut->verticalError = ROBPersonTrackingErrorBeyondDeadBand(
        y,
        configuration->centerY,
        configuration->verticalDeadBand
    );

    const int32_t requestedPan = ROBPersonTrackingRoundedTarget(
        (double)currentPanTarget
            - resultOut->horizontalError
                * configuration->panTargetsPerSecond
                * elapsed
    );
    const int32_t requestedUpper = ROBPersonTrackingRoundedTarget(
        (double)currentUpperTarget
            + resultOut->verticalError
                * configuration->upperTargetsPerSecond
                * elapsed
    );
    resultOut->panTarget = ROBPersonTrackingClampTarget(
        requestedPan,
        configuration->panMinimumTarget,
        configuration->panMaximumTarget
    );
    resultOut->upperTarget = ROBPersonTrackingClampTarget(
        requestedUpper,
        configuration->upperMinimumTarget,
        configuration->upperMaximumTarget
    );
    resultOut->panClamped = resultOut->panTarget != requestedPan;
    resultOut->upperClamped = resultOut->upperTarget != requestedUpper;
    return true;
}
