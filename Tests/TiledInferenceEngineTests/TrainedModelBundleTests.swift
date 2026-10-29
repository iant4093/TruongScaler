import XCTest
import Foundation
import CoreML
import CryptoKit
@testable import TiledInferenceEngine
@testable import TruongScalerCore

/// Trained-production-model integration coverage.
///
/// These tests deliberately load the assets under `Targets/TruongScalerApp/Models`, opt into
/// `.requireProductionModels`, and run real predictions. The repository path is passed explicitly
/// through `customSearchDirectories` because the registry excludes implicit repository discovery
/// inside XCTest (small synthetic unit tests must not accidentally load a production model).
final class TrainedModelBundleTests: XCTestCase {
    private struct CheckpointEntry: Decodable {
        let file: String
        let sha256: String
        let repo: String
        let revision: String
        let license: String
    }

    private struct ModelEntry: Decodable {
        let identifier: String
        let asset: String
        let inputShape: [Int]
        let outputShape: [Int]
        let inputTensorName: String
        let outputTensorName: String
        let inputDataType: String
        let outputDataType: String
        let computePrecision: String
        let assetDirectorySHA256: String
        let weightBinSHA256: String?
        let checkpoint: String
        let checkpointSHA256: String
        let upstreamRepo: String
        let upstreamRevision: String
        let license: String
        let productionRawPredictionRange: [Float]?
    }

    private struct Inventory: Decodable {
        let schemaVersion: Int
        let canonicalModelCount: Int
        let models: [ModelEntry]
        let checkpoints: [String: CheckpointEntry]
    }

    private struct HATSourceManifest: Decodable {
        struct File: Decodable {
            let path: String
            let sha256: String
            let bytes: Int
        }
        let repository: String
        let revision: String
        let basicSRTag: String
        let files: [File]
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TiledInferenceEngineTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    private static var modelsDirectory: URL {
        repositoryRoot.appendingPathComponent("Targets/TruongScalerApp/Models", isDirectory: true)
    }

