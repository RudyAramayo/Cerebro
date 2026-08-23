//
//  ROBRecordingCoordinator.swift
//  Cerebro
//
//  Explicit, crash-recoverable training-session and camera-footage recording.
//  Training data and ordinary footage intentionally have separate lifecycles.
//

import AppKit
import AVFoundation
import CoreImage
import Foundation

extension Notification.Name {
    static let robRecordingDemandDidChange = Notification.Name("ROBRecordingDemandDidChange")
    static let robRecordingStateDidChange = Notification.Name("ROBRecordingStateDidChange")
}

struct ROBTrainingRecordingConfiguration {
    let faceCameraEnabled: Bool
    let bellyCameraEnabled: Bool
    let keyframesPerSecond: Double
}

struct ROBFootageRecordingConfiguration {
    let faceResolution: String?
    let bellyResolution: String?
    let insta360Resolution: String?
}

struct ROBRecordingStatusSnapshot {
    let trainingActive: Bool
    let footageActive: Bool
    let trainingDirectory: URL?
    let footageDirectory: URL?
    let trainingFrameCount: UInt64
    let lidarScanCount: UInt64
    let footageFrameCount: UInt64
    let lastError: String?
}

private enum ROBRecordingError: LocalizedError {
    case alreadyRecording(String)
    case noCamerasSelected
    case invalidKeyframeRate
    case insufficientDiskSpace(Int64)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording(let kind): return "A \(kind) recording is already active."
        case .noCamerasSelected: return "Select at least one camera before recording."
        case .invalidKeyframeRate: return "Training keyframe rate must be between 0.25 and 10 frames per second."
        case .insufficientDiskSpace(let bytes):
            return "Recording requires at least 2 GB free. Only \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) is available."
        }
    }
}

private struct ROBManualMotionEpisode {
    let controllerID: String
    var startedAtUptime: TimeInterval
    var lastCommandAtUptime: TimeInterval
    var startPose: (x: Double, y: Double)?
    var commandDirection: String
}

private final class ROBJSONLinesWriter {
    private let handle: FileHandle

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        handle.write(data)
    }

    func finish() {
        try? handle.synchronize()
        try? handle.close()
    }
}

private final class ROBTrainingSession {
    let rootURL: URL
    let configuration: ROBTrainingRecordingConfiguration
    private let startedAt = Date()
    private let startedAtUptime = ProcessInfo.processInfo.systemUptime
    private let events: ROBJSONLinesWriter
    private var cameraEvents: [CameraRole: ROBJSONLinesWriter] = [:]
    private var lastKeyframeUptime: [CameraRole: TimeInterval] = [:]
    private var calibrationIDs: [CameraRole: String] = [:]
    private var latestKeyframeIDs: [CameraRole: String] = [:]
    private(set) var frameCount: UInt64 = 0
    private(set) var lidarScanCount: UInt64 = 0
    private var eventSequence: UInt64 = 0
    private var lastPose: (x: Double, y: Double, yaw: Double)?
    private var manualMotionEpisode: ROBManualMotionEpisode?

