//
//  AutoNetDataTransferProtocol.swift
//  Cerebro
//
//  The v2 control plane is a reliable QUIC stream over UDP. Cerebro presents a
//  persistent P-256 identity, ROBController pins its leaf certificate during
//  pairing, and both sides prove possession of the pairing secret before any
//  application data is accepted. The original plaintext UDP framing remains
//  here only so the explicit legacy adapter can interoperate with older builds.
//

import CryptoKit
import Foundation
import Network
import Security

enum DataMessageType: UInt32 {
  case invalid = 0
  case sendData = 1
  case setAutomationScript = 2
  case pairingChallenge = 3
  case pairingProof = 4
  case pairingAccepted = 5
  case pairingRejected = 6
  case lidarTelemetry = 7
  case pairingHello = 8
}

enum AutoNetTransportError: LocalizedError {
  case unsupportedService(String)
  case legacyDisabled
  case pairingRequired
  case invalidPairingCode
  case keychain(OSStatus)
  case randomGeneration(OSStatus)
  case identityUnavailable(String)
  case authenticationFailed
  case authorizationFailed
  case credentialRevoked
  case listenerUnavailable

  var errorDescription: String? {
    switch self {
    case .unsupportedService(let service):
      return "Unsupported robot-control Bonjour service: \(service)"
    case .legacyDisabled:
      return
        "Legacy plaintext AutoNet is disabled. Set ROB_CONTROL_ALLOW_LEGACY_AUTONET=1 only for a deliberate compatibility session."
    case .pairingRequired:
      return "No ROBController pairing key is installed."
    case .invalidPairingCode:
      return "The ROBController pairing code is invalid or incomplete."
    case .keychain(let status):
      return "Unable to access the robot-control pairing key in Keychain (OSStatus \(status))."
    case .randomGeneration(let status):
      return "Unable to create a robot-control pairing key (OSStatus \(status))."
    case .identityUnavailable(let detail):
      return "Unable to load the robot-control TLS identity: \(detail)"
    case .authenticationFailed:
      return "The ROBController pairing proof was rejected."
    case .authorizationFailed:
      return "The paired device is not authorized for this robot-control message."
    case .credentialRevoked:
      return "The paired device credential has been revoked."
    case .listenerUnavailable:
      return "The robot-control listener could not be created."
    }
  }
}

enum ROBControlPeerRole: String, Codable, CaseIterable {
  case operatorController
  case lidarPublisher
}

struct ROBControlCredential: Codable, Equatable {
  let version: Int
  let robotID: UUID
  let controllerID: UUID
  let serviceType: String
  let applicationProtocol: String
  let certificateSHA256: Data
  let sharedSecret: Data
  let role: ROBControlPeerRole?
  let deviceName: String?
  let issuedAtMilliseconds: UInt64?

  init(
    version: Int,
    robotID: UUID,
    controllerID: UUID,
    serviceType: String,
    applicationProtocol: String,
    certificateSHA256: Data,
    sharedSecret: Data,
    role: ROBControlPeerRole? = nil,
    deviceName: String? = nil,
    issuedAtMilliseconds: UInt64? = nil
  ) {
    self.version = version
    self.robotID = robotID
    self.controllerID = controllerID
    self.serviceType = serviceType
    self.applicationProtocol = applicationProtocol
    self.certificateSHA256 = certificateSHA256
    self.sharedSecret = sharedSecret
    self.role = role
    self.deviceName = deviceName
    self.issuedAtMilliseconds = issuedAtMilliseconds
  }

  var isValid: Bool {
    let normalizedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
    return version == 2 && serviceType == ROBControlPairing.serviceType
      && applicationProtocol == ROBControlPairing.applicationProtocol
      && certificateSHA256.count == 32 && sharedSecret.count == 32
      && (normalizedName == nil
        || (normalizedName!.count >= 1 && normalizedName!.count <= 80
          && normalizedName!.rangeOfCharacter(from: .controlCharacters) == nil))
      && (issuedAtMilliseconds == nil || issuedAtMilliseconds! > 0)
  }

  /// Compatibility interpretation for credentials issued before roles existed.
  /// Cerebro authorization still uses its server-owned registry record instead.
  var effectiveRole: ROBControlPeerRole { role ?? .operatorController }
}

/// A server-owned authorization record. The role stored here, never a role
/// claimed by an incoming pairing-code payload, is authoritative.
struct ROBControlPeerAuthenticationRecord: Equatable {
  let credential: ROBControlCredential
  let role: ROBControlPeerRole
  let deviceName: String
  let issuedAtMilliseconds: UInt64
}

enum ROBControlAuthorizationPolicy {
  static func allowsInbound(_ type: DataMessageType, for role: ROBControlPeerRole) -> Bool {
    switch (role, type) {
    case (.operatorController, .sendData),
      (.lidarPublisher, .lidarTelemetry),
      // Reserved capability/echo data is claimed by AutoNetServer before the
      // command parser; every other publisher sendData payload is rejected.
      (.lidarPublisher, .sendData):
      return true
    default:
      return false
    }
  }

  static func allowsOutbound(_ type: DataMessageType, to role: ROBControlPeerRole) -> Bool {
    switch role {
    case .operatorController:
      return type == .sendData || type == .lidarTelemetry
    case .lidarPublisher:
      return false
    }
  }
}

struct ROBLidarWirePoint: Equatable, Sendable {
  let distanceMeters: Float
  let angleRadians: Float
}

/// Compact, fixed-layout scan payload for ROBControl frame type 7.
///
/// All integers and Float32 bit patterns use network byte order. The 68-byte
/// header is followed by `pointCount` four-byte samples: UInt16 millimeters and
/// UInt16 angle turns. Map rasters are deliberately not part of this protocol.
struct ROBLidarScanFrame: Equatable, Sendable {
  static let formatVersion: UInt8 = 1
  static let headerLength = 68
  static let pointStride = 4
  static let minimumPointCount = 8
  static let maximumPointCount = 8_192
  static let maximumEncodedBytes = headerLength + maximumPointCount * pointStride
  static let maximumMessageAgeMilliseconds: UInt64 = 2_000
  static let maximumFutureSkewMilliseconds: UInt64 = 5_000

  private static let magic = Data([0x52, 0x4C, 0x53, 0x31]) // RLS1
  private static let minimumDistanceMeters: Float = 0.03
  private static let maximumDistanceMeters: Float = 30
  private static let maximumAbsolutePositionMeters: Float = 1_000_000
  private static let radiansPerAngleUnit = Float.pi * 2 / 65_536

  let deviceID: UUID
  let sequence: UInt64
  let sentAtMilliseconds: UInt64
  let x: Float
  let y: Float
  let z: Float
  let yaw: Float
  let pitch: Float
  let roll: Float
  let points: [ROBLidarWirePoint]

  func validationError(
    authenticatedDeviceID: UUID,
    lastAcceptedSequence: UInt64,
    nowMilliseconds: UInt64
  ) -> String? {
    guard deviceID == authenticatedDeviceID else {
      return "device ID does not match authenticated peer"
    }
    guard sequence > 0, sequence > lastAcceptedSequence else {
      return "sequence is missing or not increasing"
    }
    guard sentAtMilliseconds > 0 else { return "timestamp is missing" }
    if sentAtMilliseconds > nowMilliseconds {
      guard sentAtMilliseconds - nowMilliseconds <= Self.maximumFutureSkewMilliseconds else {
        return "timestamp is too far in the future"
      }
    } else if nowMilliseconds - sentAtMilliseconds > Self.maximumMessageAgeMilliseconds {
      return "telemetry is stale"
    }
    let poseValues = [x, y, z, yaw, pitch, roll]
    guard poseValues.allSatisfy(\.isFinite),
      abs(x) <= Self.maximumAbsolutePositionMeters,
      abs(y) <= Self.maximumAbsolutePositionMeters,
      abs(z) <= Self.maximumAbsolutePositionMeters else {
      return "pose contains an invalid value"
    }
    guard (Self.minimumPointCount ... Self.maximumPointCount).contains(points.count) else {
      return "point count is outside the supported range"
    }
    guard points.allSatisfy({ point in
      point.distanceMeters.isFinite
        && (Self.minimumDistanceMeters ... Self.maximumDistanceMeters).contains(point.distanceMeters)
        && point.angleRadians.isFinite
    }) else {
      return "scan contains an invalid point"
    }
    return nil
  }

