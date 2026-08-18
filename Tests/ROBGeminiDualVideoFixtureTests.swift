import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Test-only reference model for Cerebro's Gemini multi-camera admission
/// contract. Production has to preserve these invariants even if its AppKit /
/// Core Image implementation changes.
private struct GeminiDualVideoFixture {
    enum Source: String, CaseIterable {
        case mainCamera
        case insta360Panorama

        var burnedLabel: String {
            switch self {
            case .mainCamera: return "MAIN FORWARD CAMERA"
            case .insta360Panorama: return "INSTA360 STITCHED 360 PANORAMA"
            }
        }
    }

    struct Frame: Equatable {
        let source: Source
        let sequence: UInt64
        /// Monotonic capture time. Wall-clock adjustments must not revive old
        /// frames or make a future-dated frame look current.
        let capturedAtUptime: TimeInterval
        let pixels: String
    }

    struct Composite: Equatable {
        let generatedAtUptime: TimeInterval
        let panelSources: [Source]
        let freshSources: [Source]
        let visibleText: String
        let directionMarkers: [DirectionMarker]
    }

    struct DirectionMarker: Equatable {
        enum Direction: String, CaseIterable {
            case front = "FRONT"
            case right = "RIGHT"
            case rear = "REAR"
            case left = "LEFT"
        }

        let direction: Direction
        /// Horizontal stitched-panorama position: 0° is the left seam and
        /// 180° is the center of the image.
        let panoramaDegrees: Double
    }

    struct Settings: Equatable {
        enum PanoramaHandedness: Equatable {
            /// A forward marker alone proves only the antipodal FRONT/REAR
            /// axis. It cannot prove which horizontal direction is robot-left
            /// or robot-right.
            case unknown
            case degreesIncreaseClockwiseAroundRobot
            case degreesIncreaseCounterclockwiseAroundRobot
        }

        var masterVideoEnabled: Bool
        var mainCameraEnabled: Bool
        var insta360Enabled: Bool
        var insta360OrientationCalibrated: Bool = false
        var insta360ForwardMarkerDegrees: Double = 180
        var gyroStabilizationEnabled: Bool = false
        var activePreviewProjection: String? = "stitched-equirectangular-v1"
        var calibratedPreviewProjection = "stitched-equirectangular-v1"
        var panoramaHandedness: PanoramaHandedness = .unknown
    }

    static let minimumSendInterval: TimeInterval = 1.0
    static let maximumFrameAge: TimeInterval = 2.5
    static let maximumFutureSkew: TimeInterval = 0.1

    private(set) var settings: Settings
    private(set) var generation: UInt64 = 1
    private(set) var latestBySource: [Source: Frame] = [:]
    private(set) var lastSendUptime: TimeInterval?

    mutating func updateSettings(_ newSettings: Settings) {
        settings = newSettings
        if !newSettings.masterVideoEnabled {
            latestBySource.removeAll()
        } else {
            if !newSettings.mainCameraEnabled {
                latestBySource.removeValue(forKey: .mainCamera)
            }
            if !newSettings.insta360Enabled {
                latestBySource.removeValue(forKey: .insta360Panorama)
            }
        }
    }

    mutating func rotateGeneration() {
        generation &+= 1
        latestBySource.removeAll()
        lastSendUptime = nil
    }

    mutating func offer(
        _ frame: Frame,
        generation offeredGeneration: UInt64,
        nowUptime: TimeInterval
    ) {
        guard offeredGeneration == generation,
              settings.masterVideoEnabled,
              sourceIsEnabled(frame.source),
              frame.capturedAtUptime <= nowUptime + Self.maximumFutureSkew,
              nowUptime - frame.capturedAtUptime <= Self.maximumFrameAge else {
            return
        }

        // Latest-only by source: a fast producer replaces its own pending
        // frame, but can never evict the other camera's pending view.
        if let current = latestBySource[frame.source],
           (frame.capturedAtUptime, frame.sequence)
            <= (current.capturedAtUptime, current.sequence) {
            return
        }
        latestBySource[frame.source] = frame
    }

