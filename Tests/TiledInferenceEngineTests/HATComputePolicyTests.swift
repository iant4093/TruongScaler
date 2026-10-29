import Foundation
import XCTest
import CoreML
import MetalColorEngine
import TruongScalerCore
@testable import TiledInferenceEngine

final class HATComputePolicyTests: XCTestCase, @unchecked Sendable {
    func testPerModelMappingKeepsExistingRestrictionsAndExplicitSafeRequests() {
        let production = CoreMLModelRegistry(initialComputeUnits: .all, availabilityPolicy: .requireProductionModels)
        let fallback = CoreMLModelRegistry(initialComputeUnits: .all, availabilityPolicy: .allowDeterministicFallback)
        for modelID in CoreMLModelIdentifier.allCases {
            #if targetEnvironment(simulator)
            let permitsGPU = false
            #else
            let permitsGPU = modelID == .hatSX2_192 || modelID == .hatSX2_256
            #endif
            for request in [MLComputeUnits.all, .cpuAndGPU, .cpuAndNeuralEngine, .cpuOnly] {
                let expected: MLComputeUnits = permitsGPU || request == .cpuOnly ? request : .cpuAndNeuralEngine
                XCTAssertEqual(production.effectiveComputeUnits(for: request, modelID: modelID), expected,
                               "The selected compute request must be resolved for \(modelID.rawValue)")
                XCTAssertEqual(fallback.effectiveComputeUnits(for: request, modelID: modelID), request)
            }
        }
        XCTAssertEqual(production.effectiveComputeUnits(for: .all), .cpuAndNeuralEngine,
                       "The existing model-agnostic API keeps its QuickSRNet restriction")
    }

    func testExecutorForegroundAndBackgroundRequestsRetainHATIntentWithoutChangingQuickPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HATCompute-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CoreMLModelRegistry(initialComputeUnits: .all, availabilityPolicy: .requireProductionModels)
        let executor = TiledPipelineExecutor(workingDirectory: directory, modelRegistry: registry,
            checkpointStore: try JobCheckpointStore(workingDirectory: directory),
            colorProcessor: MetalColorProcessor(preferMetal: false))
        await executor.switchExecutionTier(.gpuAndANE)
        let rawForeground = await registry.currentRequestedUnits()
        let hatForeground = await registry.currentUnits(for: .hatSX2_192)
        let quickForeground = await registry.currentUnits()
        let hatDescription = await executor.currentRequestedComputeDescriptionForTesting(modelID: .hatSX2_192)
        let quickDescription = await executor.currentRequestedComputeDescriptionForTesting()
        #if targetEnvironment(simulator)
        let foreground: MLComputeUnits = .cpuAndNeuralEngine
        #else
        let foreground: MLComputeUnits = .all
        #endif
        XCTAssertEqual(rawForeground, .all)
        XCTAssertEqual(hatForeground, foreground)
        XCTAssertEqual(quickForeground, .cpuAndNeuralEngine)
        XCTAssertTrue(hatDescription.hasPrefix(CoreMLModelRegistry.describeComputeUnits(foreground)))
        XCTAssertTrue(quickDescription.contains("cpuAndNeuralEngine"))

        await executor.setBackgroundExecutionMode(true)
        let rawBackground = await registry.currentRequestedUnits()
        let hatBackground = await registry.currentUnits(for: .hatSX2_256)
        let backgroundDescription = await executor.currentRequestedComputeDescriptionForTesting(modelID: .hatSX2_256)
        XCTAssertEqual(rawBackground, .cpuAndNeuralEngine)
        XCTAssertEqual(hatBackground, .cpuAndNeuralEngine)
        XCTAssertTrue(backgroundDescription.contains("cpuAndNeuralEngine"))
        await executor.setBackgroundExecutionMode(false)
        let returnedForeground = await registry.currentUnits(for: .hatSX2_256)
        let stillRestrictedEDSR = await registry.currentUnits(for: .edsrX2_256)
        XCTAssertEqual(returnedForeground, foreground)
        XCTAssertEqual(stillRestrictedEDSR, .cpuAndNeuralEngine)
        await executor.switchExecutionTier(.cpuOnly)
        let explicitCPU = await registry.currentUnits(for: .hatSX2_192)
        XCTAssertEqual(explicitCPU, .cpuOnly)
    }

    func testRawRequestChangeEvictsARealLoadedModelEvenIfItsLegacyEffectivePolicyIsEqual() async throws {
        let models = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Targets/TruongScalerApp/Models")
        let registry = CoreMLModelRegistry(initialComputeUnits: .all, customSearchDirectories: [models],
                                          availabilityPolicy: .requireProductionModels)
        let tensor = [Float16](repeating: 0.5, count: 192 * 192 * 3)
        let first = try await registry.predict(modelID: .quickSRx2_192, inputPlanarFP16: tensor,
            inputHeight: 192, inputWidth: 192, outputHeight: 384, outputWidth: 384, tileIndex: 0)
        let loadedBefore = await registry.loadedModelIdentifiersForTesting()
        XCTAssertEqual(loadedBefore, [.quickSRx2_192])
        await registry.setComputeUnits(.cpuAndGPU)
        let loadedAfter = await registry.loadedModelIdentifiersForTesting()
        let quickPolicy = await registry.currentUnits(for: .quickSRx2_192)
        let hatPolicy = await registry.currentUnits(for: .hatSX2_192)
        XCTAssertTrue(loadedAfter.isEmpty, "A changed raw request must not leave a stale model cached")
        XCTAssertEqual(quickPolicy, .cpuAndNeuralEngine)
        #if targetEnvironment(simulator)
        XCTAssertEqual(hatPolicy, .cpuAndNeuralEngine)
        #else
        XCTAssertEqual(hatPolicy, .cpuAndGPU)
        #endif
        let reloaded = try await registry.predict(modelID: .quickSRx2_192, inputPlanarFP16: tensor,
            inputHeight: 192, inputWidth: 192, outputHeight: 384, outputWidth: 384, tileIndex: 1)
        XCTAssertEqual(reloaded, first, "QuickSRNet still uses the same validated graph policy after reloading")
        let loadedAgain = await registry.loadedModelIdentifiersForTesting()
        XCTAssertEqual(loadedAgain, [.quickSRx2_192])
    }
}
