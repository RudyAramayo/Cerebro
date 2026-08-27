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

static ROBPersonTrackingResult track(
    const ROBPersonTrackingConfig *configuration,
    int pan,
    int upper,
    double x,
    double y,
    double elapsed
) {
    ROBPersonTrackingResult result = {0};
    EXPECT_TRUE(ROBPersonTrackingApply(
        configuration, pan, upper, x, y, elapsed, &result
    ));
    return result;
}

static void testDefaultCalibration(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    EXPECT_TRUE(ROBPersonTrackingConfigIsValid(&configuration));
    EXPECT_INT(ROBPersonTrackingMinimumUpperTarget, 7350);
    EXPECT_INT(ROBPersonTrackingNeutralUpperTarget, 7375);
    EXPECT_INT(ROBPersonTrackingMaximumUpperTarget, 7400);
    EXPECT_FALSE(configuration.mirrorHorizontalCoordinate);

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
    // Vision reads the unmirrored sample buffer. Image right must lower the
    // installed servo's raw target and turn ROB physically right.
    ROBPersonTrackingResult robotRight = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.8, 0.8, 0.1
    );
    EXPECT_INT(robotRight.panTarget, 5994);
    EXPECT_INT(robotRight.upperTarget, 7377);

    ROBPersonTrackingResult robotLeft = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.2, 0.2, 0.1
    );
    EXPECT_INT(robotLeft.panTarget, 6006);
    EXPECT_INT(robotLeft.upperTarget, 7373);
    EXPECT_FALSE(robotLeft.upperClamped);

    // A future mirrored display coordinate can still opt into conversion.
    configuration.mirrorHorizontalCoordinate = true;
    ROBPersonTrackingResult mirroredRight = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.2, 0.5, 0.1
    );
    EXPECT_INT(mirroredRight.panTarget, 5994);

    // A downward correction is limited to two raw targets in this representative
    // frame and cannot cross the slight-up floor that prevents the observed dip.
    ROBPersonTrackingResult downwardWithinGuard = track(
        &configuration, 6000, 7360, 0.5, 0.2, 0.1
    );
    EXPECT_INT(downwardWithinGuard.upperTarget, 7358);
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
    EXPECT_INT(pan, 5940);
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
    EXPECT_INT(cappedGap.panTarget, 5989);

    EXPECT_FALSE(ROBPersonTrackingApply(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        NAN, 0.5, 0.1, &low
    ));
    EXPECT_FALSE(ROBPersonTrackingApply(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.5, 0.5, 0.0, &low
    ));
    EXPECT_FALSE(ROBPersonTrackingApply(
        NULL, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.5, 0.5, 0.1, &low
    ));
}

int main(void) {
    testDefaultCalibration();
    testCorrectionsPointCameraTowardBlob();
    testRightTrackingAccumulatesMonotonically();
    testTrackingGuards();

    if (failures != 0) {
        fprintf(stderr, "ROB person tracking policy fixtures failed: %d\n", failures);
        return 1;
    }
    puts("ROB person tracking policy fixtures passed");
    return 0;
}
