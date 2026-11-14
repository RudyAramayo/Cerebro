#ifndef ROBAccumulatedSurfaceMap_h
#define ROBAccumulatedSurfaceMap_h

#include "ROBDepthFloorRectification.h"
#include <stdlib.h>
#include <string.h>

/* A bounded, session-only DISPLAY submap in metres, Y up. This is neither
 * occupancy/free-space evidence nor SLAM or camera/arm registration. Each
 * camera owns a separate map. Completed primitives never enter the voxels. */
enum { ROBSurfaceSlotCount = 65536, ROBSurfaceMaximumVoxels = 32000,
       ROBSurfaceMaximumInput = 20000, ROBSurfaceMaximumPlanes = 6,
       ROBSurfaceMaximumQuads = 2048, ROBSurfaceMaximumResiduals = 4000,
       ROBSurfaceMaximumTombstones = ROBSurfaceSlotCount/8 };
static const double ROBSurfaceVoxelSize = .02;
static const double ROBSurfaceTexelSize = .04;
typedef ROBDepthFloorPoint ROBSurfacePoint;
typedef struct { ROBSurfacePoint point; uint32_t rgba; } ROBSurfaceSample;
typedef struct {
    int16_t x, y, z;
    uint8_t state; /* empty, occupied, tombstone */
    uint16_t frames, misses;
    uint32_t pendingCount;
    uint64_t pendingFrame;
    double lastSeen;
    ROBSurfacePoint point, pendingSum;
    double rgb[3], pendingRGB[3];
} ROBSurfaceVoxel;
typedef struct {
    int width, height;
    const uint8_t *depthLittleEndian;
    double fx, fy, cx, cy;
    double cameraToMap[12]; /* Rigid row-major optical -> submap, NO scale. */
} ROBSurfaceDepthView;
typedef struct { uint16_t x, y, width, height; } ROBSurfaceRectangle;
typedef struct {
    ROBSurfacePoint normal, u, v;
    ROBSurfacePoint centroid;
    uint32_t trackID;
    double offset;
    int originU, originV, width, height;
    uint32_t *rgba;
    ROBSurfaceRectangle *rectangles;
    size_t rectangleCount, support;
    double rms;
} ROBSurfacePlane;
typedef struct {
    bool valid;
    ROBSurfacePoint center;
    ROBSurfacePoint axis;
    double radius, height, rms, observedArcRadians;
    double observedAgeSeconds;
    uint32_t trackID;
    size_t support;
} ROBSurfaceCylinder;
typedef struct {
    bool valid;
    uint32_t id;
    ROBSurfacePoint normal, u, v;
    ROBSurfacePoint centroid;
    double offset, lastSeen;
    uint64_t lastFrame;
    unsigned fits;
} ROBSurfacePlaneTrack;
typedef struct {
    ROBSurfaceCylinder cylinder;
    double lastSeen;
    unsigned contradictions;
} ROBSurfaceCylinderTrack;
typedef struct {
    ROBSurfaceVoxel *slots;
    ROBSurfaceSample *recentSamples; /* Two raw frames; small objects retain detail. */
    size_t recentCounts[2];
    double recentTimes[2];
    unsigned recentIndex;
    ROBSurfacePlaneTrack planeTracks[12];
    ROBSurfaceCylinderTrack cylinderTracks[4];
    uint32_t nextTrackID;
    uint32_t touched[ROBSurfaceMaximumInput];
    size_t count, tombstones;
    uint64_t frame;
    double lastCapture;
    bool full;
} ROBSurfaceMap;
typedef struct {
    ROBSurfacePlane planes[ROBSurfaceMaximumPlanes];
    size_t planeCount, quadCount, stableVoxelCount;
    ROBSurfaceSample residuals[ROBSurfaceMaximumResiduals];
    size_t residualCount;
    ROBSurfaceCylinder cylinders[4];
    size_t cylinderCount;
    bool truncated;
} ROBSurfaceMesh;

static inline ROBSurfacePoint ROBSurfaceAdd(ROBSurfacePoint a, ROBSurfacePoint b) {
    return (ROBSurfacePoint){a.x+b.x, a.y+b.y, a.z+b.z};
}
static inline double ROBSurfaceDistance2(ROBSurfacePoint a, ROBSurfacePoint b) {
    ROBSurfacePoint d = ROBDepthFloorSubtract(a,b); return ROBDepthFloorDot(d,d);
}
static inline uint32_t ROBSurfaceHash(int x, int y, int z) {
    return ((uint32_t)x*73856093u ^ (uint32_t)y*19349663u ^ (uint32_t)z*83492791u) & (ROBSurfaceSlotCount-1);
}
static inline ROBSurfaceMap *ROBSurfaceMapCreate(void) {
    ROBSurfaceMap *m = calloc(1,sizeof(*m));
    if (m) m->slots = calloc(ROBSurfaceSlotCount,sizeof(*m->slots));
    if (m) m->recentSamples=calloc(2*ROBSurfaceMaximumInput,sizeof(*m->recentSamples));
    if (m && (!m->slots || !m->recentSamples)) { free(m->slots);free(m->recentSamples);free(m);return NULL; }
    return m;
}
static inline void ROBSurfaceMapDestroy(ROBSurfaceMap *m) { if (m) { free(m->slots);free(m->recentSamples);free(m); } }
static inline int ROBSurfaceFind(const ROBSurfaceMap *m, int x, int y, int z, bool insert) {
    uint32_t start = ROBSurfaceHash(x,y,z); int tombstone = -1;
    for (uint32_t probe=0;probe<ROBSurfaceSlotCount;probe++) {
        uint32_t slot = (start+probe)&(ROBSurfaceSlotCount-1);
        const ROBSurfaceVoxel *v = &m->slots[slot];
        if (!v->state) return insert ? (tombstone >= 0 ? tombstone : (int)slot) : -1;
        if (v->state == 2 && tombstone < 0) tombstone = (int)slot;
        if (v->state == 1 && v->x == x && v->y == y && v->z == z) return (int)slot;
    }
    return insert ? tombstone : -1;
}
static inline bool ROBSurfacePointValid(ROBSurfacePoint p) {
    return ROBDepthFloorFinite(p) && fabs(p.x) <= 12 && fabs(p.y) <= 6 && fabs(p.z) <= 12;
}
static inline bool ROBSurfaceViewValid(const ROBSurfaceDepthView *v) {
    if (!v || !v->depthLittleEndian || v->width < 3 || v->height < 3 || v->width > 8192 || v->height > 8192 ||
        !isfinite(v->fx) || !isfinite(v->fy) || v->fx <= 0 || v->fy <= 0 ||
        !isfinite(v->cx) || !isfinite(v->cy) || v->cx < 0 || v->cy < 0 || v->cx >= v->width || v->cy >= v->height) return false;
    for (int i=0;i<12;i++) if (!isfinite(v->cameraToMap[i])) return false;
    ROBSurfacePoint a={v->cameraToMap[0],v->cameraToMap[4],v->cameraToMap[8]},
        b={v->cameraToMap[1],v->cameraToMap[5],v->cameraToMap[9]}, c={v->cameraToMap[2],v->cameraToMap[6],v->cameraToMap[10]};
    return fabs(ROBDepthFloorDot(a,a)-1)+fabs(ROBDepthFloorDot(b,b)-1)+fabs(ROBDepthFloorDot(c,c)-1) < .002 &&
        fabs(ROBDepthFloorDot(a,b))+fabs(ROBDepthFloorDot(a,c))+fabs(ROBDepthFloorDot(b,c)) < .002 &&
        ROBDepthFloorDot(ROBDepthFloorCross(a,b),c) > .999;
}
/* Only clear a previously seen surface when a fresh, locally consistent depth
 * image sees THROUGH its location. Occlusion, holes and edges never clear it. */
