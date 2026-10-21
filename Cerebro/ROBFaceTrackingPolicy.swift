import CoreGraphics
import Foundation

/// Geometry and temporal evidence for a confirmed face. No images or vectors
/// are persisted, and geometry alone never establishes a new identity.
enum ROBFaceTrackingPolicy {
    static func associationScore(previous: CGRect, observed: CGRect) -> CGFloat? {
        let previousArea = previous.width * previous.height
        let observedArea = observed.width * observed.height
        guard previousArea > 0, observedArea > 0 else { return nil }
        let sizeRatio = min(previousArea, observedArea) / max(previousArea, observedArea)
        guard sizeRatio >= 0.4 else { return nil }
        let intersection = previous.intersection(observed)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let overlap = intersectionArea / (previousArea + observedArea - intersectionArea)
        let distance = hypot(previous.midX - observed.midX, previous.midY - observed.midY)
        let allowance = max(0.04, hypot(previous.width, previous.height) * 0.65)
        guard overlap >= 0.1 || distance <= allowance else { return nil }
        let centerScore = max(0, 1 - distance / allowance)
        return 0.58 * overlap + 0.27 * centerScore + 0.15 * sizeRatio
    }

    static func associatedIndex(previous: CGRect, observations: [CGRect]) -> Int? {
        let ranked = observations.enumerated().compactMap { index, box -> (Int, CGFloat)? in
            guard let score = associationScore(previous: previous, observed: box) else { return nil }
            return (index, score)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.28 else { return nil }
        // Crowded or crossing faces need biometric evidence to resolve them.
        if ranked.count > 1, best.1 - ranked[1].1 < 0.12 { return nil }
        return best.0
    }

    struct Confirmation {
        private var profileID: UUID?
        private var boundingBox: CGRect = .zero
        private var lastMatchUptime: TimeInterval = -.greatestFiniteMagnitude
        private var matches = 0

        mutating func reset() { self = Self() }

        mutating func noteMiss(at now: TimeInterval) {
            if now - lastMatchUptime > 2 { reset() }
        }

        mutating func observe(profileID: UUID, boundingBox: CGRect, at now: TimeInterval) -> Bool {
            let continuous = self.profileID == profileID
                && now - lastMatchUptime <= 2
                && ROBFaceTrackingPolicy.associationScore(previous: self.boundingBox, observed: boundingBox) != nil
            matches = continuous ? matches + 1 : 1
            self.profileID = profileID
            self.boundingBox = boundingBox
            lastMatchUptime = now
            return matches >= 3
        }
    }
}
