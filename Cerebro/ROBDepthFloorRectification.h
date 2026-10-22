#ifndef ROBDepthFloorRectification_h
#define ROBDepthFloorRectification_h

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Display-only floor alignment. Inputs and translations are METERS in a
 * y-up frame, before any presentation scale. The caller must select likely
 * floor pixels using image ROI and expected world height. Geometry alone
 * cannot identify wood or distinguish a low tabletop from an identical plane.
 * This estimate confers no motion, collision, or force authority. */
typedef struct { double x, y, z; } ROBDepthFloorPoint;

typedef enum {
    ROBDepthFloorAccepted = 0,
    ROBDepthFloorInvalidOptions,
    ROBDepthFloorInsufficientPoints,
    ROBDepthFloorNoBoundedPlane,
    ROBDepthFloorInsufficientSupport,
    ROBDepthFloorPoorCoverage,
    ROBDepthFloorExcessNoise,
    ROBDepthFloorAmbiguousPlane,
    ROBDepthFloorUnstableRefit
} ROBDepthFloorRejection;

typedef struct {
    size_t maximumSamples;
    size_t minimumInliers;
    unsigned ransacIterations;
    double minimumInlierFraction;
    double inlierToleranceMeters;
    double maximumRMSMeters;
    double minimumSpanMeters;
    double minimumMinorRMSMeters;
    unsigned minimumCoveredCells;
    double maximumTiltRadians;
    double maximumVerticalOffsetMeters;
} ROBDepthFloorOptions;

typedef struct {
    bool valid;
    ROBDepthFloorRejection rejection;
    ROBDepthFloorPoint normal; /* Unit normal, positive Y. n.p + offset = 0. */
    double offsetMeters;
    double correction[12]; /* Rigid row-major 3x4: normal -> +Y, floor -> Y=0. */
    double inlierToleranceMeters;
    size_t inputCount, sampleCount, inlierCount;
    double inlierFraction, rmsMeters, tiltRadians, verticalOffsetMeters;
    double spanXMeters, spanZMeters, minorRMSMeters;
    unsigned coveredCells;
    double confidence; /* Fit quality only; not a calibrated probability. */
} ROBDepthFloorModel;

enum { ROBDepthFloorMaximumSamples = 2048 };

static inline ROBDepthFloorOptions ROBDepthFloorDefaultOptions(void) {
    ROBDepthFloorOptions o = {2048, 80, 96, .55, .020, .009, .40, .08, 8,
                              30.0 * 3.14159265358979323846 / 180.0, .35};
    return o;
}

static inline const char *ROBDepthFloorRejectionName(ROBDepthFloorRejection r) {
    switch (r) {
        case ROBDepthFloorAccepted: return "accepted";
        case ROBDepthFloorInvalidOptions: return "invalid options";
        case ROBDepthFloorInsufficientPoints: return "insufficient finite floor candidates";
        case ROBDepthFloorNoBoundedPlane: return "no plane within floor tilt/height bounds";
        case ROBDepthFloorInsufficientSupport: return "insufficient floor-plane support";
        case ROBDepthFloorPoorCoverage: return "floor coverage is too small or line-like";
        case ROBDepthFloorExcessNoise: return "floor residual noise is too high";
        case ROBDepthFloorAmbiguousPlane: return "multiple plausible floor planes";
        case ROBDepthFloorUnstableRefit: return "floor-plane refit is unstable";
    }
    return "unknown floor-fit result";
}

