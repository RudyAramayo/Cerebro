//
//  CameraManager.swift
//  Cerebro
//
//  DepthAI is intentionally hosted out of process.  This file consumes the
//  helper's versioned RGB + aligned-depth stream and retains AVFoundation as
//  an RGB-only fallback for ordinary webcams. Luxonis UVC fallback is opt-in.
//

import AVFoundation
import Cocoa
import Network

enum CameraError: LocalizedError {
    case cannotDetectCameraDevice
    case cannotAddInput
    case cannotAddOutput
    case videoSessionNil

    var errorDescription: String? {
        switch self {
        case .cannotDetectCameraDevice: return "Cannot detect an accessible camera device."
        case .cannotAddInput: return "Cannot add the selected camera input."
        case .cannotAddOutput: return "Cannot add the camera video output."
        case .videoSessionNil: return "The camera video session is unavailable."
        }
    }
}

enum CameraSource: String {
    case depthAIService
    case avFoundationRGB
}

enum CameraSourceState: String {
    case stopped
    case connecting
    case streamingRGB
    case streamingRGBD
    case reconnecting
    case unavailable
}

/// A depth image aligned pixel-for-pixel to the RGB image in the same frame set.
/// Values are little-endian UInt16 millimeters; zero means that depth is invalid.
struct CameraDepthFrame {
    let width: Int
    let height: Int
    let millimetersLittleEndian: Data

    func distanceMillimeters(x: Int, y: Int) -> UInt16? {
        guard width > 0, height > 0, x >= 0, x < width, y >= 0, y < height else { return nil }
        let (rowOffset, rowOverflow) = y.multipliedReportingOverflow(by: width)
        let (pixelOffset, pixelOverflow) = rowOffset.addingReportingOverflow(x)
        let (offset, byteOverflow) = pixelOffset.multipliedReportingOverflow(
            by: MemoryLayout<UInt16>.size
        )
        guard !rowOverflow, !pixelOverflow, !byteOverflow,
              millimetersLittleEndian.count >= MemoryLayout<UInt16>.size,
              offset <= millimetersLittleEndian.count - MemoryLayout<UInt16>.size else {
            return nil
        }
        let value: UInt16 = millimetersLittleEndian.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        return value == 0 ? nil : value
    }
}

/// Pinhole calibration for the RGB image to which depth is aligned.
struct CameraIntrinsics: Sendable {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double

    func isValid(forWidth width: Int, height: Int) -> Bool {
        fx.isFinite && fy.isFinite && cx.isFinite && cy.isFinite
            && fx > 0 && fy > 0 && cx >= 0 && cy >= 0
            && cx < Double(width) && cy < Double(height)
    }
}

/// Rectified grayscale views from the OAK stereo pair. These remain useful
/// when tuning IR illumination, validating calibration, and debugging depth.
struct CameraStereoFrame {
    let width: Int
    let height: Int
    let pixels: Data
}

/// The common frame contract used by RGB-only and RGB-D camera providers.
struct CameraFrameSet {
    let source: CameraSource
    let sequence: UInt64
    let timestampNanoseconds: UInt64
    let rgbSampleBuffer: CMSampleBuffer
    let alignedDepth: CameraDepthFrame?
    var intrinsics: CameraIntrinsics? = nil
    var rectifiedLeft: CameraStereoFrame? = nil
    var rectifiedRight: CameraStereoFrame? = nil
}

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManagerProtocol, didOutput frameSet: CameraFrameSet)
    func cameraManager(
        _ manager: CameraManagerProtocol,
        didChange state: CameraSourceState,
        detail: String?
    )
}

extension CameraManagerDelegate {
    func cameraManager(
        _ manager: CameraManagerProtocol,
        didChange state: CameraSourceState,
        detail: String?
    ) {
        // State reporting is optional for existing consumers.
    }
}

protocol CameraManagerProtocol: AnyObject {
    var delegate: CameraManagerDelegate? { get set }
    /// A cheap, nonblocking tap that runs before perception's latest-frame
    /// gate. Consumers must retain anything they use asynchronously.
    var videoSampleHandler: ((CMSampleBuffer) -> Void)? { get set }

    func startSession() throws
    func stopSession() throws
    func bindCamera() throws
    func bindCameraRebootSession() throws
}

