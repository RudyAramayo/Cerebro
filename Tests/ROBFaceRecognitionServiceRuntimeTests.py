#!/usr/bin/env python3
"""Run production recognition/enrollment with synthetic faces and an isolated gallery.

Only the encoder, paired-controller list, and scene-context sink are fakes.
Vision observations, image cropping, JPEG encoding, and encrypted storage are real.
No camera, robot hardware, production defaults, or production gallery is accessed.
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

STUBS = r'''
import AppKit
import Foundation
import Vision

public enum ROBFaceEmbeddingModelOption: String, CaseIterable, Sendable {
    case webFace4M = "fixture"
    public var isInstalled: Bool { true }
    public var displayName: String { "Fixture encoder" }
}
final class ROBFaceCoreMLEncoder {
    static var probe: [Float] = [1, 0, 0]
    init(option: ROBFaceEmbeddingModelOption) throws {}
    func embedding(for image: CGImage) throws -> [Float] { Self.probe }
}
struct ROBControlPairedDevice {
    let deviceID: String
    let isRevoked: Bool
    let roleName: String
}
enum ROBControlPairing {
    static func pairedDevices() -> [ROBControlPairedDevice] { [] }
}
final class ROBSceneSnapshotStore {
    static let shared = ROBSceneSnapshotStore()
    var names: [String] = []
    func updateIdentifiedPeople(_ names: [String]) { self.names = names }
}
'''

HARNESS = r'''
import AppKit
import CoreImage
import Foundation
import Vision

@main
enum ROBFaceRecognitionServiceFixtures {
    static func main() throws {
        // The fixture process has a separate defaults domain from Cerebro.
        UserDefaults.standard.set(true, forKey: "ROBFaceIdentity.enabled")
        UserDefaults.standard.set("fixture", forKey: "ROBFaceIdentity.embeddingModel")
        defer {
            UserDefaults.standard.removeObject(forKey: "ROBFaceIdentity.enabled")
            UserDefaults.standard.removeObject(forKey: "ROBFaceIdentity.embeddingModel")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gallery = ROBFaceIdentityGallery(rootURL: root, encryptionKey: Data(repeating: 0x51, count: 32))
        func profiles() -> [ROBFaceIdentityProfile] { try! gallery.profiles() }
        let rudy = try gallery.createProfile(
            displayName: "Rudy", pronunciation: nil, role: .knownPerson,
            trustedEnrollmentReference: "fixture-consent", modelIdentifier: "fixture"
        )
        for _ in 0..<ROBFaceIdentityProfile.requiredEnrollmentSamples {
            let id = UUID()
            let sample = ROBFaceIdentitySample(
                id: id, capturedAt: Date(), quality: 0.9, luminance: 0.5,
                yawRadians: nil, rollRadians: nil, embedding: [1, 0, 0],
                encryptedImageFileName: "\(id).robface"
            )
            _ = try gallery.appendSample(sample, encryptedImagePlaintext: Data([1]), to: rudy.id)
        }
        let service = ROBFaceRecognitionService(gallery: gallery)
        service.analysisQueue.sync {} // drain initial profile loading
        var spoken: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .robFaceIdentityConversationCue, object: service, queue: nil
        ) { notification in
            if notification.userInfo?["kind"] as? String == "speak",
               let text = notification.userInfo?["text"] as? String { spoken.append(text) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // This usable face was rejected by the former 0.025 area cutoff.
        let distantFace = ROBFixtureFace(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.06))
        service.analysisQueue.sync {
            for _ in 0..<20 { service.processRecognitionFaces([distantFace], source: source) }
            precondition(service.lastRecognitionValue?.profileID == rudy.id)
            precondition(service.pixelIdentityTrack?.profileID == rudy.id)
            precondition(service.activeEnrollmentID == nil)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(spoken.isEmpty, "Ordinary recognized faces must not receive positioning prompts")
        precondition(profiles().first!.samples.count == 24, "Recognition must not append adaptive samples")

        ROBFaceCoreMLEncoder.probe = [0.6, 0.8, 0]
        service.analysisQueue.sync {
            service.processRecognitionFaces([distantFace], source: source)
            precondition(service.pixelIdentityTrack?.profileID == rudy.id, "A temporary weak match preserves a spatially continuous identity")
        }
        precondition(profiles().first!.samples.count == 24, "Lighting continuity must remain in memory")

        ROBFaceCoreMLEncoder.probe = [0, 1, 0]
        let enrollmentFace = ROBFixtureFace(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.25, height: 0.25))
        service.analysisQueue.sync {
            for _ in 0..<20 { service.processRecognitionFaces([distantFace], source: source) }
            precondition(service.pixelIdentityTrack == nil, "A clear appearance conflict releases the remembered name")
            precondition(service.activeEnrollmentID == nil)
            precondition(service.friendConversation.invitationExpiresAtUptime == nil)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(spoken.isEmpty, "An unfamiliar face must not start an unsolicited conversation")
        precondition(!service.noteConversationTranscript("Yes, my name is Ada"))
        precondition(profiles().count == 1)

        precondition(service.noteConversationTranscript("ROB, remember this person"))
        precondition(service.noteConversationTranscript("My name is Ada"))
        precondition(profiles().count == 1, "An operator request plus a name is not consent")
        precondition(service.noteConversationTranscript("yes"))
        let adaID = service.analysisQueue.sync { service.activeEnrollmentID! }
        precondition(profiles().first { $0.id == adaID }!.samples.isEmpty)
        try service.analysisQueue.sync {
            try service.processEnrollmentFace(enrollmentFace, source: source, profileID: adaID)
        }
        precondition(profiles().first { $0.id == adaID }!.samples.count == 1,
                     "Requested, consented enrollment may persist a face")
        precondition(service.noteConversationTranscript("cancel enrollment"))
        precondition(profiles().count == 1, "Cancellation deletes partial face storage")

        ROBFaceCoreMLEncoder.probe = [1, 0, 0]
        service.analysisQueue.sync {
            for _ in 0..<3 { service.processRecognitionFaces([distantFace], source: source) }
        }
        precondition(service.noteConversationTranscript("Remember me, my name is Rudy"))
        service.analysisQueue.sync {
            precondition(service.activeEnrollmentID == rudy.id, "A known face refines its existing profile")
            precondition(service.activeEnrollmentIsRefinement)
            service.updateEnrollmentGuidance(key: "hold-still", status: "blur", spoken: "fixture correction")
            service.lastGuidanceCueUptime = -.greatestFiniteMagnitude
            service.updateEnrollmentGuidance(key: "hold-still", status: "blur", spoken: "fixture correction")
            precondition(service.spokenGuidanceKeys == ["hold-still"])
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(spoken.filter { $0 == "fixture correction" }.count == 1, "A correction is spoken only once per requested session")
        precondition(profiles().first!.samples.count == 24)
        precondition(service.noteConversationTranscript("cancel enrollment"))
        service.analysisQueue.sync {
            service.enrollmentCandidate = ROBFaceRecognitionService.EnrollmentCandidate(
                embedding: [1, 0, 0], observedAtUptime: ProcessInfo.processInfo.systemUptime - 10
            )
        }
        precondition(service.noteConversationTranscript("Remember me, my name is Rudy"))
        service.analysisQueue.sync { precondition(service.activeEnrollmentID == nil, "A stale face cannot bind a new enrollment") }
        precondition(profiles().first!.samples.count == 24)
        print("ROB face recognition runtime fixtures passed")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="rob-face-runtime-") as directory:
        work = Path(directory)
        # Expose internals in this temporary test copy; execute production method
        # bodies unchanged, without adding test accessors to the shipping app.
        service = (ROOT / "Cerebro/ROBFaceRecognitionService.swift").read_text()
        (work / "Service.swift").write_text(service.replace("private ", ""))
        (work / "Stubs.swift").write_text(STUBS)
        # Override Vision's Objective-C quality getter for synthetic observations;
        # its Swift overlay is a non-overridable extension property.
        (work / "Face.h").write_text("#import <Vision/Vision.h>\n@interface ROBFixtureFace : VNFaceObservation\n@end\n")
        (work / "Face.m").write_text('#import "Face.h"\n@implementation ROBFixtureFace\n- (NSNumber *)faceCaptureQuality { return @0.9; }\n@end\n')
        (work / "Fixtures.swift").write_text(HARNESS)
        executable = work / "fixtures"
        subprocess.run(["clang", "-fobjc-arc", "-c", str(work / "Face.m"), "-o", str(work / "Face.o")], check=True)
        subprocess.run([
            "swiftc", "-swift-version", "5",
            "-import-objc-header", str(work / "Face.h"), str(work / "Face.o"),
            str(ROOT / "Cerebro/ROBFaceIdentityGallery.swift"),
            str(ROOT / "Cerebro/ROBFaceConversationPolicy.swift"),
            str(ROOT / "Cerebro/ROBFaceTrackingPolicy.swift"),
            str(work / "Stubs.swift"), str(work / "Service.swift"), str(work / "Fixtures.swift"),
            "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
