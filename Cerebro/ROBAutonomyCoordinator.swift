//
//  ROBAutonomyCoordinator.swift
//  Cerebro
//
//  Local, deterministic coordinator for controller-authorized autonomous
//  sessions. Gemini supplies conversation and high-level context; it never
//  writes tread or servo values directly.
//

import Foundation

@objc public protocol ROBAutonomyCoordinatorDelegate: AnyObject {
    func autonomyCoordinator(
        _ coordinator: ROBAutonomyCoordinator,
        applyLeftTread leftTread: Double,
        rightTread: Double,
        speedScale: Double
    )
    func autonomyCoordinatorDidRequestBaseStop(_ coordinator: ROBAutonomyCoordinator)
    func autonomyCoordinator(
        _ coordinator: ROBAutonomyCoordinator,
        publishStatus status: ROBAutonomySessionMessage
    )
    func autonomyCoordinator(
        _ coordinator: ROBAutonomyCoordinator,
        requestConversationPrompt prompt: String
    )
}

@objcMembers public final class ROBAutonomyCoordinator: NSObject {
    public weak var delegate: ROBAutonomyCoordinatorDelegate?
    public private(set) var active = false
    public private(set) var sessionID: String?
    public private(set) var controllerID: String?
    public private(set) var profile: ROBAutonomyProfile = .expressiveStationary

    private struct LidarPoint {
        let distance: Double
        let angle: Double
    }

    private struct LidarSnapshot {
        let x: Double
        let y: Double
        let yaw: Double
        let points: [LidarPoint]
        let receivedAtUptime: TimeInterval
    }

    private enum MotionState: Equatable {
        case silent
        case waitingForLidar
        case forward
        case turningLeft
        case turningRight
        case returningToZone
    }

    private let robotID: String
    private var sequence: UInt64 = 0
    private var expiresAt: Date?
    private var zoneRadiusMeters = 5.0
    private var maximumSpeedScale = 0.2
    private var behaviors: [String] = []
    private var latestLidar: LidarSnapshot?
    private var zoneOrigin: (x: Double, y: Double)?
    private var tickTimer: Timer?
    private var nextWanderChangeUptime: TimeInterval = 0
    private var wanderTurnUntilUptime: TimeInterval = 0
    private var nextConversationUptime: TimeInterval = 0
    private var personVisible = false
    private var motionState: MotionState = .silent
    private var lastPublishedDetail: String?
    private var lastStatusUptime: TimeInterval = 0

    private static let plannerInterval: TimeInterval = 0.2
    private static let lidarFreshness: TimeInterval = 0.75
    private static let obstacleDistanceMeters = 0.8
    private static let frontHalfAngleRadians = 0.48

    public init(robotID: String) {
        self.robotID = robotID
        super.init()
    }

    public func handleSessionMessage(_ message: ROBAutonomySessionMessage) {
        precondition(Thread.isMainThread, "Autonomy session state must be serialized on the main thread")
        guard message.recipientID == nil || message.recipientID == robotID else { return }

        switch message.kind {
        case .start:
            handleStart(message)
        case .stop:
            handleStop(message)
        case .status:
            break
        }
    }