  func encoded() throws -> Data {
    let previous = sequence > 0 ? sequence - 1 : 0
    if let error = validationError(
      authenticatedDeviceID: deviceID,
      lastAcceptedSequence: previous,
      nowMilliseconds: sentAtMilliseconds
    ) {
      throw ROBLidarTelemetryEncodingError.invalid(error)
    }

    var data = Data(capacity: Self.headerLength + points.count * Self.pointStride)
    data.append(Self.magic)
    data.append(Self.formatVersion)
    data.append(0) // flags
    Self.append(UInt16(Self.headerLength), to: &data)
    data.append(Self.bytes(for: deviceID))
    Self.append(sequence, to: &data)
    Self.append(sentAtMilliseconds, to: &data)
    for value in [x, y, z, yaw, pitch, roll] {
      Self.append(value.bitPattern, to: &data)
    }
    Self.append(UInt16(points.count), to: &data)
    Self.append(UInt16(0), to: &data) // reserved
    for point in points {
      let millimeters = UInt16((point.distanceMeters * 1_000).rounded())
      let normalized = Self.normalizedAngle(point.angleRadians)
      let rawAngle = Int((normalized / Self.radiansPerAngleUnit).rounded()) & 0xFFFF
      Self.append(millimeters, to: &data)
      Self.append(UInt16(rawAngle), to: &data)
    }
    return data
  }

  static func decode(_ data: Data) throws -> ROBLidarScanFrame {
    guard data.count >= headerLength, data.count <= maximumEncodedBytes else {
      throw ROBLidarTelemetryEncodingError.oversized
    }
    let bytes = [UInt8](data)
    guard Data(bytes[0..<4]) == magic,
      bytes[4] == formatVersion,
      bytes[5] == 0,
      Int(readUInt16(bytes, at: 6)) == headerLength,
      let deviceID = uuid(from: bytes[8..<24]) else {
      throw ROBLidarTelemetryEncodingError.invalid("unsupported binary header")
    }
    let pointCount = Int(readUInt16(bytes, at: 64))
    guard readUInt16(bytes, at: 66) == 0,
      (minimumPointCount ... maximumPointCount).contains(pointCount),
      data.count == headerLength + pointCount * pointStride else {
      throw ROBLidarTelemetryEncodingError.invalid("length or point count is invalid")
    }

    let frame = ROBLidarScanFrame(
      deviceID: deviceID,
      sequence: readUInt64(bytes, at: 24),
      sentAtMilliseconds: readUInt64(bytes, at: 32),
      x: Float(bitPattern: readUInt32(bytes, at: 40)),
      y: Float(bitPattern: readUInt32(bytes, at: 44)),
      z: Float(bitPattern: readUInt32(bytes, at: 48)),
      yaw: Float(bitPattern: readUInt32(bytes, at: 52)),
      pitch: Float(bitPattern: readUInt32(bytes, at: 56)),
      roll: Float(bitPattern: readUInt32(bytes, at: 60)),
      points: stride(from: headerLength, to: data.count, by: pointStride).map { offset in
        let distance = Float(readUInt16(bytes, at: offset)) / 1_000
        var angle = Float(readUInt16(bytes, at: offset + 2)) * radiansPerAngleUnit
        if angle > .pi { angle -= .pi * 2 }
        return ROBLidarWirePoint(distanceMeters: distance, angleRadians: angle)
      }
    )
    let previous = frame.sequence > 0 ? frame.sequence - 1 : 0
    if let error = frame.validationError(
      authenticatedDeviceID: frame.deviceID,
      lastAcceptedSequence: previous,
      nowMilliseconds: frame.sentAtMilliseconds
    ) {
      throw ROBLidarTelemetryEncodingError.invalid(error)
    }
    return frame
  }

  private static func normalizedAngle(_ angle: Float) -> Float {
    var result = angle.truncatingRemainder(dividingBy: .pi * 2)
    if result < 0 { result += .pi * 2 }
    return result
  }

  private static func bytes(for identifier: UUID) -> Data {
    var value = identifier.uuid
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func uuid(from bytes: ArraySlice<UInt8>) -> UUID? {
    guard bytes.count == 16 else { return nil }
    var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    _ = withUnsafeMutableBytes(of: &value) { destination in
      Data(bytes).copyBytes(to: destination)
    }
    return UUID(uuid: value)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }

  private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
  }

  private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24)
      | (UInt32(bytes[offset + 1]) << 16)
      | (UInt32(bytes[offset + 2]) << 8)
      | UInt32(bytes[offset + 3])
  }

  private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in bytes[offset ..< offset + 8] {
      value = (value << 8) | UInt64(byte)
    }
    return value
  }
}

enum ROBLidarTelemetryEncodingError: LocalizedError {
  case invalid(String)
  case oversized

  var errorDescription: String? {
    switch self {
    case .invalid(let detail):
      return "Invalid RPLidar scan: \(detail)."
    case .oversized:
      return "RPLidar scan is outside the compact binary frame bounds."
    }
  }
}

@objcMembers public final class ROBControlPairedDevice: NSObject {
  public let deviceID: String
  public let deviceName: String
  public let roleName: String
  public let isRevoked: Bool

  init(deviceID: UUID, deviceName: String, role: ROBControlPeerRole, isRevoked: Bool) {
    self.deviceID = deviceID.uuidString.lowercased()
    self.deviceName = deviceName
    self.roleName = role.rawValue
    self.isRevoked = isRevoked
    super.init()
  }
}

extension Notification.Name {
  static let robControlCredentialWasRevoked = Notification.Name(
    "com.orbitusrobotics.robctl.v2.credential-revoked")
}

enum ROBControlCredentialNotification {
  static let deviceIDKey = "deviceID"
}

private struct ROBControlStoredPeerRecord: Codable {
  let deviceID: UUID
  var credential: ROBControlCredential?
  let role: ROBControlPeerRole
  let deviceName: String
  let issuedAtMilliseconds: UInt64
  var revokedAtMilliseconds: UInt64?

  var isRevoked: Bool { revokedAtMilliseconds != nil || credential == nil }
}

private struct ROBControlStoredPeerRegistry: Codable {
  static let currentVersion = 1
  let version: Int
  var peers: [ROBControlStoredPeerRecord]

  init(peers: [ROBControlStoredPeerRecord] = []) {
    self.version = Self.currentVersion
    self.peers = peers
  }
}

/// Keychain-backed pairing material transferred out-of-band from Cerebro to a
/// trusted controller. Bonjour contains only routing metadata; the certificate
/// pin and shared secret exist only in this code and the two devices' Keychains.
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
@objcMembers public final class ROBControlPairing: NSObject {
  public static let serviceType = "_robctl._udp"
  public static let legacyServiceType = "_roboNet._tcp"
  public static let applicationProtocol = "robctl/2"

  private static let keychainService = "com.orbitusrobotics.robctl.v2"
  private static let serverProfileAccount = "cerebro-server-profile"
  private static let clientProfileAccount = "paired-cerebro-profile"
  private static let peerRegistryAccount = "cerebro-peer-registry-v1"
  private static let legacySecretAccount = "tls-psk"
  private static let environmentKey = "ROB_CONTROL_PAIRING_SECRET"
  private static let pairingPrefix = "ROBCTL2:"
  private static let requiredSecretLength = 32
  private static let verifyQueue = DispatchQueue(label: "com.orbitusrobotics.robctl.v2.verify")
  private static let registryQueue = DispatchQueue(
    label: "com.orbitusrobotics.robctl.v2.credential-registry")
  private static var cachedPeerRegistry: ROBControlStoredPeerRegistry?

  #if os(macOS)
    private struct ServerIdentityContext {
      let loadedIdentity: ROBControlIdentityStore.LoadedIdentity
      let credential: ROBControlCredential
    }

    private static let serverIdentityQueue = DispatchQueue(
      label: "com.orbitusrobotics.robctl.v2.server-identity")
    private static var cachedServerIdentityContext: ServerIdentityContext?
  #endif

  #if ROB_CONTROL_IDENTITY_FIXTURE && os(macOS)
    static func runIdentityPersistenceFixture(
      keychain: SecKeychain,
      iterations: Int = 3
    ) throws -> (fingerprints: [Data], certificateCount: Int) {
      try ROBControlIdentityStore.runPersistenceFixture(
        keychain: keychain,
        iterations: iterations
      )
    }
  #endif

  public static var isPaired: Bool {
    guard let credential = try? loadCredential(account: clientProfileAccount) else { return false }
    return credential.isValid
  }

