//
//  ROBFollowPersonCoordinator.swift
//  Cerebro
//
//  Controller-authorized visual person lock and deterministic follow motion.
//  The delayed Insta360 panorama is used only to help reacquire a lost lock;
//  it can never authorize a person or command tread movement.
//

import AppKit
import AVFoundation
import CoreImage
import Foundation
import Vision

@objc public protocol ROBFollowPersonCoordinatorDelegate: AnyObject {
    func followPersonCoordinator(
        _ coordinator: ROBFollowPersonCoordinator,
        applyLeftTread leftTread: Double,
        rightTread: Double,
        speedScale: Double
    )
    func followPersonCoordinatorDidRequestBaseStop(_ coordinator: ROBFollowPersonCoordinator)
    func followPersonCoordinatorPrepareTrackingPose(_ coordinator: ROBFollowPersonCoordinator) -> Bool
    func followPersonCoordinator(
        _ coordinator: ROBFollowPersonCoordinator,
        applyNeckPan pan: Float,
        tilt: Float
    )
    func followPersonCoordinator(
        _ coordinator: ROBFollowPersonCoordinator,
        applyTorsoRotation rotation: Float
    )
    func followPersonCoordinatorDidRequestActuatorRelease(_ coordinator: ROBFollowPersonCoordinator)
    func followPersonCoordinator(
        _ coordinator: ROBFollowPersonCoordinator,
        publishData data: Data,
        controllerID: UUID,
        sessionID: UUID
    )
}

@objcMembers public final class ROBFollowPersonCoordinator: NSObject {
    public weak var delegate: ROBFollowPersonCoordinatorDelegate?

    private struct LidarPoint {
        let distance: Double
        let angle: Double
    }

    private struct LidarSnapshot {
        let points: [LidarPoint]
        let receivedAtUptime: TimeInterval
    }

    private struct PreviewCandidate {
        let wire: ROBFollowTargetCandidate
        let observation: VNDetectedObjectObservation
        let featurePrint: VNFeaturePrintObservation?
    }

    private struct PendingPreview {
        let request: ROBFollowTargetMessage
        let candidates: [UUID: PreviewCandidate]
        let createdAtMilliseconds: UInt64
    }

    private struct FollowLimits {
        let minimumDistance: Double
        let preferredDistance: Double
        let maximumDistance: Double
        let maximumSpeed: Double
    }

