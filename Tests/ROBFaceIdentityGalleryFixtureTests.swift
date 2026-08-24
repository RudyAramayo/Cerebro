import Foundation

@main
enum ROBFaceIdentityGalleryFixtureTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROBFaceIdentityGallery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gallery = ROBFaceIdentityGallery(rootURL: root, encryptionKey: Data(repeating: 0x5a, count: 32))

        let profile = try gallery.createProfile(
            displayName: "Rob Test Administrator",
            pronunciation: "Rob",
            role: .administrator,
            trustedEnrollmentReference: "fixture-trusted-controller",
            modelIdentifier: "fixture-model-v1"
        )
        precondition(profile.samples.isEmpty)

        let sample = ROBFaceIdentitySample(
            id: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1234),
            quality: 0.9,
            luminance: 0.42,
            yawRadians: 0.1,
            rollRadians: -0.1,
            featurePrintArchive: Data([1, 2, 3, 4]),
            encryptedImageFileName: "fixture.robface"
        )
        let imagePlaintext = Data("private-face-image-fixture".utf8)
        let updated = try gallery.appendSample(sample, encryptedImagePlaintext: imagePlaintext, to: profile.id)
        precondition(updated.samples.count == 1)
        precondition(ROBFaceIdentityProfile.requiredEnrollmentSamples == 24)
        precondition(!updated.enrollmentIsComplete)

        let loaded = try gallery.profiles()
        precondition(loaded.count == 1)
        precondition(loaded[0].displayName == "Rob Test Administrator")
        precondition(loaded[0].role == .administrator)
        precondition(loaded[0].samples[0].luminance == 0.42)

        var latestAdaptiveID = UUID()
        for index in 2...26 {
            latestAdaptiveID = UUID()
            let adaptive = ROBFaceIdentitySample(
                id: latestAdaptiveID,
                capturedAt: Date(timeIntervalSince1970: TimeInterval(1234 + index)),
                quality: Float(index) / 30,
                luminance: Float(index) / 30,
                yawRadians: nil,
                rollRadians: nil,
                featurePrintArchive: Data([UInt8(index)]),
                encryptedImageFileName: "adaptive-\(index).robface"
            )
            _ = try gallery.appendAdaptiveSample(
                adaptive,
                encryptedImagePlaintext: Data("adaptive-\(index)".utf8),
                to: profile.id,
                retainingAtMost: 25
            )
        }
        let adapted = try gallery.profiles().first { $0.id == profile.id }!
        precondition(adapted.samples.count == 25)
        precondition(adapted.samples.first?.id == sample.id)
        precondition(adapted.samples.contains { $0.id == latestAdaptiveID })
        precondition(!FileManager.default.fileExists(atPath:
            root.appendingPathComponent(profile.id.uuidString.lowercased())
                .appendingPathComponent("samples/adaptive-25.robface").path
        ))

        let profileCiphertext = try Data(contentsOf:
            root.appendingPathComponent(profile.id.uuidString.lowercased())
                .appendingPathComponent("profile.robidentity")
        )
        precondition(!String(decoding: profileCiphertext, as: UTF8.self).contains("Rob Test Administrator"))
        let imageCiphertext = try Data(contentsOf:
            root.appendingPathComponent(profile.id.uuidString.lowercased())
                .appendingPathComponent("samples/fixture.robface")
        )
        precondition(imageCiphertext != imagePlaintext)

        do {
            _ = try gallery.createProfile(
                displayName: "Second Admin",
                pronunciation: nil,
                role: .administrator,
                trustedEnrollmentReference: "fixture",
                modelIdentifier: "fixture-model-v1"
            )
            preconditionFailure("A second administrator must be rejected")
        } catch ROBFaceIdentityGalleryError.administratorAlreadyExists {
            // Expected.
        }

        try gallery.deleteProfile(id: profile.id)
        let remaining = try gallery.profiles()
        precondition(remaining.isEmpty)
        print("ROB face identity encrypted gallery fixtures passed")
    }
}
