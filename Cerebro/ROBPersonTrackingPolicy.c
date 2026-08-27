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
    double deadBand,
    double responseExponent
) {
    const double error = coordinate - center;
    if (fabs(error) <= deadBand) return 0.0;
    const double errorBeyondDeadBand = error - copysign(deadBand, error);
    const double availableError = error > 0.0
        ? 1.0 - center - deadBand
        : center - deadBand;
    const double normalizedError = ROBPersonTrackingClampDouble(
        fabs(errorBeyondDeadBand) / availableError,
        0.0,
        1.0
    );
    return copysign(
        availableError * pow(normalizedError, responseExponent),
        errorBeyondDeadBand
    );
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
        .horizontalDeadBand = 0.06,
        .verticalDeadBand = 0.06,
        .mirrorHorizontalCoordinate = false,
        .lowerClearanceEnabled = false,
        .responseExponent = 1.5,
        .panTargetsPerSecond =
            ROBPersonTrackingDefaultPanTargetsPerSecond,
        .upperTargetsPerSecond =
            ROBPersonTrackingDefaultVerticalTargetsPerSecond,
        .upperDownTargetsPerSecond =
            ROBPersonTrackingDefaultVerticalTargetsPerSecond * 0.2,
        .maximumElapsedSeconds = 0.1,
        .panMinimumTarget = 4000,
        .panMaximumTarget = 8000,
        .lowerMinimumTarget = 4375,
        .lowerFullPanMinimumTarget =
            ROBPersonTrackingFullPanLowerMinimumTarget,
        .lowerFullPanMaximumTarget =
            ROBPersonTrackingFullPanLowerMaximumTarget,
        .lowerMaximumTarget = 7675,
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
        || !isfinite(configuration->responseExponent)
        || !isfinite(configuration->panTargetsPerSecond)
        || !isfinite(configuration->upperTargetsPerSecond)
        || !isfinite(configuration->upperDownTargetsPerSecond)
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
        && configuration->responseExponent >= 1.0
        && configuration->responseExponent <= 4.0
        && configuration->panTargetsPerSecond > 0.0
        && configuration->upperTargetsPerSecond > 0.0
        && configuration->upperDownTargetsPerSecond > 0.0
        && configuration->maximumElapsedSeconds > 0.0
        && configuration->panMinimumTarget < configuration->panMaximumTarget
        && configuration->lowerMinimumTarget
            <= configuration->lowerFullPanMinimumTarget
        && configuration->lowerFullPanMinimumTarget
            <= configuration->lowerFullPanMaximumTarget
        && configuration->lowerFullPanMaximumTarget
            <= configuration->lowerMaximumTarget
        && configuration->upperMinimumTarget
            <= configuration->upperMaximumTarget;
}

bool ROBPersonTrackingApply(
    const ROBPersonTrackingConfig *configuration,
    int32_t currentPanTarget,
    int32_t currentLowerTarget,
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

    const double observedX = ROBPersonTrackingClampDouble(
        normalizedX,
        0.0,
        1.0
    );
    // Vision runs on the raw sample buffer. A future mirrored detector can
    // request one X conversion explicitly, but preview presentation must not
    // reverse the physical controller by default.
    const double x = configuration->mirrorHorizontalCoordinate
        ? 1.0 - observedX
        : observedX;
    const double y = ROBPersonTrackingClampDouble(normalizedY, 0.0, 1.0);
    const double elapsed = fmin(
        elapsedSeconds,
        configuration->maximumElapsedSeconds
    );
    resultOut->horizontalError = ROBPersonTrackingErrorBeyondDeadBand(
        x,
        configuration->centerX,
        configuration->horizontalDeadBand,
        configuration->responseExponent
    );
    resultOut->verticalError = ROBPersonTrackingErrorBeyondDeadBand(
        y,
        configuration->centerY,
        configuration->verticalDeadBand,
        configuration->responseExponent
    );

    int32_t requestedLower = ROBPersonTrackingClampTarget(
        currentLowerTarget,
        configuration->lowerMinimumTarget,
        configuration->lowerMaximumTarget
    );
    resultOut->lowerClearanceActive =
        configuration->lowerClearanceEnabled
        && (requestedLower < configuration->lowerFullPanMinimumTarget
            || requestedLower > configuration->lowerFullPanMaximumTarget);
    if (resultOut->lowerClearanceActive) {
        // Move only as far as the nearest reviewed full-pan boundary. The
        // runtime enables this request only when the safety gateway can issue
        // the lower target and its calibrated upper counter-rotation together.
        requestedLower = requestedLower
                < configuration->lowerFullPanMinimumTarget
            ? configuration->lowerFullPanMinimumTarget
            : configuration->lowerFullPanMaximumTarget;
    }

    // ROB's physical pan calibration moves right toward the lower raw target
    // (4000) and left toward the higher raw target (8000). Hold direct pan and
    // camera demand during a clearance transition so the coupled neck move
    // cannot compete with image-centering corrections.
    const int32_t requestedPan = resultOut->lowerClearanceActive
        ? currentPanTarget
        : ROBPersonTrackingRoundedTarget(
            (double)currentPanTarget
                - resultOut->horizontalError
                    * configuration->panTargetsPerSecond
                    * elapsed
        );
    const int32_t requestedUpper = resultOut->lowerClearanceActive
        ? currentUpperTarget
        : ROBPersonTrackingRoundedTarget(
            (double)currentUpperTarget
                + resultOut->verticalError
                    * (resultOut->verticalError >= 0.0
                        ? configuration->upperTargetsPerSecond
                        : configuration->upperDownTargetsPerSecond)
                    * elapsed
        );
    resultOut->panTarget = ROBPersonTrackingClampTarget(
        requestedPan,
        configuration->panMinimumTarget,
        configuration->panMaximumTarget
    );
    resultOut->lowerTarget = requestedLower;
    resultOut->upperTarget = ROBPersonTrackingClampTarget(
        requestedUpper,
        configuration->upperMinimumTarget,
        configuration->upperMaximumTarget
    );
    resultOut->panClamped = resultOut->panTarget != requestedPan;
    resultOut->upperClamped = resultOut->upperTarget != requestedUpper;
    return true;
}