  /// Returns the already-installed code. This is intended only for a local,
  /// explicit pairing UI; callers must not log, persist, or advertise it.
  public static func currentPairingCode() -> String? {
    return try? ensurePairingCode()
  }

  /// Cerebro calls this once to create its persistent local pairing secret.
  /// ROBController should instead install the code shown by Cerebro.
  public static func ensurePairingCode() throws -> String {
    let credential = try serverCredential()
    try ensureLegacyCredentialIsRegistered(credential)
    let export = credentialWithMetadata(
      credential,
      role: .operatorController,
      deviceName: "Legacy ROBController",
      issuedAtMilliseconds: nil
    )
    let payload = try JSONEncoder().encode(export)
    return pairingPrefix + payload.base64EncodedString()
  }

  /// Issues a new, independently revocable full-control credential. Existing
  /// pairings are not changed or invalidated.
  public static func issueOperatorPairingCode(deviceName: String) throws -> String {
    try issuePairingCode(role: .operatorController, deviceName: deviceName)
  }

  /// Issues a new telemetry-only credential for an external RPLidar publisher.
  public static func issueLidarPairingCode(deviceName: String) throws -> String {
    try issuePairingCode(role: .lidarPublisher, deviceName: deviceName)
  }

  /// Returns active credentials and revoked tombstones without exposing secrets.
  public static func pairedDevices() -> [ROBControlPairedDevice] {
    do {
      let baseCredential = try serverCredential()
      try ensureLegacyCredentialIsRegistered(baseCredential)
      return try registryQueue.sync {
        let registry = try loadPeerRegistry()
        return registry.peers
          .sorted {
            if $0.isRevoked != $1.isRevoked { return !$0.isRevoked }
            if $0.deviceName != $1.deviceName {
              return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
            }
            return $0.deviceID.uuidString < $1.deviceID.uuidString
          }
          .map {
            ROBControlPairedDevice(
              deviceID: $0.deviceID,
              deviceName: $0.deviceName,
              role: $0.role,
              isRevoked: $0.isRevoked
            )
          }
      }
    } catch {
      print("ROBControl could not list paired devices: \(error.localizedDescription)")
      return []
    }
  }

  /// Persists a tombstone before notifying live servers. AutoNetServer observes
  /// this notification and immediately closes matching authenticated sessions.
  public static func revokeDevice(deviceID: String) throws {
    guard let identifier = UUID(uuidString: deviceID) else {
      throw AutoNetTransportError.invalidPairingCode
    }
    try registryQueue.sync {
      var registry = try loadPeerRegistry()
      guard let index = registry.peers.firstIndex(where: { $0.deviceID == identifier }) else {
        throw AutoNetTransportError.pairingRequired
      }
      if !registry.peers[index].isRevoked {
        registry.peers[index].credential = nil
        registry.peers[index].revokedAtMilliseconds = currentTimeMilliseconds()
        try storePeerRegistry(registry)
      }
    }
    NotificationCenter.default.post(
      name: .robControlCredentialWasRevoked,
      object: nil,
      userInfo: [ROBControlCredentialNotification.deviceIDKey: identifier]
    )
  }

