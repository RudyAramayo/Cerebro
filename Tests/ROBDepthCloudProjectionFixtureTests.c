#include "../Cerebro/ROBDepthCloudProjection.h"
#include <assert.h>
#include <stdio.h>
static int near(double a,double b) { return fabs(a-b)<1e-8; }
int main(void) {
    // Known optical right/down/forward basis at level, with shared 1.2 scale.
    double rows[12]={1.2,0,0,0, 0,-1.2,0,1.416, 0,0,-1.2,-.108};
    ROBDepthCloudTransform level=ROBDepthCloudMakeTransform(rows);
    assert(level.valid);
    ROBDepthPoint p=ROBDepthCloudProject(level,0,-.2,1);
    assert(near(p.y,1.656) && near(p.z,-1.308));
    // Round-trip independent optical samples through rigid camera poses.
    for(int i=0;i<21;i++) {
        double angle=(i-10)*acos(-1)/60, c=cos(angle)*1.2, s=sin(angle)*1.2;
        double pose[12]={c,0,s,.1, 0,-1.2,0,1.4, s,0,-c,-.2};
        ROBDepthCloudTransform t=ROBDepthCloudMakeTransform(pose);
        assert(t.valid);
        ROBDepthPoint world={.4,1.9,-1.8};
        double v[3]={world.x-t.m[3],world.y-t.m[7],world.z-t.m[11]},optical[3]={0};
        for(int col=0;col<3;col++) for(int r=0;r<3;r++) optical[col]+=t.m[r*4+col]*v[r]/1.44;
        ROBDepthPoint rebuilt=ROBDepthCloudProject(t,optical[0],optical[1],optical[2]);
        assert(near(rebuilt.x,world.x)&&near(rebuilt.y,world.y)&&near(rebuilt.z,world.z));
    }
    rows[0]=NAN;
    assert(!ROBDepthCloudMakeTransform(rows).valid);
    double zero[12]={0};
    assert(!ROBDepthCloudMakeTransform(zero).valid && !ROBDepthCloudMakeTransform(NULL).valid);
    puts("Depth affine projection: optical axes, shared scale, stationary-surface round trips and invalid transforms passed; no camera or actuator IO");
}
