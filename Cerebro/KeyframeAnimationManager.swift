//
//  KeyframeAnimationManager.swift
//  Cerebro
//
//  Created by Rob Makina on 9/16/25.
//  Copyright © 2025 Rob Makina. All rights reserved.
//

import AppKit

extension Notification.Name {
    static let ROBAmberGestureCatalogDidChange = Notification.Name("ROBAmberGestureCatalogDidChange")
}

@objcMembers public class KeyframeAnimationManager: NSObject {
    public static var shared: KeyframeAnimationManager = KeyframeAnimationManager()
    
    //Animations are stored in the UserData Directory as codable model files
    @objc public var animations: [KeyframeAnimation] = []
    
    @objc public var currentAnimation: KeyframeAnimation?
    
    public override init() {
        super.init()
        loadAnimations()
    }
    
    public func saveCurrentKeyframeAnimation() {
        guard let currentAnimation = self.currentAnimation else {
            return
        }
        
        let userDataDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let keyframeAnimationsDirectory = userDataDirectoryURL.appendingPathComponent("ROB KeyframeAnimations")
        let newKeyframeAnimationURL = keyframeAnimationsDirectory.appendingPathComponent(currentAnimation.name + ".keyAnim")
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(currentAnimation)
            try data.write(to: newKeyframeAnimationURL)
            //Successfully written to file
        } catch {
            print("error saving KeyframeAnimation")
        }
    }
    
    @objc public func loadAnimations() {
        let userDataDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        let isDirectory:ObjCBool = true
        let keyframeAnimationsDirectory = userDataDirectoryURL.appendingPathComponent("ROB KeyframeAnimations")
        
        if !FileManager.default.fileExists(atPath: keyframeAnimationsDirectory.path) && isDirectory.boolValue {
            do {
                try FileManager.default.createDirectory(at: keyframeAnimationsDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("failed to write to documents directory")
            }
        }
        
        do {
            var keyframeAnimations = try FileManager.default.contentsOfDirectory(atPath: keyframeAnimationsDirectory.path)
            
            //create default animation if it doesn't exist
            if keyframeAnimations.isEmpty || (keyframeAnimations.count == 1 && keyframeAnimations.first == ".DS_Store") {
                //create our first animation here
                let newKeyframeAnimation = KeyframeAnimation(name:"StarWars Droid Battle")
                self.currentAnimation = newKeyframeAnimation
                let newKeyframeAnimationURL = keyframeAnimationsDirectory.appendingPathComponent(newKeyframeAnimation.name + ".keyAnim")
                let encoder = JSONEncoder()
                do {
                    let data = try encoder.encode(newKeyframeAnimation)
                    try data.write(to: newKeyframeAnimationURL)
                    keyframeAnimations = try FileManager.default.contentsOfDirectory(atPath: keyframeAnimationsDirectory.path)
                    //Successfully written to file
                }
            }
            
            for keyframeAnimation in keyframeAnimations {
                guard keyframeAnimation != ".DS_Store" else { continue }
                print("keyframeAnimation \(keyframeAnimation)")
                
                let keyframeAnimationURL = keyframeAnimationsDirectory.appendingPathComponent(keyframeAnimation)
                
                if currentAnimation == nil {
                    //Read it back
                    let savedData = try Data(contentsOf: keyframeAnimationURL)
                    let decoder = JSONDecoder()
                    let decodedInstance = try decoder.decode(KeyframeAnimation.self, from: savedData)
                    print("decodedInstance = \(decodedInstance.name) keyframes = \(decodedInstance.namedSequences) keyframeA: \(decodedInstance.namedSequences.first?.name ?? "noname")")
                    self.currentAnimation = decodedInstance
                }
                
            }
            
        } catch {
            print("Failed to decode keyframes \(error)")
        }
    }
    
    public func addNewNamedKeyframe(name:String) {
        currentAnimation?.addNewNamedKeyframe()
        saveCurrentKeyframeAnimation()
    }

    /// Copies a fresh measured Amber pose into the editable keyframe. UI slider
    /// values are never treated as feedback or as the robot's starting pose.
    @discardableResult
    public func captureCurrentAmberPose(forArm arm: String) -> Bool {
        let normalizedArm = arm.lowercased()
        guard ["left", "right"].contains(normalizedArm) else { return false }
        let telemetry = ROBAmberGatewayClient.shared.telemetry(forArm: normalizedArm)
        guard let telemetry,
              telemetry.effectiveSampleAgeMilliseconds.isFinite,
              telemetry.effectiveSampleAgeMilliseconds <= 250,
              telemetry.positionsRadians.count == 7 else { return false }
        let positions = telemetry.positionsRadians.map(\.doubleValue)
        guard positions.allSatisfy(\.isFinite), let keyframe = currentAnimation?.currentKeyframe else {
            return false
        }
        if normalizedArm == "left" {
            keyframe.arm_L10_keyframe = true
            keyframe.arm_L10_servo1 = positions[0]
            keyframe.arm_L10_servo2 = positions[1]
            keyframe.arm_L10_servo3 = positions[2]
            keyframe.arm_L10_servo4 = positions[3]
            keyframe.arm_L10_servo5 = positions[4]
            keyframe.arm_L10_servo6 = positions[5]
            keyframe.arm_L10_servo7 = positions[6]
        } else {
            keyframe.arm_R11_keyframe = true
            keyframe.arm_R11_servo1 = positions[0]
            keyframe.arm_R11_servo2 = positions[1]
            keyframe.arm_R11_servo3 = positions[2]
            keyframe.arm_R11_servo4 = positions[3]
            keyframe.arm_R11_servo5 = positions[4]
            keyframe.arm_R11_servo6 = positions[5]
            keyframe.arm_R11_servo7 = positions[6]
        }
        return true
    }
    
}