  /// Installs a code transferred directly from Cerebro. Replacing a code
  /// intentionally revokes the previous pairing on this device.
  public static func installPairingCode(_ code: String) throws {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: pairingPrefix, options: [.anchored, .caseInsensitive]) != nil else {
      throw AutoNetTransportError.invalidPairingCode
    }
    let normalized =
      trimmed
      .replacingOccurrences(of: pairingPrefix, with: "", options: [.anchored, .caseInsensitive])
      .replacingOccurrences(of: " ", with: "")
    guard let payload = Data(base64Encoded: normalized),
      payload.count <= 4_096,
      let credential = try? JSONDecoder().decode(ROBControlCredential.self, from: payload),
      credential.isValid
    else {
      throw AutoNetTransportError.invalidPairingCode
    }
    try storeCredential(credential, account: clientProfileAccount)
  }

  public static func removePairing() throws {
    let status = SecItemDelete(genericQuery(account: clientProfileAccount) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AutoNetTransportError.keychain(status)
    }
  }

  public static func legacyTransportIsEnabled() -> Bool {
    let environmentValue = ProcessInfo.processInfo.environment["ROB_CONTROL_ALLOW_LEGACY_AUTONET"]?
      .lowercased()
    if ["1", "true", "yes"].contains(environmentValue ?? "") {
      return true
    }
    return UserDefaults.standard.bool(forKey: "ROBControlAllowLegacyAutoNet")
  }

  static func serverAuthenticationMaterial() throws -> ROBControlCredential {
    let credential = try serverCredential()
    try ensureLegacyCredentialIsRegistered(credential)
    return credential
  }

  /// Resolves an active peer by the identifier carried in its authenticated
  /// proof. The returned role comes exclusively from Cerebro's registry.
  static func activePeerAuthenticationRecord(
    for deviceID: UUID
  ) throws -> ROBControlPeerAuthenticationRecord? {
    try registryQueue.sync {
      let registry = try loadPeerRegistry()
      guard let peer = registry.peers.first(where: { $0.deviceID == deviceID }),
        !peer.isRevoked,
        let credential = peer.credential,
        credential.isValid
      else { return nil }
      return ROBControlPeerAuthenticationRecord(
        credential: credential,
        role: peer.role,
        deviceName: peer.deviceName,
        issuedAtMilliseconds: peer.issuedAtMilliseconds
      )
    }
  }

  static func clientAuthenticationMaterial() throws -> ROBControlCredential {
    if let code = ProcessInfo.processInfo.environment[environmentKey],
      !code.isEmpty,
      code.uppercased().hasPrefix(pairingPrefix)
    {
      try installPairingCode(code)
    }
    guard let credential = try loadCredential(account: clientProfileAccount), credential.isValid
    else {
      throw AutoNetTransportError.pairingRequired
    }
    return credential
  }

  static func makeV2ServerParameters() throws -> NWParameters {
    #if os(macOS)
      let loadedIdentity = try serverIdentityContext().loadedIdentity
      let quic = NWProtocolQUIC.Options(alpn: [applicationProtocol])
      quic.direction = .bidirectional
      quic.idleTimeout = 10_000
      let securityOptions = quic.securityProtocolOptions
      sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
      guard let localIdentity = sec_identity_create(loadedIdentity.identity) else {
        throw AutoNetTransportError.identityUnavailable(
          "Security.framework could not bridge the Keychain identity")
      }
      sec_protocol_options_set_local_identity(securityOptions, localIdentity)
      return framedQUICParameters(options: quic)
    #else
      throw AutoNetTransportError.identityUnavailable(
        "Cerebro's QUIC listener is supported only on macOS")
    #endif
  }

  /// Builds the media-plane listener with Cerebro's existing persistent TLS
  /// identity while keeping its ALPN, framing, queueing, and authorization
  /// independent from robot control.
  static func makeVideoServerParameters() throws -> NWParameters {
    #if os(macOS)
      let loadedIdentity = try serverIdentityContext().loadedIdentity
      let quic = NWProtocolQUIC.Options(alpn: [ROBVideoTransport.applicationProtocol])
      quic.direction = .bidirectional
      quic.idleTimeout = 10_000
      // The Vision client opens one bidirectional stream with its auth hello.
      // No other client-initiated or unidirectional flow is part of robvideo/1.
      quic.initialMaxStreamsBidirectional = 1
      quic.initialMaxStreamsUnidirectional = 0
      let securityOptions = quic.securityProtocolOptions
      sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
      guard let localIdentity = sec_identity_create(loadedIdentity.identity) else {
        throw AutoNetTransportError.identityUnavailable(
          "Security.framework could not bridge the Keychain identity")
      }
      sec_protocol_options_set_local_identity(securityOptions, localIdentity)

      let parameters = NWParameters(quic: quic)
      parameters.allowLocalEndpointReuse = true
      parameters.includePeerToPeer = true
      parameters.serviceClass = .interactiveVideo
      parameters.defaultProtocolStack.applicationProtocols.insert(
        NWProtocolFramer.Options(definition: ROBVideoFramer.definition),
        at: 0
      )
      return parameters
    #else
      throw AutoNetTransportError.identityUnavailable(
        "Cerebro's video listener is supported only on macOS")
    #endif
  }

  static func makeV2ClientParameters() throws -> NWParameters {
    let credential = try clientAuthenticationMaterial()
    return makeV2ClientParameters(pinnedCertificateSHA256: credential.certificateSHA256)
  }

  /// Internal injection point used by localhost transport fixtures.
  static func makeV2ClientParameters(pinnedCertificateSHA256 expectedFingerprint: Data)
    -> NWParameters
  {
    precondition(expectedFingerprint.count == 32)
    let quic = NWProtocolQUIC.Options(alpn: [applicationProtocol])
    quic.direction = .bidirectional
    quic.idleTimeout = 10_000
    let securityOptions = quic.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
    sec_protocol_options_set_verify_block(
      securityOptions,
      { _, trust, complete in
        let trustReference = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(trustReference) as? [SecCertificate],
          let leaf = chain.first
        else {
          complete(false)
          return
        }
        let leafData = SecCertificateCopyData(leaf) as Data
        complete(Data(SHA256.hash(data: leafData)) == expectedFingerprint)
      }, verifyQueue)
    return framedQUICParameters(options: quic)
  }

  static func serverBonjourTXTRecord() throws -> Data {
    let credential = try serverCredential()
    return NetService.data(fromTXTRecord: [
      "ver": Data("2".utf8),
      "alpn": Data(applicationProtocol.utf8),
      "robot_id": Data(credential.robotID.uuidString.lowercased().utf8),
    ])
  }

  static func pairedRobotID() -> UUID? {
    try? loadCredential(account: clientProfileAccount)?.robotID
  }

  static func robotID(fromBonjourMetadata metadata: NWBrowser.Result.Metadata) -> UUID? {
    guard case .bonjour(let txtRecord) = metadata,
      let string = txtRecord["robot_id"]
    else { return nil }
    return UUID(uuidString: string)
  }

  static func makeLegacyUDPParameters() throws -> NWParameters {
    guard legacyTransportIsEnabled() else {
      throw AutoNetTransportError.legacyDisabled
    }
    let parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    parameters.defaultProtocolStack.applicationProtocols.insert(
      NWProtocolFramer.Options(definition: LegacyAutoNetFramer.definition),
      at: 0
    )
    return parameters
  }

  private static func framedQUICParameters(options: NWProtocolQUIC.Options) -> NWParameters {
    let parameters = NWParameters(quic: options)
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    parameters.serviceClass = .signaling
    parameters.defaultProtocolStack.applicationProtocols.insert(
      NWProtocolFramer.Options(definition: ROBV2ControlFramer.definition),
      at: 0
    )
    return parameters
  }

  private static func genericQuery(account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
  }

  private static func loadData(account: String) throws -> Data? {
    var query = genericQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess {
      return result as? Data
    }
    guard status == errSecItemNotFound else {
      throw AutoNetTransportError.keychain(status)
    }

    return nil
  }

  private static func storeData(_ data: Data, account: String) throws {
    let updateStatus = SecItemUpdate(
      genericQuery(account: account) as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw AutoNetTransportError.keychain(updateStatus)
    }

    var addQuery = genericQuery(account: account)
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw AutoNetTransportError.keychain(addStatus)
    }
  }

  private static func loadCredential(account: String) throws -> ROBControlCredential? {
    guard let data = try loadData(account: account) else { return nil }
    guard let credential = try? JSONDecoder().decode(ROBControlCredential.self, from: data),
      credential.isValid
    else {
      throw AutoNetTransportError.invalidPairingCode
    }
    return credential
  }

  private static func storeCredential(_ credential: ROBControlCredential, account: String) throws {
    guard credential.isValid else { throw AutoNetTransportError.invalidPairingCode }
    try storeData(try JSONEncoder().encode(credential), account: account)
  }

  private static func issuePairingCode(
    role: ROBControlPeerRole,
    deviceName: String
  ) throws -> String {
    let normalizedName = try validatedDeviceName(deviceName)
    let server = try serverCredential()
    try ensureLegacyCredentialIsRegistered(server)
    let issuedAt = currentTimeMilliseconds()
    let credential = ROBControlCredential(
      version: 2,
      robotID: server.robotID,
      controllerID: UUID(),
      serviceType: serviceType,
      applicationProtocol: applicationProtocol,
      certificateSHA256: server.certificateSHA256,
      sharedSecret: try secureRandomData(count: requiredSecretLength),
      role: role,
      deviceName: normalizedName,
      issuedAtMilliseconds: issuedAt
    )
    guard credential.isValid else { throw AutoNetTransportError.invalidPairingCode }

    try registryQueue.sync {
      var registry = try loadPeerRegistry()
      guard !registry.peers.contains(where: { $0.deviceID == credential.controllerID }) else {
        throw AutoNetTransportError.invalidPairingCode
      }
      registry.peers.append(
        ROBControlStoredPeerRecord(
          deviceID: credential.controllerID,
          credential: credential,
          role: role,
          deviceName: normalizedName,
          issuedAtMilliseconds: issuedAt,
          revokedAtMilliseconds: nil
        ))
      try storePeerRegistry(registry)
    }

    let payload = try JSONEncoder().encode(credential)
    return pairingPrefix + payload.base64EncodedString()
  }

  private static func ensureLegacyCredentialIsRegistered(
    _ credential: ROBControlCredential
  ) throws {
    try registryQueue.sync {
      var registry = try loadPeerRegistry()
      // Never resurrect a revoked legacy credential. Its tombstone deliberately
      // wins over the old server-profile Keychain item.
      guard !registry.peers.contains(where: { $0.deviceID == credential.controllerID }) else {
        return
      }
      let issuedAt = currentTimeMilliseconds()
      let migrated = credentialWithMetadata(
        credential,
        role: .operatorController,
        deviceName: "Legacy ROBController",
        issuedAtMilliseconds: issuedAt
      )
      registry.peers.append(
        ROBControlStoredPeerRecord(
          deviceID: credential.controllerID,
          credential: migrated,
          role: .operatorController,
          deviceName: "Legacy ROBController",
          issuedAtMilliseconds: issuedAt,
          revokedAtMilliseconds: nil
        ))
      try storePeerRegistry(registry)
    }
  }

  private static func credentialWithMetadata(
    _ credential: ROBControlCredential,
    role: ROBControlPeerRole,
    deviceName: String,
    issuedAtMilliseconds: UInt64?
  ) -> ROBControlCredential {
    ROBControlCredential(
      version: credential.version,
      robotID: credential.robotID,
      controllerID: credential.controllerID,
      serviceType: credential.serviceType,
      applicationProtocol: credential.applicationProtocol,
      certificateSHA256: credential.certificateSHA256,
      sharedSecret: credential.sharedSecret,
      role: role,
      deviceName: deviceName,
      issuedAtMilliseconds: issuedAtMilliseconds
    )
  }

  private static func validatedDeviceName(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.count <= 80,
      normalized.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AutoNetTransportError.invalidPairingCode
    }
    return normalized
  }

  private static func loadPeerRegistry() throws -> ROBControlStoredPeerRegistry {
    if let cachedPeerRegistry { return cachedPeerRegistry }
    guard let data = try loadData(account: peerRegistryAccount) else {
      let empty = ROBControlStoredPeerRegistry()
      cachedPeerRegistry = empty
      return empty
    }
    guard let registry = try? JSONDecoder().decode(ROBControlStoredPeerRegistry.self, from: data),
      registry.version == ROBControlStoredPeerRegistry.currentVersion
    else { throw AutoNetTransportError.invalidPairingCode }
    var identifiers = Set<UUID>()
    for peer in registry.peers {
      guard identifiers.insert(peer.deviceID).inserted,
        (try? validatedDeviceName(peer.deviceName)) != nil
      else { throw AutoNetTransportError.invalidPairingCode }
      if let credential = peer.credential {
        guard peer.revokedAtMilliseconds == nil,
          credential.isValid,
          credential.controllerID == peer.deviceID,
          credential.role == nil || credential.role == peer.role
        else { throw AutoNetTransportError.invalidPairingCode }
      } else {
        guard peer.revokedAtMilliseconds != nil else {
          throw AutoNetTransportError.invalidPairingCode
        }
      }
    }
    cachedPeerRegistry = registry
    return registry
  }

  private static func storePeerRegistry(_ registry: ROBControlStoredPeerRegistry) throws {
    try storeData(try JSONEncoder().encode(registry), account: peerRegistryAccount)
    cachedPeerRegistry = registry
  }

  private static func currentTimeMilliseconds() -> UInt64 {
    UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
  }

  private static func serverCredential() throws -> ROBControlCredential {
    #if os(macOS)
      return try serverIdentityContext().credential
    #else
      throw AutoNetTransportError.identityUnavailable(
        "Cerebro's server identity is supported only on macOS")
    #endif
  }

  #if os(macOS)
    private static func serverIdentityContext() throws -> ServerIdentityContext {
      try serverIdentityQueue.sync {
        if let cachedServerIdentityContext {
          return cachedServerIdentityContext
        }

        let loadedIdentity = try ROBControlIdentityStore.loadOrCreate()
        let fingerprint = Data(
          SHA256.hash(data: SecCertificateCopyData(loadedIdentity.certificate) as Data))
        let existing = try loadCredential(account: serverProfileAccount)

        let credential: ROBControlCredential
        if let existing, existing.certificateSHA256 == fingerprint {
          credential = existing
        } else {
          let migratedSecret: Data?
          if let oldSecret = try loadData(account: legacySecretAccount),
            oldSecret.count == requiredSecretLength
          {
            migratedSecret = oldSecret
          } else if let environmentSecret = ProcessInfo.processInfo.environment[environmentKey],
            let decoded = Data(base64Encoded: environmentSecret),
            decoded.count == requiredSecretLength
          {
            migratedSecret = decoded
          } else {
            migratedSecret = nil
          }

          credential = ROBControlCredential(
            version: 2,
            robotID: existing?.robotID ?? UUID(),
            controllerID: existing?.controllerID ?? UUID(),
            serviceType: serviceType,
            applicationProtocol: applicationProtocol,
            certificateSHA256: fingerprint,
            sharedSecret: try existing?.sharedSecret ?? migratedSecret
              ?? secureRandomData(count: requiredSecretLength)
          )
          try storeCredential(credential, account: serverProfileAccount)
        }

        let context = ServerIdentityContext(
          loadedIdentity: loadedIdentity,
          credential: credential
        )
        cachedServerIdentityContext = context
        return context
      }
    }
  #endif

  private static func secureRandomData(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return errSecParam }
      return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
    }
    guard status == errSecSuccess else { throw AutoNetTransportError.randomGeneration(status) }
    return data
  }
}

