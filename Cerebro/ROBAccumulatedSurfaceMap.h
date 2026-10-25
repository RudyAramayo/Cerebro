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
    ROBSurfaceVoxel *slots;
    uint32_t touched[ROBSurfaceMaximumInput];
    size_t count, tombstones;
    uint64_t frame;
    double lastCapture;
    bool full;
} ROBSurfaceMap;
typedef struct {
    int width, height;
    const uint8_t *depthLittleEndian;
    double fx, fy, cx, cy;
    double cameraToMap[12]; /* Rigid row-major optical -> submap, NO scale. */
} ROBSurfaceDepthView;
typedef struct { uint16_t x, y, width, height; } ROBSurfaceRectangle;
typedef struct {
    ROBSurfacePoint normal, u, v;
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
    double radius, height, rms, observedArcRadians;
    size_t support;
} ROBSurfaceCylinder;
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
    if (m && !m->slots) { free(m); return NULL; }
    return m;
}
static inline void ROBSurfaceMapDestroy(ROBSurfaceMap *m) { if (m) { free(m->slots); free(m); } }
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
    plane->normal=normal;plane->offset=offset;plane->rms=sqrt(squared/inliers);
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
    if (inliers < 20 || inliers < count*.8 || bins < 4 || heightMask != 7 || high-low < height*.6 ||
        high < baseY+height*.8 || sqrt(squared/inliers) > .0045) return out;
    /* Circular gap yields actual angular support, independent of the seam. */
    for (size_t i=1;i<inliers;i++) { double value=angles[i];size_t j=i;while (j && angles[j-1]>value) {angles[j]=angles[j-1];j--;}angles[j]=value; }
    double gap=angles[0]+2*3.14159265358979323846-angles[inliers-1];
    for (size_t i=1;i<inliers;i++) gap=fmax(gap,angles[i]-angles[i-1]);
    double arc=2*3.14159265358979323846-gap;if (arc < 1.5) return out;
    out.valid=true;out.center=(ROBSurfacePoint){bx,baseY+height/2,bz};out.radius=radius;out.height=height;
    out.rms=sqrt(squared/inliers);out.observedArcRadians=arc;out.support=inliers;return out;
}
static inline void ROBSurfaceMeshDestroy(ROBSurfaceMesh *mesh) {
    if (!mesh) return;for (size_t i=0;i<ROBSurfaceMaximumPlanes;i++) { free(mesh->planes[i].rgba);free(mesh->planes[i].rectangles); }free(mesh);
}
static inline ROBSurfaceMesh *ROBSurfaceMapBuildMesh(const ROBSurfaceMap *m) {
    if (!m) return NULL;ROBSurfaceMesh *mesh=calloc(1,sizeof(*mesh));
    ROBSurfaceSample *samples=calloc(m->count+1,sizeof(*samples));uint8_t *used=calloc(m->count+1,1);
    if (!mesh || !samples || !used) { free(samples);free(used);ROBSurfaceMeshDestroy(mesh);return NULL; }
    size_t count=0;for (size_t i=0;i<ROBSurfaceSlotCount;i++) if (m->slots[i].state==1 && m->slots[i].frames>=2) {
        samples[count++]=(ROBSurfaceSample){m->slots[i].point,ROBSurfaceColor(&m->slots[i])};
    }
    mesh->stableVoxelCount=count;mesh->truncated=m->full;
    for (size_t i=0;i<ROBSurfaceMaximumPlanes;i++) {
        ROBSurfacePlane *p=&mesh->planes[i];
        if (!ROBSurfaceFitPlane(samples,used,count,p)) break;
        if (!ROBSurfaceRasterizePlane(p,samples,used,count,ROBSurfaceMaximumQuads-mesh->quadCount)) {
            free(p->rgba);free(p->rectangles);memset(p,0,sizeof(*p));break;
        }
        mesh->planeCount++;mesh->quadCount+=p->rectangleCount;
    }
    size_t residualsSeen=0;uint32_t random=0x971bc3u;
    for (size_t i=0;i<count;i++) if (!used[i]) {
        residualsSeen++;if (mesh->residualCount<ROBSurfaceMaximumResiduals) mesh->residuals[mesh->residualCount++]=samples[i];
        else { size_t slot=ROBSurfaceRandom(&random)%residualsSeen;if (slot<ROBSurfaceMaximumResiduals) mesh->residuals[slot]=samples[i]; }
    }
    if (residualsSeen > ROBSurfaceMaximumResiduals || mesh->quadCount == ROBSurfaceMaximumQuads) mesh->truncated=true;
    /* Can candidates must sit on a fitted, observed horizontal surface. Search
     * only small residual neighbourhoods; room planes cannot become cylinders. */
    unsigned cylinderAttempts=0;
    for (size_t plane=0;plane<mesh->planeCount && mesh->cylinderCount<4 && cylinderAttempts<16;plane++) {
        ROBSurfacePlane *p=&mesh->planes[plane];if (p->normal.y < .995) continue;
        for (size_t i=0;i<count && mesh->cylinderCount<4 && cylinderAttempts<16;i++) if (!used[i]) {
            ROBSurfacePoint seed=samples[i].point;
            double base=-(p->offset+p->normal.x*seed.x+p->normal.z*seed.z)/p->normal.y;
            if (base<.25 || base>1.5 || seed.y<=base+.02 || seed.y>=base+.14) continue;
            int u=(int)floor(ROBDepthFloorDot(p->u,seed)/ROBSurfaceTexelSize)-p->originU,
                v=(int)floor(ROBDepthFloorDot(p->v,seed)/ROBSurfaceTexelSize)-p->originV;
            unsigned nearby=0;
            for (int y=-2;y<=2;y++) for (int x=-2;x<=2;x++) if (u+x>=0 && u+x<p->width && v+y>=0 && v+y<p->height &&
                p->rgba[(size_t)(v+y)*p->width+u+x]) nearby++;
            if (nearby<4) continue;
            bool duplicate=false;
            for (size_t j=0;j<mesh->cylinderCount;j++) if (hypot(seed.x-mesh->cylinders[j].center.x,seed.z-mesh->cylinders[j].center.z)<.1) duplicate=true;
            if (duplicate) continue;
            ROBSurfaceSample local[512];size_t n=0;
            for (size_t j=0;j<count && n<512;j++) if (!used[j] && samples[j].point.y>base+.005 && samples[j].point.y<base+.14 &&
                hypot(seed.x-samples[j].point.x,seed.z-samples[j].point.z)<.085) local[n++]=samples[j];
            /* Avoid re-fitting every point in the same rejected neighbourhood. */
            for (size_t j=0;j<count;j++) if (!used[j] && samples[j].point.y>base+.005 && samples[j].point.y<base+.14 &&
                hypot(seed.x-samples[j].point.x,seed.z-samples[j].point.z)<.085) used[j]=2;
            cylinderAttempts++;
            ROBSurfaceCylinder cylinder=ROBSurfaceFitCylinder(local,n,base,.033,.115);
            if (cylinder.valid) mesh->cylinders[mesh->cylinderCount++]=cylinder;
        }
    }
    free(samples);free(used);return mesh;
}

#endif