private struct ROBAmberApprovedArmTarget: Codable {
    let positionsRadians: [Double]
    let durationSeconds: Double
}

private struct ROBAmberApprovedGesture: Codable {
    let name: String
    let sourceKeyframeID: UUID
    let approvedAt: Date
    let left: ROBAmberApprovedArmTarget?
    let right: ROBAmberApprovedArmTarget?
}

/// Stores immutable copies of operator-approved keyframes. Editing a keyframe
/// after approval cannot silently change what Gemini is allowed to execute;
/// the operator must explicitly approve the edited pose again.
@objcMembers public final class ROBAmberGestureCatalog: NSObject {
    public static let shared = ROBAmberGestureCatalog()

    private static let defaultsKey = "ROBAmberApprovedGestureCatalog.v1"
    private let lock = NSLock()
    private var gestures: [String: ROBAmberApprovedGesture] = [:]

    public override init() {
        super.init()
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(
                [String: ROBAmberApprovedGesture].self,
                from: data
              ) else { return }
        gestures = decoded
    }

    public var approvedGestureNames: [String] {
        lock.withLock { gestures.values.map(\.name).sorted() }
    }

    /// Captures the currently edited keyframe under a human-readable tool
    /// name. At least one arm must be enabled in the keyframe.
    public func approveCurrentKeyframe(as proposedName: String) throws {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else {
            throw CatalogError.invalidName
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " ._-")
        )
        guard name.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw CatalogError.invalidName
        }
        guard let keyframe = KeyframeAnimationManager.shared.currentAnimation?.currentKeyframe else {
            throw CatalogError.missingKeyframe
        }

        let left = try keyframe.arm_L10_keyframe
            ? validatedTarget(
                positions: [
                    keyframe.arm_L10_servo1, keyframe.arm_L10_servo2,
                    keyframe.arm_L10_servo3, keyframe.arm_L10_servo4,
                    keyframe.arm_L10_servo5, keyframe.arm_L10_servo6,
                    keyframe.arm_L10_servo7,
                ],
                duration: keyframe.arm_L10_cmd_time,
                arm: "left"
            ) : nil
        let right = try keyframe.arm_R11_keyframe
            ? validatedTarget(
                positions: [
                    keyframe.arm_R11_servo1, keyframe.arm_R11_servo2,
                    keyframe.arm_R11_servo3, keyframe.arm_R11_servo4,
                    keyframe.arm_R11_servo5, keyframe.arm_R11_servo6,
                    keyframe.arm_R11_servo7,
                ],
                duration: keyframe.arm_R11_cmd_time,
                arm: "right"
            ) : nil
        guard left != nil || right != nil else {
            throw CatalogError.noArmTargets
        }

        let gesture = ROBAmberApprovedGesture(
            name: name,
            sourceKeyframeID: keyframe.uuid,
            approvedAt: Date(),
            left: left,
            right: right
        )
        lock.withLock {
            gestures[normalized(name)] = gesture
            if let data = try? JSONEncoder().encode(gestures) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
        NotificationCenter.default.post(name: .ROBAmberGestureCatalogDidChange, object: self)
    }

    public func revokeGesture(named name: String) {
        lock.withLock {
            gestures.removeValue(forKey: normalized(name))
            if let data = try? JSONEncoder().encode(gestures) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
        NotificationCenter.default.post(name: .ROBAmberGestureCatalogDidChange, object: self)
    }

    public func removeAllGestures() {
        lock.withLock {
            gestures.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: .ROBAmberGestureCatalogDidChange, object: self)
    }

    public func detailsForGesture(named name: String) -> NSDictionary? {
        guard let gesture = snapshot(named: name) else { return nil }
        return [
            "name": gesture.name,
            "sourceKeyframeID": gesture.sourceKeyframeID.uuidString,
            "approvedAt": gesture.approvedAt,
            "arms": [gesture.left == nil ? nil : "left", gesture.right == nil ? nil : "right"]
                .compactMap { $0 },
        ]
    }

    fileprivate func snapshot(named name: String) -> ROBAmberApprovedGesture? {
        lock.withLock { gestures[normalized(name)] }
    }

    private func validatedTarget(
        positions: [Double],
        duration: Double,
        arm: String
    ) throws -> ROBAmberApprovedArmTarget {
        guard positions.count == ROBAmberB1Kinematics.joints.count,
              positions.allSatisfy(\.isFinite) else {
            throw CatalogError.invalidPositions(arm)
        }
        for (position, joint) in zip(positions, ROBAmberB1Kinematics.joints)
        where !(joint.lowerLimit ... joint.upperLimit).contains(position) {
            throw CatalogError.jointLimit(arm, joint.name)
        }
        guard duration.isFinite, (0.65 ... 10).contains(duration) else {
            throw CatalogError.invalidDuration(arm)
        }
        return ROBAmberApprovedArmTarget(
            positionsRadians: positions,
            durationSeconds: duration
        )
    }

    private func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    public enum CatalogError: LocalizedError {
        case invalidName
        case missingKeyframe
        case noArmTargets
        case invalidPositions(String)
        case invalidDuration(String)
        case jointLimit(String, String)

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Use a gesture name of 1–64 letters, numbers, spaces, periods, underscores, or hyphens."
            case .missingKeyframe:
                return "There is no current keyframe to approve."
            case .noArmTargets:
                return "Enable at least one Amber arm in the current keyframe first."
            case .invalidPositions(let arm):
                return "The \(arm) keyframe does not contain seven finite joint positions."
            case .invalidDuration(let arm):
                return "The \(arm) keyframe duration must be between 0.65 and 10 seconds."
            case .jointLimit(let arm, let joint):
                return "The \(arm) \(joint) value exceeds the calibrated B1 joint limit."
            }
        }
    }
}

