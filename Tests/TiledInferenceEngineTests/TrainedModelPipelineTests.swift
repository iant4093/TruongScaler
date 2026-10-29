import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TiledInferenceEngine
@testable import TruongScalerCore
@testable import MMapCanvas
@testable import CoreIngestion
@testable import CoreExport

/// End-to-end production-model pipeline coverage: real trained Core ML assets, a licensed/project
/// synthetic fixture, the real executor, the real exporter and a real re-ingest. This is intentionally
/// separate from the deterministic model-registry tests, which use the explicit CI fallback.
final class TrainedModelPipelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongScalerTrainedPipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private static var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Targets/TruongScalerApp/Models", isDirectory: true)
    }

    func testQuickSRNetRealPipelineExportsAndReingestsNonconstantX2Artifact() async throws {
        let sourceURL = directory.appendingPathComponent("trained-pipeline-fixture.png")
        try Self.writeFixturePNG(url: sourceURL, width: 192, height: 192)

        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuAndGPU,
            customSearchDirectories: [Self.modelsDirectory],
            availabilityPolicy: .requireProductionModels
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .png16Bit
        )
        let artifacts = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )

        XCTAssertEqual(artifacts.sourceBuffer.width, 192)
        XCTAssertEqual(artifacts.outputBuffer.width, 384)
        XCTAssertEqual(artifacts.outputBuffer.height, 384)
        XCTAssertFalse(artifacts.checkpoint.didRunDenoise)
        XCTAssertEqual(artifacts.checkpoint.totalTiles, 1)
        XCTAssertGreaterThanOrEqual(artifacts.checkpoint.lastCompletedTileIndex, 0)
        Self.assertNonconstantAndFinite(artifacts.outputBuffer)

        let exportURL = directory.appendingPathComponent("trained-pipeline-x2.png")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: exportURL,
            overrideFormat: .png16Bit
        )
        XCTAssertEqual(result.actualScaleFactor, 2)
        XCTAssertEqual(result.format, .png16Bit)
        XCTAssertFalse(result.isHDR, "This synthetic SDR fixture must not be labelled HDR")
        XCTAssertGreaterThan(result.finalLinearPeak, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        let reingestURL = directory.appendingPathComponent("trained-pipeline-reingest.rgba16f.bin")
        let reingested = try UniversalStripDecoder.decodeToMMap(
            imageURL: exportURL,
            destinationMMapURL: reingestURL,
            stripHeight: 64
        )
        XCTAssertEqual(reingested.decodedWidth, 384)
        XCTAssertEqual(reingested.decodedHeight, 384)
        Self.assertNonconstantAndFinite(reingested.sourceBuffer)
    }

    func testQuickSRNetx2RealPipelineProducesTrainedX2ArtifactWithoutDenoise() async throws {
        let sourceURL = directory.appendingPathComponent("trained-quicksr-fixture.png")
        try Self.writeFixturePNG(url: sourceURL, width: 192, height: 192)

        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuAndGPU,
            customSearchDirectories: [Self.modelsDirectory],
            availabilityPolicy: .requireProductionModels
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .tiff16BitLZW
        )
        let artifacts = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertEqual(artifacts.outputBuffer.width, 384)
        XCTAssertEqual(artifacts.outputBuffer.height, 384)
        XCTAssertFalse(artifacts.checkpoint.didRunDenoise)
        XCTAssertEqual(artifacts.checkpoint.totalTiles, 1)
        Self.assertNonconstantAndFinite(artifacts.outputBuffer)

        let exportURL = directory.appendingPathComponent("trained-quicksr-x2.tiff")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: exportURL,
            overrideFormat: .tiff16BitLZW
        )
        XCTAssertEqual(result.actualScaleFactor, 2)
        XCTAssertEqual(result.format, .tiff16BitLZW)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
    }

    /// Replace the duplicate QuickSRNet TIFF smoke case with one required-model HAT-S pass.
    /// Photo quality, HDR/alpha and resumable seams have separate all-model coverage; this case
    /// checks the complete native 2× → Linear DNG → independent re-ingest/history contract.
    func testHATNativeTwoTimesPipelineExportsAndReingestsRecordedModelAndPriorHistory() async throws {
        let sourceURL = directory.appendingPathComponent("trained-hat-x2-fixture.png")
        try Self.writeFixturePNG(url: sourceURL, width: 192, height: 192)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let upstream = ImageProcessingHistory.Step(
            id: UUID(), app: "com.iantruong.truongnoiser", operation: "denoise", model: "NAFNet_w64",
            scale: 1, date: Date(timeIntervalSince1970: 1_792_962_000),
            inputWidth: 192, inputHeight: 192, outputWidth: 192, outputHeight: 192
        )
        let upstreamHistory = ImageProcessingHistory(steps: [upstream])
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .all,
            customSearchDirectories: [Self.modelsDirectory],
            availabilityPolicy: .requireProductionModels
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x2,
            backbone: .hatSmall,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .linearDNG16Bit,
            sessionState: PipelineSessionState(isDenoised: true, isDenoisedByNoiser: true,
                processingHistory: upstreamHistory)
        )
        let artifacts = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertEqual(artifacts.sourceBuffer.width, 192)
        XCTAssertEqual(artifacts.sourceBuffer.height, 192)
        XCTAssertEqual(artifacts.outputBuffer.width, 384)
        XCTAssertEqual(artifacts.outputBuffer.height, 384)
        XCTAssertEqual(artifacts.checkpoint.config.backbone, .hatSmall)
        XCTAssertEqual(artifacts.checkpoint.config.scaleFactor, .x2)
        XCTAssertEqual(artifacts.checkpoint.config.denoiseMode, .off)
        XCTAssertFalse(artifacts.checkpoint.didRunDenoise, "An inherited Noiser flag must not run another denoise stage")
        XCTAssertEqual(artifacts.checkpoint.tileConfig, TileConfiguration(tier: .tierB_ConstrainedMemory, backbone: .hatSmall))
        XCTAssertEqual(artifacts.checkpoint.tileConfig.inputOverlap, 32)
        XCTAssertEqual(artifacts.checkpoint.totalTiles, 1)
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, 0)
        Self.assertNonconstantAndFinite(artifacts.outputBuffer)
        let durable = try await store.load(jobID: config.id)
        XCTAssertEqual(durable.config.backbone, .hatSmall)
        XCTAssertEqual(durable.tileConfig, artifacts.checkpoint.tileConfig)

        let exportURL = directory.appendingPathComponent("trained-hat-x2.dng")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: exportURL,
            overrideFormat: .linearDNG16Bit
        )
        XCTAssertEqual(result.actualScaleFactor, 2)
        XCTAssertEqual(result.format, .linearDNG16Bit)
        let reingested = try UniversalStripDecoder.decodeToMMap(
            imageURL: exportURL,
            destinationMMapURL: directory.appendingPathComponent("trained-hat-reingest.rgba16f.bin"),
            stripHeight: 64
        )
        XCTAssertEqual(reingested.decodedWidth, 384)
        XCTAssertEqual(reingested.decodedHeight, 384)
        XCTAssertTrue(reingested.metadata.isLinearDNG)
        XCTAssertTrue(reingested.metadata.hasSuiteLinearDNGMarker)
        XCTAssertTrue(reingested.metadata.isAlreadyUpscaledBySuite)
        XCTAssertEqual(reingested.metadata.upscaledByAppFactor, 2)
        XCTAssertTrue(reingested.metadata.isAlreadyDenoisedBySuite)
        XCTAssertTrue(reingested.metadata.isAlreadyDenoisedByNoiser)
        let history = try XCTUnwrap(reingested.metadata.processingHistory)
        XCTAssertEqual(history.steps.count, 2, "Export/re-ingest must retain the upstream step and append one actual HAT-S step")
        XCTAssertEqual(history.steps.first, upstream)
        let step = try XCTUnwrap(history.steps.last)
        XCTAssertEqual(step.id, config.id)
        XCTAssertEqual(step.app, "com.iantruong.truongscaler")
        XCTAssertEqual(step.operation, "upscale")
        XCTAssertEqual(step.model, BackboneModelKind.hatSmall.rawValue)
        XCTAssertEqual(step.scale, 2)
        XCTAssertEqual(step.inputWidth, 192)
        XCTAssertEqual(step.inputHeight, 192)
        XCTAssertEqual(step.outputWidth, 384)
        XCTAssertEqual(step.outputHeight, 384)
        XCTAssertEqual(history, FormatAwareExporter.processedMetadata(artifacts: artifacts).processingHistory)
        Self.assertNonconstantAndFinite(reingested.sourceBuffer)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes, "A real HAT-S enlargement must leave its source bytes unchanged")
    }

    func testHDRLinearDNGFixtureThroughTrainedQuickSRNetPreservesExtendedRange() async throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/saturatedComponentPeak.dng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuAndGPU,
            customSearchDirectories: [Self.modelsDirectory],
            availabilityPolicy: .requireProductionModels
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .tiff16BitLZW
        )
        let artifacts = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertEqual(artifacts.outputBuffer.width, 128)
        XCTAssertEqual(artifacts.outputBuffer.height, 128)
        XCTAssertGreaterThanOrEqual(
            artifacts.checkpoint.globalMaxLinearComponent,
            3.9,
            "The saturated red component (4.0) must define the normalization peak"
        )
        Self.assertNonconstantAndFinite(artifacts.outputBuffer)

        let exportURL = directory.appendingPathComponent("trained-hdr-x2.tiff")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: exportURL,
            overrideFormat: .tiff16BitLZW
        )
        XCTAssertEqual(result.actualScaleFactor, 2)
        XCTAssertEqual(result.format, .tiff16BitLZW)
        let reingestURL = directory.appendingPathComponent("trained-hdr-reingest.rgba16f.bin")
        let reingested = try UniversalStripDecoder.decodeToMMap(
            imageURL: exportURL,
            destinationMMapURL: reingestURL,
            stripHeight: 64
        )
        XCTAssertEqual(reingested.decodedWidth, 128)
        XCTAssertEqual(reingested.decodedHeight, 128)
        XCTAssertGreaterThanOrEqual(
            reingested.globalMaxLinearComponent,
            3.9,
            "TIFF HDR component range was not preserved through export/re-ingest"
        )
        if result.isHDR {
            XCTAssertGreaterThan(result.finalLinearPeak, 1.0)
        }
    }

    // MARK: - Fixture / assertions

    private static func writeFixturePNG(url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Float(x) / Float(width - 1)
                let fy = Float(y) / Float(height - 1)
                let wave = 0.18 * sinf(0.13 * Float(x) + 0.07 * Float(y))
                let block = (x > width / 3 && x < 2 * width / 3 && y > height / 4 && y < 3 * height / 4)
                    ? Float(0.18) : 0
                let r = min(max(0.08 + 0.65 * fx + wave + block, 0), 1)
                let g = min(max(0.10 + 0.55 * fy + 0.5 * wave + block, 0), 1)
                let b = min(max(0.20 + 0.35 * (1 - fx) + 0.3 * wave, 0), 1)
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(r * 255)
                pixels[offset + 1] = UInt8(g * 255)
                pixels[offset + 2] = UInt8(b * 255)
                pixels[offset + 3] = 255
            }
        }
        guard let image = context.makeImage() else {
            throw ScalerError.stripDecodingFailed(stripIndex: 0, rectDescription: "fixture CGImage creation failed")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScalerError.stripDecodingFailed(stripIndex: 0, rectDescription: "fixture PNG destination creation failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScalerError.stripDecodingFailed(stripIndex: 0, rectDescription: "fixture PNG finalize failed")
        }
    }

    private static func assertNonconstantAndFinite(_ buffer: MMapBuffer) {
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        var sum: Double = 0
        var sumSquares: Double = 0
        var count = 0
        let step = max(1, min(buffer.width, buffer.height) / 64)
        var y = 0
        while y < buffer.height {
            var x = 0
            while x < buffer.width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                for channel in 0..<3 {
                    let value = Float(pixel[channel])
                    XCTAssertTrue(value.isFinite, "Non-finite trained output at (\(x),\(y))")
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    sum += Double(value)
                    sumSquares += Double(value) * Double(value)
                    count += 1
                }
                x += step
            }
            y += step
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertGreaterThan(maximum - minimum, 1e-5, "Trained output must not be a constant image")
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        XCTAssertGreaterThan(variance, 1e-10, "Trained output must carry nonconstant texture")
    }
}