    public func updateLidarPayload(_ payload: String) {
        let lines = payload
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard lines.count >= 3 else { return }

        let position = lines[0].split(separator: ":").compactMap { Double($0) }
        let pose = lines[1].split(separator: ":").compactMap { Double($0) }
        guard position.count >= 2, pose.count >= 1,
              position[0].isFinite, position[1].isFinite, pose[0].isFinite else {
            return
        }

        var points: [LidarPoint] = []
        points.reserveCapacity(lines.count - 2)
        for line in lines.dropFirst(2) {
            let values = line.split(separator: ":").compactMap { Double($0) }
            guard values.count == 2,
                  values[0].isFinite, values[1].isFinite,
                  (0.03 ... 30.0).contains(values[0]),
                  (-Double.pi * 2 ... Double.pi * 2).contains(values[1]) else {
                continue
            }
            points.append(LidarPoint(distance: values[0], angle: values[1]))
        }
        guard points.count >= 8 else { return }

        let snapshot = LidarSnapshot(
            x: position[0],
            y: position[1],
            yaw: pose[0],
            points: points,
            receivedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        latestLidar = snapshot
        ROBSceneSnapshotStore.shared.updateLidarFreeSpace(
            Self.sceneFreeSpace(from: points)
        )
        if active, zoneOrigin == nil {
            zoneOrigin = (snapshot.x, snapshot.y)
        }
    }

    public func updatePersonVisible(_ visible: Bool) {
        personVisible = visible
    }

    private static func sceneFreeSpace(from points: [LidarPoint]) -> [ROBFreeSpaceRegion] {
        let sectors: [(String, Double)] = [("forward", 0), ("left", .pi / 2), ("back", .pi), ("right", -.pi / 2)]
        return sectors.map { name, center in
            let distances = points.compactMap { point -> Double? in
                let delta = atan2(sin(point.angle - center), cos(point.angle - center))
                return abs(delta) <= .pi / 6 ? point.distance : nil
            }
            let minimum = distances.min() ?? 0
            let clearCount = distances.filter { $0 >= obstacleDistanceMeters }.count
            let clearFraction = distances.isEmpty ? 0 : Double(clearCount) / Double(distances.count)
            let confidence = min(1, Double(distances.count) / 12)
            return ROBFreeSpaceRegion(
                id: "lidar-\(name)", direction: name,
                minimumClearanceMeters: minimum, clearFraction: clearFraction,
                traversable: confidence >= 0.25 && minimum >= obstacleDistanceMeters,
                confidence: confidence, source: "rplidar"
            )
        }
    }

    public func stop(reason: String) {
        precondition(Thread.isMainThread, "Autonomy session state must be serialized on the main thread")
        guard active, let sessionID = sessionID, let controllerID = controllerID else {
            delegate?.autonomyCoordinatorDidRequestBaseStop(self)
            return
        }
        let stoppedProfile = profile
        let stoppedRadius = zoneRadiusMeters
        let stoppedSpeed = maximumSpeedScale
        let stoppedBehaviors = behaviors
        let statusSequence = max(sequence, 1)

        active = false
        tickTimer?.invalidate()
        tickTimer = nil
        motionState = .silent
        delegate?.autonomyCoordinatorDidRequestBaseStop(self)

        let status = ROBAutonomySessionMessage.status(
            sessionID: sessionID,
            sequence: statusSequence,
            senderID: robotID,
            recipientID: controllerID,
            profile: stoppedProfile,
            zoneRadiusMeters: stoppedRadius,
            maximumSpeedScale: stoppedSpeed,
            behaviors: stoppedBehaviors,
            state: .inactive,
            expiresAt: nil,
            detail: reason
        )
        delegate?.autonomyCoordinator(self, publishStatus: status)

        self.sessionID = nil
        self.controllerID = nil
        expiresAt = nil
        zoneOrigin = nil
        behaviors = []
    }

    public func shutdown() {
        if active {
            stop(reason: "Cerebro is shutting down")
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
            delegate?.autonomyCoordinatorDidRequestBaseStop(self)
        }
    }

    private func handleStart(_ message: ROBAutonomySessionMessage) {
        if active,
           message.sessionID == sessionID,
           message.senderID == controllerID,
           message.sequence <= sequence {
            publishActiveStatus(force: true)
            return
        }

        guard message.validationError == nil, !message.isExpired else {
            publishUnavailable(for: message, detail: "Autonomy request is invalid or expired")
            return
        }

        if active {
            stop(reason: "Replaced by a newly authorized autonomy session")
        }

        active = true
        sessionID = message.sessionID
        controllerID = message.senderID
        sequence = message.sequence
        expiresAt = Date(timeIntervalSince1970: Double(message.expiresAtMilliseconds) / 1_000)
        profile = message.profile
        zoneRadiusMeters = message.zoneRadiusMeters
        maximumSpeedScale = message.maximumSpeedScale
        behaviors = message.behaviors
        zoneOrigin = nil
        motionState = .silent
        lastPublishedDetail = nil
        lastStatusUptime = 0

        if let latestLidar,
           ProcessInfo.processInfo.systemUptime - latestLidar.receivedAtUptime <= Self.lidarFreshness {
            zoneOrigin = (latestLidar.x, latestLidar.y)
        }

        nextWanderChangeUptime = ProcessInfo.processInfo.systemUptime + 4
        nextConversationUptime = ProcessInfo.processInfo.systemUptime + 15
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: Self.plannerInterval, repeats: true) { [weak self] _ in
            self?.plannerTick()
        }
        publishActiveStatus(force: true)
        plannerTick()
    }

