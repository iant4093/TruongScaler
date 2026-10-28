import Foundation
import CoreML
import TruongScalerCore

/// Canonical CoreML `.mlpackage` model identifiers (`docs/DEVELOPMENT.md` Section 1.1).
public enum CoreMLModelIdentifier: String, CaseIterable, Sendable {
    case quickSRx2_256 = "QuickSRNet_Large_x2_256"
    case quickSRx2_192 = "QuickSRNet_Large_x2_192"
    case edsrX2_192 = "EDSR_Baseline_x2_192"
    case edsrX2_256 = "EDSR_Baseline_x2_256"
    public var inputTileSize: Int { rawValue.hasSuffix("_256") ? 256 : 192 }
    public var outputScale: Int { 2 }
    public var outputTileSize: Int { inputTileSize * outputScale }
    public var expectedInputShape: [Int] { [1, 3, inputTileSize, inputTileSize] }
    public var expectedOutputShape: [Int] { [1, 3, outputTileSize, outputTileSize] }
    public static func superResolver(backbone: BackboneModelKind = .quickSRNet, tier: DeviceTier) -> Self {
        let large = tier == .tierA_HighMemory
        switch backbone {
        case .edsrBaseline: return large ? .edsrX2_256 : .edsrX2_192
        default: return large ? .quickSRx2_256 : .quickSRx2_192
        }
    }
}

/// Foreground/background model execution policy.
///
/// `TruongScalerCore` does not declare an `ExecutionTier` type (only `DeviceTier`), so the required
/// `.gpuAndANE` / `.cpuAndANE` / `.cpuOnly` contract is provided here, scoped to the CoreML registry,
/// without modifying the pre-implemented core module.
public enum ModelExecutionTier: Sendable, Equatable {
    /// Generic foreground request (`.all`); the production model resolves this to CPU+NE.
    case gpuAndANE
    /// Background: CoreML may only use CPU + ANE (never the GPU, whose work the OS can preempt).
    case cpuAndANE
    /// Explicit CPU-only execution (deterministic CI / simulator fallback).
    case cpuOnly

    public var computeUnits: MLComputeUnits {
        switch self {
        case .gpuAndANE: return .all
        case .cpuAndANE: return .cpuAndNeuralEngine
        case .cpuOnly: return .cpuOnly
        }
    }

    public static func forBackgroundMode(_ inBackground: Bool) -> ModelExecutionTier {
        inBackground ? .cpuAndANE : .gpuAndANE
    }
}

/// Model-availability policy for `CoreMLModelRegistry` (`docs/DEVELOPMENT.md` Section 6,
/// contract §8).
///
/// `.allowDeterministicFallback` is intended **only** for explicit CI/test selection. It preserves the
/// historical behaviour where a missing or lightweight stub model is replaced with a deterministic
/// CPU Lanczos/identity resampler. The production app (`StudioViewModel`, group D) uses
/// `.requireProductionModels`, which fails visibly instead of presenting a resampler as AI output.
public enum ModelAvailabilityPolicy: Sendable, Equatable {
    /// Explicit CI/test-only selection: a missing model is replaced with the deterministic resampler,
    /// and a real model whose output spatial size differs from the contract is resampled.
    case allowDeterministicFallback
    /// Production selection: a missing model throws `ScalerError.modelNotFound`, and a real model whose
    /// output spatial size differs from the contract throws `ScalerError.modelInferenceFailed`.
    /// No Lanczos/identity result is ever substituted.
    case requireProductionModels
}

/// Bundle-locating anchor type. `Bundle.module` is intentionally not referenced because the
/// `TiledInferenceEngine` target declares no SwiftPM resources, so no resource bundle accessor is
/// generated; every plausible on-disk location (custom directories, app bundle, test bundle, and the
/// repository's `Targets/TruongScalerApp/Models`) is searched explicitly instead.
private final class CoreMLRegistryBundleToken {}

public enum CoreMLPredictionStage: Sendable, Equatable {
    case loadingModel
    case predicting
}

