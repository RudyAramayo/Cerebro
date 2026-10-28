import Foundation
import simd

/// Read-only sensor evidence shared by missions and Controller Diagnostics.
/// Call only after AutoNet has authenticated the lidar publisher. No renderer
/// owns a sensor, renews timestamps, or supplies motion/clearance authority.
final class ROBRoomSpatialStore {
    static let shared = ROBRoomSpatialStore()
    private(set) var scan: ROBLidarScanFrame?
    private(set) var map: ROBRoomMissionMap?
    private(set) var depthGeneration: UInt64 = 0
    var requestCanApproachPreview: (() -> Void)?
    var canApproachPreview: ROBRoomCanApproach?
    var canApproachClearance = 0.0
    var canApproachDetail = "Plan an approach after a fresh front-table scan. No tread commands."
    private var assembler = ROBRoomMapAssembler()
    private var epoch: UUID?
    private var anchor: ROBLidarScanFrame?
    private var poseAt = -Double.infinity
    private var mapAt = -Double.infinity
    private struct PoseStamp { let time: Double, x: Double, y: Double, yaw: Double }
    private var poseHistory = [PoseStamp]()

    func poseStillMatches(capturedAtMilliseconds: Double) -> Bool {
        poseMatchFailure(capturedAtMilliseconds: capturedAtMilliseconds) == nil
    }

    func poseMatchFailure(capturedAtMilliseconds: Double) -> String? {
        guard let current = scan, let old = poseHistory.min(by: {
            abs($0.time-capturedAtMilliseconds) < abs($1.time-capturedAtMilliseconds)
        }), abs(old.time-capturedAtMilliseconds) <= 750 else {
            return "No time-matched SLAM pose for the can observation; reacquire the can with live lidar."
        }
        let distance = hypot(old.x-Double(current.x),old.y-Double(current.y))
        let turn = abs(atan2(sin(old.yaw-Double(current.yaw)),cos(old.yaw-Double(current.yaw))))
        guard distance <= 0.05, turn <= 0.05 else {
            return String(format: "SLAM changed by %.0f mm / %.1f° since the can observation; reacquire the can at the current base pose.", distance*1000, turn*180 / .pi)
        }
        return nil
    }

    @discardableResult func consume(_ frame: ROBLidarScanFrame,
        now: Double = ProcessInfo.processInfo.systemUptime,
        wallMilliseconds: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        precondition(Thread.isMainThread)
        let age = wallMilliseconds - Double(frame.sentAtMilliseconds)
        // AutoNet owns per-session replay admission. A publisher restart can
        // keep its device UUID while resetting its sequence; do not lock the
        // new authenticated session out behind a previous process's counter.
        let restarted = scan.map { $0.deviceID == frame.deviceID && frame.sequence <= $0.sequence &&
            frame.sentAtMilliseconds > $0.sentAtMilliseconds } ?? false
        guard wallMilliseconds.isFinite, wallMilliseconds > 0, wallMilliseconds < Double(UInt64.max),
              (-500...2_000).contains(age), now.isFinite,
              frame.validationError(authenticatedDeviceID: frame.deviceID,
                lastAcceptedSequence: scan?.deviceID == frame.deviceID && !restarted ? scan!.sequence : 0,
                nowMilliseconds: UInt64(wallMilliseconds)) == nil else { return false }
        let sourceChanged = scan?.deviceID != frame.deviceID
        let epochChanged = frame.mapFragment.map { epoch != nil && epoch != $0.epoch } ?? false
        if sourceChanged || epochChanged || restarted {
            map = nil; mapAt = -.infinity; assembler = ROBRoomMapAssembler()
            epoch = frame.mapFragment?.epoch
            poseHistory = []
        }
        // Accumulate displacement against a fixed anchor: a succession of
        // small manual moves must also invalidate stationary RGB-D history.
        let moved = anchor.map {
            hypot(Double(frame.x-$0.x), Double(frame.y-$0.y)) > 0.025 ||
            abs(atan2(sin(Double(frame.yaw-$0.yaw)), cos(Double(frame.yaw-$0.yaw)))) > 0.02 ||
            abs(Double(frame.z-$0.z)) > 0.025 || abs(Double(frame.pitch-$0.pitch)) > 0.02 ||
            abs(Double(frame.roll-$0.roll)) > 0.02
        } ?? true
        if sourceChanged || epochChanged || restarted || moved || !poseIsFresh(at: now) {
            depthGeneration &+= 1; anchor = frame
            if canApproachPreview != nil {
                canApproachPreview = nil
                canApproachDetail = "Base pose changed; replan the can approach from fresh observations."
            }
        }
        scan = frame; poseAt = now - max(0, age) / 1000
        poseHistory.append(.init(time:Double(frame.sentAtMilliseconds),x:Double(frame.x),y:Double(frame.y),yaw:Double(frame.yaw)))
        if poseHistory.count>400 { poseHistory.removeFirst(poseHistory.count-400) }
        if let fragment = frame.mapFragment {
            epoch = fragment.epoch
            // Late chunks cannot replace a newer complete snapshot.
            if map == nil || fragment.revision >= map!.revision,
               let complete = assembler.consume(fragment, device: frame.deviceID, now: wallMilliseconds) {
                if map?.revision != complete.revision, let proposal = canApproachPreview,
                   let start = proposal.route.first {
                    let checked = ROBRoomMissionPlanner(map:complete,clearanceMeters:canApproachClearance,origin:start,radius:10)
                    if checked == nil || !zip(proposal.route,proposal.route.dropFirst()).allSatisfy({checked!.segmentIsFree($0.0,$0.1)}) {
                        canApproachPreview = nil
                        canApproachDetail = "Updated room map blocks the proposed approach; replan."
                    }
                }
                map = complete
                mapAt = now - max(0, wallMilliseconds-complete.capturedAtMilliseconds) / 1000
            }
        }
        return true
    }