private enum ROBAmberGestureAuthoritySource {
    case geminiDebug
    case controllerApprovedOneShot

    var requiresGeminiDebugAuthority: Bool {
        self == .geminiDebug
    }
}

private final class ROBAmberGestureRun {
    let ownerID: UUID
    let gesture: ROBAmberApprovedGesture
    let targets: [String: ROBAmberApprovedArmTarget]
    let reservedArms: [ROBArmSide]
    let authoritySource: ROBAmberGestureAuthoritySource
    let completion: (NSDictionary) -> Void
    let startedAt = Date()
    let deadline: Date
    var commandArms: [UInt64: String] = [:]
    var acknowledgedCommands: Set<UInt64> = []
    var renewalCommandArms: [UInt64: String] = [:]
    var lastLeaseRenewalUptime = ProcessInfo.processInfo.systemUptime
    var lastEvaluatedTelemetrySequences: [String: UInt64] = [:]
    var consecutiveSettledSamples = 0
    var largestObservedError = 0.0

    init(
        ownerID: UUID,
        gesture: ROBAmberApprovedGesture,
        targets: [String: ROBAmberApprovedArmTarget],
        reservedArms: [ROBArmSide],
        authoritySource: ROBAmberGestureAuthoritySource,
        completion: @escaping (NSDictionary) -> Void
    ) {
        self.ownerID = ownerID
        self.gesture = gesture
        self.targets = targets
        self.reservedArms = reservedArms
        self.authoritySource = authoritySource
        self.completion = completion
        let longestMove = targets.values.map(\.durationSeconds).max() ?? 0.65
        deadline = Date(timeIntervalSinceNow: longestMove + 4.0)
    }
}

/// Executes only immutable named poses copied into ROBAmberGestureCatalog.
/// Gemini never supplies joint values. Both the Gemini-debug and controller-
/// approved one-shot lanes deliberately limit each joint to a small step and
/// verify the physical outcome using measured telemetry before completion.
@objcMembers public final class ROBAmberGestureExecutor: NSObject {
    public static let shared = ROBAmberGestureExecutor()

