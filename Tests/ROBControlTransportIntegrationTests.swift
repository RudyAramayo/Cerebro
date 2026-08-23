import Foundation

#if ROB_CONTROL_IDENTITY_FIXTURE && os(macOS)
import Network
import Security

enum ROBVideoTransport {
    static let applicationProtocol = "robvideo/1"
}

@available(macOS 12.0, *)
final class ROBVideoFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: ROBVideoFramer.self)
    static var label: String { "ROBVideoFixture" }

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
    func handleInput(framer: NWProtocolFramer.Instance) -> Int { 0 }
    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {}
}
#endif

private enum TransportFixtureError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct LegacyROBControlCredential: Codable {
    let version: Int
    let robotID: UUID
    let controllerID: UUID
    let serviceType: String
    let applicationProtocol: String
    let certificateSHA256: Data
    let sharedSecret: Data
}

@main
struct ROBControlTransportIntegrationTests {
    static func main() throws {
        let credential = ROBControlCredential(
            version: 2,
            robotID: UUID(),
            controllerID: UUID(),
            serviceType: ROBControlPairing.serviceType,
            applicationProtocol: ROBControlPairing.applicationProtocol,
            certificateSHA256: Data(repeating: 0xA5, count: 32),
            sharedSecret: Data((0..<32).map(UInt8.init)),
            role: .operatorController,
            deviceName: "Fixture ROBController",
            issuedAtMilliseconds: 1_725_000_000_000
        )

        try testAuthentication(with: credential)
        try testCredentialRoleCompatibility(using: credential)
        try testAuthorizationPolicy()
        try testLidarTelemetry()
        #if ROB_CONTROL_IDENTITY_FIXTURE && os(macOS)
        try testPersistentServerIdentity()
        #endif

        print("ROB control pairing, identity persistence, role authorization, and Lidar telemetry fixtures passed")
    }

    private static func testAuthentication(with credential: ROBControlCredential) throws {
        let challenge = try ROBControlAuthenticator.makeChallenge(robotID: credential.robotID)
        let proof = try ROBControlAuthenticator.makeProof(challenge: challenge, credential: credential)
        try expect(
            ROBControlAuthenticator.validate(proof, challenge: challenge, credential: credential),
            "A valid controller proof was rejected"
        )

        let accepted = ROBControlAuthenticator.accepted(
            for: proof,
            challenge: challenge,
            credential: credential
        )
        try expect(
            ROBControlAuthenticator.validate(
                accepted,
                proof: proof,
                challenge: challenge,
                credential: credential
            ),
            "A valid server acceptance proof was rejected"
        )

        let wrongSecret = ROBControlCredential(
            version: credential.version,
            robotID: credential.robotID,
            controllerID: credential.controllerID,
            serviceType: credential.serviceType,
            applicationProtocol: credential.applicationProtocol,
            certificateSHA256: credential.certificateSHA256,
            sharedSecret: Data(repeating: 0x5A, count: 32),
            role: credential.role,
            deviceName: credential.deviceName,
            issuedAtMilliseconds: credential.issuedAtMilliseconds
        )
        try expect(
            !ROBControlAuthenticator.validate(
                proof,
                challenge: challenge,
                credential: wrongSecret
            ),
            "A proof made with the wrong pairing secret was accepted"
        )

        let replayChallenge = try ROBControlAuthenticator.makeChallenge(robotID: credential.robotID)
        try expect(
            !ROBControlAuthenticator.validate(
                proof,
                challenge: replayChallenge,
                credential: credential
            ),
            "A proof replayed into a fresh connection was accepted"
        )

        var tamperedAcceptedBytes = accepted.encoded
        tamperedAcceptedBytes[tamperedAcceptedBytes.index(before: tamperedAcceptedBytes.endIndex)] ^= 0x01
        let tamperedAccepted = try require(
            ROBControlAuthAccepted(tamperedAcceptedBytes),
            "The tampered acceptance fixture could not be decoded"
        )
        try expect(
            !ROBControlAuthenticator.validate(
                tamperedAccepted,
                proof: proof,
                challenge: challenge,
                credential: credential
            ),
            "A tampered server acceptance proof was accepted"
        )

        try expect(
            challenge.encoded.count == ROBControlAuthChallenge.encodedSize
                && proof.encoded.count == ROBControlAuthProof.encodedSize
                && accepted.encoded.count == ROBControlAuthAccepted.encodedSize,
            "The fixed-width authentication wire format changed"
        )
    }

