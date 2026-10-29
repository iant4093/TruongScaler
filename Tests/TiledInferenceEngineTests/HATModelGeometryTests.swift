import Foundation
import XCTest
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MMapCanvas
import MetalColorEngine
import TruongScalerCore
@testable import TiledInferenceEngine

/// Geometry/ownership fixtures deliberately select the explicit test resampler. Trained HAT-S
/// fidelity, quality and required-model predictions are validated by separate production tests.
final class HATModelGeometryTests: XCTestCase, @unchecked Sendable {
    func testEachSupportedFamilyMapsToItsOwnNativeTwoTimesAssetAndUnknownNeverMapsToQuick() throws {
        let expected: [(BackboneModelKind, CoreMLModelIdentifier, CoreMLModelIdentifier)] = [
            (.quickSRNet, .quickSRx2_192, .quickSRx2_256),
            (.edsrBaseline, .edsrX2_192, .edsrX2_256),
            (.hatSmall, .hatSX2_192, .hatSX2_256)
        ]
        for (family, small, large) in expected {
            XCTAssertEqual(try CoreMLModelIdentifier.superResolver(backbone: family, tier: .tierB_ConstrainedMemory), small)
            XCTAssertEqual(try CoreMLModelIdentifier.superResolver(backbone: family, tier: .tierA_HighMemory), large)
            for identifier in [small, large] {
                XCTAssertEqual(identifier.expectedInputShape, [1, 3, identifier.inputTileSize, identifier.inputTileSize])
                XCTAssertEqual(identifier.expectedOutputShape, [1, 3, identifier.inputTileSize * 2, identifier.inputTileSize * 2])
            }
        }
        XCTAssertEqual(CoreMLModelIdentifier.allCases.count, 6)
        for unknown in [BackboneModelKind.unavailable, BackboneModelKind(rawValue: "retired:HAT-L")] {
            XCTAssertThrowsError(try CoreMLModelIdentifier.superResolver(backbone: unknown, tier: .tierA_HighMemory)) { error in
                guard let error = error as? ScalerError,
                      case .modelInferenceFailed(let name, _, _) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(name, unknown.rawValue)
            }
        }
    }

    func testHATPlannerHasCompleteCoverageAndAtLeastItsRecordedHalo() {
        for tier in [DeviceTier.tierA_HighMemory, .tierB_ConstrainedMemory] {
            let geometry = TileConfiguration(tier: tier, backbone: .hatSmall)
            let plan = TileGridPlanner.makePlan(sourceWidth: 601, sourceHeight: 403,
                                               scaleFactor: .x2, tileConfig: geometry)
            XCTAssertEqual(plan.outputWidth, 1202)
            XCTAssertEqual(plan.outputHeight, 806)
            XCTAssertGreaterThan(plan.totalTiles, 1)
            for tile in plan.tiles {
                XCTAssertEqual(tile.inputSize, geometry.inputTileSize)
                if tile.col > 0 { XCTAssertGreaterThanOrEqual(tile.actualLeftOverlapOut, 64) }
                if tile.row > 0 { XCTAssertGreaterThanOrEqual(tile.actualTopOverlapOut, 64) }
            }
            let last = plan.tiles.last
            XCTAssertEqual(last.map { $0.outputOriginX + $0.outputSize }, plan.outputWidth)
            XCTAssertEqual(last.map { $0.outputOriginY + $0.outputSize }, plan.outputHeight)
        }
    }