    mutating func drain(nowUptime: TimeInterval) -> Composite? {
        guard settings.masterVideoEnabled else { return nil }
        if let lastSendUptime,
           nowUptime - lastSendUptime < Self.minimumSendInterval {
            return nil
        }

        latestBySource = latestBySource.filter { source, frame in
            sourceIsEnabled(source)
                && frame.capturedAtUptime <= nowUptime + Self.maximumFutureSkew
                && nowUptime - frame.capturedAtUptime <= Self.maximumFrameAge
        }
        let freshSources = Source.allCases.filter { latestBySource[$0] != nil }
        guard !freshSources.isEmpty else { return nil }
        let panelSources = Source.allCases.filter(sourceIsEnabled)
        let directionMarkers = panoramaDirectionMarkers()

        // One composite is one Gemini realtimeInput.video message. Burning the
        // labels into the pixels avoids relying on ordering between separate
        // text and media WebSocket messages. An enabled-but-missing view keeps
        // its deterministic panel and says that it is unavailable; it never
        // silently reuses an old image.
        var visibleText = panelSources.map { source in
            let content = latestBySource[source]?.pixels ?? "[UNAVAILABLE OR STALE]"
            return "\(source.burnedLabel):\(content)"
        }.joined(separator: "|")
        if panelSources.contains(.insta360Panorama) {
            if directionMarkers.isEmpty {
                visibleText += "|ORIENTATION UNCALIBRATED"
            } else {
                visibleText += "|ROB DIRECTIONS CALIBRATED|"
                visibleText += directionMarkers.map {
                    "\($0.direction.rawValue)@\($0.panoramaDegrees)"
                }.joined(separator: "|")
            }
        }
        latestBySource.removeAll()
        lastSendUptime = nowUptime
        return Composite(
            generatedAtUptime: nowUptime,
            panelSources: panelSources,
            freshSources: freshSources,
            visibleText: visibleText,
            directionMarkers: directionMarkers
        )
    }

    private func panoramaDirectionMarkers() -> [DirectionMarker] {
        guard settings.insta360Enabled,
              settings.insta360OrientationCalibrated,
              !settings.gyroStabilizationEnabled,
              settings.activePreviewProjection == settings.calibratedPreviewProjection else {
            return []
        }
        let forward = Self.normalizedDegrees(settings.insta360ForwardMarkerDegrees)
        var markers = [
            DirectionMarker(direction: .front, panoramaDegrees: forward),
            DirectionMarker(
                direction: .rear,
                panoramaDegrees: Self.normalizedDegrees(forward + 180)
            ),
        ]
        switch settings.panoramaHandedness {
        case .unknown:
            break
        case .degreesIncreaseClockwiseAroundRobot:
            markers.append(DirectionMarker(
                direction: .right,
                panoramaDegrees: Self.normalizedDegrees(forward + 90)
            ))
            markers.append(DirectionMarker(
                direction: .left,
                panoramaDegrees: Self.normalizedDegrees(forward + 270)
            ))
        case .degreesIncreaseCounterclockwiseAroundRobot:
            markers.append(DirectionMarker(
                direction: .right,
                panoramaDegrees: Self.normalizedDegrees(forward + 270)
            ))
            markers.append(DirectionMarker(
                direction: .left,
                panoramaDegrees: Self.normalizedDegrees(forward + 90)
            ))
        }
        return markers
    }

    private static func normalizedDegrees(_ value: Double) -> Double {
        guard value.isFinite else { return 180 }
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped >= 0 ? wrapped : wrapped + 360
    }

    private func sourceIsEnabled(_ source: Source) -> Bool {
        switch source {
        case .mainCamera: return settings.mainCameraEnabled
        case .insta360Panorama: return settings.insta360Enabled
        }
    }
}

/// Models the encoder's scheduled terminal transition. A live observation
/// gets exactly one later all-placeholder STALE composite when its final
/// source expires; it never becomes a repeating heartbeat.
private struct GeminiTerminalStaleFixture {
    static let maximumFrameAge: TimeInterval = 2.5

