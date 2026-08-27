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

NS_ASSUME_NONNULL_END

#endif /* ROBPersonTrackingPreferences_h */
