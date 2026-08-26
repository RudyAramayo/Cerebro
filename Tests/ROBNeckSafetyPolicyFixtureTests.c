//
//  ROBNeckSafetyPolicyFixtureTests.c
//  Cerebro
//

#include "../Cerebro/ROBNeckSafetyPolicy.h"

#include <math.h>
#include <stdio.h>

static int failures = 0;

#define EXPECT_TRUE(expression) \
    do { \
        if (!(expression)) { \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expression); \
            failures++; \
        } \
    } while (0)

#define EXPECT_FALSE(expression) EXPECT_TRUE(!(expression))

#define EXPECT_INT(actual, expected) \
    do { \
        const int actualValue = (int)(actual); \
        const int expectedValue = (int)(expected); \
        if (actualValue != expectedValue) { \
            fprintf( \
                stderr, \
                "FAIL %s:%d: %s = %d, expected %d\n", \
                __FILE__, \
                __LINE__, \
                #actual, \
                actualValue, \
                expectedValue \
            ); \
            failures++; \
        } \
    } while (0)

#define EXPECT_NEAR(actual, expected, tolerance) \
    do { \
        const double actualValue = (double)(actual); \
        const double expectedValue = (double)(expected); \
        if (!isfinite(actualValue) \
            || fabs(actualValue - expectedValue) > (double)(tolerance)) { \
            fprintf( \
                stderr, \
                "FAIL %s:%d: %s = %.12f, expected %.12f +/- %.12f\n", \
                __FILE__, \
                __LINE__, \
                #actual, \
                actualValue, \
                expectedValue, \
                (double)(tolerance) \
            ); \
            failures++; \
        } \
    } while (0)

static ROBNeckSafetyPanBounds testedPanBounds(
    const ROBNeckSafetyConfig *config,
    int32_t lowerTarget
) {
    ROBNeckSafetyPanBounds bounds = { NAN, NAN };
    EXPECT_TRUE(ROBNeckSafetyAllowedPanBounds(config, lowerTarget, &bounds));
    return bounds;
}

