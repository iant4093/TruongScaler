import XCTest
import CoreML
@testable import TiledInferenceEngine

/// Cross-platform regression against independent official PyTorch outputs, including the
/// high-frequency case that exposed unsupported execution paths during model evaluation.
final class QuickSRReferenceParityTests: XCTestCase {
    private struct Reference: Decodable {
        let checkpointSHA256: String
        let cases: [Sample]
    }
    private struct Sample: Decodable {
        let size: Int
        let pattern: String
        let indices: [Int]
        let expected: [Double]
    }

    func testSupportedProductionPoliciesMatchOfficialPyTorchReference() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/TiledInferenceEngineTests/Fixtures/quicksr-reference-samples.json"))
        let reference = try JSONDecoder().decode(Reference.self, from: data)
        XCTAssertEqual(reference.checkpointSHA256, "0c6e0f4e2b444b161d6bce22852b0e2aa0dc391ef804c99e867882dd9715ad9d")
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
                            input[plane + index] = 1 - input[index]
                            input[2 * plane + index] = input[index]
                        }
                    }
                }
                let output = try await registry.predict(modelID: size == 192 ? .quickSRx2_192 : .quickSRx2_256,
                    inputPlanarFP16: input, inputHeight: size, inputWidth: size,
                    outputHeight: size * 2, outputWidth: size * 2, tileIndex: 0)
                XCTAssertTrue(output.allSatisfy(\.isFinite))
                var mse = 0.0, maximum = 0.0
                for (index, expected) in zip(sample.indices, sample.expected) {
                    let difference = abs(Double(output[index]) - expected)
                    mse += difference * difference; maximum = max(maximum, difference)
                }
                let psnr = -10 * log10(max(mse / Double(sample.indices.count), 1e-20))
                print("OFFICIAL_QUICKSR_PARITY units=\(units.rawValue) size=\(size) pattern=\(sample.pattern) PSNR=\(psnr) maxError=\(maximum)")
                XCTAssertGreaterThanOrEqual(psnr, 50)
                XCTAssertLessThan(maximum, 0.02)
            }
        }
    }
}
