//
//  ROBTraversabilityRuntime.swift
//  Cerebro
//
//  An online, self-supervised terrain model. During operator-driven motion it
//  remembers compact RGB-D features in front of ROB and labels them positive
//  only after RPLidar odometry confirms ROB actually crossed that ground.
//  Images are never persisted and autonomous motion never trains the model.
//

import AVFoundation
import Foundation

struct ROBTraversabilityDirection: Sendable {
    let headingOffset: Double
    let depthClearanceMeters: Double
    let geometryConfidence: Double
    let learnedScore: Double
    let learnedConfidence: Double
}

struct ROBTraversabilitySnapshot: Sendable {
    let directions: [ROBTraversabilityDirection]
    let receivedAtUptime: TimeInterval
    let trainingSampleCount: Int
    let modelGeneration: UInt64
}

final class ROBTraversabilityRuntime {
    static let shared = ROBTraversabilityRuntime()
    static let minimumTrainingSamples = 12

    private struct LocalPose {
        let x: Double
        let y: Double
        let yaw: Double
        let uptime: TimeInterval
    }

    private struct DirectionFeatures {
        let headingOffset: Double
        let vector: [Double]
        let depthClearanceMeters: Double
        let geometryConfidence: Double
    }

    private struct PendingExample {
        let features: [Double]
        let pose: LocalPose
        let createdAtUptime: TimeInterval
    }

    private struct OnlineModel: Codable {
        var count = 0
        var generation: UInt64 = 0
        var mean: [Double] = []
        var m2: [Double] = []

        mutating func add(_ values: [Double]) {
            guard !values.isEmpty else { return }
            if mean.isEmpty {
                mean = Array(repeating: 0, count: values.count)
                m2 = Array(repeating: 0, count: values.count)
            }
            guard values.count == mean.count else { return }
            count += 1
            generation &+= 1
            for index in values.indices {
                let delta = values[index] - mean[index]
                mean[index] += delta / Double(count)
                m2[index] += delta * (values[index] - mean[index])
            }
        }

        func similarity(to values: [Double]) -> Double {
            guard count >= ROBTraversabilityRuntime.minimumTrainingSamples,
                  values.count == mean.count else { return 0 }
            let distance = values.indices.reduce(0.0) { partial, index in
                let variance = count > 1 ? m2[index] / Double(count - 1) : 0
                let scale = max(variance, 0.0025)
                let delta = values[index] - mean[index]
                return partial + min(9, delta * delta / scale)
            } / Double(values.count)
            return exp(-0.5 * distance)
        }
    }

    private let queue = DispatchQueue(label: "com.orbitusrobotics.traversability", qos: .userInitiated)
    private let offerLock = NSLock()
    private var lastOfferUptime: TimeInterval = 0
    private var latestPose: LocalPose?
    private var latestSnapshot: ROBTraversabilitySnapshot?
    private var pendingExamples: [PendingExample] = []
    private var model = OnlineModel()
    private var autonomousMotionActive = false
    private var lastQueuedExampleUptime: TimeInterval = 0

    private init() {
        if let data = try? Data(contentsOf: Self.modelURL),
           let persisted = try? JSONDecoder().decode(OnlineModel.self, from: data),
           persisted.count >= 0, persisted.mean.count == persisted.m2.count {
            model = persisted
        }
    }

    func setAutonomousMotionActive(_ active: Bool) {
        queue.async { [weak self] in
            self?.autonomousMotionActive = active
            if active { self?.pendingExamples.removeAll() }
        }
    }

    func updateLocalPose(x: Double, y: Double, yaw: Double, receivedAtUptime: TimeInterval) {
        let pose = LocalPose(x: x, y: y, yaw: yaw, uptime: receivedAtUptime)
        queue.async { [weak self] in
            guard let self else { return }
            self.latestPose = pose
            self.promoteTraversedExamples(at: pose)
        }
    }

    func offer(frameSet: CameraFrameSet) {
        let now = ProcessInfo.processInfo.systemUptime
        offerLock.lock()
        guard now - lastOfferUptime >= 0.45 else {
            offerLock.unlock()
            return
        }
        lastOfferUptime = now
        offerLock.unlock()

        guard let depth = frameSet.alignedDepth,
              let imageBuffer = CMSampleBufferGetImageBuffer(frameSet.rgbSampleBuffer) else { return }
        let extracted = Self.extractFeatures(imageBuffer: imageBuffer, depth: depth)
        guard !extracted.isEmpty else { return }
        queue.async { [weak self] in
            self?.consume(extracted, at: now)
        }
    }

    func snapshot() -> ROBTraversabilitySnapshot? {
        queue.sync { latestSnapshot }
    }

    private func consume(_ features: [DirectionFeatures], at uptime: TimeInterval) {
        let modelConfidence = min(1, Double(model.count) / 40)
        let directions = features.map {
            ROBTraversabilityDirection(
                headingOffset: $0.headingOffset,
                depthClearanceMeters: $0.depthClearanceMeters,
                geometryConfidence: $0.geometryConfidence,
                learnedScore: model.similarity(to: $0.vector),
                learnedConfidence: modelConfidence
            )
        }
        latestSnapshot = ROBTraversabilitySnapshot(
            directions: directions,
            receivedAtUptime: uptime,
            trainingSampleCount: model.count,
            modelGeneration: model.generation
        )

        guard !autonomousMotionActive,
              uptime - lastQueuedExampleUptime >= 0.8,
              let pose = latestPose,
              uptime - pose.uptime <= 1,
              let center = features.min(by: { abs($0.headingOffset) < abs($1.headingOffset) }),
              center.geometryConfidence >= 0.5,
              center.depthClearanceMeters >= 0.45 else { return }
        lastQueuedExampleUptime = uptime
        pendingExamples.append(PendingExample(
            features: center.vector,
            pose: pose,
            createdAtUptime: uptime
        ))
        if pendingExamples.count > 40 { pendingExamples.removeFirst(pendingExamples.count - 40) }
    }