    private func loadInventory() throws -> Inventory {
        let url = Self.modelsDirectory.appendingPathComponent("Provenance/model-inventory.json")
        return try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: url))
    }

    // MARK: - Inventory / discovery / hashes

    func testCanonicalInventoryMatchesAllSixIdentifiersAndNotices() throws {
        let inventory = try loadInventory()
        XCTAssertEqual(inventory.schemaVersion, 2)
        XCTAssertEqual(inventory.canonicalModelCount, 6)
        XCTAssertEqual(inventory.models.count, 6)
        XCTAssertEqual(
            Set(inventory.models.map(\.identifier)),
            Set(CoreMLModelIdentifier.allCases.map(\.rawValue))
        )

        for entry in inventory.models {
            let assetURL = Self.modelsDirectory.appendingPathComponent(entry.asset, isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: assetURL.path, isDirectory: &isDirectory),
                "Missing production asset \(entry.asset)"
            )
            XCTAssertTrue(isDirectory.boolValue, "\(entry.asset) must be a compiled model directory")
            XCTAssertTrue(entry.asset.hasSuffix(".mlmodelc"))
            XCTAssertEqual(entry.inputDataType, "Float16")
            XCTAssertEqual(entry.outputDataType, "Float16")
            XCTAssertFalse(entry.computePrecision.isEmpty)
            XCTAssertEqual(entry.computePrecision, entry.identifier.hasPrefix("QuickSRNet_") ? "FLOAT16" : "FLOAT32")
            XCTAssertEqual(entry.checkpointSHA256.count, 64)
            XCTAssertEqual(entry.assetDirectorySHA256.count, 64)
            XCTAssertFalse(entry.upstreamRepo.isEmpty)
            XCTAssertEqual(entry.upstreamRevision.count, 40)
            XCTAssertFalse(entry.license.isEmpty)
            XCTAssertNotNil(inventory.checkpoints[entry.checkpoint])
            XCTAssertEqual(inventory.checkpoints[entry.checkpoint]?.sha256, entry.checkpointSHA256)
            XCTAssertEqual(inventory.checkpoints[entry.checkpoint]?.repo, entry.upstreamRepo)
            XCTAssertEqual(inventory.checkpoints[entry.checkpoint]?.revision, entry.upstreamRevision)
        }

        for notice in ["QuickSRNet-LICENSE.txt", "EDSR-LICENSE.txt", "HAT-S-LICENSE.txt", "HAT-S-BasicSR-LICENSE.txt", "HAT-S-timm-LICENSE.txt"] {
            let url = Self.modelsDirectory.appendingPathComponent("Notices/\(notice)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing notice \(notice)")
            XCTAssertGreaterThan((try? Data(contentsOf: url).count) ?? 0, 100)
        }
        let provenanceURL = Self.modelsDirectory.appendingPathComponent("Provenance/checkpoint-sha256.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        let readmeURL = Self.modelsDirectory.appendingPathComponent("README-MODELS.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readmeURL.path))
    }

    func testHATPinsTheOfficialCheckpointAndCompleteArchitectureSupportManifest() throws {
        let inventory = try loadInventory()
        let checkpoint = try XCTUnwrap(inventory.checkpoints["hat-s-2x"])
        let expectedHash = "3e249a901c2aed6b82548875e21847ef6c015a40c814237a7a0abb10c69d5ddf"
        let revision = "1638a9a822581657811867bf670717f8371fc3e5"
        XCTAssertEqual(checkpoint.file, "HAT-S_SRx2.pth")
        XCTAssertEqual(checkpoint.sha256, expectedHash)
        XCTAssertEqual(checkpoint.repo, "https://github.com/XPixelGroup/HAT")
        XCTAssertEqual(checkpoint.revision, revision)
        let checkpointURL = Self.repositoryRoot.appendingPathComponent("ModelConversionTools/checkpoints/" + checkpoint.file)
        XCTAssertEqual(try Self.fileDigest(checkpointURL), expectedHash)
        let hatRows = inventory.models.filter { $0.identifier.hasPrefix("HAT_S_") }
        XCTAssertEqual(Set(hatRows.map(\.identifier)), ["HAT_S_x2_192", "HAT_S_x2_256"])
        for row in hatRows {
            XCTAssertEqual(row.computePrecision, "FLOAT32")
            XCTAssertEqual(row.productionRawPredictionRange, [-0.25, 1.25])
        }

        let manifestURL = Self.modelsDirectory.appendingPathComponent("Provenance/hat-source-manifest.json")
        let vendor = Self.repositoryRoot.appendingPathComponent("ModelConversionTools/vendor/hat", isDirectory: true)
        let manifestBytes = try Data(contentsOf: manifestURL)
        XCTAssertEqual(manifestBytes, try Data(contentsOf: vendor.appendingPathComponent("source-manifest.json")))
        let manifest = try JSONDecoder().decode(HATSourceManifest.self, from: manifestBytes)
        XCTAssertEqual(manifest.repository, "https://github.com/XPixelGroup/HAT")
        XCTAssertEqual(manifest.revision, revision)
        XCTAssertEqual(manifest.basicSRTag, "v1.3.4.9")
        let expectedFiles = ["HAT-S_SRx2.yml", "LICENSE", "hat_arch.py", "basicsr/LICENSE",
            "basicsr/LICENSE_pytorch-image-models", "basicsr/arch_util.py", "basicsr/registry.py"]
        XCTAssertEqual(Set(manifest.files.map(\.path)), Set(expectedFiles.map { "ModelConversionTools/vendor/hat/" + $0 }))
        XCTAssertEqual(manifest.files.count, expectedFiles.count)
        for file in manifest.files {
            let url = Self.repositoryRoot.appendingPathComponent(file.path).resolvingSymlinksInPath()
            XCTAssertTrue(url.path.hasPrefix(vendor.resolvingSymlinksInPath().path + "/"))
            XCTAssertEqual(try Self.fileDigest(url), file.sha256, file.path)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            XCTAssertEqual(size?.intValue, file.bytes, file.path)
        }
        for (notice, source) in [("HAT-S-LICENSE.txt", "LICENSE"), ("HAT-S-BasicSR-LICENSE.txt", "basicsr/LICENSE"),
                                 ("HAT-S-timm-LICENSE.txt", "basicsr/LICENSE_pytorch-image-models")] {
            XCTAssertEqual(try Self.fileDigest(Self.modelsDirectory.appendingPathComponent("Notices/" + notice)),
                           try Self.fileDigest(vendor.appendingPathComponent(source)))
        }
    }

    func testAllAssetDirectoryDigestsAndWeightsMatchInventory() throws {
        let inventory = try loadInventory()
        for entry in inventory.models {
            let assetURL = Self.modelsDirectory.appendingPathComponent(entry.asset, isDirectory: true)
            XCTAssertEqual(
                try Self.directoryDigest(assetURL),
                entry.assetDirectorySHA256,
                "Directory digest drift for \(entry.identifier)"
            )
            if let expectedWeightHash = entry.weightBinSHA256 {
                let weightURL = assetURL.appendingPathComponent("weights/weight.bin")
                XCTAssertTrue(FileManager.default.fileExists(atPath: weightURL.path))
                XCTAssertEqual(try Self.fileDigest(weightURL), expectedWeightHash)
            }
        }
    }

    // MARK: - Exact loaded model contract

    func testAllProductionModelsHaveExactFloat16TensorContract() throws {
        let inventory = try loadInventory()
        for entry in inventory.models {
            let assetURL = Self.modelsDirectory.appendingPathComponent(entry.asset, isDirectory: true)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: assetURL, configuration: configuration)
            let description = model.modelDescription

            guard let input = description.inputDescriptionsByName[entry.inputTensorName],
                  let inputConstraint = input.multiArrayConstraint else {
                XCTFail("\(entry.identifier) has no \(entry.inputTensorName) MLMultiArray input")
                continue
            }
            XCTAssertEqual(inputConstraint.shape.map(\.intValue), entry.inputShape, entry.identifier)
            XCTAssertEqual(inputConstraint.dataType, .float16, entry.identifier)

            guard let output = description.outputDescriptionsByName[entry.outputTensorName],
                  let outputConstraint = output.multiArrayConstraint else {
                XCTFail("\(entry.identifier) has no \(entry.outputTensorName) MLMultiArray output")
                continue
            }
            XCTAssertEqual(outputConstraint.shape.map(\.intValue), entry.outputShape, entry.identifier)
            XCTAssertEqual(outputConstraint.dataType, .float16, entry.identifier)
        }
    }

    // MARK: - Real model-required predictions

    func testAllProductionModelsPerformNonconstantRealPrediction() async throws {
        let inventory = try loadInventory()
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuAndGPU,
            customSearchDirectories: [Self.modelsDirectory],
            availabilityPolicy: .requireProductionModels
        )
        let discovered = await registry.discoveredProductionModelURLs()
        XCTAssertEqual(discovered.count, 6, "Production discovery did not resolve all trained assets")

        for entry in inventory.models {
            guard let identifier = CoreMLModelIdentifier(rawValue: entry.identifier) else {
                XCTFail("Unknown inventory identifier \(entry.identifier)")
                continue
            }
            let inputHeight = entry.inputShape[2]
            let inputWidth = entry.inputShape[3]
            let input = Self.deterministicInput(width: inputWidth, height: inputHeight)
            let started = Date()
            let output = try await registry.predict(
                modelID: identifier,
                inputPlanarFP16: input,
                inputHeight: inputHeight,
                inputWidth: inputWidth,
                outputHeight: entry.outputShape[2],
                outputWidth: entry.outputShape[3],
                tileIndex: 0
            )
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertEqual(output.count, 3 * entry.outputShape[2] * entry.outputShape[3], entry.identifier)
            XCTAssertTrue(output.allSatisfy(\.isFinite), "\(entry.identifier) produced a non-finite value")
            let floats = output.map(Float.init)
            let minimum = floats.min() ?? 0
            let maximum = floats.max() ?? 0
            let mean = floats.reduce(0, +) / Float(floats.count)
            let variance = floats.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(floats.count)
            XCTAssertGreaterThan(maximum - minimum, 1e-5, "\(entry.identifier) output is constant")
            XCTAssertGreaterThan(variance, 1e-10, "\(entry.identifier) output has no content")
            XCTAssertLessThan(elapsed, 300, "\(entry.identifier) prediction exceeded the local 300 s guard")

            // A real SR/denoise model must not be an identity or nearest-neighbour stub. Compare a
            // sample near the center with the corresponding input pixel.
            let sampleX = entry.outputShape[3] / 2
            let sampleY = entry.outputShape[2] / 2
            let sourceX = min(inputWidth - 1, sampleX * inputWidth / entry.outputShape[3])
            let sourceY = min(inputHeight - 1, sampleY * inputHeight / entry.outputShape[2])
            let sourcePlane = inputWidth * inputHeight
            let sourceR = Float(input[sourceY * inputWidth + sourceX])
            let sourceG = Float(input[sourcePlane + sourceY * inputWidth + sourceX])
            let sourceB = Float(input[2 * sourcePlane + sourceY * inputWidth + sourceX])
            let outputPlane = entry.outputShape[2] * entry.outputShape[3]
            let outR = Float(output[sampleY * entry.outputShape[3] + sampleX])
            let outG = Float(output[outputPlane + sampleY * entry.outputShape[3] + sampleX])
            let outB = Float(output[2 * outputPlane + sampleY * entry.outputShape[3] + sampleX])
            XCTAssertGreaterThan(
                abs(outR - sourceR) + abs(outG - sourceG) + abs(outB - sourceB),
                1e-6,
                "\(entry.identifier) produced a pure identity/nearest output"
            )
            print("[trained-model] \(entry.identifier) real prediction: \(String(format: "%.2f", elapsed)) s, range [\(minimum), \(maximum)]")
            await registry.unloadAllModels()
        }
    }

    // MARK: - Truthful failures

    func testRequiredPolicyRejectsWrongOutputGeometryBeforeInference() async throws {
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            customSearchDirectories: [Self.modelsDirectory],
            availabilityPolicy: .requireProductionModels
        )
        let input = [Float16](repeating: 0.5, count: 3 * 192 * 192)
        do {
            _ = try await registry.predict(
                modelID: .quickSRx2_192,
                inputPlanarFP16: input,
                inputHeight: 192,
                inputWidth: 192,
                outputHeight: 191,
                outputWidth: 192,
                tileIndex: 5
            )
            XCTFail("A production model with a non-canonical output request must be rejected")
        } catch let error as ScalerError {
            guard case .modelInferenceFailed(let name, let tile, let reason) = error else {
                XCTFail("Expected modelInferenceFailed, got \(error)")
                return
            }
            XCTAssertEqual(name, "QuickSRNet_Large_x2_192")
            XCTAssertEqual(tile, 5)
            XCTAssertTrue(reason.contains("[1, 3, 191, 192]"), reason)
            XCTAssertTrue(reason.contains("requires"), reason)
        }
    }

    func testInvalidCompiledModelFailsWithActionableInferenceError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongScalerInvalidModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("QuickSRNet_Large_x2_192.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not a compiled Core ML model".utf8).write(
            to: directory.appendingPathComponent("QuickSRNet_Large_x2_192.mlmodelc/coremldata.bin")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            customSearchDirectories: [directory],
            availabilityPolicy: .requireProductionModels
        )
        let input = [Float16](repeating: 0.5, count: 3 * 192 * 192)
        do {
            _ = try await registry.predict(
                modelID: .quickSRx2_192,
                inputPlanarFP16: input,
                inputHeight: 192,
                inputWidth: 192,
                outputHeight: 192,
                outputWidth: 192,
                tileIndex: 0
            )
            XCTFail("An invalid compiled model must not produce output")
        } catch let error as ScalerError {
            guard case .modelInferenceFailed(let name, _, let reason) = error else {
                XCTFail("Expected modelInferenceFailed, got \(error)")
                return
            }
            XCTAssertEqual(name, "QuickSRNet_Large_x2_192")
            XCTAssertTrue(reason.lowercased().contains("failed to load"), reason)
        }
    }

    // MARK: - Helpers

    private static func deterministicInput(width: Int, height: Int) -> [Float16] {
        var values = [Float16](repeating: 0, count: 3 * width * height)
        let plane = width * height
        for channel in 0..<3 {
            for y in 0..<height {
                for x in 0..<width {
                    let horizontal = Float(x) / Float(max(1, width - 1))
                    let vertical = Float(y) / Float(max(1, height - 1))
                    let wave = 0.12 * sinf(0.11 * Float(x) + 0.07 * Float(y) + Float(channel))
                    let inBlockX = x > width / 3 && x < 2 * width / 3
                    let inBlockY = y > height / 4 && y < 3 * height / 4
                    let block: Float = (inBlockX && inBlockY) ? 0.18 : 0.0
                    let channelOffset = 0.04 * Float(channel)
                    var value: Float = 0.08
                    value += 0.55 * horizontal
                    value += 0.22 * vertical
                    value += wave
                    value += block
                    value += channelOffset
                    values[channel * plane + y * width + x] = Float16(min(max(value, 0), 1))
                }
            }
        }
        return values
    }

    private static func directoryDigest(_ directory: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return "" }
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            files.append((relative, url))
        }
        files.sort { $0.0 < $1.0 }
        var hasher = SHA256()
        for (relative, url) in files {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(try fileDigest(url).utf8))
            hasher.update(data: Data([0x0A]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
