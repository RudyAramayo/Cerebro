import Foundation
import simd

/// Relative six-axis clutch: moving a hand never sends an absolute AR world
/// coordinate to the robot. Rotation occurs about the measured tool, not the hand.
struct ROBArmTeleoperationClutch {
    let trackingID: UUID
    let controllerOrigin: simd_double4x4
    let toolOrigin: simd_double4x4
    let robotFromTracking: simd_quatd
    let scale: Double
    private(set) var sampleID: UInt64
    private(set) var lastController: simd_double4x4

    init(sample: ROBShadowTrackingSample, tool: simd_double4x4, scale: Double) throws {
        let controller = try Self.transform(sample.pose)
        guard sample.isValid, sample.quality == "tracked", sample.ageMilliseconds <= 150,
              ROBSerialChain.rigid(tool), [0.2, 1].contains(scale) else { throw Self.blocked("Fresh accurate tracking and a measured tool pose are required.") }
        // Point the controller forward when clutching. AR up is +Y, controller
        // forward is -Z. This is a proper rotation into ROB +X forward/+Y left/+Z up.
        let forward = -SIMD3(controller[2].x, 0, controller[2].z)
        guard simd_length(forward) >= 0.5 else { throw Self.blocked("Point the controller level and forward before holding the grips.") }
        let x = simd_normalize(forward), z = SIMD3<Double>(0, 1, 0), y = simd_cross(z, x)
        robotFromTracking = simd_quatd(simd_double3x3(columns: (x, y, z)).transpose).normalized
        trackingID = sample.trackingID; sampleID = sample.sampleID
        controllerOrigin = controller; lastController = controller; toolOrigin = tool; self.scale = scale
    }

    mutating func update(_ sample: ROBShadowTrackingSample) throws {
        guard sample.isValid, sample.quality == "tracked", sample.ageMilliseconds <= 150,
              sample.trackingID == trackingID, sample.sampleID > sampleID else {
            throw Self.blocked("Controller tracking changed or expired. Release and re-clutch.")
        }
        let next = try Self.transform(sample.pose)
        guard simd_distance(ROBSerialChain.translation(next), ROBSerialChain.translation(lastController)) <= 0.20,
              Self.angle(simd_quatd(next), simd_quatd(lastController)) <= 0.8 else {
            throw Self.blocked("Controller pose jumped. Hold, then release and re-clutch.")
        }
        lastController = next; sampleID = sample.sampleID
    }

    func target(from measured: simd_double4x4, seconds: Double) throws -> simd_double4x4 {
        guard ROBSerialChain.rigid(measured), seconds.isFinite, (0.01...1).contains(seconds) else { throw Self.blocked("Invalid measured interpolation origin.") }
        let translation = robotFromTracking.act(ROBSerialChain.translation(lastController) - ROBSerialChain.translation(controllerOrigin)) * scale
        let desiredPosition = ROBSerialChain.translation(toolOrigin) + translation
        let delta = robotFromTracking * simd_quatd(lastController) * simd_quatd(controllerOrigin).inverse * robotFromTracking.inverse
        let desiredRotation = (delta * simd_quatd(toolOrigin)).normalized
        // No integration or extrapolation of stale input. Each bounded segment
        // begins at feedback, using XYZ lerp and shortest-arc quaternion SLERP.
        let distance = simd_distance(desiredPosition, ROBSerialChain.translation(measured))
        let angle = Self.angle(simd_quatd(measured), desiredRotation)
        guard distance <= 0.25, angle <= 1.2 else { throw Self.blocked("Hand-to-arm error exceeds the clutch workspace. Release and re-clutch.") }
        let fraction = min(1, min(0.03 * seconds / max(distance, 1e-12), 0.25 * seconds / max(angle, 1e-12)))
        var result = simd_double4x4(simd_slerp(simd_quatd(measured).normalized, desiredRotation, fraction).normalized)
        result[3] = SIMD4(ROBSerialChain.translation(measured) + (desiredPosition - ROBSerialChain.translation(measured)) * fraction, 1)
        return result
    }
    static func transform(_ pose: ROBShadowPose) throws -> simd_double4x4 {
        guard pose.isValid else { throw blocked("Invalid XYZ/quaternion pose.") }
        let p = pose.position, q = pose.quaternion
        var result = simd_double4x4(simd_quatd(ix: q[0], iy: q[1], iz: q[2], r: q[3]).normalized)
        result[3] = SIMD4(p[0], p[1], p[2], 1); return result
    }
    static func angle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
        2 * acos(min(1, abs(simd_dot(a.normalized.vector, b.normalized.vector))))
    }
    static func blocked(_ detail: String) -> ROBKinematicsError { .invalid(detail) }
}