final class CameraManager: NSObject, CameraManagerProtocol {
    private static let depthCameraSocketDefaultsKey = "ROBDepthCameraSocketPath"
    private static let depthCameraReadyNotification = Notification.Name("ROBDepthCameraServiceReady")
    private static let legacyLuxonisUVCDefaultsKey = "ROBAllowLuxonisUVCFallback"

    private let containerView: NSView
    private let sessionQueue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.camera.session")
    private let captureQueue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.camera.capture")
    private let deliveryQueue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.camera.delivery")
    private let deliveryLock = NSLock()
    private let previewLock = NSLock()

    private var videoSession: AVCaptureSession?
    /// The layer stays alive across source changes. Assigning its `session`
    /// creates or removes an AVCaptureConnection, so that property is mutated
    /// only on sessionQueue with the rest of the capture graph.
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var depthPreviewLayer: AVSampleBufferDisplayLayer?
    private var deviceDiscoverySession: AVCaptureDevice.DiscoverySession
    private var notificationTokens: [NSObjectProtocol] = []
    private var depthClient: DepthCameraServiceClient?
    private var wantsRunning = false
    private var activeSource: CameraSource?
    private var deliveryInFlight = false
    private var previewDeliveryInFlight = false
    private var lifecycleGeneration: UInt64 = 0
    private var acceptedDeliveryGeneration: UInt64 = 0
    private var fallbackSequence: UInt64 = 0
    private var cameraAuthorizationRequestInFlight = false
    private var expectedDepthRunGeneration: UInt64?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var acceptedFallbackOutputID: ObjectIdentifier?
    private var acceptedFallbackOutputGeneration: UInt64?

    weak var delegate: CameraManagerDelegate?
    var videoSampleHandler: ((CMSampleBuffer) -> Void)?

    init(containerView: NSView) {
        let previewLayer: AVCaptureVideoPreviewLayer = {
            dispatchPrecondition(condition: .onQueue(.main))
            return AVCaptureVideoPreviewLayer()
        }()
        self.containerView = containerView
        self.previewLayer = previewLayer
        self.deviceDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        super.init()

        installDeviceObservers()
        installDepthCameraClient()
        configureAVFoundationFallback()
    }

    deinit {
        depthClient?.stop()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)