    init(rootURL: URL, configuration: ROBTrainingRecordingConfiguration) throws {
        self.rootURL = rootURL
        self.configuration = configuration
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: rootURL.appendingPathComponent("lidar"), withIntermediateDirectories: true)
        events = try ROBJSONLinesWriter(url: rootURL.appendingPathComponent("events.jsonl"))
        for role in [CameraRole.face, .belly] where enabled(role) {
            let cameraRoot = rootURL.appendingPathComponent("cameras/\(role.rawValue)")
            for component in ["rgb", "depth", "stereo_left", "stereo_right", "calibrations"] {
                try fm.createDirectory(
                    at: cameraRoot.appendingPathComponent(component),
                    withIntermediateDirectories: true
                )
            }
            cameraEvents[role] = try ROBJSONLinesWriter(url: cameraRoot.appendingPathComponent("frames.jsonl"))
        }
        writeManifest(state: "recording", endedAt: nil)
        appendEvent(type: "session_started", uptime: startedAtUptime, body: [
            "label_policy": "Manual active-master commands may receive sensor-derived labels; autonomous commands never self-train."
        ])
    }

    func enabled(_ role: CameraRole) -> Bool {
        role == .face ? configuration.faceCameraEnabled : configuration.bellyCameraEnabled
    }

    func recordCameraFrame(role: CameraRole, frameSet: CameraFrameSet, ciContext: CIContext) {
        guard enabled(role), let frameWriter = cameraEvents[role] else { return }
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let interval = 1.0 / configuration.keyframesPerSecond
        if let previous = lastKeyframeUptime[role], nowUptime - previous < interval { return }
        lastKeyframeUptime[role] = nowUptime

        guard let imageBuffer = CMSampleBufferGetImageBuffer(frameSet.rgbSampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let keyframeID = String(format: "%@-%012llu", role.rawValue, frameSet.sequence)
        let rgbRelativePath = "cameras/\(role.rawValue)/rgb/\(keyframeID).jpg"
        let rgbURL = rootURL.appendingPathComponent(rgbRelativePath)
        let image = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent),
              let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.94]
              ) else { return }
        do {
            try jpeg.write(to: rgbURL, options: .atomic)
        } catch {
            appendEvent(type: "write_error", uptime: nowUptime, body: ["detail": error.localizedDescription])
            return
        }

        var metadata: [String: Any] = [
            "keyframe_id": keyframeID,
            "source": frameSet.source.rawValue,
            "source_sequence": frameSet.sequence,
            "source_timestamp_nanoseconds": frameSet.timestampNanoseconds,
            "received_at": Self.iso8601(Date()),
            "received_at_uptime": nowUptime,
            "rgb_file": rgbRelativePath,
            "rgb_encoding": "jpeg",
            "rgb_width": width,
            "rgb_height": height
        ]

        if let depth = frameSet.alignedDepth {
            let relativePath = "cameras/\(role.rawValue)/depth/\(keyframeID).depth16"
            do {
                try depth.millimetersLittleEndian.write(
                    to: rootURL.appendingPathComponent(relativePath),
                    options: .atomic
                )
                metadata["aligned_depth_file"] = relativePath
                metadata["aligned_depth_width"] = depth.width
                metadata["aligned_depth_height"] = depth.height
                metadata["aligned_depth_encoding"] = "uint16-little-endian-millimeters-zero-invalid"
            } catch {
                metadata["aligned_depth_error"] = error.localizedDescription
            }
        }
        if let left = frameSet.rectifiedLeft {
            metadata.merge(writeStereo(left, side: "left", role: role, keyframeID: keyframeID)) { _, new in new }
        }
        if let right = frameSet.rectifiedRight {
            metadata.merge(writeStereo(right, side: "right", role: role, keyframeID: keyframeID)) { _, new in new }
        }
        if let intrinsics = frameSet.intrinsics {
            let calibrationID = calibrationIDFor(
                role: role,
                width: width,
                height: height,
                intrinsics: intrinsics
            )
            metadata["calibration_id"] = calibrationID
            metadata["intrinsics"] = [
                "fx": intrinsics.fx, "fy": intrinsics.fy,
                "cx": intrinsics.cx, "cy": intrinsics.cy
            ]
        }
        frameWriter.append(metadata)
        latestKeyframeIDs[role] = keyframeID
        frameCount &+= 1
    }

    private func writeStereo(
        _ frame: CameraStereoFrame,
        side: String,
        role: CameraRole,
        keyframeID: String
    ) -> [String: Any] {
        let relativePath = "cameras/\(role.rawValue)/stereo_\(side)/\(keyframeID).gray8"
        do {
            try frame.pixels.write(to: rootURL.appendingPathComponent(relativePath), options: .atomic)
            return [
                "rectified_\(side)_file": relativePath,
                "rectified_\(side)_width": frame.width,
                "rectified_\(side)_height": frame.height,
                "rectified_\(side)_encoding": "uint8-gray"
            ]
        } catch {
            return ["rectified_\(side)_error": error.localizedDescription]
        }
    }

    private func calibrationIDFor(
        role: CameraRole,
        width: Int,
        height: Int,
        intrinsics: CameraIntrinsics
    ) -> String {
        let identity = String(
            format: "%@-%dx%d-%.3f-%.3f-%.3f-%.3f",
            role.rawValue, width, height, intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy
        )
        if calibrationIDs[role] == identity { return identity }
        calibrationIDs[role] = identity
        var calibration: [String: Any] = [
            "calibration_id": identity,
            "camera_role": role.rawValue,
            "image_width": width,
            "image_height": height,
            "intrinsics": [
                "model": "pinhole",
                "fx": intrinsics.fx, "fy": intrinsics.fy,
                "cx": intrinsics.cx, "cy": intrinsics.cy
            ],
            "depth_alignment": "depth-pixels-aligned-to-rgb"
        ]
        let poseKey = role == .face ? "ROBCameraPoseFace" : "ROBCameraPoseBelly"
        if let data = UserDefaults.standard.data(forKey: poseKey),
           let pose = try? JSONSerialization.jsonObject(with: data) {
            calibration["camera_to_robot_extrinsics"] = pose
        } else {
            calibration["camera_to_robot_extrinsics"] = NSNull()
        }
        if JSONSerialization.isValidJSONObject(calibration),
           let data = try? JSONSerialization.data(withJSONObject: calibration, options: [.prettyPrinted, .sortedKeys]) {
            let safeID = identity.replacingOccurrences(of: ".", with: "_")
            let url = rootURL.appendingPathComponent("cameras/\(role.rawValue)/calibrations/\(safeID).json")
            try? data.write(to: url, options: .atomic)
        }
        return identity
    }

    func recordTreadCommand(
        controllerID: String,
        model: ROBBaseControllerModel,
        activeMaster: Bool,
        uptime: TimeInterval
    ) {
        let leftValid = model.touchPadPointL.x > -999 && model.touchPadPointL.y > -999
        let rightValid = model.touchPadPointR.x > -999 && model.touchPadPointR.y > -999
        let leftMagnitude = leftValid ? hypot(model.touchPadPointL.x, model.touchPadPointL.y) : 0
        let rightMagnitude = rightValid ? hypot(model.touchPadPointR.x, model.touchPadPointR.y) : 0
        let moving = !model.tredBrakeLock && (
            leftMagnitude > 0.04 || rightMagnitude > 0.04 || (model.speed_playPause && model.speed > 0)
        )
        let autonomous = controllerID.caseInsensitiveCompare("Autonomous") == .orderedSame
        appendEvent(type: "tread_command", uptime: uptime, body: [
            "controller_id": controllerID,
            "active_master": activeMaster,
            "autonomous": autonomous,
            "tread_brake_lock": model.tredBrakeLock,
            "left": ["valid": leftValid, "x": model.touchPadPointL.x, "y": model.touchPadPointL.y],
            "right": ["valid": rightValid, "x": model.touchPadPointR.x, "y": model.touchPadPointR.y],
            "speed_percent": model.speed,
            "cruise_active": model.speed_playPause,
            "cruise_forward": model.speed_forward_reverse
        ])

        guard activeMaster, !autonomous, moving else {
            // A master handoff to autonomy terminates any manual episode
            // immediately, so subsequent autonomous odometry cannot complete
            // an earlier manual positive-label window.
            if activeMaster { manualMotionEpisode = nil }
            return
        }
        let direction: String
        let meanY = ((leftValid ? model.touchPadPointL.y : 0) + (rightValid ? model.touchPadPointR.y : 0)) / 2
        if model.speed_playPause {
            direction = model.speed_forward_reverse ? "forward" : "reverse"
        } else if meanY > 0.03 {
            direction = "forward"
        } else if meanY < -0.03 {
            direction = "reverse"
        } else {
            direction = "turn"
        }
        if var episode = manualMotionEpisode,
           episode.controllerID == controllerID,
           uptime - episode.lastCommandAtUptime < 0.65,
           episode.commandDirection == direction {
            episode.lastCommandAtUptime = uptime
            manualMotionEpisode = episode
        } else {
            manualMotionEpisode = ROBManualMotionEpisode(
                controllerID: controllerID,
                startedAtUptime: uptime,
                lastCommandAtUptime: uptime,
                startPose: lastPose.map { ($0.x, $0.y) },
                commandDirection: direction
            )
        }
    }

    func recordLidar(data: Data, x: Double, y: Double, yaw: Double, uptime: TimeInterval, pointCount: Int) {
        lidarScanCount &+= 1
        let scanID = String(format: "scan-%012llu", lidarScanCount)
        let relativePath = "lidar/\(scanID).rscan"
        try? data.write(
            to: rootURL.appendingPathComponent(relativePath),
            options: .atomic
        )
        var odometry: [String: Any] = ["x_meters": x, "y_meters": y, "yaw_radians": yaw]
        if let previous = lastPose {
            odometry["delta_x_meters"] = x - previous.x
            odometry["delta_y_meters"] = y - previous.y
            odometry["delta_distance_meters"] = hypot(x - previous.x, y - previous.y)
            odometry["delta_yaw_radians"] = Self.normalizedAngle(yaw - previous.yaw)
        }
        lastPose = (x, y, yaw)
        appendEvent(type: "lidar_pose_odometry", uptime: uptime, body: [
            "scan_id": scanID,
            "scan_file": relativePath,
            "scan_encoding": "rob-lidar-scan-binary-v1",
            "point_count": pointCount,
            "pose_and_odometry": odometry
        ])
        updateAutomaticLabel(x: x, y: y, uptime: uptime)
    }

    private func updateAutomaticLabel(x: Double, y: Double, uptime: TimeInterval) {
        guard var episode = manualMotionEpisode,
              uptime - episode.lastCommandAtUptime <= 0.9 else { return }
        if episode.startPose == nil {
            episode.startPose = (x, y)
            manualMotionEpisode = episode
            return
        }
        guard let start = episode.startPose else { return }
        let distance = hypot(x - start.x, y - start.y)
        let duration = uptime - episode.startedAtUptime
        if distance >= 0.35 {
            appendLabel(
                "successfully_traversed",
                provenance: "sensor_derived_manual_traversal",
                note: String(format: "%.2f m measured displacement during %@ command", distance, episode.commandDirection),
                uptime: uptime
            )
            episode.startedAtUptime = uptime
            episode.startPose = (x, y)
            manualMotionEpisode = episode
        } else if duration >= 1.75 && distance < 0.08 {
            appendLabel(
                "stall_or_slip",
                provenance: "sensor_derived_manual_traversal",
                note: String(format: "Only %.2f m displacement after %.2f s of demand", distance, duration),
                uptime: uptime
            )
            episode.startedAtUptime = uptime
            episode.startPose = (x, y)
            manualMotionEpisode = episode
        }
    }

    func appendOperatorLabel(_ label: String, note: String?) {
        appendLabel(
            label,
            provenance: "operator",
            note: note ?? "Operator marked from recording control panel",
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func appendLabel(_ label: String, provenance: String, note: String, uptime: TimeInterval) {
        var body: [String: Any] = [
            "label": label,
            "provenance": provenance,
            "note": note
        ]
        if let face = latestKeyframeIDs[.face] { body["face_keyframe_id"] = face }
        if let belly = latestKeyframeIDs[.belly] { body["belly_keyframe_id"] = belly }
        if let pose = lastPose {
            body["local_pose"] = ["x_meters": pose.x, "y_meters": pose.y, "yaw_radians": pose.yaw]
        }
        appendEvent(type: "traversability_label", uptime: uptime, body: body)
    }

    private func appendEvent(type: String, uptime: TimeInterval, body: [String: Any]) {
        eventSequence &+= 1
        var event = body
        event["event_id"] = eventSequence
        event["type"] = type
        event["captured_at"] = Self.iso8601(Date())
        event["captured_at_uptime"] = uptime
        events.append(event)
    }

    func finish(reason: String) {
        appendEvent(
            type: "session_ended",
            uptime: ProcessInfo.processInfo.systemUptime,
            body: ["reason": reason]
        )
        cameraEvents.values.forEach { $0.finish() }
        events.finish()
        writeManifest(state: "complete", endedAt: Date())
    }

    private func writeManifest(state: String, endedAt: Date?) {
        var manifest: [String: Any] = [
            "schema": "com.orbitusrobotics.cerebro.training-session",
            "schema_version": 1,
            "session_id": rootURL.lastPathComponent,
            "state": state,
            "started_at": Self.iso8601(startedAt),
            "started_at_uptime": startedAtUptime,
            "camera_roles": [
                "face": configuration.faceCameraEnabled,
                "belly": configuration.bellyCameraEnabled
            ],
            "keyframes_per_second": configuration.keyframesPerSecond,
            "rgb_encoding": "jpeg-quality-0.94",
            "depth_encoding": "uint16-little-endian-millimeters-zero-invalid",
            "event_log": "events.jsonl",
            "training_policy": [
                "autonomous_motion_trains_model": false,
                "automatic_positive_labels_require_manual_active_master_command_and_measured_odometry": true,
                "operator_labels_supported": ["acceptable", "operator_rejected", "blocked", "stall_or_slip"]
            ],
            "frame_count": frameCount,
            "lidar_scan_count": lidarScanCount,
            "software": Self.softwareMetadata()
        ]
        if let endedAt { manifest["ended_at"] = Self.iso8601(endedAt) }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: rootURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func softwareMetadata() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "bundle_identifier": Bundle.main.bundleIdentifier ?? "unknown",
            "version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown",
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString
        ]
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter.robRecording.string(from: date)
    }

    private static func normalizedAngle(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }
}

