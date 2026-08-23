//
//  ROBFaceIdentityGallery.swift
//  Cerebro
//
//  Consent-based, encrypted local identity gallery for face enrollment.
//

import CryptoKit
import Foundation
import Security

public enum ROBFaceIdentityRole: String, Codable, CaseIterable, Sendable {
    case knownPerson
    case administrator

    public var displayName: String {
        switch self {
        case .knownPerson: return "Known person"
        case .administrator: return "Administrator"
        }
    }
}

public struct ROBFaceIdentitySample: Codable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let quality: Float
    public let yawRadians: Double?
    public let rollRadians: Double?
    /// AdaFace's normalized 512-dimensional vector. Optional so galleries
    /// created by the earlier Vision feature-print backend still decode.
    public let embedding: [Float]?
    public let featurePrintArchive: Data?
    public let encryptedImageFileName: String

    public init(
        id: UUID,
        capturedAt: Date,
        quality: Float,
        yawRadians: Double?,
        rollRadians: Double?,
        embedding: [Float]? = nil,
        featurePrintArchive: Data? = nil,
        encryptedImageFileName: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.quality = quality
        self.yawRadians = yawRadians
        self.rollRadians = rollRadians
        self.embedding = embedding
        self.featurePrintArchive = featurePrintArchive
        self.encryptedImageFileName = encryptedImageFileName
    }
}

public struct ROBFaceIdentityProfile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var pronunciation: String?
    public var role: ROBFaceIdentityRole
    public let consentedAt: Date
    public let trustedEnrollmentReference: String
    public var modelIdentifier: String
    public var samples: [ROBFaceIdentitySample]
    public var lastConfirmedAt: Date?

    public var enrollmentIsComplete: Bool { samples.count >= 12 }
}

public enum ROBFaceIdentityGalleryError: LocalizedError {
    case invalidInput(String)
    case identityNotFound
    case administratorAlreadyExists
    case keychain(OSStatus)
    case encryption
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): return detail
        case .identityNotFound: return "The selected person no longer exists."
        case .administratorAlreadyExists:
            return "An administrator is already enrolled. Delete or change that identity before imprinting another administrator."
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Face identity Keychain error \(status)."
        case .encryption:
            return "The encrypted face identity gallery could not be opened safely."
        case .storage(let detail): return "Face identity storage failed: \(detail)"
        }
    }
}

/// Stores only encrypted profile manifests and encrypted, consented face crops.
/// Directory names are opaque UUIDs; display names never become path components.
public final class ROBFaceIdentityGallery: @unchecked Sendable {
    public static let shared = ROBFaceIdentityGallery()

    private static let keychainService = "com.orbitusrobotics.Cerebro.FaceIdentity"
    private static let keychainAccount = "gallery-encryption-key-v1"
    private static let profileFileName = "profile.robidentity"

    private let rootURL: URL
    private let keyDataProvider: () throws -> Data
    private let queue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.FaceIdentityGallery")
    private var cachedKey: SymmetricKey?

    public convenience init() {
        self.init(rootURL: Self.defaultRootURL(), keyDataProvider: Self.loadOrCreateProductionKey)
    }

    init(rootURL: URL, encryptionKey: Data) {
        self.rootURL = rootURL
        keyDataProvider = { encryptionKey }
    }

    private init(rootURL: URL, keyDataProvider: @escaping () throws -> Data) {
        self.rootURL = rootURL
        self.keyDataProvider = keyDataProvider
    }

    public func profiles() throws -> [ROBFaceIdentityProfile] {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
            let directories = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return try directories.compactMap { directory in
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return nil
                }
                let profileURL = directory.appendingPathComponent(Self.profileFileName)
                guard FileManager.default.fileExists(atPath: profileURL.path) else { return nil }
                return try readProfile(at: profileURL)
            }.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    public func createProfile(
        displayName: String,
        pronunciation: String?,
        role: ROBFaceIdentityRole,
        trustedEnrollmentReference: String,
        modelIdentifier: String
    ) throws -> ROBFaceIdentityProfile {
        try queue.sync {
            let name = try boundedRequired(displayName, maximum: 120, label: "name")
            let spokenName = try boundedOptional(pronunciation, maximum: 160, label: "pronunciation")
            let trust = try boundedRequired(
                trustedEnrollmentReference,
                maximum: 160,
                label: "trusted enrollment reference"
            )
            if role == .administrator,
               try allProfilesUnlocked().contains(where: { $0.role == .administrator }) {
                throw ROBFaceIdentityGalleryError.administratorAlreadyExists
            }
            let profile = ROBFaceIdentityProfile(
                id: UUID(),
                displayName: name,
                pronunciation: spokenName,
                role: role,
                consentedAt: Date(),
                trustedEnrollmentReference: trust,
                modelIdentifier: modelIdentifier,
                samples: [],
                lastConfirmedAt: nil
            )
            try writeProfile(profile)
            return profile
        }
    }

