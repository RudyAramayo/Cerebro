//
//  ROBMLXRuntime.swift
//  Cerebro
//
//  Private, on-device MLX inference. Vision work is explicitly sampled and
//  runs on its own actor; it never participates in the motor-control loop.
//

import AVFoundation
import CoreImage
import Foundation
import MLX
import MLXEmbedders
import MLXEmbeddersHFAPI
import MLXEmbeddersTokenizers
import MLXLLM
import MLXLMCommon
import MLXLMHFAPI
import MLXLMTokenizers
import MLXVLM

public struct ROBMLXDiagnosticsSnapshot: Sendable {
    public let state: String
    public let llmModel: String
    public let vlmModel: String
    public let embeddingModel: String
    public let loadLatency: TimeInterval?
    public let generationLatency: TimeInterval?
    public let tokensPerSecond: Double?
    public let activeMemoryBytes: Int
    public let peakMemoryBytes: Int
    public let cacheMemoryBytes: Int
    public let visionEnabled: Bool
    public let visionFrameCount: UInt64
    public let lastVisionLatency: TimeInterval?
    public let lastVisionObservation: String?
    public let semanticMemoryCount: Int
    public let downloadProgress: Double?
    public let downloadDetail: String?
    public let lastError: String?
}

public struct ROBMLXSemanticMatch: Sendable {
    public let text: String
    public let similarity: Float
}