    private static func testCredentialRoleCompatibility(
        using operatorCredential: ROBControlCredential
    ) throws {
        let legacy = LegacyROBControlCredential(
            version: operatorCredential.version,
            robotID: operatorCredential.robotID,
            controllerID: operatorCredential.controllerID,
            serviceType: operatorCredential.serviceType,
            applicationProtocol: operatorCredential.applicationProtocol,
            certificateSHA256: operatorCredential.certificateSHA256,
            sharedSecret: operatorCredential.sharedSecret
        )
        let decodedLegacy = try JSONDecoder().decode(
            ROBControlCredential.self,
            from: JSONEncoder().encode(legacy)
        )
        try expect(decodedLegacy.role == nil, "A legacy credential unexpectedly gained a wire role")
        try expect(
            decodedLegacy.effectiveRole == .operatorController,
            "A role-less legacy credential did not default to operatorController"
        )

        let lidarCredential = ROBControlCredential(
            version: 2,
            robotID: operatorCredential.robotID,
            controllerID: UUID(),
            serviceType: ROBControlPairing.serviceType,
            applicationProtocol: ROBControlPairing.applicationProtocol,
            certificateSHA256: operatorCredential.certificateSHA256,
            sharedSecret: Data(repeating: 0x3C, count: 32),
            role: .lidarPublisher,
            deviceName: "Fixture RPLidar",
            issuedAtMilliseconds: 1_725_000_000_001
        )
        let decodedLidar = try JSONDecoder().decode(
            ROBControlCredential.self,
            from: JSONEncoder().encode(lidarCredential)
        )
        try expect(decodedLidar == lidarCredential, "The explicit Lidar credential did not round-trip")
        try expect(
            decodedLidar.effectiveRole == .lidarPublisher,
            "The explicit Lidar role was not preserved"
        )
    }

    private static func testAuthorizationPolicy() throws {
        try expect(
            DataMessageType.lidarTelemetry.rawValue == 7,
            "The typed Lidar frame number changed"
        )
        try expect(
            ROBControlAuthorizationPolicy.allowsInbound(.sendData, for: .operatorController),
            "An operator was denied the controller application frame"
        )
        try expect(
            !ROBControlAuthorizationPolicy.allowsInbound(.lidarTelemetry, for: .operatorController),
            "An operator credential was allowed to impersonate a Lidar publisher"
        )
        try expect(
            ROBControlAuthorizationPolicy.allowsInbound(.lidarTelemetry, for: .lidarPublisher),
            "A Lidar publisher was denied typed telemetry"
        )
        try expect(
            ROBControlAuthorizationPolicy.allowsInbound(.sendData, for: .lidarPublisher),
            "A Lidar publisher was denied the reserved network-probe response lane"
        )
        try expect(
            ROBControlAuthorizationPolicy.allowsOutbound(.sendData, to: .operatorController),
            "Controller results could not be routed to an operator"
        )
        try expect(
            !ROBControlAuthorizationPolicy.allowsOutbound(.sendData, to: .lidarPublisher),
            "Generic controller output could be leaked to a Lidar publisher"
        )
    }

    private static func testLidarTelemetry() throws {
        let deviceID = UUID()
        let now: UInt64 = 1_725_000_010_000
        let points = (0..<8).map {
            ROBLidarWirePoint(
                distanceMeters: 0.4 + Float($0) * 0.01,
                angleRadians: -0.3 + Float($0) * 0.08
            )
        }
        let scan = ROBLidarScanFrame(
            deviceID: deviceID,
            sequence: 41,
            sentAtMilliseconds: now - 100,
            x: 1,
            y: -2,
            z: 0.25,
            yaw: 0.2,
            pitch: -0.1,
            roll: 0.05,
            points: points
        )
        let encodedScan = try scan.encoded()
        let decodedScan = try ROBLidarScanFrame.decode(encodedScan)
        try expect(
            Data(encodedScan.prefix(4)) == Data([0x52, 0x4C, 0x53, 0x31])
                && encodedScan.count == ROBLidarScanFrame.headerLength
                    + scan.points.count * ROBLidarScanFrame.pointStride
                && decodedScan.deviceID == scan.deviceID
                && decodedScan.sequence == scan.sequence
                && decodedScan.points.count == scan.points.count,
            "A typed Lidar scan did not round-trip"
        )
        try expect(
            decodedScan.validationError(
                authenticatedDeviceID: deviceID,
                lastAcceptedSequence: 40,
                nowMilliseconds: now
            ) == nil,
            "A valid typed Lidar scan failed validation"
        )
        try expect(
            decodedScan.validationError(
                authenticatedDeviceID: UUID(),
                lastAcceptedSequence: 40,
                nowMilliseconds: now
            ) != nil,
            "Telemetry from a different authenticated device was accepted"
        )
        try expect(
            decodedScan.validationError(
                authenticatedDeviceID: deviceID,
                lastAcceptedSequence: scan.sequence,
                nowMilliseconds: now
            ) != nil,
            "A duplicate Lidar sequence was accepted"
        )

        let staleScan = ROBLidarScanFrame(
            deviceID: deviceID,
            sequence: 42,
            sentAtMilliseconds: now - ROBLidarScanFrame.maximumMessageAgeMilliseconds - 1,
            x: 0,
            y: 0,
            z: 0,
            yaw: 0,
            pitch: 0,
            roll: 0,
            points: points
        )
        try expect(
            staleScan.validationError(
                authenticatedDeviceID: deviceID,
                lastAcceptedSequence: 41,
                nowMilliseconds: now
            ) != nil,
            "Stale Lidar telemetry was accepted"
        )

        let shortScan = ROBLidarScanFrame(
            deviceID: deviceID,
            sequence: 43,
            sentAtMilliseconds: now,
            x: 0,
            y: 0,
            z: 0,
            yaw: 0,
            pitch: 0,
            roll: 0,
            points: Array(points.prefix(7))
        )
        try expect(
            shortScan.validationError(
                authenticatedDeviceID: deviceID,
                lastAcceptedSequence: 42,
                nowMilliseconds: now
            ) != nil,
            "A scan below the minimum point count was accepted"
        )

        var unsupportedHeader = encodedScan
        unsupportedHeader[5] = 1
        do {
            _ = try ROBLidarScanFrame.decode(unsupportedHeader)
            throw TransportFixtureError.failed("Reserved Lidar header flags were accepted")
        } catch ROBLidarTelemetryEncodingError.invalid {
            // Expected: version 1 reserves all header flag bits.
        }
        do {
            _ = try ROBLidarScanFrame.decode(Data("{\"kind\":\"scan\"}".utf8))
            throw TransportFixtureError.failed("Removed JSON Lidar telemetry was accepted")
        } catch {
            // Expected: there is deliberately no compatibility decoder.
        }
    }

