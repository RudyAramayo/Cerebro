import CoreGraphics
import Foundation

@main
enum ROBFaceTrackingPolicyFixtureTests {
    static func main() {
        let rudy = UUID()
        let visitor = UUID()
        let initial = CGRect(x: 0.4, y: 0.4, width: 0.15, height: 0.2)
        let moved = initial.offsetBy(dx: 0.035, dy: 0.01)
        let farAway = initial.offsetBy(dx: -0.35, dy: 0)
        let tiny = CGRect(x: 0.45, y: 0.45, width: 0.02, height: 0.02)

        precondition(ROBFaceTrackingPolicy.associatedIndex(previous: initial, observations: [farAway, moved]) == 1)
        precondition(ROBFaceTrackingPolicy.associatedIndex(previous: initial, observations: [farAway]) == nil)
        precondition(ROBFaceTrackingPolicy.associatedIndex(previous: initial, observations: [tiny]) == nil)
        precondition(ROBFaceTrackingPolicy.associatedIndex(
            previous: initial, observations: [initial.offsetBy(dx: -0.01, dy: 0), initial.offsetBy(dx: 0.01, dy: 0)]
        ) == nil, "Crossing faces must not inherit a name through ambiguous geometry")

        var confirmation = ROBFaceTrackingPolicy.Confirmation()
        precondition(!confirmation.observe(profileID: rudy, boundingBox: initial, at: 0))
        confirmation.noteMiss(at: 0.4) // blur between two usable frames
        precondition(!confirmation.observe(profileID: rudy, boundingBox: moved, at: 0.8))
        confirmation.noteMiss(at: 1.2)
        precondition(confirmation.observe(profileID: rudy, boundingBox: moved, at: 1.6), "Brief blur must not erase valid evidence")
        precondition(!confirmation.observe(profileID: visitor, boundingBox: moved, at: 2), "Different identity resets evidence")
        precondition(!confirmation.observe(profileID: rudy, boundingBox: moved, at: 2.4))
        precondition(!confirmation.observe(profileID: rudy, boundingBox: farAway, at: 2.8), "Disjoint faces cannot pool evidence")
        confirmation.noteMiss(at: 5)
        precondition(!confirmation.observe(profileID: rudy, boundingBox: farAway, at: 5.2), "Stale evidence expires")
        precondition(!confirmation.observe(profileID: rudy, boundingBox: farAway, at: 5.6))
        precondition(confirmation.observe(profileID: rudy, boundingBox: farAway, at: 6))
        print("ROB face tracking policy fixtures passed")
    }
}
