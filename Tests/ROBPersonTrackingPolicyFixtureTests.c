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
    EXPECT_INT(ROBPersonTrackingMinimumUpperTarget, 7300);
    EXPECT_INT(ROBPersonTrackingNeutralUpperTarget, 7300);
    EXPECT_INT(ROBPersonTrackingMaximumUpperTarget, 7400);

    ROBPersonTrackingResult centered = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.5, 0.5, 0.1
    );
    EXPECT_INT(centered.panTarget, 6000);
    EXPECT_INT(centered.upperTarget, ROBPersonTrackingNeutralUpperTarget);

    ROBPersonTrackingResult jitter = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.539, 0.461, 0.1
    );
    EXPECT_INT(jitter.panTarget, 6000);
    EXPECT_INT(jitter.upperTarget, ROBPersonTrackingNeutralUpperTarget);
}

static void testCorrectionsPointCameraTowardBlob(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
    // The installed pan servo turns right as the raw target decreases.
    ROBPersonTrackingResult upperRight = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.8, 0.8, 0.1
    );
    EXPECT_INT(upperRight.panTarget, 5990);
    EXPECT_INT(upperRight.upperTarget, 7304);

    ROBPersonTrackingResult lowerLeft = track(
        &configuration, 6000, ROBPersonTrackingNeutralUpperTarget,
        0.2, 0.2, 0.1
    );
    EXPECT_INT(lowerLeft.panTarget, 6010);
    EXPECT_INT(lowerLeft.upperTarget, ROBPersonTrackingMinimumUpperTarget);
    EXPECT_TRUE(lowerLeft.upperClamped);

    // A downward correction may reduce an already raised target, but cannot
    // cross the slight-up tracking floor that prevents the observed dip.
    ROBPersonTrackingResult downwardWithinGuard = track(
        &configuration, 6000, 7350, 0.5, 0.2, 0.1
    );
    EXPECT_INT(downwardWithinGuard.upperTarget, 7346);
}

static void testTrackingGuards(void) {
    ROBPersonTrackingConfig configuration = ROBPersonTrackingDefaultConfig();
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
    EXPECT_INT(cappedGap.panTarget, 5982);

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
    testTrackingGuards();

    if (failures != 0) {
        fprintf(stderr, "ROB person tracking policy fixtures failed: %d\n", failures);
        return 1;
    }
    puts("ROB person tracking policy fixtures passed");
    return 0;
}
