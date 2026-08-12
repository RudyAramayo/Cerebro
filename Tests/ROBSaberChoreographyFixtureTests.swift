import Foundation

@main
struct ROBSaberChoreographyFixtureTests {
    static func main() throws {
        let show = try ROBStageShowCodec.decode(
            Data(contentsOf: URL(fileURLWithPath: "Cerebro/StageShows/GalacticSaberBattle.robshow.json"))
        )
        let duration = ROBStageShowCodec.estimatedDuration(of: show)
        precondition((9 * 60 ... 12 * 60).contains(duration))
        let gestures = show.cues.compactMap { $0.kind == .playGesture ? $0.gesture : nil }
        precondition(gestures.count >= 8)
        for gesture in gestures {
            guard let transforms = ROBSaberChoreographyCatalog.shared.transforms(forGesture: gesture) else {
                fatalError("Missing choreography: \(gesture)")
            }
            precondition(!transforms.isEmpty && transforms.count <= 6)
            precondition(transforms.allSatisfy(\.isSafe))
        }
        precondition(ROBSaberChoreographyCatalog.shared.transforms(forGesture: "saber.unknown") == nil)
        let levels = ROBSaberChoreographyCatalog.shared.trainingGestureNames
        precondition(levels.count == 4)
        let requestedDurations = levels.map { ROBSaberChoreographyCatalog.shared.requestedTrainingDuration(forGesture: $0) }
        precondition(zip(requestedDurations, requestedDurations.dropFirst()).allSatisfy(>))
        for level in levels {
            for _ in 0 ..< 50 {
                guard let transforms = ROBSaberChoreographyCatalog.shared.transforms(forGesture: level) else {
                    fatalError("Missing dynamic training level: \(level)")
                }
                precondition((3 ... 5).contains(transforms.count))
                precondition(transforms.allSatisfy(\.isSafe))
            }
        }
        precondition(!ROBSaberSafetyGate.shared.isArmed)
        print("ROB saber choreography fixtures passed (\(Int(duration.rounded())) seconds, \(gestures.count) cues)")
    }
}
