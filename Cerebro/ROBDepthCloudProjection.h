#ifndef ROBDepthCloudProjection_h
#define ROBDepthCloudProjection_h
#include <math.h>
#include <stdbool.h>

// Display-only camera projection. Mount points are the pinned URDF reference
// in the scene's X-right/Y-up/Z-back basis, in meters before presentation scale.
typedef struct { double x, y, z; } ROBDepthPoint;
typedef struct { double m[12]; bool valid; } ROBDepthCloudTransform;
static inline ROBDepthPoint ROBDepthAdd(ROBDepthPoint a, ROBDepthPoint b) {
    return (ROBDepthPoint){a.x+b.x, a.y+b.y, a.z+b.z};
}
static inline ROBDepthPoint ROBDepthSubtract(ROBDepthPoint a, ROBDepthPoint b) {
    return (ROBDepthPoint){a.x-b.x, a.y-b.y, a.z-b.z};
}
static inline ROBDepthPoint ROBDepthRotateX(ROBDepthPoint p, double a) {
    return (ROBDepthPoint){p.x, cos(a)*p.y-sin(a)*p.z, sin(a)*p.y+cos(a)*p.z};
}
static inline ROBDepthPoint ROBDepthRotateY(ROBDepthPoint p, double a) {
    return (ROBDepthPoint){cos(a)*p.x+sin(a)*p.z, p.y, -sin(a)*p.x+cos(a)*p.z};
}
static inline bool ROBDepthPointIsFinite(ROBDepthPoint p) {
    return isfinite(p.x) && isfinite(p.y) && isfinite(p.z);
}
static inline ROBDepthPoint ROBDepthChain(ROBDepthPoint optical, const ROBDepthPoint mounts[4],
                                         double lower, double pan, double upper, bool belly) {
    ROBDepthPoint p = {optical.x, -optical.y, -optical.z};
    if (belly) return ROBDepthAdd(p, mounts[3]);
    p = ROBDepthRotateX(ROBDepthAdd(p, ROBDepthSubtract(mounts[3], mounts[2])), upper);
    p = ROBDepthRotateY(ROBDepthAdd(p, ROBDepthSubtract(mounts[2], mounts[1])), pan);
    p = ROBDepthRotateX(ROBDepthAdd(p, ROBDepthSubtract(mounts[1], mounts[0])), lower);
    return ROBDepthAdd(p, mounts[0]);
}
static inline ROBDepthCloudTransform ROBDepthCloudMakeTransform(const ROBDepthPoint mounts[4],
    double lower, double pan, double upper, double scale, bool belly) {
    ROBDepthCloudTransform t = {{0}, false};
    if (!mounts || !isfinite(lower) || !isfinite(pan) || !isfinite(upper) || !isfinite(scale) || scale <= 0) return t;
    for (int i=0;i<4;i++) if (!ROBDepthPointIsFinite(mounts[i])) return t;
    ROBDepthPoint origin = ROBDepthChain((ROBDepthPoint){0}, mounts, lower, pan, upper, belly);
    for (int i=0;i<3;i++) {
        ROBDepthPoint basis = {i==0, i==1, i==2};
        ROBDepthPoint column = ROBDepthSubtract(ROBDepthChain(basis, mounts, lower, pan, upper, belly), origin);
        t.m[i] = scale*column.x; t.m[4+i] = scale*column.y; t.m[8+i] = scale*column.z;
    }
    t.m[3] = scale*origin.x; t.m[7] = scale*origin.y; t.m[11] = scale*origin.z; t.valid = true;
    return t;
}
static inline ROBDepthPoint ROBDepthCloudProject(ROBDepthCloudTransform t, double x, double y, double z) {
    return (ROBDepthPoint){t.m[0]*x+t.m[1]*y+t.m[2]*z+t.m[3],
        t.m[4]*x+t.m[5]*y+t.m[6]*z+t.m[7], t.m[8]*x+t.m[9]*y+t.m[10]*z+t.m[11]};
}
#endif