    private(set) var latestCaptureUptime: TimeInterval?
    private(set) var terminalStaleWasEmitted = false

    mutating func offer(
        capturedAtUptime: TimeInterval,
        isDecodable: Bool = true
    ) {
        // An invalid JPEG is not a new live observation. In particular, it
        // cannot replace the prior capture time or disarm that frame's one
        // scheduled LIVE-to-STALE transition.
        guard isDecodable else { return }
        latestCaptureUptime = capturedAtUptime
        terminalStaleWasEmitted = false
    }

    mutating func render(
        nowUptime: TimeInterval,
        allowAllPlaceholder: Bool
    ) -> String? {
        guard let latestCaptureUptime else { return nil }
        if nowUptime - latestCaptureUptime <= Self.maximumFrameAge {
            return "LIVE"
        }
        guard allowAllPlaceholder,
              !terminalStaleWasEmitted else {
            return nil
        }
        terminalStaleWasEmitted = true
        return "STALE"
    }
}

/// Models the small lock-protected gate checked synchronously at media
/// admission and again immediately before the Live actor writes its payload.
private final class GeminiVideoAuthorizationGateFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0

    func update(enabled: Bool, generation: UInt64) {
        lock.lock()
        self.enabled = enabled
        self.generation = generation
        lock.unlock()
    }

    func revoke() {
        lock.lock()
        enabled = false
        generation &+= 1
        lock.unlock()
    }

    func allows(generation offeredGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && offeredGeneration == generation
    }
}

@main
private enum ROBGeminiDualVideoFixtureTests {
    static func main() throws {
        try independentSourceSettings()
        try bothFreshViewsShareOneLabeledComposite()
        try totalSendRateIsBounded()
        try perSourceSlotsAreLatestOnlyAndFair()
        try staleAndFutureFramesFailClosed()
        try staleViewIsExplicitAndNeverReused()
        try robotRelativeMarkersRequireCalibration()
        try calibrationFailsClosedAcrossPreviewTransforms()
        try temporaryProjectionUnavailabilityPreservesOperatorIntent()
        try sideMarkersRequireExplicitHandedness()
        try terminalStaleTransitionIsEmittedOnce()
        try corruptFrameCannotDisarmTerminalStaleTransition()
        try synchronousAuthorizationGateRevokesPendingSend()
        try disableAndGenerationChangesDiscardPendingPixels()
        print("Gemini dual-video policy fixtures passed")
    }

    private static func independentSourceSettings() throws {
        var fixture = GeminiDualVideoFixture(settings: .init(
            masterVideoEnabled: true,
            mainCameraEnabled: false,
            insta360Enabled: true
        ))
        fixture.offer(frame(.mainCamera, 1, 10, "front"), generation: 1, nowUptime: 10)
        fixture.offer(frame(.insta360Panorama, 1, 10, "rear"), generation: 1, nowUptime: 10)
        let rearOnly = try require(fixture.drain(nowUptime: 10), "Enabled Insta360 frame was not admitted")
        try expect(
            rearOnly.panelSources == [.insta360Panorama]
                && rearOnly.freshSources == [.insta360Panorama]
                && !rearOnly.visibleText.contains("front"),
            "Disabling the main source also disabled or leaked into the independent Insta360 source"
        )

        fixture.updateSettings(.init(
            masterVideoEnabled: true,
            mainCameraEnabled: true,
            insta360Enabled: false
        ))
        fixture.offer(frame(.mainCamera, 2, 11, "front-2"), generation: 1, nowUptime: 11)
        fixture.offer(frame(.insta360Panorama, 2, 11, "rear-2"), generation: 1, nowUptime: 11)
        let frontOnly = try require(fixture.drain(nowUptime: 11), "Enabled main frame was not admitted")
        try expect(
            frontOnly.panelSources == [.mainCamera]
                && frontOnly.freshSources == [.mainCamera]
                && !frontOnly.visibleText.contains("rear-2"),
            "Disabling Insta360 also disabled or leaked into the independent main source"
        )

        fixture.updateSettings(.init(
            masterVideoEnabled: false,
            mainCameraEnabled: true,
            insta360Enabled: true
        ))
        fixture.offer(frame(.mainCamera, 3, 12, "private"), generation: 1, nowUptime: 12)
        try expect(
            fixture.drain(nowUptime: 12) == nil && fixture.latestBySource.isEmpty,
            "The global Gemini video privacy switch did not override both source settings"
        )
    }

