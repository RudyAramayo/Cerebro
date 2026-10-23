import Foundation
import simd

/// A raw, synchronized observation for fitting the moving neck/camera chain.
/// It contains no actuator authority and never declares camera registration.
struct ROBNeckQRMeasurement: Codable, Equatable {
    static let targetID = "ROB:TABLE:001"
    static let supportedTargetIDs = [targetID, "ROB:FLOOR:L01", "ROB:FLOOR:R01", "ROB:WALL:R01"]
    static let symbolSideMeters = 0.12

    let targetID: String
    /// Canonical TL/TR/BR/BL order in Vision's normalized, bottom-left frame.
    let cornersNormalized: [[Double]]
    /// Factory intrinsics [fx, fy, cx, cy] for the aligned depth dimensions.
    let cameraMatrix: [Double]
    /// Top-left image coordinates: x = normalizedX * width; y = (1-y) * height.
    /// These are continuous image coordinates, not rounded or clamped samples.
    let cornersPixels: [[Double]]
    let centerPixel: [Double]
    /// Row-major transforms supplied by the raw articulated model. The
    /// provisional display correction must not be applied.
    let rawCameraToBase: [Double]
    let baseToNeck: [Double]
    /// Optional diagnostic using raw model geometry, not measured registration.
    let estimatedMarkerCenterBase: [Double]?
    let capturedAtMilliseconds: Double
    let sequence: UInt64
    let neckPanDegrees: Double
    let neckUpperTarget: Int

    enum MeasurementError: LocalizedError {
        case wrongTarget, invalidCorners, invalidIntrinsics, invalidTransform
        case invalidCapture, invalidView, invalidDepth
        var errorDescription: String? {
            switch self {
            case .wrongTarget: return "The observed QR is not a supported ROB calibration target."
            case .invalidCorners: return "The QR corners are missing, reversed, outside the image or degenerate."
            case .invalidIntrinsics: return "Aligned depth dimensions or factory camera intrinsics are invalid."
            case .invalidTransform: return "A raw neck/camera transform is not a finite rigid transform."
            case .invalidCapture: return "The QR sample has no valid capture timestamp or sequence."
            case .invalidView: return "The QR sample has invalid recorded neck targets."
            case .invalidDepth: return "The QR center depth is invalid."
            }
        }
    }

    static func make(payload: String = targetID, cornersNormalized corners: [SIMD2<Double>],
                     depthWidth: Int, depthHeight: Int, intrinsics: [Double],
                     opticalToBase: simd_double4x4, baseToNeck: simd_double4x4,
                     capturedAtMilliseconds: Double, sequence: UInt64,
                     neckPanDegrees: Double, neckUpperTarget: Int,
                     centerDepthMeters: Double? = nil) throws -> Self {
        guard supportedTargetIDs.contains(payload) else { throw MeasurementError.wrongTarget }
        let center = try centerNormalized(of: corners)
        guard (1...32_768).contains(depthWidth), (1...32_768).contains(depthHeight),
              intrinsics.count == 4, intrinsics.allSatisfy(\.isFinite),
              intrinsics[0] > 0, intrinsics[1] > 0,
              (0..<Double(depthWidth)).contains(intrinsics[2]),
              (0..<Double(depthHeight)).contains(intrinsics[3]) else {
            throw MeasurementError.invalidIntrinsics
        }
        guard isRigid(opticalToBase), isRigid(baseToNeck) else {
            throw MeasurementError.invalidTransform
        }
        guard capturedAtMilliseconds.isFinite, capturedAtMilliseconds > 0, sequence > 0 else {
            throw MeasurementError.invalidCapture
        }
        // This validates recorded data, not a safe command range. Mechanical
        // limits remain the responsibility of the existing neck executor.
        guard neckPanDegrees.isFinite, abs(neckPanDegrees) <= 180,
              (0...16_383).contains(neckUpperTarget) else { throw MeasurementError.invalidView }
        func pixel(_ point: SIMD2<Double>) -> [Double] {
            [point.x * Double(depthWidth), (1-point.y) * Double(depthHeight)]
        }
        let centerPixel = pixel(center)
        var estimate: [Double]?
        if let depth = centerDepthMeters {
            guard depth.isFinite, depth > 0, depth <= 20 else { throw MeasurementError.invalidDepth }
            let camera = SIMD4((centerPixel[0]-intrinsics[2])*depth/intrinsics[0],
                               (centerPixel[1]-intrinsics[3])*depth/intrinsics[1], depth, 1)
            let point = opticalToBase * camera
            guard [point.x, point.y, point.z].allSatisfy(\.isFinite) else {
                throw MeasurementError.invalidDepth
            }
            estimate = [point.x, point.y, point.z]
        }
        return .init(targetID: payload, cornersNormalized: corners.map { [$0.x, $0.y] },
            cameraMatrix: intrinsics, cornersPixels: corners.map(pixel), centerPixel: centerPixel,
            rawCameraToBase: rows(opticalToBase), baseToNeck: rows(baseToNeck),
            estimatedMarkerCenterBase: estimate, capturedAtMilliseconds: capturedAtMilliseconds,
            sequence: sequence, neckPanDegrees: neckPanDegrees, neckUpperTarget: neckUpperTarget)
    }

    /// Perspective preserves the diagonal intersection of a square. Its
    /// bounding-box midpoint or mean of four corners need not be the center.
    static func centerNormalized(of corners: [SIMD2<Double>]) throws -> SIMD2<Double> {
        guard corners.count == 4,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw MeasurementError.invalidCorners
        }
        // TL/TR/BR/BL is clockwise in Vision's bottom-left/Y-up coordinates.
        for i in 0..<4 {
            let a = corners[(i+1)%4]-corners[i], b = corners[(i+2)%4]-corners[(i+1)%4]
            guard cross(a,b) < -1e-10 else { throw MeasurementError.invalidCorners }
        }
        let twiceArea = (0..<4).reduce(0.0) { $0+cross(corners[$1],corners[($1+1)%4]) }
        guard twiceArea < -2e-6 else { throw MeasurementError.invalidCorners }
        let diagonal = corners[2]-corners[0], other = corners[3]-corners[1]
        let denominator = cross(diagonal,other)
        guard denominator.isFinite, abs(denominator) > 1e-10 else {
            throw MeasurementError.invalidCorners
        }
        let t = cross(corners[1]-corners[0],other)/denominator
        let result = corners[0]+t*diagonal
        guard t > 0, t < 1, result.x.isFinite, result.y.isFinite else {
            throw MeasurementError.invalidCorners
        }
        return result
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x*b.y-a.y*b.x }
    private static func rows(_ m: simd_double4x4) -> [Double] {
        (0..<4).flatMap { row in (0..<4).map { m[$0][row] } }
    }
    private static func isRigid(_ m: simd_double4x4) -> Bool {
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { m[c][$0].isFinite } }),
              abs(m.columns.0.w) <= 1e-9, abs(m.columns.1.w) <= 1e-9,
              abs(m.columns.2.w) <= 1e-9, abs(m.columns.3.w-1) <= 1e-9 else { return false }
        let x = SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z)
        let y = SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z)
        let z = SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z)
        return abs(simd_length_squared(x)-1) <= 1e-6 && abs(simd_length_squared(y)-1) <= 1e-6 &&
            abs(simd_length_squared(z)-1) <= 1e-6 && abs(simd_dot(x,y)) <= 1e-6 &&
            abs(simd_dot(x,z)) <= 1e-6 && abs(simd_dot(y,z)) <= 1e-6 &&
            abs(simd_dot(x,simd_cross(y,z))-1) <= 1e-6
    }
}
