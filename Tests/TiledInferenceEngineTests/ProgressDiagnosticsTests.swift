import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TiledInferenceEngine
@testable import MetalColorEngine
@testable import MMapCanvas
@testable import TruongScalerCore

/// Executed progress-contract test against the real tiled executor (deterministic CPU fallback
/// resampler, no production model loading). It proves the app receives real phases, geometry,
/// timings, per-tile committed counts and an ETA only after measured samples exist.
final class ProgressDiagnosticsTests: XCTestCase {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PipelineProgressUpdate] = []
        func record(_ update: PipelineProgressUpdate) {
            lock.lock(); storage.append(update); lock.unlock()
        }
        var updates: [PipelineProgressUpdate] {
            lock.lock(); defer { lock.unlock() }; return storage
        }
    }

    private func makePNG(directory: URL, width: Int, height: Int) throws -> URL {
        var rgba16 = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                rgba16[offset + 0] = UInt16((x * 65535) / max(1, width - 1))
                rgba16[offset + 1] = UInt16((y * 65535) / max(1, height - 1))
                rgba16[offset + 2] = 32768
                rgba16[offset + 3] = 65535
            }
        }
        let url = directory.appendingPathComponent("progress_\(width)x\(height).png")
        let data = rgba16.withUnsafeBytes { Data($0) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 64,
                bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: "ProgressDiagnosticsTests", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ProgressDiagnosticsTests", code: 2)
        }
        return url
    }

    func testRequestedComputePolicyTracksRealForegroundBackgroundTierSwitches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobCheckpointStore(workingDirectory: directory)
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let initialPolicy = await executor.currentRequestedComputeDescriptionForTesting()
        XCTAssertFalse(initialPolicy.isEmpty)
        await executor.setBackgroundExecutionMode(true)
        let backgroundPolicy = await executor.currentRequestedComputeDescriptionForTesting()
        XCTAssertTrue(backgroundPolicy.contains("cpuAndNeuralEngine"))
        let backgroundUnits = await registry.currentUnits()
        XCTAssertEqual(backgroundUnits, .cpuAndNeuralEngine)
        await executor.setBackgroundExecutionMode(false)
        let foregroundPolicy = await executor.currentRequestedComputeDescriptionForTesting()
        XCTAssertTrue(foregroundPolicy.contains("all"))
        let foregroundUnits = await registry.currentUnits()
        XCTAssertEqual(foregroundUnits, .all)
    }

    func testRealExecutorPausedProgressReportsDurableCheckpointFrontier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPauseFrontier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = try makePNG(directory: directory, width: 512, height: 384)
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0,
            exportFormat: .png16Bit
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: CoreMLModelRegistry(initialComputeUnits: .cpuOnly),
            checkpointStore: store,
            colorProcessor: MetalColorProcessor(preferMetal: false)
        )
        let recorder = ProgressRecorder()
        await executor.requestPauseAfterTileForTesting(1)
        do {
            _ = try await executor.executeOrResumeJob(
                config: config,
                overrideTier: .tierB_ConstrainedMemory,
                progressHandler: { recorder.record($0) }
            )
            XCTFail("Expected controlled pause")
        } catch ScalerError.jobPausedForBackgroundExpiration {}
        let checkpoint = try await store.load(jobID: config.id)
        let paused = try XCTUnwrap(recorder.updates.last)
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.stage, .pausedOnDisk)
        XCTAssertEqual(paused.completedTiles, checkpoint.lastCompletedTileIndex + 1,
                       "Paused progress must report the durable checkpoint frontier")
    }

    func testResumedBusyProgressUsesCurrentBackgroundComputePolicy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPolicyRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = try makePNG(directory: directory, width: 512, height: 384)
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0,
            exportFormat: .png16Bit
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: registry,
            checkpointStore: store,
            colorProcessor: MetalColorProcessor(preferMetal: false)
        )
        await executor.requestPauseAfterTileForTesting(0)
        do {
            _ = try await executor.executeOrResumeJob(
                config: config,
                overrideTier: .tierB_ConstrainedMemory
            )
            XCTFail("Expected controlled pause")
        } catch ScalerError.jobPausedForBackgroundExpiration {}
        let checkpoint = try await store.load(jobID: config.id)
        await executor.setBackgroundExecutionMode(true)
        let recorder = ProgressRecorder()
        _ = try await executor.executeOrResumeJob(
            config: config,
            existingCheckpoint: checkpoint,
            progressHandler: { recorder.record($0) }
        )
        let busy = recorder.updates.filter { $0.currentTileIndex != nil && $0.phase != .tileCommitted }
        XCTAssertFalse(busy.isEmpty)
        XCTAssertTrue(busy.allSatisfy { ($0.requestedCompute ?? "").contains("cpuAndNeuralEngine") },
                      "Busy events must reflect the current requested policy, not the entry policy")
        XCTAssertFalse(busy.contains { ($0.requestedCompute ?? "").contains("all (CPU+GPU+ANE") })
    }

    func testRealExecutorPublishesPhasesGeometryTimingsCommittedCountsAndHonestETA() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = try makePNG(directory: directory, width: 256, height: 192)
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .png16Bit
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: CoreMLModelRegistry(initialComputeUnits: .cpuOnly),
            checkpointStore: store,
            colorProcessor: MetalColorProcessor(preferMetal: false)
        )
        let recorder = ProgressRecorder()
        _ = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory,
            progressHandler: { recorder.record($0) }
        )
        let updates = recorder.updates

        XCTAssertFalse(updates.isEmpty)
        XCTAssertEqual(updates.last?.phase, .completed)
        XCTAssertEqual(updates.last?.overallFraction ?? 0, 1.0, accuracy: 0.0001)
        let wholeJobSeconds = try XCTUnwrap(updates.last?.elapsedSeconds)
        let tileLoopSeconds = try XCTUnwrap(updates.last?.tileLoopElapsedSeconds)
        XCTAssertGreaterThanOrEqual(wholeJobSeconds, tileLoopSeconds,
                                    "Whole-job elapsed includes decode/canvas preparation before the tile loop")

        let tilePhases = Set(updates.map(\.phase))
        XCTAssertTrue(tilePhases.contains(.extractingTile))
        XCTAssertTrue(tilePhases.contains(.predictingSuperResolution))
        XCTAssertTrue(tilePhases.contains(.reconstructingTile))
        XCTAssertTrue(tilePhases.contains(.committingTile))
        XCTAssertTrue(tilePhases.contains(.tileCommitted))
        XCTAssertTrue(tilePhases.contains(.finalizing))

        let committed = updates.filter { $0.phase == .tileCommitted }
        XCTAssertEqual(committed.count, updates.last?.totalTiles)
        XCTAssertFalse(committed.isEmpty)
        var previousCompleted = 0
        for update in committed {
            XCTAssertGreaterThan(update.totalTiles, 0)
            XCTAssertEqual(update.sourceWidth, 256)
            XCTAssertEqual(update.sourceHeight, 192)
            XCTAssertEqual(update.outputWidth, 512)
            XCTAssertEqual(update.outputHeight, 384)
            XCTAssertTrue(update.tileSize == 256 || update.tileSize == 192)
            XCTAssertEqual(update.tileOverlap, update.tileSize == 256 ? 24 : 16)
            XCTAssertGreaterThanOrEqual(update.gridColumns ?? 0, 2)
            XCTAssertGreaterThanOrEqual(update.gridRows ?? 0, 1)
            XCTAssertEqual(update.modelName, "QuickSRNet_Large_x2_192")
            XCTAssertTrue(update.requestedCompute?.contains("cpuOnly") ?? false)
            XCTAssertEqual(update.didRunDenoise, false)
            XCTAssertEqual(update.completedTiles, previousCompleted + 1, "Committed counts advance one durable tile at a time")
            XCTAssertGreaterThanOrEqual(update.completedTiles, 1)
            XCTAssertLessThanOrEqual(update.completedTiles, update.totalTiles)
            XCTAssertNotNil(update.currentTileIndex)
            XCTAssertNotNil(update.timings)
            XCTAssertNotNil(update.timings?.modelSeconds)
            XCTAssertNotNil(update.timings?.journalSeconds)
            XCTAssertNotNil(update.timings?.blendSeconds)
            XCTAssertNotNil(update.timings?.flushSeconds)
            XCTAssertNotNil(update.timings?.checkpointSeconds)
            XCTAssertNotNil(update.timings?.cleanupSeconds)
            XCTAssertGreaterThanOrEqual(update.timings?.modelSeconds ?? -1, 0)
            if update.completedTiles == 1 {
                XCTAssertNil(update.averageSecondsPerTile, "The warmup tile must not set an ETA")
                XCTAssertNil(update.estimatedSecondsRemaining)
            } else {
                XCTAssertNotNil(update.averageSecondsPerTile)
                XCTAssertNotNil(update.estimatedSecondsRemaining)
            }
            previousCompleted = update.completedTiles
        }

        // Preparing updates deliberately have no fake 1/1 or ETA.
        let preparing = updates.filter { $0.totalTiles == 0 }
        for update in preparing {
            XCTAssertNil(update.estimatedSecondsRemaining, "No ETA before a measured tile exists")
        }

        // A busy uncommitted tile publishes the same committed count, never completed+1.
        let busy = updates.filter { $0.phase == .predictingSuperResolution }
        XCTAssertFalse(busy.isEmpty)
        for update in busy {
            XCTAssertLessThanOrEqual(update.completedTiles, update.totalTiles)
        }

        // Diagnostics were emitted for the job/plan and representative committed tiles, with bounded
        // structured fields (no source path).
        let events = Diagnostics.shared.recentEvents(limit: 500)
        let start = events.first { $0.code == "pipeline.job.start" && $0.fields["correlationID"] == config.id.uuidString }
        XCTAssertNotNil(start)
        XCTAssertEqual(start?.fields["denoise"], "off")
        XCTAssertEqual(start?.fields["scale"], "2x")
        let plan = events.first { $0.code == "pipeline.plan" && $0.fields["correlationID"] == config.id.uuidString }
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.fields["totalTiles"], "\(updates.last?.totalTiles ?? -1)")
        XCTAssertEqual(plan?.fields["model"], committed.first?.modelName)
        XCTAssertNil(plan?.fields["sourcePath"])
        XCTAssertFalse(plan?.line.contains(sourceURL.path) ?? true, "Diagnostics must never include a personal path")
    }
}
