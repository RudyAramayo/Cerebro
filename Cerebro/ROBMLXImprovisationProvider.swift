//
//  ROBMLXImprovisationProvider.swift
//  Cerebro
//

import Foundation

public final class ROBMLXImprovisationProvider: ROBLocalImprovisationProviding {
    public let providerName = ROBLocalImprovisationProviderKind.mlxSwift.displayName
    public let maximumRequestSeconds: TimeInterval

    private let configuration: ROBLocalImprovisationConfiguration
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requestCount: UInt64 = 0
    private var successCount: UInt64 = 0
    private var fallbackCount: UInt64 = 0
    private var lastLatency: TimeInterval?
    private var state = "idle"
    private var lastErrorCategory: String?

    public init(configuration: ROBLocalImprovisationConfiguration) {
        self.configuration = configuration
        maximumRequestSeconds = configuration.timeout
    }

    deinit {
        lock.lock()
        let active = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        active.forEach { $0.cancel() }
    }

    public func generatePlan(
        for request: ROBLocalImprovisationRequest,
        requestID: String,
        timeout: TimeInterval,
        completion: @escaping (Result<ROBLocalImprovisationPlan, Error>) -> Void
    ) {
        lock.lock()
        guard tasks[requestID] == nil else {
            lock.unlock()
            DispatchQueue.main.async {
                completion(.failure(ROBLocalImprovisationError.invalidConfiguration("Duplicate MLX request identifier.")))
            }
            return
        }
        requestCount += 1
        state = "generating"
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { [weak self] in
            guard let self else { return }
            let result: Result<ROBLocalImprovisationPlan, Error>
            do {
                let text = try await ROBMLXEngine.shared.generate(
                    prompt: Self.prompt(for: request),
                    modelID: configuration.model,
                    maxTokens: 256,
                    temperature: Float(configuration.temperature)
                )
                try Task.checkCancellation()
                guard let data = text.data(using: .utf8) else {
                    throw ROBLocalImprovisationError.invalidServerResponse
                }
                result = .success(try ROBLocalImprovisationPlanCodec.decode(data))
            } catch is CancellationError {
                result = .failure(ROBLocalImprovisationError.cancelled)
            } catch {
                result = .failure(error)
            }
            finish(requestID: requestID, start: start, result: result, completion: completion)
        }
        tasks[requestID] = task
        lock.unlock()
    }

    public func cancel(requestID: String) {
        lock.lock()
        let task = tasks.removeValue(forKey: requestID)
        lock.unlock()
        task?.cancel()
    }

    public func checkHealth(timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                _ = try await ROBMLXEngine.shared.generate(
                    prompt: "Return exactly this JSON and nothing else: {\"schema\":\"com.orbitusrobotics.local-improvisation-plan\",\"version\":1,\"beat\":\"scene_transition\",\"delivery\":\"warm\",\"offline_line\":\"Local intelligence is ready.\"}",
                    modelID: configuration.model,
                    maxTokens: 96,
                    temperature: 0
                )
                DispatchQueue.main.async { completion(.success("MLX is loaded and running privately on this Mac.")) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    public func noteFallback() {
        lock.lock(); fallbackCount += 1; lock.unlock()
    }

    public func diagnosticsSnapshot() -> ROBLocalImprovisationDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return ROBLocalImprovisationDiagnosticsSnapshot(
            providerName: providerName,
            state: state,
            redactedEndpoint: nil,
            model: configuration.model,
            requestCount: requestCount,
            successCount: successCount,
            fallbackCount: fallbackCount,
            lastLatency: lastLatency,
            lastErrorCategory: lastErrorCategory
        )
    }

    private func finish(
        requestID: String,
        start: TimeInterval,
        result: Result<ROBLocalImprovisationPlan, Error>,
        completion: @escaping (Result<ROBLocalImprovisationPlan, Error>) -> Void
    ) {
        lock.lock()
        guard tasks.removeValue(forKey: requestID) != nil else { lock.unlock(); return }
        lastLatency = ProcessInfo.processInfo.systemUptime - start
        switch result {
        case .success:
            successCount += 1; state = "ready"; lastErrorCategory = nil
        case .failure(let error):
            state = "error"
            lastErrorCategory = (error as? ROBLocalImprovisationError)?.category ?? "mlx"
        }
        lock.unlock()
        DispatchQueue.main.async { completion(result) }
    }

    private static func prompt(for request: ROBLocalImprovisationRequest) -> String {
        """
        You are ROB's private offline stage director. Return exactly one JSON object with no Markdown or prose.
        Required schema: {"schema":"com.orbitusrobotics.local-improvisation-plan","version":1,"beat":"audience_observation|robot_joke|dramatic_reveal|call_and_response|scene_transition","delivery":"warm|playful|dramatic|deadpan|curious","offline_line":"one concise spoken line"}
        Dialogue only. Do not mention tools, commands, URLs, motors, navigation, gestures, servos, joints, or physical actions.
        Show: \(request.showTitle)
        Cue: \(request.cueID)
        Scene goal: \(request.sceneGoal)
        Authored fallback: \(request.authoredFallback)
        """
    }
}
