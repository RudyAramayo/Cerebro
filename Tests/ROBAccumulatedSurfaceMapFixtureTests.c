#include "../Cerebro/ROBAccumulatedSurfaceMap.h"
#include <assert.h>
#include <stdio.h>
#include <time.h>

static size_t room(ROBSurfaceSample *p, bool hole) {
    size_t n=0;
    for (int x=0;x<60;x++) for (int z=0;z<50;z++) {
        if (hole && x>=20 && x<30 && z>=20 && z<30) continue;
        p[n++]=(ROBSurfaceSample){{-.6+(x+.5)*.02,.75,1+(z+.5)*.02},x<30 ? 0xD02010FF : 0x1030D0FF};
    }
    for (int x=0;x<60;x++) for (int y=0;y<60;y++)
        p[n++]=(ROBSurfaceSample){{-.6+(x+.5)*.02,(y+.5)*.02,2.5},0xA0B0C0FF};
    return n;
}
static size_t can(ROBSurfaceSample *p, double arc, bool noisy) {
    size_t n=0;
    for (int y=0;y<12;y++) for (int a=0;a<24;a++) {
        double angle=-arc/2+arc*a/23,r=.033+(noisy ? ((a*7+y*3)%7-3)*.0005 : 0);
        p[n++]=(ROBSurfaceSample){{.2+r*cos(angle),.75+.008+y*.009,1.5+r*sin(angle)},0xCC1020FF};
    }
    return n;
}
int main(void) {
    ROBSurfaceSample samples[10000];size_t n=room(samples,true);
    ROBSurfaceMap *m=ROBSurfaceMapCreate();assert(m);
    assert(ROBSurfaceMapIntegrate(m,samples,n,1,NULL,true));size_t voxels=m->count;
    ROBSurfaceMesh *mesh=ROBSurfaceMapBuildMesh(m);assert(mesh && !mesh->stableVoxelCount && !mesh->planeCount);ROBSurfaceMeshDestroy(mesh);
    assert(!ROBSurfaceMapIntegrate(m,samples,n,1,NULL,true) && m->frame==1 && m->count==voxels);
    assert(!ROBSurfaceMapIntegrate(m,samples,n,NAN,NULL,true));
    assert(ROBSurfaceMapIntegrate(m,samples,n,2,NULL,true) && m->count==voxels);
    clock_t start=clock();mesh=ROBSurfaceMapBuildMesh(m);double milliseconds=(double)(clock()-start)*1000/CLOCKS_PER_SEC;
    assert(mesh && mesh->planeCount==2 && mesh->stableVoxelCount==voxels);
    assert(mesh->quadCount<80 && mesh->quadCount*2<mesh->stableVoxelCount/20);
    bool sawHole=false,sawRed=false,sawBlue=false;
    for (size_t i=0;i<mesh->planeCount;i++) {
        ROBSurfacePlane *p=&mesh->planes[i];assert(p->rms<1e-6 && p->support>2000);
        if (p->normal.y<.99) continue;
        ROBSurfacePoint hole={-.1,.75,1.5};
        int x=(int)floor(ROBDepthFloorDot(p->u,hole)/ROBSurfaceTexelSize)-p->originU,
            y=(int)floor(ROBDepthFloorDot(p->v,hole)/ROBSurfaceTexelSize)-p->originV;
        assert(x>=0 && x<p->width && y>=0 && y<p->height && !p->rgba[(size_t)y*p->width+x]);
        for (size_t j=0;j<p->rectangleCount;j++) {
            ROBSurfaceRectangle r=p->rectangles[j];assert(!(x>=r.x && x<r.x+r.width && y>=r.y && y<r.y+r.height));
        }
        sawHole=true;
        for (int j=0;j<p->width*p->height;j++) {if (p->rgba[j]==0xD02010FF) sawRed=true;if(p->rgba[j]==0x1030D0FF) sawBlue=true;}
    }
    assert(sawHole && sawRed && sawBlue);size_t originalQuads=mesh->quadCount;ROBSurfaceMeshDestroy(mesh);
    /* Arbitrary planes, noise and outliers: the mesh is not restricted to
     * axis-aligned floor/table/wall special cases. Lines must not become faces. */
    ROBSurfaceSample oblique[2000];uint8_t used[2000]={0};size_t obliqueCount=0;
    for (int x=0;x<40;x++) for (int z=0;z<40;z++) {
        double px=-.4+x*.02,pz=1+z*.02;
        oblique[obliqueCount++]=(ROBSurfaceSample){{px,.6+.3*px+.2*pz+((x*17+z*3)%7-3)*.0005,pz},0xFFFFFFFF};
    }
    for (int i=0;i<300;i++) oblique[obliqueCount++]=(ROBSurfaceSample){{(i%17)*.1,(i%13)*.09,(i%11)*.13},0xFFFFFFFF};
    ROBSurfacePlane tilted={0};assert(ROBSurfaceFitPlane(oblique,used,obliqueCount,&tilted));
    ROBSurfacePoint expected=ROBDepthFloorScale((ROBSurfacePoint){-.3,1,-.2},1/sqrt(1.13));
    assert(ROBDepthFloorDot(tilted.normal,expected)>.999 && tilted.rms<.004);
    for (int i=0;i<200;i++) oblique[i]=(ROBSurfaceSample){{i*.01,.8,i*.01},0xFFFFFFFF};
    assert(!ROBSurfaceFitPlane(oblique,used,200,&tilted));
    /* A single dense frame cannot outweigh repeated, sparse observations. */
    ROBSurfaceSample dense[1000];for (int i=0;i<1000;i++) dense[i]=samples[0];
    dense[0].point.y+=.006;for (int i=1;i<1000;i++) dense[i]=dense[0];
    assert(ROBSurfaceMapIntegrate(m,dense,1000,3,NULL,false));
    int slot=ROBSurfaceFind(m,(int)floor(dense[0].point.x/.02),(int)floor(dense[0].point.y/.02),(int)floor(dense[0].point.z/.02),false);
    assert(slot>=0 && m->slots[slot].frames==3 && fabs(m->slots[slot].point.y-.752)<1e-9);
    /* A disjoint pose prior must leave the previous map/timestamp intact. */
    for (size_t i=0;i<n;i++) samples[i].point.x+=5;
    assert(!ROBSurfaceMapIntegrate(m,samples,n,4,NULL,true) && m->lastCapture==3);
    ROBSurfaceMapDestroy(m);

    n=can(samples,3.14159265358979323846,true);
    ROBSurfaceCylinder fit=ROBSurfaceFitCylinder(samples,n,.75,.033,.115);
    assert(fit.valid && fabs(fit.center.x-.2)<.002 && fabs(fit.center.z-1.5)<.002 && fit.observedArcRadians>3);
    assert(fit.support>=n*.9 && fit.rms<.002);
    n=can(samples,.5,false);assert(!ROBSurfaceFitCylinder(samples,n,.75,.033,.115).valid);
    n=can(samples,3.14159265358979323846,false);
    for (size_t i=0;i<n;i++) samples[i].point.z=1.5;
    assert(!ROBSurfaceFitCylinder(samples,n,.75,.033,.115).valid);
    n=can(samples,3.14159265358979323846,false);for (size_t i=0;i<n;i++) samples[i].point.y=.78;
    assert(!ROBSurfaceFitCylinder(samples,n,.75,.033,.115).valid);
    assert(!ROBSurfaceFitCylinder(samples,n,.75,NAN,.115).valid);

    /* Full integration of half-can + supporting table; inference cannot add
     * occupied voxels, and a small curved object must remain residual points. */
    m=ROBSurfaceMapCreate();n=room(samples,false);n+=can(samples+n,3.14159265358979323846,false);
    assert(ROBSurfaceMapIntegrate(m,samples,n,1,NULL,false));assert(ROBSurfaceMapIntegrate(m,samples,n,2,NULL,true));
    voxels=m->count;mesh=ROBSurfaceMapBuildMesh(m);
    assert(mesh && mesh->cylinderCount==1 && mesh->residualCount>=20 && m->count==voxels);
    assert(fabs(mesh->cylinders[0].center.x-.2)<.005);ROBSurfaceMeshDestroy(mesh);ROBSurfaceMapDestroy(m);

    /* Depth contradiction, occlusion and holes. A rigid optical -> Y-up view. */
    uint8_t depth[32*32*2];for (int i=0;i<32*32;i++) {depth[2*i]=0xD0;depth[2*i+1]=7;} /* 2000 mm */
    ROBSurfaceDepthView view={32,32,depth,30,30,16,16,{1,0,0,0,0,-1,0,0,0,0,-1,0}};
    assert(ROBSurfaceViewValid(&view));
    assert(ROBSurfaceContradicted((ROBSurfacePoint){0,0,-1},&view));
    assert(!ROBSurfaceContradicted((ROBSurfacePoint){0,0,-3},&view));
    depth[(16*32+16)*2]=0;depth[(16*32+16)*2+1]=0;
    assert(!ROBSurfaceContradicted((ROBSurfacePoint){0,0,-1},&view));depth[(16*32+16)*2]=0xD0;depth[(16*32+16)*2+1]=7;
    depth[(16*32+17)*2]=0xB8;depth[(16*32+17)*2+1]=0x0B; /* depth edge: 3000 mm */
    assert(!ROBSurfaceContradicted((ROBSurfacePoint){0,0,-1},&view));depth[(16*32+17)*2]=0xD0;depth[(16*32+17)*2+1]=7;
    ROBSurfaceDepthView scaled=view;scaled.cameraToMap[0]=2;assert(!ROBSurfaceViewValid(&scaled));
    m=ROBSurfaceMapCreate();for (int i=0;i<20;i++) samples[i]=(ROBSurfaceSample){{(i%5+1)*.001,(i/5+1)*.001,-1},0xFFFFFFFF};
    assert(ROBSurfaceMapIntegrate(m,samples,20,1,NULL,false));
    for (int i=0;i<20;i++) samples[i].point.z=-2;
    assert(ROBSurfaceMapIntegrate(m,samples,20,2,&view,false));assert(m->count==2);
    assert(ROBSurfaceMapIntegrate(m,samples,20,3,&view,false));assert(m->count==1);
    assert(ROBSurfaceMapIntegrate(m,samples,20,100,NULL,false) && m->count==1);
    ROBSurfaceMapDestroy(m);

    /* Negative coordinates, finite-input rejection, capacity, tombstone reuse. */
    m=ROBSurfaceMapCreate();
    for (int frame=1;frame<=5;frame++) {
        for (int i=0;i<10000;i++) samples[i]=(ROBSurfaceSample){{-5+(i%100+.5)*.021,-2+(i/100+.5)*.021,-frame*.1},0xFFFFFFFF};
        assert(ROBSurfaceMapIntegrate(m,samples,10000,frame,NULL,false));assert(m->count<=ROBSurfaceMaximumVoxels);
    }
    assert(m->count==ROBSurfaceMaximumVoxels && m->full);
    for (int i=0;i<10000;i++) samples[i].point.x=NAN;
    assert(!ROBSurfaceMapIntegrate(m,samples,10000,6,NULL,false) && m->lastCapture==5);
    n=room(samples,false);assert(ROBSurfaceMapIntegrate(m,samples,n,100,NULL,false));assert(m->count<10000);
    ROBSurfaceMapDestroy(m);
    printf("Surface map passed: distinct-frame voxel fusion, bounded history, observed holes/RGB textures, two room planes (%zu quads), visibility clearing, half-can completion/rejection, inference isolation; %.2f ms mesh extraction for 6500 samples.\n",originalQuads,milliseconds);
}