private final class ROBVideoFileWriter {
    let cameraName: String
    let requestedResolution: String
    let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context: CIContext
    private let targetWidth: Int
    private let targetHeight: Int
    private var firstUptime: TimeInterval?
    private var lastPresentationTime = CMTime.invalid
    private(set) var appendedFrames: UInt64 = 0
    private(set) var droppedFrames: UInt64 = 0
    private(set) var sourceDimensions: Set<String> = []

    init(
        cameraName: String,
        requestedResolution: String,
        sourceWidth: Int,
        sourceHeight: Int,
        outputURL: URL,
        context: CIContext
    ) throws {
        self.cameraName = cameraName
        self.requestedResolution = requestedResolution
        self.outputURL = outputURL
        self.context = context
        let parsed = Self.parseResolution(requestedResolution)
        targetWidth = Self.even(parsed?.width ?? sourceWidth)
        targetHeight = Self.even(parsed?.height ?? sourceHeight)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: targetWidth,
                AVVideoHeightKey: targetHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.bitRate(width: targetWidth, height: targetHeight),
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
        )
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "ROBRecording", code: 10, userInfo: [NSLocalizedDescriptionKey: "Cannot add \(cameraName) video input."])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ROBRecording", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot start \(cameraName) writer."])
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ source: CIImage, sourceWidth: Int, sourceHeight: Int, uptime: TimeInterval) {
        sourceDimensions.insert("\(sourceWidth)x\(sourceHeight)")
        guard input.isReadyForMoreMediaData else {
            droppedFrames &+= 1
            return
        }
        guard let pool = adaptor.pixelBufferPool else {
            droppedFrames &+= 1
            return
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let output else {
            droppedFrames &+= 1
            return
        }
        let sourceExtent = source.extent
        let scale = min(CGFloat(targetWidth) / sourceExtent.width, CGFloat(targetHeight) / sourceExtent.height)
        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let transform = CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(
                x: (CGFloat(targetWidth) - scaledWidth) / (2 * scale),
                y: (CGFloat(targetHeight) - scaledHeight) / (2 * scale)
            )
        let destination = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        context.render(CIImage(color: .black).cropped(to: destination), to: output)
        context.render(source.transformed(by: transform), to: output, bounds: destination, colorSpace: CGColorSpaceCreateDeviceRGB())

        if firstUptime == nil { firstUptime = uptime }
        var presentation = CMTime(seconds: max(0, uptime - (firstUptime ?? uptime)), preferredTimescale: 600)
        if lastPresentationTime.isValid && CMTimeCompare(presentation, lastPresentationTime) <= 0 {
            presentation = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
        }
        guard adaptor.append(output, withPresentationTime: presentation) else {
            droppedFrames &+= 1
            return
        }
        lastPresentationTime = presentation
        appendedFrames &+= 1
    }

    func finish() -> [String: Any] {
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 20)
        var result: [String: Any] = [
            "camera": cameraName,
            "file": outputURL.lastPathComponent,
            "requested_resolution": requestedResolution,
            "encoded_resolution": "\(targetWidth)x\(targetHeight)",
            "observed_source_resolutions": sourceDimensions.sorted(),
            "appended_frames": appendedFrames,
            "dropped_frames": droppedFrames,
            "writer_status": writer.status.rawValue
        ]
        if let error = writer.error { result["error"] = error.localizedDescription }
        return result
    }

    private static func parseResolution(_ value: String) -> (width: Int, height: Int)? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func even(_ value: Int) -> Int { max(2, value - value % 2) }
    private static func bitRate(width: Int, height: Int) -> Int {
        max(4_000_000, min(60_000_000, width * height * 5))
    }
}