    private static func bothFreshViewsShareOneLabeledComposite() throws {
        var fixture = enabledFixture()
        fixture.offer(frame(.mainCamera, 1, 20, "person-ahead"), generation: 1, nowUptime: 20)
        fixture.offer(
            frame(.insta360Panorama, 1, 20, "person-outside-forward-view"),
            generation: 1,
            nowUptime: 20
        )
        let composite = try require(fixture.drain(nowUptime: 20), "Two fresh cameras produced no Gemini input")

        try expect(
            composite.panelSources == [.mainCamera, .insta360Panorama]
                && composite.freshSources == [.mainCamera, .insta360Panorama],
            "A fresh camera view was dropped instead of sharing the one video message"
        )
        for source in GeminiDualVideoFixture.Source.allCases {
            try expect(
                composite.visibleText.contains(source.burnedLabel),
                "The \(source.rawValue) pixels lost their fixed visible source label"
            )
        }
        try expect(
            composite.visibleText.contains("person-ahead")
                && composite.visibleText.contains("person-outside-forward-view"),
            "The composite did not retain observations from both camera sources"
        )
    }

    private static func totalSendRateIsBounded() throws {
        var fixture = enabledFixture()
        fixture.offer(frame(.mainCamera, 1, 30, "a"), generation: 1, nowUptime: 30)
        _ = try require(fixture.drain(nowUptime: 30), "First frame should send immediately")

        fixture.offer(frame(.insta360Panorama, 1, 30.1, "b"), generation: 1, nowUptime: 30.1)
        try expect(
            fixture.drain(nowUptime: 30.999) == nil,
            "Independent producers exceeded Gemini's one-frame-per-second total limit"
        )
        try expect(
            fixture.drain(nowUptime: 31) != nil,
            "The exact one-second total-rate boundary was rejected"
        )
    }

    private static func perSourceSlotsAreLatestOnlyAndFair() throws {
        var fixture = enabledFixture()
        fixture.offer(frame(.insta360Panorama, 7, 40, "panorama"), generation: 1, nowUptime: 40)
        for sequence in 1...100 {
            fixture.offer(
                frame(.mainCamera, UInt64(sequence), 40 + Double(sequence) / 1_000, "front-\(sequence)"),
                generation: 1,
                nowUptime: 40.1
            )
        }
        let composite = try require(fixture.drain(nowUptime: 40.1), "Flooded producers produced no composite")
        try expect(
            composite.freshSources.contains(.insta360Panorama),
            "Main-camera traffic starved the pending panorama"
        )
        try expect(
            composite.visibleText.contains("front-100")
                && !composite.visibleText.contains("front-99|"),
            "The main source queued history instead of retaining only its latest frame"
        )
    }

    private static func staleAndFutureFramesFailClosed() throws {
        var fixture = enabledFixture()
        fixture.offer(frame(.mainCamera, 1, 47.499, "stale"), generation: 1, nowUptime: 50)
        fixture.offer(frame(.insta360Panorama, 1, 50.101, "future"), generation: 1, nowUptime: 50)
        try expect(
            fixture.drain(nowUptime: 50) == nil,
            "Stale or implausibly future frames reached Gemini"
        )

        fixture.offer(frame(.mainCamera, 2, 47.5, "boundary"), generation: 1, nowUptime: 50)
        let boundary = try require(fixture.drain(nowUptime: 50), "Freshness boundary was unexpectedly rejected")
        try expect(
            boundary.visibleText.contains("boundary"),
            "The accepted freshness-boundary frame changed"
        )
    }

