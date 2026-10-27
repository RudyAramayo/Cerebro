import Foundation
import Darwin

/// Receives synchronized camera frames while its owner requests estimation.
/// One depth fit at a time, no camera ownership or actuator capability.
final class ROBMarkerlessVisionService {
    static let shared = ROBMarkerlessVisionService()
    private let queue = DispatchQueue(label: "rob.shadow.markerless", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var busy = false
    private var lastOffer: [String: TimeInterval] = [:]
    private var latestCaptureStreams: [String: String] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var requestToken = UUID()
    private var awaitingWorkerReady = false
    private let resources: URL?
    private let python: URL
    private let workerName: String
    var onObservation: (([String: Any]) -> Void)?
    var onFailure: (() -> Void)?
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rob-markerless-\(UUID())", isDirectory: true)
    private var observationURL: URL { directory.appendingPathComponent("observation.json") }

    init(resources: URL? = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil),
         workerName: String = "markerless.py",
         python: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3")) {
        self.resources = resources; self.python = python; self.workerName = workerName
    }

    func start() -> URL? {
        precondition(Thread.isMainThread)
        stop()
        guard let resources else { return nil }
        let worker = Process(), incoming = Pipe(), outgoing = Pipe(), diagnostics = Pipe()
        worker.executableURL = python
        worker.arguments = ["-u", "-B", resources.appendingPathComponent(workerName).path]
        worker.currentDirectoryURL = resources
        worker.standardInput = incoming; worker.standardOutput = outgoing; worker.standardError = diagnostics
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        environment["OPENBLAS_NUM_THREADS"] = "1"; environment["VECLIB_MAXIMUM_THREADS"] = "1"
        worker.environment = environment
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try worker.run()
        } catch { return nil }
        queue.sync {
            self.process = worker; self.input = incoming.fileHandleForWriting
            self.output = outgoing.fileHandleForReading; self.errors = diagnostics.fileHandleForReading
            let token = self.generation
            self.awaitingWorkerReady = true
            self.requestToken = UUID()
            let startupRequest = self.requestToken
            self.output?.readabilityHandler = { [weak self] handle in
                var bytes = [UInt8](repeating: 0, count: 32769)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                guard count >= 0 else { return }
                let data = Data(bytes.prefix(count))
                self?.queue.async { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.receive(data)
                }
            }
            self.errors?.readabilityHandler = { handle in
                var bytes = [UInt8](repeating: 0, count: 4096)
                _ = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            }
            // Loading the model takes longer than the bounded stdin write.
            // Drop startup frames; offer a fresh exposure only once Python
            // has opened its read loop. Never queue/freshen old camera pixels.
            self.lock.lock(); self.enabled = true; self.busy = true; self.lock.unlock()
            self.queue.asyncAfter(deadline:.now()+30) { [weak self] in
                guard let self,self.generation==token,self.awaitingWorkerReady,self.requestToken==startupRequest else{return}
                self.fail()
            }
        }
        return observationURL
    }

    func stop() {
        lock.lock(); enabled = false; busy = false; lastOffer = [:]; latestCaptureStreams = [:]; lock.unlock()
        queue.sync {
            generation = UUID(); buffer.removeAll(); requestToken = UUID()
            awaitingWorkerReady = false
            output?.readabilityHandler = nil; errors?.readabilityHandler = nil
            try? input?.close(); try? output?.close(); try? errors?.close()
            input = nil; output = nil; errors = nil
            if process?.isRunning == true { process?.terminate() }
            process = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func offer(_ frame: CameraFrameSet, role: CameraRole, streamID: String) {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let previousStream = latestCaptureStreams[role.rawValue]
        latestCaptureStreams[role.rawValue] = streamID
        if let previousStream, previousStream != streamID {
            // Invalidate only an observation from this replaced camera. The
            // torso consumer preserves a fresh accepted alternate camera.
            DispatchQueue.main.async { [weak self] in
                self?.onObservation?(["schemaVersion": 1, "source": "camera_context_invalidated",
                    "camera": role.rawValue, "streamID": previousStream, "status": "unavailable",
                    "detail": "Camera calibration or capture stream changed; previous coordinates expired."])
            }
            queue.async { [weak self] in
                guard let self else { return }
                if let data = try? Data(contentsOf: self.observationURL),
                   let prior = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   prior["camera"] as? String == role.rawValue,
                   prior["streamID"] as? String == previousStream {
                    try? FileManager.default.removeItem(at: self.observationURL)
                }
            }
        }
        guard enabled, !busy, uptime - (lastOffer[role.rawValue] ?? 0) >= 0.25,
              frame.source == .depthAIService, let depth = frame.alignedDepth,
              let capturedAt = frame.capturedAtMilliseconds, capturedAt.isFinite,
              (0 ... 400).contains(Date().timeIntervalSince1970 * 1000 - capturedAt),
              let intrinsics = frame.intrinsics,
              intrinsics.isValid(forWidth: depth.width, height: depth.height) else { lock.unlock(); return }
        busy = true; lastOffer[role.rawValue] = uptime
        lock.unlock()
        // Preserve the SDK-derived capture time through IPC and encoding.
        // Reception must never freshen pixels delayed in a camera/socket queue.
        queue.async { [weak self] in
            guard let self, self.process?.isRunning == true else { return }
            do {
                let step = max(1, Int(ceil(Double(max(depth.width, depth.height)) / 240)))
                let width = (depth.width + step - 1) / step, height = (depth.height + step - 1) / step
                var sampled = Data(capacity: width * height * 2)
                for y in stride(from: 0, to: depth.height, by: step) {
                    for x in stride(from: 0, to: depth.width, by: step) {
                        let value = depth.distanceMillimeters(x: x, y: y) ?? 0
                        sampled.append(UInt8(value & 255)); sampled.append(UInt8(value >> 8))
                    }
                }
                var packet: [String: Any] = ["camera": role.rawValue, "streamID": streamID,
                    "sequence": frame.sequence, "timestampNanoseconds": frame.timestampNanoseconds,
                    "capturedAtMilliseconds": capturedAt, "width": width, "height": height,
                    "intrinsics": [intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy].map { $0 / Double(step) },
                    "depth": sampled.base64EncodedString()]
                if let runtime = intrinsics.runtimeCalibration {
                    packet["runtimeCalibrationIdentity"] = runtime.identity
                    packet["runtimeCalibration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime))
                }
                var data = try JSONSerialization.data(withJSONObject: packet); data.append(10)
                guard let input = self.input else { throw CocoaError(.fileWriteUnknown) }
                try Self.writeBounded(data, to: input)
                self.requestToken = UUID(); let token = self.requestToken
                self.queue.asyncAfter(deadline: .now() + (self.workerName == "torso_markerless.py" ? 6 : 3)) { [weak self] in
                    guard let self, self.requestToken == token else { return }
                    // Stop accepting frames after a hung fit. Closing/reopening
                    // the preview restarts the isolated service.
                    self.fail()
                }
            } catch {
                self.fail()
            }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            fail()
            return
        }
        buffer.append(data)
        guard buffer.count <= 32769 else { fail(); return }
        guard let end = buffer.firstIndex(of: 10) else { return }
        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["schemaVersion"] as? Int == 1 else {fail();return}
        if awaitingWorkerReady {
            guard object["source"] as? String == "markerless_ready" else {fail();return}
            awaitingWorkerReady=false;requestToken=UUID()
            lock.lock();busy=false;lock.unlock()
            return // Process readiness is not a torso/arm observation.
        }
        guard object["source"] as? String == "markerless_rgbd",
              let captured = object["capturedAtMilliseconds"] as? Double, captured.isFinite else {
            fail(); return
        }
        guard captureStreamIsCurrent(object) else {
            requestToken = UUID()
            lock.lock(); busy = false; lock.unlock()
            return
        }
        // Atomic replacement prevents the planner from seeing a partial frame.
        try? line.write(to: observationURL, options: .atomic)
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.sync(execute: { token == self.generation }), self.captureStreamIsCurrent(object) else { return }
            self.onObservation?(object)
        }
        requestToken = UUID()
        lock.lock(); busy = false; lock.unlock()
    }

    private func captureStreamIsCurrent(_ object: [String: Any]) -> Bool {
        guard let camera = object["camera"] as? String, let stream = object["streamID"] as? String else { return false }
        lock.lock(); defer { lock.unlock() }
        return latestCaptureStreams[camera] == stream
    }

    private func fail() {
        awaitingWorkerReady = false
        requestToken = UUID()
        lock.lock(); enabled = false; busy = false; lock.unlock()
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil
        if process?.isRunning == true { process?.terminate() }
        try? FileManager.default.removeItem(at: observationURL)
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.sync(execute: { token == self.generation }) else { return }
            self.onFailure?()
        }
    }

    private static func writeBounded(_ data: Data, to handle: FileHandle) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                guard count < 0, errno == EAGAIN || errno == EINTR,
                      ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileWriteUnknown) }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 20)
            }
        }
    }
}