    private static let maximumStepRadians = 0.35
    private static let maximumAverageSpeedRadiansPerSecond = 0.25
    private static let positionToleranceRadians = 0.06
    private static let velocityToleranceRadiansPerSecond = 0.12
    private static let requiredSettledSamples = 3
    private static let gatewayLeaseMilliseconds: UInt32 = 1_500
    private static let gatewayLeaseRenewalInterval: TimeInterval = 0.5
    private var run: ROBAmberGestureRun?
    private var monitor: Timer?
    private var commandObserver: NSObjectProtocol?
    private var gatewayStateObserver: NSObjectProtocol?
    private var authorityObserver: NSObjectProtocol?

    public private(set) var isExecuting = false
    public private(set) var currentGestureName: String?

    public override init() {
        super.init()
        commandObserver = NotificationCenter.default.addObserver(
            forName: .ROBAmberGatewayCommandDidComplete,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            self?.commandCompleted(notification)
        }
        gatewayStateObserver = NotificationCenter.default.addObserver(
            forName: .ROBAmberGatewayStateDidChange,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            self?.gatewayStateChanged(notification)
        }
        authorityObserver = NotificationCenter.default.addObserver(
            forName: .ROBAmberDebugAuthorityDidChange,
            object: ROBAmberDebugAuthority.shared,
            queue: .main
        ) { [weak self] _ in
            self?.debugAuthorityChanged()
        }
    }

    deinit {
        if let commandObserver { NotificationCenter.default.removeObserver(commandObserver) }
        if let gatewayStateObserver {
            NotificationCenter.default.removeObserver(gatewayStateObserver)
        }
        if let authorityObserver {
            NotificationCenter.default.removeObserver(authorityObserver)
        }
        monitor?.invalidate()
    }

    public func executeApprovedGesture(
        _ name: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        executeGesture(
            name,
            authoritySource: .geminiDebug,
            completion: completion
        )
    }

    /// Executes exactly one immutable locally approved gesture after the remote
    /// operator has explicitly approved the corresponding action request. This
    /// authority is carried only by this invocation; it does not enable the
    /// broader Gemini debug grant or persist beyond the resulting run.
    @objc(executeControllerApprovedGesture:completion:)
    public func executeControllerApprovedGesture(
        _ name: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        executeGesture(
            name,
            authoritySource: .controllerApprovedOneShot,
            completion: completion
        )
    }

