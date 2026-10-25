import Foundation
import CryptoKit
import Darwin

/// The operator decides on the controller; Cerebro owns execution and its
/// measured result. No desktop alert, persisted grant, or per-waypoint prompt.
@objcMembers final class ROBControllerArmApproval: NSObject {
    static let shared = ROBControllerArmApproval()
    static let supervisedRouteNotice = "Supervised taught route: by approving, confirm both arms are physically hanging at zero for a new session, the route is clear and grippers are empty for a greeting. Watch the arms even if camera visibility is poor; keep Stop + hold ready. Gripper calibration and closing still require a camera check."
    static let supervisedGreetingName = "Supervised greet: confirm hanging/clear route/empty jaws; watch despite poor view; neck scan, arms front, wave"
    private(set) var status = "Arm operations need spoken or controller authorization"
    var isPending: Bool { pending != nil }
    var armSessionActive: Bool { armSession.map(sessionIsFresh) ?? false }
    var armSessionDetail: String {
        guard armSessionActive, let session = armSession else { return "No active arm rehearsal session" }
        let end = DateFormatter.localizedString(from: session.expires, dateStyle: .none, timeStyle: .short)
        return "Left-arm session authorized until \(end). Covered routines do not ask again. Stop ends the session."
    }
    var announceApproval: ((String) -> Void)?
    @nonobjc var send: ((ROBRobotActionMessage, UUID, UUID) -> Bool)?
    @nonobjc var sessionIsActive: (UUID, UUID) -> Bool = {
        ROBControlLiveSessionRegistry.isActiveOperator(controllerID: $0, sessionID: $1)
    }
    @nonobjc var now: () -> Date = Date.init

    // This is a separate, explicitly imported local-user approval. No ordinary
    // chat, model tool, microphone candidate or controller packet enters it.
    private let localSessionID = UUID()
    var localRecyclingApprovalSessionID: String { localSessionID.uuidString }
    @nonobjc var localRecyclingApprovalAuditDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cerebro/LocalSessionApprovals", isDirectory: true)

    private struct LocalRecyclingScope: Equatable {
        let command: String
        let arm: String
        let summary: String
        let contextIdentity: String
        let permitsUnmeasuredVisualCalibrationTrial: Bool
        let nominalEmptyCommissioningStepEnabled: Bool
        let oneDegreeEmptyCalibrationStepEnabled: Bool
        var object: [String: Any] {
            ["command": command, "arm": arm, "canCount": 4, "summary": summary,
             "summarySHA256": ROBControllerArmApproval.localHash(Data(summary.utf8)),
             "contextIdentity": contextIdentity, "targetObject": "empty_coke_can",
             "destination": "orange_bucket", "bothArmsStationaryHolds": true,
             "treads": false, "torso": false, "manualGestures": false,
             "permitsUnmeasuredVisualCalibrationTrial": permitsUnmeasuredVisualCalibrationTrial,
             "nominalEmptyCommissioningStepEnabled": nominalEmptyCommissioningStepEnabled,
             "oneDegreeEmptyCalibrationStepEnabled": oneDegreeEmptyCalibrationStepEnabled]
        }
    }
    private struct LocalRecyclingApproval {
        let receiptID: UUID
        let receiptSHA256: String
        let scope: LocalRecyclingScope
        let beginBefore: Date
        let contextIdentity: () -> String?
        var activePendingID: String?
    }
    private struct LocalReceipt: Decodable {
        let schemaVersion: Int
        let kind: String
        let receiptID: UUID
        let appSessionID: UUID
        let issuedAtMilliseconds: Double
        let expiresAtMilliseconds: Double
        let source: String
        let sourceMessage: String
        let sourceMessageSHA256: String
        let additionalUserInstruction: String?
        let additionalUserInstructionSHA256: String?
    }
    private var localRecyclingApproval: LocalRecyclingApproval?
    private static let localApprovalBeginLimit: TimeInterval = 12 * 60 * 60

    var pendingLocalRecyclingApprovalScope: NSDictionary? {
        guard let p = pending, let scope = p.localRecyclingScope, p.started == nil else { return nil }
        var value = scope.object
        value["appSessionID"] = localSessionID.uuidString
        value["pendingID"] = p.id
        return value as NSDictionary
    }

    /// An invalid-by-default template for the dedicated local file-import UI.
    /// The private file supplies the user's actual source text and its hashes.
    var localRecyclingReceiptTemplate: NSDictionary? {
        guard let p = pending, p.started == nil, let scope = p.localRecyclingScope else { return nil }
        let issued = now().timeIntervalSince1970 * 1000
        return ["schemaVersion": 1, "kind": "local_user_session_recycling_approval",
            "receiptID": UUID().uuidString, "appSessionID": localSessionID.uuidString,
            "issuedAtMilliseconds": issued, "expiresAtMilliseconds": issued + Self.localApprovalBeginLimit * 1000,
            "source": "explicit_user_session_instruction", "sourceMessage": "", "sourceMessageSHA256": "",
            "additionalUserInstruction": NSNull(), "additionalUserInstructionSHA256": NSNull(),
            "scope": scope.object]
    }