    func poseAge(at now: Double) -> Double { now-poseAt }
    func mapAge(at now: Double) -> Double { now-mapAt }
    func poseIsFresh(at now: Double) -> Bool { scan != nil && (0...0.75).contains(poseAge(at: now)) }
    func mapIsFresh(at now: Double) -> Bool { map != nil && (0...15).contains(mapAge(at: now)) }
}

/// Metric transforms only. SDK +X is heading zero, +Y is left, yaw is CCW.
/// A laser hit remains at scanner height; a 2D free cell says nothing about
/// the volume above it. Depth observations are never erased by the floor map.
enum ROBRoomSpatialGeometry {
    static func mapToBase(scan: ROBLidarScanFrame, lidarToBase: simd_double4x4) -> simd_double4x4 {
        let c = cos(Double(scan.yaw)), s = sin(Double(scan.yaw))
        var mapToLidar = matrix_identity_double4x4
        mapToLidar.columns.0 = SIMD4(c, -s, 0, 0)
        mapToLidar.columns.1 = SIMD4(s, c, 0, 0)
        mapToLidar.columns.3 = SIMD4(-c*Double(scan.x)-s*Double(scan.y),
                                     s*Double(scan.x)-c*Double(scan.y), 0, 1)
        var result = lidarToBase * mapToLidar
        // The raster is a ground reference, not a surface at laser height.
        result.columns.0.z = 0; result.columns.1.z = 0; result.columns.3.z = 0.008
        return result
    }

    static func laserPoint(_ p: ROBLidarWirePoint, lidarToBase: simd_double4x4) -> SIMD3<Double> {
        let v = lidarToBase * SIMD4(cos(Double(p.angleRadians))*Double(p.distanceMeters),
                                    sin(Double(p.angleRadians))*Double(p.distanceMeters), 0, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    /// Raw row zero is minimum map Y. The texture's top row is maximum Y.
    static func rasterRGBA(_ map: ROBRoomMissionMap) -> Data? {
        guard map.valid else { return nil }
        let cells = [UInt8](map.cells)
        var pixels = [UInt8](repeating: 255, count: cells.count*4)
        for y in 0..<map.height { for x in 0..<map.width {
            let value = Int8(bitPattern: cells[(map.height-1-y)*map.width+x])
            let color: (UInt8,UInt8,UInt8) = value < 0 ? (245,158,65) : value > 0 ? (24,55,73) : (65,65,76)
            let i = (y*map.width+x)*4
            pixels[i] = color.0; pixels[i+1] = color.1; pixels[i+2] = color.2
        } }
        return Data(pixels)
    }
}
