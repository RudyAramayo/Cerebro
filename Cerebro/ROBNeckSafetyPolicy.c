//
//  ROBNeckSafetyPolicy.c
//  Cerebro
//

#include "ROBNeckSafetyPolicy.h"

#include <math.h>
#include <stddef.h>

static const double ROBNeckSafetyMaximumAbsoluteCounterRotationGain = 10.0;

static int32_t ROBNeckSafetyClampTarget(
    int32_t value,
    int32_t minimum,
    int32_t maximum
) {
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static bool ROBNeckSafetyTargetBoundsAreValid(int32_t minimum, int32_t maximum) {
    return minimum > ROBNeckSafetyTargetOff
        && minimum < maximum
        && maximum <= ROBNeckSafetyMaximumMaestroTarget;
}

void ROBNeckSafetySettleGateReset(ROBNeckSafetySettleGate *gate) {
    if (gate == NULL) {
        return;
    }
    *gate = (ROBNeckSafetySettleGate){0};
}

bool ROBNeckSafetySettleGateShouldHold(
    ROBNeckSafetySettleGate *gate,
    int32_t lowerTarget,
    int32_t coupledTarget,
    bool commandPathEnabled,
    bool prerequisiteTargetEstablished,
    double now,
    double settleDuration
) {
    if (gate == NULL) {
        return true;
    }
    if (!isfinite(now)
        || !isfinite(settleDuration)
        || settleDuration <= 0.0) {
        ROBNeckSafetySettleGateReset(gate);
        return true;
    }

    const bool targetChanged = !gate->active
        || gate->lowerTarget != lowerTarget
        || gate->coupledTarget != coupledTarget;
    if (targetChanged) {
        gate->active = true;
        gate->lowerTarget = lowerTarget;
        gate->coupledTarget = coupledTarget;
        gate->readyAt = 0.0;
    }

    if (!commandPathEnabled) {
        gate->readyAt = 0.0;
        return true;
    }
    if (gate->readyAt <= 0.0) {
        gate->readyAt = now + settleDuration;
        return true;
    }
    if (!prerequisiteTargetEstablished || now < gate->readyAt) {
        return true;
    }

    ROBNeckSafetySettleGateReset(gate);
    return false;
}

ROBNeckSafetyConfig ROBNeckSafetyDefaultConfig(void) {
    const ROBNeckSafetyConfig config = {
        .panMinimumTarget = 4000,
        .panCenterTarget = 6000,
        .panMaximumTarget = 8000,
        .panTargetsPerDegree = 33.3333333333,
        .lowerMinimumTarget = 4375,
        .lowerFullPanLowTarget = 5300,
        .lowerFullPanHighTarget = 6822,
        .lowerForwardRestrictedTarget = 6823,
        .lowerMaximumTarget = 7675,
        .upperMinimumTarget = 4300,
        .upperMaximumTarget = 7790,
        .restrictedPanDegrees = 30.0,
        .forwardPanMinimumDegrees = -15.0,
        .forwardPanMaximumDegrees = 2.1,
        .cameraLevelingEnabled = true,
        .upperCounterRotationGain = -1.0
    };
    return config;
}

bool ROBNeckSafetyConfigIsValid(const ROBNeckSafetyConfig *config) {
    if (config == NULL) {
        return false;
    }

    if (!ROBNeckSafetyTargetBoundsAreValid(
            config->panMinimumTarget,
            config->panMaximumTarget
        )
        || config->panCenterTarget <= config->panMinimumTarget
        || config->panCenterTarget >= config->panMaximumTarget) {
        return false;
    }

    if (!ROBNeckSafetyTargetBoundsAreValid(
            config->lowerMinimumTarget,
            config->lowerMaximumTarget
        )
        || config->lowerMinimumTarget
            >= ROBNeckSafetyFullPanLowerThresholdTarget
        || config->lowerMaximumTarget
            < ROBNeckSafetyUprightLowerTarget
        || config->lowerFullPanLowTarget <= config->lowerMinimumTarget
        || config->lowerFullPanHighTarget <= config->lowerFullPanLowTarget
        || config->lowerFullPanHighTarget >= config->lowerMaximumTarget
        || config->lowerForwardRestrictedTarget <= ROBNeckSafetyTargetOff
        || config->lowerForwardRestrictedTarget
            > ROBNeckSafetyMaximumMaestroTarget) {
        return false;
    }

    if (!ROBNeckSafetyTargetBoundsAreValid(
            config->upperMinimumTarget,
            config->upperMaximumTarget
        )
        || config->upperMinimumTarget >= ROBNeckSafetyUprightUpperTarget
        || config->upperMaximumTarget < ROBNeckSafetyUprightUpperTarget) {
        return false;
    }

    if (!isfinite(config->panTargetsPerDegree)
        || config->panTargetsPerDegree <= 0.0
        || !isfinite(config->restrictedPanDegrees)
        || config->restrictedPanDegrees < 0.0
        || !isfinite(config->forwardPanMinimumDegrees)
        || !isfinite(config->forwardPanMaximumDegrees)
        || config->forwardPanMinimumDegrees
            > config->forwardPanMaximumDegrees
        || config->forwardPanMinimumDegrees > 0.0
        || config->forwardPanMaximumDegrees < 0.0
        || config->forwardPanMinimumDegrees
            < -config->restrictedPanDegrees
        || config->forwardPanMaximumDegrees
            > config->restrictedPanDegrees
        || !isfinite(config->upperCounterRotationGain)
        || fabs(config->upperCounterRotationGain)
            > ROBNeckSafetyMaximumAbsoluteCounterRotationGain) {
        return false;
    }

    const double negativeCapacity =
        (double)(config->panCenterTarget - config->panMinimumTarget)
        / config->panTargetsPerDegree;
    const double positiveCapacity =
        (double)(config->panMaximumTarget - config->panCenterTarget)
        / config->panTargetsPerDegree;
    const double fullPanDegrees = fmin(negativeCapacity, positiveCapacity);

    return isfinite(fullPanDegrees)
        && fullPanDegrees > 0.0
        && config->restrictedPanDegrees <= fullPanDegrees;
}

double ROBNeckSafetyFullPanDegrees(const ROBNeckSafetyConfig *config) {
    if (!ROBNeckSafetyConfigIsValid(config)) {
        return NAN;
    }

    const double negativeCapacity =
        (double)(config->panCenterTarget - config->panMinimumTarget)
        / config->panTargetsPerDegree;
    const double positiveCapacity =
        (double)(config->panMaximumTarget - config->panCenterTarget)
        / config->panTargetsPerDegree;
    return fmin(negativeCapacity, positiveCapacity);
}

double ROBNeckSafetyReferenceLowerTarget(const ROBNeckSafetyConfig *config) {
    if (!ROBNeckSafetyConfigIsValid(config)) {
        return NAN;
    }
    return (double)ROBNeckSafetyUprightLowerTarget;
}

double ROBNeckSafetyMaestroMotionDuration(
    int32_t fromTarget,
    int32_t toTarget,
    uint16_t speedLimit,
    uint8_t accelerationLimit
) {
    if (fromTarget < ROBNeckSafetyTargetOff
        || fromTarget > ROBNeckSafetyMaximumMaestroTarget
        || toTarget < ROBNeckSafetyTargetOff
        || toTarget > ROBNeckSafetyMaximumMaestroTarget
        || speedLimit > ROBNeckSafetyMaximumMaestroTarget) {
        return NAN;
    }

    const double distance = fabs((double)toTarget - (double)fromTarget);
    if (distance <= 0.0
        || (speedLimit == 0 && accelerationLimit == 0)) {
        return 0.0;
    }

    // One speed unit changes one quarter-microsecond target unit per 10 ms.
    const double maximumSpeed = (double)speedLimit * 100.0;
    // One acceleration unit changes speed by one target unit per 80 ms,
    // equivalent to 1250 quarter-microsecond target units per second squared.
    const double acceleration = (double)accelerationLimit * 1250.0;

    if (accelerationLimit == 0) {
        return distance / maximumSpeed;
    }
    if (speedLimit == 0) {
        return 2.0 * sqrt(distance / acceleration);
    }

    const double accelerationAndDecelerationDistance =
        maximumSpeed * maximumSpeed / acceleration;
    if (distance <= accelerationAndDecelerationDistance) {
        return 2.0 * sqrt(distance / acceleration);
    }

    return 2.0 * maximumSpeed / acceleration
        + (distance - accelerationAndDecelerationDistance) / maximumSpeed;
}

bool ROBNeckSafetyAllowedPanBounds(
    const ROBNeckSafetyConfig *config,
    int32_t lowerTarget,
    ROBNeckSafetyPanBounds *boundsOut
) {
    if (boundsOut == NULL) {
        return false;
    }
    *boundsOut = (ROBNeckSafetyPanBounds){ .minimumDegrees = NAN,
                                          .maximumDegrees = NAN };
    if (!ROBNeckSafetyConfigIsValid(config)) {
        return false;
    }

    const double full = ROBNeckSafetyFullPanDegrees(config);

    if (lowerTarget == ROBNeckSafetyTargetOff) {
        boundsOut->minimumDegrees = config->forwardPanMinimumDegrees;
        boundsOut->maximumDegrees = config->forwardPanMaximumDegrees;
        return true;
    }

    const int32_t boundedLowerTarget = ROBNeckSafetyClampTarget(
        lowerTarget,
        config->lowerMinimumTarget,
        config->lowerMaximumTarget
    );
    if (boundedLowerTarget < ROBNeckSafetyFullPanLowerThresholdTarget) {
        boundsOut->minimumDegrees = -config->restrictedPanDegrees;
        boundsOut->maximumDegrees = config->restrictedPanDegrees;
        return true;
    }

    boundsOut->minimumDegrees = -full;
    boundsOut->maximumDegrees = full;
    return true;
}

bool ROBNeckSafetyPanTargetToDegrees(
    const ROBNeckSafetyConfig *config,
    int32_t panTarget,
    double *degreesOut
) {
    if (!ROBNeckSafetyConfigIsValid(config)
        || degreesOut == NULL
        || panTarget == ROBNeckSafetyTargetOff
        || panTarget < config->panMinimumTarget
        || panTarget > config->panMaximumTarget) {
        return false;
    }

    *degreesOut = (double)(panTarget - config->panCenterTarget)
        / config->panTargetsPerDegree;
    return isfinite(*degreesOut);
}

bool ROBNeckSafetyPanDegreesToTarget(
    const ROBNeckSafetyConfig *config,
    double degrees,
    int32_t *panTargetOut
) {
    if (!ROBNeckSafetyConfigIsValid(config)
        || panTargetOut == NULL
        || !isfinite(degrees)) {
        return false;
    }

    const double target = (double)config->panCenterTarget
        + degrees * config->panTargetsPerDegree;
    if (!isfinite(target)
        || target < (double)config->panMinimumTarget
        || target > (double)config->panMaximumTarget) {
        return false;
    }

    const long rounded = lround(target);
    if (rounded < config->panMinimumTarget
        || rounded > config->panMaximumTarget) {
        return false;
    }
    *panTargetOut = (int32_t)rounded;
    return true;
}

bool ROBNeckSafetyApply(
    const ROBNeckSafetyConfig *config,
    int32_t requestedPanTarget,
    int32_t requestedLowerTarget,
    int32_t desiredUpperTarget,
    ROBNeckSafetyResult *resultOut
) {
    if (resultOut == NULL) {
        return false;
    }

    *resultOut = (ROBNeckSafetyResult){0};
    if (!ROBNeckSafetyConfigIsValid(config)) {
        return false;
    }

    ROBNeckSafetyPanBounds panBounds;
    if (!ROBNeckSafetyAllowedPanBounds(
            config,
            requestedLowerTarget,
            &panBounds
        )) {
        return false;
    }
    resultOut->allowedPanMinimumDegrees = panBounds.minimumDegrees;
    resultOut->allowedPanMaximumDegrees = panBounds.maximumDegrees;

    if (requestedLowerTarget != ROBNeckSafetyTargetOff) {
        resultOut->lowerTarget = ROBNeckSafetyClampTarget(
            requestedLowerTarget,
            config->lowerMinimumTarget,
            config->lowerMaximumTarget
        );
        resultOut->lowerClamped =
            resultOut->lowerTarget != requestedLowerTarget;
        // Use the bounded lower target for both the envelope and compensation.
        if (!ROBNeckSafetyAllowedPanBounds(
                config,
                resultOut->lowerTarget,
                &panBounds
            )) {
            return false;
        }
        resultOut->allowedPanMinimumDegrees = panBounds.minimumDegrees;
        resultOut->allowedPanMaximumDegrees = panBounds.maximumDegrees;
    }

    if (requestedPanTarget != ROBNeckSafetyTargetOff) {
        const int32_t hardBoundedPan = ROBNeckSafetyClampTarget(
            requestedPanTarget,
            config->panMinimumTarget,
            config->panMaximumTarget
        );
        double requestedDegrees = 0.0;
        if (!ROBNeckSafetyPanTargetToDegrees(
                config,
                hardBoundedPan,
                &requestedDegrees
            )) {
            return false;
        }

        const double boundedDegrees = fmax(
            resultOut->allowedPanMinimumDegrees,
            fmin(resultOut->allowedPanMaximumDegrees, requestedDegrees)
        );
        if (!ROBNeckSafetyPanDegreesToTarget(
                config,
                boundedDegrees,
                &resultOut->panTarget
            )) {
            return false;
        }
        resultOut->panClamped = resultOut->panTarget != requestedPanTarget;
    }

    if (desiredUpperTarget != ROBNeckSafetyTargetOff) {
        double compensatedTarget = (double)desiredUpperTarget;
        if (config->cameraLevelingEnabled
            && resultOut->lowerTarget != ROBNeckSafetyTargetOff) {
            const double referenceLower = ROBNeckSafetyReferenceLowerTarget(config);
            const double adjustment = config->upperCounterRotationGain
                * ((double)resultOut->lowerTarget - referenceLower);
            compensatedTarget += adjustment;
            resultOut->upperCompensated = fabs(adjustment) > 0.0;
        }

        resultOut->upperClamped =
            compensatedTarget < (double)config->upperMinimumTarget
            || compensatedTarget > (double)config->upperMaximumTarget;

        long roundedTarget;
        if (compensatedTarget <= (double)INT32_MIN) {
            roundedTarget = INT32_MIN;
        } else if (compensatedTarget >= (double)INT32_MAX) {
            roundedTarget = INT32_MAX;
        } else {
            roundedTarget = lround(compensatedTarget);
        }

        const int32_t boundedUpper = ROBNeckSafetyClampTarget(
            (int32_t)roundedTarget,
            config->upperMinimumTarget,
            config->upperMaximumTarget
        );
        resultOut->upperTarget = boundedUpper;
    }

    return true;
}