private enum ROBControlDER {
  static func tagged(_ tag: UInt8, _ content: Data) -> Data {
    var result = Data([tag])
    result.append(length(content.count))
    result.append(content)
    return result
  }
  static func sequence(_ elements: [Data]) -> Data {
    tagged(0x30, elements.reduce(into: Data()) { $0.append($1) })
  }
  static func set(_ elements: [Data]) -> Data {
    tagged(0x31, elements.reduce(into: Data()) { $0.append($1) })
  }
  static func explicit(_ number: UInt8, _ content: Data) -> Data { tagged(0xA0 | number, content) }
  static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xFF : 0x00])) }
  static func integer(_ value: Int) -> Data {
    positiveInteger(withUnsafeBytes(of: UInt64(value).bigEndian) { Data($0) })
  }
  static func positiveInteger(_ bytes: Data) -> Data {
    var value = Data(bytes.drop(while: { $0 == 0 }))
    if value.isEmpty { value = Data([0]) }
    if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
    return tagged(0x02, value)
  }
  static func objectIdentifier(_ dotted: String) throws -> Data {
    let arcs = try dotted.split(separator: ".").map { component -> UInt64 in
      guard let value = UInt64(component) else {
        throw AutoNetTransportError.identityUnavailable("invalid OID")
      }
      return value
    }
    guard arcs.count >= 2, arcs[0] <= 2, arcs[0] == 2 || arcs[1] <= 39 else {
      throw AutoNetTransportError.identityUnavailable("invalid OID")
    }
    var body = Data(base128(arcs[0] * 40 + arcs[1]))
    for arc in arcs.dropFirst(2) { body.append(contentsOf: base128(arc)) }
    return tagged(0x06, body)
  }
  static func utf8String(_ string: String) -> Data { tagged(0x0C, Data(string.utf8)) }
  static func generalizedTime(_ date: Date) -> Data {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss'Z'"
    return tagged(0x18, Data(formatter.string(from: date).utf8))
  }
  static func bitString(_ bytes: Data, unusedBits: UInt8 = 0) -> Data {
    var body = Data([unusedBits])
    body.append(bytes)
    return tagged(0x03, body)
  }
  static func octetString(_ bytes: Data) -> Data { tagged(0x04, bytes) }
  private static func length(_ count: Int) -> Data {
    if count < 128 { return Data([UInt8(count)]) }
    var remaining = count
    var bytes: [UInt8] = []
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xFF), at: 0)
      remaining >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }
  private static func base128(_ value: UInt64) -> [UInt8] {
    var remaining = value
    var bytes = [UInt8(remaining & 0x7F)]
    remaining >>= 7
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0x7F), at: 0)
      remaining >>= 7
    }
    if bytes.count > 1 { for index in 0..<(bytes.count - 1) { bytes[index] |= 0x80 } }
    return bytes
  }
}