        // Do not synchronously wait here: deinit can run on captureQueue while
        // sessionQueue is draining it. Capturing only AVFoundation resources
        // lets teardown remain serialized without retaining this manager.
        let session = videoSession
        let output = videoDataOutput
        let previewLayer = previewLayer
        let captureQueue = captureQueue
        sessionQueue.async {
            if session?.isRunning == true {
                session?.stopRunning()
            }
            output?.setSampleBufferDelegate(nil, queue: nil)
            captureQueue.sync {}
            previewLayer.session = nil
        }
    }

    func startSession() throws {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.wantsRunning else { return }
            self.wantsRunning = true
            self.advanceDeliveryGeneration()
            if self.usesLegacyLuxonisUVCMode {
                self.expectedDepthRunGeneration = nil
                self.depthClient?.stop()
                self.report(.connecting, detail: "Starting explicit legacy RGB-only UVC mode.")
            } else {
                self.report(.connecting, detail: "Waiting for the DepthAI RGB-D service.")
                self.expectedDepthRunGeneration = self.depthClient?.start()
            }
            self.startFallbackIfAvailable()
            self.reportUnavailableIfNoUsableSource(
                detail: "No authorized camera source is currently available."
            )
        }
    }

    func stopSession() throws {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.wantsRunning else { return }
            self.wantsRunning = false
            self.expectedDepthRunGeneration = nil
            self.advanceDeliveryGeneration()
            self.depthClient?.stop()
            self.stopFallbackCaptureAndDrainCallbacks()
            self.activeSource = nil
            self.report(.stopped, detail: nil)
        }
    }

    func bindCamera() throws {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.usesLegacyLuxonisUVCMode {
                self.expectedDepthRunGeneration = nil
                self.depthClient?.stop()
            } else {
                self.expectedDepthRunGeneration = self.depthClient?.start()
                self.depthClient?.reconnectNow()
            }
            self.configureAVFoundationFallbackOnSessionQueue()
            self.startFallbackIfAvailable()
        }
    }

    func bindCameraRebootSession() throws {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.usesLegacyLuxonisUVCMode {
                self.expectedDepthRunGeneration = nil
                self.depthClient?.stop()
            } else {
                self.expectedDepthRunGeneration = self.depthClient?.start()
                self.depthClient?.reconnectNow()
            }
            if self.activeSource == .avFoundationRGB {
                self.activeSource = nil
                self.advanceDeliveryGeneration()
            }
            self.stopFallbackCaptureAndDrainCallbacks()
            self.configureAVFoundationFallbackOnSessionQueue()
            self.startFallbackIfAvailable()
        }
    }

    private func installDeviceObservers() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard notification.object is AVCaptureDevice else { return }
            self?.sessionQueue.async {
                self?.configureAVFoundationFallbackOnSessionQueue()
                self?.startFallbackIfAvailable()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice else { return }
            self.sessionQueue.async {
                guard self.videoSession?.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device.uniqueID })
                    .contains(device.uniqueID) == true else { return }
                self.videoSession?.stopRunning()
                self.previewLayer.session = nil
                self.videoSession = nil
                if self.activeSource == .avFoundationRGB {
                    self.activeSource = nil
                    self.advanceDeliveryGeneration()
                    self.report(.reconnecting, detail: "RGB fallback camera disconnected.")
                }
                self.configureAVFoundationFallbackOnSessionQueue()
                self.startFallbackIfAvailable()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: Self.depthCameraReadyNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async {
                guard let self, !self.usesLegacyLuxonisUVCMode else { return }
                self.depthClient?.updateSocketPath(self.configuredDepthCameraSocketPath)
                guard self.wantsRunning else { return }
                self.expectedDepthRunGeneration = self.depthClient?.start()
                self.depthClient?.reconnectNow()
            }
        })
    }

    private var configuredDepthCameraSocketPath: String? {
        let path = UserDefaults.standard.string(forKey: Self.depthCameraSocketDefaultsKey)
        return path?.isEmpty == false ? path : nil
    }

    private var usesLegacyLuxonisUVCMode: Bool {
        UserDefaults.standard.bool(forKey: Self.legacyLuxonisUVCDefaultsKey)
    }

    private func installDepthCameraClient() {
        let client = DepthCameraServiceClient(socketPath: configuredDepthCameraSocketPath)
        client.onStateChange = { [weak self] state, detail, sourceGeneration in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.expectedDepthRunGeneration == sourceGeneration else { return }
                if self.usesLegacyLuxonisUVCMode {
                    if self.activeSource == .depthAIService {
                        self.activeSource = nil
                        self.advanceDeliveryGeneration()
                    }
                    self.startFallbackIfAvailable(
                        detail: "Explicit legacy RGB-only UVC mode is active."
                    )
                    return
                }
                if state == .reconnecting || state == .unavailable {
                    if self.activeSource == .depthAIService {
                        self.activeSource = nil
                        self.advanceDeliveryGeneration()
                    }
                    self.startFallbackIfAvailable(detail: detail.map {
                        "RGB fallback active while DepthAI reconnects: \($0)"
                    })
                    if self.activeSource == .avFoundationRGB {
                        return
                    }
                } else if state == .connecting, self.activeSource == .avFoundationRGB {
                    self.report(.streamingRGB, detail: detail.map {
                        "RGB fallback active while DepthAI connects: \($0)"
                    })
                    return
                }
                self.report(state, detail: detail)
            }
        }
        client.onFrame = { [weak self] frameSet, sourceGeneration in
            self?.receivedDepthFrameSet(frameSet, sourceGeneration: sourceGeneration)
        }
        depthClient = client
    }

    private func receivedDepthFrameSet(
        _ frameSet: CameraFrameSet,
        sourceGeneration: UInt64
    ) {
        let ingressGeneration = currentDeliveryGeneration()
        sessionQueue.async { [weak self] in
            guard let self,
                  self.wantsRunning,
                  !self.usesLegacyLuxonisUVCMode,
                  self.expectedDepthRunGeneration == sourceGeneration,
                  self.deliveryGenerationIsCurrent(ingressGeneration) else { return }
            var deliveryGeneration = ingressGeneration
            if self.activeSource != .depthAIService {
                self.advanceDeliveryGeneration()
                deliveryGeneration = self.currentDeliveryGeneration()
                self.activeSource = .depthAIService
                self.stopFallbackCaptureAndDrainCallbacks()
                self.installDepthPreviewLayer(generation: deliveryGeneration)
                self.report(.streamingRGBD, detail: "Receiving synchronized RGB and aligned depth.")
            }
            self.enqueueLatestPreview(frameSet.rgbSampleBuffer)
            self.deliverLatest(frameSet, generation: deliveryGeneration)
        }
    }

    private func enqueueLatestPreview(_ sampleBuffer: CMSampleBuffer) {
        previewLock.lock()
        guard !previewDeliveryInFlight else {
            previewLock.unlock()
            return
        }
        previewDeliveryInFlight = true
        previewLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let renderer = self.depthPreviewLayer?.sampleBufferRenderer,
               renderer.isReadyForMoreMediaData {
                renderer.enqueue(sampleBuffer)
            }
            self.previewLock.lock()
            self.previewDeliveryInFlight = false
            self.previewLock.unlock()
        }
    }

    private func deliverLatest(_ frameSet: CameraFrameSet, generation: UInt64) {
        deliveryLock.lock()
        guard generation == acceptedDeliveryGeneration else {
            deliveryLock.unlock()
            return
        }
        let shouldDeliverToPerception = !deliveryInFlight
        if shouldDeliverToPerception {
            deliveryInFlight = true
        }
        deliveryLock.unlock()

        // Network video owns its own newest-frame gate and must not inherit the
        // latency of the synchronous Vision work performed by the UI delegate.
        videoSampleHandler?(frameSet.rgbSampleBuffer)
        guard shouldDeliverToPerception else { return }

        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock()
            let shouldDeliver = generation == self.acceptedDeliveryGeneration
            self.deliveryLock.unlock()
            if shouldDeliver {
                self.delegate?.cameraManager(self, didOutput: frameSet)
            }
            self.deliveryLock.lock()
            self.deliveryInFlight = false
            self.deliveryLock.unlock()
        }
    }

    /// Invalidates already queued frames whenever capture stops or ownership
    /// moves between the RGB-only and RGB-D providers. Called on sessionQueue.
    private func advanceDeliveryGeneration() {
        lifecycleGeneration &+= 1
        deliveryLock.lock()
        acceptedDeliveryGeneration = lifecycleGeneration
        acceptedFallbackOutputID = nil
        acceptedFallbackOutputGeneration = nil
        deliveryLock.unlock()
    }

    private func currentDeliveryGeneration() -> UInt64 {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return acceptedDeliveryGeneration
    }

    private func deliveryGenerationIsCurrent(_ generation: UInt64) -> Bool {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return generation == acceptedDeliveryGeneration
    }

    private func configureAVFoundationFallback() {
        sessionQueue.async { [weak self] in
            self?.configureAVFoundationFallbackOnSessionQueue()
        }
    }

    private func configureAVFoundationFallbackOnSessionQueue() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard !cameraAuthorizationRequestInFlight else { return }
            cameraAuthorizationRequestInFlight = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                self?.sessionQueue.async {
                    guard let self else { return }
                    self.cameraAuthorizationRequestInFlight = false
                    self.configureAVFoundationFallbackOnSessionQueue()
                    self.startFallbackIfAvailable()
                    self.reportUnavailableIfNoUsableSource(
                        detail: "Camera access was not granted and no alternate source is available."
                    )
                }
            }
            return
        case .denied:
            removeAVFoundationFallback(detail: "Camera access is denied in System Settings.")
            return
        case .restricted:
            removeAVFoundationFallback(detail: "Camera access is restricted on this Mac.")
            return
        @unknown default:
            removeAVFoundationFallback(detail: "Camera authorization is unavailable.")
            return
        }

        let availableDevices = deviceDiscoverySession.devices
        let allowsLegacyLuxonisUVC = usesLegacyLuxonisUVCMode
        let isLuxonisDevice: (AVCaptureDevice) -> Bool = { device in
            let identity = "\(device.localizedName) \(device.manufacturer) \(device.modelID)".lowercased()
            return identity.contains("luxonis") || identity.contains("oak")
        }
        let eligibleDevices = availableDevices.filter {
            allowsLegacyLuxonisUVC || !isLuxonisDevice($0)
        }
        let defaultDevice = AVCaptureDevice.default(for: .video)
        let preferredDevice = eligibleDevices.first ?? defaultDevice.flatMap {
            allowsLegacyLuxonisUVC || !isLuxonisDevice($0) ? $0 : nil
        }

        guard let cameraDevice = preferredDevice else {
            removeAVFoundationFallback(
                detail: "No eligible RGB fallback camera is currently available."
            )
            return
        }

        if let currentID = videoSession?.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device.uniqueID }).first,
           currentID == cameraDevice.uniqueID {
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: cameraDevice)
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .low
            guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            session.addOutput(output)
            session.commitConfiguration()

            videoSession?.stopRunning()
            previewLayer.session = nil
            if activeSource == .avFoundationRGB {
                activeSource = nil
                advanceDeliveryGeneration()
            }
            videoSession = session
            videoDataOutput = output
            // Setting this property implicitly creates the preview connection.
            // It must complete before startRunning() enumerates connections.
            previewLayer.session = session
        } catch {
            removeAVFoundationFallback(
                detail: "RGB fallback could not bind: \(error.localizedDescription)"
            )
        }
    }

    private func removeAVFoundationFallback(detail: String) {
        videoSession?.stopRunning()
        previewLayer.session = nil
        videoSession = nil
        videoDataOutput = nil
        let wasActiveFallback = activeSource == .avFoundationRGB
        if wasActiveFallback {
            activeSource = nil
            advanceDeliveryGeneration()
        }
        guard wantsRunning else { return }
        if sourceMayStillArriveFromDepthAI {
            if wasActiveFallback {
                report(.reconnecting, detail: detail)
            }
        } else {
            report(.unavailable, detail: detail)
        }
    }

    private var sourceMayStillArriveFromDepthAI: Bool {
        !usesLegacyLuxonisUVCMode && configuredDepthCameraSocketPath != nil
    }

    private func reportUnavailableIfNoUsableSource(detail: String) {
        guard wantsRunning,
              activeSource == nil,
              videoSession == nil,
              !cameraAuthorizationRequestInFlight,
              !sourceMayStillArriveFromDepthAI else { return }
        report(.unavailable, detail: detail)
    }

    private func startFallbackIfAvailable(detail: String? = nil) {
        guard wantsRunning, activeSource != .depthAIService, let session = videoSession else { return }
        if activeSource != .avFoundationRGB {
            advanceDeliveryGeneration()
            installAVFoundationPreviewLayer(generation: currentDeliveryGeneration())
        }
        activeSource = .avFoundationRGB
        if let videoDataOutput {
            deliveryLock.lock()
            acceptedFallbackOutputID = ObjectIdentifier(videoDataOutput)
            acceptedFallbackOutputGeneration = acceptedDeliveryGeneration
            deliveryLock.unlock()
        }
        if !session.isRunning {
            session.startRunning()
        }
        report(.streamingRGB, detail: detail ?? "Using the AVFoundation RGB-only fallback.")
    }

    /// `stopRunning()` prevents new capture, while draining the serial delegate
    /// queue ensures callbacks already emitted by the old run cannot execute
    /// after a subsequent run has installed its generation token.
    private func stopFallbackCaptureAndDrainCallbacks() {
        videoSession?.stopRunning()
        captureQueue.sync {}
    }

    private func installAVFoundationPreviewLayer(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.deliveryGenerationIsCurrent(generation) else { return }
            self.depthPreviewLayer?.removeFromSuperlayer()
            self.depthPreviewLayer = nil

            self.previewLayer.videoGravity = .resizeAspectFill
            self.previewLayer.frame = self.containerView.bounds
            self.containerView.wantsLayer = true
            self.containerView.layer = self.previewLayer
        }
    }

    private func installDepthPreviewLayer(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.deliveryGenerationIsCurrent(generation) else { return }
            self.previewLayer.removeFromSuperlayer()

            let layer = AVSampleBufferDisplayLayer()
            layer.videoGravity = .resizeAspectFill
            layer.frame = self.containerView.bounds
            self.containerView.wantsLayer = true
            self.containerView.layer = layer
            self.depthPreviewLayer = layer
        }
    }

    private func report(_ state: CameraSourceState, detail: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.cameraManager(self, didChange: state, detail: detail)
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        deliveryLock.lock()
        let ingressGeneration = acceptedFallbackOutputID == ObjectIdentifier(output)
            ? acceptedFallbackOutputGeneration
            : nil
        deliveryLock.unlock()
        guard let ingressGeneration else { return }
        sessionQueue.async { [weak self] in
            guard let self,
                  self.wantsRunning,
                  self.activeSource != .depthAIService,
                  self.deliveryGenerationIsCurrent(ingressGeneration) else { return }
            self.fallbackSequence &+= 1
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampNanoseconds: UInt64
            if timestamp.isValid && timestamp.seconds >= 0 {
                timestampNanoseconds = UInt64(timestamp.seconds * 1_000_000_000)
            } else {
                timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
            }
            self.deliverLatest(CameraFrameSet(
                source: .avFoundationRGB,
                sequence: self.fallbackSequence,
                timestampNanoseconds: timestampNanoseconds,
                rgbSampleBuffer: sampleBuffer,
                alignedDepth: nil
            ), generation: ingressGeneration)
        }
    }
}