static void testConfigurationValidation(void) {
    ROBNeckSafetyConfig config = ROBNeckSafetyDefaultConfig();
    EXPECT_TRUE(ROBNeckSafetyConfigIsValid(&config));
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(NULL));
    EXPECT_NEAR(ROBNeckSafetyFullPanDegrees(&config), 60.0, 0.000001);
    EXPECT_INT(ROBNeckSafetyFullPanLowerThresholdTarget, 5000);
    EXPECT_INT(ROBNeckSafetyUprightLowerTarget, 6011);
    EXPECT_INT(ROBNeckSafetyUprightUpperTarget, 6073);
    EXPECT_INT(config.lowerFullPanLowTarget, 5300);
    EXPECT_INT(config.lowerFullPanHighTarget, 6822);
    EXPECT_NEAR(ROBNeckSafetyReferenceLowerTarget(&config), 6011.0, 0.0);
    EXPECT_INT(config.lowerForwardRestrictedTarget, 6823);
    EXPECT_NEAR(config.forwardPanMinimumDegrees, -15.0, 0.0);
    EXPECT_NEAR(config.forwardPanMaximumDegrees, 2.1, 0.0);
    EXPECT_FALSE(ROBNeckSafetyLowerTargetHasFullPanClearance(
        &config,
        ROBNeckSafetyTargetOff
    ));
    EXPECT_FALSE(ROBNeckSafetyLowerTargetHasFullPanClearance(
        &config,
        ROBNeckSafetyFullPanLowerThresholdTarget - 1
    ));
    EXPECT_TRUE(ROBNeckSafetyLowerTargetHasFullPanClearance(
        &config,
        ROBNeckSafetyFullPanLowerThresholdTarget
    ));
    EXPECT_TRUE(ROBNeckSafetyLowerTargetHasFullPanClearance(
        &config,
        ROBNeckSafetyUprightLowerTarget
    ));
    EXPECT_FALSE(ROBNeckSafetyLowerTargetHasFullPanClearance(NULL, 6200));
    EXPECT_TRUE(config.cameraLevelingEnabled);

    ROBNeckSafetyConfig invalid = config;
    invalid.panTargetsPerDegree = NAN;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.panTargetsPerDegree = 0.0;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.panCenterTarget = invalid.panMinimumTarget;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.panMaximumTarget = ROBNeckSafetyMaximumMaestroTarget + 1;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.lowerFullPanLowTarget = invalid.lowerMinimumTarget;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.lowerMinimumTarget = ROBNeckSafetyFullPanLowerThresholdTarget;
    invalid.lowerFullPanLowTarget = invalid.lowerMinimumTarget + 300;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.lowerMaximumTarget = ROBNeckSafetyUprightLowerTarget - 1;
    invalid.lowerFullPanLowTarget = 5300;
    invalid.lowerFullPanHighTarget = 5900;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.lowerFullPanHighTarget = invalid.lowerFullPanLowTarget;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.lowerForwardRestrictedTarget = ROBNeckSafetyTargetOff;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.lowerForwardRestrictedTarget =
        ROBNeckSafetyMaximumMaestroTarget + 1;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    ROBNeckSafetyConfig validEdge = config;
    validEdge.lowerForwardRestrictedTarget = validEdge.lowerFullPanHighTarget;
    EXPECT_TRUE(ROBNeckSafetyConfigIsValid(&validEdge));

    invalid = config;
    invalid.upperMinimumTarget = ROBNeckSafetyTargetOff;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.upperMaximumTarget = ROBNeckSafetyUprightUpperTarget - 1;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.restrictedPanDegrees = -1.0;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.restrictedPanDegrees = 61.0;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.forwardPanMinimumDegrees = NAN;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.forwardPanMaximumDegrees = INFINITY;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.forwardPanMinimumDegrees = invalid.forwardPanMaximumDegrees;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    // A legacy zero-degree restricted envelope migrates safely as a
    // center-only forward window rather than discarding its calibration.
    validEdge = config;
    validEdge.restrictedPanDegrees = 0.0;
    validEdge.forwardPanMinimumDegrees = 0.0;
    validEdge.forwardPanMaximumDegrees = 0.0;
    EXPECT_TRUE(ROBNeckSafetyConfigIsValid(&validEdge));

    invalid = config;
    invalid.forwardPanMinimumDegrees = -30.1;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.forwardPanMaximumDegrees = 30.1;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.forwardPanMinimumDegrees = 0.1;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.forwardPanMaximumDegrees = -0.1;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    validEdge = config;
    validEdge.forwardPanMinimumDegrees = -validEdge.restrictedPanDegrees;
    validEdge.forwardPanMaximumDegrees = validEdge.restrictedPanDegrees;
    EXPECT_TRUE(ROBNeckSafetyConfigIsValid(&validEdge));

    invalid = config;
    invalid.upperCounterRotationGain = INFINITY;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    invalid = config;
    invalid.upperCounterRotationGain = 10.01;
    EXPECT_FALSE(ROBNeckSafetyConfigIsValid(&invalid));

    EXPECT_TRUE(isnan(ROBNeckSafetyFullPanDegrees(&invalid)));
    EXPECT_TRUE(isnan(ROBNeckSafetyReferenceLowerTarget(&invalid)));
    ROBNeckSafetyPanBounds invalidBounds = { 1.0, 2.0 };
    EXPECT_FALSE(ROBNeckSafetyAllowedPanBounds(&invalid, 6200, &invalidBounds));
    EXPECT_TRUE(isnan(invalidBounds.minimumDegrees));
    EXPECT_TRUE(isnan(invalidBounds.maximumDegrees));
    EXPECT_FALSE(ROBNeckSafetyAllowedPanBounds(&config, 6200, NULL));
}