    private func handleStop(_ message: ROBAutonomySessionMessage) {
        guard active,
              message.sessionID == sessionID,
              message.senderID == controllerID else {
            publishInactive(for: message, detail: "No matching autonomy session is active")
            return
        }
        guard message.sequence > sequence else {
            publishActiveStatus(force: true)
            return
        }
        sequence = message.sequence
        stop(reason: message.detail ?? "Stopped by ROBController")
    }

    private func plannerTick() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let expiresAt, Date() >= expiresAt {
            stop(reason: "Autonomy session duration ended")
            return
        }

        if profile == .expressiveStationary || !behaviors.contains("roam") {
            transition(to: .silent, left: nil, right: nil, detail: "Expressive stationary autonomy is active")
            maybeRequestConversation(now: now)
            publishActiveStatus(force: now - lastStatusUptime >= 2)
            return
        }

        guard let lidar = latestLidar,
              now - lidar.receivedAtUptime <= Self.lidarFreshness,
              lidar.points.count >= 8 else {
            transition(
                to: .waitingForLidar,
                left: nil,
                right: nil,
                detail: "Social roam is active and waiting for a fresh RPLidar scan"
            )
            publishActiveStatus(force: now - lastStatusUptime >= 2)
            return
        }

        if zoneOrigin == nil { zoneOrigin = (lidar.x, lidar.y) }
        let origin = zoneOrigin ?? (lidar.x, lidar.y)
        let distanceFromOrigin = hypot(lidar.x - origin.x, lidar.y - origin.y)

        let front = minimumDistance(in: lidar.points) { abs(Self.normalizedAngle($0.angle)) <= Self.frontHalfAngleRadians }
        let left = minimumDistance(in: lidar.points) {
            let angle = Self.normalizedAngle($0.angle)
            return angle > Self.frontHalfAngleRadians && angle < 1.5
        }
        let right = minimumDistance(in: lidar.points) {
            let angle = Self.normalizedAngle($0.angle)
            return angle < -Self.frontHalfAngleRadians && angle > -1.5
        }

        if distanceFromOrigin >= zoneRadiusMeters * 0.82 {
            let targetYaw = atan2(origin.y - lidar.y, origin.x - lidar.x)
            let yawError = Self.normalizedAngle(targetYaw - lidar.yaw)
            if abs(yawError) > 0.35 {
                let turnLeft = yawError > 0
                transition(
                    to: .returningToZone,
                    left: turnLeft ? -0.14 : 0.14,
                    right: turnLeft ? 0.14 : -0.14,
                    detail: "Returning toward the center of the designated area"
                )
            } else {
                transition(
                    to: .forward,
                    left: 0.13,
                    right: 0.13,
                    detail: "Moving toward the center of the designated area"
                )
            }
        } else if front < Self.obstacleDistanceMeters {
            let turnLeft = left > right
            wanderTurnUntilUptime = now + 0.8
            transition(
                to: turnLeft ? .turningLeft : .turningRight,
                left: turnLeft ? -0.13 : 0.13,
                right: turnLeft ? 0.13 : -0.13,
                detail: "Turning around a nearby obstacle"
            )
        } else if now < wanderTurnUntilUptime {
            let turnLeft = motionState == .turningLeft
            transition(
                to: turnLeft ? .turningLeft : .turningRight,
                left: turnLeft ? -0.11 : 0.11,
                right: turnLeft ? 0.11 : -0.11,
                detail: "Changing direction within the designated area"
            )
        } else if now >= nextWanderChangeUptime {
            let turnLeft = Bool.random()
            wanderTurnUntilUptime = now + Double.random(in: 0.45 ... 0.9)
            nextWanderChangeUptime = now + Double.random(in: 5 ... 10)
            transition(
                to: turnLeft ? .turningLeft : .turningRight,
                left: turnLeft ? -0.09 : 0.09,
                right: turnLeft ? 0.09 : -0.09,
                detail: "Making a small organic course change"
            )
        } else {
            transition(
                to: .forward,
                left: 0.12,
                right: 0.12,
                detail: "Roaming within the designated area"
            )
        }