    private let queue = DispatchQueue(label: "com.orbitusrobotics.follow-person", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pendingPreviewRequest: ROBFollowTargetMessage?
    private var pendingPreview: PendingPreview?
    private var controllerID: UUID?
    private var sessionID: UUID?
    private var requestID: UUID?
    private var sequence: UInt64 = 0
    private var lastInboundSequenceBySession: [String: UInt64] = [:]
    private var targetFeaturePrint: VNFeaturePrintObservation?
    private var trackingRequest: VNTrackObjectRequest?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var latestBoundingBox: CGRect?
    private var latestDistanceMeters: Double?
    private var latestLockUptime: TimeInterval = 0
    private var latestLidar: LidarSnapshot?
    private var plannerTimer: DispatchSourceTimer?
    private var neckPanDemand: Float = 0
    private var neckTiltDemand: Float = 0
    private var torsoDemand: Float = 0
    private var trackingPoseReady = false
    private var lastStatusState: ROBFollowTargetState?
    private var lastStatusDetail: String?
    private var lastStatusUptime: TimeInterval = 0
    private var lastInstaAnalysisUptime: TimeInterval = 0
    private var limits = FollowLimits(
        minimumDistance: 1.2,
        preferredDistance: 1.8,
        maximumDistance: 2.8,
        maximumSpeed: 0.12
    )
    private var activeOnQueue = false
    private let activeLock = NSLock()
    private var activeSnapshot = false
    private var controlSessionObserver: NSObjectProtocol?

    public var active: Bool {
        activeLock.lock()
        defer { activeLock.unlock() }
        return activeSnapshot
    }

    public init(robotID _: String) {
        super.init()
        ROBInsta360CameraService.shared.setFollowFrameConsumer(self)
        controlSessionObserver = NotificationCenter.default.addObserver(
            forName: .robControlLiveSessionDidEnd,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let controllerID = notification.userInfo?[
                ROBControlLiveSessionNotification.controllerIDKey
            ] as? UUID,
                  let sessionID = notification.userInfo?[
                    ROBControlLiveSessionNotification.sessionIDKey
                  ] as? UUID else { return }
            self?.queue.async {
                guard self?.controllerID == controllerID,
                      self?.sessionID == sessionID else { return }
                self?.stopOnQueue(reason: "The authorizing ROBController session disconnected", publish: false)
            }
        }
    }

    deinit {
        plannerTimer?.cancel()
        if let controlSessionObserver { NotificationCenter.default.removeObserver(controlSessionObserver) }
    }

    /// Returns true for every claimed follow frame, including malformed ones,
    /// so callers never fall through to historical robot-command decoders.
    public func handleWireData(_ data: Data) -> Bool {
        guard ROBFollowTargetProtocol.claimsProtocol(data) else { return false }
        guard let message = try? ROBFollowTargetProtocol.decode(data) else { return true }
        queue.async { [weak self] in self?.consume(message) }
        return true
    }

    public func updateLidarScanData(_ data: Data) {
        guard let frame = try? ROBLidarScanFrame.decode(data) else { return }
        let snapshot = LidarSnapshot(
            points: frame.points.map {
                LidarPoint(distance: Double($0.distanceMeters), angle: Double($0.angleRadians))
            },
            receivedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        queue.async { [weak self] in self?.latestLidar = snapshot }
    }

    @nonobjc func offerMainCameraFrame(_ sampleBuffer: CMSampleBuffer, depth: CameraDepthFrame?) {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        queue.async { [weak self] in
            guard let self,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if let request = self.pendingPreviewRequest {
                self.pendingPreviewRequest = nil
                self.makePreview(for: request, pixelBuffer: pixelBuffer, depth: depth)
            }
            guard self.activeOnQueue else { return }
            self.trackTarget(pixelBuffer: pixelBuffer, depth: depth)
        }
    }

    public func stop(withReason reason: String) {
        // Priority/software/manual stops must revoke the active snapshot before
        // their caller returns, otherwise an already queued main-thread tread
        // command could briefly reacquire Follow authority after the stop.
        queue.sync { stopOnQueue(reason: reason, publish: true) }
    }

    public func shutdown() {
        queue.sync { stopOnQueue(reason: "Cerebro is shutting down", publish: false) }
        ROBInsta360CameraService.shared.setFollowFrameConsumer(nil)
    }

    private func consume(_ message: ROBFollowTargetMessage) {
        let sessionKey = message.controllerID.uuidString + ":" + message.sessionID.uuidString
        guard message.sequence > (lastInboundSequenceBySession[sessionKey] ?? 0) else { return }
        lastInboundSequenceBySession[sessionKey] = message.sequence
        switch message.kind {
        case .previewRequest:
            if activeOnQueue {
                guard controllerID == message.controllerID,
                      sessionID == message.sessionID else {
                    publishOneOffStatus(
                        to: message,
                        state: .blocked,
                        detail: "Another authenticated ROBController owns the active follow session. Use that controller to stop it first."
                    )
                    return
                }
                stopOnQueue(reason: "A new target selection was requested", publish: false)
            }
            controllerID = message.controllerID
            sessionID = message.sessionID
            requestID = message.requestID
            pendingPreviewRequest = message
            pendingPreview = nil
            publish(
                state: .idle,
                detail: "Waiting for the next main-camera frame to show selectable people."
            )

        case .authorize:
            if activeOnQueue,
               controllerID != message.controllerID || sessionID != message.sessionID {
                publishOneOffStatus(
                    to: message,
                    state: .blocked,
                    detail: "Another authenticated ROBController owns the active follow session."
                )
                return
            }
            authorize(message)

        case .stop:
            guard controllerID == message.controllerID,
                  sessionID == message.sessionID else { return }
            stopOnQueue(reason: message.detail ?? "Stopped by ROBController", publish: true)

        case .preview, .status:
            break
        }
    }

    private func makePreview(
        for request: ROBFollowTargetMessage,
        pixelBuffer: CVPixelBuffer,
        depth: CameraDepthFrame?
    ) {
        let observations = detectPeople(in: pixelBuffer)
            .filter { $0.confidence >= 0.55 && $0.boundingBox.width >= 0.06 && $0.boundingBox.height >= 0.16 }
            .prefix(8)
        guard !observations.isEmpty,
              let jpeg = previewJPEG(from: pixelBuffer) else {
            publish(state: .blocked, detail: "No selectable person is visible in the main camera. Try Refresh Preview.")
            return
        }

        let image = CIImage(cvImageBuffer: pixelBuffer)
        var candidates: [UUID: PreviewCandidate] = [:]
        for observation in observations {
            let id = UUID()
            let rect = observation.boundingBox
            let wire = ROBFollowTargetCandidate(
                id: id,
                x: Self.fixed(rect.minX),
                y: Self.fixed(rect.minY),
                width: Self.fixed(rect.width),
                height: Self.fixed(rect.height),
                confidencePermille: UInt16(clamping: Int((observation.confidence * 1_000).rounded())),
                distanceMillimeters: medianDepth(in: rect, depth: depth)
            )
            candidates[id] = PreviewCandidate(
                wire: wire,
                observation: VNDetectedObjectObservation(boundingBox: rect),
                featurePrint: featurePrint(for: rect, in: image)
            )
        }
        let now = Self.nowMilliseconds
        pendingPreview = PendingPreview(
            request: request,
            candidates: candidates,
            createdAtMilliseconds: now
        )
        publishMessage(ROBFollowTargetMessage(
            kind: .preview,
            requestID: request.requestID,
            controllerID: request.controllerID,
            sessionID: request.sessionID,
            sequence: nextSequence(),
            sentAtMilliseconds: now,
            state: .previewReady,
            detail: "Tap the person ROB should follow, then explicitly authorize Follow Mode.",
            previewJPEG: jpeg,
            candidates: candidates.values.map(\.wire).sorted { $0.x < $1.x }
        ))
    }

    private func authorize(_ message: ROBFollowTargetMessage) {
        let now = Self.nowMilliseconds
        guard let preview = pendingPreview,
              preview.request.requestID == message.requestID,
              preview.request.controllerID == message.controllerID,
              preview.request.sessionID == message.sessionID,
              now >= preview.createdAtMilliseconds,
              now - preview.createdAtMilliseconds <= ROBFollowTargetProtocol.previewLifetimeMilliseconds,
              let selectedID = message.selectedCandidateID,
              let selected = preview.candidates[selectedID] else {
            controllerID = message.controllerID
            sessionID = message.sessionID
            requestID = message.requestID
            publish(state: .blocked, detail: "That visual selection expired. Refresh the preview and choose the person again.")
            return
        }

        stopOnQueue(reason: "Replacing the previous follow target", publish: false)
        controllerID = message.controllerID
        sessionID = message.sessionID
        requestID = message.requestID
        limits = FollowLimits(
            minimumDistance: Double(message.minimumDistanceCentimeters) / 100,
            preferredDistance: Double(message.preferredDistanceCentimeters) / 100,
            maximumDistance: Double(message.maximumDistanceCentimeters) / 100,
            maximumSpeed: Double(message.maximumSpeedPermille) / 1_000
        )
        targetFeaturePrint = selected.featurePrint
        latestBoundingBox = selected.observation.boundingBox
        trackingRequest = VNTrackObjectRequest(detectedObjectObservation: selected.observation)
        trackingRequest?.trackingLevel = .accurate
        sequenceHandler = VNSequenceRequestHandler()
        latestLockUptime = ProcessInfo.processInfo.systemUptime
        latestDistanceMeters = selected.wire.distanceMillimeters.map { Double($0) / 1_000 }
        neckPanDemand = 0
        neckTiltDemand = 0
        torsoDemand = 0
        trackingPoseReady = false
        setActive(true)
        ROBTraversabilityRuntime.shared.setAutonomousMotionActive(true)
        ROBInsta360CameraService.shared.setFollowVideoDemandActive(true)
        startPlanner()
        publish(state: .following, detail: "Target authorized. Main-camera lock is active; the base is waiting for all safety inputs.")
    }

    private func trackTarget(pixelBuffer: CVPixelBuffer, depth: CameraDepthFrame?) {
        var accepted: VNDetectedObjectObservation?
        if let request = trackingRequest {
            do {
                try sequenceHandler.perform([request], on: pixelBuffer)
                if let observation = request.results?.first as? VNDetectedObjectObservation,
                   observation.confidence >= 0.42 {
                    accepted = observation
                }
            } catch {
                accepted = nil
            }
        }

        if accepted == nil {
            accepted = reacquireMainTarget(in: pixelBuffer)
            if accepted != nil { sequenceHandler = VNSequenceRequestHandler() }
        }
        guard let observation = accepted else { return }
        let next = VNTrackObjectRequest(detectedObjectObservation: observation)
        next.trackingLevel = .accurate
        trackingRequest = next
        latestBoundingBox = observation.boundingBox
        latestDistanceMeters = medianDepth(in: observation.boundingBox, depth: depth)
            .map { Double($0) / 1_000 }
        latestLockUptime = ProcessInfo.processInfo.systemUptime
        updateLookDemands(for: observation.boundingBox)
    }

    private func reacquireMainTarget(in pixelBuffer: CVPixelBuffer) -> VNDetectedObjectObservation? {
        let people = detectPeople(in: pixelBuffer).filter { $0.confidence >= 0.58 }
        guard !people.isEmpty else { return nil }
        if let old = latestBoundingBox,
           let nearby = people.max(by: { Self.intersectionOverUnion($0.boundingBox, old) < Self.intersectionOverUnion($1.boundingBox, old) }),
           Self.intersectionOverUnion(nearby.boundingBox, old) >= 0.22 {
            return VNDetectedObjectObservation(boundingBox: nearby.boundingBox)
        }
        guard let targetFeaturePrint else { return nil }
        let image = CIImage(cvImageBuffer: pixelBuffer)
        let scored = people.compactMap { observation -> (VNHumanObservation, Float)? in
            guard let candidate = featurePrint(for: observation.boundingBox, in: image) else { return nil }
            var distance: Float = .greatestFiniteMagnitude
            try? targetFeaturePrint.computeDistance(&distance, to: candidate)
            return distance.isFinite ? (observation, distance) : nil
        }.sorted { $0.1 < $1.1 }
        guard let best = scored.first, best.1 <= 18,
              scored.count == 1 || scored[1].1 - best.1 >= 1.5 else { return nil }
        return VNDetectedObjectObservation(boundingBox: best.0.boundingBox)
    }

    private func updateLookDemands(for rect: CGRect) {
        let horizontalError = Float(rect.midX - 0.5)
        let verticalError = Float(rect.midY - 0.52)
        if abs(horizontalError) > 0.035 {
            neckPanDemand = Self.clamp(neckPanDemand - horizontalError * 0.16, -1, 1)
        }
        if abs(verticalError) > 0.045 {
            neckTiltDemand = Self.clamp(neckTiltDemand + verticalError * 0.10, -0.8, 0.8)
        }
        let torsoTarget = Self.clamp(neckPanDemand * 0.82, -0.78, 0.78)
        torsoDemand += Self.clamp(torsoTarget - torsoDemand, -0.035, 0.035)
    }

    private func startPlanner() {
        plannerTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in self?.plan() }
        plannerTimer = timer
        timer.resume()
    }

    private func plan() {
        guard activeOnQueue else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !trackingPoseReady {
            dispatchDelegate { coordinator, delegate in
                let ready = delegate.followPersonCoordinatorPrepareTrackingPose(coordinator)
                coordinator.queue.async { coordinator.trackingPoseReady = ready }
            }
            requestBaseStop()
            publish(state: .blocked, detail: "Moving the lower neck into the calibrated full-pan tracking pose.")
            return
        }

        let neckPan = neckPanDemand
        let neckTilt = neckTiltDemand
        let torso = torsoDemand
        dispatchDelegate { coordinator, delegate in
            delegate.followPersonCoordinator(coordinator, applyNeckPan: neckPan, tilt: neckTilt)
            delegate.followPersonCoordinator(coordinator, applyTorsoRotation: torso)
        }

        let lockAge = now - latestLockUptime
        guard lockAge <= 0.45, let rect = latestBoundingBox else {
            requestBaseStop()
            let remaining = max(0, 15 - lockAge)
            publish(
                state: .targetLost,
                detail: String(format: "Main-camera lock lost. Treads stopped; delayed Insta360 may only re-aim the camera (%.0f s remaining).", remaining)
            )
            if lockAge > 15 { stopOnQueue(reason: "Target was lost for 15 seconds; visual authorization is required again", publish: true) }
            return
        }
        guard let distance = latestDistanceMeters else {
            requestBaseStop()
            publish(state: .blocked, detail: "Target locked, but aligned main-camera depth is unavailable. Treads are stopped.")
            return
        }
        guard distance.isFinite, distance >= limits.minimumDistance else {
            requestBaseStop()
            publish(state: .blocked, detail: String(format: "Holding: target is inside the %.1f m minimum range.", limits.minimumDistance))
            return
        }
        if distance <= limits.preferredDistance + 0.12 {
            requestBaseStop()
            publish(state: .following, detail: String(format: "Main-camera lock • holding safe range at %.1f m.", distance))
            return
        }
        guard let lidar = latestLidar, now - lidar.receivedAtUptime <= 0.75 else {
            requestBaseStop()
            publish(state: .blocked, detail: "Waiting for fresh authenticated RPLidar clearance.")
            return
        }
        guard let terrain = ROBTraversabilityRuntime.shared.snapshot(),
              now - terrain.receivedAtUptime <= 0.75 else {
            requestBaseStop()
            publish(state: .blocked, detail: "Waiting for a fresh forward-facing belly RGB-D safety frame.")
            return
        }

        // The camera/waist keep looking independently. The base selects a
        // belly-camera direction nearest the estimated target bearing.
        let imageBearing = Double(0.5 - rect.midX) * 1.22
        let estimatedTargetBearing = imageBearing
            + Double(neckPanDemand) * (.pi / 3)
            + Double(torsoDemand) * (.pi / 2)
        let candidates = terrain.directions.filter { direction in
            direction.geometryConfidence >= 0.5
                && direction.depthClearanceMeters >= 0.65
                && minimumDistance(in: lidar.points, around: direction.headingOffset, halfAngle: 0.20) >= 0.8
        }
        guard let path = candidates.min(by: {
            abs(Self.normalizedAngle($0.headingOffset - estimatedTargetBearing))
                < abs(Self.normalizedAngle($1.headingOffset - estimatedTargetBearing))
        }) else {
            requestBaseStop()
            publish(state: .blocked, detail: "No direction is clear in both belly depth and RPLidar.")
            return
        }

        let heading = Self.normalizedAngle(path.headingOffset)
        let rangeError = min(1, max(0, (distance - limits.preferredDistance) / max(0.2, limits.maximumDistance - limits.preferredDistance)))
        let base = max(0.045, limits.maximumSpeed * rangeError)
        let turn = max(-0.065, min(0.065, heading * 0.12))
        let left = max(-limits.maximumSpeed, min(limits.maximumSpeed, base - turn))
        let right = max(-limits.maximumSpeed, min(limits.maximumSpeed, base + turn))
        let maximumSpeed = limits.maximumSpeed
        dispatchDelegate { coordinator, delegate in
            delegate.followPersonCoordinator(
                coordinator,
                applyLeftTread: left,
                rightTread: right,
                speedScale: maximumSpeed
            )
        }
        publish(state: .following, detail: String(format: "Following at %.1f m • main camera locked • belly path clear.", distance))
    }

    private func stopOnQueue(reason: String, publish shouldPublish: Bool) {
        let hadSession = controllerID != nil && sessionID != nil && requestID != nil
        plannerTimer?.cancel()
        plannerTimer = nil
        pendingPreviewRequest = nil
        pendingPreview = nil
        trackingRequest = nil
        targetFeaturePrint = nil
        latestBoundingBox = nil
        latestDistanceMeters = nil
        trackingPoseReady = false
        setActive(false)
        ROBTraversabilityRuntime.shared.setAutonomousMotionActive(false)
        ROBInsta360CameraService.shared.setFollowVideoDemandActive(false)
        dispatchDelegate { coordinator, delegate in
            delegate.followPersonCoordinatorDidRequestBaseStop(coordinator)
            delegate.followPersonCoordinatorDidRequestActuatorRelease(coordinator)
        }
        if shouldPublish, hadSession { publish(state: .stopped, detail: reason, force: true) }
    }

    private func requestBaseStop() {
        dispatchDelegate { coordinator, delegate in
            delegate.followPersonCoordinatorDidRequestBaseStop(coordinator)
        }
    }

    private func setActive(_ value: Bool) {
        activeOnQueue = value
        activeLock.lock()
        activeSnapshot = value
        activeLock.unlock()
    }

    private func publish(state: ROBFollowTargetState, detail: String, force: Bool = false) {
        guard let controllerID, let sessionID, let requestID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || state != lastStatusState || detail != lastStatusDetail || now - lastStatusUptime >= 1 else { return }
        lastStatusState = state
        lastStatusDetail = detail
        lastStatusUptime = now
        publishMessage(ROBFollowTargetMessage(
            kind: .status,
            requestID: requestID,
            controllerID: controllerID,
            sessionID: sessionID,
            sequence: nextSequence(),
            sentAtMilliseconds: Self.nowMilliseconds,
            state: state,
            detail: detail
        ))
    }

    private func publishMessage(_ message: ROBFollowTargetMessage) {
        guard let data = try? ROBFollowTargetProtocol.encode(message) else { return }
        dispatchDelegate { coordinator, delegate in
            delegate.followPersonCoordinator(
                coordinator,
                publishData: data,
                controllerID: message.controllerID,
                sessionID: message.sessionID
            )
        }
    }

    private func publishOneOffStatus(
        to request: ROBFollowTargetMessage,
        state: ROBFollowTargetState,
        detail: String
    ) {
        publishMessage(ROBFollowTargetMessage(
            kind: .status,
            requestID: request.requestID,
            controllerID: request.controllerID,
            sessionID: request.sessionID,
            sequence: nextSequence(),
            sentAtMilliseconds: Self.nowMilliseconds,
            state: state,
            detail: detail
        ))
    }

    private func dispatchDelegate(
        _ body: @escaping (ROBFollowPersonCoordinator, ROBFollowPersonCoordinatorDelegate) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            body(self, delegate)
        }
    }