static void testLowerClearancePanEnvelope(void) {
    const ROBNeckSafetyConfig config = ROBNeckSafetyDefaultConfig();
    const double full = ROBNeckSafetyFullPanDegrees(&config);

    ROBNeckSafetyPanBounds bounds = testedPanBounds(
        &config,
        config.lowerMinimumTarget
    );
    EXPECT_NEAR(bounds.minimumDegrees, -30.0, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, 30.0, 0.000001);

    bounds = testedPanBounds(
        &config,
        ROBNeckSafetyFullPanLowerThresholdTarget - 1
    );
    EXPECT_NEAR(bounds.minimumDegrees, -30.0, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, 30.0, 0.000001);

    bounds = testedPanBounds(
        &config,
        ROBNeckSafetyFullPanLowerThresholdTarget
    );
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    // Every integer lower-neck command across the operator-confirmed range,
    // including the upright target, must retain the complete pan envelope.
    for (int32_t lowerTarget = ROBNeckSafetyFullPanLowerThresholdTarget;
         lowerTarget <= 6823;
         lowerTarget++) {
        bounds = testedPanBounds(&config, lowerTarget);
        EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
        EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);
    }

    bounds = testedPanBounds(&config, config.lowerFullPanLowTarget - 1);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    bounds = testedPanBounds(&config, 6200);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    bounds = testedPanBounds(&config, config.lowerFullPanHighTarget);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    bounds = testedPanBounds(&config, config.lowerFullPanHighTarget + 1);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    bounds = testedPanBounds(&config, config.lowerForwardRestrictedTarget - 1);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    bounds = testedPanBounds(&config, config.lowerForwardRestrictedTarget);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    // Upright/high lower-neck targets remain fully available; the old V3
    // 6823 anchor is serialized only for settings compatibility.
    bounds = testedPanBounds(&config, 7277);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    bounds = testedPanBounds(&config, config.lowerMaximumTarget);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);

    bounds = testedPanBounds(&config, ROBNeckSafetyTargetOff);
    EXPECT_NEAR(bounds.minimumDegrees, -15.0, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, 2.1, 0.000001);

    bounds = testedPanBounds(&config, 100);
    EXPECT_NEAR(bounds.minimumDegrees, -30.0, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, 30.0, 0.000001);

    bounds = testedPanBounds(&config, 12000);
    EXPECT_NEAR(bounds.minimumDegrees, -full, 0.000001);
    EXPECT_NEAR(bounds.maximumDegrees, full, 0.000001);
}

static void testPanDegreeConversion(void) {
    const ROBNeckSafetyConfig config = ROBNeckSafetyDefaultConfig();
    double degrees = NAN;
    int32_t target = -1;

    EXPECT_TRUE(ROBNeckSafetyPanTargetToDegrees(&config, 6000, &degrees));
    EXPECT_NEAR(degrees, 0.0, 0.000001);
    EXPECT_TRUE(ROBNeckSafetyPanTargetToDegrees(&config, 4000, &degrees));
    EXPECT_NEAR(degrees, -60.0, 0.000001);
    EXPECT_TRUE(ROBNeckSafetyPanTargetToDegrees(&config, 8000, &degrees));
    EXPECT_NEAR(degrees, 60.0, 0.000001);
    EXPECT_FALSE(ROBNeckSafetyPanTargetToDegrees(
        &config,
        ROBNeckSafetyTargetOff,
        &degrees
    ));
    EXPECT_FALSE(ROBNeckSafetyPanTargetToDegrees(&config, 3999, &degrees));
    EXPECT_FALSE(ROBNeckSafetyPanTargetToDegrees(&config, 6000, NULL));

    EXPECT_TRUE(ROBNeckSafetyPanDegreesToTarget(&config, -30.0, &target));
    EXPECT_INT(target, 5000);
    EXPECT_TRUE(ROBNeckSafetyPanDegreesToTarget(&config, 0.0, &target));
    EXPECT_INT(target, 6000);
    EXPECT_TRUE(ROBNeckSafetyPanDegreesToTarget(&config, 30.0, &target));
    EXPECT_INT(target, 7000);
    EXPECT_FALSE(ROBNeckSafetyPanDegreesToTarget(&config, NAN, &target));
    EXPECT_FALSE(ROBNeckSafetyPanDegreesToTarget(&config, 61.0, &target));
    EXPECT_FALSE(ROBNeckSafetyPanDegreesToTarget(&config, 0.0, NULL));

    EXPECT_TRUE(ROBNeckSafetyPanTargetToDegrees(&config, 7000, &degrees));
    EXPECT_TRUE(ROBNeckSafetyPanDegreesToTarget(&config, degrees, &target));
    EXPECT_INT(target, 7000);
}