#if os(macOS)
  private final class ROBControlIdentityStore {
    private static let certificateLabel = "ROB Control QUIC Server Identity v1"
    private static let keyLabel = "ROB Control QUIC P-256 Key v1"
    private static let keyTag = Data("com.orbitusrobotics.robctl.v2.p256.v1".utf8)
    private static let canonicalCertificateService = "com.orbitusrobotics.robctl.v2"
    private static let canonicalCertificateAccount = "cerebro-server-certificate-der-v1"
    private static let maximumCertificateLength = 64 * 1_024
    private static let shared = ROBControlIdentityStore()

    struct LoadedIdentity {
      let identity: SecIdentity
      let certificate: SecCertificate
    }

    private let keychain: SecKeychain?
    private let queue = DispatchQueue(label: "com.orbitusrobotics.robctl.v2.identity-store")
    private var cachedIdentity: LoadedIdentity?

    private init(keychain: SecKeychain? = nil) {
      self.keychain = keychain
    }

    static func loadOrCreate() throws -> LoadedIdentity {
      try shared.loadOrCreateIdentity()
    }

    private func loadOrCreateIdentity() throws -> LoadedIdentity {
      try queue.sync {
        if let cachedIdentity {
          return cachedIdentity
        }

        let certificateData: Data
        if let storedCertificateData = try loadCanonicalCertificateData() {
          certificateData = storedCertificateData
        } else {
          let privateKey = try loadOrCreatePrivateKey()
          let generatedCertificateData = try makeSelfSignedCertificate(privateKey: privateKey)
          certificateData = try storeCanonicalCertificateDataIfAbsent(generatedCertificateData)
        }

        let certificate = try makeCertificate(from: certificateData)
        try installCertificateIfNeeded(certificate)
        let identity = try makeIdentity(certificate: certificate)
        let loadedIdentity = LoadedIdentity(identity: identity, certificate: certificate)
        cachedIdentity = loadedIdentity
        return loadedIdentity
      }
    }

    private func loadCanonicalCertificateData() throws -> Data? {
      var query = lookupQuery(canonicalCertificateQuery())
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne

      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound {
        return nil
      }
      guard status == errSecSuccess, let data = item as? Data else {
        throw AutoNetTransportError.keychain(status)
      }
      guard !data.isEmpty, data.count <= Self.maximumCertificateLength,
        SecCertificateCreateWithData(nil, data as CFData) != nil
      else {
        throw AutoNetTransportError.identityUnavailable(
          "the canonical certificate stored in Keychain is invalid")
      }
      return data
    }

    private func storeCanonicalCertificateDataIfAbsent(_ candidate: Data) throws -> Data {
      guard !candidate.isEmpty, candidate.count <= Self.maximumCertificateLength else {
        throw AutoNetTransportError.identityUnavailable(
          "the generated certificate has an invalid size")
      }

      var addQuery = insertionQuery(canonicalCertificateQuery())
      addQuery[kSecValueData as String] = candidate
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(addQuery as CFDictionary, nil)
      if status == errSecSuccess {
        return candidate
      }
      guard status == errSecDuplicateItem,
        let storedCertificateData = try loadCanonicalCertificateData()
      else {
        throw AutoNetTransportError.keychain(status)
      }
      return storedCertificateData
    }

    private func canonicalCertificateQuery() -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Self.canonicalCertificateService,
        kSecAttrAccount as String: Self.canonicalCertificateAccount,
      ]
    }

    private func makeCertificate(from data: Data) throws -> SecCertificate {
      guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
        throw AutoNetTransportError.identityUnavailable(
          "the canonical X.509 certificate could not be decoded")
      }
      return certificate
    }

    private func installCertificateIfNeeded(_ certificate: SecCertificate) throws {
      let status = SecItemAdd(
        insertionQuery([
          kSecClass as String: kSecClassCertificate,
          kSecAttrLabel as String: Self.certificateLabel,
          kSecValueRef as String: certificate,
        ]) as CFDictionary,
        nil
      )
      guard status == errSecSuccess || status == errSecDuplicateItem else {
        throw AutoNetTransportError.keychain(status)
      }
    }

    private func makeIdentity(certificate: SecCertificate) throws -> SecIdentity {
      var identity: SecIdentity?
      let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
      guard status == errSecSuccess, let identity else {
        throw AutoNetTransportError.identityUnavailable(
          "private key missing for the canonical certificate (OSStatus \(status))")
      }
      return identity
    }

    private func loadPrivateKey() throws -> SecKey? {
      let query = lookupQuery([
        kSecClass as String: kSecClassKey,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrApplicationTag as String: Self.keyTag, kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ])
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let key = item as! SecKey? else {
        throw AutoNetTransportError.keychain(status)
      }
      return key
    }

    private func loadOrCreatePrivateKey() throws -> SecKey {
      if let existing = try loadPrivateKey() {
        return existing
      }
      do {
        return try createPrivateKey()
      } catch {
        // A concurrent cold-start process may have installed the tagged key
        // between our lookup and creation attempt. Reuse that winner.
        if let winner = try loadPrivateKey() {
          return winner
        }
        throw error
      }
    }

    private func createPrivateKey() throws -> SecKey {
      let attributes = insertionQuery([
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecPrivateKeyAttrs as String: [
          kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Self.keyTag,
          kSecAttrLabel as String: Self.keyLabel,
        ],
      ])
      var error: Unmanaged<CFError>?
      guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw AutoNetTransportError.identityUnavailable(
          error?.takeRetainedValue().localizedDescription ?? "P-256 key generation failed")
      }
      return key
    }

    private func lookupQuery(_ values: [String: Any]) -> [String: Any] {
      guard let keychain else {
        return values
      }
      var scoped = values
      scoped[kSecMatchSearchList as String] = [keychain]
      return scoped
    }

    private func insertionQuery(_ values: [String: Any]) -> [String: Any] {
      guard let keychain else {
        return values
      }
      var scoped = values
      scoped[kSecUseKeychain as String] = keychain
      return scoped
    }

    private func makeSelfSignedCertificate(privateKey: SecKey) throws -> Data {
      guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
        throw AutoNetTransportError.identityUnavailable("public key unavailable")
      }
      var exportError: Unmanaged<CFError>?
      guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data?,
        publicBytes.count == 65, publicBytes.first == 0x04
      else {
        throw AutoNetTransportError.identityUnavailable(
          exportError?.takeRetainedValue().localizedDescription ?? "P-256 public key export failed")
      }
      let signatureAlgorithm = ROBControlDER.sequence([
        try ROBControlDER.objectIdentifier("1.2.840.10045.4.3.2")
      ])
      let name = ROBControlDER.sequence([
        ROBControlDER.set([
          ROBControlDER.sequence([
            try ROBControlDER.objectIdentifier("2.5.4.3"),
            ROBControlDER.utf8String(Self.certificateLabel),
          ])
        ])
      ])
      let publicKeyInfo = ROBControlDER.sequence([
        ROBControlDER.sequence([
          try ROBControlDER.objectIdentifier("1.2.840.10045.2.1"),
          try ROBControlDER.objectIdentifier("1.2.840.10045.3.1.7"),
        ]), ROBControlDER.bitString(publicBytes),
      ])
      var serial = Data(count: 16)
      let randomStatus = serial.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
      }
      guard randomStatus == errSecSuccess else {
        throw AutoNetTransportError.randomGeneration(randomStatus)
      }
      let now = Date()
      let validity = ROBControlDER.sequence([
        ROBControlDER.generalizedTime(now.addingTimeInterval(-300)),
        ROBControlDER.generalizedTime(now.addingTimeInterval(10 * 365 * 24 * 60 * 60)),
      ])
      let extensions = ROBControlDER.sequence([
        ROBControlDER.sequence([
          try ROBControlDER.objectIdentifier("2.5.29.19"), ROBControlDER.boolean(true),
          ROBControlDER.octetString(ROBControlDER.sequence([])),
        ]),
        ROBControlDER.sequence([
          try ROBControlDER.objectIdentifier("2.5.29.15"), ROBControlDER.boolean(true),
          ROBControlDER.octetString(ROBControlDER.bitString(Data([0x80]), unusedBits: 7)),
        ]),
        ROBControlDER.sequence([
          try ROBControlDER.objectIdentifier("2.5.29.37"),
          ROBControlDER.octetString(
            ROBControlDER.sequence([try ROBControlDER.objectIdentifier("1.3.6.1.5.5.7.3.1")])),
        ]),
      ])
      let tbs = ROBControlDER.sequence([
        ROBControlDER.explicit(0, ROBControlDER.integer(2)), ROBControlDER.positiveInteger(serial),
        signatureAlgorithm, name, validity, name, publicKeyInfo,
        ROBControlDER.explicit(3, extensions),
      ])
      var signError: Unmanaged<CFError>?
      guard
        let signature = SecKeyCreateSignature(
          privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &signError) as Data?
      else {
        throw AutoNetTransportError.identityUnavailable(
          signError?.takeRetainedValue().localizedDescription ?? "certificate signing failed")
      }
      return ROBControlDER.sequence([tbs, signatureAlgorithm, ROBControlDER.bitString(signature)])
    }

    #if ROB_CONTROL_IDENTITY_FIXTURE
      fileprivate static func runPersistenceFixture(
        keychain: SecKeychain,
        iterations: Int
      ) throws -> (fingerprints: [Data], certificateCount: Int) {
        guard iterations > 1 else {
          throw AutoNetTransportError.identityUnavailable(
            "the identity persistence fixture requires multiple loads")
        }

        var keyError: Unmanaged<CFError>?
        guard
          let signingKey = SecKeyCreateRandomKey(
            [
              kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
              kSecAttrKeySizeInBits as String: 256,
            ] as CFDictionary,
            &keyError
          )
        else {
          throw AutoNetTransportError.identityUnavailable(
            keyError?.takeRetainedValue().localizedDescription
              ?? "the fixture signing key could not be created")
        }

        var fingerprints: [Data] = []
        for _ in 0..<iterations {
          let store = ROBControlIdentityStore(keychain: keychain)
          let certificate = try store.loadOrCreateFixtureCertificate(signingKey: signingKey)
          fingerprints.append(
            Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)))
        }

        let counter = ROBControlIdentityStore(keychain: keychain)
        return (fingerprints, try counter.certificateCount())
      }

      private func loadOrCreateFixtureCertificate(signingKey: SecKey) throws -> SecCertificate {
        try queue.sync {
          let certificateData: Data
          if let storedCertificateData = try loadCanonicalCertificateData() {
            certificateData = storedCertificateData
          } else {
            let generatedCertificateData = try makeSelfSignedCertificate(privateKey: signingKey)
            certificateData = try storeCanonicalCertificateDataIfAbsent(generatedCertificateData)
          }
          let certificate = try makeCertificate(from: certificateData)
          try installCertificateIfNeeded(certificate)
          return certificate
        }
      }

      private func certificateCount() throws -> Int {
        let query = lookupQuery([
          kSecClass as String: kSecClassCertificate,
          kSecReturnRef as String: true,
          kSecMatchLimit as String: kSecMatchLimitAll,
        ])
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
          return 0
        }
        guard status == errSecSuccess else {
          throw AutoNetTransportError.keychain(status)
        }
        guard let certificates = item as? [SecCertificate] else {
          throw AutoNetTransportError.identityUnavailable(
            "the fixture Keychain returned an unexpected certificate result")
        }
        return certificates.count
      }
    #endif
  }
#endif

struct ROBControlAuthChallenge {
  static let encodedSize = 65
  let sessionID: Data
  let serverNonce: Data
  let robotID: UUID
  var encoded: Data {
    var data = Data([1])
    data.append(sessionID)
    data.append(serverNonce)
    data.append(robotID.robControlBytes)
    return data
  }
  init(sessionID: Data, serverNonce: Data, robotID: UUID) {
    self.sessionID = sessionID
    self.serverNonce = serverNonce
    self.robotID = robotID
  }
  init?(_ data: Data) {
    guard data.count == Self.encodedSize, data[0] == 1,
      let robotID = UUID(robControlBytes: data.subdata(in: 49..<65))
    else { return nil }
    self.sessionID = data.subdata(in: 1..<17)
    self.serverNonce = data.subdata(in: 17..<49)
    self.robotID = robotID
  }
}

