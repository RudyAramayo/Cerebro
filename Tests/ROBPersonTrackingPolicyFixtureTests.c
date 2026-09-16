//
//  ROBPersonTrackingPolicyFixtureTests.c
//  Cerebro
//


#include "../Cerebro/ROBPersonTrackingPolicy.h"

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

static ROBPersonTrackingResult trackWithLower(
    const ROBPersonTrackingConfig *configuration,
    int pan,
    int lower,
    int upper,
    double x,
    double y,
    double elapsed
) {
    ROBPersonTrackingResult result = {0};
    EXPECT_TRUE(ROBPersonTrackingApply(
        configuration, pan, lower, upper, x, y, elapsed, &result
    ));
    return result;
}

static ROBPersonTrackingResult track(
    const ROBPersonTrackingConfig *configuration,
    int pan,
    int upper,
    double x,
    double y,
    double elapsed
) {
    return trackWithLower(
        configuration, pan, 7014, upper, x, y, elapsed
    );
}

static void testDefaultCalibration(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    EXPECT_TRUE(ROBPersonTrackingConfigIsValid(&configuration));
    EXPECT_INT(ROBPersonTrackingMinimumUpperTarget, 7350);
    EXPECT_INT(ROBPersonTrackingNeutralUpperTarget, 7375);
    EXPECT_INT(ROBPersonTrackingMaximumUpperTarget, 7400);
    EXPECT_FALSE(configuration.mirrorHorizontalCoordinate);
    EXPECT_TRUE(fabs(configuration.responseExponent - 1.5) < 0.000001);
    EXPECT_INT(configuration.panTargetsPerSecond, 1500);
    EXPECT_INT(ROBPersonTrackingMinimumPanTargetsPerSecond, 1500);
    EXPECT_INT(ROBPersonTrackingDefaultPanTargetsPerSecond, 1500);
    EXPECT_INT(ROBPersonTrackingMaximumPanTargetsPerSecond, 6000);
    EXPECT_INT(ROBPersonTrackingMinimumVerticalTargetsPerSecond, 400);
    EXPECT_INT(ROBPersonTrackingDefaultVerticalTargetsPerSecond, 400);
    EXPECT_INT(ROBPersonTrackingMaximumVerticalTargetsPerSecond, 2000);
    EXPECT_INT(configuration.upperTargetsPerSecond, 400);
    EXPECT_INT(configuration.upperDownTargetsPerSecond, 80);
    EXPECT_FALSE(configuration.uprightTransitionEnabled);

    ROBPersonTrackingResult centered = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.5, 0.5, 0.1
    );
    EXPECT_INT(centered.panTarget, 6000);
    EXPECT_INT(centered.upperTarget, ROBPersonTrackingNeutralUpperTarget);

    ROBPersonTrackingResult jitter = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.559, 0.441, 0.1
    );
    EXPECT_INT(jitter.panTarget, 6000);
    EXPECT_INT(jitter.upperTarget, ROBPersonTrackingNeutralUpperTarget);
}

static void testCorrectionsPointCameraTowardBlob(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    // Vision sees the raw camera buffer. A person on ROB's physical right is
    // on the right of that buffer; lowering the raw pan target turns ROB right.
    ROBPersonTrackingResult robotRight = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.8, 0.8, 0.1
    );
    EXPECT_INT(robotRight.panTarget, 5973);
    EXPECT_INT(robotRight.lowerTarget, 7014);
    EXPECT_INT(robotRight.upperTarget, 7382);

    ROBPersonTrackingResult robotLeft = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.2, 0.2, 0.1
    );
    EXPECT_INT(robotLeft.panTarget, 6027);
    EXPECT_INT(robotLeft.upperTarget, 7374);
    EXPECT_FALSE(robotLeft.upperClamped);

    // A future mirrored detector can opt into one conversion explicitly.
    configuration.mirrorHorizontalCoordinate = true;
    ROBPersonTrackingResult mirroredRight = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.2, 0.5, 0.1
    );
    EXPECT_INT(mirroredRight.panTarget, 5973);
    configuration.mirrorHorizontalCoordinate = false;

    // Downward correction retains the one-fifth anti-dip speed ratio and
    // cannot cross the slight-up floor that prevents the observed dip.
    ROBPersonTrackingResult downwardWithinGuard = track(
        &configuration, 6000, 7360, 0.5, 0.2, 0.1
    );
    EXPECT_INT(downwardWithinGuard.upperTarget, 7359);

    ROBPersonTrackingResult far = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.8, 0.5, 0.1
    );
    ROBPersonTrackingResult closer = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.65, 0.5, 0.1
    );
    ROBPersonTrackingResult almostCentered = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.57, 0.5, 0.1
    );
    EXPECT_TRUE(fabs(far.horizontalError) > fabs(closer.horizontalError));
    EXPECT_TRUE(fabs(closer.horizontalError)
        > fabs(almostCentered.horizontalError));
    EXPECT_INT(far.panTarget, 5973);
    EXPECT_INT(closer.panTarget, 5994);
    EXPECT_INT(almostCentered.panTarget, 6000);
}