static void testPanApplicationAndOffSentinel(void) {
    const ROBNeckSafetyConfig config = ROBNeckSafetyDefaultConfig();
    ROBNeckSafetyResult result;

    EXPECT_TRUE(ROBNeckSafetyApply(&config, 8000, 6200, 0, &result));
    EXPECT_INT(result.panTarget, 8000);
    EXPECT_FALSE(result.panClamped);
    EXPECT_NEAR(result.allowedPanMinimumDegrees, -60.0, 0.000001);
    EXPECT_NEAR(result.allowedPanMaximumDegrees, 60.0, 0.000001);

    EXPECT_TRUE(ROBNeckSafetyApply(
        &config,
        8000,
        config.lowerMinimumTarget,
        0,
        &result
    ));
    EXPECT_INT(result.panTarget, 7000);
    EXPECT_TRUE(result.panClamped);

    EXPECT_TRUE(ROBNeckSafetyApply(
        &config,
        4000,
        config.lowerMaximumTarget,
        0,
        &result
    ));
    EXPECT_INT(result.panTarget, 4000);
    EXPECT_FALSE(result.panClamped);

    EXPECT_TRUE(ROBNeckSafetyApply(
        &config,
        8000,
        config.lowerForwardRestrictedTarget,
        0,
        &result
    ));
    EXPECT_INT(result.panTarget, 8000);
    EXPECT_FALSE(result.panClamped);
    EXPECT_NEAR(result.allowedPanMinimumDegrees, -60.0, 0.000001);
    EXPECT_NEAR(result.allowedPanMaximumDegrees, 60.0, 0.000001);

    ROBNeckSafetyConfig centerOnly = config;
    centerOnly.restrictedPanDegrees = 0.0;
    centerOnly.forwardPanMinimumDegrees = 0.0;
    centerOnly.forwardPanMaximumDegrees = 0.0;
    EXPECT_TRUE(ROBNeckSafetyApply(
        &centerOnly,
        centerOnly.panMaximumTarget,
        centerOnly.lowerForwardRestrictedTarget,
        0,
        &result
    ));
    EXPECT_INT(result.panTarget, centerOnly.panMaximumTarget);
    EXPECT_NEAR(result.allowedPanMinimumDegrees, -60.0, 0.000001);
    EXPECT_NEAR(result.allowedPanMaximumDegrees, 60.0, 0.000001);

    EXPECT_TRUE(ROBNeckSafetyApply(
        &centerOnly,
        centerOnly.panMaximumTarget,
        ROBNeckSafetyTargetOff,
        0,
        &result
    ));
    EXPECT_INT(result.panTarget, centerOnly.panCenterTarget);

    EXPECT_TRUE(ROBNeckSafetyApply(
        &config,
        4000,
        config.lowerForwardRestrictedTarget,
        0,
        &result
    ));
    EXPECT_INT(result.panTarget, 4000);
    EXPECT_FALSE(result.panClamped);

    EXPECT_TRUE(ROBNeckSafetyApply(&config, 8000, 0, 0, &result));
    EXPECT_INT(result.panTarget, 6070);
    EXPECT_INT(result.lowerTarget, ROBNeckSafetyTargetOff);
    EXPECT_NEAR(result.allowedPanMinimumDegrees, -15.0, 0.000001);
    EXPECT_NEAR(result.allowedPanMaximumDegrees, 2.1, 0.000001);

    EXPECT_TRUE(ROBNeckSafetyApply(&config, 0, 6200, 0, &result));
    EXPECT_INT(result.panTarget, ROBNeckSafetyTargetOff);
    EXPECT_FALSE(result.panClamped);

    EXPECT_TRUE(ROBNeckSafetyApply(&config, 0, 0, 0, &result));
    EXPECT_INT(result.panTarget, ROBNeckSafetyTargetOff);
    EXPECT_INT(result.lowerTarget, ROBNeckSafetyTargetOff);
    EXPECT_INT(result.upperTarget, ROBNeckSafetyTargetOff);

    EXPECT_TRUE(ROBNeckSafetyApply(&config, 6000, 9999, 0, &result));
    EXPECT_INT(result.lowerTarget, config.lowerMaximumTarget);
    EXPECT_TRUE(result.lowerClamped);
    EXPECT_NEAR(result.allowedPanMinimumDegrees, -60.0, 0.000001);
    EXPECT_NEAR(result.allowedPanMaximumDegrees, 60.0, 0.000001);

    ROBNeckSafetyConfig invalid = config;
    invalid.panTargetsPerDegree = NAN;
    result.panTarget = 1234;
    EXPECT_FALSE(ROBNeckSafetyApply(&invalid, 6000, 6200, 6000, &result));
    EXPECT_INT(result.panTarget, ROBNeckSafetyTargetOff);
    EXPECT_FALSE(ROBNeckSafetyApply(&config, 6000, 6200, 6000, NULL));
}