    private func executeGesture(
        _ name: String,
        authoritySource: ROBAmberGestureAuthoritySource,
        completion: @escaping (NSDictionary) -> Void
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.executeGesture(
                    name,
                    authoritySource: authoritySource,
                    completion: completion
                )
            }
            return
        }
        guard run == nil else {
            completion([
                "status": "rejected",
                "detail": "Another Amber gesture is already executing.",
            ])
            return
        }
        guard !authoritySource.requiresGeminiDebugAuthority
                || ROBAmberDebugAuthority.shared.authorizesGemini() else {
            completion([
                "status": "rejected",
                "detail": "Enable the short-lived Gemini Arm Debug Authority in Amber Diagnostics first.",
            ])
            return
        }
        guard ROBAmberGatewayClient.shared.isReady() else {
            completion([
                "status": "failed",
                "detail": "The authenticated Amber gateway is not ready.",
            ])
            return
        }
        guard let gesture = ROBAmberGestureCatalog.shared.snapshot(named: name) else {
            let names = ROBAmberGestureCatalog.shared.approvedGestureNames
            completion([
                "status": "rejected",
                "detail": names.isEmpty
                    ? "No immutable Amber gestures have been approved locally."
                    : "Gesture is not approved. Available names: \(names.joined(separator: ", ")).",
            ])
            return
        }

        var targets: [String: ROBAmberApprovedArmTarget] = [:]
        if let left = gesture.left { targets["left"] = left }
        if let right = gesture.right { targets["right"] = right }
        for (arm, target) in targets {
            guard let rejection = validateStart(arm: arm, target: target) else { continue }
            completion(["status": "rejected", "detail": rejection])
            return
        }

        let ownerID = UUID()
        var reservedArms: [ROBArmSide] = []
        for armName in targets.keys.sorted() {
            guard let arm = ROBArmSide(rawValue: armName),
                  ROBAmberArmMotionArbiter.shared.reserve(arm, owner: ownerID) else {
                for reserved in reservedArms {
                    ROBAmberArmMotionArbiter.shared.release(reserved, owner: ownerID)
                }
                completion([
                    "status": "rejected",
                    "detail": "The \(armName) arm is already owned by another supervised motion session.",
                ])
                return
            }
            reservedArms.append(arm)
        }

        let newRun = ROBAmberGestureRun(
            ownerID: ownerID,
            gesture: gesture,
            targets: targets,
            reservedArms: reservedArms,
            authoritySource: authoritySource,
            completion: completion
        )
        run = newRun
        isExecuting = true
        currentGestureName = gesture.name
        for arm in targets.keys.sorted() {
            guard let target = targets[arm] else { continue }
            guard !authoritySource.requiresGeminiDebugAuthority
                    || ROBAmberDebugAuthority.shared.authorizesGemini() else {
                finish([
                    "status": "cancelled",
                    "detail": "Gemini Arm Debug Authority expired or was revoked before the \(arm) trajectory was transmitted.",
                ], requestHold: true)
                return
            }
            let commandID = ROBAmberGatewayClient.shared.sendLeasedTrajectory(
                arm: arm,
                positionsRadians: target.positionsRadians.map(NSNumber.init(value:)),
                duration: target.durationSeconds,
                leaseMilliseconds: Self.gatewayLeaseMilliseconds
            )
            guard commandID != 0 else {
                finish([
                    "status": "failed",
                    "detail": "Cerebro refused the bounded \(arm) trajectory before transmission.",
                ], requestHold: true)
                return
            }
            newRun.commandArms[commandID] = arm
        }

        monitor?.invalidate()
        let monitor = Timer(
            timeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in
            self?.samplePhysicalCompletion()
        }
        self.monitor = monitor
        // Safety supervision must continue while AppKit is tracking menus or
        // running another modal event loop.
        RunLoop.main.add(monitor, forMode: .common)
    }

    /// Cancels the active gesture and holds only the arms reserved by that run.
    /// A concurrent owner of the other arm must not be interrupted. True global
    /// stop, shutdown, and emergency-stop lanes use `requestPriorityHold()`.
    public func cancelCurrentGesture(reason: String) -> NSDictionary {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { cancelCurrentGesture(reason: reason) }
        }
        let gestureName = currentGestureName
        let current = run
        let holds = current.map { sendHoldRequests(for: $0.reservedArms) } ?? [:]
        if let current {
            monitor?.invalidate()
            monitor = nil
            run = nil
            isExecuting = false
            currentGestureName = nil
            releaseReservations(for: current)
            current.completion([
                "status": "cancelled",
                "gesture": current.gesture.name,
                "detail": reason,
                "hold_command_ids": holds,
            ])
        }
        return [
            "gesture": gestureName ?? "",
            "hold_command_ids": holds,
            "arm_status": holds.isEmpty ? "no_position_mode_arm" : "hold_requested",
        ]
    }

    public func requestPriorityHold() -> NSDictionary {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { requestPriorityHold() }
        }
        let holds = sendGlobalHoldRequests()
        return [
            "hold_command_ids": holds,
            "arm_status": holds.isEmpty ? "no_position_mode_arm" : "hold_requested",
        ]
    }

    private func validateStart(
        arm: String,
        target: ROBAmberApprovedArmTarget
    ) -> String? {
        let client = ROBAmberGatewayClient.shared
        guard let telemetry = client.telemetry(forArm: arm),
              telemetry.sequence > 0,
              telemetry.effectiveSampleAgeMilliseconds.isFinite,
              (0 ... 250).contains(telemetry.effectiveSampleAgeMilliseconds),
              telemetry.positionsRadians.count == 7 else {
            return "The \(arm) arm does not have fresh measured telemetry."
        }
        let modes = client.modes(forArm: arm).map(\.intValue)
        guard modes.count == 7, modes.allSatisfy({ $0 == 2 }) else {
            return "The \(arm) arm is not verified in position mode."
        }
        let measured = telemetry.positionsRadians.map(\.doubleValue)
        let deltas = zip(measured, target.positionsRadians).map { abs($0 - $1) }
        guard let largestDelta = deltas.max(),
              largestDelta <= Self.maximumStepRadians else {
            return "The \(arm) gesture exceeds the supervised \(Self.maximumStepRadians)-radian single-step limit. Move through a closer approved pose first."
        }
        let averageSpeeds = deltas.map { $0 / target.durationSeconds }
        guard averageSpeeds.allSatisfy({
            $0 <= Self.maximumAverageSpeedRadiansPerSecond
        }) else {
            return "The \(arm) gesture is too fast for supervised debug mode. Increase its keyframe duration."
        }
        return nil
    }

    private func commandCompleted(_ notification: Notification) {
        let commandID: UInt64?
        if let value = notification.userInfo?["commandID"] as? UInt64 {
            commandID = value
        } else {
            commandID = (notification.userInfo?["commandID"] as? NSNumber)?.uint64Value
        }
        guard let current = run,
              let operation = notification.userInfo?["operation"] as? String,
              let commandID else { return }
        if operation == "renew_lease",
           let arm = current.renewalCommandArms.removeValue(forKey: commandID) {
            guard notification.userInfo?["accepted"] as? Bool == true else {
                let error = notification.userInfo?["error"] as? String
                    ?? "Gateway rejected lease renewal."
                finish([
                    "status": "failed",
                    "detail": "The \(arm) safety lease could not be renewed: \(error)",
                ], requestHold: true)
                return
            }
            return
        }
        guard operation == "leased_trajectory",
              let arm = current.commandArms[commandID] else { return }
        guard notification.userInfo?["accepted"] as? Bool == true else {
            let error = notification.userInfo?["error"] as? String ?? "Amber rejected the request."
            finish([
                "status": "failed",
                "detail": "The \(arm) trajectory was rejected: \(error)",
            ], requestHold: true)
            return
        }
        current.acknowledgedCommands.insert(commandID)
    }

    /// Command IDs and acknowledgements are scoped to one authenticated TCP
    /// session. Latch every transition away from ready so a rapid reconnect
    /// cannot make an old run observe a new session whose command IDs restarted.
    private func gatewayStateChanged(_ notification: Notification) {
        let rawState: Int?
        if let value = notification.userInfo?["state"] as? Int {
            rawState = value
        } else {
            rawState = (notification.userInfo?["state"] as? NSNumber)?.intValue
        }
        guard rawState != ROBAmberGatewayState.ready.rawValue, run != nil else { return }
        let detail = notification.userInfo?["detail"] as? String
            ?? "Amber gateway session ended"
        finish([
            "status": "failed",
            "detail": "Amber gateway session changed before physical completion could be verified: \(detail)",
        ], requestHold: true)
    }

    private func debugAuthorityChanged() {
        guard run?.authoritySource.requiresGeminiDebugAuthority == true,
              !ROBAmberDebugAuthority.shared.authorizesGemini() else { return }
        finish([
            "status": "cancelled",
            "detail": "Gemini Arm Debug Authority was revoked during the gesture.",
        ], requestHold: true)
    }

    private func samplePhysicalCompletion() {
        guard let current = run else { return }
        guard !current.authoritySource.requiresGeminiDebugAuthority
                || ROBAmberDebugAuthority.shared.authorizesGemini() else {
            finish([
                "status": "cancelled",
                "detail": "Gemini Arm Debug Authority expired or was revoked during the gesture.",
            ], requestHold: true)
            return
        }
        guard ROBAmberGatewayClient.shared.isReady() else {
            finish([
                "status": "failed",
                "detail": "Amber gateway disconnected before physical completion could be verified.",
            ])
            return
        }
        if Date() > current.deadline {
            finish([
                "status": "failed",
                "detail": "Timed out waiting for measured arm position and velocity to settle.",
                "maximum_tracking_error_rad": current.largestObservedError,
            ], requestHold: true)
            return
        }
        guard renewGatewayLeasesIfNeeded(for: current) else { return }
        guard current.acknowledgedCommands.count == current.commandArms.count else { return }

        for arm in current.targets.keys {
            let modes = ROBAmberGatewayClient.shared.modes(forArm: arm).map(\.intValue)
            guard modes.count == 7, modes.allSatisfy({ $0 == 2 }) else {
                finish([
                    "status": "failed",
                    "detail": "The \(arm) arm left verified position mode before physical completion.",
                ], requestHold: true)
                return
            }
        }

        var allSettled = true
        var currentMaximumError = 0.0
        var observedSequences: [String: UInt64] = [:]
        for (arm, target) in current.targets {
            guard let telemetry = ROBAmberGatewayClient.shared.telemetry(forArm: arm),
                  telemetry.sequence > 0,
                  telemetry.effectiveSampleAgeMilliseconds.isFinite,
                  (0 ... 250).contains(telemetry.effectiveSampleAgeMilliseconds),
                  telemetry.positionsRadians.count == 7,
                  telemetry.velocitiesRadiansPerSecond.count == 7,
                  telemetry.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
                  telemetry.velocitiesRadiansPerSecond.allSatisfy({
                      $0.doubleValue.isFinite
                  }) else {
                allSettled = false
                continue
            }
            // The 50 ms monitor may fire twice between gateway deliveries.
            // Waiting for the next sequence must not erase already accumulated
            // settled evidence or count the same physical sample twice.
            if current.lastEvaluatedTelemetrySequences[arm] == telemetry.sequence {
                return
            }
            observedSequences[arm] = telemetry.sequence
            let errors = zip(
                telemetry.positionsRadians.map(\.doubleValue),
                target.positionsRadians
            ).map { abs($0 - $1) }
            let velocities = telemetry.velocitiesRadiansPerSecond.map { abs($0.doubleValue) }
            currentMaximumError = max(currentMaximumError, errors.max() ?? .infinity)
            if !errors.allSatisfy({ $0 <= Self.positionToleranceRadians }) ||
                !velocities.allSatisfy({
                    $0 <= Self.velocityToleranceRadiansPerSecond
                }) {
                allSettled = false
            }
        }
        // A timer tick is not a physical sample. Count a settled round only
        // when every target arm supplied a distinct, fresh telemetry sequence.
        guard observedSequences.count == current.targets.count else {
            current.consecutiveSettledSamples = 0
            return
        }
        current.lastEvaluatedTelemetrySequences.merge(
            observedSequences,
            uniquingKeysWith: { _, new in new }
        )
        current.largestObservedError = max(
            current.largestObservedError,
            currentMaximumError
        )
        current.consecutiveSettledSamples = allSettled
            ? current.consecutiveSettledSamples + 1 : 0
        guard current.consecutiveSettledSamples >= Self.requiredSettledSamples else { return }
        finish([
            "status": "completed",
            "gesture": current.gesture.name,
            "arms": current.targets.keys.sorted(),
            "measured": true,
            "maximum_tracking_error_rad": currentMaximumError,
            "elapsed_seconds": Date().timeIntervalSince(current.startedAt),
        ])
    }

    @discardableResult
    private func renewGatewayLeasesIfNeeded(for current: ROBAmberGestureRun) -> Bool {
        guard current.acknowledgedCommands.count == current.commandArms.count else { return true }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - current.lastLeaseRenewalUptime
                >= Self.gatewayLeaseRenewalInterval else { return true }
        let pendingArms = Set(current.renewalCommandArms.values)
        for arm in current.targets.keys.sorted() where !pendingArms.contains(arm) {
            let commandID = ROBAmberGatewayClient.shared.renewLease(
                forArm: arm,
                leaseMilliseconds: Self.gatewayLeaseMilliseconds
            )
            guard commandID != 0 else {
                finish([
                    "status": "failed",
                    "detail": "Cerebro could not renew the \(arm) gateway safety lease.",
                ], requestHold: true)
                return false
            }
            current.renewalCommandArms[commandID] = arm
        }
        current.lastLeaseRenewalUptime = uptime
        return true
    }

    private func finish(_ result: NSDictionary, requestHold: Bool = false) {
        guard let current = run else { return }
        if requestHold { _ = sendHoldRequests(for: current.reservedArms) }
        monitor?.invalidate()
        monitor = nil
        run = nil
        isExecuting = false
        currentGestureName = nil
        releaseReservations(for: current)
        current.completion(result)
    }

    private func releaseReservations(for run: ROBAmberGestureRun) {
        for arm in run.reservedArms {
            ROBAmberArmMotionArbiter.shared.release(arm, owner: run.ownerID)
        }
    }

    /// Explicit global safety lane. Unlike gesture cleanup, this intentionally
    /// considers every arm already verified in position mode.
    private func sendGlobalHoldRequests() -> [String: NSNumber] {
        sendHoldRequests(for: ROBArmSide.allCases)
    }

    /// Automatic gesture cleanup is isolated to the arms reserved by that run.
    /// Mode verification still prevents this path from activating an arm.
    private func sendHoldRequests(for arms: [ROBArmSide]) -> [String: NSNumber] {
        let client = ROBAmberGatewayClient.shared
        guard client.isReady() else { return [:] }
        var commands: [String: NSNumber] = [:]
        for arm in arms {
            let armName = arm.rawValue
            let modes = client.modes(forArm: armName).map(\.intValue)
            guard modes.count == 7, modes.allSatisfy({ $0 == 2 }) else { continue }
            let commandID = client.priorityHold(forArm: armName)
            if commandID != 0 { commands[armName] = NSNumber(value: commandID) }
        }
        return commands
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}