static void testRightTrackingAccumulatesMonotonically(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    int pan = 6000;
    for (int frame = 0; frame < 10; frame++) {
        const int previousPan = pan;
        ROBPersonTrackingResult result = track(
            &configuration,
            pan,
            ROBPersonTrackingNeutralUpperTarget,
            0.8,
            0.5,
            0.1
        );
        pan = result.panTarget;
        EXPECT_TRUE(pan < previousPan);
    }
    EXPECT_INT(pan, 5730);
}

static void testPanLimitRequestsUprightTransition(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    configuration.panMinimumTarget = 5900;
    configuration.panMaximumTarget = 6100;
    configuration.uprightTransitionEnabled = true;

    ROBPersonTrackingResult rightLimit = trackWithLower(
        &configuration, 5900, 7014, 7375, 0.8, 0.8, 0.1
    );
    EXPECT_TRUE(rightLimit.uprightTransitionRequested);
    EXPECT_TRUE(rightLimit.panClamped);
    EXPECT_INT(rightLimit.panTarget, 5900);
    EXPECT_INT(rightLimit.lowerTarget, 7014);
    EXPECT_INT(rightLimit.upperTarget, 7375);

    ROBPersonTrackingResult leftLimit = trackWithLower(
        &configuration, 6100, 7014, 7375, 0.2, 0.2, 0.1
    );
    EXPECT_TRUE(leftLimit.uprightTransitionRequested);
    EXPECT_TRUE(leftLimit.panClamped);
    EXPECT_INT(leftLimit.panTarget, 6100);
    EXPECT_INT(leftLimit.lowerTarget, 7014);
    EXPECT_INT(leftLimit.upperTarget, 7375);

    ROBPersonTrackingResult insideEnvelope = trackWithLower(
        &configuration, 6000, 7014, 7375, 0.8, 0.8, 0.1
    );
    EXPECT_FALSE(insideEnvelope.uprightTransitionRequested);
    EXPECT_INT(insideEnvelope.panTarget, 5973);
    EXPECT_INT(insideEnvelope.lowerTarget, 7014);
    EXPECT_INT(insideEnvelope.upperTarget, 7382);

    // Without runtime authorization the controller remains clamped at the
    // live envelope, while ordinary vertical centering remains available.
    configuration.uprightTransitionEnabled = false;
    ROBPersonTrackingResult unauthorized = trackWithLower(
        &configuration, 5900, 7014, 7375, 0.8, 0.8, 0.1
    );
    EXPECT_FALSE(unauthorized.uprightTransitionRequested);
    EXPECT_TRUE(unauthorized.panClamped);
    EXPECT_INT(unauthorized.panTarget, 5900);
    EXPECT_INT(unauthorized.lowerTarget, 7014);
    EXPECT_INT(unauthorized.upperTarget, 7382);
}