struct ROBControlAuthProof {
  static let encodedSize = 97
  let sessionID: Data
  let controllerID: UUID
  let clientNonce: Data
  let mac: Data
  var encoded: Data {
    var data = Data([1])
    data.append(sessionID)
    data.append(controllerID.robControlBytes)
    data.append(clientNonce)
    data.append(mac)
    return data
  }
  init(sessionID: Data, controllerID: UUID, clientNonce: Data, mac: Data) {
    self.sessionID = sessionID
    self.controllerID = controllerID
    self.clientNonce = clientNonce
    self.mac = mac
  }
  init?(_ data: Data) {
    guard data.count == Self.encodedSize, data[0] == 1,
      let controllerID = UUID(robControlBytes: data.subdata(in: 17..<33))
    else { return nil }
    self.sessionID = data.subdata(in: 1..<17)
    self.controllerID = controllerID
    self.clientNonce = data.subdata(in: 33..<65)
    self.mac = data.subdata(in: 65..<97)
  }
}

struct ROBControlAuthAccepted {
  static let encodedSize = 65
  let sessionID: Data
  let controllerID: UUID
  let mac: Data
  var encoded: Data {
    var data = Data([1])
    data.append(sessionID)
    data.append(controllerID.robControlBytes)
    data.append(mac)
    return data
  }
  init(sessionID: Data, controllerID: UUID, mac: Data) {
    self.sessionID = sessionID
    self.controllerID = controllerID
    self.mac = mac
  }
  init?(_ data: Data) {
    guard data.count == Self.encodedSize, data[0] == 1,
      let controllerID = UUID(robControlBytes: data.subdata(in: 17..<33))
    else { return nil }
    self.sessionID = data.subdata(in: 1..<17)
    self.controllerID = controllerID
    self.mac = data.subdata(in: 33..<65)
  }
}

enum ROBControlAuthenticator {
  private static let transcriptDomain = Data("robctl/2\0".utf8)
  private static let clientDomain = Data("ROBCTL-AUTH-V1/CLIENT-PROOF\0".utf8)
  private static let serverDomain = Data("ROBCTL-AUTH-V1/SERVER-ACCEPTED\0".utf8)

  static func makeChallenge(robotID: UUID) throws -> ROBControlAuthChallenge {
    ROBControlAuthChallenge(
      sessionID: try random(count: 16), serverNonce: try random(count: 32), robotID: robotID)
  }
  static func makeProof(challenge: ROBControlAuthChallenge, credential: ROBControlCredential) throws
    -> ROBControlAuthProof
  {
    let nonce = try random(count: 32)
    let transcript = makeTranscript(
      challenge: challenge, controllerID: credential.controllerID, clientNonce: nonce)
    return ROBControlAuthProof(
      sessionID: challenge.sessionID, controllerID: credential.controllerID, clientNonce: nonce,
      mac: hmac(domain: clientDomain, transcript: transcript, secret: credential.sharedSecret))
  }
  static func validate(
    _ proof: ROBControlAuthProof, challenge: ROBControlAuthChallenge,
    credential: ROBControlCredential
  ) -> Bool {
    guard proof.sessionID == challenge.sessionID, proof.controllerID == credential.controllerID,
      challenge.robotID == credential.robotID
    else { return false }
    var input = clientDomain
    input.append(
      makeTranscript(
        challenge: challenge, controllerID: proof.controllerID, clientNonce: proof.clientNonce))
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof.mac, authenticating: input, using: SymmetricKey(data: credential.sharedSecret))
  }
  static func accepted(
    for proof: ROBControlAuthProof, challenge: ROBControlAuthChallenge,
    credential: ROBControlCredential
  ) -> ROBControlAuthAccepted {
    let transcript = makeTranscript(
      challenge: challenge, controllerID: proof.controllerID, clientNonce: proof.clientNonce)
    var input = serverDomain
    input.append(transcript)
    input.append(proof.mac)
    let mac = Data(
      HMAC<SHA256>.authenticationCode(
        for: input, using: SymmetricKey(data: credential.sharedSecret)))
    return ROBControlAuthAccepted(
      sessionID: proof.sessionID, controllerID: proof.controllerID, mac: mac)
  }
  static func validate(
    _ accepted: ROBControlAuthAccepted, proof: ROBControlAuthProof,
    challenge: ROBControlAuthChallenge, credential: ROBControlCredential
  ) -> Bool {
    guard accepted.sessionID == challenge.sessionID,
      accepted.controllerID == credential.controllerID
    else { return false }
    var input = serverDomain
    input.append(
      makeTranscript(
        challenge: challenge, controllerID: proof.controllerID, clientNonce: proof.clientNonce))
    input.append(proof.mac)
    return HMAC<SHA256>.isValidAuthenticationCode(
      accepted.mac, authenticating: input, using: SymmetricKey(data: credential.sharedSecret))
  }
  private static func makeTranscript(
    challenge: ROBControlAuthChallenge, controllerID: UUID, clientNonce: Data
  ) -> Data {
    var data = transcriptDomain
    data.append(challenge.encoded)
    data.append(controllerID.robControlBytes)
    data.append(clientNonce)
    return data
  }
  private static func hmac(domain: Data, transcript: Data, secret: Data) -> Data {
    var input = domain
    input.append(transcript)
    return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret)))
  }
  private static func random(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw AutoNetTransportError.randomGeneration(status) }
    return data
  }
}

extension UUID {
  var robControlBytes: Data {
    var value = uuid
    return withUnsafeBytes(of: &value) { Data($0) }
  }
  init?(robControlBytes data: Data) {
    guard data.count == 16 else { return nil }
    var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
    self.init(uuid: value)
  }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
enum AutoNetTransportMode {
  case v2
  case legacy

  init(service: String) throws {
    switch service {
    case ROBControlPairing.serviceType:
      self = .v2
    case ROBControlPairing.legacyServiceType:
      guard ROBControlPairing.legacyTransportIsEnabled() else {
        throw AutoNetTransportError.legacyDisabled
      }
      self = .legacy
    default:
      throw AutoNetTransportError.unsupportedService(service)
    }
  }

  var serviceType: String {
    switch self {
    case .v2: return ROBControlPairing.serviceType
    case .legacy: return ROBControlPairing.legacyServiceType
    }
  }

  var framerDefinition: NWProtocolFramer.Definition {
    switch self {
    case .v2: return ROBV2ControlFramer.definition
    case .legacy: return LegacyAutoNetFramer.definition
    }
  }

  func makeServerParameters() throws -> NWParameters {
    switch self {
    case .v2: return try ROBControlPairing.makeV2ServerParameters()
    case .legacy: return try ROBControlPairing.makeLegacyUDPParameters()
    }
  }

  func makeClientParameters() throws -> NWParameters {
    switch self {
    case .v2: return try ROBControlPairing.makeV2ClientParameters()
    case .legacy: return try ROBControlPairing.makeLegacyUDPParameters()
    }
  }

  func makeMessage(type: DataMessageType) -> NWProtocolFramer.Message {
    let message = NWProtocolFramer.Message(definition: framerDefinition)
    message.autoNetMessageType = type
    return message
  }

  func messageType(from context: NWConnection.ContentContext?) -> DataMessageType? {
    guard
      let message = context?.protocolMetadata(definition: framerDefinition)
        as? NWProtocolFramer.Message
    else {
      return nil
    }
    return message.autoNetMessageType
  }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
final class ROBV2ControlFramer: NWProtocolFramerImplementation {
  static let definition = NWProtocolFramer.Definition(implementation: ROBV2ControlFramer.self)
  static var label: String { "ROBControlV2" }

  private var nextOutputSequence: UInt64 = 1
  private var lastInputSequence: UInt64 = 0

  required init(framer: NWProtocolFramer.Instance) {}
  func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
  func wakeup(framer: NWProtocolFramer.Instance) {}
  func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
  func cleanup(framer: NWProtocolFramer.Instance) {}

