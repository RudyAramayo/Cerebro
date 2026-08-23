//
//  ROBFaceRecognitionService.swift
//  Cerebro
//
//  Headless, quality-gated face enrollment and open-set recognition.
//

import AppKit
import AVFoundation
import CoreImage
import Foundation
import Vision

extension Notification.Name {
    static let robFaceIdentityStateDidChange = Notification.Name("ROBFaceIdentityStateDidChange")
    static let robFaceIdentityDidRecognize = Notification.Name("ROBFaceIdentityDidRecognize")
}

public struct ROBFaceRecognitionResult: Sendable {
    public let profileID: UUID
    public let displayName: String
    public let role: ROBFaceIdentityRole
    public let distance: Float
    public let confirmedAt: Date
}

public struct ROBFaceIdentityServiceSnapshot: Sendable {
    public let enabled: Bool
    public let profiles: [ROBFaceIdentityProfile]
    public let enrollingProfileID: UUID?
    public let enrollmentAcceptedSamples: Int
    public let enrollmentTargetSamples: Int
    public let status: String
    public let lastRecognition: ROBFaceRecognitionResult?
    public let selectedModel: ROBFaceEmbeddingModelOption
    public let availableModels: [ROBFaceEmbeddingModelOption]
}

/// Face crops are embedded locally by the selected AdaFace Core ML encoder.
/// Profiles remain backend-versioned so vectors from different models are
/// never compared as though they occupied the same embedding space.
@objcMembers public final class ROBFaceRecognitionService: NSObject {
    public static let shared = ROBFaceRecognitionService()

    public static let enrollmentTargetSamples = 24
    private static let modelDefaultsKey = "ROBFaceIdentity.embeddingModel"

    private let gallery: ROBFaceIdentityGallery
    private let analysisQueue = DispatchQueue(
        label: "com.orbitusrobotics.Cerebro.FaceRecognition",
        qos: .userInitiated
    )
    private let admissionLock = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var analysisInFlight = false
    private var lastAdmission: TimeInterval = 0

    private var cachedProfiles: [ROBFaceIdentityProfile] = []
    private var activeEnrollmentID: UUID?
    private var statusText = "Face identity is idle."
    private var lastRecognitionValue: ROBFaceRecognitionResult?
    private var pendingCandidateID: UUID?
    private var pendingCandidateFrames = 0
    private var encoders: [ROBFaceEmbeddingModelOption: ROBFaceCoreMLEncoder] = [:]
    private var selectedModelValue: ROBFaceEmbeddingModelOption

