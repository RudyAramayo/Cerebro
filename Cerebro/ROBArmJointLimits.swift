import Foundation

/// Raw J1...J7 limits enforced at the authenticated Amber transport boundary.
/// These are vendor coordinates. A URDF/reference conversion may narrow them
/// for a planner, but must never widen the gateway's accepted interval.
enum ROBArmJointLimits {
    static let radians: [ClosedRange<Double>] = [
        -2.4435 ... 2.4435,
        -2.3213 ... 2.3213,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -3.05 ... 3.05,
    ]
}