static inline bool ROBSurfaceContradicted(ROBSurfacePoint p, const ROBSurfaceDepthView *v) {
    if (!v) return false;
    const double *m=v->cameraToMap;
    double dx=p.x-m[3],dy=p.y-m[7],dz=p.z-m[11];
    double z=m[2]*dx+m[6]*dy+m[10]*dz;
    if (z < .15 || z > 6) return false;
    double px=v->fx*(m[0]*dx+m[4]*dy+m[8]*dz)/z+v->cx,
        py=v->fy*(m[1]*dx+m[5]*dy+m[9]*dz)/z+v->cy;
    if (px < 1 || px >= v->width-1 || py < 1 || py >= v->height-1) return false;
    int x=(int)lround(px),y=(int)lround(py),low=65535,high=0;
    if (x < 1 || x >= v->width-1 || y < 1 || y >= v->height-1) return false;
    for (int j=-1;j<=1;j++) for (int i=-1;i<=1;i++) {
        size_t index=((size_t)(y+j)*v->width+(x+i))*2;
        int mm=v->depthLittleEndian[index] | ((int)v->depthLittleEndian[index+1]<<8);
        if (mm < 150 || mm > 6000) return false;
        if (mm < low) low=mm; if (mm > high) high=mm;
    }
    return high-low <= 30 && (double)low/1000-z > .06;
}
static inline bool ROBSurfaceNeedsCompaction(size_t count, size_t tombstones) {
    return tombstones && (!count || tombstones >= ROBSurfaceMaximumTombstones ||
                          (tombstones >= 512 && tombstones > count));
}
/* Rehash only between completed frame updates: touched[] contains slot indices
 * while a frame is pending. Copy whole surviving voxels, including all sample
 * weights/times and pending fields. Never reset the historical full flag. */
static inline bool ROBSurfaceMapRebuild(ROBSurfaceMap *m, const uint8_t *actions, size_t remaining) {
    if (!remaining) {
        memset(m->slots,0,ROBSurfaceSlotCount*sizeof(*m->slots));m->count=0;m->tombstones=0;return true;
    }
    ROBSurfaceVoxel *slots=calloc(ROBSurfaceSlotCount,sizeof(*slots));
    if (!slots) return false;
    for (size_t i=0;i<ROBSurfaceSlotCount;i++) if (m->slots[i].state==1 && (!actions || actions[i]!=2)) {
        ROBSurfaceVoxel voxel=m->slots[i];
        if (actions) voxel.misses=actions[i] ? (uint16_t)(voxel.misses+1) : 0;
        uint32_t start=ROBSurfaceHash(voxel.x,voxel.y,voxel.z),probe=0;
        while (probe<ROBSurfaceSlotCount && slots[(start+probe)&(ROBSurfaceSlotCount-1)].state) probe++;
        if (probe==ROBSurfaceSlotCount) { free(slots);return false; }
        slots[(start+probe)&(ROBSurfaceSlotCount-1)]=voxel;
    }
    free(m->slots);m->slots=slots;m->count=remaining;m->tombstones=0;return true;
}
static inline bool ROBSurfaceMapCompact(ROBSurfaceMap *m) {
    return !m->tombstones || ROBSurfaceMapRebuild(m,NULL,m->count);
}
/* Stage expiry before changing voxels. If a required bounded rehash cannot be
 * allocated, reject the frame without partially changing its history. */