        maybeRequestConversation(now: now)
        publishActiveStatus(force: now - lastStatusUptime >= 2)
    }

    private func transition(
        to newState: MotionState,
        left: Double?,
        right: Double?,
        detail: String
    ) {
        if let left, let right {
            delegate?.autonomyCoordinator(
                self,
                applyLeftTread: left,
                rightTread: right,
                speedScale: maximumSpeedScale
            )
        } else if motionState != newState {
            delegate?.autonomyCoordinatorDidRequestBaseStop(self)
        }
        motionState = newState
        if lastPublishedDetail != detail {
            lastPublishedDetail = detail
            publishActiveStatus(force: true)
        }
    }

    private func maybeRequestConversation(now: TimeInterval) {
        guard behaviors.contains("talk"), now >= nextConversationUptime else { return }
        nextConversationUptime = now + Double.random(in: 45 ... 90)
        let prompt: String
        if personVisible {
            prompt = "Autonomy context: a person is visible. Briefly and naturally greet or engage them using the live camera and audio context."
        } else {
            prompt = "Autonomy context: continue mingling naturally. If nobody is clearly present, make at most one brief friendly observation and then listen."
        }
        delegate?.autonomyCoordinator(self, requestConversationPrompt: prompt)
    }

    private func publishActiveStatus(force: Bool) {
        guard force, active,
              let sessionID = sessionID,
              let controllerID = controllerID else { return }
        lastStatusUptime = ProcessInfo.processInfo.systemUptime
        let status = ROBAutonomySessionMessage.status(
            sessionID: sessionID,
            sequence: max(sequence, 1),
            senderID: robotID,
            recipientID: controllerID,
            profile: profile,
            zoneRadiusMeters: zoneRadiusMeters,
            maximumSpeedScale: maximumSpeedScale,
            behaviors: behaviors,
            state: .active,
            expiresAt: expiresAt,
            detail: lastPublishedDetail ?? "Controller-authorized autonomy is active"
        )
        delegate?.autonomyCoordinator(self, publishStatus: status)
    }

    private func publishUnavailable(for message: ROBAutonomySessionMessage, detail: String) {
        let status = ROBAutonomySessionMessage.status(
            sessionID: message.sessionID,
            sequence: max(message.sequence, 1),
            senderID: robotID,
            recipientID: message.senderID,
            profile: message.profile,
            zoneRadiusMeters: message.zoneRadiusMeters,
            maximumSpeedScale: message.maximumSpeedScale,
            behaviors: message.behaviors,
            state: .unavailable,
            expiresAt: nil,
            detail: detail
        )
        delegate?.autonomyCoordinator(self, publishStatus: status)
    }

    private func publishInactive(for message: ROBAutonomySessionMessage, detail: String) {
        let status = ROBAutonomySessionMessage.status(
            sessionID: message.sessionID,
            sequence: max(message.sequence, 1),
            senderID: robotID,
            recipientID: message.senderID,
            profile: message.profile,
            zoneRadiusMeters: message.zoneRadiusMeters,
            maximumSpeedScale: message.maximumSpeedScale,
            behaviors: message.behaviors,
            state: .inactive,
            expiresAt: nil,
            detail: detail
        )
        delegate?.autonomyCoordinator(self, publishStatus: status)
    }

    private func minimumDistance(
        in points: [LidarPoint],
        where predicate: (LidarPoint) -> Bool
    ) -> Double {
        return points.lazy.filter(predicate).map(\.distance).min() ?? .infinity
    }

    private static func normalizedAngle(_ angle: Double) -> Double {
        return atan2(sin(angle), cos(angle))
    }
}
