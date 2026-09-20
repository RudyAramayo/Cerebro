import Foundation
import Darwin

/// Preview-only process boundary. Intentionally has no reference to an arm
/// controller, motor gateway, actuator authority or vendor coordinate mapper.
final class ROBShadowPlannerBridge {
    typealias Sender = (Data, UUID, UUID) -> Bool
    private let send: Sender
    private let resources: URL?
    private let python: URL
    private let startVision: (() -> URL?)?
    private let stopVision: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var active: ROBShadowRequest?
    private var pending: ROBShadowRequest?
    private var publishActive = true
    private var owner: (controller: UUID, session: UUID)?
    private var lastSequence: UInt64 = 0
    private var generation = UUID()
    private var timeout: DispatchWorkItem?

    init(resources: URL? = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil),
         python: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3"),
         startVision: (() -> URL?)? = nil, stopVision: (() -> Void)? = nil,
         send: @escaping Sender) {
        self.resources = resources; self.python = python; self.send = send
        self.startVision = startVision; self.stopVision = stopVision
    }

    func consume(_ data: Data, controllerID: UUID, sessionID: UUID) {
        precondition(Thread.isMainThread)
        guard let request = try? ROBShadowProtocol.request(data),
              request.controllerID == controllerID, request.sessionID == sessionID,
              ROBShadowProtocol.fresh(request) else { return }
        if let owner, owner.controller != controllerID || owner.session != sessionID {
            reply(request, status: "unavailable", detail: "Another controller session owns this shadow preview")
            return
        }
        guard request.sequence > lastSequence else { return }
        if owner == nil {
            guard request.command.action == .start else {
                reply(request, status: "unavailable", detail: "Start a new shadow preview first"); return
            }
            owner = (controllerID, sessionID)
        }
        lastSequence = request.sequence
        if active != nil {
            // At most one in-flight solve and one replacement. Never replay a
            // backlog of controller poses. Release/end supersede old previews.
            if [.release, .end, .start].contains(request.command.action) {
                pending = request; publishActive = false
            } else if request.command.action == .pose && (pending == nil || pending?.command.action == .pose) {
                pending = request
            } else {
                reply(request, status: "paused", detail: "Planner is busy; release the grip and retry")
            }
            return
        }
        submit(request)
    }

    func sessionEnded(controllerID: UUID, sessionID: UUID) {
        guard owner?.controller == controllerID, owner?.session == sessionID else { return }
        stop()
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation = UUID(); timeout?.cancel(); timeout = nil
        active = nil; pending = nil; owner = nil; lastSequence = 0
        buffer.removeAll(keepingCapacity: false)
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil
        if let process, process.isRunning { process.terminate() }
        process?.terminationHandler = nil; process = nil
        stopVision?()
    }

    private func submit(_ request: ROBShadowRequest) {
        do {
            try startWorkerIfNeeded()
            active = request; publishActive = true
            var line = try ROBShadowProtocol.encode(request); line.append(10)
            try input?.write(contentsOf: line)
            let token = generation
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.fail("Drake did not answer before the preview deadline; start again")
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + (request.command.action == .start ? 8 : 2), execute: deadline)
        } catch {
            reply(request, status: "unavailable", detail: "Shadow planner unavailable: \(error.localizedDescription)")
            stop()
        }
    }

    private func startWorkerIfNeeded() throws {
        if process?.isRunning == true { return }
        guard let resources, FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("worker.py").path) else {
            throw NSError(domain: "ROBShadow", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Install the isolated Drake runtime with Scripts/setup-shadow-planner.sh, then use the updated Cerebro app."])
        }
        let worker = Process(), incoming = Pipe(), outgoing = Pipe(), diagnostics = Pipe()
        worker.executableURL = python
        worker.arguments = ["-u", "-B", resources.appendingPathComponent("worker.py").path]
        worker.currentDirectoryURL = resources
        worker.standardInput = incoming; worker.standardOutput = outgoing; worker.standardError = diagnostics
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        if let path = startVision?() { environment["ROB_SHADOW_OBSERVATION_PATH"] = path.path }
        worker.environment = environment
        let token = generation
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let data = Self.readAvailable(handle, limit: ROBShadowProtocol.maximumBytes + 1) else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.receive(data)
            }
        }
        diagnostics.fileHandleForReading.readabilityHandler = { handle in
            _ = Self.readAvailable(handle, limit: 4096) // bounded diagnostic drain
        }
        worker.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.fail("Drake worker exited; install/check the isolated runtime and start again")
            }
        }
        input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
        errors = diagnostics.fileHandleForReading; process = worker
        try worker.run()
    }

    private static func readAvailable(_ handle: FileHandle, limit: Int) -> Data? {
        // FileHandle.read(upToCount:) can wait to fill the requested count on a
        // live pipe. One POSIX read returns the available chunk without waiting
        // for another request or worker EOF, and bounds allocation.
        var bytes = [UInt8](repeating: 0, count: limit)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { return nil }
        return Data(bytes.prefix(count))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { fail("Drake worker closed its output"); return }
        buffer.append(data)
        guard buffer.count <= ROBShadowProtocol.maximumBytes + 1 else { fail("Oversized Drake response"); return }
        guard let end = buffer.firstIndex(of: 10) else { return }
        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
        guard let request = active,
              let response = try? ROBShadowProtocol.response(line),
              response.controllerID == request.controllerID, response.sessionID == request.sessionID,
              response.shadowID == request.command.shadowID, response.requestID == request.command.requestID,
              response.arm == request.command.arm,
              response.sequence == request.sequence,
              request.command.modelID == nil || request.command.modelID == response.modelID else {
            fail("Invalid or mismatched Drake response"); return
        }
        timeout?.cancel(); timeout = nil; active = nil
        if publishActive { _ = send(line, request.controllerID, request.sessionID) }
        if request.command.action == .end { stop(); return }
        if let next = pending { pending = nil; submit(next) }
    }

    private func fail(_ detail: String) {
        if let request = pending ?? active { reply(request, status: "unavailable", detail: detail) }
        stop()
    }
    private func reply(_ request: ROBShadowRequest, status: String, detail: String) {
        if let data = try? ROBShadowProtocol.encode(ROBShadowResponse(request: request, status: status, detail: detail)) {
            _ = send(data, request.controllerID, request.sessionID)
        }
    }
}
