import Foundation

/// Foundation-only stand-in for stage coordination fixtures. Envelope and HTTP
/// behavior have their own dedicated provider fixtures.
public final class ROBLlamaCppImprovisationProvider: ROBLocalImprovisationProviding {
    public let providerName = "Fixture llama.cpp provider"
    public let maximumRequestSeconds: TimeInterval

    public init(configuration: ROBLocalImprovisationConfiguration) {
        maximumRequestSeconds = configuration.timeout
    }

    public func generatePlan(
        for request: ROBLocalImprovisationRequest,
        requestID: String,
        timeout: TimeInterval,
        completion: @escaping (Result<ROBLocalImprovisationPlan, Error>) -> Void
    ) {
        completion(.failure(ROBLocalImprovisationError.serverUnavailable(
            "The Foundation-only fixture stub does not contact llama.cpp."
        )))
    }

    public func cancel(requestID: String) {}

    public func checkHealth(
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        completion(.failure(ROBLocalImprovisationError.serverUnavailable(
            "The Foundation-only fixture stub does not contact llama.cpp."
        )))
    }

    public func noteFallback() {}

    public func diagnosticsSnapshot() -> ROBLocalImprovisationDiagnosticsSnapshot {
        ROBLocalImprovisationDiagnosticsSnapshot(
            providerName: providerName,
            state: "fixture-only",
            redactedEndpoint: nil,
            model: nil,
            requestCount: 0,
            successCount: 0,
            fallbackCount: 0,
            lastLatency: nil,
            lastErrorCategory: nil
        )
    }
}

/// Foundation-only stand-in used when compiling stage-show fixtures outside
/// the Xcode target. The app build links the real MLX provider; these fixtures
/// never load a model or contact a service.
public final class ROBMLXImprovisationProvider: ROBLocalImprovisationProviding {
    public let providerName = "Fixture MLX provider"
    public let maximumRequestSeconds: TimeInterval

    public init(configuration: ROBLocalImprovisationConfiguration) {
        maximumRequestSeconds = configuration.timeout
    }

    public func generatePlan(
        for request: ROBLocalImprovisationRequest,
        requestID: String,
        timeout: TimeInterval,
        completion: @escaping (Result<ROBLocalImprovisationPlan, Error>) -> Void
    ) {
        completion(.failure(ROBLocalImprovisationError.serverUnavailable(
            "The Foundation-only fixture stub does not run MLX."
        )))
    }

    public func cancel(requestID: String) {}

    public func checkHealth(
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        completion(.failure(ROBLocalImprovisationError.serverUnavailable(
            "The Foundation-only fixture stub does not run MLX."
        )))
    }

    public func noteFallback() {}

    public func diagnosticsSnapshot() -> ROBLocalImprovisationDiagnosticsSnapshot {
        ROBLocalImprovisationDiagnosticsSnapshot(
            providerName: providerName,
            state: "fixture-only",
            redactedEndpoint: nil,
            model: nil,
            requestCount: 0,
            successCount: 0,
            fallbackCount: 0,
            lastLatency: nil,
            lastErrorCategory: nil
        )
    }
}
