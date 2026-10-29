import XCTest
import CoreML
@testable import TiledInferenceEngine
@testable import TruongScalerCore
@testable import MetalColorEngine

final class AdditionalModelReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let checkpoints: [String: String]
        let cases: [Sample]
    }
    private struct Sample: Decodable {
        let model: String
        let size: Int
        let pattern: String
        let indices: [Int]
        let expected: [Double]
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var modelsDirectory: URL { root.appendingPathComponent("Targets/TruongScalerApp/Models") }

    private func loadReference() throws -> Reference {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/TiledInferenceEngineTests/Fixtures/additional-reference-samples.json")))
        XCTAssertEqual(reference.checkpoints["EDSR_Baseline"], "1bc9523228fdc3b0a5ddb0d7062001e22b31bbb398ae09cfdefb97e8ee06e171")
        XCTAssertEqual(reference.checkpoints["HAT_S"], "3e249a901c2aed6b82548875e21847ef6c015a40c814237a7a0abb10c69d5ddf")
        let identifiers: [CoreMLModelIdentifier] = [.edsrX2_192, .edsrX2_256, .hatSX2_192, .hatSX2_256]
        let expectedCases = Set(identifiers.flatMap { id in
            ["gradient", "checker", "luma-checker"].map { "\(id.rawValue):\($0)" }
        })
        XCTAssertEqual(reference.cases.count, expectedCases.count)
        XCTAssertEqual(Set(reference.cases.map { "\($0.model):\($0.pattern)" }), expectedCases)
        for sample in reference.cases {
            let id = try XCTUnwrap(CoreMLModelIdentifier(rawValue: sample.model))
            XCTAssertEqual(sample.size, id.inputTileSize, sample.model)
            XCTAssertEqual(sample.indices.count, 1024, sample.model)
            XCTAssertEqual(sample.expected.count, sample.indices.count, sample.model)
            XCTAssertEqual(Set(sample.indices).count, sample.indices.count, sample.model)
            XCTAssertTrue(sample.expected.allSatisfy(\.isFinite), sample.model)
        }
        return reference
    }

    func testEDSRVariantsMatchOfficialReferenceOnBothSupportedComputePolicies() async throws {
        let reference = try loadReference()
        for units in [MLComputeUnits.cpuAndNeuralEngine, .cpuOnly] {
            let registry = CoreMLModelRegistry(initialComputeUnits: units,
                customSearchDirectories: [modelsDirectory], availabilityPolicy: .requireProductionModels)
            for sample in reference.cases where sample.model.hasPrefix("EDSR_Baseline_") {
                let id = try XCTUnwrap(CoreMLModelIdentifier(rawValue: sample.model))
                let input = try inputTensor(for: sample)
                let output = try await registry.predict(modelID: id, inputPlanarFP16: input,
                    inputHeight: sample.size, inputWidth: sample.size,
                    outputHeight: id.outputTileSize, outputWidth: id.outputTileSize, tileIndex: 0)
                try verify(output, input: input, sample: sample, units: units)
            }
        }
    }

    func testHATRawPredictionsMatchOfficialReferenceOnEverySupportedComputeRequest() async throws {
        let reference = try loadReference()
        let registry = CoreMLModelRegistry(initialComputeUnits: .cpuOnly,
            availabilityPolicy: .requireProductionModels, searchDirectoriesOverride: [modelsDirectory])
        let discovered = await registry.discoveredProductionModelURLs()
        var successful = Set<String>()
        var unavailable = Set<String>()
        for units in [MLComputeUnits.all, .cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly] {
            for id in [CoreMLModelIdentifier.hatSX2_192, .hatSX2_256] {
                try autoreleasepool {
                    let assetURL = try XCTUnwrap(discovered[id], "Missing required \(id.rawValue) compiled asset")
                    XCTAssertEqual(assetURL.pathExtension, "mlmodelc")
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = units
                    // Load CoreML directly: registry compute restrictions or a resampler must never
                    // turn a broken raw GPU request into an apparently passing parity result.
                    let requestID = "\(id.rawValue):\(units.rawValue)"
                    let model: MLModel
                    do {
                        model = try MLModel(contentsOf: assetURL, configuration: configuration)
                    } catch {
                        #if targetEnvironment(simulator)
                        let failure = error as NSError
                        if (units == .all || units == .cpuAndGPU), failure.domain == "com.apple.CoreML",
                           failure.localizedDescription.contains("error code: -14") {
                            // Record the actual raw request failure, rather than turning a registry
                            // remap into a claimed GPU parity pass. Both CPU requests below must
                            // still load these exact assets and pass every reference case.
                            print("HAT_RAW_GPU_UNAVAILABLE request=\(requestID) reason=\(failure.localizedDescription)")
                            unavailable.insert(requestID)
                            return
                        }
                        #endif
                        throw error
                    }
                    XCTAssertEqual(model.configuration.computeUnits, units)
                    let description = model.modelDescription
                    let inputConstraint = try XCTUnwrap(description.inputDescriptionsByName["input_tile"]?.multiArrayConstraint)
                    let outputConstraint = try XCTUnwrap(description.outputDescriptionsByName["output_tile"]?.multiArrayConstraint)
                    XCTAssertEqual(inputConstraint.shape.map(\.intValue), id.expectedInputShape)
                    XCTAssertEqual(inputConstraint.dataType, .float16)
                    XCTAssertEqual(outputConstraint.shape.map(\.intValue), id.expectedOutputShape)
                    XCTAssertEqual(outputConstraint.dataType, .float16)
                    for sample in reference.cases where sample.model == id.rawValue {
                        let input = try inputTensor(for: sample)
                        let tensor = try MLMultiArray(shape: id.expectedInputShape.map { NSNumber(value: $0) }, dataType: .float16)
                        CoreMLModelRegistry.copyContiguousToMultiArray(input, into: tensor,
                            channels: 3, height: sample.size, width: sample.size)
                        let provider = try MLDictionaryFeatureProvider(dictionary: ["input_tile": MLFeatureValue(multiArray: tensor)])
                        let prediction = try model.prediction(from: provider)
                        let rawOutputTensor = try XCTUnwrap(prediction.featureValue(for: "output_tile")?.multiArrayValue)
                        let outputTensor = try XCTUnwrap(rawOutputTensor.shape.map(\.intValue) == id.expectedOutputShape
                            ? rawOutputTensor : nil, "Wrong raw output shape for \(id.rawValue)")
                        let output = try CoreMLModelRegistry.copyMultiArrayToContiguous(outputTensor,
                            channels: 3, height: id.outputTileSize, width: id.outputTileSize,
                            modelName: id.rawValue, tileIndex: 0)
                        try verify(output, input: input, sample: sample, units: units)
                    }
                    successful.insert(requestID)
                }
            }
        }
        let ids = [CoreMLModelIdentifier.hatSX2_192, .hatSX2_256]
        let required = Set(ids.flatMap { id in
            [MLComputeUnits.cpuOnly, .cpuAndNeuralEngine].map { "\(id.rawValue):\($0.rawValue)" }
        })
        XCTAssertTrue(required.isSubset(of: successful), "Both CPU requests must execute the official cases for both shapes")
        XCTAssertEqual(successful.count + unavailable.count, 8, "Every raw request must be observed")
        #if !targetEnvironment(simulator)
        XCTAssertTrue(unavailable.isEmpty)
        XCTAssertEqual(successful.count, 8)
        #endif
    }

    private func inputTensor(for sample: Sample) throws -> [Float16] {
        _ = try XCTUnwrap(["gradient", "checker", "luma-checker"].contains(sample.pattern) ? sample.pattern : nil)
        let size = sample.size, plane = size * size
        var input = [Float16](repeating: 0, count: 3 * plane)
        for y in 0..<size {
            for x in 0..<size {
                let index = y * size + x
                if sample.pattern == "gradient" {
                    input[index] = Float16(Float(x) / Float(size - 1))
                    input[plane + index] = Float16(Float(y) / Float(size - 1))
                    input[2 * plane + index] = Float16(1 - Float(x) / Float(size - 1))
                } else {
                    input[index] = Float16((x + y) % 2)
                    input[plane + index] = sample.pattern == "luma-checker" ? input[index] : 1 - input[index]
                    input[2 * plane + index] = input[index]
                }
            }
        }
        return input
    }

    private func verify(_ output: [Float16], input: [Float16], sample: Sample, units: MLComputeUnits) throws {
        let id = try XCTUnwrap(CoreMLModelIdentifier(rawValue: sample.model))
        let backbone: BackboneModelKind
        switch id {
        case .edsrX2_192, .edsrX2_256: backbone = .edsrBaseline
        case .hatSX2_192, .hatSX2_256: backbone = .hatSmall
        default: return XCTFail("Unexpected additional-model reference identity \(sample.model)")
        }
        XCTAssertEqual(output.count, 3 * id.outputTileSize * id.outputTileSize)
        XCTAssertTrue(output.allSatisfy(\.isFinite), "\(sample.model) units=\(units.rawValue) \(sample.pattern)")
        XCTAssertGreaterThan(Float(output.max() ?? 0) - Float(output.min() ?? 0), 0.1,
            "A zero/constant raw prediction must fail, even when it is finite")
        var mse = 0.0, maximum = 0.0
        for (index, expected) in zip(sample.indices, sample.expected) {
            let actual = try XCTUnwrap(output.indices.contains(index) ? output[index] : nil)
            let difference = abs(Double(actual) - expected)
            mse += difference * difference
            maximum = max(maximum, difference)
        }
        let psnr = -10 * log10(max(mse / Double(sample.indices.count), 1e-20))
        print("ADDITIONAL_OFFICIAL_PARITY model=\(sample.model) units=\(units.rawValue) pattern=\(sample.pattern) PSNR=\(psnr) maxError=\(maximum)")
        XCTAssertGreaterThanOrEqual(psnr, 50)
        XCTAssertLessThan(maximum, 0.02)
        if sample.pattern == "luma-checker" {
            // The independent official prediction also rings outside the production envelope.
            // Verify that finite but unsafe raw detail is refused before reconstruction/commit.
            XCTAssertTrue(output.contains { !backbone.predictionSampleRange.contains(Float($0)) })
            let plane = sample.size * sample.size
            let tensors = PreparedTileTensors(tileSize: sample.size, logConstantK: log1pf(16), alphaConstant: 16,
                planarTensorFP16: input, cbPlane: [Float](repeating: 0, count: plane),
                crPlane: [Float](repeating: 0, count: plane), alphaPlane: [Float16](repeating: 1, count: plane))
            XCTAssertThrowsError(try MetalColorProcessor(preferMetal: false).restoreSuperResolvedLuminance(
                output, tensors: tensors, outputSize: id.outputTileSize, modelName: sample.model, tileIndex: 0,
                predictionRange: backbone.predictionSampleRange))
        }
    }
}
