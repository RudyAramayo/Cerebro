#ifndef ROBDepthCloudProjection_h
#define ROBDepthCloudProjection_h
#include <math.h>
#include <stdbool.h>

// Optical right/down/forward -> scene coordinates. The articulated URDF mesh
// supplies this entire affine transform, including its presentation scale.
typedef struct { double x, y, z; } ROBDepthPoint;
typedef struct { double m[12]; bool valid; } ROBDepthCloudTransform;
static inline ROBDepthCloudTransform ROBDepthCloudMakeTransform(const double rows[12]) {
    ROBDepthCloudTransform t = {{0}, false};
    if (!rows) return t;
    for (int i=0;i<12;i++) { if (!isfinite(rows[i])) return t; t.m[i] = rows[i]; }
    // A missing or degenerate camera basis must never fabricate a cloud.
    double determinant = rows[0]*(rows[5]*rows[10]-rows[6]*rows[9])
        -rows[1]*(rows[4]*rows[10]-rows[6]*rows[8])+rows[2]*(rows[4]*rows[9]-rows[5]*rows[8]);
    t.valid = isfinite(determinant) && fabs(determinant) > 1e-9;
    return t;
}
static inline ROBDepthPoint ROBDepthCloudProject(ROBDepthCloudTransform t, double x, double y, double z) {
    return (ROBDepthPoint){t.m[0]*x+t.m[1]*y+t.m[2]*z+t.m[3],
        t.m[4]*x+t.m[5]*y+t.m[6]*z+t.m[7], t.m[8]*x+t.m[9]*y+t.m[10]*z+t.m[11]};
}
#endif