    private func nextSequence() -> UInt64 {
        sequence &+= 1
        return sequence
    }

    private func detectPeople(in pixelBuffer: CVPixelBuffer) -> [VNHumanObservation] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        return request.results ?? []
    }

    private func previewJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvImageBuffer: pixelBuffer)
        let scale = min(1, min(720 / max(image.extent.width, 1), 480 / max(image.extent.height, 1)))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.68]
        )
    }

    private func featurePrint(for rect: CGRect, in image: CIImage) -> VNFeaturePrintObservation? {
        let pixelRect = CGRect(
            x: image.extent.minX + rect.minX * image.extent.width,
            y: image.extent.minY + rect.minY * image.extent.height,
            width: rect.width * image.extent.width,
            height: rect.height * image.extent.height
        ).intersection(image.extent)
        guard pixelRect.width >= 16, pixelRect.height >= 32 else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(ciImage: image.cropped(to: pixelRect), options: [:]).perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    private func medianDepth(in rect: CGRect, depth: CameraDepthFrame?) -> UInt16? {
        guard let depth, depth.width > 0, depth.height > 0 else { return nil }
        let inset = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.18)
        let x0 = max(0, min(depth.width - 1, Int(inset.minX * CGFloat(depth.width))))
        let x1 = max(x0, min(depth.width - 1, Int(inset.maxX * CGFloat(depth.width))))
        // Vision rectangles are lower-left; aligned depth rows are upper-left.
        let y0 = max(0, min(depth.height - 1, Int((1 - inset.maxY) * CGFloat(depth.height))))
        let y1 = max(y0, min(depth.height - 1, Int((1 - inset.minY) * CGFloat(depth.height))))
        let xStep = max(1, (x1 - x0) / 6)
        let yStep = max(1, (y1 - y0) / 7)
        var samples: [UInt16] = []
        for y in stride(from: y0, through: y1, by: yStep) {
            for x in stride(from: x0, through: x1, by: xStep) {
                if let value = depth.distanceMillimeters(x: x, y: y), value >= 300, value <= 8_000 {
                    samples.append(value)
                }
            }
        }
        guard samples.count >= 5 else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func minimumDistance(
        in points: [LidarPoint],
        around angle: Double,
        halfAngle: Double
    ) -> Double {
        points.compactMap { point in
            abs(Self.normalizedAngle(point.angle - angle)) <= halfAngle ? point.distance : nil
        }.min() ?? 0
    }

    private static var nowMilliseconds: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func fixed(_ value: CGFloat) -> UInt16 {
        UInt16(clamping: Int((max(0, min(1, value)) * 10_000).rounded()))
    }

    private static func clamp(_ value: Float, _ minimum: Float, _ maximum: Float) -> Float {
        max(minimum, min(maximum, value))
    }

    private static func normalizedAngle(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        return intersectionArea / max(0.000_1, lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea)
    }
}

