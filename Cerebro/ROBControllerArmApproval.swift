import Foundation
import CryptoKit
import Darwin

enum ROBStandingCanCampaignRecoveryReason: String { case transportLost, feedbackLost, cameraSourceChanged }

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

    // Imported local-user approval and the separate clean-final-microphone
    // restart below are distinct from ordinary chat/model/controller text.
    private let localSessionID = UUID()
    var localRecyclingApprovalSessionID: String { localSessionID.uuidString }
    @nonobjc var localRecyclingApprovalAuditDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cerebro/LocalSessionApprovals", isDirectory: true)
    @nonobjc var standingCanCampaignDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cerebro/LocalSessionApprovals/StandingCanCampaign", isDirectory: true)
    private struct StandingAuthorizationScope: Decodable { let canCount: Int }
    private struct SpokenCampaignRestart: Codable {
        let schemaVersion: Int, eventID: UUID, appSessionID: UUID
        let previousCampaignID: UUID, previousAuthorizationSHA256: String, previousTerminalSHA256: String
        let previousCompletedTransfers: Int, previousTargetCanCount: Int
        let previousPossiblePayloadHeld: Bool
    }
    private struct StandingAuthorization: Decodable {
        let schemaVersion: Int, kind: String, campaignID: UUID, issuedAtMilliseconds: Double
        let source: String, sourceMessage: String, sourceMessageSHA256: String
        let additionalUserInstruction: String, additionalUserInstructionSHA256: String
        let scope: StandingAuthorizationScope
        let restart: SpokenCampaignRestart?
    }
    private struct StandingState: Codable {
        let schemaVersion: Int, campaignID: UUID, authorizationSHA256: String
        var state: String, completedTransfers: Int, verifiedLandings: Int, recoveryAttempts: Int
        var detail: String, lastJobID: String?, lastJobAppSessionID: UUID?
        var creditedJobCounts: [String: Int]
        var possiblePayloadHeld: Bool? = nil
        var targetCanCount: Int? = nil
        var authorizationSource: String? = nil
        var canCount: Int { targetCanCount ?? 4 }
    }
    private var standingRecovery: DispatchWorkItem?
    private var standingRecoveryToken = UUID()
    private var standingIOFailure: String?
    private static func standingScope(canCount: Int, legacy: Bool) -> [String: Any] {
        ["canCount": canCount, "targetObject": "empty_coke_can", "destination": "orange_bucket", "arms": ["left", "right"],
         "treads": false, "torso": false, "manualGestures": false, "permitsUnmeasuredVisualCalibrationTrial": true,
         "automaticConnectionRecovery": true,
         "validUntil": legacy ? "four_transfers_or_user_intervention" : "target_transfers_or_user_intervention"]
    }
    private var standingStateURL: URL { standingCanCampaignDirectory.appendingPathComponent("active-campaign.json") }
    private func standingAuthorizationURL(_ id: UUID) -> URL {
        standingCanCampaignDirectory.appendingPathComponent("authorization-" + id.uuidString + ".json")
    }
    private func standingTerminalURL(_ id: UUID) -> URL {
        standingCanCampaignDirectory.appendingPathComponent("terminal-" + id.uuidString + ".json")
    }
    private func validateStandingAuthorization(_ data: Data, validateRestartParent: Bool = true) throws -> StandingAuthorization {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let a = try JSONDecoder().decode(StandingAuthorization.self, from: data)
        let spoken = a.source == "final_clean_local_microphone"
        var keys: Set<String> = ["schemaVersion", "kind", "campaignID", "issuedAtMilliseconds", "source", "sourceMessage",
            "sourceMessageSHA256", "additionalUserInstruction", "additionalUserInstructionSHA256", "scope"]
        if spoken { keys.insert("restart") }
        guard let value, Set(value.keys) == keys, let scope = value["scope"] as? [String: Any],
              [1, 2].contains(a.schemaVersion), (1...8).contains(a.scope.canCount),
              a.schemaVersion != 1 || a.scope.canCount == 4,
              try localCanonical(scope) == localCanonical(Self.standingScope(canCount: a.scope.canCount, legacy: a.schemaVersion == 1)),
              a.kind == "local_user_standing_can_campaign_authorization",
              (a.source == "explicit_user_session_instruction" || spoken && a.schemaVersion == 2),
              a.issuedAtMilliseconds.isFinite, a.issuedAtMilliseconds > 0,
              a.issuedAtMilliseconds <= now().timeIntervalSince1970 * 1000,
              !a.sourceMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, a.sourceMessage.utf8.count <= 8192,
              a.sourceMessageSHA256 == Self.localHash(Data(a.sourceMessage.utf8)),
              !a.additionalUserInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              a.additionalUserInstruction.utf8.count <= 8192,
              a.additionalUserInstructionSHA256 == Self.localHash(Data(a.additionalUserInstruction.utf8)) else {
            throw localApprovalError("Standing authorization needs an exact bounded can count, arms-only scope and matching private user evidence.")
        }
        if spoken {
            let restartKeys: Set<String> = ["schemaVersion", "eventID", "appSessionID", "previousCampaignID",
                "previousAuthorizationSHA256", "previousTerminalSHA256", "previousCompletedTransfers", "previousTargetCanCount", "previousPossiblePayloadHeld"]
            guard let restart = a.restart, restart.schemaVersion == 1, restart.previousCampaignID != a.campaignID,
                  let object = value["restart"] as? [String: Any], Set(object.keys) == restartKeys,
                  (1...8).contains(restart.previousTargetCanCount),
                  (0..<restart.previousTargetCanCount).contains(restart.previousCompletedTransfers),
                  a.scope.canCount == restart.previousTargetCanCount - restart.previousCompletedTransfers,
                  Self.isSpokenCanCampaignRestartPhrase(a.sourceMessage) else {
                throw localApprovalError("A spoken restart needs a new campaign linked to the stopped job's remaining scope.")
            }
            if validateRestartParent {
                let terminalData = try readPrivateLocalReceipt(standingTerminalURL(restart.previousCampaignID))
                let previous = try JSONDecoder().decode(StandingState.self, from: terminalData)
                let previousData = try readPrivateLocalReceipt(standingAuthorizationURL(restart.previousCampaignID))
                let previousAuthorization = try validateStandingAuthorization(previousData, validateRestartParent: false)
                guard Self.localHash(terminalData) == restart.previousTerminalSHA256,
                      Self.localHash(previousData) == restart.previousAuthorizationSHA256,
                      previous.state == "revoked", previous.campaignID == restart.previousCampaignID,
                      [1, 2].contains(previous.schemaVersion),
                      previous.schemaVersion != 1 || previous.canCount == 4,
                      previous.schemaVersion != 2 || previous.targetCanCount != nil,
                      previous.authorizationSHA256 == restart.previousAuthorizationSHA256,
                      previousAuthorization.campaignID == previous.campaignID,
                      previousAuthorization.scope.canCount == previous.canCount,
                      previous.canCount == restart.previousTargetCanCount,
                      previous.completedTransfers == restart.previousCompletedTransfers,
                      standingMayHoldPayload(previous) == restart.previousPossiblePayloadHeld,
                      a.additionalUserInstruction == previousAuthorization.additionalUserInstruction,
                      a.additionalUserInstructionSHA256 == previousAuthorization.additionalUserInstructionSHA256 else {
                    throw localApprovalError("The spoken restart's prior revoked evidence changed or cannot be verified.")
                }
            }
        } else if a.restart != nil {
            throw localApprovalError("Written authorization cannot claim a microphone restart.")
        }
        return a
    }
    private func prepareStandingDirectory() throws {
        try FileManager.default.createDirectory(at: standingCanCampaignDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let a = try FileManager.default.attributesOfItem(atPath: standingCanCampaignDirectory.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw localApprovalError("Standing campaign storage must be private and owned by this OS user.")
        }
    }
    private func writeStandingExclusive(_ data: Data, to url: URL) throws {
        try prepareStandingDirectory()
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw localApprovalError("This campaign was already imported, ended, or could not be recorded.") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? h.close() }
        try h.write(contentsOf: data); try h.synchronize()
    }
    private func saveStanding(_ state: StandingState) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let temp = standingCanCampaignDirectory.appendingPathComponent("state-" + UUID().uuidString + ".tmp")
        try writeStandingExclusive(try encoder.encode(state), to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard rename(temp.path, standingStateURL.path) == 0 else { throw localApprovalError("Could not save standing campaign progress.") }
    }
    private func standingRecord(includeTerminal: Bool = false) -> StandingState? {
        guard standingIOFailure == nil, FileManager.default.fileExists(atPath: standingStateURL.path) else { return nil }
        do {
            var s = try JSONDecoder().decode(StandingState.self, from: readPrivateLocalReceipt(standingStateURL))
            if FileManager.default.fileExists(atPath: standingTerminalURL(s.campaignID).path) {
                guard includeTerminal else { return nil }
                let terminal = try JSONDecoder().decode(StandingState.self, from: readPrivateLocalReceipt(standingTerminalURL(s.campaignID)))
                guard terminal.campaignID == s.campaignID, terminal.authorizationSHA256 == s.authorizationSHA256 else { return nil }
                s = terminal
            }
            guard [1, 2].contains(s.schemaVersion), (1...8).contains(s.canCount),
                  s.schemaVersion != 1 || s.canCount == 4,
                  s.schemaVersion != 2 || s.targetCanCount != nil,
                  s.schemaVersion != 2 || s.authorizationSource != nil,
                  (0...s.canCount).contains(s.completedTransfers), (0...s.completedTransfers).contains(s.verifiedLandings),
                  (0...3).contains(s.recoveryAttempts),
                  (["active", "paused", "recovering", "executing", "waiting_for_intervention"].contains(s.state)
                    || includeTerminal && ["revoked", "consumed"].contains(s.state)) else { return nil }
            let data = try readPrivateLocalReceipt(standingAuthorizationURL(s.campaignID))
            let authorization = try validateStandingAuthorization(data)
            guard Self.localHash(data) == s.authorizationSHA256,
                  authorization.campaignID == s.campaignID, authorization.scope.canCount == s.canCount,
                  s.authorizationSource == nil || s.authorizationSource == authorization.source else { return nil }
            return s
        } catch { return nil }
    }
    var standingLocalCanCampaignActive: Bool { standingRecord().map { $0.completedTransfers < $0.canCount } ?? false }
    /// Object state is independent of permission. Startup jaw preparation and
    /// new campaign imports must not assume EMPTY after a crash or I/O loss.
    var standingCanCampaignMayHoldPayload: Bool {
        if FileManager.default.fileExists(atPath: standingStateURL.path) {
            guard let s = standingRecord(includeTerminal: true) else { return true }
            return standingMayHoldPayload(s)
        }
        guard FileManager.default.fileExists(atPath: standingCanCampaignDirectory.path) else { return false }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: standingCanCampaignDirectory.path) else { return true }
        return files.contains { $0.hasPrefix("authorization-") || $0.hasPrefix("terminal-") }
    }
    private func standingMayHoldPayload(_ s: StandingState) -> Bool {
        (s.possiblePayloadHeld ?? true) || (s.state == "executing" && s.lastJobAppSessionID != localSessionID)
    }
    var standingLocalCanCampaignState: NSDictionary? {
        guard let s = standingRecord(includeTerminal: true) else { return standingIOFailure.map { ["state": "blocked", "detail": $0] as NSDictionary } }
        let state = s.state == "executing" && s.lastJobAppSessionID != localSessionID ? "paused" : s.state
        return ["campaignID": s.campaignID.uuidString, "state": state, "completedTransfers": s.completedTransfers,
            "targetCanCount": s.canCount, "canCount": s.canCount, "remainingTransfers": s.canCount - s.completedTransfers, "verifiedLandings": s.verifiedLandings,
            "possiblePayloadHeld": standingMayHoldPayload(s),
            "recoveryAttempts": s.recoveryAttempts, "detail": state == "paused" && s.state == "executing"
                ? "App restarted; a new plan and fresh possession/scene checks are required. No old waypoint resumes." : s.detail,
            "source": s.authorizationSource ?? "explicit_user_session_instruction", "authorizationSHA256": s.authorizationSHA256] as NSDictionary
    }
    @nonobjc func importLocalCanCampaignAuthorization(fromReceiptURL url: URL) throws {
        precondition(Thread.isMainThread)
        guard pending == nil, standingRecord() == nil else { throw localApprovalError("Finish or stop the current job/campaign before importing another campaign.") }
        let data = try readPrivateLocalReceipt(url), a = try validateStandingAuthorization(data)
        guard a.source == "explicit_user_session_instruction", a.restart == nil else {
            throw localApprovalError("File import is written-user authority; it cannot claim a microphone event.")
        }
        guard !FileManager.default.fileExists(atPath: standingTerminalURL(a.campaignID).path) else {
            throw localApprovalError("This campaign was stopped or consumed; its authorization cannot replay.")
        }
        let priorPayloadMayBeHeld = standingCanCampaignMayHoldPayload
        try writeStandingExclusive(data, to: standingAuthorizationURL(a.campaignID))
        try saveStanding(.init(schemaVersion: 2, campaignID: a.campaignID, authorizationSHA256: Self.localHash(data),
            state: "active", completedTransfers: 0, verifiedLandings: 0, recoveryAttempts: 0,
            detail: "Standing \(a.scope.canCount)-can authorization ready. Run starts a fresh plan; import does not move the arms.",
            lastJobID: nil, lastJobAppSessionID: nil, creditedJobCounts: [:], possiblePayloadHeld: priorPayloadMayBeHeld,
            targetCanCount: a.scope.canCount, authorizationSource: a.source))
        update("Standing \(a.scope.canCount)-can authorization imported. Run uses fresh context; Stop revokes it.")
    }
    private func endStandingCampaign(_ reason: String, consumed: Bool = false) {
        standingRecovery?.cancel(); standingRecovery = nil; standingRecoveryToken = UUID()
        // Stop must remain durable even if a previous read/progress failure
        // latched the normal grant loader closed. The private state still
        // identifies which campaign to revoke; it never grants authority.
        guard var s = standingRecord() ?? (try? JSONDecoder().decode(StandingState.self,
            from: readPrivateLocalReceipt(standingStateURL))) else {
            _ = unlink(standingStateURL.path); return
        }
        if FileManager.default.fileExists(atPath: standingTerminalURL(s.campaignID).path) { return }
        s.state = consumed ? "consumed" : "revoked"; s.detail = reason
        do {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            try writeStandingExclusive(try e.encode(s), to: standingTerminalURL(s.campaignID))
            try saveStanding(s)
            standingIOFailure = nil
        } catch {
            standingIOFailure = "Campaign ended; its status could not be saved: " + error.localizedDescription
            _ = unlink(standingStateURL.path) // Fail closed across relaunch even if the disk cannot accept a tombstone.
        }
    }
    @nonobjc func pauseStandingLocalCanCampaign(reason: String) {
        precondition(Thread.isMainThread)
        if var s = standingRecord() {
            s.state = "paused"; s.detail = reason
            do { try saveStanding(s) } catch { standingIOFailure = error.localizedDescription }
        }
        cancelCurrentOperation(reason: reason, standingPause: true)
    }
    @nonobjc func scheduleStandingLocalCanCampaignRecovery(reason: ROBStandingCanCampaignRecoveryReason,
        restart: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard pending == nil, var s = standingRecord(), s.completedTransfers < s.canCount,
              s.state != "waiting_for_intervention", !standingMayHoldPayload(s) else { return false }
        guard s.recoveryAttempts < 3 else {
            s.state = "waiting_for_intervention"; s.detail = "Automatic recovery reached its three-attempt limit; intervention is required."
            try? saveStanding(s); update(s.detail); return false
        }
        standingRecovery?.cancel(); standingRecoveryToken = UUID(); let token = standingRecoveryToken
        let delay = [1.0, 3, 7][s.recoveryAttempts]; s.recoveryAttempts += 1
        s.state = "recovering"; s.detail = "Recovering connection/feedback; fresh scene and a new plan are required."
        do { try saveStanding(s) } catch { standingIOFailure = error.localizedDescription; return false }
        let campaign = s.campaignID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.standingRecoveryToken == token, self.pending == nil,
                  let current = self.standingRecord(), current.campaignID == campaign, current.state == "recovering" else { return }
            self.standingRecovery = nil; restart()
        }
        standingRecovery = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        update("Standing can campaign recovering: " + reason.rawValue + "; retry \(s.recoveryAttempts)/3, new plan only.")
        return true
    }
    private func bindStandingCampaign(scope: LocalRecyclingScope, context: @escaping () -> String?) throws -> Bool {
        guard scope.permitsUnmeasuredVisualCalibrationTrial, !scope.nominalEmptyCommissioningStepEnabled,
              !scope.oneDegreeEmptyCalibrationStepEnabled, let p = pending, var s = standingRecord(), s.completedTransfers < s.canCount else { return false }
        guard scope.canCount == s.canCount else {
            throw localApprovalError("The requested count differs from this standing campaign's exact target count.")
        }
        guard !standingMayHoldPayload(s) else {
            throw localApprovalError("A possible payload is held or its state is unknown. Standing authorization remains active; no new empty-can grasp, jaw calibration or parking is admitted without supported release/object-clear evidence.")
        }
        let id = UUID()
        let derived: [String: Any] = ["schemaVersion": 1, "kind": "standing_can_campaign_fresh_job_binding",
            "campaignID": s.campaignID.uuidString, "standingAuthorizationSHA256": s.authorizationSHA256,
            "receiptID": id.uuidString, "appSessionID": localSessionID.uuidString, "pendingID": p.id,
            "scope": scope.object, "boundAtMilliseconds": now().timeIntervalSince1970 * 1000,
            "targetCanCount": s.canCount, "canCount": s.canCount, "remainingTransfers": s.canCount - s.completedTransfers, "registrationVerifiedByApproval": false]
        let bytes = try localCanonical(derived)
        try writeLocalApprovalAudit(derived, name: "standing-job-" + id.uuidString + ".json")
        s.state = "executing"; s.lastJobID = p.id; s.lastJobAppSessionID = localSessionID
        s.detail = "Standing campaign executing a new plan in fresh robot context."
        try saveStanding(s)
        var approval = LocalRecyclingApproval(receiptID: id, receiptSHA256: Self.localHash(bytes), scope: scope,
            beginBefore: now().addingTimeInterval(p.executionLimit), contextIdentity: context, activePendingID: p.id)
        approval.standingCampaignID = s.campaignID
        localRecyclingApproval = approval; pending?.localSessionApprovalID = id
        startTimer(); beginAcceptedOperation(); return true
    }
    @nonobjc func recordLocalCanCampaignTransferProgress(_ completedInCurrentJob: Int, bucketLandingVerified: Bool = false) throws {
        precondition(Thread.isMainThread)
        guard let p = pending, let approval = localRecyclingApproval, let id = approval.standingCampaignID,
              authorizationIsLive(p), var s = standingRecord(), s.campaignID == id,
              (0...approval.scope.canCount).contains(completedInCurrentJob) else { throw localApprovalError("No live standing job for transfer progress.") }
        let prior = s.creditedJobCounts[p.id] ?? 0, delta = completedInCurrentJob - prior
        guard delta >= 0, s.completedTransfers + delta <= s.canCount else { throw localApprovalError("Transfer progress exceeds this campaign's exact target count.") }
        s.completedTransfers += delta; s.creditedJobCounts[p.id] = completedInCurrentJob
        if bucketLandingVerified { s.verifiedLandings = min(s.completedTransfers, s.verifiedLandings + delta) }
        try saveStanding(s)
    }
    /// Persist BEFORE a close can create possession, including an uncertain
    /// empty-hand identification close. Connection loss/crash cannot erase it.
    @nonobjc func markLocalCanCampaignPossiblePayloadHeld() throws {
        precondition(Thread.isMainThread)
        guard let approval = localRecyclingApproval, let campaign = approval.standingCampaignID else { return }
        guard let p = pending, authorizationIsLive(p), var s = standingRecord(), s.campaignID == campaign else {
            throw localApprovalError("No current standing job for possible-payload evidence.")
        }
        s.possiblePayloadHeld = true; s.detail = "Possible payload: a new empty-can job is blocked until supported release/object-clear evidence."
        try saveStanding(s)
    }
    /// Only the native observed-release/verified-empty path calls this; an ACK,
    /// a per-run flag reset, or a new Run is not release evidence.
    @nonobjc func recordLocalCanCampaignSupportedRelease() throws {
        precondition(Thread.isMainThread)
        guard let approval = localRecyclingApproval, let campaign = approval.standingCampaignID else { return }
        guard let p = pending, authorizationIsLive(p), var s = standingRecord(), s.campaignID == campaign else {
            throw localApprovalError("No current standing job for supported release evidence.")
        }
        s.possiblePayloadHeld = false; try saveStanding(s)
    }

    private struct LocalRecyclingScope: Equatable {
        let command: String
        let arm: String
        let canCount: Int
        let summary: String
        let contextIdentity: String
        let permitsUnmeasuredVisualCalibrationTrial: Bool
        let nominalEmptyCommissioningStepEnabled: Bool
        let oneDegreeEmptyCalibrationStepEnabled: Bool
        var object: [String: Any] {
            ["command": command, "arm": arm, "canCount": canCount, "summary": summary,
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
        var standingCampaignID: UUID? = nil
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

    /// Dedicated native callers only. A typed bounded can request does
    /// not create a grant; its exact immutable scope must match a local receipt.
    @nonobjc func requestRecyclingWorkspaceTask(command: String, arm: String, canCount: Int,
        summary: String, contextIdentity: @escaping () -> String?, receiptOnly: Bool,
        permitsUnmeasuredVisualCalibrationTrial: Bool = false,
        nominalEmptyCommissioningStepEnabled: Bool = false,
        oneDegreeEmptyCalibrationStepEnabled: Bool = false,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard (1...8).contains(canCount), ["left", "right"].contains(arm), command == arm + "_recycle_cans",
              !nominalEmptyCommissioningStepEnabled || (receiptOnly && permitsUnmeasuredVisualCalibrationTrial),
              !oneDegreeEmptyCalibrationStepEnabled || (arm == "right" && receiptOnly && permitsUnmeasuredVisualCalibrationTrial),
              !(nominalEmptyCommissioningStepEnabled && oneDegreeEmptyCalibrationStepEnabled),
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.count <= 2048,
              let identity = contextIdentity(), !identity.isEmpty, identity.utf8.count <= 8192 else {
            completion(["status": "rejected", "detail": "A local session approval requires an exact 1...8 can task and a current camera/body/arm context."])
            return
        }
        let scope = LocalRecyclingScope(command: command, arm: arm, canCount: canCount, summary: summary, contextIdentity: identity,
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
        if let id = approval.standingCampaignID, let s = standingRecord(), s.campaignID == id {
            value["standingCampaignID"] = id.uuidString
            value["standingAuthorizationSHA256"] = s.authorizationSHA256
            value["standingRemainingTransfers"] = s.canCount - s.completedTransfers
            value["standingTargetCanCount"] = s.canCount
            value["possiblePayloadHeld"] = standingMayHoldPayload(s)
            value["authorizationSource"] = s.authorizationSource ?? "explicit_user_session_instruction"
        }
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
        value["source"] = approval.standingCampaignID == nil ? "explicit_local_OS_file_import" : "explicit_private_local_standing_authorization"
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
    private struct ControllerStopReceipt {
        let device: UUID, session: UUID, messageID: String, callID: String
        let expiresAtMilliseconds: Int64
    }
    // Volatile, bounded duplicate suppression; a Stop never creates authority.
    private var controllerStopReceipts: [ControllerStopReceipt] = []
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
            if let campaign = approval.standingCampaignID {
                guard let s = standingRecord(), s.campaignID == campaign, s.state == "executing", s.lastJobID == p.id else { return false }
            }
            return true
        }
        if let id = p.armSessionID {
            return armSession.map { $0.id == id && sessionIsFresh($0) } == true
        }
        return p.voiceAuthorized || p.peer.map(peerIsFresh) == true
    }

    private(set) var spokenCanCampaignRestartStatus = "No new can-campaign restart requested."

    private static func isSpokenCanCampaignRestartPhrase(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "^(?:(?:hey )?(?:rob|robbie|robot)[, ]+)?"
        return value.range(of: prefix + "proceed with protections[.!?]*$", options: .regularExpression) != nil
    }

    /// A lexical endpointing hint only, never a grant. Even an unavailable or
    /// consumed intent receives a native no-motion acknowledgement on FINAL.
    func isSpokenCanCampaignRestartCandidate(_ text: String) -> Bool {
        Self.isSpokenCanCampaignRestartPhrase(text)
    }

    private func stoppedCanCampaignRestartIntent() -> StandingState? {
        guard pending == nil, localRecyclingApproval == nil, !armSessionActive,
              let previous = standingRecord(includeTerminal: true), previous.state == "revoked",
              previous.completedTransfers < previous.canCount,
              FileManager.default.fileExists(atPath: standingTerminalURL(previous.campaignID).path) else { return nil }
        return previous
    }

    /// Explicit remaining scope for the new job. A voice restart cannot turn
    /// two delivered cans out of five into permission for five more transfers.
    var spokenCanCampaignRestartTargetCanCount: Int {
        stoppedCanCampaignRestartIntent().map { $0.canCount - $0.completedTransfers } ?? 0
    }

    /// ONLY the clean FINAL on-device microphone delegate may call this. It
    /// records new authority and no motion; Main separately starts a fresh task.
    /// Ordinary spoken approval, model/chat text and private-file import do not
    /// enter this path. The caller must consume each recognition event once.
    func receiveSpokenCanCampaignRestart(_ text: String, targetCanCount: Int) -> Bool {
        precondition(Thread.isMainThread)
        guard Self.isSpokenCanCampaignRestartPhrase(text) else { return false }
        guard let previous = stoppedCanCampaignRestartIntent() else {
            spokenCanCampaignRestartStatus = "No stopped can task is available to restart. No new motion authorized."
            update(spokenCanCampaignRestartStatus); return false
        }
        let remaining = previous.canCount - previous.completedTransfers
        guard (1...8).contains(targetCanCount), targetCanCount == remaining else {
            spokenCanCampaignRestartStatus = "The stopped task has \(remaining) remaining cans. A changed count needs new explicit authorization."
            update(spokenCanCampaignRestartStatus); return false
        }
        do {
            let terminalData = try readPrivateLocalReceipt(standingTerminalURL(previous.campaignID))
            let previousData = try readPrivateLocalReceipt(standingAuthorizationURL(previous.campaignID))
            let oldAuthorization = try validateStandingAuthorization(previousData)
            let id = UUID()
            let restart = SpokenCampaignRestart(schemaVersion: 1, eventID: UUID(), appSessionID: localSessionID,
                previousCampaignID: previous.campaignID, previousAuthorizationSHA256: previous.authorizationSHA256,
                previousTerminalSHA256: Self.localHash(terminalData), previousCompletedTransfers: previous.completedTransfers,
                previousTargetCanCount: previous.canCount, previousPossiblePayloadHeld: standingMayHoldPayload(previous))
            let restartObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restart))
            let value: [String: Any] = ["schemaVersion": 2, "kind": "local_user_standing_can_campaign_authorization",
                "campaignID": id.uuidString, "issuedAtMilliseconds": now().timeIntervalSince1970 * 1000,
                "source": "final_clean_local_microphone", "sourceMessage": text,
                "sourceMessageSHA256": Self.localHash(Data(text.utf8)),
                "additionalUserInstruction": oldAuthorization.additionalUserInstruction,
                "additionalUserInstructionSHA256": oldAuthorization.additionalUserInstructionSHA256,
                "scope": Self.standingScope(canCount: remaining, legacy: false), "restart": restartObject]
            let data = try localCanonical(value)
            _ = try validateStandingAuthorization(data)
            // Never replace/reopen the old authorization or terminal record.
            try writeStandingExclusive(data, to: standingAuthorizationURL(id))
            try saveStanding(.init(schemaVersion: 2, campaignID: id, authorizationSHA256: Self.localHash(data),
                state: "active", completedTransfers: 0, verifiedLandings: 0, recoveryAttempts: 0,
                detail: "New spoken authorization; fresh camera, feedback and plan required. No previous waypoint retained.",
                lastJobID: nil, lastJobAppSessionID: nil, creditedJobCounts: [:],
                possiblePayloadHeld: standingMayHoldPayload(previous), targetCanCount: remaining,
                authorizationSource: "final_clean_local_microphone"))
            standingRecovery?.cancel(); standingRecovery = nil; standingRecoveryToken = UUID()
            spokenCanCampaignRestartStatus = standingMayHoldPayload(previous)
                ? "Approval received for \(remaining) remaining cans. Possible payload remains held or unknown; no new empty grasp until supported object-clear evidence."
                : "Approval received for \(remaining) remaining cans. Fresh scene and a new plan are required."
            update(spokenCanCampaignRestartStatus)
            return true
        } catch {
            spokenCanCampaignRestartStatus = "Can-task restart could not be recorded; no new motion authorized: " + error.localizedDescription
            update(spokenCanCampaignRestartStatus)
            return false
        }
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
                if localRecyclingApproval?.standingCampaignID != nil {
                    pauseStandingLocalCanCampaign(reason: "Current context changed before the standing job started; fresh revalidation required.")
                } else { cancel(reason: "The local recycling approval lost its scope or current context before execution.") }
                return
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
            if let campaign = self.localRecyclingApproval?.standingCampaignID {
                if var s = self.standingRecord(), s.campaignID == campaign {
                    if result["transfer_completed"] as? Bool == true || result["release_visually_verified"] as? Bool == true {
                        s.possiblePayloadHeld = false
                    } else if result["possible_payload_held"] as? Bool == true || result["grasp_attempted"] as? Bool == true {
                        s.possiblePayloadHeld = true
                    }
                    do { try self.saveStanding(s) } catch { self.standingIOFailure = error.localizedDescription }
                }
                if result["transfer_completed"] as? Bool == true {
                    let count = (result["batch_completed"] as? NSNumber)?.intValue ?? 1
                    do { try self.recordLocalCanCampaignTransferProgress(count, bucketLandingVerified: result["placement_verified"] as? Bool == true) }
                    catch { self.standingIOFailure = error.localizedDescription }
                }
                if var s = self.standingRecord(), s.campaignID == campaign {
                    if s.completedTransfers == s.canCount { self.endStandingCampaign("All \(s.canCount) native transfers reported; bucket landing remains separately verified.", consumed: true) }
                    else {
                        s.state = self.standingMayHoldPayload(s) || result["requires_intervention"] as? Bool == true ? "waiting_for_intervention" : "paused"
                        s.detail = self.standingMayHoldPayload(s)
                            ? "Possible payload held: empty-can Run blocked; authorization retained. Supported release/object-clear evidence is required."
                            : result["detail"] as? String ?? "Job ended; a fresh plan is required."
                        do { try self.saveStanding(s) } catch { self.standingIOFailure = error.localizedDescription }
                    }
                }
                self.revokeLocalApproval(reason: "Standing job ended; no old waypoint is retained.")
            } else if let receiptID = p.localSessionApprovalID {
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
        if receiptOnly, let scope = localRecyclingScope, let context = localContextIdentity {
            do { if try bindStandingCampaign(scope: scope, context: context) { return } }
            catch { finish(["status": "blocked", "detail": "Standing authorization could not bind this fresh job: " + error.localizedDescription], state: .failed); return }
        }
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
            update("Awaiting local user-session receipt for the exact recycling job: \(summary)")
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
        if message.kind == .actionRequest, message.action == "stop_motion" {
            return receiveControllerPriorityStop(message, device: device, session: session)
        }
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

    private func receiveControllerPriorityStop(_ message: ROBRobotActionMessage, device: UUID, session: UUID) -> Bool {
        // This is independent of any pending task ID (including locally approved
        // jobs), but not of the authenticated, currently advertised operator.
        guard let peer = peers[device], peer.session == session, peer.sender == message.senderID,
              message.recipientID == senderID, peer.capabilities.contains("stop_motion"),
              (0..<15).contains(now().timeIntervalSince(peer.seen)),
              message.arguments.count == 0, !isExpired(message), let callID = message.callID else { return false }
        let milliseconds = now().timeIntervalSince1970 * 1000
        controllerStopReceipts.removeAll { Double($0.expiresAtMilliseconds) <= milliseconds }
        if controllerStopReceipts.contains(where: {
            $0.device == device && $0.session == session && ($0.messageID == message.messageID || $0.callID == callID)
        }) {
            _ = send?(.actionStatus(callID: callID, state: .rejected, detail: "This controller Stop request was already handled.",
                result: ["status": "rejected_replay"], senderID: senderID, recipientID: peer.sender), device, session)
            return true
        }
        if controllerStopReceipts.count >= 512 { controllerStopReceipts.removeFirst() }
        controllerStopReceipts.append(ControllerStopReceipt(device: device, session: session,
            messageID: message.messageID, callID: callID, expiresAtMilliseconds: message.expiresAtMilliseconds))
        let reason = "Authenticated controller Stop; hold requested."
        cancel(reason: reason)
        // Synchronous revocation/cancellation above must precede the Main-owned
        // global both-arm hold. Notification is not confirmation of hardware hold.
        NotificationCenter.default.post(name: Notification.Name("ROBControllerOperatorPriorityStop"),
            object: self, userInfo: ["reason": reason])
        _ = send?(.actionStatus(callID: callID, state: .accepted, detail: reason,
            result: ["status": "stop_requested", "physical_hold_confirmed": false, "automatic_lowering": false],
            senderID: senderID, recipientID: peer.sender), device, session)
        return true
    }

    func cancel(reason: String) {
        precondition(Thread.isMainThread)
        endStandingCampaign(reason)
        cancelCurrentOperation(reason: reason, standingPause: false)
    }
    private func cancelCurrentOperation(reason: String, standingPause: Bool) {
        armSession = nil
        revokeLocalApproval(reason: reason)
        guard let p = pending else {
            timer?.invalidate(); timer = nil; update(reason); return
        }
        // Clear before callbacks, so cancellation/replayed accepts cannot restart.
        finish(["status": standingPause ? "paused" : "cancelled", "detail": reason,
            "standing_campaign_context_lost": standingPause], state: .cancelled, cancelExecution: p.started != nil)
    }
    private func pauseOrCancelLostOperation(_ reason: String) {
        if localRecyclingApproval?.standingCampaignID != nil { pauseStandingLocalCanCampaign(reason: reason) }
        else { cancel(reason: reason) }
    }

    @nonobjc func tick() {
        precondition(Thread.isMainThread)
        if let approval = localRecyclingApproval,
           approval.contextIdentity() != approval.scope.contextIdentity ||
            (approval.activePendingID == nil && approval.beginBefore <= now()) {
            if approval.standingCampaignID != nil {
                pauseStandingLocalCanCampaign(reason: "Current camera/body/arm context was lost; hold and fresh revalidation required.")
            } else { cancel(reason: "Local recycling approval expired or its camera/body/arm context was lost; hold requested.") }
            return
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
            if !authorizationIsLive(p) { pauseOrCancelLostOperation("Authorized arm operation expired; hold requested.") }
            return
        }
        if let peer = p.peer {
            guard peerIsFresh(peer) else {
                cancel(reason: "The approving controller disconnected; arm hold requested."); return
            }
            if let started = p.started {
                if now().timeIntervalSince(started) > p.executionLimit {
                    pauseOrCancelLostOperation("The approved arm operation timed out; hold requested.")
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