    public var enabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "ROBFaceIdentity.enabled") == nil { return false }
            return defaults.bool(forKey: "ROBFaceIdentity.enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ROBFaceIdentity.enabled")
            analysisQueue.async {
                self.statusText = newValue ? "Looking for known, consenting people." : "Face identity is disabled."
                if !newValue { ROBSceneSnapshotStore.shared.updateIdentifiedPeople([]) }
                self.publishState()
            }
        }
    }

    private override convenience init() {
        self.init(gallery: .shared)
    }

    init(gallery: ROBFaceIdentityGallery) {
        self.gallery = gallery
        let saved = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
            .flatMap(ROBFaceEmbeddingModelOption.init(rawValue:))
        selectedModelValue = saved
            ?? ROBFaceEmbeddingModelOption.allCases.first(where: \.isInstalled)
            ?? .webFace4M
        super.init()
        analysisQueue.async { self.reloadProfiles() }
    }

    @nonobjc public func selectModel(_ model: ROBFaceEmbeddingModelOption, completion: @escaping (Error?) -> Void) {
        analysisQueue.async {
            do {
                guard self.activeEnrollmentID == nil else {
                    throw ROBFaceIdentityGalleryError.invalidInput("Finish or cancel enrollment before changing models.")
                }
                guard model.isInstalled else {
                    throw ROBFaceIdentityGalleryError.storage("\(model.displayName) has not finished installing.")
                }
                _ = try self.encoder(for: model)
                self.selectedModelValue = model
                UserDefaults.standard.set(model.rawValue, forKey: Self.modelDefaultsKey)
                self.resetTemporalCandidate()
                self.statusText = "Using \(model.displayName). Enrollments made with another model remain stored but inactive."
                self.publishState()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    public func snapshot(completion: @escaping (ROBFaceIdentityServiceSnapshot) -> Void) {
        analysisQueue.async {
            let snapshot = self.snapshotUnlocked()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// Administrator is a personalization role, never a motion or command
    /// credential. Callers must provide a trusted local/controller confirmation
    /// reference before this method will create an administrator profile.
    public func startEnrollment(
        displayName: String,
        pronunciation: String?,
        role: ROBFaceIdentityRole,
        consentConfirmed: Bool,
        trustedEnrollmentReference: String,
        completion: @escaping (Error?) -> Void
    ) {
        analysisQueue.async {
            do {
                guard consentConfirmed else {
                    throw ROBFaceIdentityGalleryError.invalidInput(
                        "Enrollment requires the person's explicit consent."
                    )
                }
                let trust = trustedEnrollmentReference.trimmingCharacters(in: .whitespacesAndNewlines)
                if role == .administrator {
                    let trustedOperator = ROBControlPairing.pairedDevices().contains {
                        !$0.isRevoked
                            && $0.roleName == "operatorController"
                            && $0.deviceID.caseInsensitiveCompare(trust) == .orderedSame
                    }
                    guard trustedOperator else {
                        throw ROBFaceIdentityGalleryError.invalidInput(
                            "Administrator enrollment requires a currently paired, non-revoked operator controller."
                        )
                    }
                }
                if let activeID = self.activeEnrollmentID {
                    throw ROBFaceIdentityGalleryError.invalidInput(
                        "Finish or cancel the current enrollment (\(activeID.uuidString)) first."
                    )
                }
                let profile = try self.gallery.createProfile(
                    displayName: displayName,
                    pronunciation: pronunciation,
                    role: role,
                    trustedEnrollmentReference: trust.isEmpty ? "local-consent" : trust,
                    modelIdentifier: self.selectedModelValue.rawValue
                )
                self.cachedProfiles.append(profile)
                self.activeEnrollmentID = profile.id
                self.enabled = true
                self.statusText = "Enrolling \(profile.displayName): look straight at ROB."
                self.publishState()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.statusText = error.localizedDescription
                self.publishState()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    public func cancelEnrollment(deleteIncompleteProfile: Bool = true, completion: ((Error?) -> Void)? = nil) {
        analysisQueue.async {
            guard let profileID = self.activeEnrollmentID else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            self.activeEnrollmentID = nil
            var returnedError: Error?
            if deleteIncompleteProfile,
               let profile = self.cachedProfiles.first(where: { $0.id == profileID }),
               !profile.enrollmentIsComplete {
                do {
                    try self.gallery.deleteProfile(id: profileID)
                    self.cachedProfiles.removeAll { $0.id == profileID }
                } catch {
                    returnedError = error
                }
            }
            self.statusText = returnedError?.localizedDescription ?? "Enrollment cancelled."
            self.publishState()
            DispatchQueue.main.async { completion?(returnedError) }
        }
    }

    public func deleteProfile(id: UUID, completion: @escaping (Error?) -> Void) {
        analysisQueue.async {
            do {
                if self.activeEnrollmentID == id { self.activeEnrollmentID = nil }
                try self.gallery.deleteProfile(id: id)
                self.cachedProfiles.removeAll { $0.id == id }
                if self.lastRecognitionValue?.profileID == id { self.lastRecognitionValue = nil }
                self.statusText = "The identity and all retained face samples were deleted."
                self.publishState()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.statusText = error.localizedDescription
                self.publishState()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Safe for the camera callback: admission is constant-time and no image
    /// conversion or Vision work occurs on the capture thread.
    public func offer(_ sampleBuffer: CMSampleBuffer) {
        guard enabled || activeEnrollmentExists else { return }
        let now = ProcessInfo.processInfo.systemUptime
        admissionLock.lock()
        guard !analysisInFlight, now - lastAdmission >= 0.4 else {
            admissionLock.unlock()
            return
        }
        analysisInFlight = true
        lastAdmission = now
        admissionLock.unlock()

        analysisQueue.async {
            defer {
                self.admissionLock.lock()
                self.analysisInFlight = false
                self.admissionLock.unlock()
            }
            autoreleasepool { self.analyze(sampleBuffer) }
        }
    }

    private var activeEnrollmentExists: Bool {
        analysisQueue.sync { activeEnrollmentID != nil }
    }

    private func analyze(_ sampleBuffer: CMSampleBuffer) {
        let rectangles = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:]).perform([rectangles])
            guard let detected = rectangles.results, !detected.isEmpty else {
                updateStatusWhileEnrolling("No face detected. Move into the main camera view.")
                resetTemporalCandidate()
                if activeEnrollmentID == nil {
                    ROBSceneSnapshotStore.shared.updateIdentifiedPeople([])
                }
                return
            }
            if activeEnrollmentID != nil, detected.count != 1 {
                updateStatusWhileEnrolling("Enrollment needs exactly one face in view.")
                return
            }

            let landmarks = VNDetectFaceLandmarksRequest()
            landmarks.inputFaceObservations = detected
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = detected
            try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:]).perform([landmarks, quality])

            let refined = quality.results ?? landmarks.results ?? detected
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            let faces = refined.sorted { Self.area($0.boundingBox) > Self.area($1.boundingBox) }
            if let enrollmentID = activeEnrollmentID, let face = faces.first {
                try processEnrollmentFace(face, source: source, profileID: enrollmentID)
            } else if enabled {
                processRecognitionFaces(Array(faces.prefix(4)), source: source)
            }
        } catch {
            statusText = "Face analysis failed: \(error.localizedDescription)"
            publishState()
        }
    }

    private func processEnrollmentFace(
        _ face: VNFaceObservation,
        source: CIImage,
        profileID: UUID
    ) throws {
        let quality = face.faceCaptureQuality ?? 0
        guard Self.area(face.boundingBox) >= 0.035 else {
            updateStatusWhileEnrolling("Move closer; the face is too small for enrollment.")
            return
        }
        guard quality >= 0.45 else {
            updateStatusWhileEnrolling("Hold still in better light; this face sample is too soft or obstructed.")
            return
        }
        guard let crop = faceCrop(face.boundingBox, source: source) else {
            updateStatusWhileEnrolling("Could not align this face sample; please look toward ROB.")
            return
        }
        let embedding = try encoder(for: selectedModelValue).embedding(for: crop)
        guard sampleIsDiverse(embedding, profileID: profileID) else {
            updateStatusWhileEnrolling("Good—now turn your head slightly for a different view.")
            return
        }
        guard let jpeg = jpegData(crop) else {
            throw ROBFaceIdentityGalleryError.storage("The accepted face crop could not be encoded.")
        }
        let sampleID = UUID()
        let sample = ROBFaceIdentitySample(
            id: sampleID,
            capturedAt: Date(),
            quality: quality,
            yawRadians: face.yaw?.doubleValue,
            rollRadians: face.roll?.doubleValue,
            embedding: embedding,
            encryptedImageFileName: "\(sampleID.uuidString.lowercased()).robface"
        )
        let updated = try gallery.appendSample(sample, encryptedImagePlaintext: jpeg, to: profileID)
        replaceCachedProfile(updated)

        if updated.samples.count >= Self.enrollmentTargetSamples {
            activeEnrollmentID = nil
            statusText = "Enrollment complete for \(updated.displayName). Recognition is now active."
        } else {
            statusText = enrollmentPrompt(for: updated)
        }
        publishState()
    }

    private func processRecognitionFaces(_ faces: [VNFaceObservation], source: CIImage) {
        let candidates = cachedProfiles.filter {
            $0.enrollmentIsComplete && $0.modelIdentifier == selectedModelValue.rawValue
        }
        guard !candidates.isEmpty else { return }
        guard let encoder = try? encoder(for: selectedModelValue) else {
            statusText = "\(selectedModelValue.displayName) is not installed."
            publishState()
            return
        }
        var best: (profile: ROBFaceIdentityProfile, distance: Float, second: Float)?
        for face in faces where Self.area(face.boundingBox) >= 0.025 {
            guard (face.faceCaptureQuality ?? 0) >= 0.35,
                  let crop = faceCrop(face.boundingBox, source: source),
                  let probe = try? encoder.embedding(for: crop) else { continue }
            let ranked = candidates.compactMap { profile -> (ROBFaceIdentityProfile, Float)? in
                let distances = profile.samples.compactMap { sample -> Float? in
                    guard let enrolled = sample.embedding else { return nil }
                    return Self.cosineDistance(probe, enrolled)
                }
                guard let nearest = distances.min() else { return nil }
                return (profile, nearest)
            }.sorted { $0.1 < $1.1 }
            guard let first = ranked.first else { continue }
            let secondDistance = ranked.dropFirst().first?.1 ?? .greatestFiniteMagnitude
            if best == nil || first.1 < best!.distance {
                best = (first.0, first.1, secondDistance)
            }
        }
        guard let best else {
            resetTemporalCandidate()
            ROBSceneSnapshotStore.shared.updateIdentifiedPeople([])
            return
        }

        // Conservative starting points; calibrate against ROB's actual camera.
        let threshold = configuredFloat("ROBFaceIdentity.maximumCosineDistance", fallback: 0.35, range: 0.01...1)
        let margin = configuredFloat("ROBFaceIdentity.minimumCosineMargin", fallback: 0.06, range: 0...0.5)
        guard best.distance <= threshold, best.second - best.distance >= margin else {
            resetTemporalCandidate()
            statusText = "A face is visible, but it is not confidently recognized."
            ROBSceneSnapshotStore.shared.updateIdentifiedPeople([])
            publishState()
            return
        }

        if pendingCandidateID == best.profile.id {
            pendingCandidateFrames += 1
        } else {
            pendingCandidateID = best.profile.id
            pendingCandidateFrames = 1
        }
        guard pendingCandidateFrames >= 3 else { return }
        pendingCandidateFrames = 0
        if let previous = lastRecognitionValue,
           previous.profileID == best.profile.id,
           Date().timeIntervalSince(previous.confirmedAt) < 8 {
            ROBSceneSnapshotStore.shared.updateIdentifiedPeople([best.profile.displayName])
            return
        }
        let result = ROBFaceRecognitionResult(
            profileID: best.profile.id,
            displayName: best.profile.displayName,
            role: best.profile.role,
            distance: best.distance,
            confirmedAt: Date()
        )
        lastRecognitionValue = result
        statusText = "Recognized \(result.displayName) as \(result.role.displayName.lowercased())."
        ROBSceneSnapshotStore.shared.updateIdentifiedPeople([result.displayName])
        try? gallery.markConfirmed(profileID: result.profileID, at: result.confirmedAt)
        publishState()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .robFaceIdentityDidRecognize,
                object: self,
                userInfo: ["result": result]
            )
        }
    }

    private func sampleIsDiverse(_ probe: [Float], profileID: UUID) -> Bool {
        guard let profile = cachedProfiles.first(where: { $0.id == profileID }) else { return false }
        for sample in profile.samples.suffix(60) {
            guard let enrolled = sample.embedding else { continue }
            if Self.cosineDistance(probe, enrolled) < 0.04 {
                return false
            }
        }
        return true
    }

    private func encoder(for option: ROBFaceEmbeddingModelOption) throws -> ROBFaceCoreMLEncoder {
        if let cached = encoders[option] { return cached }
        let encoder = try ROBFaceCoreMLEncoder(option: option)
        encoders[option] = encoder
        return encoder
    }

    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .greatestFiniteMagnitude }
        return 1 - zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
    }

    private func faceCrop(_ normalized: CGRect, source: CIImage) -> CGImage? {
        let extent = source.extent
        let faceRectangle = CGRect(
            x: extent.minX + normalized.minX * extent.width,
            y: extent.minY + normalized.minY * extent.height,
            width: normalized.width * extent.width,
            height: normalized.height * extent.height
        )
        let side = min(
            max(faceRectangle.width, faceRectangle.height) * 1.36,
            min(extent.width, extent.height)
        )
        var origin = CGPoint(
            x: faceRectangle.midX - side / 2,
            y: faceRectangle.midY - side / 2
        )
        origin.x = min(max(origin.x, extent.minX), extent.maxX - side)
        origin.y = min(max(origin.y, extent.minY), extent.maxY - side)
        let rectangle = CGRect(origin: origin, size: CGSize(width: side, height: side))
            .intersection(extent)
            .integral
        guard rectangle.width >= 80, rectangle.height >= 80 else { return nil }
        return imageContext.createCGImage(source, from: rectangle)
    }

    private func jpegData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        )
    }

    private func enrollmentPrompt(for profile: ROBFaceIdentityProfile) -> String {
        let count = profile.samples.count
        let direction: String
        switch count % 6 {
        case 0: direction = "look straight at ROB"
        case 1: direction = "turn slightly left"
        case 2: direction = "turn slightly right"
        case 3: direction = "look slightly up"
        case 4: direction = "look slightly down"
        default: direction = "change your expression naturally"
        }
        return "Enrolling \(profile.displayName): \(count)/\(Self.enrollmentTargetSamples) accepted; \(direction)."
    }

    private func updateStatusWhileEnrolling(_ status: String) {
        guard activeEnrollmentID != nil else { return }
        statusText = status
        publishState()
    }

    private func resetTemporalCandidate() {
        pendingCandidateID = nil
        pendingCandidateFrames = 0
    }

    private func configuredFloat(_ key: String, fallback: Float, range: ClosedRange<Float>) -> Float {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(range.upperBound, max(range.lowerBound, defaults.float(forKey: key)))
    }

    private func reloadProfiles() {
        do {
            cachedProfiles = try gallery.profiles()
        } catch {
            cachedProfiles = []
            statusText = error.localizedDescription
        }
        publishState()
    }

    private func replaceCachedProfile(_ profile: ROBFaceIdentityProfile) {
        if let index = cachedProfiles.firstIndex(where: { $0.id == profile.id }) {
            cachedProfiles[index] = profile
        } else {
            cachedProfiles.append(profile)
        }
    }

    private func snapshotUnlocked() -> ROBFaceIdentityServiceSnapshot {
        let accepted = activeEnrollmentID.flatMap { id in
            cachedProfiles.first(where: { $0.id == id })?.samples.count
        } ?? 0
        return ROBFaceIdentityServiceSnapshot(
            enabled: enabled,
            profiles: cachedProfiles.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            },
            enrollingProfileID: activeEnrollmentID,
            enrollmentAcceptedSamples: accepted,
            enrollmentTargetSamples: Self.enrollmentTargetSamples,
            status: statusText,
            lastRecognition: lastRecognitionValue,
            selectedModel: selectedModelValue,
            availableModels: ROBFaceEmbeddingModelOption.allCases
        )
    }

    private func publishState() {
        let snapshot = snapshotUnlocked()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .robFaceIdentityStateDidChange,
                object: self,
                userInfo: ["snapshot": snapshot]
            )
        }
    }

    private static func area(_ rectangle: CGRect) -> CGFloat {
        rectangle.width * rectangle.height
    }
}