extension ROBFollowPersonCoordinator: ROBInsta360VideoFrameConsumer {
    public func consumeInsta360JPEGFrame(
        _ jpegData: Data,
        capturedAt: Date,
        capturedAtUptime: TimeInterval
    ) {
        queue.async { [weak self] in
            guard let self, self.activeOnQueue,
                  ProcessInfo.processInfo.systemUptime - self.latestLockUptime > 0.45,
                  capturedAtUptime - self.lastInstaAnalysisUptime >= 1.5,
                  let targetFeaturePrint = self.targetFeaturePrint,
                  let image = CIImage(data: jpegData) else { return }
            self.lastInstaAnalysisUptime = capturedAtUptime
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
            let scored = (request.results ?? []).compactMap { observation -> (VNHumanObservation, Float)? in
                guard observation.confidence >= 0.58,
                      let candidate = self.featurePrint(for: observation.boundingBox, in: image) else { return nil }
                var distance: Float = .greatestFiniteMagnitude
                try? targetFeaturePrint.computeDistance(&distance, to: candidate)
                return distance.isFinite ? (observation, distance) : nil
            }.sorted { $0.1 < $1.1 }
            guard let best = scored.first, best.1 <= 16,
                  scored.count == 1 || scored[1].1 - best.1 >= 2 else { return }

            // Reacquisition remains relative to the current neck direction,
            // with the fixed optical offset shared by attention tracking.
            let deltaDegrees = (
                best.0.boundingBox.midX
                    - CGFloat(ROBInsta360TrackingCalibration.forwardCenterX)
            ) * 360
            let coarseTorso = Self.clamp(Float(deltaDegrees / 120), -0.75, 0.75)
            let coarseNeck = Self.clamp(Float(-deltaDegrees / 75), -1, 1)
            self.torsoDemand = coarseTorso
            self.neckPanDemand = coarseNeck
            self.requestBaseStop()
            self.publish(
                state: .targetLost,
                detail: String(format: "Main lock lost; delayed Insta360 matched the authorized appearance at %+.0f°. Re-aiming only—treads remain stopped.", deltaDegrees)
            )
        }
    }

}
