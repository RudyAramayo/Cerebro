//
//  ROBInsta360CameraService.swift
//  Cerebro
//
//  Headless ownership, health monitoring, and decoding for Insta360 Pro cameras.
//

import AppKit
import Foundation

extension Notification.Name {
    static let robInsta360CameraServiceDidChange = Notification.Name("ROBInsta360CameraServiceDidChange")
}

@objc public protocol ROBInsta360VideoFrameConsumer: AnyObject {
    func consumeInsta360JPEGFrame(
        _ jpegData: Data,
        capturedAt: Date,
        capturedAtUptime: TimeInterval
    )
}

private struct ROBInsta360PendingFrame {
    let jpegData: Data
    let capturedAt: Date
}

struct ROBInsta360ServiceStatusSnapshot: Sendable {
    let state: String
    let streamURL: String
    let lastError: String?
    let desiredRunning: Bool
    let decoderActive: Bool
    let diagnosticsPreviewVisible: Bool
    let analysisNeedsFrames: Bool
    let geminiVideoDemandActive: Bool
    let framesReceived: UInt64
    let decodedBytes: UInt64
    let framesPerSecond: Double
    let lastFrameAt: Date?
}

@objcMembers public final class ROBInsta360CameraService: NSObject {
    public static let shared = ROBInsta360CameraService()
    private static let gyroStabilizationDefaultsKey = "ROBInsta360GyroStabilizationEnabled"
    private static let cameraHostDefaultsKey = "ROBInsta360CameraHost"
    /// Changing any pixel-to-yaw property requires a new operator calibration.
    /// Keep this identity stable across ordinary reconnects to the same camera.
    private static let calibrationProjectionDescriptor = "equirectangular-pano-1920x960-v1"

    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.insta360-service")
    private let session: URLSession
    private var desiredRunning = false
    private var generation: UInt64 = 0
    private var fingerprint: String?
    private var heartbeatTimer: DispatchSourceTimer?
    private var retryWorkItem: DispatchWorkItem?
    private var retryAttempt = 0
    private var heartbeatFailures = 0
    private var heartbeatInFlight = false
    private var decoder: Process?
    private var decoderOutput: Pipe?
    private var decoderError: Pipe?
    private var jpegBuffer = Data()
    private var decoderErrorTail = Data()
    private var startedAt: Date?
    private var pendingDisplayFrame: ROBInsta360PendingFrame?
    private var displayDeliveryScheduled = false
    private var diagnosticsPreviewVisible = false
    private var geminiVideoDemandActive = false
    private var remoteVideoDemandActive = false
    private var recordingVideoDemandActive = false
    private var recordingPreviewResolution: String?
    private var activeDecoderURL: String?
    private var lastFrameAt: Date?
    private var observedPreviewConfigurationIdentity = ""

    public private(set) var state = "Stopped"
    public private(set) var streamURL = "rtmp://10.0.0.18:1935/live/preview"
    public private(set) var latestFrame: NSImage?
    public private(set) var framesReceived: UInt64 = 0
    public private(set) var decodedBytes: UInt64 = 0
    public private(set) var framesPerSecond: Double = 0
    public private(set) var lastError: String?
    public private(set) var previewSettingsPending = false
    // This reference is read only from `queue`. Keeping registration on that
    // same queue prevents the decoder callback from racing startup/shutdown.
    private weak var geminiFrameConsumer: ROBInsta360VideoFrameConsumer?
    private weak var recordingFrameConsumer: ROBInsta360VideoFrameConsumer?

    /// The unstabilized host/projection that was successfully applied in this
    /// process. Nil means robot-relative FRONT/REAR calibration is currently
    /// ineligible, not merely that the diagnostics window is closed.
    public var calibrationProjectionIdentity: String? {
        ROBGeminiVideoSourceSettings.shared.insta360AppliedPreviewProjectionIdentity
    }