static void testCounterRotation(void) {
    ROBNeckSafetyConfig config = ROBNeckSafetyDefaultConfig();
    ROBNeckSafetyResult result;
    const int32_t referenceLower =
        (int32_t)ROBNeckSafetyReferenceLowerTarget(&config);

    config.upperCounterRotationGain = -1.0;
    EXPECT_TRUE(ROBNeckSafetyApply(
        &config,
        config.panCenterTarget,
        ROBNeckSafetyUprightLowerTarget,
        ROBNeckSafetyUprightUpperTarget,
        &result
    ));
    EXPECT_INT(result.upperTarget, ROBNeckSafetyUprightUpperTarget);
    EXPECT_FALSE(result.upperCompensated);

    EXPECT_TRUE(ROBNeckSafetyApply(
        &config, 6000, referenceLower + 100, 6000, &result));
    EXPECT_INT(result.upperTarget, 5900);
    EXPECT_TRUE(result.upperCompensated);
    EXPECT_FALSE(result.upperClamped);

    config.upperCounterRotationGain = 1.0;
    EXPECT_TRUE(ROBNeckSafetyApply(
        &config, 6000, referenceLower + 100, 6000, &result));
    EXPECT_INT(result.upperTarget, 6100);
    EXPECT_TRUE(result.upperCompensated);
    EXPECT_FALSE(result.upperClamped);

    config.upperCounterRotationGain = 0.005;
    EXPECT_TRUE(ROBNeckSafetyApply(
        &config, 6000, referenceLower + 100, 6000, &result));
    EXPECT_INT(result.upperTarget, 6001);
    EXPECT_TRUE(result.upperCompensated);
    // Rounding a safe fractional target is quantization, not hard clamping.
    EXPECT_FALSE(result.upperClamped);

    config.upperCounterRotationGain = 1.0;
    EXPECT_TRUE(ROBNeckSafetyApply(
        &config, 6000, referenceLower, 6000, &result));
    EXPECT_INT(result.upperTarget, 6000);
    EXPECT_FALSE(result.upperCompensated);
    EXPECT_FALSE(result.upperClamped);

    EXPECT_TRUE(ROBNeckSafetyApply(&config, 6000, 7675, 7000, &result));
    EXPECT_INT(result.upperTarget, config.upperMaximumTarget);
    EXPECT_TRUE(result.upperCompensated);
    EXPECT_TRUE(result.upperClamped);

    config.upperCounterRotationGain = -1.0;
    EXPECT_TRUE(ROBNeckSafetyApply(&config, 6000, 7675, 4400, &result));
    EXPECT_INT(result.upperTarget, config.upperMinimumTarget);
    EXPECT_TRUE(result.upperCompensated);
    EXPECT_TRUE(result.upperClamped);

    config.cameraLevelingEnabled = false;
    config.upperCounterRotationGain = 10.0;
    EXPECT_TRUE(ROBNeckSafetyApply(
        &config, 6000, config.lowerMaximumTarget, 6000, &result));
    EXPECT_INT(result.upperTarget, 6000);
    EXPECT_FALSE(result.upperCompensated);
    EXPECT_FALSE(result.upperClamped);

    config.cameraLevelingEnabled = true;
    config.upperCounterRotationGain = -1.0;
    EXPECT_TRUE(ROBNeckSafetyApply(
        &config, 6000, referenceLower + 100, 0, &result));
    EXPECT_INT(result.upperTarget, ROBNeckSafetyTargetOff);
    EXPECT_FALSE(result.upperCompensated);
    EXPECT_FALSE(result.upperClamped);

    EXPECT_TRUE(ROBNeckSafetyApply(&config, 6000, 0, 8000, &result));
    EXPECT_INT(result.lowerTarget, ROBNeckSafetyTargetOff);
    EXPECT_INT(result.upperTarget, config.upperMaximumTarget);
    EXPECT_FALSE(result.upperCompensated);
    EXPECT_TRUE(result.upperClamped);
}