public actor ROBMLXEngine {
    public static let shared = ROBMLXEngine()
    public static let defaultLLMModel = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    public static let defaultVLMModel = "mlx-community/Qwen2-VL-2B-Instruct-4bit"
    public static let defaultEmbeddingModel = "TaylorAI/gte-tiny"

    private var llm: ModelContainer?
    private var vlm: ModelContainer?
    private var embedder: EmbedderModelContainer?
    private var loadedLLMModel: String?
    private var state = "idle"
    private var loadLatency: TimeInterval?
    private var generationLatency: TimeInterval?
    private var tokensPerSecond: Double?
    private var visionEnabled = false
    private var lastVisionStart: TimeInterval = 0
    private var visionFrameCount: UInt64 = 0
    private var lastVisionLatency: TimeInterval?
    private var lastVisionObservation: String?
    private var lastError: String?
    private var downloadProgress: Double?
    private var downloadDetail: String?
    private var memories: [(text: String, vector: [Float])] = []

    public func setVisionEnabled(_ enabled: Bool) { visionEnabled = enabled }

    public func ensureLLMReady(modelID: String = defaultLLMModel) async throws {
        _ = try await loadLLM(modelID: modelID)
    }

    public func generate(
        prompt: String,
        modelID: String = defaultLLMModel,
        maxTokens: Int = 256,
        temperature: Float = 0.4
    ) async throws -> String {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let container = try await loadLLM(modelID: modelID)
            let input = try await container.prepare(input: UserInput(prompt: prompt))
            let stream = try await container.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature)
            )
            var result = ""
            for await event in stream {
                try Task.checkCancellation()
                switch event {
                case .chunk(let text): result += text
                case .info(let info): tokensPerSecond = info.tokensPerSecond
                case .toolCall:
                    throw ROBLocalImprovisationError.invalidPlan("MLX attempted a tool call.")
                }
            }
            generationLatency = ProcessInfo.processInfo.systemUptime - start
            state = "ready"
            lastError = nil
            return result
        } catch {
            generationLatency = ProcessInfo.processInfo.systemUptime - start
            state = "error"
            lastError = String(describing: error)
            throw error
        }
    }

    /// Accepts at most one selected frame per interval. The caller returns
    /// immediately; inference remains fully outside capture and control paths.
    public func offerVisionFrame(_ image: CIImage, minimumInterval: TimeInterval = 5) {
        guard visionEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVisionStart >= max(3, minimumInterval) else { return }
        lastVisionStart = now
        Task { await analyzeVisionFrame(image) }
    }

    public func remember(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000 else { return }
        let vector = try await embedding(for: "search_document: \(trimmed)")
        memories.append((trimmed, vector))
        if memories.count > 200 { memories.removeFirst(memories.count - 200) }
    }

    public func retrieve(_ query: String, limit: Int = 3) async throws -> [ROBMLXSemanticMatch] {
        guard !memories.isEmpty else { return [] }
        let vector = try await embedding(for: "search_query: \(query)")
        return memories.map { memory in
            ROBMLXSemanticMatch(text: memory.text, similarity: dot(vector, memory.vector))
        }.sorted { $0.similarity > $1.similarity }.prefix(max(1, min(limit, 10))).map { $0 }
    }

    public func diagnostics() -> ROBMLXDiagnosticsSnapshot {
        ROBMLXDiagnosticsSnapshot(
            state: state,
            llmModel: loadedLLMModel ?? Self.defaultLLMModel,
            vlmModel: Self.defaultVLMModel,
            embeddingModel: Self.defaultEmbeddingModel,
            loadLatency: loadLatency,
            generationLatency: generationLatency,
            tokensPerSecond: tokensPerSecond,
            activeMemoryBytes: Memory.activeMemory,
            peakMemoryBytes: Memory.peakMemory,
            cacheMemoryBytes: Memory.cacheMemory,
            visionEnabled: visionEnabled,
            visionFrameCount: visionFrameCount,
            lastVisionLatency: lastVisionLatency,
            lastVisionObservation: lastVisionObservation,
            semanticMemoryCount: memories.count,
            downloadProgress: downloadProgress,
            downloadDetail: downloadDetail,
            lastError: lastError
        )
    }

    private func loadLLM(modelID: String) async throws -> ModelContainer {
        if let llm, loadedLLMModel == modelID { return llm }
        state = "loading"
        downloadProgress = 0
        downloadDetail = "Preparing \(modelID)"
        let start = ProcessInfo.processInfo.systemUptime
        let container = try await LLMModelFactory.shared.loadContainer(
            using: TokenizersLoader(),
            configuration: ModelConfiguration(id: modelID),
            progressHandler: { progress in
                Task { await ROBMLXEngine.shared.updateDownloadProgress(
                    progress.fractionCompleted,
                    detail: progress.localizedDescription ?? "Downloading model files"
                ) }
            }
        )
        loadLatency = ProcessInfo.processInfo.systemUptime - start
        loadedLLMModel = modelID
        llm = container
        state = "ready"
        downloadProgress = 1
        downloadDetail = "Model loaded"
        return container
    }

    private func updateDownloadProgress(_ fraction: Double, detail: String) {
        downloadProgress = min(1, max(0, fraction))
        downloadDetail = detail
        state = "downloading"
    }

    private func analyzeVisionFrame(_ image: CIImage) async {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let container: ModelContainer
            if let vlm { container = vlm } else {
                container = try await VLMModelFactory.shared.loadContainer(
                    using: TokenizersLoader(),
                    configuration: ModelConfiguration(id: Self.defaultVLMModel)
                )
                vlm = container
            }
            let prompt = "Describe people, obstacles, graspable objects, and safety-relevant changes in one concise sentence. Do not propose or execute robot actions."
            let input = try await container.prepare(input: UserInput(prompt: prompt, images: [.ciImage(image)]))
            let stream = try await container.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 96, temperature: 0.1)
            )
            var observation = ""
            for await event in stream {
                if case .chunk(let chunk) = event { observation += chunk }
            }
            lastVisionObservation = observation.trimmingCharacters(in: .whitespacesAndNewlines)
            lastVisionLatency = ProcessInfo.processInfo.systemUptime - start
            visionFrameCount += 1
            if let observation = lastVisionObservation, !observation.isEmpty {
                try? await remember("Visual observation: \(observation)")
            }
        } catch {
            lastVisionLatency = ProcessInfo.processInfo.systemUptime - start
            lastError = "VLM: \(error)"
        }
    }

    private func embedding(for text: String) async throws -> [Float] {
        let container: EmbedderModelContainer
        if let embedder { container = embedder } else {
            container = try await EmbedderModelFactory.shared.loadContainer(
                using: TokenizersLoader(),
                configuration: ModelConfiguration(id: Self.defaultEmbeddingModel)
            )
            embedder = container
        }
        return await container.perform { context in
            let tokenizer = context.tokenizer
            let ids = tokenizer.encode(text: text, addSpecialTokens: true)
            let tokens = MLXArray(ids)[.newAxis]
            let mask = MLXArray.ones(like: tokens)
            let types = MLXArray.zeros(like: tokens)
            let output = context.model(tokens, positionIds: nil, tokenTypeIds: types, attentionMask: mask)
            let pooled = context.pooling(output, normalize: true, applyLayerNorm: true)
            pooled.eval()
            return pooled[0].asArray(Float.self)
        }
    }

    private func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

/// Objective-C-friendly frame entry point used by CameraViewController.
@objcMembers
public final class ROBMLXRuntime: NSObject {
    public static let shared = ROBMLXRuntime()

    public func offerCameraSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        Task { await ROBMLXEngine.shared.offerVisionFrame(image) }
    }

    public func setVisionEnabled(_ enabled: Bool) {
        Task { await ROBMLXEngine.shared.setVisionEnabled(enabled) }
    }
}
