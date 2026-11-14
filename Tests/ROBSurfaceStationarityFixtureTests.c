#include "../Cerebro/ROBSurfaceStationarity.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    ROBSurfaceStationarity stable={0};ROBSurfaceStationaryEvidence e={0};
    for (int i=0;i<16;i++) {
        ROBSurfaceStationarityObserve(&stable,(ROBDepthFloorPoint){.5+sin(i)*.0015,.75,1.3+cos(i)*.0015},i*.2);
        e=ROBSurfaceStationarityEvaluate(&stable,i*.2);
        if (i<5) assert(!e.ready);if (i>=5) assert(e.ready);
    }
    assert(stable.count==12 && e.maxDeviationMeters<.002 && e.speedMetersPerSecond<.001);
    unsigned count=stable.count;double last=stable.times[count-1];
    ROBSurfaceStationarityObserve(&stable,(ROBDepthFloorPoint){9,9,9},last);
    ROBSurfaceStationarityObserve(&stable,(ROBDepthFloorPoint){9,9,9},last-.1);
    ROBSurfaceStationarityObserve(&stable,(ROBDepthFloorPoint){NAN,0,0},last+.1);
    ROBSurfaceStationarityObserve(&stable,(ROBDepthFloorPoint){0,0,0},INFINITY);
    assert(stable.count==count && stable.times[count-1]==last);
    assert(!ROBSurfaceStationarityEvaluate(&stable,last+.501).ready);
    assert(!ROBSurfaceStationarityEvaluate(&stable,last-.001).ready);
    // Movement too slow for a 5cm pairwise agreement gate still fails here.
    for (int scenario=0;scenario<3;scenario++) {
        ROBSurfaceStationarity moving={0};
        for (int i=0;i<25;i++) {
            double x=scenario==0 ? i*.2*.006 : scenario==1 ? sin(i*1.4)*.012 : (i<12 ? 0:.035);
            ROBSurfaceStationarityObserve(&moving,(ROBDepthFloorPoint){x,.75,1.3},i*.2);
            e=ROBSurfaceStationarityEvaluate(&moving,i*.2);
            if (scenario<2 || (i>=12 && i<23)) assert(!e.ready);
        }
        if (scenario==2) assert(e.ready); // genuinely re-established stationary location
    }
    ROBSurfaceStationarityObserve(&stable,(ROBDepthFloorPoint){.5,.75,1.3},last+1);
    assert(stable.count==1 && !ROBSurfaceStationarityEvaluate(&stable,last+1).ready);
    // High-rate duplicate evidence cannot satisfy the one-second window.
    ROBSurfaceStationarity burst={0};
    for(int i=0;i<100;i++) ROBSurfaceStationarityObserve(&burst,(ROBDepthFloorPoint){0,0,0},i*.0001);
    assert(burst.count==1 && !ROBSurfaceStationarityEvaluate(&burst,.01).ready);
    puts("Stationarity passed: bounded noisy stable window, minimum duration, 6mm/s drift, oscillation, abrupt relocation/reacquisition, gaps, expiry, duplicates, invalid values and high-rate burst rejection.");
}