static inline double ROBDepthFloorDot(ROBDepthFloorPoint a, ROBDepthFloorPoint b) {
    return a.x*b.x + a.y*b.y + a.z*b.z;
}
static inline ROBDepthFloorPoint ROBDepthFloorScale(ROBDepthFloorPoint a, double s) {
    return (ROBDepthFloorPoint){a.x*s, a.y*s, a.z*s};
}
static inline ROBDepthFloorPoint ROBDepthFloorSubtract(ROBDepthFloorPoint a, ROBDepthFloorPoint b) {
    return (ROBDepthFloorPoint){a.x-b.x, a.y-b.y, a.z-b.z};
}
static inline ROBDepthFloorPoint ROBDepthFloorCross(ROBDepthFloorPoint a, ROBDepthFloorPoint b) {
    return (ROBDepthFloorPoint){a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}
static inline bool ROBDepthFloorFinite(ROBDepthFloorPoint p) {
    return isfinite(p.x) && isfinite(p.y) && isfinite(p.z);
}

static inline bool ROBDepthFloorOptionsValid(ROBDepthFloorOptions o) {
    return o.maximumSamples >= 80 && o.maximumSamples <= ROBDepthFloorMaximumSamples &&
        o.minimumInliers >= 80 && o.minimumInliers <= o.maximumSamples &&
        o.ransacIterations >= 16 && o.ransacIterations <= 256 &&
        isfinite(o.minimumInlierFraction) && o.minimumInlierFraction >= .5 && o.minimumInlierFraction <= 1 &&
        isfinite(o.inlierToleranceMeters) && o.inlierToleranceMeters > 0 && o.inlierToleranceMeters <= .05 &&
        isfinite(o.maximumRMSMeters) && o.maximumRMSMeters > 0 && o.maximumRMSMeters <= o.inlierToleranceMeters &&
        isfinite(o.minimumSpanMeters) && o.minimumSpanMeters >= .1 && o.minimumSpanMeters <= 10 &&
        isfinite(o.minimumMinorRMSMeters) && o.minimumMinorRMSMeters > 0 && o.minimumMinorRMSMeters <= o.minimumSpanMeters &&
        o.minimumCoveredCells >= 4 && o.minimumCoveredCells <= 16 &&
        isfinite(o.maximumTiltRadians) && o.maximumTiltRadians > 0 && o.maximumTiltRadians <= 3.14159265358979323846 / 3 &&
        isfinite(o.maximumVerticalOffsetMeters) && o.maximumVerticalOffsetMeters > 0 && o.maximumVerticalOffsetMeters <= 1;
}

static inline ROBDepthFloorModel ROBDepthFloorEmptyModel(ROBDepthFloorRejection rejection, size_t count) {
    ROBDepthFloorModel m = {0};
    m.rejection = rejection; m.inputCount = count;
    m.correction[0] = m.correction[5] = m.correction[10] = 1;
    return m;
}

static inline uint32_t ROBDepthFloorRandom(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    *state = x;
    return x;
}

typedef struct { ROBDepthFloorPoint n; double d, squaredError; size_t count; } ROBDepthFloorCandidate;

static inline bool ROBDepthFloorPlaneBounded(ROBDepthFloorPoint n, double d, ROBDepthFloorOptions o) {
    return ROBDepthFloorFinite(n) && isfinite(d) && n.y >= cos(o.maximumTiltRadians) &&
        fabs(d / n.y) <= o.maximumVerticalOffsetMeters;
}

static inline ROBDepthFloorCandidate ROBDepthFloorRansac(const ROBDepthFloorPoint *points, size_t count,
                                                        ROBDepthFloorOptions o, unsigned iterations, uint32_t seed) {
    ROBDepthFloorCandidate best = {{0, 1, 0}, 0, DBL_MAX, 0};
    for (unsigned iteration = 0; iteration < iterations; ++iteration) {
        size_t a = ROBDepthFloorRandom(&seed) % count;
        size_t b = ROBDepthFloorRandom(&seed) % count;
        size_t c = ROBDepthFloorRandom(&seed) % count;
        if (a == b || a == c || b == c) continue;
        ROBDepthFloorPoint n = ROBDepthFloorCross(ROBDepthFloorSubtract(points[b], points[a]),
                                                ROBDepthFloorSubtract(points[c], points[a]));
        double length = sqrt(ROBDepthFloorDot(n, n));
        if (!(length > 1e-8)) continue;
        n = ROBDepthFloorScale(n, (n.y < 0 ? -1 : 1) / length);
        double d = -ROBDepthFloorDot(n, points[a]);
        if (!ROBDepthFloorPlaneBounded(n, d, o)) continue;
        size_t support = 0; double squaredError = 0;
        for (size_t i = 0; i < count; ++i) {
            double residual = ROBDepthFloorDot(n, points[i]) + d;
            if (fabs(residual) <= o.inlierToleranceMeters) { ++support; squaredError += residual * residual; }
        }
        if (support > best.count || (support == best.count && squaredError < best.squaredError)) {
            best = (ROBDepthFloorCandidate){n, d, squaredError, support};
        }
    }
    return best;
}

/* Fixed-work Jacobi eigensolver for a symmetric 3x3 covariance matrix. */
static inline void ROBDepthFloorEigen(double covariance[3][3], double vectors[3][3], double values[3]) {
    for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) vectors[row][col] = row == col ? 1 : 0;
    const int axes[3][2] = {{0, 1}, {0, 2}, {1, 2}};
    for (int sweep = 0; sweep < 12; ++sweep) for (int pair = 0; pair < 3; ++pair) {
        int p = axes[pair][0], q = axes[pair][1];
        double off = covariance[p][q];
        if (fabs(off) < 1e-15) continue;
        double theta = (covariance[q][q] - covariance[p][p]) / (2 * off);
        double t = copysign(1.0, theta) / (fabs(theta) + hypot(theta, 1));
        double cosine = 1 / sqrt(1 + t*t), sine = t*cosine;
        covariance[p][p] -= t*off; covariance[q][q] += t*off;
        covariance[p][q] = covariance[q][p] = 0;
        for (int k = 0; k < 3; ++k) if (k != p && k != q) {
            double kp = covariance[k][p], kq = covariance[k][q];
            covariance[k][p] = covariance[p][k] = cosine*kp - sine*kq;
            covariance[k][q] = covariance[q][k] = sine*kp + cosine*kq;
        }
        for (int k = 0; k < 3; ++k) {
            double kp = vectors[k][p], kq = vectors[k][q];
            vectors[k][p] = cosine*kp - sine*kq; vectors[k][q] = sine*kp + cosine*kq;
        }
    }
    for (int i = 0; i < 3; ++i) values[i] = fmax(0, covariance[i][i]);
}

