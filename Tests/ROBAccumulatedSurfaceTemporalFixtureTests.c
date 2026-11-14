#include "../Cerebro/ROBAccumulatedSurfaceMap.h"
#include <assert.h>
#include <stdio.h>

static size_t scene(ROBSurfaceSample *samples,int frame,int canMode) {
    size_t n=0;
    for (int x=0;x<55;x++) for (int z=0;z<45;z++) {
        double noise=sin(frame*.3+x*.7+z*.4)*.0015;
        samples[n++]=(ROBSurfaceSample){{-.5+(x+.5)*.02,.75+noise,1+(z+.5)*.02},0xA07840FF};
    }
    if (!canMode) return n;
    for (int y=0;y<12;y++) for (int a=0;a<24;a++) {
        /* Partial views cannot pass a fresh full-cylinder fit. Existing tracks
         * must use current side evidence rather than disappear each update. */
        if (canMode==2 && (a%4 || y%2)) continue;
        double angle=canMode==2 ? -.3+.6*a/23 : -1.57+3.14*a/23;
        double radius=.033+sin(frame*.8+a*.7+y*.4)*.0018;
        samples[n++]=(ROBSurfaceSample){{.2+radius*cos(angle),.758+y*.009,1.5+radius*sin(angle)},0xCC1020FF};
    }
    return n;
}
int main(void) {
    ROBSurfaceMap *map=ROBSurfaceMapCreate();assert(map);ROBSurfaceSample samples[6000];
    uint32_t planeID=0,canID=0;ROBSurfacePoint normal={0},u={0},v={0};double offset=0,maxDrift=0;
    size_t trackedFrames=0;
    for (int frame=1;frame<=80;frame++) {
        int mode=(frame>5 && frame%5!=0) ? 2 : 1;
        size_t count=scene(samples,frame,mode);
        assert(ROBSurfaceMapIntegrate(map,samples,count,frame*.2,NULL,true));
        ROBSurfaceMesh *mesh=ROBSurfaceMapBuildMesh(map);assert(mesh);
        if (frame>=2) {
            assert(mesh->planeCount==1 && mesh->cylinderCount==1);
            ROBSurfacePlane *plane=&mesh->planes[0];ROBSurfaceCylinder can=mesh->cylinders[0];
            if (!planeID) {planeID=plane->trackID;normal=plane->normal;u=plane->u;v=plane->v;offset=plane->offset;canID=can.trackID;}
            assert(planeID==plane->trackID && canID==can.trackID);
            assert(!memcmp(&normal,&plane->normal,sizeof(normal)) && !memcmp(&u,&plane->u,sizeof(u)) &&
                !memcmp(&v,&plane->v,sizeof(v)) && offset==plane->offset);
            double drift=sqrt(ROBSurfaceDistance2(can.center,(ROBSurfacePoint){.2,.8075,1.5}));
            if (drift>maxDrift) maxDrift=drift;assert(drift<.005);trackedFrames++;
        }
        ROBSurfaceMeshDestroy(mesh);
    }
    /* A brief complete occlusion coasts; new evidence keeps the same identity. */
    for (int frame=81;frame<=86;frame++) {
        size_t count=scene(samples,frame,0);assert(ROBSurfaceMapIntegrate(map,samples,count,frame*.2,NULL,true));
        ROBSurfaceMesh *mesh=ROBSurfaceMapBuildMesh(map);assert(mesh->cylinderCount==1 && mesh->cylinders[0].trackID==canID);
        assert(mesh->cylinders[0].observedAgeSeconds>0);ROBSurfaceMeshDestroy(mesh);
    }
    size_t count=scene(samples,87,1);assert(ROBSurfaceMapIntegrate(map,samples,count,87*.2,NULL,true));
    ROBSurfaceMesh *mesh=ROBSurfaceMapBuildMesh(map);assert(mesh->cylinderCount==1 && mesh->cylinders[0].trackID==canID);ROBSurfaceMeshDestroy(mesh);
    /* A genuine lack of evidence must eventually retire an inferred object. */
    for (int frame=88;frame<=105;frame++) {
        count=scene(samples,frame,0);assert(ROBSurfaceMapIntegrate(map,samples,count,frame*.2,NULL,true));
        mesh=ROBSurfaceMapBuildMesh(map);if (frame==105) assert(!mesh->cylinderCount);ROBSurfaceMeshDestroy(mesh);
    }
    ROBSurfaceMapDestroy(map);
    /* Positive see-through evidence removes an old model before its time limit. */
    map=ROBSurfaceMapCreate();
    for (int frame=1;frame<=3;frame++) {
        count=scene(samples,frame,1);assert(ROBSurfaceMapIntegrate(map,samples,count,frame*.2,NULL,true));
        mesh=ROBSurfaceMapBuildMesh(map);ROBSurfaceMeshDestroy(mesh);
    }
    uint8_t depth[64*64*2];for (int i=0;i<64*64;i++) {depth[i*2]=0xD0;depth[i*2+1]=7;}
    ROBSurfaceDepthView view={64,64,depth,45,45,32,32,{1,0,0,.2,0,1,0,.8,0,0,1,0}};
    for (int frame=4;frame<=5;frame++) {
        count=scene(samples,frame,0);assert(ROBSurfaceMapIntegrate(map,samples,count,frame*.2,&view,true));
        mesh=ROBSurfaceMapBuildMesh(map);if (frame==5) assert(!mesh->cylinderCount);ROBSurfaceMeshDestroy(mesh);
    }
    ROBSurfaceMapDestroy(map);
    printf("Temporal reconstruction passed: %zu consecutive visible frames, zero can ID/dropout transitions, frozen plane UV axes under depth noise, %.2f mm maximum centre drift, partial fits, brief occlusion/reacquisition, bounded expiry and two-frame see-through removal.\n",trackedFrames,maxDrift*1000);
}
