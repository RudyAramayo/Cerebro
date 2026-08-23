//
//  ROBFaceEmbeddingModel.swift
//  Cerebro
//
//  Runtime-selectable, locally installed AdaFace Core ML encoders.
//

import CoreML
import Foundation
import Vision

public enum ROBFaceEmbeddingModelOption: String, CaseIterable, Sendable {
    case webFace4M = "adaface-ir18-webface4m-v1"
    case vggFace2 = "adaface-ir18-vggface2-v1"

    public var displayName: String {
        switch self {
        case .webFace4M: return "AdaFace R18 — WebFace4M"
        case .vggFace2: return "AdaFace R18 — VGGFace2"
        }
    }

    public var compiledModelName: String {
        switch self {
        case .webFace4M: return "AdaFace-R18-WebFace4M.mlmodelc"
        case .vggFace2: return "AdaFace-R18-VGGFace2.mlmodelc"
        }
    }

    public var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/Models", isDirectory: true)
            .appendingPathComponent(compiledModelName, isDirectory: true)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    public var menuTitle: String {
        isInstalled ? displayName : "\(displayName) (not installed)"
    }
}

final class ROBFaceCoreMLEncoder {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let imageConstraint: MLImageConstraint

    init(option: ROBFaceEmbeddingModelOption) throws {
        guard option.isInstalled else {
            throw ROBFaceIdentityGalleryError.storage("\(option.displayName) is not installed.")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: option.installedURL, configuration: configuration)
        guard let input = model.modelDescription.inputDescriptionsByName.first(where: {
            $0.value.type == .image && $0.value.imageConstraint != nil
        }), let constraint = input.value.imageConstraint else {
            throw ROBFaceIdentityGalleryError.storage("The installed AdaFace model has no image input.")
        }
        guard let output = model.modelDescription.outputDescriptionsByName.first(where: {
            $0.value.type == .multiArray
        }) else {
            throw ROBFaceIdentityGalleryError.storage("The installed AdaFace model has no embedding output.")
        }
        inputName = input.key
        outputName = output.key
        imageConstraint = constraint
    }

    func embedding(for image: CGImage) throws -> [Float] {
        let imageValue = try MLFeatureValue(
            cgImage: image,
            constraint: imageConstraint,
            options: [MLFeatureValue.ImageOption.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: imageValue])
        guard let array = try model.prediction(from: provider).featureValue(for: outputName)?.multiArrayValue else {
            throw ROBFaceIdentityGalleryError.storage("AdaFace returned no embedding.")
        }
        var values = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else {
            throw ROBFaceIdentityGalleryError.storage("AdaFace returned an invalid embedding.")
        }
        for index in values.indices { values[index] /= norm }
        return values
    }
}
