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
}

/// This first on-device backend uses Apple's feature-print representation over
/// aligned face crops. The archive boundary is intentionally backend-versioned
/// so a licensed ArcFace/AdaFace Core ML encoder can replace it and retained,
/// consented images can be re-embedded without changing gallery ownership.
@objcMembers public final class ROBFaceRecognitionService: NSObject {
    public static let shared = ROBFaceRecognitionService()

    public static let modelIdentifier = "vision-face-crop-featureprint-v1"
    public static let enrollmentTargetSamples = 24

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
        super.init()
        analysisQueue.async { self.reloadProfiles() }
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
                    modelIdentifier: Self.modelIdentifier
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
        let featurePrint = try featurePrint(for: crop)
        guard sampleIsDiverse(featurePrint, profileID: profileID) else {
            updateStatusWhileEnrolling("Good—now turn your head slightly for a different view.")
            return
        }
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: featurePrint,
            requiringSecureCoding: true
        )
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
            featurePrintArchive: archive,
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
        let candidates = cachedProfiles.filter(\.enrollmentIsComplete)
        guard !candidates.isEmpty else { return }
        var best: (profile: ROBFaceIdentityProfile, distance: Float, second: Float)?
        for face in faces where Self.area(face.boundingBox) >= 0.025 {
            guard (face.faceCaptureQuality ?? 0) >= 0.35,
                  let crop = faceCrop(face.boundingBox, source: source),
                  let probe = try? featurePrint(for: crop) else { continue }
            let ranked = candidates.compactMap { profile -> (ROBFaceIdentityProfile, Float)? in
                let distances = profile.samples.compactMap { sample -> Float? in
                    guard let enrolled = Self.unarchiveFeaturePrint(sample.featurePrintArchive) else { return nil }
                    var distance: Float = 0
                    guard (try? probe.computeDistance(&distance, to: enrolled)) != nil else { return nil }
                    return distance
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

        // Feature-print distance is device/API dependent, so both controls are
        // configurable and deliberately conservative. Unknown remains a valid result.
        let threshold = configuredFloat("ROBFaceIdentity.maximumDistance", fallback: 8.5, range: 0.1...100)
        let margin = configuredFloat("ROBFaceIdentity.minimumMargin", fallback: 1.0, range: 0...50)
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

    private func sampleIsDiverse(_ probe: VNFeaturePrintObservation, profileID: UUID) -> Bool {
        guard let profile = cachedProfiles.first(where: { $0.id == profileID }) else { return false }
        for sample in profile.samples.suffix(60) {
            guard let enrolled = Self.unarchiveFeaturePrint(sample.featurePrintArchive) else { continue }
            var distance: Float = 0
            if (try? probe.computeDistance(&distance, to: enrolled)) != nil, distance < 0.45 {
                return false
            }
        }
        return true
    }

    private func featurePrint(for image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let result = request.results?.first else {
            throw ROBFaceIdentityGalleryError.storage("Vision returned no face feature representation.")
        }
        return result
    }

    private static func unarchiveFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    private func faceCrop(_ normalized: CGRect, source: CIImage) -> CGImage? {
        let extent = source.extent
        var rectangle = CGRect(
            x: extent.minX + normalized.minX * extent.width,
            y: extent.minY + normalized.minY * extent.height,
            width: normalized.width * extent.width,
            height: normalized.height * extent.height
        )
        rectangle = rectangle.insetBy(dx: -rectangle.width * 0.18, dy: -rectangle.height * 0.18)
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
            lastRecognition: lastRecognitionValue
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