static inline bool ROBSurfaceMapExpire(ROBSurfaceMap *m, double capturedAt, const ROBSurfaceDepthView *view) {
    uint8_t actions[ROBSurfaceSlotCount];size_t removed=0;
    for (size_t i=0;i<ROBSurfaceSlotCount;i++) if (m->slots[i].state==1) {
        const ROBSurfaceVoxel *v=&m->slots[i];bool contradicted=ROBSurfaceContradicted(v->point,view);
        bool expired=capturedAt-v->lastSeen>90 || (contradicted && (uint32_t)v->misses+1>=2);
        actions[i]=expired ? 2 : (contradicted ? 1 : 0);if (expired) removed++;
    }
    size_t remaining=m->count-removed,tombstones=m->tombstones+removed;
    if (ROBSurfaceNeedsCompaction(remaining,tombstones)) return ROBSurfaceMapRebuild(m,actions,remaining);
    for (size_t i=0;i<ROBSurfaceSlotCount;i++) if (m->slots[i].state==1) {
        ROBSurfaceVoxel *v=&m->slots[i];
        if (actions[i]==2) v->state=2;
        else v->misses=actions[i] ? (uint16_t)(v->misses+1) : 0;
    }
    m->count=remaining;m->tombstones=tombstones;return true;
}
static inline uint32_t ROBSurfaceColor(const ROBSurfaceVoxel *v) {
    return ((uint32_t)lround(fmin(255,fmax(0,v->rgb[0])))<<24) |
        ((uint32_t)lround(fmin(255,fmax(0,v->rgb[1])))<<16) |
        ((uint32_t)lround(fmin(255,fmax(0,v->rgb[2])))<<8) | 255u;
}
/* Pose-prior overlap is a consistency gate, not an estimated registration.
 * Reject a new view without sufficient overlap instead of smearing the map.
 * Separate, non-overlapping views need a fresh submap or a real SLAM pose. */
static inline bool ROBSurfaceOverlap(const ROBSurfaceMap *m, const ROBSurfaceSample *samples, size_t count) {
    if (m->count < 100 || m->frame < 2) return true;
    size_t tested=0,hits=0; double sum=0;
    size_t step=count/1500+1;
    for (size_t i=0;i<count;i+=step) {
        ROBSurfacePoint p=samples[i].point;
        if (!ROBSurfacePointValid(p)) continue;
        tested++; int x=(int)floor(p.x/ROBSurfaceVoxelSize),y=(int)floor(p.y/ROBSurfaceVoxelSize),z=(int)floor(p.z/ROBSurfaceVoxelSize);
        double best=.04*.04;
        for (int a=-1;a<=1;a++) for (int b=-1;b<=1;b++) for (int c=-1;c<=1;c++) {
            int slot=ROBSurfaceFind(m,x+a,y+b,z+c,false);
            if (slot >= 0) { double d=ROBSurfaceDistance2(p,m->slots[slot].point); if (d < best) best=d; }
        }
        if (best < .04*.04) { hits++; sum+=best; }
    }
    return hits >= 60 && hits >= tested*.15 && sqrt(sum/(double)hits) <= .025;
}
static inline bool ROBSurfaceMapIntegrate(ROBSurfaceMap *m, const ROBSurfaceSample *samples, size_t count,
                                         double capturedAt, const ROBSurfaceDepthView *view, bool checkOverlap) {
    if (!m || !samples || !count || count > ROBSurfaceMaximumInput || !isfinite(capturedAt) ||
        capturedAt <= m->lastCapture || (view && !ROBSurfaceViewValid(view))) return false;
    size_t valid=0; for (size_t i=0;i<count;i++) if (ROBSurfacePointValid(samples[i].point)) valid++;
    if (valid < 20 ||
        (ROBSurfaceNeedsCompaction(m->count,m->tombstones) && !ROBSurfaceMapCompact(m)) ||
        (checkOverlap && !ROBSurfaceOverlap(m,samples,count)) || !ROBSurfaceMapExpire(m,capturedAt,view)) return false;
    m->lastCapture=capturedAt; m->frame++;
    size_t touched=0;
    for (size_t i=0;i<count;i++) {
        ROBSurfacePoint p=samples[i].point; if (!ROBSurfacePointValid(p)) continue;
        int x=(int)floor(p.x/ROBSurfaceVoxelSize),y=(int)floor(p.y/ROBSurfaceVoxelSize),z=(int)floor(p.z/ROBSurfaceVoxelSize);
        int slot=ROBSurfaceFind(m,x,y,z,true); if (slot < 0) { m->full=true; continue; }
        ROBSurfaceVoxel *v=&m->slots[slot];
        if (v->state != 1) {
            if (m->count >= ROBSurfaceMaximumVoxels) { m->full=true; continue; }
            if (v->state==2) m->tombstones--;
            memset(v,0,sizeof(*v)); v->state=1; v->x=(int16_t)x; v->y=(int16_t)y; v->z=(int16_t)z; m->count++;
        }
        if (v->pendingFrame != m->frame) {
            v->pendingFrame=m->frame; v->pendingCount=0; v->pendingSum=(ROBSurfacePoint){0,0,0};
            memset(v->pendingRGB,0,sizeof(v->pendingRGB)); m->touched[touched++]=(uint32_t)slot;
        }
        v->pendingCount++; v->pendingSum=ROBSurfaceAdd(v->pendingSum,p);
        v->pendingRGB[0]+=(samples[i].rgba>>24)&255; v->pendingRGB[1]+=(samples[i].rgba>>16)&255; v->pendingRGB[2]+=(samples[i].rgba>>8)&255;
    }
    for (size_t i=0;i<touched;i++) {
        ROBSurfaceVoxel *v=&m->slots[m->touched[i]];
        double weight=1.0/fmin((double)v->frames+1,32), n=v->pendingCount;
        v->point=ROBSurfaceAdd(ROBDepthFloorScale(v->point,1-weight),ROBDepthFloorScale(v->pendingSum,weight/n));
        for (int c=0;c<3;c++) v->rgb[c]=v->rgb[c]*(1-weight)+v->pendingRGB[c]*weight/n;
        if (v->frames < UINT16_MAX) v->frames++; v->lastSeen=capturedAt; v->misses=0;
    }
    m->recentIndex=(m->recentIndex+1)%2;
    memcpy(m->recentSamples+m->recentIndex*ROBSurfaceMaximumInput,samples,count*sizeof(*samples));
    m->recentCounts[m->recentIndex]=count;m->recentTimes[m->recentIndex]=capturedAt;
    for (int i=0;i<4;i++) {
        ROBSurfaceCylinderTrack *t=&m->cylinderTracks[i];if (!t->cylinder.valid) continue;
        unsigned through=0;
        for (int j=-1;j<=1;j++) if (ROBSurfaceContradicted(ROBSurfaceAdd(t->cylinder.center,
            ROBDepthFloorScale(t->cylinder.axis,j*t->cylinder.height*.25)),view)) through++;
        t->contradictions=through>=2 ? t->contradictions+1 : 0;
        if (t->contradictions>=2) t->cylinder.valid=false;
    }
    return true;
}