static inline bool ROBDepthFloorRefit(const ROBDepthFloorPoint *points, size_t count,
                                     ROBDepthFloorCandidate seed, double tolerance,
                                     ROBDepthFloorCandidate *fit, double *minorVariance) {
    ROBDepthFloorPoint center = {0}; size_t support = 0;
    double covariance[3][3] = {{0}};
    for (size_t i = 0; i < count; ++i) {
        if (fabs(ROBDepthFloorDot(seed.n, points[i]) + seed.d) > tolerance) continue;
        ++support;
        ROBDepthFloorPoint delta = ROBDepthFloorSubtract(points[i], center);
        center.x += delta.x / support; center.y += delta.y / support; center.z += delta.z / support;
        ROBDepthFloorPoint updated = ROBDepthFloorSubtract(points[i], center);
        double a[3] = {delta.x, delta.y, delta.z}, b[3] = {updated.x, updated.y, updated.z};
        for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) covariance[row][col] += a[row]*b[col];
    }
    if (support < 3) return false;
    for (int row = 0; row < 3; ++row) for (int col = row; col < 3; ++col) {
        double value = (covariance[row][col] + covariance[col][row]) / (2 * support);
        covariance[row][col] = covariance[col][row] = value;
    }
    double vectors[3][3], values[3]; ROBDepthFloorEigen(covariance, vectors, values);
    int order[3] = {0, 1, 2};
    for (int i = 0; i < 2; ++i) for (int j = i+1; j < 3; ++j) if (values[order[i]] > values[order[j]]) {
        int temporary = order[i]; order[i] = order[j]; order[j] = temporary;
    }
    ROBDepthFloorPoint n = {vectors[0][order[0]], vectors[1][order[0]], vectors[2][order[0]]};
    if (n.y < 0) n = ROBDepthFloorScale(n, -1);
    double length = sqrt(ROBDepthFloorDot(n, n));
    if (!(length > .99) || !ROBDepthFloorFinite(n)) return false;
    n = ROBDepthFloorScale(n, 1 / length);
    *fit = (ROBDepthFloorCandidate){n, -ROBDepthFloorDot(n, center), values[order[0]] * support, support};
    *minorVariance = values[order[1]];
    return true;
}

