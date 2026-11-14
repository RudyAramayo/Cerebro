#ifndef ROBSurfaceStationarity_h
#define ROBSurfaceStationarity_h
#include "ROBDepthFloorRectification.h"
#include <string.h>

/* Bounded, measured stability in one unchanged display submap. This is a
 * preview target, never a collision/free-space or registration certificate.
 * Feed independent current-frame fits, BEFORE any visual smoothing. */
enum { ROBSurfaceStationarityCapacity = 12 };
typedef struct {
    ROBDepthFloorPoint positions[ROBSurfaceStationarityCapacity];
    double times[ROBSurfaceStationarityCapacity];
    unsigned count;
} ROBSurfaceStationarity;
typedef struct {
    bool ready;
    ROBDepthFloorPoint center;
    double spanSeconds, maxDeviationMeters, speedMetersPerSecond, lastMeasuredAt;
    unsigned observations;
} ROBSurfaceStationaryEvidence;

static inline void ROBSurfaceStationarityObserve(ROBSurfaceStationarity *s, ROBDepthFloorPoint p, double time) {
    if (!isfinite(time) || !isfinite(p.x) || !isfinite(p.y) || !isfinite(p.z)) return;
    if (s->count && time<=s->times[s->count-1]) return;
    if (s->count && time-s->times[s->count-1]>.6) s->count=0;
    // No camera frame-rate weighting or repeated mesh-build confirmations.
    if (s->count && time-s->times[s->count-1]<.099) return;
    while (s->count && (s->count==ROBSurfaceStationarityCapacity || time-s->times[0]>3)) {
        s->count--;
        memmove(s->positions,s->positions+1,s->count*sizeof(s->positions[0]));
        memmove(s->times,s->times+1,s->count*sizeof(s->times[0]));
    }
    s->positions[s->count]=p;s->times[s->count++]=time;
}
static inline ROBSurfaceStationaryEvidence ROBSurfaceStationarityEvaluate(const ROBSurfaceStationarity *s, double now) {
    ROBSurfaceStationaryEvidence e={0};e.observations=s->count;
    if (!s->count || !isfinite(now)) return e;
    e.lastMeasuredAt=s->times[s->count-1];e.spanSeconds=e.lastMeasuredAt-s->times[0];
    double meanTime=0;
    for (unsigned i=0;i<s->count;i++) {
        e.center.x+=s->positions[i].x/s->count;e.center.y+=s->positions[i].y/s->count;e.center.z+=s->positions[i].z/s->count;
        meanTime+=(s->times[i]-s->times[0])/s->count;
    }
    double timeVariance=0;ROBDepthFloorPoint covariance={0};
    for (unsigned i=0;i<s->count;i++) {
        ROBDepthFloorPoint delta=ROBDepthFloorSubtract(s->positions[i],e.center);
        e.maxDeviationMeters=fmax(e.maxDeviationMeters,sqrt(ROBDepthFloorDot(delta,delta)));
        double dt=s->times[i]-s->times[0]-meanTime;timeVariance+=dt*dt;
        covariance.x+=delta.x*dt;covariance.y+=delta.y*dt;covariance.z+=delta.z*dt;
    }
    e.speedMetersPerSecond=timeVariance>1e-12 ? sqrt(ROBDepthFloorDot(covariance,covariance))/timeVariance : INFINITY;
    e.ready=s->count>=5 && e.spanSeconds>=1 && now>=e.lastMeasuredAt && now-e.lastMeasuredAt<=.5 &&
        e.maxDeviationMeters<=.004 && e.speedMetersPerSecond<=.003;
    return e;
}
#endif
