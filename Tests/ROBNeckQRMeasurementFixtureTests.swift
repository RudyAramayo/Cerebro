import Foundation
import simd

@main struct NeckQRMeasurementFixtures {
    static func main() throws {
        let square = [SIMD2<Double>(0.2,0.8), SIMD2(0.8,0.8), SIMD2(0.8,0.2), SIMD2(0.2,0.2)]
        let identity = matrix_identity_double4x4
        var raw = simd_double4x4(simd_quatd(angle: .pi/2, axis: SIMD3<Double>(0,0,1)))
        raw.columns.3 = SIMD4(0.3,-0.2,1.1,1)
        func make(corners: [SIMD2<Double>] = square, matrix: simd_double4x4 = identity,
                  neck: simd_double4x4 = identity, width: Int = 640, height: Int = 480,
                  k: [Double] = [500,500,320,240], capture: Double = 1000,
                  sequence: UInt64 = 1, depth: Double? = nil, payload: String = ROBNeckQRMeasurement.targetID,
                  pan: Double = 10, upper: Int = 6306) throws -> ROBNeckQRMeasurement {
            try .make(payload:payload,cornersNormalized:corners,depthWidth:width,depthHeight:height,
                intrinsics:k,opticalToBase:matrix,baseToNeck:neck,capturedAtMilliseconds:capture,
                sequence:sequence,neckPanDegrees:pan,neckUpperTarget:upper,centerDepthMeters:depth)
        }
        func blocked(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("Invalid QR sample accepted") }
            catch is ROBNeckQRMeasurement.MeasurementError { }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let record = try make(matrix:raw,depth:0.8)
        precondition(record.targetID == "ROB:TABLE:001" && ROBNeckQRMeasurement.symbolSideMeters == 0.12)
        precondition(record.cornersPixels[0] == [128,95.99999999999997])
        precondition(abs(record.centerPixel[0]-320) < 1e-10 && abs(record.centerPixel[1]-240) < 1e-10)
        precondition(record.estimatedMarkerCenterBase!.enumerated().allSatisfy { abs($0.element-[0.3,-0.2,1.9][$0.offset]) < 1e-10 })
        precondition(record.rawCameraToBase[3] == 0.3 && record.rawCameraToBase[7] == -0.2 && record.rawCameraToBase[11] == 1.1)
        precondition(record.rawCameraToBase[12...15].elementsEqual([0,0,0,1]))
        let decoded = try JSONDecoder().decode(ROBNeckQRMeasurement.self,from:JSONEncoder().encode(record))
        precondition(decoded == record)
        let noDepth = try make()
        precondition(noDepth.estimatedMarkerCenterBase == nil)

        // Noncentral observations exercise both intrinsics and full rigid
        // rotation, rather than checking translation along the optical axis.
        let shifted = square.map { $0+SIMD2<Double>(0.05,-0.1) }
        let offcenter = try make(corners:shifted,matrix:raw,depth:0.8)
        let expected = raw*SIMD4<Double>((352-320)*0.8/500,(288-240)*0.8/500,0.8,1)
        precondition(zip(offcenter.estimatedMarkerCenterBase!,[expected.x,expected.y,expected.z]).allSatisfy { abs($0-$1)<1e-10 })

        // An oblique image of the paper has a projective center. Build it
        // from a known homography and compare against the diagonal helper.
        let paper = [SIMD2<Double>(-1,1), SIMD2(1,1), SIMD2(1,-1), SIMD2(-1,-1)]
        func project(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let w = 1+0.16*p.x-0.09*p.y
            return SIMD2((0.18*p.x+0.5)/w,(0.14*p.y+0.5)/w)
        }
        let trapezoid = paper.map(project), center = try ROBNeckQRMeasurement.centerNormalized(of:trapezoid)
        precondition(simd_distance(center,project(.zero)) < 1e-10)
        precondition(simd_distance(center,trapezoid.reduce(.zero,+)/4) > 0.005)

        let angle = 0.7, pivot = SIMD2<Double>(0.5,0.5)
        let rotated = square.map { p -> SIMD2<Double> in
            let q = p-pivot
            return SIMD2(cos(angle)*q.x-sin(angle)*q.y,sin(angle)*q.x+cos(angle)*q.y)+pivot
        }
        let rotatedCenter = try ROBNeckQRMeasurement.centerNormalized(of:rotated)
        precondition(simd_distance(rotatedCenter,pivot) < 1e-10)
        blocked { _ = try make(corners:Array(square.reversed())) }
        blocked { _ = try make(corners:[square[0],square[2],square[1],square[3]]) }
        blocked { _ = try make(corners:[square[0],square[1],square[1],square[3]]) }
        blocked { _ = try make(corners:[SIMD2(-0.1,0.8),square[1],square[2],square[3]]) }
        blocked { _ = try make(corners:[SIMD2(.nan,0.8),square[1],square[2],square[3]]) }
        blocked { _ = try make(corners:Array(square.prefix(3))) }
        blocked { _ = try make(corners:square.map { SIMD2(0.5,0.5)+($0-SIMD2(0.5,0.5))*0.0001 }) }
        for k in [[0,500,320,240],[500,.nan,320,240],[500,500,640,240],[500,500,320,-1],[500,500]] {
            blocked { _ = try make(k:k) }
        }
        blocked { _ = try make(width:0) }; blocked { _ = try make(height:32_769) }
        var invalid = identity; invalid.columns.0.x = 2
        blocked { _ = try make(matrix:invalid) }
        invalid = identity; invalid.columns.2.z = -1
        blocked { _ = try make(neck:invalid) }
        invalid = identity; invalid.columns.3.x = .infinity
        blocked { _ = try make(matrix:invalid) }
        invalid = identity; invalid.columns.0.w = 0.1
        blocked { _ = try make(matrix:invalid) }
        for depth in [0.0,-0.1,Double.nan,Double.infinity,20.1] { blocked { _ = try make(depth:depth) } }
        for time in [0.0,-1,Double.nan,Double.infinity] { blocked { _ = try make(capture:time) } }
        blocked { _ = try make(sequence:0) }; blocked { _ = try make(payload:"unrelated") }
        blocked { _ = try make(pan:.nan) }; blocked { _ = try make(pan:181) }
        blocked { _ = try make(upper:-1) }; blocked { _ = try make(upper:16_384) }
        print("Neck QR measurement fixtures passed: canonical corners, projective center, raw rigid projection, Codable round trip and invalid capture rejection; no hardware transport")
    }
}