@objcMembers public class KeyframeAnimation: NSObject, Codable {
    public var name: String = "Keyframe Animation"
    
    public var namedKeyframes: [Keyframe] = []
    public var namedSequences: [KeyframeSequence] = []
    public var keyframeDict: [String: Keyframe] = [:]
    public var currentKeyframe: Keyframe = Keyframe(name: UUID().uuidString)
    public var currentSequence: KeyframeSequence = KeyframeSequence()
    
    init(name: String, namedKeyframes: [Keyframe]) {
        self.name = name
        self.namedKeyframes = namedKeyframes
    }
    
    convenience init(name: String) {
        self.init()
        self.name = name
        self.namedSequences = []
    }
    
    public override init() {}
    
    public func addNewNamedKeyframe() {
        keyframeDict[currentKeyframe.name] = currentKeyframe
        namedKeyframes.append(currentKeyframe)
        currentKeyframe = Keyframe(name: UUID().uuidString)
    }
    
    public func addNewNamedSequence() {
        let newSequence = KeyframeSequence()
        namedSequences.append(newSequence)
        currentSequence = newSequence
    }
    
    public func removeNamedKeyframe(name: String) {
        keyframeDict[name] = nil
        namedKeyframes.removeAll { $0.name == name }
        if currentKeyframe.name == name {
            currentKeyframe = namedKeyframes.last ?? Keyframe(name: UUID().uuidString)
        }
    }
    