  func handleOutput(
    framer: NWProtocolFramer.Instance,
    message: NWProtocolFramer.Message,
    messageLength: Int,
    isComplete: Bool
  ) {
    guard messageLength <= ROBV2FrameHeader.maximumPayloadLength,
      messageLength >= 0,
      message.autoNetMessageType != .invalid,
      nextOutputSequence != UInt64.max
    else {
      framer.markFailed(error: NWError.posix(.EMSGSIZE))
      return
    }

    let header = ROBV2FrameHeader(
      type: message.autoNetMessageType,
      payloadLength: UInt32(messageLength),
      sequence: nextOutputSequence,
      messageID: UUID()
    )
    nextOutputSequence += 1
    framer.writeOutput(data: header.encodedData)
    do {
      try framer.writeOutputNoCopy(length: messageLength)
    } catch {
      framer.markFailed(error: NWError.posix(.EIO))
    }
  }

  func handleInput(framer: NWProtocolFramer.Instance) -> Int {
    while true {
      var parsedHeader: ROBV2FrameHeader?
      var malformed = false
      let headerSize = ROBV2FrameHeader.encodedSize
      let parsed = framer.parseInput(
        minimumIncompleteLength: headerSize,
        maximumLength: headerSize
      ) { buffer, _ in
        guard let buffer = buffer, buffer.count >= headerSize else { return 0 }
        parsedHeader = ROBV2FrameHeader(buffer)
        malformed = parsedHeader == nil
        return headerSize
      }

      guard parsed else { return headerSize }
      guard !malformed,
        let header = parsedHeader,
        header.sequence > lastInputSequence
      else {
        framer.markFailed(error: NWError.posix(.EPROTO))
        return 0
      }
      lastInputSequence = header.sequence

      let message = NWProtocolFramer.Message(definition: Self.definition)
      message.autoNetMessageType = header.type
      if !framer.deliverInputNoCopy(
        length: Int(header.payloadLength),
        message: message,
        isComplete: true
      ) {
        return 0
      }
    }
  }
}

private struct ROBV2FrameHeader {
  static let magic: UInt32 = 0x5243_544C  // "RCTL"
  static let version: UInt8 = 2
  static let encodedSize = 40
  static let maximumPayloadLength = 4 * 1024 * 1024

  let type: DataMessageType
  let payloadLength: UInt32
  let sequence: UInt64
  let messageID: [UInt8]

  init(type: DataMessageType, payloadLength: UInt32, sequence: UInt64, messageID: UUID) {
    self.type = type
    self.payloadLength = payloadLength
    self.sequence = sequence
    var uuid = messageID.uuid
    self.messageID = withUnsafeBytes(of: &uuid) { Array($0) }
  }

  init?(_ buffer: UnsafeMutableRawBufferPointer) {
    guard buffer.count >= Self.encodedSize,
      Self.readUInt32(buffer, offset: 0) == Self.magic,
      buffer[4] == Self.version,
      Int(buffer[5]) == Self.encodedSize,
      Self.readUInt16(buffer, offset: 8) == 0,
      Self.readUInt16(buffer, offset: 10) == 0,
      let type = DataMessageType(rawValue: UInt32(Self.readUInt16(buffer, offset: 6))),
      type != .invalid
    else {
      return nil
    }
    let length = Self.readUInt32(buffer, offset: 12)
    guard length <= UInt32(Self.maximumPayloadLength) else { return nil }

    self.type = type
    self.payloadLength = length
    self.sequence = Self.readUInt64(buffer, offset: 16)
    self.messageID = Array(UnsafeRawBufferPointer(rebasing: buffer[24..<40]))
  }

  var encodedData: Data {
    var data = Data(capacity: Self.encodedSize)
    data.appendBigEndian(Self.magic)
    data.append(Self.version)
    data.append(UInt8(Self.encodedSize))
    data.appendBigEndian(UInt16(type.rawValue))
    data.appendBigEndian(UInt16(0))  // flags
    data.appendBigEndian(UInt16(0))  // channel
    data.appendBigEndian(payloadLength)
    data.appendBigEndian(sequence)
    data.append(contentsOf: messageID)
    return data
  }

  private static func readUInt16(_ buffer: UnsafeMutableRawBufferPointer, offset: Int) -> UInt16 {
    return (UInt16(buffer[offset]) << 8) | UInt16(buffer[offset + 1])
  }

  private static func readUInt32(_ buffer: UnsafeMutableRawBufferPointer, offset: Int) -> UInt32 {
    return (UInt32(buffer[offset]) << 24) | (UInt32(buffer[offset + 1]) << 16)
      | (UInt32(buffer[offset + 2]) << 8) | UInt32(buffer[offset + 3])
  }

  private static func readUInt64(_ buffer: UnsafeMutableRawBufferPointer, offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in offset..<(offset + 8) {
      value = (value << 8) | UInt64(buffer[index])
    }
    return value
  }
}

extension Data {
  fileprivate mutating func appendBigEndian(_ value: UInt16) {
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

  fileprivate mutating func appendBigEndian(_ value: UInt32) {
    append(UInt8((value >> 24) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8(value & 0xff))
  }

  fileprivate mutating func appendBigEndian(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      append(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class LegacyAutoNetFramer: NWProtocolFramerImplementation {
  static let definition = NWProtocolFramer.Definition(implementation: LegacyAutoNetFramer.self)
  static var label: String { "LegacyAutoNetPlaintextUDP" }

  required init(framer: NWProtocolFramer.Instance) {}
  func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
  func wakeup(framer: NWProtocolFramer.Instance) {}
  func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
  func cleanup(framer: NWProtocolFramer.Instance) {}

  func handleOutput(
    framer: NWProtocolFramer.Instance,
    message: NWProtocolFramer.Message,
    messageLength: Int,
    isComplete: Bool
  ) {
    guard messageLength >= 0,
      messageLength <= LegacyAutoNetHeader.maximumPayloadLength,
      message.autoNetMessageType != .invalid
    else {
      framer.markFailed(error: NWError.posix(.EMSGSIZE))
      return
    }
    let header = LegacyAutoNetHeader(
      type: message.autoNetMessageType.rawValue,
      length: UInt32(messageLength)
    )
    framer.writeOutput(data: header.encodedData)
    do {
      try framer.writeOutputNoCopy(length: messageLength)
    } catch {
      framer.markFailed(error: NWError.posix(.EIO))
    }
  }

  func handleInput(framer: NWProtocolFramer.Instance) -> Int {
    while true {
      var parsedHeader: LegacyAutoNetHeader?
      let headerSize = LegacyAutoNetHeader.encodedSize
      let parsed = framer.parseInput(
        minimumIncompleteLength: headerSize,
        maximumLength: headerSize
      ) { buffer, _ in
        guard let buffer = buffer, buffer.count >= headerSize else { return 0 }
        parsedHeader = LegacyAutoNetHeader(buffer)
        return headerSize
      }
      guard parsed else { return headerSize }
      guard let header = parsedHeader,
        header.length <= UInt32(LegacyAutoNetHeader.maximumPayloadLength),
        let type = DataMessageType(rawValue: header.type),
        type != .invalid
      else {
        framer.markFailed(error: NWError.posix(.EPROTO))
        return 0
      }

      let message = NWProtocolFramer.Message(definition: Self.definition)
      message.autoNetMessageType = type
      if !framer.deliverInputNoCopy(length: Int(header.length), message: message, isComplete: true)
      {
        return 0
      }
    }
  }
}

/// This is the only host-endian wire structure. It deliberately preserves the
/// original bug-compatible layout inside the legacy adapter.
private struct LegacyAutoNetHeader {
  static let encodedSize = MemoryLayout<UInt32>.size * 2
  static let maximumPayloadLength = 4 * 1024 * 1024

  let type: UInt32
  let length: UInt32

  init(type: UInt32, length: UInt32) {
    self.type = type
    self.length = length
  }

  init(_ buffer: UnsafeMutableRawBufferPointer) {
    var type: UInt32 = 0
    var length: UInt32 = 0
    withUnsafeMutableBytes(of: &type) { destination in
      destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: buffer[0..<4]))
    }
    withUnsafeMutableBytes(of: &length) { destination in
      destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: buffer[4..<8]))
    }
    self.type = type
    self.length = length
  }

  var encodedData: Data {
    var type = self.type
    var length = self.length
    var data = Data(bytes: &type, count: MemoryLayout<UInt32>.size)
    data.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
    return data
  }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NWProtocolFramer.Message {
  fileprivate var autoNetMessageType: DataMessageType {
    get { self["ROBControlMessageType"] as? DataMessageType ?? .invalid }
    set { self["ROBControlMessageType"] = newValue }
  }
}