/// Manages CoreML `.mlpackage` / `.mlmodelc` loading, dynamic `MLComputeUnits` switching,
/// and stride-safe `MLMultiArray` tensor marshaling.
/// Specification: `docs/DEVELOPMENT.md` Section 1.
public actor CoreMLModelRegistry {
    private var loadedModels: [CoreMLModelIdentifier: MLModel] = [:]
    private var compiledURLCache: [CoreMLModelIdentifier: URL] = [:]
    private var discoveredModelURLs: [CoreMLModelIdentifier: URL] = [:]
    private var currentComputeUnits: MLComputeUnits
    private var firstPredictionRecorded: Set<CoreMLModelIdentifier> = []
    private let customSearchDirectories: [URL]
    private let searchDirectories: [URL]
    public nonisolated let availabilityPolicy: ModelAvailabilityPolicy

    /// Creates a registry.
    ///
    /// - Parameter availabilityPolicy: `.allowDeterministicFallback` is the default **only** so existing
    ///   tests and CI call sites keep compiling and can explicitly select deterministic behaviour.
    ///   Production code (the `StudioViewModel` pipeline in group D) must pass
    ///   `.requireProductionModels`; the default is not a production fallback.
    public init(
        initialComputeUnits: MLComputeUnits = .all,
        customSearchDirectories: [URL] = [],
        availabilityPolicy: ModelAvailabilityPolicy = .allowDeterministicFallback
    ) {
        self.currentComputeUnits = Self.resolveComputeUnits(initialComputeUnits, policy: availabilityPolicy)
        self.customSearchDirectories = customSearchDirectories
        self.availabilityPolicy = availabilityPolicy
        self.searchDirectories = Self.makeSearchDirectories(extra: customSearchDirectories)
    }

    /// Test-only initializer that replaces the whole discovery search path with `searchDirectoriesOverride`
    /// so availability-policy tests can guarantee a model is absent without depending on the repository's
    /// production model directories. Production call sites use the public initializer.
    init(
        initialComputeUnits: MLComputeUnits,
        availabilityPolicy: ModelAvailabilityPolicy,
        searchDirectoriesOverride: [URL]
    ) {
        self.currentComputeUnits = Self.resolveComputeUnits(initialComputeUnits, policy: availabilityPolicy)
        self.customSearchDirectories = searchDirectoriesOverride
        self.availabilityPolicy = availabilityPolicy
        self.searchDirectories = searchDirectoriesOverride
    }

    /// The active availability policy (diagnostics only).
    public func currentAvailabilityPolicy() -> ModelAvailabilityPolicy {
        availabilityPolicy
    }

    /// The shipped model is validated locally for CPU+NE requests and explicit CPU-only use.
    /// GPU-enabled iOS simulator predictions returned zeros despite valid tensors/weights. Keep
    /// production on the validated graph path on every platform; no resampler or model substitution.
    public nonisolated func effectiveComputeUnits(for requested: MLComputeUnits) -> MLComputeUnits {
        Self.resolveComputeUnits(requested, policy: availabilityPolicy)
    }

    private nonisolated static func resolveComputeUnits(
        _ requested: MLComputeUnits, policy: ModelAvailabilityPolicy
    ) -> MLComputeUnits {
        guard policy == .requireProductionModels, requested != .cpuOnly else { return requested }
        return .cpuAndNeuralEngine
    }

    /// Dynamically switches compute units (e.g. to `.cpuAndNeuralEngine` when entering background).
    /// Evicts loaded `MLModel` instances so the next inference reloads with the new (safe) units.
    public func setComputeUnits(_ requestedUnits: MLComputeUnits) {
        let units = effectiveComputeUnits(for: requestedUnits)
        if currentComputeUnits != units {
            let previous = currentComputeUnits
            currentComputeUnits = units
            Diagnostics.shared.record(
                category: .model,
                level: .notice,
                code: "model.compute_policy",
                message: "requested compute policy changed",
                fields: [
                    "previous": Self.describeComputeUnits(previous),
                    "requested": Self.describeComputeUnits(units)
                ]
            )
            loadedModels.removeAll()
        }
    }

    /// Convenience wrapper mapping the foreground/background execution policy to `MLComputeUnits`.
    public func setExecutionTier(_ tier: ModelExecutionTier) {
        setComputeUnits(tier.computeUnits)
    }

    public func currentUnits() -> MLComputeUnits {
        currentComputeUnits
    }

    /// Requested CoreML policy as text. Never presented as proof of ANE/GPU placement.
    public func currentComputeUnitsDescription() -> String {
        Self.describeComputeUnits(currentComputeUnits)
    }

    /// Releases all loaded `MLModel` instances to free model memory before Stage 4 Export.
    public func unloadAllModels(correlationID: UUID? = nil) {
        if !loadedModels.isEmpty {
            Diagnostics.shared.record(
                category: .model,
                level: .info,
                code: "model.unload",
                message: "models unloaded",
                fields: [
                    "modelCount": "\(loadedModels.count)",
                    "requestedCompute": Self.describeComputeUnits(currentComputeUnits),
                    "correlationID": correlationID?.uuidString ?? "unattributed"
                ]
            )
        }
        loadedModels.removeAll()
        firstPredictionRecorded.removeAll()
    }

    /// The (deduplicated) directories searched for `*.mlmodelc` / `*.mlpackage` bundles.
    /// Exposed for diagnostics; guaranteed to include `customSearchDirectories` in order.
    public func modelSearchDirectories() -> [URL] {
        searchDirectories
    }

    /// Resolves every canonical production model without loading or predicting it.
    ///
    /// This is used by the app's production-model readiness checks and by the trained-model tests.
    /// It never substitutes the deterministic CI resampler; missing identifiers are simply absent
    /// from the returned dictionary and become actionable `ScalerError.modelNotFound` failures when
    /// the caller tries to predict with them.
    public func discoveredProductionModelURLs() -> [CoreMLModelIdentifier: URL] {
        var result: [CoreMLModelIdentifier: URL] = [:]
        for identifier in CoreMLModelIdentifier.allCases {
            if let url = locateModelBundle(for: identifier) {
                result[identifier] = url
            }
        }
        return result
    }

    /// Runs a planar `[1, 3, H, W]` Float16 input tensor through the specified model and returns
    /// the contiguous planar `[1, 3, outH, outW]` Float16 output array.
    ///
    /// Behaviour when no model bundle can be found on disk is controlled by `availabilityPolicy`:
    ///
    /// - `.allowDeterministicFallback` (ci/test): uses a deterministic, CPU-only Lanczos-3-style
    ///   fallback so tiled CI runs always produce sane output. This is the explicit test/CI behaviour.
    /// - `.requireProductionModels`: throws `ScalerError.modelNotFound` naming the model and every
    ///   searched directory. No Lanczos/identity result is substituted.
    ///
    /// Real inference failures (unreadable compiled models, prediction errors, malformed tensors, and —
    /// under `.requireProductionModels` — an output tensor whose spatial size disagrees with the
    /// contract) throw `ScalerError.modelInferenceFailed`.
    public func predict(
        modelID: CoreMLModelIdentifier,
        inputPlanarFP16: [Float16],
        inputHeight: Int,
        inputWidth: Int,
        outputHeight: Int,
        outputWidth: Int,
        tileIndex: Int,
        correlationID: UUID? = nil,
        stageHandler: (@Sendable (CoreMLPredictionStage) -> Void)? = nil
    ) async throws -> [Float16] {
        guard let expectedElementCount = Self.planarElementCount(height: inputHeight, width: inputWidth),
              Self.planarElementCount(height: outputHeight, width: outputWidth) != nil,
              inputPlanarFP16.count == expectedElementCount else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Malformed tensor dimensions or element count for [1, 3, \(inputHeight), \(inputWidth)]: got \(inputPlanarFP16.count) Float16 elements."
            )
        }

        if availabilityPolicy == .requireProductionModels,
           !inputPlanarFP16.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) {
            throw ScalerError.modelInferenceFailed(modelName: modelID.rawValue, tileIndex: tileIndex,
                reason: "Production input must contain finite transfer-encoded samples in [0,1].")
        }
        let modelURL: URL
        let discoveryStart = DispatchTime.now().uptimeNanoseconds
        let wasLoaded = loadedModels[modelID] != nil
        do {
            modelURL = try compiledModelURL(for: modelID, tileIndex: tileIndex)
        } catch let error as ScalerError {
            guard case .modelNotFound = error else { throw error }
            switch availabilityPolicy {
            case .allowDeterministicFallback:
                return try Self.deterministicFallbackResample(
                    inputPlanarFP16,
                    inputHeight: inputHeight,
                    inputWidth: inputWidth,
                    outputHeight: outputHeight,
                    outputWidth: outputWidth,
                    modelName: modelID.rawValue,
                    tileIndex: tileIndex
                )
            case .requireProductionModels:
                throw Self.missingProductionModelError(
                    modelID: modelID,
                    searchDirectories: searchDirectories
                )
            }
        } catch {
            throw error
        }

        if !wasLoaded {
            let discoverySeconds = Double(DispatchTime.now().uptimeNanoseconds &- discoveryStart) / 1_000_000_000.0
            Diagnostics.shared.record(
                category: .model,
                level: .notice,
                code: "model.discovery",
                message: "model resolved",
                fields: [
                    "model": modelID.rawValue,
                    "seconds": String(format: "%.3f", discoverySeconds),
                    "requestedCompute": Self.describeComputeUnits(currentComputeUnits),
                    "correlationID": correlationID?.uuidString ?? "unattributed"
                ]
            )
        }

        let loadStart = DispatchTime.now().uptimeNanoseconds
        if !wasLoaded {
            stageHandler?(.loadingModel)
            Diagnostics.shared.record(category: .model, level: .notice,
                code: "model.load.started", message: "loading and specializing model for this device",
                fields: ["model": modelID.rawValue, "requestedCompute": Self.describeComputeUnits(currentComputeUnits),
                         "correlationID": correlationID?.uuidString ?? "unattributed",
                         "availableMemoryMiB": "\(HardwareTelemetry.currentAvailableMemoryBytes() / 1_048_576)"])
        }
        let model = try loadModel(at: modelURL, modelID: modelID, tileIndex: tileIndex)
        let loadSeconds = Double(DispatchTime.now().uptimeNanoseconds &- loadStart) / 1_000_000_000.0
        if !wasLoaded {
            Diagnostics.shared.record(category: .model, level: .notice,
                code: "model.load.finished", message: "model ready",
                fields: ["model": modelID.rawValue, "seconds": String(format: "%.3f", loadSeconds),
                         "correlationID": correlationID?.uuidString ?? "unattributed"])
        }
        stageHandler?(.predicting)
        if !firstPredictionRecorded.contains(modelID) {
            Diagnostics.shared.record(category: .model, level: .notice,
                code: "model.prediction.started", message: "first prediction; may include graph warmup",
                fields: ["model": modelID.rawValue, "correlationID": correlationID?.uuidString ?? "unattributed"])
        }
        let predictionStart = DispatchTime.now().uptimeNanoseconds
        let prediction = try runPrediction(
            model: model,
            modelID: modelID,
            inputPlanarFP16: inputPlanarFP16,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            outputHeight: outputHeight,
            outputWidth: outputWidth,
            tileIndex: tileIndex
        )
        let predictionSeconds = Double(DispatchTime.now().uptimeNanoseconds &- predictionStart) / 1_000_000_000.0
        if !firstPredictionRecorded.contains(modelID) {
            firstPredictionRecorded.insert(modelID)
            // The first call includes any CoreML graph warmup; later tiles are measured separately
            // by the executor. Keep load and first-prediction times distinct so a slow first tile is
            // not mislabeled as a model failure.
            Diagnostics.shared.record(
                category: .model,
                level: .notice,
                code: "model.first_prediction",
                message: "first prediction",
                fields: [
                    "model": modelID.rawValue,
                    "loadSeconds": String(format: "%.3f", loadSeconds),
                    "firstPredictionSeconds": String(format: "%.3f", predictionSeconds),
                    "requestedCompute": Self.describeComputeUnits(currentComputeUnits),
                    "correlationID": correlationID?.uuidString ?? "unattributed"
                ]
            )
        }
        return prediction
    }

    private static func describeComputeUnits(_ units: MLComputeUnits) -> String {
        switch units {
        case .all: return "all (CPU+GPU+ANE requested)"
        case .cpuAndGPU: return "cpuAndGPU requested"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine requested"
        case .cpuOnly: return "cpuOnly"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Model discovery / compilation

    private func compiledModelURL(for modelID: CoreMLModelIdentifier, tileIndex: Int) throws -> URL {
        if let cached = compiledURLCache[modelID] {
            return cached
        }
        guard let bundleURL = locateModelBundle(for: modelID) else {
            throw ScalerError.modelNotFound(modelName: modelID.rawValue)
        }

        if bundleURL.pathExtension.lowercased() == "mlmodelc" {
            compiledURLCache[modelID] = bundleURL
            return bundleURL
        }

        do {
            let compiledURL = try MLModel.compileModel(at: bundleURL)
            compiledURLCache[modelID] = compiledURL
            return compiledURL
        } catch {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Failed to compile .mlpackage at \(bundleURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func loadModel(
        at compiledURL: URL,
        modelID: CoreMLModelIdentifier,
        tileIndex: Int
    ) throws -> MLModel {
        if let alreadyLoaded = loadedModels[modelID] {
            return alreadyLoaded
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = currentComputeUnits
        do {
            let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            loadedModels[modelID] = model
            return model
        } catch {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Failed to load compiled CoreML model: \(error.localizedDescription)"
            )
        }
    }

    private func locateModelBundle(for modelID: CoreMLModelIdentifier) -> URL? {
        if let cached = discoveredModelURLs[modelID] {
            return cached
        }
        let candidates = [
            "\(modelID.rawValue).mlmodelc",
            "\(modelID.rawValue).mlpackage"
        ]
        let fileManager = FileManager.default
        for directory in searchDirectories {
            for candidateName in candidates {
                let direct = directory.appendingPathComponent(candidateName, isDirectory: true)
                if fileManager.fileExists(atPath: direct.path) {
                    discoveredModelURLs[modelID] = direct
                    return direct
                }
                // One additional level (e.g. `Resources/Models/<name>.mlpackage`).
                if let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for child in children {
                        let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        guard isDirectory else { continue }
                        let nested = child.appendingPathComponent(candidateName, isDirectory: true)
                        if fileManager.fileExists(atPath: nested.path) {
                            discoveredModelURLs[modelID] = nested
                            return nested
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func makeSearchDirectories(extra: [URL]) -> [URL] {
        var directories: [URL] = []
        directories.append(contentsOf: extra)

        // In XCTest, the repository's production model directory is deliberately excluded from the
        // *implicit* search path. Existing CI/unit tests feed tiny synthetic tensors through the
        // explicit deterministic policy; silently loading a trained model there would change
        // their semantics and make the suite depend on machine-specific assets. Trained-model tests
        // opt in by passing the production directory through `customSearchDirectories` and asserting
        // real predictions under `.requireProductionModels`. The app (no XCTestCase class) always
        // uses the repository/app-bundle locations below.
        let isXCTestProcess = NSClassFromString("XCTestCase") != nil
        if !isXCTestProcess {
            // Repository locations derived from this source file (#filePath) and the current directory.
            let sourceFileURL = URL(fileURLWithPath: #filePath)
            var repositoryRoot = sourceFileURL.deletingLastPathComponent() // .../Sources/TiledInferenceEngine
            repositoryRoot.deleteLastPathComponent()                       // .../Sources
            repositoryRoot.deleteLastPathComponent()                       // repository root
            directories.append(repositoryRoot.appendingPathComponent("Targets/TruongScalerApp/Models", isDirectory: true))
            directories.append(repositoryRoot.appendingPathComponent("Sources/TiledInferenceEngine/Resources", isDirectory: true))
            directories.append(repositoryRoot.appendingPathComponent("Sources/TiledInferenceEngine/Models", isDirectory: true))
            directories.append(repositoryRoot.appendingPathComponent("Models", isDirectory: true))

            var workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            for _ in 0..<5 {
                directories.append(workingDirectory.appendingPathComponent("Targets/TruongScalerApp/Models", isDirectory: true))
                directories.append(workingDirectory.appendingPathComponent("Models", isDirectory: true))
                workingDirectory.deleteLastPathComponent()
            }
        }

        // App/test bundle locations. `Bundle.module` is unavailable (no resources declared for this target),
        // so probe the standard bundle roots and the SwiftPM resource-bundle directory name explicitly.
        var bundles: [Bundle] = [Bundle.main]
        bundles.append(contentsOf: Bundle.allBundles)
        bundles.append(Bundle(for: CoreMLRegistryBundleToken.self))
        for bundle in bundles {
            let bundleRoots = [bundle.bundleURL, bundle.resourceURL, bundle.builtInPlugInsURL]
            for root in bundleRoots.compactMap({ $0 }) {
                // XcodeGen may copy folder resources flat into the app bundle or preserve a Models/
                // directory. Search both so production discovery never depends on the development
                // machine's repository layout.
                directories.append(root)
                directories.append(root.appendingPathComponent("Models", isDirectory: true))
                directories.append(root.appendingPathComponent("TruongScalerPackage_TiledInferenceEngine.bundle", isDirectory: true))
                directories.append(root.appendingPathComponent("Contents/Resources", isDirectory: true))
                directories.append(root.appendingPathComponent("Contents/Resources/Models", isDirectory: true))
                directories.append(root.appendingPathComponent("Contents/Resources/TruongScalerPackage_TiledInferenceEngine.bundle", isDirectory: true))
            }
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - Prediction

    private func runPrediction(
        model: MLModel,
        modelID: CoreMLModelIdentifier,
        inputPlanarFP16: [Float16],
        inputHeight: Int,
        inputWidth: Int,
        outputHeight: Int,
        outputWidth: Int,
        tileIndex: Int
    ) throws -> [Float16] {
        let description = model.modelDescription
        guard let inputName = Self.multiArrayFeatureName(
            in: description.inputDescriptionsByName,
            preferredNames: ["input_tile", "input", "image"]
        ) else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Model has no MLMultiArray input feature (inputs: \(description.inputDescriptionsByName.keys.sorted()))."
            )
        }
        guard let outputName = Self.multiArrayFeatureName(
            in: description.outputDescriptionsByName,
            preferredNames: ["output_tile", "output"]
        ) else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Model has no MLMultiArray output feature (outputs: \(description.outputDescriptionsByName.keys.sorted()))."
            )
        }
        if availabilityPolicy == .requireProductionModels {
            try Self.validateProductionFeatureContract(
                modelID: modelID,
                description: description,
                inputName: inputName,
                outputName: outputName,
                inputHeight: inputHeight,
                inputWidth: inputWidth,
                outputHeight: outputHeight,
                outputWidth: outputWidth,
                tileIndex: tileIndex
            )
        }

        let inputMultiArray: MLMultiArray
        do {
            inputMultiArray = try MLMultiArray(
                shape: [
                    NSNumber(value: 1),
                    NSNumber(value: 3),
                    NSNumber(value: inputHeight),
                    NSNumber(value: inputWidth)
                ],
                dataType: .float16
            )
        } catch {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Failed to allocate [1, 3, \(inputHeight), \(inputWidth)] Float16 MLMultiArray: \(error.localizedDescription)"
            )
        }

        Self.copyContiguousToMultiArray(
            inputPlanarFP16,
            into: inputMultiArray,
            channels: 3,
            height: inputHeight,
            width: inputWidth
        )

        let featureProvider: MLFeatureProvider
        do {
            featureProvider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputMultiArray)]
            )
        } catch {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Failed to build MLDictionaryFeatureProvider: \(error.localizedDescription)"
            )
        }

        let predictionOutput: MLFeatureProvider
        do {
            predictionOutput = try model.prediction(from: featureProvider)
        } catch {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "MLModel.prediction(from:) failed: \(error.localizedDescription)"
            )
        }

        guard let outputMultiArray = predictionOutput.featureValue(for: outputName)?.multiArrayValue else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Model returned no MLMultiArray output feature (outputs: \(description.outputDescriptionsByName.keys.sorted()))."
            )
        }

        let shape = outputMultiArray.shape.map { $0.intValue }
        guard shape.count == 4, shape[0] == 1, shape[1] >= 3, shape[2] > 0, shape[3] > 0 else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Unexpected CoreML output shape \(shape); expected [1, 3, H, W]."
            )
        }

        let producedHeight = shape[2]
        let producedWidth = shape[3]
        let extracted = try Self.copyMultiArrayToContiguous(
            outputMultiArray,
            channels: 3,
            height: producedHeight,
            width: producedWidth,
            modelName: modelID.rawValue,
            tileIndex: tileIndex
        )

        if producedHeight == outputHeight && producedWidth == outputWidth {
            return extracted
        }
        // Under `.requireProductionModels` an incompatible real-model output is a hard failure (no silent
        // resize). Under `.allowDeterministicFallback` (CI/test) lightweight identity/bilinear stub models
        // whose output spatial size differs are resampled deterministically up to the contract size.
        let needsResample = try Self.validateProducedSpatialSize(
            producedHeight: producedHeight,
            producedWidth: producedWidth,
            requestedHeight: outputHeight,
            requestedWidth: outputWidth,
            modelName: modelID.rawValue,
            tileIndex: tileIndex,
            policy: availabilityPolicy
        )
        guard needsResample else { return extracted }
        return try Self.deterministicFallbackResample(
            extracted,
            inputHeight: producedHeight,
            inputWidth: producedWidth,
            outputHeight: outputHeight,
            outputWidth: outputWidth,
            modelName: modelID.rawValue,
            tileIndex: tileIndex
        )
    }

    // MARK: - Availability-policy validation (pure, testable)

    /// Validates the loaded model's feature contract against the exact production request.
    ///
    /// Production must never silently accept a model whose tensor names, dimensions, or element type
    /// disagree with the pipeline. This runs before allocating/predicting an incompatible file and
    /// names the expected and actual values so the error is actionable on device.
    static func validateProductionFeatureContract(
        modelID: CoreMLModelIdentifier,
        description: MLModelDescription,
        inputName: String,
        outputName: String,
        inputHeight: Int,
        inputWidth: Int,
        outputHeight: Int,
        outputWidth: Int,
        tileIndex: Int
    ) throws {
        let expectedInput = [1, 3, inputHeight, inputWidth]
        let expectedOutput = [1, 3, outputHeight, outputWidth]
        guard let inputDescription = description.inputDescriptionsByName[inputName],
              inputDescription.type == .multiArray,
              let inputConstraint = inputDescription.multiArrayConstraint else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Production model input '\(inputName)' is not an MLMultiArray. Expected [1, 3, \(inputHeight), \(inputWidth)] Float16."
            )
        }
        let actualInput = inputConstraint.shape.map { $0.intValue }
        guard actualInput == expectedInput else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Production model input '\(inputName)' has shape \(actualInput), but the pipeline requires \(expectedInput). Regenerate the model with the canonical input_tile shape."
            )
        }
        guard inputConstraint.dataType == .float16 else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Production model input '\(inputName)' uses \(inputConstraint.dataType) instead of Float16. The registry feeds Float16 tensor interfaces only."
            )
        }
        guard let outputDescription = description.outputDescriptionsByName[outputName],
              outputDescription.type == .multiArray,
              let outputConstraint = outputDescription.multiArrayConstraint else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Production model output '\(outputName)' is not an MLMultiArray. Expected [1, 3, \(outputHeight), \(outputWidth)]."
            )
        }
        let actualOutput = outputConstraint.shape.map { $0.intValue }
        guard actualOutput == expectedOutput else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Production model output '\(outputName)' has shape \(actualOutput), but the pipeline requires \(expectedOutput). Regenerate the model with the canonical output_tile shape."
            )
        }
        guard outputConstraint.dataType == .float16 || outputConstraint.dataType == .float32 else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelID.rawValue,
                tileIndex: tileIndex,
                reason: "Production model output '\(outputName)' uses unsupported data type \(outputConstraint.dataType); expected Float16 or Float32."
            )
        }
    }

    /// Builds the actionable missing-model error used by `.requireProductionModels`.
    ///
    /// `ScalerError.modelNotFound` carries a single string, so the model identifier and the searched
    /// directories are combined here (the localized description then contains both). The deterministic
    /// resampler is never used for this path.
    static func missingProductionModelError(
        modelID: CoreMLModelIdentifier,
        searchDirectories: [URL]
    ) -> ScalerError {
        let paths = searchDirectories.map { $0.standardizedFileURL.path }
        let searched = paths.isEmpty
            ? "(the registry has no search directories)"
            : paths.joined(separator: ", ")
        let message = "\(modelID.rawValue). Install the production .mlpackage/.mlmodelc bundle in one of the searched directories: \(searched)"
        return .modelNotFound(modelName: message)
    }

    /// Validates a real model's produced output spatial size against the requested pipeline contract.
    ///
    /// - Returns: `true` when the deterministic CI fallback may resample the produced tensor to the
    ///   requested size (only under `.allowDeterministicFallback`), `false` when the sizes already match.
    /// - Throws: `ScalerError.modelInferenceFailed` under `.requireProductionModels` when the real model
    ///   produced a different spatial size. This path never resizes unexpected production output.
    static func validateProducedSpatialSize(
        producedHeight: Int,
        producedWidth: Int,
        requestedHeight: Int,
        requestedWidth: Int,
        modelName: String,
        tileIndex: Int,
        policy: ModelAvailabilityPolicy
    ) throws -> Bool {
        if producedHeight == requestedHeight && producedWidth == requestedWidth {
            return false
        }
        switch policy {
        case .allowDeterministicFallback:
            return true
        case .requireProductionModels:
            throw ScalerError.modelInferenceFailed(
                modelName: modelName,
                tileIndex: tileIndex,
                reason: "Model produced a [1, 3, \(producedHeight), \(producedWidth)] output tensor, but the pipeline contract requires [1, 3, \(requestedHeight), \(requestedWidth)]. A production-model output with an incompatible spatial size is rejected instead of silently resized; regenerate/convert the model with an exact \(requestedHeight)x\(requestedWidth) output."
            )
        }
    }

    // MARK: - Stride-safe MLMultiArray marshaling

    /// Copies a tightly packed planar `[C, H, W]` Float16 array into an `MLMultiArray` whose
    /// channel/row strides may be padded (ANE commonly aligns rows/channels to 64 bytes).
    static func copyContiguousToMultiArray(
        _ contiguous: [Float16],
        into multiArray: MLMultiArray,
        channels: Int,
        height: Int,
        width: Int
    ) {
        let strides = multiArray.strides.map { $0.intValue }
        guard strides.count == 4, contiguous.count >= channels * height * width else { return }
        let strideC = strides[1]
        let strideY = strides[2]
        let strideX = strides[3]
        let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
        contiguous.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for c in 0..<channels {
                let sourceChannelOffset = c * height * width
                let destinationChannelOffset = c * strideC
                for y in 0..<height {
                    let sourceRowOffset = sourceChannelOffset + y * width
                    let destinationRowOffset = destinationChannelOffset + y * strideY
                    if strideX == 1 {
                        pointer.advanced(by: destinationRowOffset)
                            .update(from: base.advanced(by: sourceRowOffset), count: width)
                    } else {
                        for x in 0..<width {
                            pointer[destinationRowOffset + x * strideX] = base[sourceRowOffset + x]
                        }
                    }
                }
            }
        }
    }

    /// Extracts the first `channels` planes of an `MLMultiArray` `[1, C, H, W]` tensor into a tightly
    /// packed planar Float16 array, honoring arbitrary channel/row/element strides and float dtypes.
    static func copyMultiArrayToContiguous(
        _ multiArray: MLMultiArray,
        channels: Int,
        height: Int,
        width: Int,
        modelName: String,
        tileIndex: Int
    ) throws -> [Float16] {
        let strides = multiArray.strides.map { $0.intValue }
        guard strides.count == 4 else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelName,
                tileIndex: tileIndex,
                reason: "Unexpected MLMultiArray stride count \(strides.count); expected 4."
            )
        }
        let strideC = strides[1]
        let strideY = strides[2]
        let strideX = strides[3]
        var result = [Float16](repeating: 0, count: channels * height * width)

        switch multiArray.dataType {
        case .float16:
            let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
            for c in 0..<channels {
                let destinationChannelOffset = c * height * width
                let sourceChannelOffset = c * strideC
                for y in 0..<height {
                    let destinationRowOffset = destinationChannelOffset + y * width
                    let sourceRowOffset = sourceChannelOffset + y * strideY
                    if strideX == 1 {
                        result.withUnsafeMutableBufferPointer { destination in
                            destination.baseAddress!.advanced(by: destinationRowOffset)
                                .update(from: pointer.advanced(by: sourceRowOffset), count: width)
                        }
                    } else {
                        for x in 0..<width {
                            result[destinationRowOffset + x] = pointer[sourceRowOffset + x * strideX]
                        }
                    }
                }
            }
        case .float32:
            let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float32.self)
            for c in 0..<channels {
                let destinationChannelOffset = c * height * width
                let sourceChannelOffset = c * strideC
                for y in 0..<height {
                    let destinationRowOffset = destinationChannelOffset + y * width
                    let sourceRowOffset = sourceChannelOffset + y * strideY
                    for x in 0..<width {
                        result[destinationRowOffset + x] = Float16(pointer[sourceRowOffset + x * strideX])
                    }
                }
            }
        case .double:
            let pointer = multiArray.dataPointer.assumingMemoryBound(to: Double.self)
            for c in 0..<channels {
                let destinationChannelOffset = c * height * width
                let sourceChannelOffset = c * strideC
                for y in 0..<height {
                    let destinationRowOffset = destinationChannelOffset + y * width
                    let sourceRowOffset = sourceChannelOffset + y * strideY
                    for x in 0..<width {
                        result[destinationRowOffset + x] = Float16(pointer[sourceRowOffset + x * strideX])
                    }
                }
            }
        default:
            throw ScalerError.modelInferenceFailed(
                modelName: modelName,
                tileIndex: tileIndex,
                reason: "Unsupported CoreML output data type \(multiArray.dataType.rawValue); expected Float16/Float32/Double."
            )
        }
        guard result.allSatisfy(\.isFinite) else {
            throw ScalerError.modelInferenceFailed(modelName: modelName, tileIndex: tileIndex,
                reason: "Model returned a non-finite or unrepresentable prediction; refusing tile commit.")
        }
        return result
    }

    private static func multiArrayFeatureName(
        in descriptions: [String: MLFeatureDescription],
        preferredNames: [String]
    ) -> String? {
        for name in preferredNames {
            if let description = descriptions[name], description.type == .multiArray {
                return name
            }
        }
        return descriptions.keys.sorted().first { descriptions[$0]?.type == .multiArray }
    }

    // MARK: - Deterministic CPU fallback (Lanczos-3 separable resampling)

    private struct ResampleTap: Sendable {
        let index: Int
        let weight: Float
    }

    /// Deterministic, thread-safe, CPU-only Lanczos-3 separable resampler used whenever no model
    /// bundle is available on disk. It maps the contiguous planar `[3, inH, inW]` Float16 input to a
    /// contiguous planar `[3, outH, outW]` Float16 output, matching the CoreML tensor contract.
    /// Equal input/output dimensions reduce to a sanitized identity copy (denoiser fallback).
    static func deterministicFallbackResample(
        _ inputPlanarFP16: [Float16],
        inputHeight: Int,
        inputWidth: Int,
        outputHeight: Int,
        outputWidth: Int,
        modelName: String,
        tileIndex: Int
    ) throws -> [Float16] {
        guard let inputCount = Self.planarElementCount(height: inputHeight, width: inputWidth),
              let outputCount = Self.planarElementCount(height: outputHeight, width: outputWidth),
              inputPlanarFP16.count == inputCount else {
            throw ScalerError.modelInferenceFailed(
                modelName: modelName,
                tileIndex: tileIndex,
                reason: "Fallback resampler received malformed tensor dimensions or element count (\(inputPlanarFP16.count))."
            )
        }

        let inputPlaneSize = inputCount / 3
        let outputPlaneSize = outputHeight * outputWidth
        var output = [Float16](repeating: 0, count: outputCount)

        if inputHeight == outputHeight && inputWidth == outputWidth {
            for index in 0..<output.count {
                output[index] = Self.sanitizedFloat16(Float(inputPlanarFP16[index]))
            }
            return output
        }

        let horizontalTaps = Self.makeResampleTaps(inputLength: inputWidth, outputLength: outputWidth)
        let verticalTaps = Self.makeResampleTaps(inputLength: inputHeight, outputLength: outputHeight)
        var horizontallyResampled = [Float](repeating: 0, count: inputHeight * outputWidth)

        for channel in 0..<3 {
            let sourceChannelOffset = channel * inputPlaneSize
            for y in 0..<inputHeight {
                let sourceRowOffset = sourceChannelOffset + y * inputWidth
                let destinationRowOffset = y * outputWidth
                for outX in 0..<outputWidth {
                    let taps = horizontalTaps[outX]
                    var accumulator: Float = 0
                    for tap in taps {
                        accumulator += tap.weight * Float(inputPlanarFP16[sourceRowOffset + tap.index])
                    }
                    horizontallyResampled[destinationRowOffset + outX] = accumulator
                }
            }

            let destinationChannelOffset = channel * outputPlaneSize
            for outY in 0..<outputHeight {
                let taps = verticalTaps[outY]
                let destinationRowOffset = destinationChannelOffset + outY * outputWidth
                for outX in 0..<outputWidth {
                    var accumulator: Float = 0
                    for tap in taps {
                        accumulator += tap.weight * horizontallyResampled[tap.index * outputWidth + outX]
                    }
                    output[destinationRowOffset + outX] = Self.sanitizedFloat16(accumulator)
                }
            }
        }
        return output
    }

    /// Builds normalized, edge-clamped 6-tap Lanczos-3 weights for pixel-center-aligned resampling.
    private static func makeResampleTaps(inputLength: Int, outputLength: Int) -> [[ResampleTap]] {
        guard inputLength > 0, outputLength > 0 else { return [] }
        let scale = Float(inputLength) / Float(outputLength)
        var allTaps: [[ResampleTap]] = []
        allTaps.reserveCapacity(outputLength)
        let lastInputIndex = inputLength - 1

        for outputIndex in 0..<outputLength {
            let center = (Float(outputIndex) + 0.5) * scale - 0.5
            let baseIndex = Int(floorf(center))
            var taps: [ResampleTap] = []
            taps.reserveCapacity(6)
            var weightSum: Float = 0
            for offset in -2...3 {
                let sourceIndex = baseIndex + offset
                let weight = lanczos3(center - Float(sourceIndex))
                guard weight != 0 else { continue }
                let clampedIndex = min(max(sourceIndex, 0), lastInputIndex)
                taps.append(ResampleTap(index: clampedIndex, weight: weight))
                weightSum += weight
            }
            if weightSum == 0 || !weightSum.isFinite {
                let clampedIndex = min(max(Int(center.rounded()), 0), lastInputIndex)
                taps = [ResampleTap(index: clampedIndex, weight: 1.0)]
            } else {
                taps = taps.map { ResampleTap(index: $0.index, weight: $0.weight / weightSum) }
            }
            allTaps.append(taps)
        }
        return allTaps
    }

    private static func lanczos3(_ t: Float) -> Float {
        let x = abs(t)
        if x < 1e-6 { return 1.0 }
        if x >= 3.0 { return 0.0 }
        let piX = Float.pi * x
        return (sinf(piX) / piX) * (sinf(piX / 3.0) / (piX / 3.0))
    }

    @inline(__always)
    private static func planarElementCount(height: Int, width: Int) -> Int? {
        guard height > 0, width > 0, height <= Int.max / width else { return nil }
        let plane = height * width
        guard plane <= Int.max / (3 * MemoryLayout<Float16>.stride) else { return nil }
        return plane * 3
    }

    @inline(__always)
    private static func sanitizedFloat16(_ value: Float) -> Float16 {
        guard value.isFinite else { return 0 }
        return Float16(min(max(value, -65504.0), 65504.0))
    }
}