private final class DepthCameraServiceClient {
    private static let protocolMagic = Data([0x43, 0x44, 0x50, 0x31]) // CDP1
    private static let protocolVersion = 2
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumPayloadBytes = 64 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.depth-camera-ipc")
    private let lifecycleLock = NSLock()
    private var socketPath: String?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var shouldRun = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var reportedStreaming = false
    private var requestedShouldRun = false
    private var requestedRunGeneration: UInt64 = 0
    private var activeRunGeneration: UInt64 = 0

    var onFrame: ((CameraFrameSet, UInt64) -> Void)?
    var onStateChange: ((CameraSourceState, String?, UInt64) -> Void)?

    init(socketPath: String?) {
        self.socketPath = socketPath
    }

    func updateSocketPath(_ path: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.socketPath != path {
                self.socketPath = path
                self.cancelConnection()
            }
        }
    }

    @discardableResult
    func start() -> UInt64 {
        lifecycleLock.lock()
        let shouldEnqueue = !requestedShouldRun
        if shouldEnqueue {
            requestedShouldRun = true
            requestedRunGeneration &+= 1
        }
        let generation = requestedRunGeneration
        lifecycleLock.unlock()
        if shouldEnqueue {
            queue.async { [weak self] in
                guard let self else { return }
                self.activeRunGeneration = generation
                self.shouldRun = true
                self.connectIfPossible()
            }
        }
        return generation
    }

    func stop() {
        lifecycleLock.lock()
        guard requestedShouldRun else {
            lifecycleLock.unlock()
            return
        }
        requestedShouldRun = false
        requestedRunGeneration &+= 1
        let generation = requestedRunGeneration
        lifecycleLock.unlock()
        queue.async {
            self.activeRunGeneration = generation
            self.shouldRun = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.cancelConnection()
            self.onStateChange?(.stopped, nil, generation)
        }
    }

    func reconnectNow() {
        queue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.reconnectAttempt = 0
            self.cancelConnection()
            self.connectIfPossible()
        }
    }

    private func connectIfPossible() {
        guard shouldRun, connection == nil else { return }
        guard let socketPath, !socketPath.isEmpty else {
            scheduleReconnect(detail: "Depth camera service has not published its socket yet.")
            return
        }

        onStateChange?(.connecting, "Connecting to the DepthAI helper.", activeRunGeneration)
        let newConnection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.connection === newConnection else { return }
            switch state {
            case .ready:
                self.reconnectAttempt = 0
                self.reportedStreaming = false
                self.receiveBuffer.removeAll(keepingCapacity: true)
                self.receiveNext(on: newConnection)
            case .failed(let error):
                self.connection = nil
                newConnection.cancel()
                self.scheduleReconnect(detail: "Depth camera IPC failed: \(error.localizedDescription)")
            case .cancelled:
                if self.connection === newConnection {
                    self.connection = nil
                }
            case .waiting(let error):
                self.onStateChange?(
                    .reconnecting,
                    "Depth camera IPC is waiting: \(error.localizedDescription)",
                    self.activeRunGeneration
                )
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receiveNext(on activeConnection: NWConnection) {
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024 * 1024) {
            [weak self, weak activeConnection] data, _, isComplete, error in
            guard let self, let activeConnection, self.connection === activeConnection else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                do {
                    try self.drainPackets()
                } catch {
                    self.onStateChange?(
                        .reconnecting,
                        "Rejected invalid DepthAI frame data: \(error.localizedDescription)",
                        self.activeRunGeneration
                    )
                    self.cancelConnection()
                    self.scheduleReconnect(detail: "The DepthAI helper sent an invalid frame.")
                    return
                }
            }

            if let error {
                self.cancelConnection()
                self.scheduleReconnect(detail: "Depth camera IPC read failed: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.cancelConnection()
                self.scheduleReconnect(detail: "Depth camera helper disconnected.")
                return
            }
            self.receiveNext(on: activeConnection)
        }
    }

    private func drainPackets() throws {
        while receiveBuffer.count >= 8 {
            guard receiveBuffer.prefix(4) == Self.protocolMagic else {
                throw DepthCameraIPCError.invalidMagic
            }
            let headerLength = try integer32BigEndian(in: receiveBuffer, offset: 4)
            guard headerLength > 0, headerLength <= Self.maximumHeaderBytes else {
                throw DepthCameraIPCError.invalidLength
            }
            guard receiveBuffer.count >= 8 + headerLength else { return }

            let headerData = receiveBuffer.subdata(in: 8..<(8 + headerLength))
            let header = try JSONDecoder().decode(DepthCameraPacketHeader.self, from: headerData)
            let expectedRGBLength = Self.expectedPayloadLength(
                width: header.rgbWidth,
                height: header.rgbHeight,
                bytesPerPixel: 3
            )
            let expectedDepthLength = Self.expectedPayloadLength(
                width: header.depthWidth,
                height: header.depthHeight,
                bytesPerPixel: 2
            )
            let expectedStereoLength = Self.expectedPayloadLength(
                width: header.stereoWidth,
                height: header.stereoHeight,
                bytesPerPixel: 1
            )
            guard header.protocolVersion == Self.protocolVersion,
                  header.rgbFormat == "RGB888",
                  header.depthFormat == "DEPTH16LE",
                  header.depthUnit == "millimeter",
                  header.stereoFormat == "GRAY8",
                  header.rgbWidth == header.depthWidth,
                  header.rgbHeight == header.depthHeight,
                  let expectedRGBLength,
                  let expectedDepthLength,
                  let expectedStereoLength,
                  header.rgbLength == expectedRGBLength,
                  header.depthLength == expectedDepthLength,
                  header.rgbLength <= Self.maximumPayloadBytes,
                  header.leftLength == expectedStereoLength,
                  header.rightLength == expectedStereoLength,
                  header.rgbLength + header.depthLength + header.leftLength + header.rightLength <= Self.maximumPayloadBytes else {
                throw DepthCameraIPCError.invalidHeader
            }

            let packetLength = 8 + headerLength + header.rgbLength + header.depthLength
                + header.leftLength + header.rightLength
            guard receiveBuffer.count >= packetLength else { return }

            let rgbStart = 8 + headerLength
            let depthStart = rgbStart + header.rgbLength
            let leftStart = depthStart + header.depthLength
            let rightStart = leftStart + header.leftLength
            let rgbData = receiveBuffer.subdata(in: rgbStart..<depthStart)
            let depthData = receiveBuffer.subdata(in: depthStart..<leftStart)
            let leftData = receiveBuffer.subdata(in: leftStart..<rightStart)
            let rightData = receiveBuffer.subdata(in: rightStart..<packetLength)
            receiveBuffer.removeSubrange(0..<packetLength)

            guard let sampleBuffer = Self.makeRGBSampleBuffer(
                rgbData: rgbData,
                width: header.rgbWidth,
                height: header.rgbHeight,
                timestampNanoseconds: header.timestampNanoseconds
            ) else {
                throw DepthCameraIPCError.cannotCreateSampleBuffer
            }

            if !reportedStreaming {
                reportedStreaming = true
                onStateChange?(.streamingRGBD, nil, activeRunGeneration)
            }
            onFrame?(CameraFrameSet(
                source: .depthAIService,
                sequence: header.sequence,
                timestampNanoseconds: header.timestampNanoseconds,
                rgbSampleBuffer: sampleBuffer,
                alignedDepth: CameraDepthFrame(
                    width: header.depthWidth,
                    height: header.depthHeight,
                    millimetersLittleEndian: depthData
                ),
                intrinsics: header.rgbIntrinsics.flatMap { values in
                    guard values.count == 9 else { return nil }
                    let result = CameraIntrinsics(
                        fx: values[0], fy: values[4], cx: values[2], cy: values[5]
                    )
                    return result.isValid(forWidth: header.rgbWidth, height: header.rgbHeight)
                        ? result : nil
                },
                rectifiedLeft: CameraStereoFrame(width: header.stereoWidth, height: header.stereoHeight, pixels: leftData),
                rectifiedRight: CameraStereoFrame(width: header.stereoWidth, height: header.stereoHeight, pixels: rightData)
            ), activeRunGeneration)
        }
    }

    private func integer32BigEndian(in data: Data, offset: Int) throws -> Int {
        guard data.count >= offset + 4 else { throw DepthCameraIPCError.invalidLength }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
        }
    }

    private static func expectedPayloadLength(
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) -> Int? {
        // Bound both allocation size and the amount of per-pixel conversion
        // work before performing any arithmetic with untrusted IPC metadata.
        guard width > 0, width <= 8_192, height > 0, height <= 8_192 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (length, lengthOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !lengthOverflow, length <= maximumPayloadBytes else { return nil }
        return length
    }

    private static func makeRGBSampleBuffer(
        rgbData: Data,
        width: Int,
        height: Int,
        timestampNanoseconds: UInt64
    ) -> CMSampleBuffer? {
        var optionalPixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optionalPixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer = optionalPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destinationBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let converted = rgbData.withUnsafeBytes { sourceRaw -> Bool in
            guard let sourceBase = sourceRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let destination = destinationBase.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let sourceRow = sourceBase.advanced(by: row * width * 3)
                let destinationRow = destination.advanced(by: row * destinationBytesPerRow)
                for column in 0..<width {
                    let sourcePixel = sourceRow.advanced(by: column * 3)
                    let destinationPixel = destinationRow.advanced(by: column * 4)
                    destinationPixel[0] = sourcePixel[2]
                    destinationPixel[1] = sourcePixel[1]
                    destinationPixel[2] = sourcePixel[0]
                    destinationPixel[3] = 255
                }
            }
            return true
        }
        guard converted else { return nil }

        var optionalFormatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &optionalFormatDescription
        ) == noErr, let formatDescription = optionalFormatDescription else {
            return nil
        }

        // AVSampleBufferDisplayLayer runs on the host clock. The OAK timestamp
        // belongs to the device clock and is retained in CameraFrameSet for
        // RGB/depth correlation, but using it as a presentation timestamp can
        // leave the display layer waiting forever after its first image.
        let hostPresentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: hostPresentationTime,
            decodeTimeStamp: .invalid
        )
        var optionalSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &optionalSampleBuffer
        ) == noErr else {
            return nil
        }
        if let sampleBuffer = optionalSampleBuffer {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        return optionalSampleBuffer
    }

    private func cancelConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        reportedStreaming = false
        receiveBuffer.removeAll(keepingCapacity: true)
    }

    private func scheduleReconnect(detail: String) {
        guard shouldRun else { return }
        onStateChange?(.reconnecting, detail, activeRunGeneration)
        reconnectWorkItem?.cancel()
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)) * 0.5, 10.0)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connectIfPossible()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

