#include <stdbool.h>
#include <stdlib.h>
static bool failNextSurfaceAllocation;
static void *fixtureSurfaceCalloc(size_t count, size_t size) {
    if (failNextSurfaceAllocation) { failNextSurfaceAllocation=false;return NULL; }
    return calloc(count,size);
}
#define calloc fixtureSurfaceCalloc
#include "../Cerebro/ROBAccumulatedSurfaceMap.h"
#undef calloc
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
static void sameVoxel(const ROBSurfaceVoxel *a, const ROBSurfaceVoxel *b) {
    assert(a->x==b->x && a->y==b->y && a->z==b->z && a->state==b->state);
    assert(a->frames==b->frames && a->misses==b->misses && a->pendingCount==b->pendingCount);
    assert(a->pendingFrame==b->pendingFrame && a->lastSeen==b->lastSeen);
    assert(a->point.x==b->point.x && a->point.y==b->point.y && a->point.z==b->point.z);
    assert(a->pendingSum.x==b->pendingSum.x && a->pendingSum.y==b->pendingSum.y && a->pendingSum.z==b->pendingSum.z);
    for (int c=0;c<3;c++) assert(a->rgb[c]==b->rgb[c] && a->pendingRGB[c]==b->pendingRGB[c]);
}
static void churn(void) {
    ROBSurfaceMap *m=ROBSurfaceMapCreate();assert(m);
    ROBSurfaceSample input[1000];uint32_t random=0x719304a1;
    size_t compactions=0,peakTombstones=0,peakSlots=0;clock_t start=clock();
    for (unsigned frame=1;frame<=199;frame++) {
        /* These200 voxels persist. The other800 observations change each
         * frame and expire after two46-second intervals. All199 captures use
         * the real overlap/expiry/integration path, with at least20% overlap. */
        for (int i=0;i<200;i++) input[i]=(ROBSurfaceSample){{-.9+(i%20+.5)*.02,.75,1+(i/20+.5)*.02},0xD02010FF};
        for (int i=200;i<1000;i++) {
            double x=-11+(ROBSurfaceRandom(&random)%1100+.5)*.02;
            double y=-5+(ROBSurfaceRandom(&random)%500+.5)*.02;
            double z=-11+(ROBSurfaceRandom(&random)%1100+.5)*.02;
            input[i]=(ROBSurfaceSample){{x,y,z},0x336699FF};
        }
        ROBSurfaceVoxel *previous=m->slots;
        assert(ROBSurfaceMapIntegrate(m,input,1000,frame*46.0,NULL,true));
        if (m->slots!=previous) compactions++;
        size_t live=0,tombstones=0;
        for (size_t i=0;i<ROBSurfaceSlotCount;i++) {
            if (m->slots[i].state==1) live++;
            if (m->slots[i].state==2) tombstones++;
        }
        assert(live==m->count && tombstones==m->tombstones && live>=200 && live<=1800);
        assert(tombstones<ROBSurfaceMaximumTombstones && (tombstones<512 || tombstones<=live));
        if (tombstones>peakTombstones) peakTombstones=tombstones;
        if (live+tombstones>peakSlots) peakSlots=live+tombstones;
        int slot=ROBSurfaceFind(m,(int)floor(input[0].point.x/.02),(int)floor(input[0].point.y/.02),(int)floor(input[0].point.z/.02),false);
        assert(slot>=0);const ROBSurfaceVoxel *v=&m->slots[slot];
        assert(v->frames==frame && v->pendingFrame==frame && v->pendingCount==1 && v->misses==0);
        assert(fabs(v->point.x-input[0].point.x)<1e-12 && fabs(v->point.y-.75)<1e-12 && fabs(v->point.z-input[0].point.z)<1e-12);
        assert(fabs(v->rgb[0]-208)<1e-10 && fabs(v->rgb[1]-32)<1e-10 && fabs(v->rgb[2]-16)<1e-10);
        assert(v->lastSeen==frame*46.0 && m->lastCapture==frame*46.0 && m->frame==frame && !m->full);
    }
    assert(compactions>50 && m->tombstones>0);
    /* Sparse but nonempty compaction must preserve EVERY live voxel field,
     * including its completed pending fields, and all map history metadata. */
    size_t count=m->count,n=0;ROBSurfaceVoxel *saved=calloc(count,sizeof(*saved));assert(saved);
    for (size_t i=0;i<ROBSurfaceSlotCount;i++) if (m->slots[i].state==1) saved[n++]=m->slots[i];
    uint64_t frame=m->frame;double captured=m->lastCapture;bool full=m->full;
    /* The next expiry needs a nonempty rehash. Its allocation failure must
     * reject the entire capture without changing any slot or map metadata. */
    void *mapState=malloc(sizeof(*m));assert(mapState);memcpy(mapState,m,sizeof(*m));
    failNextSurfaceAllocation=true;
    assert(!ROBSurfaceMapIntegrate(m,input,1000,200*46.0,NULL,true) && !failNextSurfaceAllocation);
    assert(memcmp(mapState,m,sizeof(*m))==0);free(mapState);
    for (size_t i=0;i<n;i++) {
        int slot=ROBSurfaceFind(m,saved[i].x,saved[i].y,saved[i].z,false);assert(slot>=0);sameVoxel(&saved[i],&m->slots[slot]);
    }
    assert(ROBSurfaceMapCompact(m) && !m->tombstones && m->count==count);
    assert(m->frame==frame && m->lastCapture==captured && m->full==full);
    for (size_t i=0;i<n;i++) {
        int slot=ROBSurfaceFind(m,saved[i].x,saved[i].y,saved[i].z,false);assert(slot>=0);sameVoxel(&saved[i],&m->slots[slot]);
    }
    free(saved);
    /* A subsequent update must collect NEW touched indices after rehash. */
    assert(ROBSurfaceMapIntegrate(m,input,1000,200*46.0,NULL,true));
    int slot=ROBSurfaceFind(m,(int)floor(input[0].point.x/.02),(int)floor(input[0].point.y/.02),(int)floor(input[0].point.z/.02),false);
    assert(slot>=0 && m->slots[slot].frames==200 && m->slots[slot].pendingFrame==200 && m->slots[slot].lastSeen==9200);
    printf("Surface churn passed:199000 actual samples, %zu rehashes, peak%zu tombstones/%zu nonempty slots; sparse voxel metadata preserved; %.2fms.\n",
           compactions,peakTombstones,peakSlots,1000.0*(clock()-start)/CLOCKS_PER_SEC);
    ROBSurfaceMapDestroy(m);
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
    n=room(samples,false);assert(ROBSurfaceMapIntegrate(m,samples,n,100,NULL,false));
    assert(m->count<10000 && !m->tombstones && m->full && m->frame==6 && m->lastCapture==100);
    ROBSurfaceMapDestroy(m);
    churn();
    printf("Surface map passed: distinct-frame voxel fusion, bounded history, observed holes/RGB textures, two room planes (%zu quads), visibility clearing, half-can completion/rejection, inference isolation; %.2f ms mesh extraction for 6500 samples.\n",originalQuads,milliseconds);
}