/* Smallest covariance eigenvector, with the other eigenvalues retained for
 * rejecting lines and narrow curved objects masquerading as room planes. */
static inline ROBSurfacePoint ROBSurfaceSmallestEigenvector(double a[3][3], double eigenvalues[3]) {
    double vectors[3][3]={{1,0,0},{0,1,0},{0,0,1}};
    for (int iteration=0;iteration<24;iteration++) {
        int p=0,q=1; double largest=fabs(a[0][1]);
        if (fabs(a[0][2]) > largest) { p=0;q=2;largest=fabs(a[0][2]); }
        if (fabs(a[1][2]) > largest) { p=1;q=2;largest=fabs(a[1][2]); }
        if (largest < 1e-12) break;
        double angle=.5*atan2(2*a[p][q],a[q][q]-a[p][p]),c=cos(angle),s=sin(angle);
        double app=a[p][p],aqq=a[q][q],apq=a[p][q];
        for (int k=0;k<3;k++) if (k != p && k != q) {
            double akp=a[k][p],akq=a[k][q];
            a[k][p]=a[p][k]=c*akp-s*akq; a[k][q]=a[q][k]=s*akp+c*akq;
        }
        a[p][p]=c*c*app-2*s*c*apq+s*s*aqq; a[q][q]=s*s*app+2*s*c*apq+c*c*aqq; a[p][q]=a[q][p]=0;
        for (int k=0;k<3;k++) { double vp=vectors[k][p],vq=vectors[k][q]; vectors[k][p]=c*vp-s*vq;vectors[k][q]=s*vp+c*vq; }
    }
    int smallest=0; for (int k=0;k<3;k++) { eigenvalues[k]=a[k][k];if (a[k][k] < a[smallest][smallest]) smallest=k; }
    return (ROBSurfacePoint){vectors[0][smallest],vectors[1][smallest],vectors[2][smallest]};
}
static inline uint32_t ROBSurfaceRandom(uint32_t *state) { *state=*state*1664525u+1013904223u;return *state; }
static inline bool ROBSurfaceFitPlane(const ROBSurfaceSample *samples, const uint8_t *used, size_t count, ROBSurfacePlane *plane) {
    size_t available[2048],n=0,seen=0; uint32_t random=0x82ab91u;
    for (size_t i=0;i<count;i++) if (!used[i]) {
        seen++; if (n < 2048) available[n++]=i;
        else { size_t slot=ROBSurfaceRandom(&random)%seen; if (slot < 2048) available[slot]=i; }
    }
    if (n < 80) return false;
    size_t best=0; ROBSurfacePoint normal={0,1,0}; double offset=0;
    for (int trial=0;trial<96;trial++) {
        ROBSurfacePoint a=samples[available[ROBSurfaceRandom(&random)%n]].point,
            b=samples[available[ROBSurfaceRandom(&random)%n]].point,c=samples[available[ROBSurfaceRandom(&random)%n]].point;
        ROBSurfacePoint cross=ROBDepthFloorCross(ROBDepthFloorSubtract(b,a),ROBDepthFloorSubtract(c,a));
        double length=sqrt(ROBDepthFloorDot(cross,cross)); if (length < .002) continue;
        ROBSurfacePoint candidate=ROBDepthFloorScale(cross,1/length); double d=-ROBDepthFloorDot(candidate,a); size_t hits=0;
        for (size_t i=0;i<n;i++) if (fabs(ROBDepthFloorDot(candidate,samples[available[i]].point)+d) <= .015) hits++;
        if (hits > best) { best=hits;normal=candidate;offset=d; }
    }
    if (best < 80) return false;
    ROBSurfacePoint mean={0,0,0};size_t inliers=0;
    for (size_t i=0;i<n;i++) if (fabs(ROBDepthFloorDot(normal,samples[available[i]].point)+offset) <= .015) {
        mean=ROBSurfaceAdd(mean,samples[available[i]].point);inliers++;
    }
    mean=ROBDepthFloorScale(mean,1.0/inliers); double covariance[3][3]={{0}},eigenvalues[3];
    for (size_t i=0;i<n;i++) if (fabs(ROBDepthFloorDot(normal,samples[available[i]].point)+offset) <= .015) {
        ROBSurfacePoint p=ROBDepthFloorSubtract(samples[available[i]].point,mean);double d[3]={p.x,p.y,p.z};
        for (int a=0;a<3;a++) for (int b=0;b<3;b++) covariance[a][b]+=d[a]*d[b]/inliers;
    }
    normal=ROBSurfaceSmallestEigenvector(covariance,eigenvalues);
    int broad=0;for (int i=0;i<3;i++) if (eigenvalues[i] >= .05*.05) broad++;
    if (broad < 2) return false;
    if (normal.y < 0 || (fabs(normal.y)<1e-6 && normal.x < 0)) normal=ROBDepthFloorScale(normal,-1);
    offset=-ROBDepthFloorDot(normal,mean);double squared=0;inliers=0;
    for (size_t i=0;i<n;i++) { double error=ROBDepthFloorDot(normal,samples[available[i]].point)+offset;
        if (fabs(error) <= .015) { squared+=error*error;inliers++; }
    }
    if (inliers < 80 || sqrt(squared/inliers) > .010) return false;
    plane->normal=normal;plane->offset=offset;plane->rms=sqrt(squared/inliers);plane->centroid=mean;
    ROBSurfacePoint axis=fabs(normal.y) < .9 ? (ROBSurfacePoint){0,1,0} : (ROBSurfacePoint){1,0,0};
    plane->u=ROBDepthFloorCross(axis,normal);
    plane->u=ROBDepthFloorScale(plane->u,1/sqrt(ROBDepthFloorDot(plane->u,plane->u)));
    plane->v=ROBDepthFloorCross(normal,plane->u);return true;
}
static inline bool ROBSurfaceRasterizePlane(ROBSurfacePlane *p, const ROBSurfaceSample *samples, uint8_t *used,
                                           size_t count, size_t remainingQuads) {
    int minU=INT16_MAX,minV=INT16_MAX,maxU=INT16_MIN,maxV=INT16_MIN;
    for (size_t i=0;i<count;i++) if (!used[i] && fabs(ROBDepthFloorDot(p->normal,samples[i].point)+p->offset) <= .015) {
        int u=(int)floor(ROBDepthFloorDot(p->u,samples[i].point)/ROBSurfaceTexelSize),v=(int)floor(ROBDepthFloorDot(p->v,samples[i].point)/ROBSurfaceTexelSize);
        if (u < minU) minU=u;if (v < minV) minV=v;if (u > maxU) maxU=u;if (v > maxV) maxV=v;
    }
    int w=maxU-minU+1,h=maxV-minV+1;if (w < 5 || h < 5 || w > 512 || h > 512 || !remainingQuads) return false;
    size_t cells=(size_t)w*h;
    typedef struct { uint32_t r,g,b,n; } Texel;
    Texel *accum=calloc(cells,sizeof(*accum));uint8_t *covered=calloc(cells,1);
    p->rgba=calloc(cells,sizeof(*p->rgba));p->rectangles=calloc(remainingQuads,sizeof(*p->rectangles));
    if (!accum || !covered || !p->rgba || !p->rectangles) { free(accum);free(covered);return false; }
    p->originU=minU;p->originV=minV;p->width=w;p->height=h;
    for (size_t i=0;i<count;i++) if (!used[i] && fabs(ROBDepthFloorDot(p->normal,samples[i].point)+p->offset) <= .015) {
        int u=(int)floor(ROBDepthFloorDot(p->u,samples[i].point)/ROBSurfaceTexelSize)-minU,v=(int)floor(ROBDepthFloorDot(p->v,samples[i].point)/ROBSurfaceTexelSize)-minV;
        if (u < 0 || u >= w || v < 0 || v >= h) continue;
        Texel *t=&accum[(size_t)v*w+u];uint32_t color=samples[i].rgba;
        t->r+=(color>>24)&255;t->g+=(color>>16)&255;t->b+=(color>>8)&255;t->n++;p->support++;
    }
    for (size_t i=0;i<cells;i++) if (accum[i].n) p->rgba[i]=((accum[i].r/accum[i].n)<<24)|((accum[i].g/accum[i].n)<<16)|((accum[i].b/accum[i].n)<<8)|255u;
    for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
        size_t start=(size_t)y*w+x;if (!p->rgba[start] || covered[start] || p->rectangleCount >= remainingQuads) continue;
        int rw=1,rh=1;while (x+rw<w && p->rgba[start+rw] && !covered[start+rw]) rw++;
        bool complete=true;while (y+rh<h && complete) {
            for (int a=0;a<rw;a++) if (!p->rgba[(size_t)(y+rh)*w+x+a] || covered[(size_t)(y+rh)*w+x+a]) { complete=false;break; }
            if (complete) rh++;
        }
        p->rectangles[p->rectangleCount++]=(ROBSurfaceRectangle){(uint16_t)x,(uint16_t)y,(uint16_t)rw,(uint16_t)rh};
        for (int b=0;b<rh;b++) for (int a=0;a<rw;a++) covered[(size_t)(y+b)*w+x+a]=1;
    }
    for (size_t i=0;i<count;i++) if (!used[i] && fabs(ROBDepthFloorDot(p->normal,samples[i].point)+p->offset) <= .015) {
        int u=(int)floor(ROBDepthFloorDot(p->u,samples[i].point)/ROBSurfaceTexelSize)-minU,v=(int)floor(ROBDepthFloorDot(p->v,samples[i].point)/ROBSurfaceTexelSize)-minV;
        if (u >= 0 && u < w && v >= 0 && v < h && covered[(size_t)v*w+u]) used[i]=1;
    }
    free(accum);free(covered);return p->rectangleCount > 0;
}
/* Plane identity and its UV frame survive refits. A near-vertical normal can
 * change sign numerically; matching is sign independent. Never derive a new
 * texture basis or move an established plane on each camera update. */