private struct DepthCameraPacketHeader: Decodable {
    let protocolVersion: Int
    let sequence: UInt64
    let timestampNanoseconds: UInt64
    let rgbWidth: Int
    let rgbHeight: Int
    let rgbFormat: String
    let rgbLength: Int
    let depthWidth: Int
    let depthHeight: Int
    let depthFormat: String
    let depthUnit: String
    let depthLength: Int
    let stereoWidth: Int
    let stereoHeight: Int
    let stereoFormat: String
    let leftLength: Int
    let rightLength: Int
    let rgbIntrinsics: [Double]?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sequence
        case timestampNanoseconds = "timestamp_ns"
        case rgbWidth = "rgb_width"
        case rgbHeight = "rgb_height"
        case rgbFormat = "rgb_format"
        case rgbLength = "rgb_length"
        case depthWidth = "depth_width"
        case depthHeight = "depth_height"
        case depthFormat = "depth_format"
        case depthUnit = "depth_unit"
        case depthLength = "depth_length"
        case stereoWidth = "stereo_width"
        case stereoHeight = "stereo_height"
        case stereoFormat = "stereo_format"
        case leftLength = "left_length"
        case rightLength = "right_length"
        case rgbIntrinsics = "rgb_intrinsics"
    }
}

private enum DepthCameraIPCError: LocalizedError {
    case invalidMagic
    case invalidLength
    case invalidHeader
    case cannotCreateSampleBuffer

    var errorDescription: String? {
        switch self {
        case .invalidMagic: return "Invalid camera protocol magic."
        case .invalidLength: return "Invalid camera packet length."
        case .invalidHeader: return "Unsupported or inconsistent camera packet header."
        case .cannotCreateSampleBuffer: return "Could not create an RGB sample buffer."
        }
    }
}
