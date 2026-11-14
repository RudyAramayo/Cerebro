import Foundation

@main enum ArmPositionControlFixtures {
    static func numbers(_ values: [Double]) -> [NSNumber] { values.map(NSNumber.init(value:)) }
    static func main() {
        let q = [-0.25, -1.66, 0.02, -0.98, 1.11, 1.71, 0.47]
        let right = numbers(q)
        let left = ROBArmPoseMirror.mirroredJointValues(right)!
        let mirrored = [0.25, 1.66, -0.02, 0.98, 1.11, -1.71, -0.47]
        precondition(left.map(\.doubleValue) == mirrored)
        precondition(ROBArmPoseMirror.mirroredJointValues(left)! == right)
        precondition(ROBArmPoseMirror.mirroredJointValues([]) == nil)
        precondition(ROBArmPoseMirror.mirroredJointValues(numbers([.nan,0,0,0,0,0,0])) == nil)
        let state = ROBArmPositionControlState()
        precondition(state.nextSliderValues(targetRadians: [], measuredRadians: right, feedbackFresh: false) == nil)
        precondition(state.nextSliderValues(targetRadians: [], measuredRadians: right, feedbackFresh: true) == numbers(q.map { $0*100 }))
        // Streaming measurements cannot move an editable draft on every frame.
        precondition(state.nextSliderValues(targetRadians: [], measuredRadians: left, feedbackFresh: true) == nil)
        precondition(state.nextSliderValues(targetRadians: right, measuredRadians: [], feedbackFresh: false) != nil)
        precondition(state.nextSliderValues(targetRadians: right, measuredRadians: left, feedbackFresh: true) == nil)
        var edited = q; edited[4] += 0.01
        state.noteEditedSliderValues(numbers(edited.map { $0*100 }))
        precondition(state.nextSliderValues(targetRadians: right, measuredRadians: right, feedbackFresh: true) == nil)
        precondition(state.nextSliderValues(targetRadians: left, measuredRadians: left, feedbackFresh: true) == nil)
        precondition(state.nextSliderValues(targetRadians: numbers(edited), measuredRadians: right, feedbackFresh: true) == numbers(edited.map { $0*100 }))
        precondition(state.nextSliderValues(targetRadians: left, measuredRadians: right, feedbackFresh: true) == numbers(mirrored.map { $0*100 }))
        print("PASS both mirror directions, radians/slider units, fresh startup seed, accepted target updates and preserved manual adjustments; no hardware IO")
    }
}
