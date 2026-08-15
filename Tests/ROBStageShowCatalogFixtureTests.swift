import Foundation

@main
struct ROBStageShowCatalogFixtureTests {
    static func main() throws {
        let names = [
            "MakerFaireOpening",
            "OrbitusTenMinuteComedy",
            "GalacticSaberBattle",
            "ProgressiveSaberTraining",
            "OrbitusComedyActTwo",
            "OrbitusComedyActThree",
            "ROBJuniorMakerFaireComedy"
        ]
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
        let extendedActOne = Array(comedy.cues.dropLast())
        let twentyMinute = ROBStageShow(
            showID: "orbitus-twenty-minute-comedy",
            title: "Twenty-minute fixture",
            cues: extendedActOne + shows[4].cues
        )
        let thirtyMinute = ROBStageShow(
            showID: "orbitus-thirty-minute-ai-comedy",
            title: "Thirty-minute fixture",
            cues: extendedActOne + shows[4].cues + shows[5].cues
        )
        try ROBStageShowCodec.validate(twentyMinute)
        try ROBStageShowCodec.validate(thirtyMinute)
        let twentyDuration = ROBStageShowCodec.estimatedDuration(of: twentyMinute)
        let thirtyDuration = ROBStageShowCodec.estimatedDuration(of: thirtyMinute)
        precondition((19 * 60 ... 21 * 60).contains(twentyDuration))
        precondition((29 * 60 ... 31 * 60).contains(thirtyDuration))
        precondition(twentyMinute.cues.allSatisfy { $0.kind != .geminiTurn || $0.fallbackText != nil })
        precondition(thirtyMinute.cues.allSatisfy { $0.kind != .geminiTurn || $0.fallbackText != nil })
        let juniorShow = shows[6]
        let juniorDuration = ROBStageShowCodec.estimatedDuration(of: juniorShow)
        precondition((29 * 60 ... 31 * 60).contains(juniorDuration))
        precondition(juniorShow.cues.count >= 100)
        precondition(juniorShow.cues.allSatisfy { $0.kind != .geminiTurn || $0.fallbackText != nil })
        let training = shows[3]
        let trainingDuration = ROBStageShowCodec.estimatedDuration(of: training)
        precondition((9 * 60 ... 12 * 60).contains(trainingDuration))
        precondition(training.cues.filter { $0.kind == .playGesture }.count >= 24)
        print("ROB stage-show catalog fixtures passed (extended estimates \(Int(twentyDuration.rounded())) and \(Int(thirtyDuration.rounded())) seconds)")
    }
}
