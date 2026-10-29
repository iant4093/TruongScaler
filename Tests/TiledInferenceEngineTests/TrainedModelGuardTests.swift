import XCTest
import CoreML
@testable import TiledInferenceEngine
@testable import TruongScalerCore
@testable import MetalColorEngine

final class TrainedModelGuardTests: XCTestCase {
    func testProductionComputePolicyUsesTheValidatedGraphPath() async throws {
        let registry = CoreMLModelRegistry(initialComputeUnits: .all, availabilityPolicy: .requireProductionModels)
        let initial = await registry.currentUnits()
        XCTAssertEqual(initial, .cpuAndNeuralEngine)
        await registry.setComputeUnits(.cpuAndGPU)
        let gpuRequest = await registry.currentUnits()
        XCTAssertEqual(gpuRequest, .cpuAndNeuralEngine)
        await registry.setComputeUnits(.cpuOnly)
        let cpuRequest = await registry.currentUnits()
        XCTAssertEqual(cpuRequest, .cpuOnly)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = TiledPipelineExecutor(workingDirectory: directory, modelRegistry: registry,
            checkpointStore: JobCheckpointStore(directory: directory))
        await executor.switchExecutionTier(.gpuAndANE)
        let effective = await registry.currentUnits()
        let description = await executor.currentRequestedComputeDescriptionForTesting()
        XCTAssertEqual(effective, .cpuAndNeuralEngine)
        XCTAssertTrue(description.contains("cpuAndNeuralEngine"), description)
    }

    func testTensorMarshalingRefusesNonfiniteValuesInEverySupportedType() throws {
        for type in [MLMultiArrayDataType.float16, .float32, .double] {
            let array = try MLMultiArray(shape: [1, 3, 2, 2], dataType: type)
            for index in 0..<12 { array[index] = 0.5 }
            array[4] = NSNumber(value: Double.nan)
            XCTAssertThrowsError(try CoreMLModelRegistry.copyMultiArrayToContiguous(array,
                channels: 3, height: 2, width: 2, modelName: "test", tileIndex: 3))
        }
    }

    func testRealNativeTwoTimesPredictionIsFiniteOnHighFrequencyAndClippedControls() async throws {
        let models = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Targets/TruongScalerApp/Models")
        for units in [MLComputeUnits.all, .cpuAndNeuralEngine, .cpuOnly] {
            let registry = CoreMLModelRegistry(initialComputeUnits: units, customSearchDirectories: [models],
                availabilityPolicy: .requireProductionModels)
            for pattern in 0..<5 {
                let size = 192, plane = size * size
                var input = [Float16](repeating: 0, count: 3 * plane)
                for channel in 0..<3 {
                    for y in 0..<size {
                        for x in 0..<size {
                            let value: Float
                            switch pattern {
                            case 0: value = 0
                            case 1: value = 1
                            case 2: value = Float((x + y + channel) % 2)
                            case 3: value = Float((x + channel) % 3 == 0 ? 1 : 0)
                            default: value = Float(y) / Float(size - 1)
                            }
                            input[channel * plane + y * size + x] = Float16(value)
                        }
                    }
                }
                let output = try await registry.predict(modelID: .quickSRx2_192, inputPlanarFP16: input,
                    inputHeight: size, inputWidth: size, outputHeight: 384, outputWidth: 384, tileIndex: pattern)
                print("QUICKSR_BACKEND requestedUnits=\(units.rawValue) pattern=\(pattern) min=\(output.min() ?? -1) max=\(output.max() ?? -1)")
                if pattern == 1 { XCTAssertGreaterThan(Float(output.min() ?? 0), 0.9) }
                if pattern >= 2 { XCTAssertGreaterThan(Float(output.max() ?? 0) - Float(output.min() ?? 0), 0.1) }
                XCTAssertEqual(output.count, 3 * 384 * 384)
                XCTAssertTrue(output.allSatisfy { $0.isFinite && $0 >= -0.02 && $0 <= 1.02 })
            }
        }
    }

    func testTransferDomainRoundTripPreservesHDRLuminanceAndRejectsInvalidPredictions() throws {
        let processor = MetalColorProcessor(preferMetal: false)
        let peak: Float = 8, alpha: Float = 16
        let values: [Float] = [0, 0.0001, 0.1, 0.5, 1, 2, 4, 8]
        let size = 8, plane = size * size, logK = log1pf(alpha * peak)
        var logValues = [Float16](repeating: 0, count: 3 * plane)
        for i in logValues.indices { logValues[i] = Float16(log1pf(alpha * values[i % values.count]) / logK) }
        let tensors = PreparedTileTensors(tileSize: size, logConstantK: logK, alphaConstant: alpha,
            planarTensorFP16: logValues, cbPlane: [Float](repeating: 0, count: plane),
            crPlane: [Float](repeating: 0, count: plane), alphaPlane: [Float16](repeating: 1, count: plane))
        let encoded = try processor.superResolutionInputTensor(from: tensors)
        XCTAssertTrue(encoded.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        let restored = try processor.restoreSuperResolvedLuminance(encoded, tensors: tensors, outputSize: size,
            modelName: "test", tileIndex: 0)
        for i in restored.indices { XCTAssertEqual(Float(restored[i]), Float(logValues[i]), accuracy: 0.001) }
        for invalid in [Float16.nan, .infinity, -0.1, 1.2] {
            var prediction = encoded; prediction[0] = invalid
            XCTAssertThrowsError(try processor.restoreSuperResolvedLuminance(prediction, tensors: tensors,
                outputSize: size, modelName: "test", tileIndex: 4))
        }
        for backbone in [BackboneModelKind.edsrBaseline, .hatSmall] {
            let restored = try processor.restoreSuperResolvedLuminance(encoded, tensors: tensors,
                outputSize: size, modelName: backbone.rawValue, tileIndex: 0,
                predictionRange: backbone.predictionSampleRange)
            for i in restored.indices { XCTAssertEqual(Float(restored[i]), Float(logValues[i]), accuracy: 0.001) }
            for invalid in [Float16.nan, .infinity, -0.5, 1.5] {
                var prediction = encoded; prediction[0] = invalid
                XCTAssertThrowsError(try processor.restoreSuperResolvedLuminance(prediction, tensors: tensors,
                    outputSize: size, modelName: backbone.rawValue, tileIndex: 4,
                    predictionRange: backbone.predictionSampleRange))
            }
        }
    }

    func testUnavailableJobRefusalLeavesExistingArtifactsUnmodified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("existing-output.bin")
        let bytes = Data([1,2,3,4]); try bytes.write(to: sentinel)
        let executor = TiledPipelineExecutor(workingDirectory: directory,
            modelRegistry: CoreMLModelRegistry(availabilityPolicy: .requireProductionModels),
            checkpointStore: JobCheckpointStore(directory: directory))
        for (backbone, scale, denoise) in [(BackboneModelKind.unavailable, ScaleFactor.x2, DenoiseMode.off),
                                         (.quickSRNet, .x4, .off), (.quickSRNet, .x2, .forceOn)] {
            let config = UpscaleJobConfig(sourceImageURL: sentinel, scaleFactor: scale, backbone: backbone, denoiseMode: denoise)
            do { _ = try await executor.executeOrResumeJob(config: config); XCTFail("Unavailable job must be refused") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Start a new 2×")) }
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [sentinel.lastPathComponent])
        }
    }
}