    private static func staleViewIsExplicitAndNeverReused() throws {
        var fixture = enabledFixture()
        fixture.offer(
            frame(.insta360Panorama, 1, 70, "old-person-in-panorama"),
            generation: 1,
            nowUptime: 70
        )
        fixture.offer(frame(.mainCamera, 1, 70, "front-first"), generation: 1, nowUptime: 70)
        _ = try require(fixture.drain(nowUptime: 70), "Initial composite was not emitted")

        fixture.offer(frame(.mainCamera, 2, 73, "front-current"), generation: 1, nowUptime: 73)
        let next = try require(fixture.drain(nowUptime: 73), "Fresh main frame did not produce a composite")
        try expect(
            next.panelSources == [.mainCamera, .insta360Panorama]
                && next.freshSources == [.mainCamera],
            "The missing rear view did not retain its deterministic labeled panel"
        )
        try expect(
            next.visibleText.contains("INSTA360 STITCHED 360 PANORAMA:[UNAVAILABLE OR STALE]")
                && !next.visibleText.contains("old-person-in-panorama"),
            "An old panorama was reused instead of being marked unavailable"
        )
    }

    private static func robotRelativeMarkersRequireCalibration() throws {
        var uncalibrated = GeminiDualVideoFixture(settings: .init(
            masterVideoEnabled: true,
            mainCameraEnabled: false,
            insta360Enabled: true
        ))
        uncalibrated.offer(
            frame(.insta360Panorama, 1, 80, "person-outside-forward-view"),
            generation: 1,
            nowUptime: 80
        )
        let unknownOrientation = try require(
            uncalibrated.drain(nowUptime: 80),
            "An uncalibrated panorama was not composited"
        )
        try expect(
            unknownOrientation.directionMarkers.isEmpty
                && unknownOrientation.visibleText.contains("ORIENTATION UNCALIBRATED")
                && !unknownOrientation.visibleText.contains("REAR@"),
            "An uncalibrated panorama falsely identified robot-relative rear"
        )

        var calibrated = GeminiDualVideoFixture(settings: .init(
            masterVideoEnabled: true,
            mainCameraEnabled: false,
            insta360Enabled: true,
            insta360OrientationCalibrated: true,
            insta360ForwardMarkerDegrees: 300,
            panoramaHandedness: .degreesIncreaseClockwiseAroundRobot
        ))
        calibrated.offer(
            frame(.insta360Panorama, 1, 81, "person-near-rear-marker"),
            generation: 1,
            nowUptime: 81
        )
        let knownOrientation = try require(
            calibrated.drain(nowUptime: 81),
            "A calibrated panorama was not composited"
        )
        let expected = [
            GeminiDualVideoFixture.DirectionMarker(direction: .front, panoramaDegrees: 300),
            GeminiDualVideoFixture.DirectionMarker(direction: .rear, panoramaDegrees: 120),
            GeminiDualVideoFixture.DirectionMarker(direction: .right, panoramaDegrees: 30),
            GeminiDualVideoFixture.DirectionMarker(direction: .left, panoramaDegrees: 210),
        ]
        try expect(
            knownOrientation.directionMarkers == expected
                && knownOrientation.visibleText.contains("ROB DIRECTIONS CALIBRATED")
                && knownOrientation.visibleText.contains("REAR@120.0"),
            "Calibrated FRONT/RIGHT/REAR/LEFT markers lost their wrap-safe panorama mapping"
        )
    }

