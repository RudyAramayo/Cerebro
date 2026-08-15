import Foundation

@main
struct ROBMLXStageObservationFixtureTests {
    static func main() throws {
        let valid = Data(#"{"audience_present":true,"estimated_people":4,"presenter_visible":true,"demonstration_object_visible":false,"visible_items":["robot arm","table"],"audience_activity":"watching","scene_change":"two people approached","confidence":0.71}"#.utf8)
        let observation = try ROBMLXStageObservationCodec.decode(valid)
        precondition(observation.estimatedPeople == 4)
        precondition(observation.audienceActivity == .watching)

        let rejected = [
            #"The audience is here."#,
            #"```json\n{"audience_present":false}\n```"#,
            #"{"audience_present":false,"estimated_people":2,"presenter_visible":false,"demonstration_object_visible":false,"visible_items":[],"audience_activity":"watching","scene_change":"none","confidence":0.8}"#,
            #"{"audience_present":true,"estimated_people":4,"presenter_visible":true,"demonstration_object_visible":false,"visible_items":[],"audience_activity":"driving","scene_change":"traffic moved","confidence":0.9}"#,
            #"{"audience_present":true,"estimated_people":4,"presenter_visible":true,"demonstration_object_visible":false,"visible_items":[],"audience_activity":"watching","scene_change":"stable","confidence":1.4,"extra":true}"#
        ]
        for text in rejected {
            do {
                _ = try ROBMLXStageObservationCodec.decode(Data(text.utf8))
                fatalError("Invalid observation was accepted: \(text)")
            } catch is ROBMLXStageObservationError {}
        }
        print("ROB MLX stage-observation fixtures passed")
    }
}
