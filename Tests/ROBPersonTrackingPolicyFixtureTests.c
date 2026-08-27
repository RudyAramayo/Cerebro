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
    EXPECT_INT(configuration.panTargetsPerSecond, 3000);
    EXPECT_INT(ROBPersonTrackingMinimumPanTargetsPerSecond, 1500);
    EXPECT_INT(ROBPersonTrackingDefaultPanTargetsPerSecond, 3000);
    EXPECT_INT(ROBPersonTrackingMaximumPanTargetsPerSecond, 6000);
    EXPECT_INT(configuration.lowerTargetsPerSecond, 1000);
    EXPECT_INT(configuration.lowerUprightTarget, 6011);
    EXPECT_INT(configuration.upperTargetsPerSecond, 400);
    EXPECT_INT(configuration.upperDownTargetsPerSecond, 80);

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
    EXPECT_INT(robotRight.panTarget, 5947);
    EXPECT_INT(robotRight.lowerTarget, 7014);
    EXPECT_INT(robotRight.upperTarget, 7382);

    ROBPersonTrackingResult robotLeft = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.2, 0.2, 0.1
    );
    EXPECT_INT(robotLeft.panTarget, 6053);
    EXPECT_INT(robotLeft.upperTarget, 7374);
    EXPECT_FALSE(robotLeft.upperClamped);

    // A future mirrored detector can opt into one conversion explicitly.
    configuration.mirrorHorizontalCoordinate = true;
    ROBPersonTrackingResult mirroredRight = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.2, 0.5, 0.1
    );
    EXPECT_INT(mirroredRight.panTarget, 5947);
    configuration.mirrorHorizontalCoordinate = false;

    // A downward correction is limited to one raw target in this representative
    // frame and cannot cross the slight-up floor that prevents the observed dip.
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
    EXPECT_INT(far.panTarget, 5947);
    EXPECT_INT(closer.panTarget, 5988);
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
    EXPECT_INT(pan, 5470);
}

static void testUpwardTrackingCoordinatesBothTiltJoints(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    ROBPersonTrackingResult above = trackWithLower(
        &configuration, 6000, 7014, 7375, 0.5, 0.8, 0.1
    );
    EXPECT_INT(above.panTarget, 6000);
    EXPECT_INT(above.lowerTarget, 6996);
    EXPECT_INT(above.upperTarget, 7382);

    // Lower posture pauses during active pan, then may resume at a clamped
    // pan edge so erecting the neck can eventually widen its safe envelope.
    ROBPersonTrackingResult whilePanning = trackWithLower(
        &configuration, 6000, 7014, 7375, 0.8, 0.8, 0.1
    );
    EXPECT_INT(whilePanning.lowerTarget, 7014);
    ROBPersonTrackingResult atPanEdge = trackWithLower(
        &configuration, 4000, 7014, 7375, 1.0, 0.8, 0.1
    );
    EXPECT_TRUE(atPanEdge.panClamped);
    EXPECT_INT(atPanEdge.lowerTarget, 6996);

    ROBPersonTrackingResult below = trackWithLower(
        &configuration, 6000, 7014, 7375, 0.5, 0.2, 0.1
    );
    EXPECT_INT(below.lowerTarget, 7014);
    ROBPersonTrackingResult belowUpright = trackWithLower(
        &configuration, 6000, 5000, 7375, 0.5, 0.8, 0.1
    );
    EXPECT_INT(belowUpright.lowerTarget, 5018);
    ROBPersonTrackingResult nearUpright = trackWithLower(
        &configuration, 6000, 6015, 7375, 0.5, 1.0, 0.1
    );
    EXPECT_INT(nearUpright.lowerTarget, 6011);
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
    EXPECT_INT(cappedGap.panTarget, 5868);

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
    configuration.lowerUprightTarget = configuration.lowerMaximumTarget + 1;
    EXPECT_FALSE(ROBPersonTrackingConfigIsValid(&configuration));
    configuration = ROBPersonTrackingDefaultConfig();
    configuration.upperDownTargetsPerSecond = 0.0;
    EXPECT_FALSE(ROBPersonTrackingConfigIsValid(&configuration));
}

int main(void) {
    testDefaultCalibration();
    testCorrectionsPointCameraTowardBlob();
    testRightTrackingAccumulatesMonotonically();
    testUpwardTrackingCoordinatesBothTiltJoints();
    testTrackingGuards();

    if (failures != 0) {
        fprintf(stderr, "ROB person tracking policy fixtures failed: %d\n", failures);
        return 1;
    }
    puts("ROB person tracking policy fixtures passed");
    return 0;
}