static inline void ROBSurfaceAnchorPlane(ROBSurfaceMap *m, ROBSurfacePlane *p, uint32_t matched[ROBSurfaceMaximumPlanes], size_t matchedCount) {
    int best=-1;double error=.025;
    for (int i=0;i<12;i++) {
        ROBSurfacePlaneTrack *t=&m->planeTracks[i];
        if (m->lastCapture-t->lastSeen>90) t->valid=false;
        if (!t->valid) continue;
        bool used=false;for (size_t j=0;j<matchedCount;j++) if (matched[j]==t->id) used=true;
        double dot=ROBDepthFloorDot(t->normal,p->normal),sign=dot<0 ? -1 : 1;
        double distance=fabs(t->offset-p->offset*sign);
        if (!used && fabs(dot)>.999 && distance<error) {best=i;error=distance;}
    }
    if (best<0) {
        for (int i=0;i<12;i++) if (!m->planeTracks[i].valid || m->lastCapture-m->planeTracks[i].lastSeen>90) {best=i;break;}
        if (best<0) return;
        m->planeTracks[best]=(ROBSurfacePlaneTrack){true,++m->nextTrackID,p->normal,p->u,p->v,p->centroid,p->offset,m->lastCapture,m->frame,0};
    }
    ROBSurfacePlaneTrack *t=&m->planeTracks[best];t->lastSeen=m->lastCapture;
    if (t->lastFrame!=m->frame || !t->fits) {t->fits++;t->lastFrame=m->frame;}
    if (p->support>=400 && t->fits<2) t->fits=2;
    p->trackID=t->id;p->normal=t->normal;p->u=t->u;p->v=t->v;p->offset=t->offset;
}
static inline size_t ROBSurfacePlaneSupport(ROBSurfacePlane *p, const ROBSurfaceSample *samples, const uint8_t *used, size_t count) {
    size_t support=0;double squared=0;
    for (size_t i=0;i<count;i++) if (!used[i]) {
        double error=ROBDepthFloorDot(p->normal,samples[i].point)+p->offset;
        if (fabs(error)<=.015) {support++;squared+=error*error;}
    }
    p->support=support;if (support) p->rms=sqrt(squared/support);return support;
}
static inline void ROBSurfaceSkipPlane(const ROBSurfacePlane *p, const ROBSurfaceSample *samples, uint8_t *used, size_t count) {
    for (size_t i=0;i<count;i++) if (!used[i] && fabs(ROBDepthFloorDot(p->normal,samples[i].point)+p->offset)<=.015) used[i]=2;
}
/* Fit a KNOWN upright can-size prior to observed side samples. Completion is
 * deliberately a separate output: unseen back/top pixels are never invented. */