    private static func calibrationFailsClosedAcrossPreviewTransforms() throws {
        for settings in [
            GeminiDualVideoFixture.Settings(
                masterVideoEnabled: true,
                mainCameraEnabled: false,
                insta360Enabled: true,
                insta360OrientationCalibrated: true,
                insta360ForwardMarkerDegrees: 180,
                gyroStabilizationEnabled: true
            ),
            GeminiDualVideoFixture.Settings(
                masterVideoEnabled: true,
                mainCameraEnabled: false,
                insta360Enabled: true,
                insta360OrientationCalibrated: true,
                insta360ForwardMarkerDegrees: 180,
                activePreviewProjection: "rectilinear-v2",
                calibratedPreviewProjection: "stitched-equirectangular-v1"
            ),
        ] {
            var fixture = GeminiDualVideoFixture(settings: settings)
            fixture.offer(
                frame(.insta360Panorama, 1, 82, "person-at-unknown-bearing"),
                generation: 1,
                nowUptime: 82
            )
            let composite = try require(
                fixture.drain(nowUptime: 82),
                "A transform-invalid panorama was not retained as non-directional context"
            )
            try expect(
                composite.directionMarkers.isEmpty
                    && composite.visibleText.contains("ORIENTATION UNCALIBRATED")
                    && !composite.visibleText.contains("REAR@"),
                "Gyro stabilization or a changed preview projection reused a stale robot-relative calibration"
            )
        }
    }

    private static func sideMarkersRequireExplicitHandedness() throws {
        var fixture = GeminiDualVideoFixture(settings: .init(
            masterVideoEnabled: true,
            mainCameraEnabled: false,
            insta360Enabled: true,
            insta360OrientationCalibrated: true,
            insta360ForwardMarkerDegrees: 45,
            panoramaHandedness: .unknown
        ))
        fixture.offer(
            frame(.insta360Panorama, 1, 83, "person-near-axis"),
            generation: 1,
            nowUptime: 83
        )
        let composite = try require(
            fixture.drain(nowUptime: 83),
            "A front/rear-only calibrated panorama was not composited"
        )
        try expect(
            composite.directionMarkers == [
                .init(direction: .front, panoramaDegrees: 45),
                .init(direction: .rear, panoramaDegrees: 225),
            ]
                && !composite.visibleText.contains("RIGHT@")
                && !composite.visibleText.contains("LEFT@"),
            "A forward-axis calibration made an unproven panorama handedness claim"
        )
    }

    private static func temporaryProjectionUnavailabilityPreservesOperatorIntent() throws {
        var settings = GeminiDualVideoFixture.Settings(
            masterVideoEnabled: true,
            mainCameraEnabled: false,
            insta360Enabled: true,
            insta360OrientationCalibrated: true,
            insta360ForwardMarkerDegrees: 90,
            activePreviewProjection: nil,
            calibratedPreviewProjection: "stitched-equirectangular-v1"
        )
        var fixture = GeminiDualVideoFixture(settings: settings)
        fixture.offer(
            frame(.insta360Panorama, 1, 90, "projection-not-applied"),
            generation: 1,
            nowUptime: 90
        )
        let unavailable = try require(
            fixture.drain(nowUptime: 90),
            "A temporarily unidentified panorama was not retained as non-directional context"
        )
        try expect(
            unavailable.directionMarkers.isEmpty
                && fixture.settings.insta360OrientationCalibrated,
            "A temporary missing applied projection erased the operator's saved calibration intent"
        )

        settings.activePreviewProjection = "stitched-equirectangular-v1"
        fixture.updateSettings(settings)
        fixture.offer(
            frame(.insta360Panorama, 2, 91, "projection-restored"),
            generation: 1,
            nowUptime: 91
        )
        let restored = try require(
            fixture.drain(nowUptime: 91),
            "The panorama did not resume after its verified projection returned"
        )
        try expect(
            restored.directionMarkers.map(\.direction) == [.front, .rear],
            "The effective calibration did not recover from saved intent when the verified projection returned"
        )
    }

