#include "../Cerebro/ROBDepthFloorRectification.h"
#include <assert.h>
#include <stdio.h>
#include <time.h>

static double uniform(uint32_t *seed) { return ROBDepthFloorRandom(seed) / 4294967296.0; }
static double distance(ROBDepthFloorPoint a, ROBDepthFloorPoint b) {
    ROBDepthFloorPoint d = ROBDepthFloorSubtract(a, b); return sqrt(ROBDepthFloorDot(d, d));
}
static void floor_points(ROBDepthFloorPoint *points, size_t count, ROBDepthFloorPoint n,
                         double d, double noise, double span) {
    uint32_t seed = UINT32_C(0x123abc19);
    for (size_t i = 0; i < count; ++i) {
        double x = span * (uniform(&seed)-.5), z = span * (uniform(&seed)-.5);
        points[i] = (ROBDepthFloorPoint){x, -(n.x*x+n.z*z+d)/n.y + noise*(uniform(&seed)-.5), z};
    }
}
static void assert_rigid(ROBDepthFloorModel fit) {
    assert(fit.valid);
    const double *m = fit.correction;
    for (int row = 0; row < 3; ++row) for (int other = 0; other < 3; ++other) {
        double dot = 0;
        for (int col = 0; col < 3; ++col) dot += m[row*4+col]*m[other*4+col];
        assert(fabs(dot-(row == other ? 1 : 0)) < 1e-10);
    }
    double determinant = m[0]*(m[5]*m[10]-m[6]*m[9])-m[1]*(m[4]*m[10]-m[6]*m[8])+m[2]*(m[4]*m[9]-m[5]*m[8]);
    assert(fabs(determinant-1) < 1e-10);
    ROBDepthFloorPoint a = {.4, .8, -1.2}, b = {-.6, 1.1, -2.7};
    assert(fabs(distance(a,b)-distance(ROBDepthFloorRectify(fit,a,false),ROBDepthFloorRectify(fit,b,false))) < 1e-10);
}

