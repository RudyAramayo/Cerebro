//
//  ROBPersonTrackingPreferences.h
//  Cerebro
//
//  Persistent operator calibration for face and human-blob tracking.
//

#ifndef ROBPersonTrackingPreferences_h
#define ROBPersonTrackingPreferences_h

#import <Foundation/Foundation.h>

#import "ROBPersonTrackingPolicy.h"

#import <math.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const ROBPersonTrackingPanSpeedDefaultsKey =
    @"ROB.PersonTracking.PanTargetsPerSecond";
static NSString * const ROBPersonTrackingVerticalSpeedDefaultsKey =
    @"ROB.PersonTracking.VerticalTargetsPerSecond";
static NSString * const ROBPersonTrackingAutomaticPostureChangesDefaultsKey =
    @"ROB.PersonTracking.AutomaticPostureChangesEnabled";

// Opt in explicitly to the large distance/search lean gestures. New and
// existing installations otherwise keep the lower neck upright while pan and
// upper-camera tracking continue normally.
static inline BOOL ROBPersonTrackingAutomaticPostureChangesEnabledFromDefaults(
    NSUserDefaults *defaults
) {
    return [defaults boolForKey:ROBPersonTrackingAutomaticPostureChangesDefaultsKey];
}

static inline double ROBPersonTrackingClampPanTargetsPerSecond(double value)
{
    if (!isfinite(value)) {
        return ROBPersonTrackingDefaultPanTargetsPerSecond;
    }
    return fmax(
        ROBPersonTrackingMinimumPanTargetsPerSecond,
        fmin(ROBPersonTrackingMaximumPanTargetsPerSecond, value)
    );
}

static inline double ROBPersonTrackingPanTargetsPerSecondFromDefaults(
    NSUserDefaults *defaults
) {
    id storedValue = [defaults objectForKey:ROBPersonTrackingPanSpeedDefaultsKey];
    if (![storedValue respondsToSelector:@selector(doubleValue)]) {
        return ROBPersonTrackingDefaultPanTargetsPerSecond;
    }
    return ROBPersonTrackingClampPanTargetsPerSecond(
        [storedValue doubleValue]
    );
}

static inline double ROBPersonTrackingClampVerticalTargetsPerSecond(
    double value
) {
    if (!isfinite(value)) {
        return ROBPersonTrackingDefaultVerticalTargetsPerSecond;
    }
    return fmax(
        ROBPersonTrackingMinimumVerticalTargetsPerSecond,
        fmin(ROBPersonTrackingMaximumVerticalTargetsPerSecond, value)
    );
}

static inline double ROBPersonTrackingVerticalTargetsPerSecondFromDefaults(
    NSUserDefaults *defaults
) {
    id storedValue = [defaults
        objectForKey:ROBPersonTrackingVerticalSpeedDefaultsKey];
    if (![storedValue respondsToSelector:@selector(doubleValue)]) {
        return ROBPersonTrackingDefaultVerticalTargetsPerSecond;
    }
    return ROBPersonTrackingClampVerticalTargetsPerSecond(
        [storedValue doubleValue]
    );
}

NS_ASSUME_NONNULL_END

#endif /* ROBPersonTrackingPreferences_h */