    public func appendSample(
        _ sample: ROBFaceIdentitySample,
        encryptedImagePlaintext: Data,
        to profileID: UUID
    ) throws -> ROBFaceIdentityProfile {
        try queue.sync {
            var profile = try profileUnlocked(id: profileID)
            guard profile.samples.count < 200 else {
                throw ROBFaceIdentityGalleryError.invalidInput(
                    "This identity already has the maximum of 200 retained samples."
                )
            }
            let directory = profileDirectory(profileID)
            let samplesDirectory = directory.appendingPathComponent("samples", isDirectory: true)
            try createPrivateDirectory(samplesDirectory)
            let imageURL = samplesDirectory.appendingPathComponent(sample.encryptedImageFileName)
            let encryptedImage = try seal(encryptedImagePlaintext)
            do {
                try encryptedImage.write(to: imageURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
                profile.samples.append(sample)
                try writeProfile(profile)
                return profile
            } catch {
                try? FileManager.default.removeItem(at: imageURL)
                if let galleryError = error as? ROBFaceIdentityGalleryError { throw galleryError }
                throw ROBFaceIdentityGalleryError.storage(error.localizedDescription)
            }
        }
    }

    public func markConfirmed(profileID: UUID, at date: Date = Date()) throws {
        try queue.sync {
            var profile = try profileUnlocked(id: profileID)
            profile.lastConfirmedAt = date
            try writeProfile(profile)
        }
    }

    public func deleteProfile(id: UUID) throws {
        try queue.sync {
            let directory = profileDirectory(id)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw ROBFaceIdentityGalleryError.identityNotFound
            }
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                throw ROBFaceIdentityGalleryError.storage(error.localizedDescription)
            }
        }
    }

    private func allProfilesUnlocked() throws -> [ROBFaceIdentityProfile] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { directory in
            let profileURL = directory.appendingPathComponent(Self.profileFileName)
            guard FileManager.default.fileExists(atPath: profileURL.path) else { return nil }
            return try readProfile(at: profileURL)
        }
    }

    private func profileUnlocked(id: UUID) throws -> ROBFaceIdentityProfile {
        let url = profileDirectory(id).appendingPathComponent(Self.profileFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ROBFaceIdentityGalleryError.identityNotFound
        }
        return try readProfile(at: url)
    }

    private func readProfile(at url: URL) throws -> ROBFaceIdentityProfile {
        do {
            let encrypted = try Data(contentsOf: url, options: [.mappedIfSafe])
            return try JSONDecoder().decode(ROBFaceIdentityProfile.self, from: open(encrypted))
        } catch let error as ROBFaceIdentityGalleryError {
            throw error
        } catch {
            throw ROBFaceIdentityGalleryError.storage(error.localizedDescription)
        }
    }

    private func writeProfile(_ profile: ROBFaceIdentityProfile) throws {
        do {
            let directory = profileDirectory(profile.id)
            try createPrivateDirectory(directory)
            let encoded = try JSONEncoder().encode(profile)
            let url = directory.appendingPathComponent(Self.profileFileName)
            try seal(encoded).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as ROBFaceIdentityGalleryError {
            throw error
        } catch {
            throw ROBFaceIdentityGalleryError.storage(error.localizedDescription)
        }
    }

    private func seal(_ plaintext: Data) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(plaintext, using: try encryptionKey())
            guard let combined = sealed.combined else { throw ROBFaceIdentityGalleryError.encryption }
            return combined
        } catch let error as ROBFaceIdentityGalleryError {
            throw error
        } catch {
            throw ROBFaceIdentityGalleryError.encryption
        }
    }

    private func open(_ ciphertext: Data) throws -> Data {
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: ciphertext),
                using: try encryptionKey()
            )
        } catch let error as ROBFaceIdentityGalleryError {
            throw error
        } catch {
            throw ROBFaceIdentityGalleryError.encryption
        }
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let data = try keyDataProvider()
        guard data.count == 32 else { throw ROBFaceIdentityGalleryError.encryption }
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }

    private func profileDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw ROBFaceIdentityGalleryError.storage(error.localizedDescription)
        }
    }

    private func boundedRequired(_ value: String, maximum: Int, label: String) throws -> String {
        let bounded = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty else {
            throw ROBFaceIdentityGalleryError.invalidInput("Enter a \(label).")
        }
        guard bounded.count <= maximum else {
            throw ROBFaceIdentityGalleryError.invalidInput(
                "The \(label) must be no longer than \(maximum) characters."
            )
        }
        return bounded
    }

    private func boundedOptional(_ value: String?, maximum: Int, label: String) throws -> String? {
        guard let value else { return nil }
        let bounded = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if bounded.isEmpty { return nil }
        guard bounded.count <= maximum else {
            throw ROBFaceIdentityGalleryError.invalidInput(
                "The \(label) must be no longer than \(maximum) characters."
            )
        }
        return bounded
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Cerebro", isDirectory: true)
            .appendingPathComponent("People", isDirectory: true)
    }

    private static func loadOrCreateProductionKey() throws -> Data {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else {
                throw ROBFaceIdentityGalleryError.encryption
            }
            return data
        }
        guard status == errSecItemNotFound else {
            throw ROBFaceIdentityGalleryError.keychain(status)
        }

        var keyData = Data(count: 32)
        let randomStatus = keyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw ROBFaceIdentityGalleryError.keychain(randomStatus)
        }
        var newItem = identity
        newItem[kSecValueData as String] = keyData
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        if addStatus == errSecSuccess { return keyData }
        if addStatus == errSecDuplicateItem {
            item = nil
            let retry = SecItemCopyMatching(query as CFDictionary, &item)
            guard retry == errSecSuccess, let data = item as? Data, data.count == 32 else {
                throw ROBFaceIdentityGalleryError.keychain(retry)
            }
            return data
        }
        throw ROBFaceIdentityGalleryError.keychain(addStatus)
    }
}