private final class ROBFootageSession {
    let rootURL: URL
    let configuration: ROBFootageRecordingConfiguration
    private let startedAt = Date()
    private let context: CIContext
    private var writers: [String: ROBVideoFileWriter] = [:]
    private(set) var frameCount: UInt64 = 0

    init(rootURL: URL, configuration: ROBFootageRecordingConfiguration, context: CIContext) throws {
        self.rootURL = rootURL
        self.configuration = configuration
        self.context = context
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        writeManifest(state: "recording", recordings: [])
    }

    func requestedResolution(camera: String) -> String? {
        switch camera {
        case "face": return configuration.faceResolution
        case "belly": return configuration.bellyResolution
        case "insta360": return configuration.insta360Resolution
        default: return nil
        }
    }

    func appendCamera(role: CameraRole, frameSet: CameraFrameSet, uptime: TimeInterval) {
        let name = role.rawValue
        guard let requested = requestedResolution(camera: name),
              let buffer = CMSampleBufferGetImageBuffer(frameSet.rgbSampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        append(name: name, requested: requested, image: CIImage(cvPixelBuffer: buffer), width: width, height: height, uptime: uptime)
    }

    func appendInsta360(jpeg: Data, uptime: TimeInterval) {
        guard let requested = configuration.insta360Resolution,
              let image = CIImage(data: jpeg) else { return }
        append(
            name: "insta360",
            requested: requested,
            image: image,
            width: Int(image.extent.width),
            height: Int(image.extent.height),
            uptime: uptime
        )
    }

    private func append(name: String, requested: String, image: CIImage, width: Int, height: Int, uptime: TimeInterval) {
        do {
            let writer: ROBVideoFileWriter
            if let existing = writers[name] {
                writer = existing
            } else {
                writer = try ROBVideoFileWriter(
                    cameraName: name,
                    requestedResolution: requested,
                    sourceWidth: width,
                    sourceHeight: height,
                    outputURL: rootURL.appendingPathComponent("\(name).mov"),
                    context: context
                )
                writers[name] = writer
            }
            writer.append(image, sourceWidth: width, sourceHeight: height, uptime: uptime)
            frameCount &+= 1
        } catch {
            // The coordinator publishes the directory and final writer state;
            // a failed camera writer does not corrupt recordings from peers.
        }
    }

    func finish() {
        let recordings = writers.keys.sorted().compactMap { writers[$0]?.finish() }
        writeManifest(state: "complete", recordings: recordings)
    }

    private func writeManifest(state: String, recordings: [[String: Any]]) {
        var manifest: [String: Any] = [
            "schema": "com.orbitusrobotics.cerebro.camera-footage-session",
            "schema_version": 1,
            "session_id": rootURL.lastPathComponent,
            "state": state,
            "started_at": ISO8601DateFormatter.robRecording.string(from: startedAt),
            "requested": [
                "face": configuration.faceResolution.map { $0 as Any } ?? NSNull(),
                "belly": configuration.bellyResolution.map { $0 as Any } ?? NSNull(),
                "insta360": configuration.insta360Resolution.map { $0 as Any } ?? NSNull()
            ],
            "notes": [
                "Encoded and observed source resolutions are recorded separately.",
                "Changing a hardware capture resolution may briefly restart that camera stream."
            ],
            "recordings": recordings
        ]
        if state == "complete" { manifest["ended_at"] = ISO8601DateFormatter.robRecording.string(from: Date()) }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: rootURL.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

@objcMembers public final class ROBRecordingCoordinator: NSObject, ROBInsta360VideoFrameConsumer {
    public static let shared = ROBRecordingCoordinator()
    private static let minimumFreeBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.recording", qos: .utility)
    private let admissionLock = NSLock()
    private var cameraOfferInFlight: [CameraRole: Bool] = [:]
    private var insta360OfferInFlight = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var trainingSession: ROBTrainingSession?
    private var footageSession: ROBFootageSession?
    private var lastTrainingDirectory: URL?
    private var lastFootageDirectory: URL?
    private var lastError: String?

    private override init() {
        super.init()
        ROBInsta360CameraService.shared.setRecordingFrameConsumer(self)
    }

    func startTraining(_ configuration: ROBTrainingRecordingConfiguration) throws {
        guard configuration.faceCameraEnabled || configuration.bellyCameraEnabled else { throw ROBRecordingError.noCamerasSelected }
        guard (0.25 ... 10).contains(configuration.keyframesPerSecond) else { throw ROBRecordingError.invalidKeyframeRate }
        try queue.sync {
            guard trainingSession == nil else { throw ROBRecordingError.alreadyRecording("training") }
            let root = try makeSessionDirectory(kind: "Training")
            let session = try ROBTrainingSession(rootURL: root, configuration: configuration)
            trainingSession = session
            lastTrainingDirectory = root
            lastError = nil
        }
        demandDidChange()
    }

    public func stopTraining() {
        queue.async {
            guard let session = self.trainingSession else { return }
            session.finish(reason: "operator_stop")
            self.trainingSession = nil
            self.publishStateChange()
            self.publishDemandChange()
        }
    }

    func startFootage(_ configuration: ROBFootageRecordingConfiguration) throws {
        guard configuration.faceResolution != nil || configuration.bellyResolution != nil || configuration.insta360Resolution != nil else {
            throw ROBRecordingError.noCamerasSelected
        }
        try queue.sync {
            guard footageSession == nil else { throw ROBRecordingError.alreadyRecording("footage") }
            let root = try makeSessionDirectory(kind: "Footage")
            footageSession = try ROBFootageSession(rootURL: root, configuration: configuration, context: context)
            lastFootageDirectory = root
            lastError = nil
        }
        demandDidChange()
    }

    public func stopFootage() {
        queue.async {
            guard let session = self.footageSession else { return }
            session.finish()
            self.footageSession = nil
            self.publishStateChange()
            self.publishDemandChange()
        }
    }

    func cameraCaptureDemand(for role: CameraRole) -> (active: Bool, resolutionOverride: String?) {
        queue.sync {
            let trainingActive = trainingSession?.enabled(role) == true
            let footageResolution = footageSession?.requestedResolution(camera: role.rawValue)
            let override = Self.isSourceResolution(footageResolution) ? nil : footageResolution
            return (trainingActive || footageResolution != nil, override)
        }
    }

    public func insta360CaptureDemand() -> (active: Bool, resolutionOverride: String?) {
        queue.sync {
            let resolution = footageSession?.configuration.insta360Resolution
            return (resolution != nil, Self.isSourceResolution(resolution) ? nil : resolution)
        }
    }

    func offerCameraFrame(role: CameraRole, frameSet: CameraFrameSet) {
        admissionLock.lock()
        guard cameraOfferInFlight[role] != true else {
            admissionLock.unlock()
            return
        }
        cameraOfferInFlight[role] = true
        admissionLock.unlock()
        queue.async {
            let sourceUptime = TimeInterval(frameSet.timestampNanoseconds) / 1_000_000_000
            let uptime = sourceUptime.isFinite && sourceUptime > 0
                ? sourceUptime
                : ProcessInfo.processInfo.systemUptime
            self.trainingSession?.recordCameraFrame(role: role, frameSet: frameSet, ciContext: self.context)
            self.footageSession?.appendCamera(role: role, frameSet: frameSet, uptime: uptime)
            self.admissionLock.lock()
            self.cameraOfferInFlight[role] = false
            self.admissionLock.unlock()
        }
    }

    public func consumeInsta360JPEGFrame(_ jpegData: Data, capturedAt: Date, capturedAtUptime: TimeInterval) {
        admissionLock.lock()
        guard !insta360OfferInFlight else {
            admissionLock.unlock()
            return
        }
        insta360OfferInFlight = true
        admissionLock.unlock()
        queue.async {
            self.footageSession?.appendInsta360(jpeg: jpegData, uptime: capturedAtUptime)
            self.admissionLock.lock()
            self.insta360OfferInFlight = false
            self.admissionLock.unlock()
        }
    }

    @objc(recordTreadCommandWithControllerID:model:activeMaster:)
    public func recordTreadCommand(controllerID: String, model: ROBBaseControllerModel, activeMaster: Bool) {
        let uptime = model.receivedAtUptime > 0 ? model.receivedAtUptime : ProcessInfo.processInfo.systemUptime
        queue.async {
            self.trainingSession?.recordTreadCommand(
                controllerID: controllerID,
                model: model,
                activeMaster: activeMaster,
                uptime: uptime
            )
        }
    }

    public func recordLidarScanData(_ data: Data, x: Double, y: Double, yaw: Double, receivedAtUptime: TimeInterval, pointCount: Int) {
        queue.async {
            self.trainingSession?.recordLidar(
                data: data,
                x: x,
                y: y,
                yaw: yaw,
                uptime: receivedAtUptime,
                pointCount: pointCount
            )
        }
    }

    func addOperatorLabel(_ label: String) {
        queue.async {
            self.trainingSession?.appendOperatorLabel(label, note: nil)
            self.publishStateChange()
        }
    }

    func statusSnapshot() -> ROBRecordingStatusSnapshot {
        queue.sync {
            ROBRecordingStatusSnapshot(
                trainingActive: trainingSession != nil,
                footageActive: footageSession != nil,
                trainingDirectory: lastTrainingDirectory,
                footageDirectory: lastFootageDirectory,
                trainingFrameCount: trainingSession?.frameCount ?? 0,
                lidarScanCount: trainingSession?.lidarScanCount ?? 0,
                footageFrameCount: footageSession?.frameCount ?? 0,
                lastError: lastError
            )
        }
    }

    public func stopAllForApplicationTermination() {
        queue.sync {
            trainingSession?.finish(reason: "application_termination")
            footageSession?.finish()
            trainingSession = nil
            footageSession = nil
        }
    }

    private func makeSessionDirectory(kind: String) throws -> URL {
        let base: URL
        if kind == "Training" {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Cerebro/Recordings/Training", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ROB Recordings", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: base.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= Self.minimumFreeBytes else { throw ROBRecordingError.insufficientDiskSpace(free) }
        let stamp = Self.directoryFormatter.string(from: Date())
        let suffix = UUID().uuidString.lowercased().prefix(8)
        return base.appendingPathComponent("\(stamp)_\(suffix)", isDirectory: true)
    }

    private func demandDidChange() {
        publishStateChange()
        publishDemandChange()
    }

    private func publishDemandChange() {
        DispatchQueue.main.async {
            let insta = self.insta360CaptureDemand()
            ROBInsta360CameraService.shared.setRecordingVideoDemandActive(
                insta.active,
                resolution: insta.resolutionOverride
            )
            NotificationCenter.default.post(name: .robRecordingDemandDidChange, object: self)
        }
    }

    private func publishStateChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .robRecordingStateDidChange, object: self)
        }
    }

    private static func isSourceResolution(_ resolution: String?) -> Bool {
        guard let resolution else { return false }
        return resolution.caseInsensitiveCompare("Source") == .orderedSame
    }

    private static let directoryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

private extension ISO8601DateFormatter {
    static let robRecording: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
