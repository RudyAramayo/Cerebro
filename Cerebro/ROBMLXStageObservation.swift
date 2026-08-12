//
//  ROBMLXStageObservation.swift
//  Cerebro
//

import Foundation

public enum ROBStageAudienceActivity: String, Codable, CaseIterable, Sendable {
    case absent
    case arriving
    case watching
    case interacting
    case distracted
    case leaving
    case unknown
}

/// A deliberately small, non-executable contract for sampled stage vision.
public struct ROBMLXStageObservation: Codable, Equatable, Sendable {
    public let audiencePresent: Bool
    public let estimatedPeople: Int
    public let presenterVisible: Bool
    public let demonstrationObjectVisible: Bool
    public let audienceActivity: ROBStageAudienceActivity
    public let sceneChange: String
    public let confidence: Double

    enum CodingKeys: String, CodingKey {
        case audiencePresent = "audience_present"
        case estimatedPeople = "estimated_people"
        case presenterVisible = "presenter_visible"
        case demonstrationObjectVisible = "demonstration_object_visible"
        case audienceActivity = "audience_activity"
        case sceneChange = "scene_change"
        case confidence
    }
}

public enum ROBMLXStageObservationCodec {
    public static let maximumDocumentBytes = 8_192
    private static let allowedKeys: Set<String> = [
        "audience_present", "estimated_people", "presenter_visible",
        "demonstration_object_visible", "audience_activity", "scene_change", "confidence"
    ]

    public static func decode(_ data: Data) throws -> ROBMLXStageObservation {
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw ROBMLXStageObservationError.invalid("Observation is empty or too large.")
        }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw ROBMLXStageObservationError.invalid("VLM output is not JSON-only.") }
        guard let object = value as? [String: Any], Set(object.keys) == allowedKeys else {
            throw ROBMLXStageObservationError.invalid("Observation fields do not match the stage schema.")
        }
        let observation: ROBMLXStageObservation
        do { observation = try JSONDecoder().decode(ROBMLXStageObservation.self, from: data) }
        catch { throw ROBMLXStageObservationError.invalid("Observation value types are invalid.") }
        guard (0 ... 50).contains(observation.estimatedPeople),
              observation.audiencePresent || observation.estimatedPeople == 0,
              observation.confidence.isFinite, (0 ... 1).contains(observation.confidence) else {
            throw ROBMLXStageObservationError.invalid("Observation values are inconsistent or out of range.")
        }
        let change = observation.sceneChange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard change == observation.sceneChange, !change.isEmpty, change.count <= 160,
              change.rangeOfCharacter(from: .newlines) == nil else {
            throw ROBMLXStageObservationError.invalid("scene_change must be one trimmed line of 1–160 characters.")
        }
        return observation
    }

    public static func encode(_ observation: ROBMLXStageObservation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(observation)
        _ = try decode(data)
        return data
    }
}

public enum ROBMLXStageObservationError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        guard case .invalid(let detail) = self else { return nil }
        return detail
    }
}
