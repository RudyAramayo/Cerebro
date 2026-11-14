import Foundation

/// Passive camera attention only. A ready neck plus advancing exposures with
/// a stationary sensor window can finish early; missing evidence keeps the
/// existing 1.5 s fallback. This never grants arm clearance or refreshes pixels.
struct ROBPassiveViewSettling {
    struct Exposure {
        let generation: String, sequence: UInt64, capturedAt: Double
        let stationary: Bool, validIMU: Bool, imuWindowMilliseconds: Double, imuSamples: Int
    }
    private var since: Double?
    private var notBefore = 0.0
    private var anchor: Exposure?
    private(set) var method = "waiting"
    mutating func observe(ready: Bool, exposure: Exposure?, nowUptime: Double, nowMilliseconds: Double,
                          maximumAgeMilliseconds: Double) -> Bool {
        guard ready, nowUptime.isFinite, nowMilliseconds.isFinite else {
            since=nil; anchor=nil; method="waiting"; return false
        }
        if since == nil { since=nowUptime; notBefore=nowMilliseconds; anchor=nil }
        let elapsed=nowUptime-since!
        guard elapsed >= 0 else { since=nil; anchor=nil; return false }
        if elapsed >= 1.5 { method="ready_neck_1.5s_fallback"; return true }
        guard let frame=exposure, frame.sequence>0, frame.capturedAt.isFinite,
              frame.capturedAt>=notBefore,
              (0...maximumAgeMilliseconds).contains(nowMilliseconds-frame.capturedAt),
              frame.validIMU,frame.stationary,frame.imuWindowMilliseconds>=300,frame.imuSamples>=20 else {
            anchor=nil; return false
        }
        if let first=anchor,first.generation==frame.generation,
           frame.sequence>first.sequence,frame.capturedAt-first.capturedAt>=300,elapsed>=0.3 {
            method="advancing_stationary_imu_exposures";return true
        }
        if anchor == nil || anchor!.generation != frame.generation || frame.sequence<anchor!.sequence || frame.capturedAt<anchor!.capturedAt { anchor=frame }
        return false
    }
}
