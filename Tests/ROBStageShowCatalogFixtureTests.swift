import Foundation

@main
struct ROBStageShowCatalogFixtureTests {
    static func main() throws {
        let names = ["MakerFaireOpening", "OrbitusTenMinuteComedy", "GalacticSaberBattle", "ProgressiveSaberTraining"]
        let shows = try names.map { name in
            try ROBStageShowCodec.decode(
                Data(contentsOf: URL(fileURLWithPath: "Cerebro/StageShows/\(name).robshow.json"))
            )
        }
        precondition(Set(shows.map(\.showID)).count == shows.count)
        let comedy = shows[1]
        let duration = ROBStageShowCodec.estimatedDuration(of: comedy)
        precondition(comedy.cues.count == 39)
        precondition((9 * 60 ... 11 * 60).contains(duration))
        precondition(comedy.cues.filter { $0.kind == .geminiTurn }.count == 5)
        precondition(comedy.cues.allSatisfy { $0.kind != .geminiTurn || $0.fallbackText != nil })
        let training = shows[3]
        let trainingDuration = ROBStageShowCodec.estimatedDuration(of: training)
        precondition((9 * 60 ... 12 * 60).contains(trainingDuration))
        precondition(training.cues.filter { $0.kind == .playGesture }.count >= 24)
        print("ROB stage-show catalog fixtures passed (comedy estimate \(Int(duration.rounded())) seconds)")
    }
}