    private func promoteTraversedExamples(at pose: LocalPose) {
        guard !autonomousMotionActive else {
            pendingExamples.removeAll()
            return
        }
        var retained: [PendingExample] = []
        var learned = false
        for example in pendingExamples {
            let age = pose.uptime - example.createdAtUptime
            guard age <= 20 else { continue }
            let dx = pose.x - example.pose.x
            let dy = pose.y - example.pose.y
            let forward = dx * cos(example.pose.yaw) + dy * sin(example.pose.yaw)
            let lateral = abs(-dx * sin(example.pose.yaw) + dy * cos(example.pose.yaw))
            if forward >= 0.35, forward <= 2.0, lateral <= 0.45 {
                model.add(example.features)
                learned = true
            } else {
                retained.append(example)
            }
        }
        pendingExamples = retained
        if learned { persistModel() }
    }

    private func persistModel() {
        do {
            let directory = Self.modelURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(model)
            try data.write(to: Self.modelURL, options: .atomic)
        } catch {
            NSLog("[Traversability] Unable to persist compact model: %@", error.localizedDescription)
        }
    }

    private static var modelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Cerebro", isDirectory: true)
            .appendingPathComponent("Navigation", isDirectory: true)
            .appendingPathComponent("traversability-model-v1.json")
    }

    private static func extractFeatures(
        imageBuffer: CVPixelBuffer,
        depth: CameraDepthFrame
    ) -> [DirectionFeatures] {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard width > 0, height > 0, depth.width == width, depth.height == height else { return [] }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(imageBuffer)
        let isBGRA = format == kCVPixelFormatType_32BGRA
        let isLuma = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isBGRA || isLuma else { return [] }
        let base: UnsafeMutableRawPointer?
        let bytesPerRow: Int
        if isLuma {
            base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
        } else {
            base = CVPixelBufferGetBaseAddress(imageBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        }
        guard let base else { return [] }

        let headings: [Double] = [-0.62, -0.31, 0, 0.31, 0.62]
        return headings.enumerated().compactMap { sector, heading -> DirectionFeatures? in
            let sectorWidth = Double(width) / Double(headings.count)
            let xStart = Int(Double(sector) * sectorWidth)
            let xEnd = min(width - 1, Int(Double(sector + 1) * sectorWidth) - 1)
            let yStart = Int(Double(height) * 0.42)
            let yEnd = min(height - 1, Int(Double(height) * 0.88))
            var lumas: [Double] = []
            var saturations: [Double] = []
            var depths: [Double] = []
            for rowIndex in 0 ..< 8 {
                let y = yStart + (yEnd - yStart) * rowIndex / 7
                for columnIndex in 0 ..< 8 {
                    let x = xStart + max(0, xEnd - xStart) * columnIndex / 7
                    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    if isBGRA {
                        let offset = x * 4
                        let blue = Double(row[offset]) / 255
                        let green = Double(row[offset + 1]) / 255
                        let red = Double(row[offset + 2]) / 255
                        lumas.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
                        let maximum = max(red, green, blue)
                        let minimum = min(red, green, blue)
                        saturations.append(maximum > 0 ? (maximum - minimum) / maximum : 0)
                    } else {
                        lumas.append(Double(row[x]) / 255)
                        saturations.append(0)
                    }
                    if let millimeters = depth.distanceMillimeters(x: x, y: y),
                       (120 ... 8_000).contains(millimeters) {
                        depths.append(Double(millimeters) / 1_000)
                    }
                }
            }
            guard lumas.count == 64 else { return nil }
            let sortedDepths = depths.sorted()
            let depthConfidence = Double(depths.count) / 64
            let clearance = sortedDepths.isEmpty
                ? 0
                : sortedDepths[min(sortedDepths.count - 1, sortedDepths.count / 5)]
            let medianDepth = sortedDepths.isEmpty ? 0 : sortedDepths[sortedDepths.count / 2]
            let meanLuma = lumas.reduce(0, +) / Double(lumas.count)
            let texture = sqrt(lumas.reduce(0) { $0 + pow($1 - meanLuma, 2) } / Double(lumas.count))
            let meanSaturation = saturations.reduce(0, +) / Double(saturations.count)
            let depthSpread = sortedDepths.isEmpty
                ? 0
                : sortedDepths.map { abs($0 - medianDepth) }.sorted()[sortedDepths.count / 2]
            return DirectionFeatures(
                headingOffset: heading,
                vector: [
                    meanLuma,
                    min(1, texture * 4),
                    meanSaturation,
                    min(1, medianDepth / 5),
                    min(1, depthSpread / 2)
                ],
                depthClearanceMeters: clearance,
                geometryConfidence: depthConfidence
            )
        }
    }
}