    public func appendCurrentKeyframeToSequence() {
        currentSequence.appendKeyframe(currentKeyframe)
    }
    
    public func addKeyframeToCurrentSequence(_ keyframe: Keyframe) {
        currentSequence.appendKeyframe(keyframe)
    }
    
    public func removeSequenceKeyframe(index: Int) {
        currentSequence.keyframes.remove(at: index)
    }
    
    public func removeSequence(index: Int) {
        namedSequences.remove(at: index)
    }
}

@objcMembers public class KeyframeSequence: NSObject, Codable {
    public var name: String = "sequence"
    public var uuid: UUID = UUID()
    public var keyframes: [Keyframe] = []
    
    func appendKeyframe(_ keyframe: Keyframe) {
        keyframes.append(keyframe)
    }
}

@objcMembers public class Keyframe: NSObject, Codable {
    public var name: String = "keyframe"
    public var uuid: UUID = UUID()
    public var arm_R11_keyframe: Bool = false
    public var arm_R11_cmd_sleep: Double = 0
    public var arm_R11_cmd_time: Double = 2
    public var arm_R11_servo1: Double = 0
    public var arm_R11_servo2: Double = 0
    public var arm_R11_servo3: Double = 0
    public var arm_R11_servo4: Double = 0
    public var arm_R11_servo5: Double = 0
    public var arm_R11_servo6: Double = 0
    public var arm_R11_servo7: Double = 0
    
