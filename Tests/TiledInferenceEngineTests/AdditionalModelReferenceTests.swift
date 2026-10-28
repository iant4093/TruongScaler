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
    func testAllNewVariantsMatchOfficialReferenceOnBothSupportedComputePolicies() async throws {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/TiledInferenceEngineTests/Fixtures/additional-reference-samples.json")))
        XCTAssertEqual(reference.checkpoints["EDSR_Baseline"], "1bc9523228fdc3b0a5ddb0d7062001e22b31bbb398ae09cfdefb97e8ee06e171")
        for units in [MLComputeUnits.cpuAndNeuralEngine, .cpuOnly] {
            let registry = CoreMLModelRegistry(initialComputeUnits: units,
                customSearchDirectories: [root.appendingPathComponent("Targets/TruongScalerApp/Models")],
                availabilityPolicy: .requireProductionModels)
            for sample in reference.cases {
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
                let id = try XCTUnwrap(CoreMLModelIdentifier(rawValue: sample.model))
                let output = try await registry.predict(modelID: id, inputPlanarFP16: input,
                    inputHeight: size, inputWidth: size, outputHeight: size * 2, outputWidth: size * 2, tileIndex: 0)
                XCTAssertTrue(output.allSatisfy(\.isFinite))
                var mse = 0.0, maximum = 0.0
                for (index, expected) in zip(sample.indices, sample.expected) {
                    let d = abs(Double(output[index]) - expected); mse += d * d; maximum = max(maximum, d)
                }
                let psnr = -10 * log10(max(mse / Double(sample.indices.count), 1e-20))
                print("ADDITIONAL_OFFICIAL_PARITY model=\(sample.model) units=\(units.rawValue) pattern=\(sample.pattern) PSNR=\(psnr) maxError=\(maximum)")
                XCTAssertGreaterThanOrEqual(psnr, 50)
                XCTAssertLessThan(maximum, 0.02)
                if sample.pattern == "luma-checker" {
                    // The raw official predictions can ring severely on adversarial fine detail.
                    // Refuse them before color reconstruction/commit, rather than masking the fault.
                    let backbone: BackboneModelKind = .edsrBaseline
                    let tensors = PreparedTileTensors(tileSize: size, logConstantK: log1pf(16), alphaConstant: 16,
                        planarTensorFP16: input, cbPlane: [Float](repeating: 0, count: plane),
                        crPlane: [Float](repeating: 0, count: plane), alphaPlane: [Float16](repeating: 1, count: plane))
                    XCTAssertThrowsError(try MetalColorProcessor(preferMetal: false).restoreSuperResolvedLuminance(
                        output, tensors: tensors, outputSize: size * 2, modelName: sample.model, tileIndex: 0,
                        predictionRange: backbone.predictionSampleRange))
                }
            }
        }
    }
}