static inline ROBDepthFloorModel ROBDepthFloorFit(const ROBDepthFloorPoint *input, size_t count,
                                                ROBDepthFloorOptions o) {
    ROBDepthFloorModel result = ROBDepthFloorEmptyModel(ROBDepthFloorInvalidOptions, count);
    if (!ROBDepthFloorOptionsValid(o)) return result;
    result.inlierToleranceMeters = o.inlierToleranceMeters;
    result.rejection = ROBDepthFloorInsufficientPoints;
    if (!input || count < o.minimumInliers) return result;
    ROBDepthFloorPoint points[ROBDepthFloorMaximumSamples];
    size_t selected = count < o.maximumSamples ? count : o.maximumSamples, used = 0;
    uint32_t random = UINT32_C(0x8e73a19b);
    for (size_t i = 0; i < selected; ++i) {
        /* Deterministic stratified samples avoid depending on a prefix and
         * avoid row/stride aliasing in image-ordered clouds. */
        size_t index = i;
        if (count > selected) {
            double fraction = (ROBDepthFloorRandom(&random) + .5) / 4294967296.0;
            index = (size_t)(((double)i + fraction) * ((double)count / selected));
            if (index >= count) index = count - 1;
        }
        ROBDepthFloorPoint p = input[index];
        if (ROBDepthFloorFinite(p) && fabs(p.x) <= 100 && fabs(p.y) <= 100 && fabs(p.z) <= 100) points[used++] = p;
    }
    result.sampleCount = used;
    if (used < o.minimumInliers || used < .8 * selected) return result;
    ROBDepthFloorCandidate fit = ROBDepthFloorRansac(points, used, o, o.ransacIterations, UINT32_C(0x79125eab));
    result.rejection = ROBDepthFloorNoBoundedPlane;
    if (!fit.count) return result;
    result.rejection = ROBDepthFloorInsufficientSupport;
    if (fit.count < o.minimumInliers || fit.count < o.minimumInlierFraction * used) return result;
    double minorVariance = 0;
    for (int pass = 0; pass < 4; ++pass) {
        ROBDepthFloorCandidate refined;
        if (!ROBDepthFloorRefit(points, used, fit, o.inlierToleranceMeters, &refined, &minorVariance) ||
            !ROBDepthFloorPlaneBounded(refined.n, refined.d, o)) {
            result.rejection = ROBDepthFloorUnstableRefit; return result;
        }
        fit = refined;
    }
    result.normal = fit.n; result.offsetMeters = fit.d;
    result.tiltRadians = acos(fmax(-1, fmin(1, fit.n.y)));
    result.verticalOffsetMeters = -fit.d / fit.n.y;
    result.minorRMSMeters = sqrt(minorVariance);
    ROBDepthFloorPoint tangentX = {1-fit.n.x*fit.n.x, -fit.n.x*fit.n.y, -fit.n.x*fit.n.z};
    tangentX = ROBDepthFloorScale(tangentX, 1 / sqrt(ROBDepthFloorDot(tangentX, tangentX)));
    ROBDepthFloorPoint tangentZ = ROBDepthFloorCross(fit.n, tangentX);
    double minimumX = DBL_MAX, maximumX = -DBL_MAX, minimumZ = DBL_MAX, maximumZ = -DBL_MAX, squared = 0;
    for (size_t i = 0; i < used; ++i) {
        double residual = ROBDepthFloorDot(fit.n, points[i]) + fit.d;
        if (fabs(residual) > o.inlierToleranceMeters) continue;
        ++result.inlierCount; squared += residual * residual;
        double x = ROBDepthFloorDot(tangentX, points[i]), z = ROBDepthFloorDot(tangentZ, points[i]);
        minimumX = fmin(minimumX, x); maximumX = fmax(maximumX, x);
        minimumZ = fmin(minimumZ, z); maximumZ = fmax(maximumZ, z);
    }
    result.inlierFraction = (double)result.inlierCount / used;
    result.rmsMeters = result.inlierCount ? sqrt(squared / result.inlierCount) : DBL_MAX;
    if (result.inlierCount < o.minimumInliers || result.inlierFraction < o.minimumInlierFraction) return result;
    result.spanXMeters = maximumX - minimumX; result.spanZMeters = maximumZ - minimumZ;
    result.rejection = ROBDepthFloorPoorCoverage;
    if (result.spanXMeters < o.minimumSpanMeters || result.spanZMeters < o.minimumSpanMeters ||
        result.minorRMSMeters < o.minimumMinorRMSMeters) return result;
    unsigned cells[16] = {0};
    for (size_t i = 0; i < used; ++i) {
        if (fabs(ROBDepthFloorDot(fit.n, points[i]) + fit.d) > o.inlierToleranceMeters) continue;
        int x = (int)(4 * (ROBDepthFloorDot(tangentX, points[i])-minimumX) / result.spanXMeters);
        int z = (int)(4 * (ROBDepthFloorDot(tangentZ, points[i])-minimumZ) / result.spanZMeters);
        if (x > 3) x = 3; if (z > 3) z = 3;
        if (x < 0) x = 0; if (z < 0) z = 0;
        ++cells[z*4+x];
    }
    size_t minimumCellSupport = result.inlierCount / 64;
    if (minimumCellSupport < 2) minimumCellSupport = 2;
    for (int i = 0; i < 16; ++i) if (cells[i] >= minimumCellSupport) ++result.coveredCells;
    if (result.coveredCells < o.minimumCoveredCells) return result;
    result.rejection = ROBDepthFloorExcessNoise;
    if (result.rmsMeters > o.maximumRMSMeters) return result;
    /* A second broad plane cannot be resolved by asserting the larger one is
     * floor. Look only among points clearly outside the fitted floor band. */
    ROBDepthFloorPoint other[ROBDepthFloorMaximumSamples]; size_t otherCount = 0;
    for (size_t i = 0; i < used; ++i) if (fabs(ROBDepthFloorDot(fit.n, points[i]) + fit.d) > 2*o.inlierToleranceMeters) other[otherCount++] = points[i];
    if (otherCount >= o.minimumInliers && otherCount >= .25 * used) {
        ROBDepthFloorCandidate alternative = ROBDepthFloorRansac(other, otherCount, o,
            o.ransacIterations / 3, UINT32_C(0x534e942d));
        if (alternative.count >= o.minimumInliers && alternative.count >= .25 * used) {
            result.rejection = ROBDepthFloorAmbiguousPlane; return result;
        }
    }
    /* Shortest-arc rotation n -> +Y. Its second row is n, hence adding d
     * makes a point's corrected Y equal its signed height above the floor. */
    double vx = -fit.n.z, vz = fit.n.x, inverse = 1 / (1 + fit.n.y);
    result.correction[0] = 1-vz*vz*inverse;
    result.correction[1] = -vz;
    result.correction[2] = vx*vz*inverse;
    result.correction[3] = 0;
    result.correction[4] = vz;
    result.correction[5] = fit.n.y;
    result.correction[6] = -vx;
    result.correction[7] = fit.d;
    result.correction[8] = vx*vz*inverse;
    result.correction[9] = vx;
    result.correction[10] = 1-vx*vx*inverse;
    result.correction[11] = 0;
    result.confidence = result.inlierFraction * ((double)result.coveredCells / 16) *
        fmax(0, 1-result.rmsMeters/(2*o.maximumRMSMeters));
    result.valid = true; result.rejection = ROBDepthFloorAccepted;
    return result;
}

static inline bool ROBDepthFloorIsInlier(ROBDepthFloorModel model, ROBDepthFloorPoint p) {
    return model.valid && ROBDepthFloorFinite(p) &&
        fabs(ROBDepthFloorDot(model.normal, p) + model.offsetMeters) <= model.inlierToleranceMeters;
}

/* snapFloor is permission from the caller's ROI/height gate, not a semantic
 * classification inferred from every near-plane point in the whole cloud.
 * false preserves all pairwise distances and each object's floor height. */
static inline ROBDepthFloorPoint ROBDepthFloorRectify(ROBDepthFloorModel model, ROBDepthFloorPoint p, bool snapFloor) {
    if (!model.valid || !ROBDepthFloorFinite(p)) return p;
    const double *m = model.correction;
    ROBDepthFloorPoint corrected = {m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3],
        m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7], m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11]};
    if (snapFloor && ROBDepthFloorIsInlier(model, p)) corrected.y = 0;
    return corrected;
}

#endif