    public var arm_L10_keyframe: Bool = false
    public var arm_L10_cmd_sleep: Double = 0
    public var arm_L10_cmd_time: Double = 2
    public var arm_L10_servo1: Double = 0
    public var arm_L10_servo2: Double = 0
    public var arm_L10_servo3: Double = 0
    public var arm_L10_servo4: Double = 0
    public var arm_L10_servo5: Double = 0
    public var arm_L10_servo6: Double = 0
    public var arm_L10_servo7: Double = 0
    
    public var head_keyframe: Bool = false
    public var head_upperNeck: Double = 0
    public var head_lowerNeck: Double = 0
    public var head_neckRotation: Double = 0
    
    public var tread_movement_keyframe: Bool = false
    public var tread_movement_cmd_time: Double = 0
    public var treadR: Double = 0
    public var treadL: Double = 0
    
    public var flipper_keyframe: Bool = false
    public var flipper: Double = 0
    
    public var LACT_keyframe: Bool = false
    public var LACT_cmd_time: Double = 0
    public var LACT: Double = 0
    
    public var torsoRotation_keyframe: Bool = false
    public var torsoRotation_speed: Double = 0
    public var torsoRotation_finalPosition: Double = 0
    
    public var speechDialog_keyframe: Bool = false
    public var speech_dialog: String = ""
    public var speech_language: String = ""
    public var speech_volume: Double = 0
    public var speech_rate: Double = 0
    public var speech_pitchMultiplier: Double = 0
    
    init(name: String) {
        self.name = name
    }
    
    public override init() {}
}
