import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ROBWorkspaceObjectBoxes: Decodable, Sendable {
    struct Candidate: Decodable, Sendable {
        let target: String
        let query: String
        let score: Double
        let box: [Double]
    }
    let id: String?
    let provider: String
    let model: String
    let device: String
    let width: Int
    let height: Int
    let inference_ms: Double
    let candidates: [Candidate]

    func validated() throws -> Self {
        guard provider == "owlv2", model == "google/owlv2-base-patch16-ensemble",
              ["cpu", "mps"].contains(device), (1...4096).contains(width), (1...4096).contains(height),
              inference_ms.isFinite, (0...120_000).contains(inference_ms), candidates.count <= 32,
              candidates.allSatisfy({ candidate in
                  ["can", "orangeBucket", "other"].contains(candidate.target) && candidate.query.utf8.count <= 200 &&
                  candidate.score.isFinite && (0...1).contains(candidate.score) && candidate.box.count == 4 &&
                  candidate.box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) &&
                  candidate.box[2] > candidate.box[0] && candidate.box[3] > candidate.box[1]
              }) else { throw ROBWorkspaceDetectorError.failure("Local detector returned invalid object boxes.") }
        return self
    }
}

enum ROBWorkspaceDetectorError: LocalizedError {
    case failure(String)
    var errorDescription: String? { if case .failure(let text) = self { return text }; return nil }
}

/// Serialized persistent local worker. Loading completes BEFORE the caller
/// captures its image. A cancelled/failed request never supplies old boxes.
final class ROBWorkspaceObjectDetector: @unchecked Sendable {
    static let shared = ROBWorkspaceObjectDetector()
    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.workspace-object-detector", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var operation: UUID?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private let directory: URL
    private let script: URL?

    init(directory: URL? = nil, script: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/WorkspaceDetector")
        self.script = script ?? Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil)?
            .appendingPathComponent("workspace_detector.py")
    }

    func warmUp() async throws {
        try await perform { try self.ensureReady() }
    }

    func detect(jpeg: Data) async throws -> ROBWorkspaceObjectBoxes {
        guard jpeg.count <= 2_500_000 else { throw ROBWorkspaceDetectorError.failure("Detector image is too large.") }
        return try await perform {
            try self.ensureReady()
            let id = UUID().uuidString
            var request = try JSONSerialization.data(withJSONObject: ["id": id, "jpeg": jpeg.base64EncodedString()])
            request.append(0x0a)
            try self.input?.write(contentsOf: request)
            let line = try self.readLine()
            if let error = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["error"] as? String {
                throw ROBWorkspaceDetectorError.failure("Local detector: " + String(error.prefix(300)))
            }
            let result = try JSONDecoder().decode(ROBWorkspaceObjectBoxes.self, from: line).validated()
            guard result.id == id else { throw ROBWorkspaceDetectorError.failure("Local detector response did not match its camera frame.") }
            return result
        }
    }

    private func perform<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let token = UUID()
        let result: Value = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.lock.lock(); self.operation = token; self.lock.unlock()
                    let timeout = DispatchWorkItem { self.stop(operation: token) }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 45, execute: timeout)
                    defer {
                        self.lock.lock(); if self.operation == token { self.operation = nil }; self.lock.unlock()
                        timeout.cancel()
                    }
                    do { continuation.resume(returning: try work()) }
                    catch {
                        self.stop(operation: token)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { self.stop(operation: token) })
        try Task.checkCancellation()
        return result
    }

    private func stop(operation token: UUID?) {
        lock.lock()
        let matches = token == nil || operation == token
        let child = matches ? process : nil
        if matches { process = nil }
        lock.unlock()
        if child?.isRunning == true { child?.terminate() }
    }

    private func ensureReady() throws {
        lock.lock(); let existing = process; lock.unlock()
        if existing?.isRunning == true { return }
        let python = directory.appendingPathComponent("venv/bin/python3")
        let model = directory.appendingPathComponent("model")
        guard let script, FileManager.default.fileExists(atPath: script.path),
              FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: model.appendingPathComponent("model.safetensors").path) else {
            throw ROBWorkspaceDetectorError.failure("Install the offline object detector with Scripts/setup-workspace-detector.py before searching.")
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = python
        child.arguments = ["-u", script.path, "--model-directory", model.path]
        var environment = ProcessInfo.processInfo.environment
        environment.merge(["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"]) { _, new in new }
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout
        let log = directory.appendingPathComponent("worker.log")
        try Data().write(to: log, options: .atomic)
        child.standardError = try FileHandle(forWritingTo: log)
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; buffer = Data()
        #if canImport(Darwin)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        lock.lock(); process = child; lock.unlock()
        try child.run()
        let ready = try JSONSerialization.jsonObject(with: readLine()) as? [String: Any]
        guard ready?["ready"] as? Bool == true, ready?["provider"] as? String == "owlv2" else {
            throw ROBWorkspaceDetectorError.failure("Local detector did not become ready. Inspect WorkspaceDetector/worker.log.")
        }
    }

    private func readLine() throws -> Data {
        while true {
            lock.lock(); let running = process != nil; lock.unlock()
            guard running else { throw ROBWorkspaceDetectorError.failure("Local detector was cancelled or timed out.") }
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[...newline]); buffer.removeSubrange(...newline); return line
            }
            guard buffer.count < 65_536, let output else {
                throw ROBWorkspaceDetectorError.failure("Local detector output exceeded its bound.")
            }
            #if canImport(Darwin)
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || ready < 0 && errno == EINTR { continue }
            var storage = [UInt8](repeating: 0, count: 4096)
            let count = storage.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            let bytes = count > 0 ? Data(storage.prefix(count)) : Data()
            #else
            let bytes = output.availableData
            #endif
            guard !bytes.isEmpty else {
                throw ROBWorkspaceDetectorError.failure("Local detector stopped or timed out; no object position was accepted.")
            }
            buffer.append(bytes)
        }
    }
}