int main(void) {
    ROBDepthFloorOptions options = ROBDepthFloorDefaultOptions();
    ROBDepthFloorPoint points[12000];
    floor_points(points, 1600, (ROBDepthFloorPoint){0,1,0}, 0, 0, 1.6);
    ROBDepthFloorModel level = ROBDepthFloorFit(points, 1600, options);
    assert(level.valid && level.inlierCount == 1600 && level.coveredCells == 16);
    assert(level.rmsMeters < 1e-12 && fabs(level.normal.y-1) < 1e-12);
    assert(level.tiltRadians < 1e-12 && level.confidence > .999);
    assert_rigid(level);

    /* A tilted, translated floor with noise and 30% unrelated object points.
     * All scene units here are meters, before the app's presentation scale. */
    double pitch = 18 * 3.14159265358979323846 / 180;
    ROBDepthFloorPoint actualNormal = {sin(pitch)*.8, cos(pitch), sin(pitch)*.6};
    double actualOffset = -.12;
    floor_points(points, 8400, actualNormal, actualOffset, .008, 2.0);
    uint32_t seed = UINT32_C(0x8bc531ac);
    for (size_t i = 8400; i < 12000; ++i) points[i] = (ROBDepthFloorPoint){3*(uniform(&seed)-.5), .65+uniform(&seed), 3*(uniform(&seed)-.5)};
    /* Interleave objects so uniform bounded subsampling sees both populations. */
    for (size_t i = 0; i < 12000; ++i) {
        size_t j = ROBDepthFloorRandom(&seed) % 12000;
        ROBDepthFloorPoint temporary = points[i]; points[i] = points[j]; points[j] = temporary;
    }
    ROBDepthFloorModel fitted = ROBDepthFloorFit(points, 12000, options);
    assert(fitted.valid && fitted.sampleCount == ROBDepthFloorMaximumSamples);
    assert(fitted.inlierFraction > .65 && fitted.inlierFraction < .76 && fitted.rmsMeters < .004);
    assert(ROBDepthFloorDot(fitted.normal,actualNormal) > .99999 && fabs(fitted.offsetMeters-actualOffset) < .001);
    assert_rigid(fitted);
    ROBDepthFloorPoint onPlane = {.3, -(fitted.normal.x*.3+fitted.normal.z*.7+fitted.offsetMeters)/fitted.normal.y, .7};
    ROBDepthFloorPoint object = {onPlane.x+.45*fitted.normal.x, onPlane.y+.45*fitted.normal.y, onPlane.z+.45*fitted.normal.z};
    ROBDepthFloorPoint above = ROBDepthFloorRectify(fitted,object,false);
    assert(fabs(above.y-.45) < 1e-10);
    assert(fabs(ROBDepthFloorRectify(fitted,onPlane,false).y) < 1e-10);
    assert(!ROBDepthFloorIsInlier(fitted,object));
    assert(fabs(ROBDepthFloorRectify(fitted,object,true).y-.45) < 1e-10);
    ROBDepthFloorPoint noisyFloor = {onPlane.x+.004*fitted.normal.x, onPlane.y+.004*fitted.normal.y, onPlane.z+.004*fitted.normal.z};
    assert(ROBDepthFloorRectify(fitted,noisyFloor,true).y == 0);
    assert(fabs(ROBDepthFloorRectify(fitted,noisyFloor,false).y-.004) < 1e-10);
    ROBDepthFloorModel repeated = ROBDepthFloorFit(points, 12000, options);
    assert(repeated.sampleCount == fitted.sampleCount && repeated.inlierCount == fitted.inlierCount);
    assert(repeated.normal.x == fitted.normal.x && repeated.normal.y == fitted.normal.y && repeated.normal.z == fitted.normal.z);
    for (int i = 0; i < 12; ++i) assert(repeated.correction[i] == fitted.correction[i]);

    /* Default bounds reject walls, an ordinary tabletop, and excessive tilt. */
    for (size_t i = 0; i < 1600; ++i) points[i] = (ROBDepthFloorPoint){.15, .001*(i%40), .04*(i/40)};
    assert(!ROBDepthFloorFit(points,1600,options).valid);
    floor_points(points,1600,(ROBDepthFloorPoint){0,1,0},-.75,0,1.6);
    assert(!ROBDepthFloorFit(points,1600,options).valid);
    double steep = 38 * 3.14159265358979323846 / 180;
    floor_points(points,1600,(ROBDepthFloorPoint){sin(steep),cos(steep),0},0,0,1.6);
    assert(!ROBDepthFloorFit(points,1600,options).valid);

    /* Both correction axes and positive/negative offsets remain proper rigid
     * rotations throughout the configured tilt range. */
    for (int i = 0; i < 24; ++i) {
        double tilt = (.5 + i) * 3.14159265358979323846 / 180;
        double azimuth = i * .71;
        ROBDepthFloorPoint n = {sin(tilt)*cos(azimuth),cos(tilt),sin(tilt)*sin(azimuth)};
        floor_points(points,1600,n,(i%2 ? -.27 : .27),.004,1.6);
        ROBDepthFloorModel tilted = ROBDepthFloorFit(points,1600,options);
        assert(tilted.valid && ROBDepthFloorDot(tilted.normal,n) > .99999);
        assert_rigid(tilted);
    }

    /* Sparse, narrow, diagonal line and corner-only candidates lack coverage. */
    floor_points(points,79,(ROBDepthFloorPoint){0,1,0},0,0,1.6);
    assert(ROBDepthFloorFit(points,79,options).rejection == ROBDepthFloorInsufficientPoints);
    floor_points(points,1600,(ROBDepthFloorPoint){0,1,0},0,0,.3);
    assert(ROBDepthFloorFit(points,1600,options).rejection == ROBDepthFloorPoorCoverage);
    for (size_t i = 0; i < 1600; ++i) points[i] = (ROBDepthFloorPoint){.001*i, .0001*(int)(i%3), .001*i+.0001*(int)(i%7)};
    assert(!ROBDepthFloorFit(points,1600,options).valid);
    for (size_t i = 0; i < 1600; ++i) points[i] = (ROBDepthFloorPoint){i%2 ? -1 : 1, 0, i%4 < 2 ? -1 : 1};
    assert(ROBDepthFloorFit(points,1600,options).rejection == ROBDepthFloorPoorCoverage);

    floor_points(points,1600,(ROBDepthFloorPoint){0,1,0},0,0,1.6);
    for (size_t i = 0; i < 1600; ++i) points[i].y = i%2 ? .016 : -.016;
    assert(!ROBDepthFloorFit(points,1600,options).valid);
    floor_points(points,960,(ROBDepthFloorPoint){0,1,0},-.05,0,1.6);
    floor_points(points+960,640,(ROBDepthFloorPoint){0,1,0},-.20,0,1.6);
    assert(ROBDepthFloorFit(points,1600,options).rejection == ROBDepthFloorAmbiguousPlane);
    floor_points(points,700,(ROBDepthFloorPoint){0,1,0},0,0,1.6);
    for (size_t i = 700; i < 1600; ++i) points[i] = (ROBDepthFloorPoint){3*(uniform(&seed)-.5), .65+uniform(&seed), 3*(uniform(&seed)-.5)};
    assert(!ROBDepthFloorFit(points,1600,options).valid);

    /* Unknown/nonfinite inputs cannot create a fabricated correction. */
    assert(!ROBDepthFloorFit(NULL,1600,options).valid);
    floor_points(points,1600,(ROBDepthFloorPoint){0,1,0},0,0,1.6);
    points[0].x = NAN;
    assert(ROBDepthFloorFit(points,1600,options).valid);
    for (size_t i = 0; i < 500; ++i) points[i].y = INFINITY;
    ROBDepthFloorModel invalid = ROBDepthFloorFit(points,1600,options);
    assert(!invalid.valid);
    ROBDepthFloorPoint unchanged = ROBDepthFloorRectify(invalid,(ROBDepthFloorPoint){1,2,3},true);
    assert(unchanged.x == 1 && unchanged.y == 2 && unchanged.z == 3);
    options.maximumSamples = 4096;
    assert(ROBDepthFloorFit(points,1600,options).rejection == ROBDepthFloorInvalidOptions);
    options = ROBDepthFloorDefaultOptions(); options.maximumTiltRadians = NAN;
    assert(ROBDepthFloorFit(points,1600,options).rejection == ROBDepthFloorInvalidOptions);

    floor_points(points,12000,actualNormal,actualOffset,.008,2.0);
    options = ROBDepthFloorDefaultOptions();
    clock_t start = clock();
    for (int i = 0; i < 100; ++i) assert(ROBDepthFloorFit(points,12000,options).valid);
    printf("Floor rectification passed: robust bounded deterministic fit, rigid distances/heights, optional gated floor snap, coverage/noise/ambiguity/invalid-input rejection; %.3f ms/fit at2048 samples; no camera or actuator IO\n",
        1000.0*(clock()-start)/CLOCKS_PER_SEC/100);
    return 0;
}