static void testSettleGate(void) {
    ROBNeckSafetySettleGate gate = {0};

    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 6500, 0, true, false, 10.0, 1.0));
    EXPECT_TRUE(gate.active);
    EXPECT_NEAR(gate.readyAt, 11.0, 0.000001);

    // Repeated continuous-slider events must not move the deadline.
    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 6500, 0, true, true, 10.2, 1.0));
    EXPECT_NEAR(gate.readyAt, 11.0, 0.000001);
    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 6500, 0, true, false, 11.2, 1.0));
    EXPECT_FALSE(ROBNeckSafetySettleGateShouldHold(
        &gate, 6500, 0, true, true, 11.2, 1.0));
    EXPECT_FALSE(gate.active);

    // A new lower or coupled target starts a fresh interval.
    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 6400, 5900, true, false, 20.0, 0.5));
    EXPECT_NEAR(gate.readyAt, 20.5, 0.000001);
    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 6400, 5800, true, true, 20.6, 0.5));
    EXPECT_NEAR(gate.readyAt, 21.1, 0.000001);

    // A disabled path stays latched with no deadline. Enabling it begins the
    // full wait rather than using elapsed disabled time.
    ROBNeckSafetySettleGateReset(&gate);
    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 0, 0, false, false, 30.0, 1.0));
    EXPECT_NEAR(gate.readyAt, 0.0, 0.0);
    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 0, 0, true, true, 50.0, 1.0));
    EXPECT_NEAR(gate.readyAt, 51.0, 0.000001);
    EXPECT_FALSE(ROBNeckSafetySettleGateShouldHold(
        &gate, 0, 0, true, true, 51.0, 1.0));

    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        NULL, 6200, 0, true, true, 0.0, 1.0));
    EXPECT_TRUE(ROBNeckSafetySettleGateShouldHold(
        &gate, 6200, 0, true, true, NAN, 1.0));
    EXPECT_FALSE(gate.active);
}

static void testMaestroMotionDuration(void) {
    EXPECT_TRUE(isnan(ROBNeckSafetyMaestroMotionDuration(
        -1, 6000, 40, 4)));
    EXPECT_TRUE(isnan(ROBNeckSafetyMaestroMotionDuration(
        6000, ROBNeckSafetyMaximumMaestroTarget + 1, 40, 4)));
    EXPECT_TRUE(isnan(ROBNeckSafetyMaestroMotionDuration(
        6000, 7000, ROBNeckSafetyMaximumMaestroTarget + 1, 4)));

    EXPECT_NEAR(ROBNeckSafetyMaestroMotionDuration(
        6000, 6000, 40, 4), 0.0, 0.0);
    EXPECT_NEAR(ROBNeckSafetyMaestroMotionDuration(
        6000, 10000, 0, 0), 0.0, 0.0);

    // Speed 40 caps the target at 4000 quarter-microsecond units/second.
    EXPECT_NEAR(ROBNeckSafetyMaestroMotionDuration(
        6000, 10000, 40, 0), 1.0, 0.000001);

    // Acceleration 4 is 5000 target units/second squared. With no speed cap,
    // a 5000-unit triangular move takes one second up and one second down.
    EXPECT_NEAR(ROBNeckSafetyMaestroMotionDuration(
        5000, 10000, 0, 4), 2.0, 0.000001);

    // The configured default profile remains triangular below 3200 units and
    // becomes trapezoidal beyond it.
    EXPECT_NEAR(ROBNeckSafetyMaestroMotionDuration(
        6000, 7000, 40, 4), 2.0 * sqrt(0.2), 0.000001);
    EXPECT_NEAR(ROBNeckSafetyMaestroMotionDuration(
        6000, 10000, 40, 4), 1.8, 0.000001);
    EXPECT_NEAR(ROBNeckSafetyMaestroMotionDuration(
        10000, 6000, 40, 4), 1.8, 0.000001);
}

int main(void) {
    testConfigurationValidation();
    testLowerClearancePanEnvelope();
    testPanDegreeConversion();
    testPanApplicationAndOffSentinel();
    testCounterRotation();
    testSettleGate();
    testMaestroMotionDuration();

    if (failures != 0) {
        fprintf(stderr, "ROB neck safety policy fixtures failed: %d\n", failures);
        return 1;
    }

    puts("ROB neck safety policy fixtures passed");
    return 0;
}