    #if ROB_CONTROL_IDENTITY_FIXTURE && os(macOS)
    private static func testPersistentServerIdentity() throws {
        let keychainURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CerebroROBControlIdentityFixture-\(UUID().uuidString).keychain-db"
        )
        let password = "fixture-\(UUID().uuidString)"
        var keychain: SecKeychain?
        var fixtureError: Error?

        do {
            let createStatus = keychainURL.path.withCString { pathPointer in
                password.withCString { passwordPointer in
                    SecKeychainCreate(
                        pathPointer,
                        UInt32(password.utf8.count),
                        passwordPointer,
                        false,
                        nil,
                        &keychain
                    )
                }
            }
            try expect(createStatus == errSecSuccess, "Could not create the isolated fixture Keychain")
            let fixtureKeychain = try require(keychain, "The isolated fixture Keychain was unavailable")
            let unlockStatus = password.withCString { passwordPointer in
                SecKeychainUnlock(
                    fixtureKeychain,
                    UInt32(password.utf8.count),
                    passwordPointer,
                    true
                )
            }
            try expect(unlockStatus == errSecSuccess, "Could not unlock the isolated fixture Keychain")

            let result = try ROBControlPairing.runIdentityPersistenceFixture(
                keychain: fixtureKeychain,
                iterations: 3
            )
            try expect(result.fingerprints.count == 3, "The identity fixture skipped a load")
            try expect(
                Set(result.fingerprints).count == 1,
                "Repeated identity loads rotated the TLS certificate fingerprint"
            )
            try expect(
                result.certificateCount == 1,
                "Repeated identity loads created duplicate TLS certificates"
            )
        } catch {
            fixtureError = error
        }

        var cleanupMessages: [String] = []
        if let keychain {
            let deleteStatus = SecKeychainDelete(keychain)
            if deleteStatus != errSecSuccess && deleteStatus != errSecNoSuchKeychain {
                cleanupMessages.append(
                    "SecKeychainDelete failed with OSStatus \(deleteStatus)"
                )
            }
        }

        if FileManager.default.fileExists(atPath: keychainURL.path) {
            do {
                try FileManager.default.removeItem(at: keychainURL)
            } catch {
                cleanupMessages.append(
                    "could not remove \(keychainURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        if FileManager.default.fileExists(atPath: keychainURL.path) {
            cleanupMessages.append("the temporary fixture Keychain still exists after cleanup")
        }

        if let fixtureError {
            if cleanupMessages.isEmpty {
                throw fixtureError
            }
            throw TransportFixtureError.failed(
                "\(fixtureError); cleanup also failed: \(cleanupMessages.joined(separator: "; "))"
            )
        }
        try expect(
            cleanupMessages.isEmpty,
            "Temporary fixture Keychain cleanup failed: \(cleanupMessages.joined(separator: "; "))"
        )
    }
    #endif

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TransportFixtureError.failed(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TransportFixtureError.failed(message) }
        return value
    }
}