static void testTrackingGuards(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    // A newly acquired face at the bottom edge may move the camera down only
    // four raw targets, even when the detector was absent for a full second.
    ROBPersonTrackingResult reacquiredLow = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.5, 0.0, 1.0
    );
    EXPECT_INT(reacquiredLow.upperTarget, 7371);

    ROBPersonTrackingResult low = track(
        &configuration, 6000, ROBPersonTrackingMinimumUpperTarget,
        0.5, 0.0, 0.2
    );
    EXPECT_INT(low.upperTarget, ROBPersonTrackingMinimumUpperTarget);
    EXPECT_TRUE(low.upperClamped);

    ROBPersonTrackingResult high = track(
        &configuration, 6000, ROBPersonTrackingMaximumUpperTarget,
        0.5, 1.0, 0.2
    );
    EXPECT_INT(high.upperTarget, ROBPersonTrackingMaximumUpperTarget);
    EXPECT_TRUE(high.upperClamped);

    // A one-second observation gap is capped to one 0.1-second control step
    // instead of producing a catch-up jump.
    ROBPersonTrackingResult cappedGap = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        1.0, 0.5, 1.0
    );
    EXPECT_INT(cappedGap.panTarget, 5934);

    // Runtime acquisition may center its narrow tilt band on the actual
    // accepted camera pose instead of jumping to the policy's legacy neutral.
    configuration.upperMinimumTarget = 6053;
    configuration.upperMaximumTarget = 6093;
    EXPECT_TRUE(ROBPersonTrackingConfigIsValid(&configuration));
    ROBPersonTrackingResult dynamicUpper = track(
        &configuration, 6000, 6073, 0.5, 1.0, 0.1
    );
    EXPECT_INT(dynamicUpper.upperTarget, 6091);

    EXPECT_FALSE(ROBPersonTrackingApply(
        &configuration, 6000, 7014, ROBPersonTrackingNeutralUpperTarget,
        NAN, 0.5, 0.1, &low
    ));
    EXPECT_FALSE(ROBPersonTrackingApply(
        &configuration, 6000, 7014, ROBPersonTrackingNeutralUpperTarget,
        0.5, 0.5, 0.0, &low
    ));
    EXPECT_FALSE(ROBPersonTrackingApply(
        NULL, 6000, 7014, ROBPersonTrackingNeutralUpperTarget,
        0.5, 0.5, 0.1, &low
    ));

    configuration.responseExponent = 0.5;
    EXPECT_FALSE(ROBPersonTrackingConfigIsValid(&configuration));
    configuration = ROBPersonTrackingDefaultConfig();
    configuration.lowerMinimumTarget = configuration.lowerMaximumTarget + 1;
    EXPECT_FALSE(ROBPersonTrackingConfigIsValid(&configuration));
    configuration = ROBPersonTrackingDefaultConfig();
    configuration.upperDownTargetsPerSecond = 0.0;
    EXPECT_FALSE(ROBPersonTrackingConfigIsValid(&configuration));
}

static void testUprightLookaroundAndResponsivePreset(void) {
    ROBPersonTrackingConfig gentle = ROBPersonTrackingDefaultConfig();
    // Runtime centers this band on the reviewed upright camera pose.
    gentle.upperMinimumTarget = 6906 - 40;
    gentle.upperMaximumTarget = 6906 + 200;
    int pan = 6000;
    int upper = 6906;
    bool panMoved = false;
    bool upperMoved = false;
    for (int frame = 0; frame < 600; frame++) {
        double coordinate = (frame / 20) % 2 ? 0.2 : 0.8;
        ROBPersonTrackingResult result = trackWithLower(
            &gentle, pan, 6011, upper, coordinate, coordinate, 0.1
        );
        EXPECT_INT(result.lowerTarget, 6011);
        EXPECT_FALSE(result.uprightTransitionRequested);
        EXPECT_TRUE(result.upperTarget >= gentle.upperMinimumTarget);
        EXPECT_TRUE(result.upperTarget <= gentle.upperMaximumTarget);
        panMoved |= result.panTarget != pan;
        upperMoved |= result.upperTarget != upper;
        pan = result.panTarget;
        upper = result.upperTarget;
    }
    EXPECT_TRUE(panMoved);
    EXPECT_TRUE(upperMoved);

    ROBPersonTrackingConfig responsive = gentle;
    responsive.panTargetsPerSecond = ROBPersonTrackingResponsivePanTargetsPerSecond;
    responsive.upperTargetsPerSecond = ROBPersonTrackingResponsiveVerticalTargetsPerSecond;
    responsive.upperDownTargetsPerSecond = responsive.upperTargetsPerSecond * 0.2;
    ROBPersonTrackingResult slow = trackWithLower(
        &gentle, 6000, 6011, 6906, 0.8, 0.8, 0.1
    );
    ROBPersonTrackingResult fast = trackWithLower(
        &responsive, 6000, 6011, 6906, 0.8, 0.8, 0.1
    );
    EXPECT_TRUE(fast.panTarget < slow.panTarget);
    EXPECT_TRUE(fast.upperTarget > slow.upperTarget);
    EXPECT_INT(fast.panTarget, 5947);
    EXPECT_INT(fast.lowerTarget, 6011);
    EXPECT_FALSE(fast.uprightTransitionRequested);
}

int main(void) {
    testDefaultCalibration();
    testCorrectionsPointCameraTowardBlob();
    testRightTrackingAccumulatesMonotonically();
    testPanLimitRequestsUprightTransition();
    testTrackingGuards();
    testUprightLookaroundAndResponsivePreset();

    if (failures != 0) {
        fprintf(stderr, "ROB person tracking policy fixtures failed: %d\n", failures);
        return 1;
    }
    puts("ROB person tracking policy fixtures passed");
    return 0;
}
