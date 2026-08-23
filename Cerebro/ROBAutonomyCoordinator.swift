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
        case followingSidewalk
        case navigating
    }

    private let robotID: String
    private var sequence: UInt64 = 0
    private var expiresAt: Date?
    private var zoneRadiusMeters = 5.0
    private var maximumSpeedScale = 0.2
    private var behaviors: [String] = []
    private var destination: (latitude: Double, longitude: Double, name: String?)?
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
    private var lastGreetedTimes: [String: TimeInterval] = [:]

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

    public func updateLidarScanData(_ data: Data) {
        precondition(Thread.isMainThread, "Lidar state must be serialized on the main thread")
        guard let frame = try? ROBLidarScanFrame.decode(data) else { return }
        let points = frame.points.map {
            LidarPoint(distance: Double($0.distanceMeters), angle: Double($0.angleRadians))
        }

        let snapshot = LidarSnapshot(
            x: Double(frame.x),
            y: Double(frame.y),
            yaw: Double(frame.yaw),
            points: points,
            receivedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        latestLidar = snapshot
        ROBRecordingCoordinator.shared.recordLidarScanData(
            data,
            x: snapshot.x,
            y: snapshot.y,
            yaw: snapshot.yaw,
            receivedAtUptime: snapshot.receivedAtUptime,
            pointCount: snapshot.points.count
        )
        ROBNavigationRuntime.shared.updateLocalPose(
            x: snapshot.x,
            y: snapshot.y,
            yaw: snapshot.yaw,
            receivedAtUptime: snapshot.receivedAtUptime
        )
        ROBTraversabilityRuntime.shared.updateLocalPose(
            x: snapshot.x,
            y: snapshot.y,
            yaw: snapshot.yaw,
            receivedAtUptime: snapshot.receivedAtUptime
        )
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
        let stoppedDestination = destination
        let statusSequence = max(sequence, 1)

        active = false
        ROBTraversabilityRuntime.shared.setAutonomousMotionActive(false)
        ROBNavigationRuntime.shared.clear()
        tickTimer?.invalidate()
        tickTimer = nil
        motionState = .silent
        delegate?.autonomyCoordinatorDidRequestBaseStop(self)

        let status = makeStatus(
            sessionID: sessionID,
            sequence: statusSequence,
            senderID: robotID,
            recipientID: controllerID,
            profile: stoppedProfile,
            zoneRadiusMeters: stoppedRadius,
            maximumSpeedScale: stoppedSpeed,
            behaviors: stoppedBehaviors,
            destination: stoppedDestination,
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
        destination = nil
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
        destination = message.hasDestination
            ? (message.destinationLatitude, message.destinationLongitude, message.destinationName)
            : nil
        zoneOrigin = nil
        motionState = .silent
        lastPublishedDetail = nil
        lastStatusUptime = 0
        ROBTraversabilityRuntime.shared.setAutonomousMotionActive(true)
        if let destination {
            ROBNavigationRuntime.shared.configure(
                destinationLatitude: destination.latitude,
                destinationLongitude: destination.longitude,
                destinationName: destination.name,
                authorizedRadiusMeters: zoneRadiusMeters
            )
        } else {
            ROBNavigationRuntime.shared.clear()
        }

        if let latestLidar,
           ProcessInfo.processInfo.systemUptime - latestLidar.receivedAtUptime <= Self.lidarFreshness {
            zoneOrigin = (latestLidar.x, latestLidar.y)
        }

        nextWanderChangeUptime = ProcessInfo.processInfo.systemUptime + 4
        nextConversationUptime = ProcessInfo.processInfo.systemUptime + 15
        if tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: Self.plannerInterval, repeats: true) { [weak self] _ in
                self?.plannerTick()
            }
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
        let now = ProcessInfo.processInfo.systemUptime
        guard active else { return }
        if let expiresAt, Date() >= expiresAt {
            stop(reason: "Autonomy session duration ended")
            return
        }

        let snapshot = ROBSceneSnapshotStore.shared.snapshot()

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

        if behaviors.contains("navigate_destination") {
            planDestinationNavigation(lidar: lidar, now: now)
            maybeRequestConversation(now: now)
            publishActiveStatus(force: now - lastStatusUptime >= 2)
            return
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
        } else if behaviors.contains("follow_sidewalk") && snapshot.sidewalkConfidence >= 0.5 {
            let error = snapshot.sidewalkCenterDeviation // between -1.0 and 1.0
            let kp = 0.12 // Proportional gain
            
            // Proportional steering: add error * gain to one tread, subtract from other
            let leftTread = 0.12 + (error * kp)
            let rightTread = 0.12 - (error * kp)
            
            transition(
                to: .followingSidewalk,
                left: max(0.04, min(0.20, leftTread)),
                right: max(0.04, min(0.20, rightTread)),
                detail: "Centering ROB on the sidewalk path (deviation: \(String(format: "%.2f", error)))"
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

    private func planDestinationNavigation(lidar: LidarSnapshot, now: TimeInterval) {
        switch ROBNavigationRuntime.shared.guidance(now: now) {
        case .waiting(let detail), .unavailable(let detail):
            transition(to: .waitingForLidar, left: nil, right: nil, detail: detail)

        case .arrived:
            stop(reason: "OpenStreetMap destination reached")

        case .ready(let desiredHeading, let distanceRemaining):
            guard let perception = ROBTraversabilityRuntime.shared.snapshot(),
                  now - perception.receivedAtUptime <= Self.lidarFreshness else {
                transition(
                    to: .waitingForLidar,
                    left: nil,
                    right: nil,
                    detail: "Destination navigation is waiting for a fresh belly RGB-D frame"
                )
                return
            }
            guard perception.trainingSampleCount >= ROBTraversabilityRuntime.minimumTrainingSamples else {
                transition(
                    to: .waitingForLidar,
                    left: nil,
                    right: nil,
                    detail: "Learning terrain from manual driving (\(perception.trainingSampleCount)/\(ROBTraversabilityRuntime.minimumTrainingSamples) traversed samples)"
                )
                return
            }

            let candidates = perception.directions.compactMap { direction -> (ROBTraversabilityDirection, Double)? in
                let lidarClearance = minimumDistance(in: lidar.points) { point in
                    abs(Self.normalizedAngle(point.angle - direction.headingOffset)) <= 0.20
                }
                guard lidarClearance >= Self.obstacleDistanceMeters,
                      direction.geometryConfidence >= 0.50,
                      direction.depthClearanceMeters >= 0.45,
                      direction.learnedConfidence >= 0.25,
                      direction.learnedScore >= 0.18 else { return nil }
                let routeError = abs(Self.normalizedAngle(direction.headingOffset - desiredHeading))
                let score = direction.learnedScore * 1.4
                    + min(direction.depthClearanceMeters, 2.0) * 0.12
                    + min(lidarClearance, 2.0) * 0.10
                    - routeError * 1.8
                return (direction, score)
            }
            guard let selected = candidates.max(by: { $0.1 < $1.1 })?.0 else {
                transition(
                    to: .waitingForLidar,
                    left: nil,
                    right: nil,
                    detail: "No route-aligned terrain is clear in both depth and RPLidar"
                )
                return
            }

            let heading = selected.headingOffset
            if abs(desiredHeading) > 1.15 {
                let turnLeft = desiredHeading > 0
                transition(
                    to: .navigating,
                    left: turnLeft ? -0.07 : 0.07,
                    right: turnLeft ? 0.07 : -0.07,
                    detail: String(format: "Turning toward the pedestrian route — %.1f m remaining", distanceRemaining)
                )
                return
            }
            let base = 0.085
            let turn = max(-0.075, min(0.075, heading * 0.13))
            transition(
                to: .navigating,
                left: base - turn,
                right: base + turn,
                detail: String(
                    format: "Following clear learned terrain toward the route — %.1f m remaining (model %d)",
                    distanceRemaining,
                    perception.trainingSampleCount
                )
            )
        }
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
        guard active, behaviors.contains("talk") else { return }

        // 1. Check for newly recognized identified people to greet pro-actively
        let snapshot = ROBSceneSnapshotStore.shared.snapshot()
        let identifiedPeople = snapshot.mlxIdentifiedPeople
        var personToGreet: String? = nil

        for person in identifiedPeople {
            let lastGreeted = lastGreetedTimes[person] ?? 0
            if now - lastGreeted >= 300 { // 5-minute cooldown
                lastGreetedTimes[person] = now
                personToGreet = person
                break
            }
        }

        if let person = personToGreet {
            // Push next regular conversation interval forward so we don't immediately talk again
            nextConversationUptime = now + Double.random(in: 45 ... 90)
            var greetingName = person
            if person.lowercased().contains("rudy") {
                let title = ROBMLXRuntime.shared.rudyGreetingTitle
                greetingName = "Rudy (\(title))"
            }
            NSLog("[Autonomy] Triggering proactive greeting for: \(greetingName)")
            let prompt = "Autonomy context: you have just recognized \(greetingName) in the camera frame! You have not greeted them recently. Briefly and naturally greet them by name/description, welcome them, and start a friendly, polite conversation."
            delegate?.autonomyCoordinator(self, requestConversationPrompt: prompt)
            return
        }

        // 2. Regular periodic conversation request
        guard now >= nextConversationUptime else { return }
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
        let status = makeStatus(
            sessionID: sessionID,
            sequence: max(sequence, 1),
            senderID: robotID,
            recipientID: controllerID,
            profile: profile,
            zoneRadiusMeters: zoneRadiusMeters,
            maximumSpeedScale: maximumSpeedScale,
            behaviors: behaviors,
            destination: destination,
            state: .active,
            expiresAt: expiresAt,
            detail: lastPublishedDetail ?? "Controller-authorized autonomy is active"
        )
        delegate?.autonomyCoordinator(self, publishStatus: status)
    }

    private func publishUnavailable(for message: ROBAutonomySessionMessage, detail: String) {
        let status = makeStatus(
            sessionID: message.sessionID,
            sequence: max(message.sequence, 1),
            senderID: robotID,
            recipientID: message.senderID,
            profile: message.profile,
            zoneRadiusMeters: message.zoneRadiusMeters,
            maximumSpeedScale: message.maximumSpeedScale,
            behaviors: message.behaviors,
            destination: message.hasDestination
                ? (message.destinationLatitude, message.destinationLongitude, message.destinationName)
                : nil,
            state: .unavailable,
            expiresAt: nil,
            detail: detail
        )
        delegate?.autonomyCoordinator(self, publishStatus: status)
    }

    private func publishInactive(for message: ROBAutonomySessionMessage, detail: String) {
        let status = makeStatus(
            sessionID: message.sessionID,
            sequence: max(message.sequence, 1),
            senderID: robotID,
            recipientID: message.senderID,
            profile: message.profile,
            zoneRadiusMeters: message.zoneRadiusMeters,
            maximumSpeedScale: message.maximumSpeedScale,
            behaviors: message.behaviors,
            destination: message.hasDestination
                ? (message.destinationLatitude, message.destinationLongitude, message.destinationName)
                : nil,
            state: .inactive,
            expiresAt: nil,
            detail: detail
        )
        delegate?.autonomyCoordinator(self, publishStatus: status)
    }

    private func makeStatus(
        sessionID: String,
        sequence: UInt64,
        senderID: String,
        recipientID: String?,
        profile: ROBAutonomyProfile,
        zoneRadiusMeters: Double,
        maximumSpeedScale: Double,
        behaviors: [String],
        destination: (latitude: Double, longitude: Double, name: String?)?,
        state: ROBAutonomySessionState,
        expiresAt: Date?,
        detail: String?
    ) -> ROBAutonomySessionMessage {
        if let destination {
            return .navigationStatus(
                sessionID: sessionID,
                sequence: sequence,
                senderID: senderID,
                recipientID: recipientID,
                zoneRadiusMeters: zoneRadiusMeters,
                maximumSpeedScale: maximumSpeedScale,
                behaviors: behaviors,
                state: state,
                expiresAt: expiresAt,
                detail: detail,
                destinationLatitude: destination.latitude,
                destinationLongitude: destination.longitude,
                destinationName: destination.name
            )
        }
        return .status(
            sessionID: sessionID,
            sequence: sequence,
            senderID: senderID,
            recipientID: recipientID,
            profile: profile,
            zoneRadiusMeters: zoneRadiusMeters,
            maximumSpeedScale: maximumSpeedScale,
            behaviors: behaviors,
            state: state,
            expiresAt: expiresAt,
            detail: detail
        )
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
