import XCTest
import Foundation
import CoreML
@testable import TiledInferenceEngine
@testable import TruongScalerCore

/// Regression coverage for the production model-availability policy (contract §8,
/// `docs/DEVELOPMENT.md` Section 6).
///
/// This file is intentionally separate from `TiledInferenceEngineTests.swift` (group C ownership).
/// Tests use the registry's internal search-directory override so a model is deterministically absent
/// without depending on the repository's trained assets under `Targets/TruongScalerApp/Models`.
/// The trained-model tests opt into that directory explicitly; the implicit repository search path is
/// excluded inside XCTest so small synthetic tests cannot accidentally load a multi-hundred-MB model.
final class ModelAvailabilityPolicyTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongScalerModelPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
    }

    override func tearDownWithError() throws {
        if let directory = temporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectory = nil
    }

    // MARK: - Required policy: a missing model must fail visibly

    func testRequiredPolicyMissingModelThrowsActionableModelNotFound() async throws {
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            availabilityPolicy: .requireProductionModels,
            searchDirectoriesOverride: [temporaryDirectory]
        )
        let policy = await registry.currentAvailabilityPolicy()
        XCTAssertEqual(policy, .requireProductionModels)

        let inputHeight = 4
        let inputWidth = 6
        let input = [Float16](repeating: 0.5, count: 3 * inputHeight * inputWidth)

        do {
            _ = try await registry.predict(
                modelID: .quickSRx2_192,
                inputPlanarFP16: input,
                inputHeight: inputHeight,
                inputWidth: inputWidth,
                outputHeight: inputHeight * 2,
                outputWidth: inputWidth * 2,
                tileIndex: 7
            )
            XCTFail("A missing production model must not silently return a deterministic resample.")
        } catch let error as ScalerError {
            guard case .modelNotFound(let message) = error else {
                XCTFail("Expected ScalerError.modelNotFound, got \(error)")
                return
            }
            // The frozen modelNotFound case carries one string; the required-policy error embeds the
            // model id and every searched directory so the failure is actionable in the app.
            XCTAssertTrue(message.contains("QuickSRNet_Large_x2_192"), "Missing-model error does not name the model: \(message)")
            XCTAssertTrue(
                message.contains(temporaryDirectory.standardizedFileURL.path),
                "Missing-model error does not list the searched directory: \(message)"
            )
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - Explicit CI/test fallback remains deterministic and contract-shaped

    func testExplicitFallbackPolicyStillReturnsCorrectSizeDeterministicOutput() async throws {
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            availabilityPolicy: .allowDeterministicFallback,
            searchDirectoriesOverride: [temporaryDirectory]
        )
        let inputHeight = 4
        let inputWidth = 6
        var input = [Float16](repeating: 0, count: 3 * inputHeight * inputWidth)
        let planeSize = inputHeight * inputWidth
        for channel in 0..<3 {
            for index in 0..<planeSize {
                input[channel * planeSize + index] = Float16(
                    0.05 * Float(channel + 1) + 0.25 * Float(index % inputWidth) / Float(inputWidth)
                )
            }
        }

        let first = try await registry.predict(
            modelID: .quickSRx2_192,
            inputPlanarFP16: input,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            outputHeight: inputHeight * 2,
            outputWidth: inputWidth * 2,
            tileIndex: 0
        )
        let second = try await registry.predict(
            modelID: .quickSRx2_192,
            inputPlanarFP16: input,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            outputHeight: inputHeight * 2,
            outputWidth: inputWidth * 2,
            tileIndex: 0
        )

        XCTAssertEqual(first.count, 3 * (inputHeight * 2) * (inputWidth * 2))
        XCTAssertEqual(first, second, "The explicit CI fallback must be deterministic.")
        XCTAssertTrue(first.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(Set(first.map { Float($0) }).count, 1, "Fallback output must not be a flat constant.")

        // Equal-size denoiser fallback is the documented identity copy.
        let identity = try await registry.predict(
            modelID: .quickSRx2_192,
            inputPlanarFP16: input,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            outputHeight: inputHeight,
            outputWidth: inputWidth,
            tileIndex: 0
        )
        XCTAssertEqual(identity, input, "Equal input/output dimensions must reduce to an identity copy.")
    }

    func testDefaultInitPolicyIsExplicitTestFallback() async {
        // The default preserves pre-existing call sites/tests; production callers opt in to the
        // required policy explicitly (StudioViewModel, group D).
        let registry = CoreMLModelRegistry(initialComputeUnits: .cpuOnly)
        let policy = await registry.currentAvailabilityPolicy()
        XCTAssertEqual(policy, .allowDeterministicFallback)
    }

    // MARK: - Required policy rejects incompatible real-model output sizes

    func testRequiredPolicyRejectsIncompatibleOutputSpatialSize() {
        // Production model would produce 383x383 for a 384x384 contract; that is not the requested
        // spatial size, so the registry must fail rather than silently resize the tensor.
        XCTAssertThrowsError(
            try CoreMLModelRegistry.validateProducedSpatialSize(
                producedHeight: 383,
                producedWidth: 383,
                requestedHeight: 384,
                requestedWidth: 384,
                modelName: CoreMLModelIdentifier.quickSRx2_192.rawValue,
                tileIndex: 3,
                policy: .requireProductionModels
            )
        ) { error in
            guard let scalerError = error as? ScalerError,
                  case .modelInferenceFailed(let modelName, let tileIndex, let reason) = scalerError else {
                XCTFail("Expected ScalerError.modelInferenceFailed, got \(error)")
                return
            }
            XCTAssertEqual(modelName, CoreMLModelIdentifier.quickSRx2_192.rawValue)
            XCTAssertEqual(tileIndex, 3)
            XCTAssertTrue(reason.contains("383"), "Rejection reason does not name the produced size: \(reason)")
            XCTAssertTrue(reason.contains("384"), "Rejection reason does not name the contract size: \(reason)")
            XCTAssertTrue(
                reason.lowercased().contains("silently resize")
                    || reason.lowercased().contains("incompatible spatial size"),
                "Rejection reason must state that silent resizing is refused: \(reason)"
            )
        }

        // Mismatched width alone is rejected as well.
        XCTAssertThrowsError(
            try CoreMLModelRegistry.validateProducedSpatialSize(
                producedHeight: 384,
                producedWidth: 382,
                requestedHeight: 384,
                requestedWidth: 384,
                modelName: "QuickSRNet_Large_x2_192",
                tileIndex: 0,
                policy: .requireProductionModels
            )
        )

        // The explicit CI fallback may still resample a stub model's output up to the contract size.
        let fallbackNeedsResample = try? CoreMLModelRegistry.validateProducedSpatialSize(
            producedHeight: 383,
            producedWidth: 383,
            requestedHeight: 384,
            requestedWidth: 384,
            modelName: "stub",
            tileIndex: 0,
            policy: .allowDeterministicFallback
        )
        XCTAssertEqual(
            fallbackNeedsResample,
            true,
            "The CI fallback must be allowed to resample a mismatched stub output."
        )

        // Matching sizes never need a resample under either policy.
        let requiredMatch = try? CoreMLModelRegistry.validateProducedSpatialSize(
            producedHeight: 384,
            producedWidth: 384,
            requestedHeight: 384,
            requestedWidth: 384,
            modelName: "real",
            tileIndex: 0,
            policy: .requireProductionModels
        )
        XCTAssertEqual(requiredMatch, false)
        let fallbackMatch = try? CoreMLModelRegistry.validateProducedSpatialSize(
            producedHeight: 384,
            producedWidth: 384,
            requestedHeight: 384,
            requestedWidth: 384,
            modelName: "real",
            tileIndex: 0,
            policy: .allowDeterministicFallback
        )
        XCTAssertEqual(fallbackMatch, false)
    }

    // MARK: - Generic requests and validated production compute policy

    func testComputeRequestsResolveToValidatedProductionPolicy() async {
        XCTAssertEqual(ModelExecutionTier.gpuAndANE.computeUnits.rawValue, MLComputeUnits.all.rawValue)
        XCTAssertEqual(ModelExecutionTier.cpuAndANE.computeUnits.rawValue, MLComputeUnits.cpuAndNeuralEngine.rawValue)
        XCTAssertEqual(ModelExecutionTier.cpuOnly.computeUnits.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(ModelExecutionTier.forBackgroundMode(true), .cpuAndANE)
        XCTAssertEqual(ModelExecutionTier.forBackgroundMode(false), .gpuAndANE)

        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            availabilityPolicy: .requireProductionModels,
            searchDirectoriesOverride: [temporaryDirectory]
        )
        let initial = await registry.currentUnits()
        XCTAssertEqual(initial.rawValue, MLComputeUnits.cpuOnly.rawValue)
        await registry.setExecutionTier(.gpuAndANE)
        let foreground = await registry.currentUnits()
        XCTAssertEqual(foreground.rawValue, MLComputeUnits.cpuAndNeuralEngine.rawValue)
        await registry.setExecutionTier(.cpuAndANE)
        let background = await registry.currentUnits()
        XCTAssertEqual(background.rawValue, MLComputeUnits.cpuAndNeuralEngine.rawValue)
    }
}