    /// Stabilization is opt-out: a new install always requests the camera's
    /// gyro-stabilized panorama unless a developer explicitly disables it.
    public var gyroStabilizationEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: Self.gyroStabilizationDefaultsKey) != nil else { return true }
            return defaults.bool(forKey: Self.gyroStabilizationDefaultsKey)
        }
        set {
            guard gyroStabilizationEnabled != newValue else { return }
            UserDefaults.standard.set(newValue, forKey: Self.gyroStabilizationDefaultsKey)
            // Gyro stabilization changes panorama yaw without a compensating
            // transform in Cerebro. Withdraw and erase robot-relative
            // calibration before the camera command is applied.
            let settings = ROBGeminiVideoSourceSettings.shared
            settings.invalidateInsta360OrientationCalibration()
            settings.setInsta360AppliedPreviewProjectionIdentity(nil)
            DispatchQueue.main.async {
                self.previewSettingsPending = true
                NotificationCenter.default.post(name: .robInsta360CameraServiceDidChange, object: self)
            }
        }
    }

    private override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        // Starting the on-camera stitcher can take well over ten seconds.
        // Heartbeats run concurrently while command requests use this longer
        // resource deadline.
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        super.init()
        observedPreviewConfigurationIdentity = requestedPreviewConfigurationIdentity
        let requestedCalibrationIdentity = calibrationProjectionIdentity(
            host: cameraHost,
            stabilizationEnabled: gyroStabilizationEnabled
        )
        let storedCalibrationIdentity = UserDefaults.standard.string(
            forKey: GeminiRoboticsRuntimeSettings
                .insta360CalibrationProjectionIdentityDefaultsKey
        )
        if storedCalibrationIdentity != nil,
           storedCalibrationIdentity != requestedCalibrationIdentity {
            // A known host/projection/gyro mismatch is materially different
            // from waiting for camera confirmation, so fail closed immediately.
            ROBGeminiVideoSourceSettings.shared
                .invalidateInsta360OrientationCalibration()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(perceptionSettingsDidChange(_:)),
            name: .robDetectorSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(perceptionSettingsDidChange(_:)),
            name: .robMLXRuntimeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(previewDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteVideoDemandDidChange(_:)),
            name: .robVideoCameraDemandDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func perceptionSettingsDidChange(_ notification: Notification) {
        refreshDecoderDemand()
    }

    @objc private func remoteVideoDemandDidChange(_ notification: Notification) {
        guard notification.userInfo?[ROBVideoCameraDemandNotification.cameraIDKey]
                as? String == "insta360",
              let active = notification.userInfo?[
                ROBVideoCameraDemandNotification.isActiveKey
              ] as? Bool else { return }
        queue.async {
            self.remoteVideoDemandActive = active
            self.reevaluateDecoderDemand()
        }
    }

    /// Also catches an externally edited camera host. Calibration is cleared
    /// only when the stable host/projection/stabilization configuration really
    /// changes, never for frame delivery or a reconnect with the same values.
    @objc private func previewDefaultsDidChange(_ notification: Notification) {
        queue.async {
            let requestedIdentity = self.requestedPreviewConfigurationIdentity
            guard requestedIdentity != self.observedPreviewConfigurationIdentity else { return }
            self.observedPreviewConfigurationIdentity = requestedIdentity
            let settings = ROBGeminiVideoSourceSettings.shared
            settings.invalidateInsta360OrientationCalibration()
            settings.setInsta360AppliedPreviewProjectionIdentity(nil)
            DispatchQueue.main.async {
                self.previewSettingsPending = true
                NotificationCenter.default.post(
                    name: .robInsta360CameraServiceDidChange,
                    object: self
                )
            }
        }
    }

    public func start() {
        queue.async {
            guard !self.desiredRunning else { return }
            self.desiredRunning = true
            self.generation &+= 1
            self.retryAttempt = 0
            self.connect(generation: self.generation)
        }
    }

    public func recoverAfterWake() {
        queue.async {
            guard self.desiredRunning else { return }
            self.generation &+= 1
            self.cancelRuntime()
            self.retryAttempt = 0
            self.connect(generation: self.generation)
        }
    }

    public func restart() {
        queue.async {
            self.desiredRunning = true
            if self.fingerprint != nil {
                self.reconfigurePreviewOnQueue()
                return
            }
            self.generation &+= 1
            let relinquishingOwnedSession = self.fingerprint != nil
            self.stopOwnedPreview(generation: self.generation)
            self.cancelRuntime()
            self.retryAttempt = 0
            let restartGeneration = self.generation
            let delay = relinquishingOwnedSession ? 11.0 : 0.0
            self.publish(state: delay > 0 ? "Restarting after camera lease expires…" : "Restarting…", error: nil)
            let work = DispatchWorkItem { [weak self] in self?.connect(generation: restartGeneration) }
            self.retryWorkItem = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    public func setDiagnosticsPreviewVisible(_ visible: Bool) {
        queue.async {
            self.diagnosticsPreviewVisible = visible
            self.reevaluateDecoderDemand()
        }
    }

    /// Registers Gemini's raw-JPEG consumer without making it part of the
    /// AppKit preview path. Registration and frame delivery are serialized on
    /// the camera service queue.
    public func setGeminiFrameConsumer(_ consumer: ROBInsta360VideoFrameConsumer?) {
        queue.async {
            self.geminiFrameConsumer = consumer
        }
    }

    /// Registers the footage recorder independently from Gemini and AppKit.
    public func setRecordingFrameConsumer(_ consumer: ROBInsta360VideoFrameConsumer?) {
        queue.async {
            self.recordingFrameConsumer = consumer
        }
    }

    /// Adds Gemini as an independent, headless consumer of the stitched
    /// preview. This affects decoder demand only; the raw frame still passes
    /// through ROBAI's connection, source, generation, and rate gates before
    /// it can leave the Mac.
    public func setGeminiVideoDemandActive(_ active: Bool) {
        queue.async {
            guard self.geminiVideoDemandActive != active else { return }
            self.geminiVideoDemandActive = active
            self.reevaluateDecoderDemand()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .robInsta360CameraServiceDidChange,
                    object: self
                )
            }
        }
    }

    /// Makes the stitched stream available to explicit footage recording.
    /// 3840x1920 is the Pro Camera API's documented high-resolution pano
    /// preview; nil restores the ordinary 1920x960 perception preview.
    public func setRecordingVideoDemandActive(_ active: Bool, resolution: String?) {
        queue.async {
            let normalized = active ? Self.normalizedRecordingResolution(resolution) : nil
            let resolutionChanged = self.recordingPreviewResolution != normalized
            let demandChanged = self.recordingVideoDemandActive != active
            guard resolutionChanged || demandChanged else { return }
            self.recordingVideoDemandActive = active
            self.recordingPreviewResolution = normalized
            if resolutionChanged, self.desiredRunning, self.fingerprint != nil {
                self.reconfigurePreviewOnQueue()
            } else {
                self.reevaluateDecoderDemand()
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .robInsta360CameraServiceDidChange,
                    object: self
                )
            }
        }
    }

    public func refreshDecoderDemand() {
        queue.async { self.reevaluateDecoderDemand() }
    }

    /// A lock-consistent, observational snapshot for the service grid. It
    /// never starts the camera, decoder, diagnostics UI, or a network request.
    @nonobjc func statusSnapshot() -> ROBInsta360ServiceStatusSnapshot {
        precondition(Thread.isMainThread, "Insta360 status is presented on the main thread")
        let displayedState = state
        let displayedURL = streamURL
        let displayedError = lastError
        return queue.sync {
            ROBInsta360ServiceStatusSnapshot(
                state: displayedState,
                streamURL: displayedURL,
                lastError: displayedError,
                desiredRunning: desiredRunning,
                decoderActive: decoder != nil,
                diagnosticsPreviewVisible: diagnosticsPreviewVisible,
                analysisNeedsFrames: analysisNeedsFrames,
                geminiVideoDemandActive: geminiVideoDemandActive,
                framesReceived: framesReceived,
                decodedBytes: decodedBytes,
                framesPerSecond: framesPerSecond,
                lastFrameAt: lastFrameAt
            )
        }
    }

    private var analysisNeedsFrames: Bool {
        geminiVideoDemandActive
            || recordingVideoDemandActive
            || remoteVideoDemandActive
            || localAnalysisNeedsFrames
    }

    private var localAnalysisNeedsFrames: Bool {
        let registry = ROBDynamicDetectorRegistry.shared
        guard registry.processingFramesPerSecond(for: .insta360) > 0 else { return false }
        return ROBMLXRuntime.shared.insta360DetectionEnabled
            || registry.requiresFrames(for: .insta360)
    }

    private func reevaluateDecoderDemand() {
        guard desiredRunning, let url = activeDecoderURL else { return }
        if diagnosticsPreviewVisible || analysisNeedsFrames {
            if decoder == nil { startDecoder(url: url, generation: generation) }
        } else if decoder != nil {
            stopDecoder()
            publish(state: "Preview suspended — no active consumers", error: nil)
        }
    }

    /// Applies preview-only options without relinquishing the Pro 2's
    /// single-client fingerprint. Heartbeats continue throughout.
    private func reconfigurePreview() {
        queue.async { self.reconfigurePreviewOnQueue() }
    }

    private func reconfigurePreviewOnQueue() {
        guard desiredRunning, let fingerprint else { return }
        let activeGeneration = generation
        stopDecoder()
        publish(state: "Applying preview settings…", error: nil)
        executeCommand(
            ["name": "camera._stopPreview"],
            fingerprint: fingerprint,
            generation: activeGeneration
        ) { _ in
            // The same fingerprint and heartbeat remain active, so the
            // camera never sees a competing client during this change.
            self.startPreview(existingURL: self.streamURL, generation: activeGeneration)
        }
    }

    public func stop() {
        queue.async {
            guard self.desiredRunning || self.fingerprint != nil else { return }
            self.desiredRunning = false
            self.generation &+= 1
            self.stopOwnedPreview(generation: self.generation)
            self.cancelRuntime()
            self.publish(state: "Stopped", error: nil)
        }
    }

    private var cameraHost: String {
        let configured = UserDefaults.standard.string(forKey: Self.cameraHostDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false ? configured! : "10.0.0.18"
    }

    private var requestedStitchedPreviewSize: (width: Int, height: Int) {
        recordingPreviewResolution == "3840x1920" ? (3840, 1920) : (1920, 960)
    }

    private static func normalizedRecordingResolution(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "3840x1920": return "3840x1920"
        case "1920x960": return "1920x960"
        default: return nil
        }
    }

    private var requestedPreviewConfigurationIdentity: String {
        previewConfigurationIdentity(
            host: cameraHost,
            stabilizationEnabled: gyroStabilizationEnabled
        )
    }

    private func previewConfigurationIdentity(
        host: String,
        stabilizationEnabled: Bool
    ) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "host=\(normalizedHost)|projection=\(Self.calibrationProjectionDescriptor)|gyro=\(stabilizationEnabled ? "on" : "off")"
    }

    private func calibrationProjectionIdentity(
        host: String,
        stabilizationEnabled: Bool
    ) -> String? {
        guard !stabilizationEnabled else { return nil }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "host=\(normalizedHost)|projection=\(Self.calibrationProjectionDescriptor)|gyro=off"
    }

    private func connect(generation: UInt64) {
        guard desiredRunning, generation == self.generation else { return }
        publish(state: "Connecting to \(cameraHost)…", error: nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMddHHmmyyyy.ss"
        let offset = TimeZone.current.secondsFromGMT()
        let sign = offset >= 0 ? "+" : "-"
        let absoluteOffset = abs(offset)
        let zone = String(format: "GMT%@%02d:%02d", sign, absoluteOffset / 3600, (absoluteOffset % 3600) / 60)
        executeCommand(
            ["name": "camera._connect", "parameters": ["hw_time": formatter.string(from: Date()), "time_zone": zone]],
            fingerprint: "",
            generation: generation
        ) { result in
            guard let results = result["results"] as? [String: Any],
                  let fingerprint = results["Fingerprint"] as? String,
                  !fingerprint.isEmpty else {
                self.failAndRetry("Camera did not return a session fingerprint", generation: generation)
                return
            }
            self.fingerprint = fingerprint
            // Ownership expires after ten seconds without state polling. Start
            // the heartbeat before asking the camera to initialize its slower
            // stitching/preview pipeline.
            self.heartbeatFailures = 0
            self.heartbeatInFlight = false
            self.startHeartbeat(generation: generation)
            let urls = results["url_list"] as? [String: Any]
            let advertised = urls?["_previewUrl"] as? String
            self.startPreview(existingURL: advertised, generation: generation)
        }
    }

    private func startPreview(existingURL: String?, generation: UInt64) {
        let requestedHost = cameraHost
        let stabilizationEnabled = gyroStabilizationEnabled
        let requestedConfigurationIdentity = previewConfigurationIdentity(
            host: requestedHost,
            stabilizationEnabled: stabilizationEnabled
        )
        let eligibleCalibrationIdentity = calibrationProjectionIdentity(
            host: requestedHost,
            stabilizationEnabled: stabilizationEnabled
        )
        if stabilizationEnabled {
            // This is a known ineligible projection, not a transient lack of
            // camera confirmation, so any saved robot-relative calibration is
            // intentionally erased. Reconnects do not repeat a material write.
            let settings = ROBGeminiVideoSourceSettings.shared
            settings.invalidateInsta360OrientationCalibration()
            settings.setInsta360AppliedPreviewProjectionIdentity(nil)
        }
        if observedPreviewConfigurationIdentity != requestedConfigurationIdentity {
            observedPreviewConfigurationIdentity = requestedConfigurationIdentity
            let settings = ROBGeminiVideoSourceSettings.shared
            settings.invalidateInsta360OrientationCalibration()
            settings.setInsta360AppliedPreviewProjectionIdentity(nil)
        }
        let stitchedSize = requestedStitchedPreviewSize
        let command: [String: Any] = [
            "name": "camera._startPreview",
            "parameters": [
                "origin": ["mime": "h264", "width": 1920, "height": 1440, "framerate": 30, "bitrate": 20480],
                "stiching": [
                    "mode": "pano", "mime": "h264",
                    "width": stitchedSize.width, "height": stitchedSize.height,
                    "framerate": 30,
                    "bitrate": stitchedSize.width > 1920 ? 10240 : 4096
                ]
            ],
            // ProCameraApi defines stabilization beside parameters rather than
            // inside the capture-options dictionary.
            "stabilization": stabilizationEnabled
        ]
        executeCommand(command, fingerprint: fingerprint ?? "", generation: generation) { result in
            let results = result["results"] as? [String: Any]
            let advertisedURL = (results?["_previewUrl"] as? String)
                ?? existingURL
                ?? "rtmp://\(self.cameraHost):1935/live/preview"
            let url = self.normalizedPreviewURL(advertisedURL)
            self.retryAttempt = 0
            self.heartbeatFailures = 0
            let requestedConfigurationIsStillCurrent =
                self.requestedPreviewConfigurationIdentity == requestedConfigurationIdentity
            ROBGeminiVideoSourceSettings.shared.setInsta360AppliedPreviewProjectionIdentity(
                requestedConfigurationIsStillCurrent ? eligibleCalibrationIdentity : nil
            )
            DispatchQueue.main.async {
                self.previewSettingsPending = !requestedConfigurationIsStillCurrent
            }
            self.publishStreamURL(url)
            self.startDecoder(url: url, generation: generation)
        }
    }

    private func executeCommand(_ json: [String: Any], fingerprint: String, generation: UInt64,
                                completion: @escaping ([String: Any]) -> Void) {
        guard let url = URL(string: "http://\(cameraHost):20000/osc/commands/execute") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(fingerprint, forHTTPHeaderField: "Fingerprint")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        session.dataTask(with: request) { data, response, error in
            self.queue.async {
                guard self.desiredRunning, generation == self.generation else { return }
                guard error == nil,
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.failAndRetry(error?.localizedDescription ?? "Camera HTTP request failed", generation: generation)
                    return
                }
                guard object["state"] as? String == "done" else {
                    let detail = (object["error"] as? [String: Any])?["description"] as? String
                        ?? "Camera rejected \(json["name"] as? String ?? "command")"
                    self.failAndRetry(detail, generation: generation)
                    return
                }
                completion(object)
            }
        }.resume()
    }

    private func startHeartbeat(generation: UInt64) {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.pollState(generation: generation) }
        heartbeatTimer = timer
        timer.resume()
    }

    private func pollState(generation: UInt64) {
        guard desiredRunning, generation == self.generation, let fingerprint, !heartbeatInFlight else { return }
        heartbeatInFlight = true
        guard let url = URL(string: "http://\(cameraHost):20000/osc/state") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(fingerprint, forHTTPHeaderField: "Fingerprint")
        session.dataTask(with: request) { data, response, error in
            self.queue.async {
                guard self.desiredRunning, generation == self.generation else { return }
                self.heartbeatInFlight = false
                let healthy = error == nil && data != nil && ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
                self.heartbeatFailures = healthy ? 0 : self.heartbeatFailures + 1
                if self.heartbeatFailures >= 3 {
                    self.failAndRetry(error?.localizedDescription ?? "Camera heartbeat failed", generation: generation)
                }
            }
        }.resume()
    }

    private func startDecoder(url: String, generation: UInt64) {
        stopDecoder()
        activeDecoderURL = url
        guard diagnosticsPreviewVisible || analysisNeedsFrames else {
            publish(state: "Preview suspended — no active consumers", error: nil)
            return
        }
        guard let executable = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            failAndRetry("ffmpeg is unavailable", generation: generation)
            return
        }
        let output = Pipe()
        let errors = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["-hide_banner", "-loglevel", "warning", "-i", url, "-an", "-sn", "-dn", "-vf", "fps=15", "-q:v", "5", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1"]
        task.standardOutput = output
        task.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.queue.async { self?.consumeVideo(data, generation: generation) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.queue.async { self?.consumeDecoderError(data) } }
        }
        task.terminationHandler = { [weak self] finished in
            self?.queue.async {
                guard let self, self.desiredRunning, generation == self.generation, self.decoder === finished else { return }
                let detail = String(data: self.decoderErrorTail.suffix(500), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "decoder stopped"
                self.decoder = nil
                self.decoderOutput = nil
                self.decoderError = nil
                ROBDynamicDetectorRegistry.shared.invalidatePendingResults(for: .insta360)
                let message = detail.replacingOccurrences(of: "\n", with: " ")
                NSLog("Insta360 decoder error: %@; retrying decoder without releasing camera ownership", message)
                self.publish(state: "Waiting for preview stream…", error: message)
                self.queue.asyncAfter(deadline: .now() + 2) {
                    guard self.desiredRunning, generation == self.generation, self.decoder == nil else { return }
                    self.startDecoder(url: url, generation: generation)
                }
            }
        }
        do {
            try task.run()
            decoder = task
            decoderOutput = output
            decoderError = errors
            jpegBuffer.removeAll(keepingCapacity: true)
            decoderErrorTail.removeAll(keepingCapacity: true)
            framesReceived = 0
            decodedBytes = 0
            framesPerSecond = 0
            startedAt = Date()
            publish(state: "Receiving preview", error: nil)
        } catch {
            failAndRetry("Could not launch ffmpeg: \(error.localizedDescription)", generation: generation)
        }
    }

    private func consumeVideo(_ data: Data, generation: UInt64) {
        guard desiredRunning, generation == self.generation else { return }
        decodedBytes &+= UInt64(data.count)
        jpegBuffer.append(data)
        let soi = Data([0xff, 0xd8]), eoi = Data([0xff, 0xd9])
        while let start = jpegBuffer.range(of: soi),
              let end = jpegBuffer.range(of: eoi, in: start.lowerBound..<jpegBuffer.endIndex) {
            let frameEnd = end.upperBound
            let jpeg = jpegBuffer.subdata(in: start.lowerBound..<frameEnd)
            jpegBuffer.removeSubrange(jpegBuffer.startIndex..<frameEnd)
            framesReceived &+= 1
            framesPerSecond = Double(framesReceived) / max(Date().timeIntervalSince(startedAt ?? Date()), 0.001)
            let capturedAt = Date()
            let capturedAtUptime = ProcessInfo.processInfo.systemUptime
            lastFrameAt = capturedAt

            // Gemini consumes the completed JPEG directly from the service
            // queue. In particular, capture age is measured from this
            // monotonic timestamp and cannot be hidden by a busy main thread
            // or by optional NSImage decoding for diagnostics.
            if geminiVideoDemandActive {
                geminiFrameConsumer?.consumeInsta360JPEGFrame(
                    jpeg,
                    capturedAt: capturedAt,
                    capturedAtUptime: capturedAtUptime
                )
            }
            if recordingVideoDemandActive {
                recordingFrameConsumer?.consumeInsta360JPEGFrame(
                    jpeg,
                    capturedAt: capturedAt,
                    capturedAtUptime: capturedAtUptime
                )
            }
            if remoteVideoDemandActive, #available(macOS 12.0, *) {
                ROBVideoServerRegistry.shared.offerInsta360JPEG(jpeg)
            }

            // AppKit and local perception remain latest-only consumers on the
            // main thread, and incur no work when neither feature is enabled.
            if diagnosticsPreviewVisible || localAnalysisNeedsFrames {
                pendingDisplayFrame = ROBInsta360PendingFrame(
                    jpegData: jpeg,
                    capturedAt: capturedAt
                )
                scheduleLatestFrameDelivery()
            }
        }
        if jpegBuffer.count > 32_000_000 { jpegBuffer.removeAll(keepingCapacity: true) }
    }

    /// Keeps at most one main-thread delivery outstanding. If decoding is
    /// faster than AppKit can draw, intermediate frames are replaced by the
    /// newest one instead of building an ever-older playback queue.
    private func scheduleLatestFrameDelivery() {
        guard !displayDeliveryScheduled else { return }
        displayDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async {
                let frame = self.pendingDisplayFrame
                self.pendingDisplayFrame = nil
                self.displayDeliveryScheduled = false
                let deliverToLocalConsumers = self.diagnosticsPreviewVisible
                    || self.localAnalysisNeedsFrames
                guard let frame else { return }
                DispatchQueue.main.async {
                    guard deliverToLocalConsumers,
                          let image = NSImage(data: frame.jpegData) else {
                        self.queue.async {
                            if self.pendingDisplayFrame != nil { self.scheduleLatestFrameDelivery() }
                        }
                        return
                    }
                    self.latestFrame = image
                    ROBInsta360PerceptionService.shared.offer(
                        image,
                        capturedAt: frame.capturedAt
                    )
                    ROBDynamicDetectorRegistry.shared.offer(
                        image,
                        source: .insta360,
                        capturedAt: frame.capturedAt
                    )
                    NotificationCenter.default.post(name: .robInsta360CameraServiceDidChange, object: self)
                    self.queue.async {
                        if self.pendingDisplayFrame != nil { self.scheduleLatestFrameDelivery() }
                    }
                }
            }
        }
    }

    private func consumeDecoderError(_ data: Data) {
        decoderErrorTail.append(data)
        if decoderErrorTail.count > 4096 { decoderErrorTail = decoderErrorTail.suffix(4096) }
    }

    private func normalizedPreviewURL(_ advertised: String) -> String {
        guard var components = URLComponents(string: advertised) else {
            return "rtmp://\(cameraHost):1935/live/preview"
        }
        let localHosts = ["127.0.0.1", "localhost", "0.0.0.0", "::1"]
        if let host = components.host?.lowercased(), localHosts.contains(host) {
            components.host = cameraHost
        }
        return components.url?.absoluteString ?? "rtmp://\(cameraHost):1935/live/preview"
    }

    private func failAndRetry(_ message: String, generation: UInt64) {
        guard desiredRunning, generation == self.generation else { return }
        let relinquishingOwnedSession = fingerprint != nil
        if relinquishingOwnedSession {
            // Best effort. Even if this request fails, stopping heartbeats
            // guarantees that the Pro 2 expires our lease after 10 seconds.
            stopOwnedPreview(generation: generation)
        }
        self.generation &+= 1
        let nextGeneration = self.generation
        cancelRuntime()
        // Never race our own old fingerprint. The camera calls that expired
        // lease "another client" until its 10-second heartbeat timeout passes.
        let cameraReportsOwner = message.localizedCaseInsensitiveContains("already connected")
            || message.localizedCaseInsensitiveContains("another client")
        let delay = max((relinquishingOwnedSession || cameraReportsOwner) ? 11.0 : 0.0,
                        min(pow(2.0, Double(retryAttempt)), 30.0))
        retryAttempt = min(retryAttempt + 1, 6)
        NSLog("Insta360 service error: %@; retrying in %.0f seconds", message, delay)
        publish(state: String(format: "Retrying in %.0f seconds", delay), error: message)
        let work = DispatchWorkItem { [weak self] in self?.connect(generation: nextGeneration) }
        retryWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopOwnedPreview(generation: UInt64) {
        guard let fingerprint else { return }
        guard let url = URL(string: "http://\(cameraHost):20000/osc/commands/execute") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(fingerprint, forHTTPHeaderField: "Fingerprint")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": "camera._stopPreview"])
        session.dataTask(with: request).resume()
    }

    private func cancelRuntime() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        fingerprint = nil
        heartbeatFailures = 0
        heartbeatInFlight = false
        stopDecoder()
        activeDecoderURL = nil
    }

    private func stopDecoder() {
        decoderOutput?.fileHandleForReading.readabilityHandler = nil
        decoderError?.fileHandleForReading.readabilityHandler = nil
        decoderOutput = nil
        decoderError = nil
        let task = decoder
        decoder = nil
        pendingDisplayFrame = nil
        if task?.isRunning == true { task?.terminate() }
        ROBDynamicDetectorRegistry.shared.invalidatePendingResults(for: .insta360)
    }

    private func publish(state: String, error: String?) {
        DispatchQueue.main.async {
            self.state = state
            self.lastError = error
            NotificationCenter.default.post(name: .robInsta360CameraServiceDidChange, object: self)
        }
    }

    private func publishStreamURL(_ url: String) {
        DispatchQueue.main.async {
            self.streamURL = url
            NotificationCenter.default.post(name: .robInsta360CameraServiceDidChange, object: self)
        }
    }
}