static inline ROBSurfaceCylinder ROBSurfaceFitCylinder(const ROBSurfaceSample *samples, size_t count,
                                                       double baseY, double radius, double height) {
    ROBSurfaceCylinder out={0};
    if (!samples || count < 20 || count > 2048 || !isfinite(baseY) || !isfinite(radius) || !isfinite(height) ||
        radius < .025 || radius > .05 || height < .09 || height > .18) return out;
    ROBSurfacePoint mean={0,0,0};
    for (size_t i=0;i<count;i++) { if (!ROBSurfacePointValid(samples[i].point)) return out;mean=ROBSurfaceAdd(mean,samples[i].point); }
    mean=ROBDepthFloorScale(mean,1.0/count);
    double best=DBL_MAX,bx=0,bz=0;
    for (int ix=-12;ix<=12;ix++) for (int iz=-12;iz<=12;iz++) {
        double x=mean.x+ix*radius/10,z=mean.z+iz*radius/10,loss=0;
        for (size_t i=0;i<count;i++) { double e=hypot(samples[i].point.x-x,samples[i].point.z-z)-radius;loss+=fmin(e*e,.012*.012); }
        if (loss < best) { best=loss;bx=x;bz=z; }
    }
    for (int iteration=0;iteration<8;iteration++) {
        double a=0,b=0,c=0,gx=0,gz=0;
        for (size_t i=0;i<count;i++) {
            double dx=bx-samples[i].point.x,dz=bz-samples[i].point.z,d=hypot(dx,dz),e=d-radius;
            if (d < 1e-5 || fabs(e) > .012) continue;
            dx/=d;dz/=d;a+=dx*dx;b+=dx*dz;c+=dz*dz;gx+=dx*e;gz+=dz*e;
        }
        double determinant=a*c-b*b;if (determinant < 1e-6) return out;
        double dx=(c*gx-b*gz)/determinant,dz=(a*gz-b*gx)/determinant;
        if (hypot(dx,dz) > .01) return out;bx-=dx;bz-=dz;
    }
    double squared=0,low=DBL_MAX,high=-DBL_MAX;uint32_t angleMask=0,heightMask=0;size_t inliers=0;
    double angles[2048];
    for (size_t i=0;i<count;i++) {
        ROBSurfacePoint p=samples[i].point;double e=hypot(p.x-bx,p.z-bz)-radius;
        if (fabs(e) > .007 || p.y < baseY+.005 || p.y > baseY+height+.02) continue;
        squared+=e*e;low=fmin(low,p.y);high=fmax(high,p.y);
        double angle=atan2(p.z-bz,p.x-bx)+3.14159265358979323846;
        angles[inliers++]=angle;int bin=(int)floor(angle*12/(2*3.14159265358979323846));if (bin>11) bin=11;angleMask|=1u<<bin;
        int level=(int)((p.y-baseY)/height*3);if (level<0) level=0;if (level>2) level=2;heightMask|=1u<<level;
    }
    unsigned bins=0;for (int i=0;i<12;i++) if (angleMask&(1u<<i)) bins++;
    if (inliers < 20 || inliers < count*.55 || bins < 4 || heightMask != 7 || high-low < height*.6 ||
        high < baseY+height*.8 || sqrt(squared/inliers) > .0045) return out;
    /* Circular gap yields actual angular support, independent of the seam. */
    for (size_t i=1;i<inliers;i++) { double value=angles[i];size_t j=i;while (j && angles[j-1]>value) {angles[j]=angles[j-1];j--;}angles[j]=value; }
    double gap=angles[0]+2*3.14159265358979323846-angles[inliers-1];
    for (size_t i=1;i<inliers;i++) gap=fmax(gap,angles[i]-angles[i-1]);
    double arc=2*3.14159265358979323846-gap;if (arc < 1.5) return out;
    out.valid=true;out.center=(ROBSurfacePoint){bx,baseY+height/2,bz};out.axis=(ROBSurfacePoint){0,1,0};out.radius=radius;out.height=height;
    out.rms=sqrt(squared/inliers);out.observedArcRadians=arc;out.support=inliers;return out;
}
static inline void ROBSurfaceMeshDestroy(ROBSurfaceMesh *mesh) {
    if (!mesh) return;for (size_t i=0;i<ROBSurfaceMaximumPlanes;i++) { free(mesh->planes[i].rgba);free(mesh->planes[i].rectangles); }free(mesh);
}
static inline size_t ROBSurfaceCylinderEvidence(ROBSurfaceCylinder c, const ROBSurfaceSample *samples, size_t count) {
    size_t hits=0;double low=DBL_MAX,high=-DBL_MAX;
    for (size_t i=0;i<count;i++) {
        ROBSurfacePoint p=ROBDepthFloorSubtract(samples[i].point,c.center);
        double height=ROBDepthFloorDot(p,c.axis);if (fabs(height)>c.height/2+.015) continue;
        ROBSurfacePoint radial=ROBDepthFloorSubtract(p,ROBDepthFloorScale(c.axis,height));
        if (fabs(sqrt(ROBDepthFloorDot(radial,radial))-c.radius)>.015) continue;
        hits++;low=fmin(low,height);high=fmax(high,height);
    }
    return high-low>=.03 ? hits : 0;
}
static inline bool ROBSurfaceCanAppearance(uint32_t rgba) {
    double r=(rgba>>24)&255,g=(rgba>>16)&255,b=(rgba>>8)&255;
    return r>70 && r>g*1.3 && r>b*1.3 && b>g*.75;
}
static inline void ROBSurfaceUpdateCylinders(ROBSurfaceMap *m, ROBSurfaceMesh *mesh) {
    for (int i=0;i<4;i++) if (m->lastCapture-m->cylinderTracks[i].lastSeen>3) m->cylinderTracks[i].cylinder.valid=false;
    const ROBSurfaceSample *current=m->recentSamples+m->recentIndex*ROBSurfaceMaximumInput;
    size_t currentCount=m->recentCounts[m->recentIndex],count=0;
    ROBSurfaceSample *fine=calloc(2*ROBSurfaceMaximumInput,sizeof(*fine));
    uint8_t *visited=calloc(2*ROBSurfaceMaximumInput,1);
    if (!fine || !visited) {free(fine);free(visited);return;}
    for (int frame=0;frame<2;frame++) if (m->lastCapture-m->recentTimes[frame]<=2) {
        memcpy(fine+count,m->recentSamples+frame*ROBSurfaceMaximumInput,m->recentCounts[frame]*sizeof(*fine));
        count+=m->recentCounts[frame];
    }
    unsigned attempts=0;bool updated[4]={0};
    for (size_t plane=0;plane<mesh->planeCount && attempts<16;plane++) {
        ROBSurfacePlane *p=&mesh->planes[plane];if (p->normal.y<.7) continue;
        memset(visited,0,count);
        for (size_t i=0;i<count && attempts<16;i++) if (!visited[i] && ROBSurfacePointValid(fine[i].point) && ROBSurfaceCanAppearance(fine[i].rgba)) {
            ROBSurfacePoint seed=fine[i].point;
            double height=ROBDepthFloorDot(p->normal,seed)+p->offset;
            if (height<.025 || height>.145) continue;
            double su=ROBDepthFloorDot(p->u,seed),sv=ROBDepthFloorDot(p->v,seed);
            int u=(int)floor(su/ROBSurfaceTexelSize)-p->originU,v=(int)floor(sv/ROBSurfaceTexelSize)-p->originV;
            unsigned nearby=0;
            for (int y=-2;y<=2;y++) for (int x=-2;x<=2;x++) if (u+x>=0 && u+x<p->width && v+y>=0 && v+y<p->height &&
                p->rgba[(size_t)(v+y)*p->width+u+x]) nearby++;
            if (nearby<4) continue;
            ROBSurfaceSample local[1024];size_t n=0,seen=0;uint32_t random=0x51c331u;
            for (size_t j=0;j<count;j++) if (ROBSurfacePointValid(fine[j].point) && ROBSurfaceCanAppearance(fine[j].rgba)) {
                ROBSurfacePoint world=fine[j].point;
                double h=ROBDepthFloorDot(p->normal,world)+p->offset;
                double x=ROBDepthFloorDot(p->u,world),z=ROBDepthFloorDot(p->v,world);
                if (h<.016 || h>.145 || hypot(x-su,z-sv)>.09) continue;
                visited[j]=1;seen++;
                ROBSurfaceSample sample={{x,h,z},fine[j].rgba};
                if (n<1024) local[n++]=sample;
                else {size_t slot=ROBSurfaceRandom(&random)%seen;if (slot<1024) local[slot]=sample;}
            }
            attempts++;
            ROBSurfaceCylinder c=ROBSurfaceFitCylinder(local,n,0,.033,.115);if (!c.valid) continue;
            c.center=ROBSurfaceAdd(ROBDepthFloorScale(p->normal,c.center.y-p->offset),
                ROBSurfaceAdd(ROBDepthFloorScale(p->u,c.center.x),ROBDepthFloorScale(p->v,c.center.z)));
            c.axis=p->normal;
            if (ROBSurfaceCylinderEvidence(c,current,currentCount)<6) continue;
            int match=-1;double nearest=.065;
            for (int j=0;j<4;j++) if (m->cylinderTracks[j].cylinder.valid) {
                double distance=sqrt(ROBSurfaceDistance2(c.center,m->cylinderTracks[j].cylinder.center));
                if (distance<nearest && ROBDepthFloorDot(c.axis,m->cylinderTracks[j].cylinder.axis)>.97) {nearest=distance;match=j;}
            }
            if (match>=0 && updated[match]) continue;
            if (match<0) for (int j=0;j<4;j++) if (!m->cylinderTracks[j].cylinder.valid || m->lastCapture-m->cylinderTracks[j].lastSeen>3) {match=j;break;}
            if (match<0) continue;
            ROBSurfaceCylinderTrack *t=&m->cylinderTracks[match];
            if (t->cylinder.valid && m->lastCapture-t->lastSeen<=3) {
                c.center=ROBSurfaceAdd(ROBDepthFloorScale(t->cylinder.center,.8),ROBDepthFloorScale(c.center,.2));
                c.trackID=t->cylinder.trackID;
            } else c.trackID=++m->nextTrackID;
            t->cylinder=c;t->lastSeen=m->lastCapture;t->contradictions=0;updated[match]=true;
        }
    }
    for (int i=0;i<4;i++) {
        ROBSurfaceCylinderTrack *t=&m->cylinderTracks[i];if (!t->cylinder.valid) continue;
        if (!updated[i] && ROBSurfaceCylinderEvidence(t->cylinder,current,currentCount)>=6) t->lastSeen=m->lastCapture;
        double age=m->lastCapture-t->lastSeen;
        if (age>3 || t->contradictions>=2) {t->cylinder.valid=false;continue;}
        t->cylinder.observedAgeSeconds=age;mesh->cylinders[mesh->cylinderCount++]=t->cylinder;
    }
    free(fine);free(visited);
}
static inline ROBSurfaceMesh *ROBSurfaceMapBuildMesh(ROBSurfaceMap *m) {
    if (!m) return NULL;ROBSurfaceMesh *mesh=calloc(1,sizeof(*mesh));
    ROBSurfaceSample *samples=calloc(m->count+1,sizeof(*samples));uint8_t *used=calloc(m->count+1,1);
    if (!mesh || !samples || !used) { free(samples);free(used);ROBSurfaceMeshDestroy(mesh);return NULL; }
    size_t count=0;for (size_t i=0;i<ROBSurfaceSlotCount;i++) if (m->slots[i].state==1 && m->slots[i].frames>=2) {
        samples[count++]=(ROBSurfaceSample){m->slots[i].point,ROBSurfaceColor(&m->slots[i])};
    }
    mesh->stableVoxelCount=count;mesh->truncated=m->full;
    uint32_t matched[ROBSurfaceMaximumPlanes]={0};
    /* Reuse confirmed surfaces before seeking new ones. They survive noisy
     * RANSAC proposals while actual accumulated support remains. */
    for (int i=0;i<12 && mesh->planeCount<ROBSurfaceMaximumPlanes;i++) {
        ROBSurfacePlaneTrack *t=&m->planeTracks[i];if (!t->valid || t->fits<2 || m->lastCapture-t->lastSeen>90) continue;
        ROBSurfacePlane *p=&mesh->planes[mesh->planeCount];
        p->normal=t->normal;p->u=t->u;p->v=t->v;p->centroid=t->centroid;p->offset=t->offset;p->trackID=t->id;
        bool duplicate=false;
        for (size_t j=0;j<mesh->planeCount;j++) if (fabs(ROBDepthFloorDot(p->normal,mesh->planes[j].normal))>.97 &&
            fabs(ROBDepthFloorDot(mesh->planes[j].normal,p->centroid)+mesh->planes[j].offset)<.035) duplicate=true;
        if (duplicate) {ROBSurfaceSkipPlane(p,samples,used,count);memset(p,0,sizeof(*p));continue;}
        if (ROBSurfacePlaneSupport(p,samples,used,count)<80 || p->rms>.010) {memset(p,0,sizeof(*p));continue;}
        p->support=0;
        if (!ROBSurfaceRasterizePlane(p,samples,used,count,ROBSurfaceMaximumQuads-mesh->quadCount)) {
            free(p->rgba);free(p->rectangles);memset(p,0,sizeof(*p));continue;
        }
        t->lastSeen=m->lastCapture;matched[mesh->planeCount]=t->id;
        mesh->planeCount++;mesh->quadCount+=p->rectangleCount;
    }
    for (unsigned attempt=0;attempt<18 && mesh->planeCount<ROBSurfaceMaximumPlanes;attempt++) {
        ROBSurfacePlane *p=&mesh->planes[mesh->planeCount];
        if (!ROBSurfaceFitPlane(samples,used,count,p)) break;
        bool duplicate=false;
        for (size_t j=0;j<mesh->planeCount;j++) if (fabs(ROBDepthFloorDot(p->normal,mesh->planes[j].normal))>.97 &&
            fabs(ROBDepthFloorDot(mesh->planes[j].normal,p->centroid)+mesh->planes[j].offset)<.035) duplicate=true;
        if (duplicate) {ROBSurfaceSkipPlane(p,samples,used,count);memset(p,0,sizeof(*p));continue;}
        ROBSurfacePlaneSupport(p,samples,used,count);ROBSurfaceAnchorPlane(m,p,matched,mesh->planeCount);
        bool confirmed=false;for (int j=0;j<12;j++) if (m->planeTracks[j].id==p->trackID && m->planeTracks[j].fits>=2) confirmed=true;
        if (!confirmed) {ROBSurfaceSkipPlane(p,samples,used,count);memset(p,0,sizeof(*p));continue;}
        p->support=0;
        if (!ROBSurfaceRasterizePlane(p,samples,used,count,ROBSurfaceMaximumQuads-mesh->quadCount)) {
            free(p->rgba);free(p->rectangles);memset(p,0,sizeof(*p));continue;
        }
        matched[mesh->planeCount]=p->trackID;mesh->planeCount++;mesh->quadCount+=p->rectangleCount;
    }
    size_t residualsSeen=0;uint32_t random=0x971bc3u;
    for (size_t i=0;i<count;i++) if (used[i]!=1) {
        residualsSeen++;if (mesh->residualCount<ROBSurfaceMaximumResiduals) mesh->residuals[mesh->residualCount++]=samples[i];
        else { size_t slot=ROBSurfaceRandom(&random)%residualsSeen;if (slot<ROBSurfaceMaximumResiduals) mesh->residuals[slot]=samples[i]; }
    }
    if (residualsSeen > ROBSurfaceMaximumResiduals || mesh->quadCount == ROBSurfaceMaximumQuads) mesh->truncated=true;
    ROBSurfaceUpdateCylinders(m,mesh);
    free(samples);free(used);return mesh;
}

#endif
