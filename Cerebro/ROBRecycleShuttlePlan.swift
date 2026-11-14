import Foundation

/// A route preference in the tread-base frame, not a collision certificate.
/// Every physical arrival still reobserves depth/pose and plans a new grasp.
struct ROBRecycleShuttlePlan {
    struct Point { let x: Double, y: Double }
    static func propose(table: Point, bucket: Point, currentHeading: Double, debugCable: Bool,
                        minimumReach: Double = 0.25, maximumReach: Double = 0.65) throws -> [String: Any] {
        guard [table.x,table.y,bucket.x,bucket.y,currentHeading,minimumReach,maximumReach].allSatisfy(\.isFinite),
              minimumReach > 0, maximumReach > minimumReach else { throw ROBLocalControlError("Invalid shuttle geometry") }
        func wrap(_ value: Double) -> Double { atan2(sin(value * .pi/180),cos(value * .pi/180))*180 / .pi }
        // Right ready-gripper bearing is a model hypothesis, not the camera
        // calibration or a replay of the operator's visually aligned pose.
        let readyBearing = atan2(-0.20, 0.40)*180 / .pi
        let tableHeading = wrap(atan2(table.y,table.x)*180 / .pi-readyBearing)
        let bucketHeading = wrap(atan2(bucket.y,bucket.x)*180 / .pi-readyBearing)
        let tableRange = hypot(table.x,table.y), bucketRange = hypot(bucket.x,bucket.y)
        let sameAnchor = (minimumReach...maximumReach).contains(tableRange)
            && (minimumReach...maximumReach).contains(bucketRange)
        let outbound = wrap(bucketHeading-tableHeading)
        return ["strategy": sameAnchor ? "torso_first_same_base_anchor" : "checked_base_reposition_needed",
            "coordinate_frame": "tread_base_meters", "table_range_m": tableRange, "bucket_range_m": bucketRange,
            "table_heading_degrees": tableHeading, "bucket_heading_degrees": bucketHeading,
            "initial_turn_degrees": wrap(tableHeading-currentHeading), "outbound_turn_degrees": outbound,
            "return_turn_degrees": debugCable ? -outbound : wrap(tableHeading-bucketHeading),
            "debug_reverse_to_unwind": debugCable, "planned_tread_travel_m": sameAnchor ? 0 : NSNull(),
            "maximum_torso_pulses_per_second": 3000, "reach_is_model_estimate": true,
            "collision_checked": false, "executable": false,
            "required_observations": ["both arms above treads", "full torso sweep clear", "fresh table depth",
                "grasp retained", "bucket opening after turn", "can released and landed"],
            "detail": sameAnchor ? "Prefer this base anchor and reverse the torso between observed table and bucket. Replan each grasp and release."
                : "At least one target needs a fresh fused lidar/RGB-D base route; do not drive an inferred distance."]
    }
}