    private static func terminalStaleTransitionIsEmittedOnce() throws {
        var fixture = GeminiTerminalStaleFixture()
        fixture.offer(capturedAtUptime: 100)
        try expect(
            fixture.render(nowUptime: 100, allowAllPlaceholder: false) == "LIVE",
            "A fresh source did not produce a live observation"
        )
        try expect(
            fixture.render(nowUptime: 102.501, allowAllPlaceholder: false) == nil,
            "An ordinary render emitted an all-placeholder heartbeat"
        )
        try expect(
            fixture.render(nowUptime: 102.501, allowAllPlaceholder: true) == "STALE",
            "The scheduled terminal expiry did not tell Gemini the feed became stale"
        )
        try expect(
            fixture.render(nowUptime: 110, allowAllPlaceholder: true) == nil,
            "The terminal stale transition repeated as a heartbeat"
        )
        fixture.offer(capturedAtUptime: 111)
        try expect(
            fixture.render(nowUptime: 113.501, allowAllPlaceholder: true) == "STALE",
            "A new live epoch did not arm exactly one new terminal stale transition"
        )
    }

    private static func corruptFrameCannotDisarmTerminalStaleTransition() throws {
        var fixture = GeminiTerminalStaleFixture()
        fixture.offer(capturedAtUptime: 120)
        try expect(
            fixture.render(nowUptime: 120, allowAllPlaceholder: false) == "LIVE",
            "The valid panorama did not establish the initial LIVE epoch"
        )
        fixture.offer(capturedAtUptime: 121, isDecodable: false)
        try expect(
            fixture.render(nowUptime: 122.501, allowAllPlaceholder: true) == "STALE",
            "A corrupt replacement frame canceled the valid panorama's terminal STALE transition"
        )
        try expect(
            fixture.render(nowUptime: 123, allowAllPlaceholder: true) == nil,
            "Corrupt input turned the terminal STALE transition into a heartbeat"
        )
    }

    private static func synchronousAuthorizationGateRevokesPendingSend() throws {
        let gate = GeminiVideoAuthorizationGateFixture()
        gate.update(enabled: true, generation: 7)
        try expect(
            gate.allows(generation: 7),
            "The enabled current video generation was rejected"
        )

        // This generation has already been accepted into an actor-owned
        // pending slot. Revocation happens synchronously before the actor gets
        // its next turn and must still block the final WebSocket write.
        let pendingGeneration: UInt64 = 7
        gate.revoke()
        try expect(
            !gate.allows(generation: pendingGeneration),
            "A queued frame survived synchronous privacy revocation before send"
        )
        gate.update(enabled: true, generation: 9)
        try expect(
            !gate.allows(generation: 7) && gate.allows(generation: 9),
            "The authorization gate did not enforce the active media generation"
        )
    }

    private static func disableAndGenerationChangesDiscardPendingPixels() throws {
        var fixture = enabledFixture()
        fixture.offer(frame(.insta360Panorama, 1, 60, "before-disable"), generation: 1, nowUptime: 60)
        fixture.updateSettings(.init(
            masterVideoEnabled: true,
            mainCameraEnabled: true,
            insta360Enabled: false
        ))
        try expect(
            fixture.drain(nowUptime: 60) == nil,
            "A pending Insta360 frame survived its source being disabled"
        )

        fixture.updateSettings(.init(
            masterVideoEnabled: true,
            mainCameraEnabled: true,
            insta360Enabled: true
        ))
        fixture.offer(frame(.mainCamera, 1, 61, "old-generation"), generation: 1, nowUptime: 61)
        fixture.rotateGeneration()
        fixture.offer(frame(.insta360Panorama, 2, 61, "wrong-generation"), generation: 1, nowUptime: 61)
        try expect(
            fixture.drain(nowUptime: 61) == nil,
            "A reconnect leaked media from a retired Gemini video generation"
        )
    }

    private static func enabledFixture() -> GeminiDualVideoFixture {
        GeminiDualVideoFixture(settings: .init(
            masterVideoEnabled: true,
            mainCameraEnabled: true,
            insta360Enabled: true
        ))
    }

    private static func frame(
        _ source: GeminiDualVideoFixture.Source,
        _ sequence: UInt64,
        _ uptime: TimeInterval,
        _ pixels: String
    ) -> GeminiDualVideoFixture.Frame {
        .init(source: source, sequence: sequence, capturedAtUptime: uptime, pixels: pixels)
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure.failed(message) }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw FixtureFailure.failed(message) }
    return value
}
