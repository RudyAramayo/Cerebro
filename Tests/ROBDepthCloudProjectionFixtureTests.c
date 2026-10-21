#include "../Cerebro/ROBDepthCloudProjection.h"
#include <assert.h>
#include <stdio.h>
static int near(double a,double b) { return fabs(a-b)<1e-8; }
int main(void) {
    const double radians = acos(-1)/180;
    ROBDepthPoint mounts[4]={{0,.9,0},{0,1.03,0},{0,1.056,0},{0,1.18,-.09}};
    ROBDepthCloudTransform level=ROBDepthCloudMakeTransform(mounts,0,0,0,1.2,false);
    ROBDepthPoint p=ROBDepthCloudProject(level,0,-.2,1);
    assert(near(p.y,1.2*(1.18+.2)) && near(p.z,-1.2*1.09));
    ROBDepthCloudTransform down=ROBDepthCloudMakeTransform(mounts,0,0,-18*radians,1.2,false);
    ROBDepthPoint lowered=ROBDepthCloudProject(down,0,0,1);
    assert(lowered.y<ROBDepthCloudProject(level,0,0,1).y-.3);
    ROBDepthCloudTransform left=ROBDepthCloudMakeTransform(mounts,0,30*radians,0,1.2,false);
    assert(ROBDepthCloudProject(left,0,0,1).x<-.5);
    // A stationary world surface reprojects to the same place as the neck
    // moves: invert the optical rotation, then use the production transform.
    for(int i=0;i<21;i++) {
        double lower=(i-10)*radians,upper=(-18-i)*radians,pan=(i-10)*3*radians;
        ROBDepthCloudTransform t=ROBDepthCloudMakeTransform(mounts,lower,pan,upper,1.2,false);
        ROBDepthPoint world={.4,1.9,-1.8};
        double v[3]={world.x-t.m[3],world.y-t.m[7],world.z-t.m[11]},optical[3]={0};
        for(int c=0;c<3;c++) for(int r=0;r<3;r++) optical[c]+=t.m[r*4+c]*v[r]/(1.2*1.2);
        ROBDepthPoint rebuilt=ROBDepthCloudProject(t,optical[0],optical[1],optical[2]);
        assert(near(rebuilt.x,world.x)&&near(rebuilt.y,world.y)&&near(rebuilt.z,world.z));
    }
    ROBDepthCloudTransform belly=ROBDepthCloudMakeTransform(mounts,.8,.6,-.5,1.2,true);
    ROBDepthPoint body=ROBDepthCloudProject(belly,0,-.2,1);
    assert(near(body.y,p.y)&&near(body.z,p.z));
    assert(!ROBDepthCloudMakeTransform(mounts,NAN,0,0,1.2,false).valid);
    assert(!ROBDepthCloudMakeTransform(mounts,0,0,0,0,false).valid);
    puts("Depth cloud projection: URDF mount, shared scale, tilt/pan signs, stationary-surface round trips, fixed belly and invalid poses passed; no camera or actuator IO");
}