    /// Dedicated Testing Sandbox callers only. A typed four-can request does
    /// not create a grant; its exact immutable scope must match a local receipt.
    @nonobjc func requestRecyclingWorkspaceTask(command: String, arm: String, canCount: Int,
        summary: String, contextIdentity: @escaping () -> String?, receiptOnly: Bool,
        permitsUnmeasuredVisualCalibrationTrial: Bool = false,
        nominalEmptyCommissioningStepEnabled: Bool = false,
        oneDegreeEmptyCalibrationStepEnabled: Bool = false,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard canCount == 4, ["left", "right"].contains(arm), command == arm + "_recycle_cans",
              !nominalEmptyCommissioningStepEnabled || (receiptOnly && permitsUnmeasuredVisualCalibrationTrial),
              !oneDegreeEmptyCalibrationStepEnabled || (arm == "right" && receiptOnly && permitsUnmeasuredVisualCalibrationTrial),
              !(nominalEmptyCommissioningStepEnabled && oneDegreeEmptyCalibrationStepEnabled),
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.count <= 2048,
              let identity = contextIdentity(), !identity.isEmpty, identity.utf8.count <= 8192 else {
            completion(["status": "rejected", "detail": "A local session approval requires the exact four-can recycling task and a current camera/body/arm context."])
            return
        }
        let scope = LocalRecyclingScope(command: command, arm: arm, summary: summary, contextIdentity: identity,
            permitsUnmeasuredVisualCalibrationTrial: permitsUnmeasuredVisualCalibrationTrial,
            nominalEmptyCommissioningStepEnabled: nominalEmptyCommissioningStepEnabled,
            oneDegreeEmptyCalibrationStepEnabled: oneDegreeEmptyCalibrationStepEnabled)
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": arm == "right" ? "both" : "left", "summary": summary],
            summary: summary, executionLimit: 600, localRecyclingScope: scope,
            localContextIdentity: contextIdentity, receiptOnly: receiptOnly,
            execute: execute, cancel: cancel, completion: completion)
    }

    /// Local OS file selection is the only import lane. There is deliberately
    /// no equivalent method taking model/controller/chat text or a dictionary.
    @nonobjc func importLocalRecyclingSessionApproval(fromReceiptURL url: URL) throws {
        precondition(Thread.isMainThread)
        guard let p = pending, p.started == nil, let scope = p.localRecyclingScope,
              let context = p.localContextIdentity, context() == scope.contextIdentity else {
            throw localApprovalError("Prepare the exact recycling job in Testing Sandbox with its current context before importing its receipt.")
        }
        let data = try readPrivateLocalReceipt(url)
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys: Set<String> = ["schemaVersion", "kind", "receiptID", "appSessionID", "issuedAtMilliseconds",
            "expiresAtMilliseconds", "source", "sourceMessage", "sourceMessageSHA256", "additionalUserInstruction", "additionalUserInstructionSHA256", "scope"]
        guard let top, Set(top.keys) == keys, let suppliedScope = top["scope"] as? [String: Any],
              try localCanonical(suppliedScope) == localCanonical(scope.object) else {
            throw localApprovalError("The receipt does not match the immutable command, count, arm, summary and context.")
        }
        let receipt = try JSONDecoder().decode(LocalReceipt.self, from: data)
        let issued = Date(timeIntervalSince1970: receipt.issuedAtMilliseconds / 1000)
        let expires = Date(timeIntervalSince1970: receipt.expiresAtMilliseconds / 1000)
        guard receipt.schemaVersion == 1, receipt.kind == "local_user_session_recycling_approval",
              receipt.appSessionID == localSessionID, receipt.source == "explicit_user_session_instruction",
              !receipt.sourceMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              receipt.sourceMessage.utf8.count <= 8192,
              receipt.sourceMessageSHA256 == Self.localHash(Data(receipt.sourceMessage.utf8)),
              receipt.issuedAtMilliseconds.isFinite, receipt.expiresAtMilliseconds.isFinite,
              receipt.issuedAtMilliseconds <= now().timeIntervalSince1970 * 1000,
              expires > now(), expires > issued,
              receipt.expiresAtMilliseconds - receipt.issuedAtMilliseconds <= Self.localApprovalBeginLimit * 1000,
              now().timeIntervalSince(issued) <= Self.localApprovalBeginLimit else {
            throw localApprovalError("The local user approval is expired, belongs to another app session, or has invalid source evidence.")
        }
        if scope.permitsUnmeasuredVisualCalibrationTrial {
            guard let additional = receipt.additionalUserInstruction,
                  !additional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, additional.utf8.count <= 8192,
                  receipt.additionalUserInstructionSHA256 == Self.localHash(Data(additional.utf8)) else {
                throw localApprovalError("The explicitly requested visual-calibration trial needs its additional exact user instruction in the receipt.")
            }
        } else if receipt.additionalUserInstruction != nil || receipt.additionalUserInstructionSHA256 != nil {
            throw localApprovalError("The receipt adds an instruction outside this prepared job.")
        }
        // Exclusive, persistent import record before any grant. It is a replay
        // tombstone/audit, never a persisted grant to reload after a crash.
        var audit = top
        audit["receiptSHA256"] = Self.localHash(data); audit["sourceReceiptPath"] = url.path
        audit["importedAtMilliseconds"] = now().timeIntervalSince1970 * 1000
        audit["localOSUserID"] = Int(getuid()); audit["pendingID"] = p.id
        audit["event"] = "imported_once_no_persisted_motion_grant"
        try writeLocalApprovalAudit(audit, name: "receipt-" + receipt.receiptID.uuidString + ".json")
        localRecyclingApproval = LocalRecyclingApproval(receiptID: receipt.receiptID,
            receiptSHA256: Self.localHash(data), scope: scope, beginBefore: expires,
            contextIdentity: context, activePendingID: p.id)
        pending?.localSessionApprovalID = receipt.receiptID
        startTimer(); beginAcceptedOperation()
    }

    /// This exposes permission only. The planner must separately admit an
    /// explicitly unmeasured trial; this broker never certifies a transform.
    @nonobjc func authorizesLocalRecyclingVisualCalibrationTrial(summary: String, arm: String) -> Bool {
        guard let p = pending, let scope = p.localRecyclingScope,
              scope.arm == arm, scope.summary == summary, scope.permitsUnmeasuredVisualCalibrationTrial,
              p.localSessionApprovalID != nil else { return false }
        return authorizationIsLive(p)
    }

    /// Separate one-step commissioning permission, never inferred from speech,
    /// a general visual trial or a previously imported ordinary recycling job.
    @nonobjc func authorizesLocalRecyclingNominalEmptyCommissioningStep(summary: String, arm: String) -> Bool {
        guard let p = pending, let scope = p.localRecyclingScope,
              scope.nominalEmptyCommissioningStepEnabled, !scope.oneDegreeEmptyCalibrationStepEnabled, p.awaitingLocalReceipt,
              scope.arm == arm, scope.summary == summary,
              scope.permitsUnmeasuredVisualCalibrationTrial,
              p.localSessionApprovalID != nil else { return false }
        return authorizationIsLive(p)
    }

    /// Actuator/model calibration only. Environment contact predictions remain
    /// diagnostic; this permission never grants an ordinary collision route.
    @nonobjc func authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary: String, arm: String) -> Bool {
        guard let p = pending, let scope = p.localRecyclingScope,
              scope.oneDegreeEmptyCalibrationStepEnabled, !scope.nominalEmptyCommissioningStepEnabled,
              p.awaitingLocalReceipt, arm == "right", scope.arm == arm, scope.summary == summary,
              scope.permitsUnmeasuredVisualCalibrationTrial, p.localSessionApprovalID != nil else { return false }
        return authorizationIsLive(p)
    }

    var activeLocalRecyclingApprovalEvidence: NSDictionary? {
        guard let p = pending, let started = p.started, let approval = localRecyclingApproval,
              p.localSessionApprovalID == approval.receiptID, authorizationIsLive(p) else { return nil }
        var value = approval.scope.object
        value["receiptID"] = approval.receiptID.uuidString
        value["receiptSHA256"] = approval.receiptSHA256
        value["appSessionID"] = localSessionID.uuidString
        value["pendingID"] = p.id
        value["executingUntilMilliseconds"] = started.addingTimeInterval(p.executionLimit).timeIntervalSince1970 * 1000
        value["beginBeforeMilliseconds"] = approval.beginBefore.timeIntervalSince1970 * 1000
        value["registrationVerifiedByApproval"] = false
        return value as NSDictionary
    }

    /// Read-only sandbox status, including an idle exact-job approval retained
    /// after a no-travel perception miss. Private source text is never exposed.
    var localRecyclingApprovalState: NSDictionary? {
        guard let approval = localRecyclingApproval,
              approval.contextIdentity() == approval.scope.contextIdentity else { return nil }
        if approval.activePendingID != nil {
            guard let p = pending, approval.activePendingID == p.id, authorizationIsLive(p) else { return nil }
        } else if approval.beginBefore <= now() { return nil }
        var value = approval.scope.object
        value["state"] = approval.activePendingID == nil ? "available" : "executing"
        value["receiptID"] = approval.receiptID.uuidString
        value["receiptSHA256"] = approval.receiptSHA256
        value["appSessionID"] = localSessionID.uuidString
        value["beginBeforeMilliseconds"] = approval.beginBefore.timeIntervalSince1970 * 1000
        value["source"] = "explicit_local_OS_file_import"
        return value as NSDictionary
    }

    private func auditLocalApprovalEvent(_ event: String, approval: LocalRecyclingApproval, detail: String) {
        let value: [String: Any] = ["schemaVersion": 1, "event": event,
            "receiptID": approval.receiptID.uuidString, "receiptSHA256": approval.receiptSHA256,
            "appSessionID": localSessionID.uuidString, "scope": approval.scope.object,
            "atMilliseconds": now().timeIntervalSince1970 * 1000, "detail": detail]
        try? writeLocalApprovalAudit(value, name: "event-" + UUID().uuidString + ".json")
    }

    private func revokeLocalApproval(reason: String) {
        if let approval = localRecyclingApproval {
            // Clear first even when passive audit I/O fails.
            localRecyclingApproval = nil
            auditLocalApprovalEvent("revoked_or_consumed", approval: approval, detail: reason)
        }
    }

    private static func localHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func localApprovalError(_ text: String) -> NSError {
        NSError(domain: "Cerebro.LocalRecyclingApproval", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private func localCanonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func readPrivateLocalReceipt(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw localApprovalError("Select a private local receipt file.") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw localApprovalError("The receipt must be a readable regular file, not a symbolic link.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 32768 else {
            throw localApprovalError("The receipt must be owned by this OS user, private (0600), and at most 32 KB.")
        }
        let value = try handle.read(upToCount: 32769) ?? Data()
        guard value.count == Int(info.st_size) else { throw localApprovalError("The receipt changed while being read.") }
        return value
    }
    private func writeLocalApprovalAudit(_ value: [String: Any], name: String) throws {
        let directory = localRecyclingApprovalAuditDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw localApprovalError("The local approval audit directory must be private and owned by this OS user.")
        }
        let data = try localCanonical(value)
        let descriptor = open(directory.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw localApprovalError("This receipt was already imported, or its audit could not be saved. No new approval was granted.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
    }

    private struct Peer {
        let device: UUID
        let session: UUID
        let sender: String
        let seen: Date
        let capabilities: Set<String>
    }
    private struct Pending {
        let id: String
        let action: String
        let arguments: NSDictionary
        let summary: String
        let created: Date
        let execute: (@escaping (NSDictionary) -> Void) -> Void
        let cancel: () -> Void
        let completion: (NSDictionary) -> Void
        var peer: Peer?
        var request: ROBRobotActionMessage?
        var started: Date?
        let executionLimit: TimeInterval
        var voiceAuthorized = false
        var armSessionID: String? = nil
        var attentionReminders = 0
        var localRecyclingScope: LocalRecyclingScope?
        var localContextIdentity: (() -> String?)?
        var awaitingLocalReceipt = false
        var localSessionApprovalID: UUID?
    }
    private struct ArmSession {
        let id: String
        let peer: Peer?
        let voiceAuthorized: Bool
        let expires: Date
    }
    private var armSession: ArmSession?
    private var peers: [UUID: Peer] = [:]
    private var pending: Pending?
    private var timer: Timer?
    private let senderID = "Cerebro.arm-operations"
    // Give the operator time to notice the phone banner and review the complete
    // operation. No execution begins until a current controller accepts it.
    private static let operatorApprovalSeconds: TimeInterval = 90

    func request(operation: String, arm: String, summary: String,
                 execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
                 cancel: @escaping () -> Void,
                 completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": operation, "arm": arm, "summary": summary],
                summary: summary, execute: execute, cancel: cancel, completion: completion)
    }

    /// A reviewed immutable ghost rendition remains bounded to three minutes.
    /// This does not change other arm or gripper approval deadlines.
    @nonobjc func requestLeftGesture(summary: String,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, executionLimit: 180, allowArmSession: true, execute: execute, cancel: cancel, completion: completion)
    }

    /// One bounded task includes local search, pointing assistance, planning,
    /// all arm segments and gripper actions. No nested approval per step.
    @nonobjc func requestLeftWorkspaceTask(summary: String,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, executionLimit: 600, allowArmSession: true, execute: execute, cancel: cancel, completion: completion)
    }
    /// Right-arm tasks have their own one-shot scope. A left rehearsal grant
    /// never authorizes them, even while both physical arms are reserved.
    @nonobjc func requestRightWorkspaceTask(summary: String,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation":"manual","arm":"both","summary":summary],
            summary:summary,executionLimit:600,allowArmSession:false,execute:execute,cancel:cancel,completion:completion)
    }
    @nonobjc func requestLeftStationary(summary: String,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, allowArmSession: true, execute: execute, cancel: cancel, completion: completion)
    }

    func beginArmSession(completion: @escaping (NSDictionary) -> Void) {
        let summary = "Authorize a 15-minute supervised LEFT-arm rehearsal: local search/pointing, preparation of the CONFIRMED-EMPTY arm, empty calibration, a stationary EMPTY-jaw initialization close at intensity 2 followed by opening at fixed intensity 10, bounded reviewed gestures, empty-can recycling with gentle closing at intensity 2 and gravity release at intensity 10, and empty-arm lowering. A held EMPTY arm after a missed recycling attempt may first return through its recorded visited targets to front; an explicit local grasp-clearance calibration may skip low targets only after validating each connecting segment above the calibrated height. No unvisited recovery targets. Confirm no object is held. One authorization covers these complete routines and all waypoints. No driving, right-arm motion, arbitrary raw targets, blind force escalation or torque-off with a payload. The model/hand-eye geometry is provisional; watch clearance and keep Stop available. Stop, sleep/restart, expiry or controller loss ends this session."
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, execute: { [weak self] done in
                guard let self, let p = self.pending else { return }
                self.armSession = ArmSession(id: p.id, peer: p.peer, voiceAuthorized: p.voiceAuthorized,
                    expires: self.now().addingTimeInterval(900))
                done(["status": "completed", "measured": false,
                    "detail": "Left-arm rehearsal authorized for 15 minutes. Complete local routines no longer ask again. Stop ends the session; held objects must be supported before lowering."])
            }, cancel: {}, completion: completion)
    }

    private func sessionIsFresh(_ session: ArmSession) -> Bool {
        session.expires > now() && (session.voiceAuthorized || session.peer.map(peerIsFresh) == true)
    }

    private func authorizationIsLive(_ p: Pending) -> Bool {
        guard let started = p.started, (0..<p.executionLimit).contains(now().timeIntervalSince(started)) else { return false }
        if let id = p.localSessionApprovalID {
            guard let approval = localRecyclingApproval, approval.receiptID == id,
                  approval.activePendingID == p.id, approval.scope == p.localRecyclingScope,
                  approval.contextIdentity() == approval.scope.contextIdentity,
                  p.localContextIdentity?() == approval.scope.contextIdentity else { return false }
            return true
        }
        if let id = p.armSessionID {
            return armSession.map { $0.id == id && sessionIsFresh($0) } == true
        }
        return p.voiceAuthorized || p.peer.map(peerIsFresh) == true
    }

    /// Call only from the live local microphone transcript path, after echo
    /// suppression. Camera text, typed chat and model tool calls never enter it.
    func receiveSpokenAuthorization(_ text: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let p = pending, !p.awaitingLocalReceipt, p.started == nil, now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds else { return false }
        guard let accepted = Self.spokenDecision(text) else { return false }
        if !accepted { cancel(reason: "Local spoken rejection; no new motion authorized."); return true }
        pending?.voiceAuthorized = true
        beginAcceptedOperation()
        return true
    }

    /// Endpoint a stable microphone candidate promptly, then wait for its
    /// recognizer FINAL result before granting anything. Continuous dictation
    /// otherwise may not finalize a short "yes" until its minute-long timeout.
    func isSpokenAuthorizationCandidate(_ text: String) -> Bool {
        guard let p = pending, !p.awaitingLocalReceipt, p.started == nil, now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds else { return false }
        return Self.spokenDecision(text) != nil
    }

    private static func spokenDecision(_ text: String) -> Bool? {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "^(?:(?:hey )?(?:rob|robbie|robot)[, ]+)?"
        if value.range(of: prefix + "(?:no|no thanks|cancel|reject|do not proceed|don't proceed)[.!?]*$", options: .regularExpression) != nil {
            return false
        }
        return value.range(of: prefix + "(?:yes(?:[, ]+(?:please|proceed|go ahead|do it|continue))?|(?:ok|okay)(?:[, ]+(?:proceed|go ahead|do it))?|sure|proceed|go ahead|approved|permission granted)[.!?]*$", options: .regularExpression) != nil ? true : nil
    }

    private func beginAcceptedOperation() {
        guard let p = pending, p.started == nil else { return }
        if p.localSessionApprovalID != nil {
            guard let approval = localRecyclingApproval, approval.activePendingID == p.id,
                  approval.beginBefore > now(), approval.scope == p.localRecyclingScope,
                  approval.contextIdentity() == approval.scope.contextIdentity else {
                cancel(reason: "The local recycling approval lost its scope or current context before execution."); return
            }
        }
        pending?.started = now()
        update("Authorized complete operation: \(p.summary)")
        publish(.executing, detail: status, result: [:])
        p.execute { [weak self] result in
            guard let self, self.pending?.id == p.id else { return }
            precondition(Thread.isMainThread)
            let outcome = result["status"] as? String ?? "failed"
            let succeeded = ["completed", "accepted_unverified", "ready_for_object", "grip_attempted"].contains(outcome)
            let noReach = result["reach_sent"] as? Bool == false
            let safelyParked = noReach && result["empty_arm_parked"] as? Bool == true
            let observationOnly = ["not_found", "not_localized", "not_reachable", "needs_help"].contains(outcome)
                && (result["arm_motion_sent"] as? Bool == false || safelyParked)
            if !succeeded, !observationOnly, p.armSessionID != nil { self.armSession = nil }
            if let receiptID = p.localSessionApprovalID {
                // Retain only an explicit no-travel/no-jaw perception result.
                // An empty return/park is travel and cannot use this exception.
                let perceptionOutcome = ["not_found", "not_localized", "not_reachable", "needs_help"].contains(outcome)
                    || outcome == "blocked"
                let perceptionOnly = perceptionOutcome
                    && result["perception_only_rejection"] as? Bool == true
                    && result["arm_motion_sent"] as? Bool == false
                    && result["reach_sent"] as? Bool == false
                    && result["jaw_command_sent"] as? Bool == false
                if perceptionOnly, var approval = self.localRecyclingApproval,
                   approval.receiptID == receiptID, approval.beginBefore > self.now(),
                   approval.contextIdentity() == approval.scope.contextIdentity {
                    approval.activePendingID = nil; self.localRecyclingApproval = approval
                    self.auditLocalApprovalEvent("perception_only_job_available", approval: approval, detail: outcome)
                } else {
                    self.revokeLocalApproval(reason: "Job ended: " + outcome)
                }
            }
            self.finish(result, state: succeeded ? .completed : .failed)
        }
    }

    /// Existing controllers already review named play_gesture requests and
    /// leave their execution/result to Cerebro. Use that same authenticated,
    /// one-shot lane for an immutable, bounded neck rehearsal.
    func requestMotionPath(name: String, execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
                           cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "play_gesture", arguments: ["gesture": name], summary: name,
                execute: execute, cancel: cancel, completion: completion)
    }

    func authorizesMotionPath(_ name: String) -> Bool {
        guard let p = pending, p.started != nil, p.action == "play_gesture",
              p.arguments["gesture"] as? String == name else { return false }
        return authorizationIsLive(p)
    }

    /// Exact one-shot scope for the operator-supervised physical-left trial.
    func authorizesLeftArmTrial(_ summary: String) -> Bool {
        guard let p = pending,
              p.action == "arm_operation", p.arguments["operation"] as? String == "manual",
              p.arguments["arm"] as? String == "left", p.summary == summary,
              authorizationIsLive(p) else { return false }
        return true
    }

    func authorizesRightArmTrial(_ summary: String) -> Bool {
        guard let p = pending, p.action == "arm_operation",
              p.arguments["operation"] as? String == "manual",
              ["right","both"].contains(p.arguments["arm"] as? String ?? ""), p.summary == summary,
              authorizationIsLive(p) else { return false }
        return true
    }

    /// Only an active approval whose on-controller wording explicitly covers
    /// operator-supervised travel may replace the semantic route inspection.
    /// Never persist or infer this scope from a model's request or a preference.
    func authorizesSupervisedArmRoute() -> Bool {
        guard let p = pending, authorizationIsLive(p) else { return false }
        return (p.action == "arm_operation" && p.summary.hasSuffix(Self.supervisedRouteNotice))
            || (p.action == "play_gesture" && p.summary == Self.supervisedGreetingName)
    }

    private func request(action: String, arguments: NSDictionary, summary: String, executionLimit: TimeInterval = 120,
                         allowArmSession: Bool = false,
                         localRecyclingScope: LocalRecyclingScope? = nil,
                         localContextIdentity: (() -> String?)? = nil, receiptOnly: Bool = false,
                         execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
                         cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard pending == nil else {
            completion(["status": "busy", "detail": status]); return
        }
        let probe = ROBRobotActionMessage.actionRequest(callID: UUID().uuidString,
            action: action, arguments: arguments,
            senderID: senderID, recipientID: nil, expiresAt: now().addingTimeInterval(Self.operatorApprovalSeconds))
        guard probe.validationError == nil else {
            completion(["status": "rejected", "detail": "Invalid controller motion approval request."]); return
        }
        pending = Pending(id: probe.callID!, action: action, arguments: arguments.copy() as! NSDictionary, summary: summary,
            created: now(), execute: execute, cancel: cancel, completion: completion, executionLimit: executionLimit)
        pending?.localRecyclingScope = localRecyclingScope
        pending?.localContextIdentity = localContextIdentity
        pending?.awaitingLocalReceipt = receiptOnly
        if let approval = localRecyclingApproval {
            if let scope = localRecyclingScope, approval.scope == scope, approval.activePendingID == nil,
               approval.beginBefore > now(), approval.contextIdentity() == scope.contextIdentity,
               localContextIdentity?() == scope.contextIdentity {
                localRecyclingApproval?.activePendingID = pending?.id
                pending?.localSessionApprovalID = approval.receiptID
                startTimer(); beginAcceptedOperation(); return
            }
            revokeLocalApproval(reason: "A different operation or context replaced the exact recycling job.")
        }
        if receiptOnly {
            update("Awaiting local user-session receipt for the exact four-can recycling job: \(summary)")
            startTimer(); return
        }
        if allowArmSession, let session = armSession, sessionIsFresh(session) {
            pending?.peer = session.peer; pending?.voiceAuthorized = session.voiceAuthorized
            pending?.armSessionID = session.id
            startTimer(); beginAcceptedOperation(); return
        }
        update("Awaiting spoken or controller authorization: \(summary)")
        // Rob requested this exact brief spoken prompt. The immutable complete
        // scope remains in the controller request and Settings status.
        announceApproval?("Can I move my arms?")
        startTimer()
        tick()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Called only after AutoNet has authenticated an operator device/session.
    @nonobjc func receive(_ message: ROBRobotActionMessage, device: UUID, session: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard sessionIsActive(device, session), message.validationError == nil else { return false }
        if message.kind == .actionCancel, let grant = armSession, message.callID == grant.id,
           let peer = grant.peer, peer.device == device, peer.session == session,
           message.senderID == peer.sender, message.recipientID == senderID {
            cancel(reason: "Controller ended the arm rehearsal session; hold requested.")
            return true
        }
        if message.kind == .controllerHello {
            if message.acceptsActions {
                peers[device] = Peer(device: device, session: session, sender: message.senderID, seen: now(),
                                     capabilities: Set(message.capabilities))
                if let p = pending, p.peer?.device == device, !message.capabilities.contains(p.action) {
                    cancel(reason: "The controller stopped accepting this motion operation.")
                }
            } else {
                peers.removeValue(forKey: device)
                if armSession?.peer?.device == device, armSession?.voiceAuthorized == false { armSession = nil }
                if pending?.peer?.device == device, pending?.peer?.session == session, pending?.voiceAuthorized != true {
                    self.cancel(reason: "The controller stopped accepting arm operations.")
                }
            }
            tick()
            return false // Existing action workflows also consume hello.
        }
        guard let p = pending, message.callID == p.id else { return false }
        guard let peer = p.peer, peer.device == device, peer.session == session,
              message.senderID == peer.sender, message.recipientID == senderID else { return true }
        if message.kind == .actionCancel {
            cancel(reason: "The controller cancelled the arm operation."); return true
        }
        guard message.kind == .actionStatus else { return true }
        if message.state == .accepted {
            guard p.started == nil else {
                publish(.executing, detail: "This approved operation is already running.", result: [:]); return true
            }
            guard let request = p.request, !isExpired(request),
                  peerIsFresh(peer) else {
                finish(["status": "expired", "detail": "Controller approval expired; no operation was started."], state: .expired)
                return true
            }
            beginAcceptedOperation()
        } else if message.isTerminal {
            // A controller can reject/cancel, but cannot assert hardware success.
            if p.started != nil { cancel(reason: "The controller ended the arm operation; hold requested.") }
            else {
                let terminal: ROBRobotActionState
                let outcome: String
                switch message.state {
                case .expired: terminal = .expired; outcome = "expired"
                case .cancelled: terminal = .cancelled; outcome = "cancelled"
                case .failed: terminal = .failed; outcome = "failed"
                default: terminal = .rejected; outcome = "rejected"
                }
                let controllerDetail = message.detail ?? ""
                let detail = controllerDetail.isEmpty ? "The controller did not approve this motion operation."
                    : "Controller: \(String(controllerDetail.prefix(512)))"
                finish(["status": outcome, "detail": detail], state: terminal)
            }
        }
        return true
    }

    func cancel(reason: String) {
        precondition(Thread.isMainThread)
        armSession = nil
        revokeLocalApproval(reason: reason)
        guard let p = pending else {
            timer?.invalidate(); timer = nil; update(reason); return
        }
        // Clear before callbacks, so cancellation/replayed accepts cannot restart.
        finish(["status": "cancelled", "detail": reason], state: .cancelled, cancelExecution: p.started != nil)
    }

    @nonobjc func tick() {
        precondition(Thread.isMainThread)
        if let approval = localRecyclingApproval,
           approval.contextIdentity() != approval.scope.contextIdentity ||
            (approval.activePendingID == nil && approval.beginBefore <= now()) {
            cancel(reason: "Local recycling approval expired or its camera/body/arm context was lost; hold requested."); return
        }
        if armSession == nil && pending == nil && localRecyclingApproval == nil { timer?.invalidate(); timer = nil; return }
        if let session = armSession, !sessionIsFresh(session) {
            armSession = nil
            if pending?.armSessionID != nil { cancel(reason: "Arm rehearsal session ended; hold requested."); return }
            update("Arm rehearsal authorization expired or its controller disconnected.")
        }
        guard let p = pending else { return }
        if p.awaitingLocalReceipt, p.started == nil {
            if now().timeIntervalSince(p.created) >= Self.localApprovalBeginLimit ||
                p.localContextIdentity?() != p.localRecyclingScope?.contextIdentity {
                cancel(reason: "The prepared local recycling request expired or lost its context.")
            }
            return
        }
        if p.started == nil, p.attentionReminders < 2,
           now().timeIntervalSince(p.created) >= (p.attentionReminders == 0 ? 20 : 45),
           now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds {
            pending?.attentionReminders += 1
            // Rob requested an audible attention cue when the first question
            // is missed. Repeat the SAME scope without extending its deadline.
            announceApproval?("Hey! Can I move my arms?")
        }
        if p.started != nil, p.voiceAuthorized || p.armSessionID != nil || p.localSessionApprovalID != nil {
            if !authorizationIsLive(p) { cancel(reason: "Authorized arm operation expired; hold requested.") }
            return
        }
        if let peer = p.peer {
            guard peerIsFresh(peer) else {
                cancel(reason: "The approving controller disconnected; arm hold requested."); return
            }
            if let started = p.started {
                if now().timeIntervalSince(started) > p.executionLimit {
                    cancel(reason: "The approved arm operation timed out; hold requested.")
                }
            } else if p.request.map(isExpired) == true {
                finish(["status": "expired", "detail": "No controller approval arrived before the deadline."], state: .expired)
            }
            return
        }
        guard now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds else {
            finish(["status": "blocked", "detail": "No spoken or controller authorization arrived. No arm operation was started."], state: .expired)
            return
        }
        guard let peer = peers.values.filter({ now().timeIntervalSince($0.seen) < 15 &&
            $0.capabilities.contains(p.action) && sessionIsActive($0.device, $0.session) })
            .sorted(by: { $0.seen > $1.seen }).first else { return }
        let request = ROBRobotActionMessage.actionRequest(callID: p.id, action: p.action,
            arguments: p.arguments,
            senderID: senderID, recipientID: peer.sender, expiresAt: now().addingTimeInterval(Self.operatorApprovalSeconds))
        pending?.peer = peer; pending?.request = request
        guard send?(request, peer.device, peer.session) == true else {
            finish(["status": "blocked", "detail": "Could not deliver the arm approval request to the controller."], state: .failed)
            return
        }
    }

    private func isExpired(_ request: ROBRobotActionMessage) -> Bool {
        now().timeIntervalSince1970 * 1000 >= Double(request.expiresAtMilliseconds)
    }

    private func update(_ detail: String) {
        status = detail
        NotificationCenter.default.post(name: Notification.Name("ROBControllerArmApprovalDidChange"), object: self)
    }
    private func peerIsFresh(_ peer: Peer) -> Bool {
        guard let current = peers[peer.device], current.session == peer.session,
              current.sender == peer.sender,
              pending.map({ current.capabilities.contains($0.action) }) != false else { return false }
        return now().timeIntervalSince(current.seen) < 15 && sessionIsActive(peer.device, peer.session)
    }

    /// UI callers capture the selected arm/force before requesting approval.
    /// Recheck feedback and the gateway generation after the operator decides.
    @nonobjc func requestGatewayCommand(operation: String, arm: String, summary: String,
        command: @escaping () -> UInt64, completion: @escaping (NSDictionary) -> Void) {
        let gateway = ROBAmberGatewayClient.shared
        let gatewayArm = arm == "right" ? "left" : "right"
        let port = arm == "right" ? 26001 : 26002
        let generation = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        var observer: NSObjectProtocol?
        var timeout: DispatchWorkItem?
        var commandID: UInt64 = 0
        func cleanup() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil; timeout?.cancel(); timeout = nil
        }
        request(operation: operation, arm: arm, summary: summary, execute: { done in
            let readiness = gateway.manualArmControlReadiness(forUDPPort: port,
                expectedSessionGeneration: generation)
            guard generation != 0, readiness["allowed"] as? Bool == true else {
                done(["status": "blocked", "detail": readiness["reason"] as? String ?? "Gateway session is unavailable."])
                return
            }
            observer = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
                object: gateway, queue: .main) { note in
                guard commandID != 0, (note.userInfo?["commandID"] as? NSNumber)?.uint64Value == commandID else { return }
                cleanup()
                let accepted = note.userInfo?["accepted"] as? Bool == true
                let gripper = operation.contains("gripper")
                done(["status": accepted ? (gripper ? "accepted_unverified" : "completed") : "failed",
                      "detail": accepted ? (gripper ? "Amber accepted the gripper command; jaw position, force and mechanical completion remain unverified." : "Amber acknowledged the arm mode command.")
                        : (note.userInfo?["error"] as? String ?? "Amber rejected the command.")])
            }
            commandID = command()
            guard commandID != 0 else {
                cleanup(); done(["status": "blocked", "detail": "Arm interlocks rejected the command before submission."]); return
            }
            let deadline = DispatchWorkItem {
                cleanup(); _ = gateway.priorityHold(forArm: gatewayArm)
                done(["status": "failed", "detail": "Amber acknowledgement timed out; arm hold requested."])
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        }, cancel: {
            cleanup(); _ = gateway.priorityHold(forArm: gatewayArm)
        }, completion: completion)
    }
    private func publish(_ state: ROBRobotActionState, detail: String, result: NSDictionary) {
        guard let p = pending, let peer = p.peer else { return }
        let reply = ROBRobotActionMessage.actionStatus(callID: p.id, state: state, detail: detail,
            result: result, senderID: senderID, recipientID: peer.sender)
        _ = send?(reply, peer.device, peer.session)
    }
    private func finish(_ result: NSDictionary, state: ROBRobotActionState, cancelExecution: Bool = false) {
        guard let p = pending else { return }
        publish(state, detail: result["detail"] as? String ?? "Arm operation ended", result: result)
        pending = nil
        if armSessionActive || localRecyclingApproval != nil { startTimer() } else { timer?.invalidate(); timer = nil }
        if cancelExecution { p.cancel() }
        update(result["detail"] as? String ?? "Arm operation ended")
        p.completion(result)
    }
}