    func testHATPauseResumeRetainsItsSavedHaloAndModelDespiteTheNewSelection() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try makeInputImage(in: directory)
        let work = directory.appendingPathComponent("job")
        let store = try JobCheckpointStore(workingDirectory: work)
        let executor = makeExecutor(directory: work, store: store)
        let config = UpscaleJobConfig(sourceImageURL: input, backbone: .hatSmall, naturalGrainAmount: 0.2)
        await executor.requestPauseAfterTileForTesting(0)
        do {
            _ = try await executor.executeOrResumeJob(config: config, overrideTier: .tierB_ConstrainedMemory)
            XCTFail("The explicit pause should stop the unfinished job at a durable boundary")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let index) = error else { throw error }
            XCTAssertEqual(index, 0)
        }
        let state = try await store.load(jobID: config.id)
        XCTAssertEqual(state.tileConfig, TileConfiguration(tier: .tierB_ConstrainedMemory, backbone: .hatSmall))
        XCTAssertGreaterThan(state.totalTiles, 1)
        var nextSelection = config
        nextSelection.backbone = .quickSRNet
        nextSelection.naturalGrainAmount = 0.9
        let resumed = try await makeExecutor(directory: work, store: store).executeOrResumeJob(
            config: nextSelection, existingCheckpoint: state, overrideTier: .tierA_HighMemory)
        XCTAssertEqual(resumed.checkpoint.config, config)
        XCTAssertEqual(resumed.checkpoint.tileConfig, state.tileConfig)
        XCTAssertEqual(resumed.checkpoint.lastCompletedTileIndex, state.totalTiles - 1)
        let baselineDirectory = directory.appendingPathComponent("baseline")
        let baselineStore = try JobCheckpointStore(workingDirectory: baselineDirectory)
        let baseline = try await makeExecutor(directory: baselineDirectory, store: baselineStore).executeOrResumeJob(
            config: config, overrideTier: .tierB_ConstrainedMemory)
        XCTAssertEqual(snapshot(resumed.outputBuffer), snapshot(baseline.outputBuffer))
    }

    func testHATCheckpointWithQuickGeometryIsRefusedBeforeAnyFilesChange() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try MMapBuffer(fileURL: directory.appendingPathComponent("source.bin"), width: 4, height: 4)
        let output = try MMapBuffer(fileURL: directory.appendingPathComponent("output.bin"), width: 8, height: 8)
        source.unsafePixelPointer(x: 0, y: 0)[0] = 0.25
        output.unsafePixelPointer(x: 0, y: 0)[0] = 0.75
        try Data("metadata must not be opened for an incompatible halo".utf8)
            .write(to: directory.appendingPathComponent("metadata.json"))
        let config = UpscaleJobConfig(sourceImageURL: directory.appendingPathComponent("source.dng"), backbone: .hatSmall)
        let state = JobCheckpointState(jobID: config.id, config: config,
            tileConfig: TileConfiguration(tier: .tierA_HighMemory),
            sourceWidth: 4, sourceHeight: 4, paddedSourceWidth: 4, paddedSourceHeight: 4,
            outputWidth: 8, outputHeight: 8, globalMaxLuminance: 1, didRunDenoise: false,
            sourceMMapFileName: "source.bin", outputMMapFileName: "output.bin", metadataPacketFileName: "metadata.json",
            totalTiles: 1, normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion)
        let store = try JobCheckpointStore(workingDirectory: directory)
        try await store.save(state)
        let before = try fileSnapshot(directory)
        do {
            _ = try await makeExecutor(directory: directory, store: store).executeOrResumeJob(config: config, existingCheckpoint: state)
            XCTFail("A HAT model may not resume a canvas carrying QuickSRNet/EDSR geometry")
        } catch let error as ScalerError {
            guard case .checkpointCorrupted = error else { throw error }
        }
        XCTAssertEqual(try fileSnapshot(directory), before)
        XCTAssertEqual(source.unsafePixelPointer(x: 0, y: 0)[0], 0.25)
        XCTAssertEqual(output.unsafePixelPointer(x: 0, y: 0)[0], 0.75)
    }

    private func makeExecutor(directory: URL, store: JobCheckpointStore) -> TiledPipelineExecutor {
        TiledPipelineExecutor(workingDirectory: directory,
            modelRegistry: CoreMLModelRegistry(initialComputeUnits: .cpuOnly,
                availabilityPolicy: .allowDeterministicFallback, searchDirectoriesOverride: []),
            checkpointStore: store, colorProcessor: MetalColorProcessor(preferMetal: false))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HATGeometry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeInputImage(in directory: URL) throws -> URL {
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
            bytesPerRow: 320 * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<320 {
            context.setFillColor(red: 0.2 + 0.5 * CGFloat(x) / 320, green: 0.3, blue: 0.4, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 240))
        }
        let url = directory.appendingPathComponent("input.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func snapshot(_ buffer: MMapBuffer) -> [UInt16] {
        (0..<buffer.height).flatMap { y in
            (0..<buffer.width).flatMap { x in (0..<4).map { buffer.unsafePixelPointer(x: x, y: y)[$0].bitPattern } }
        }
    }

    private func fileSnapshot(_ directory: URL) throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return try Dictionary(uniqueKeysWithValues: urls.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
