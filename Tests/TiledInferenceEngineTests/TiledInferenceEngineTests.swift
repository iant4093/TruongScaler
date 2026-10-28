import XCTest
import Foundation
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate
@testable import TiledInferenceEngine
@testable import MetalColorEngine
@testable import CoreIngestion
@testable import CoreExport
@testable import MMapCanvas
@testable import TruongScalerCore

/// Thread-safe progress recorder so the `@Sendable` pipeline progress closure can be inspected after a run.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PipelineProgressUpdate] = []

    func record(_ update: PipelineProgressUpdate) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }

    var updates: [PipelineProgressUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Set-once flag used to observe asynchronous API completion without blocking the test thread.
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func set() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

/// Thread-safe optional boolean result for scoped-pause waiter assertions.
private final class ScopedPauseResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Error reported by the test-only durable-transaction interruption hook.
private struct InjectedTransactionInterruption: Error, Equatable {
    let point: TransactionInterruptionPoint
}

/// Thread-safe one-shot injector: throws at `target` after skipping `skipCount` occurrences.
private final class TransactionInterruptionInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let target: TransactionInterruptionPoint
    private var remainingSkips: Int
    private var didThrowStorage = false

    init(target: TransactionInterruptionPoint, skipCount: Int) {
        self.target = target
        self.remainingSkips = max(0, skipCount)
    }

    var didThrow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didThrowStorage
    }

    func hook(_ point: TransactionInterruptionPoint) throws {
        guard point == target else { return }
        lock.lock()
        if remainingSkips > 0 {
            remainingSkips -= 1
            lock.unlock()
            return
        }
        didThrowStorage = true
        lock.unlock()
        throw InjectedTransactionInterruption(point: point)
    }
}

final class TiledInferenceEngineTests: XCTestCase {
    // MARK: - Synthetic fixtures

    private struct SyntheticJob {
        let workingDirectory: URL
        let jobID: UUID
        let config: UpscaleJobConfig
        let tileConfig: TileConfiguration
        let sourceBuffer: MMapBuffer
        let outputBuffer: MMapBuffer
        let plan: TileGridPlan
        let checkpoint: JobCheckpointState
        let checkpointStore: JobCheckpointStore
    }

    private func makeTemporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiledInferenceEngineTests_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fillSyntheticRGBA16F(_ buffer: MMapBuffer) {
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                let fx = Float(x) / Float(max(1, buffer.width - 1))
                let fy = Float(y) / Float(max(1, buffer.height - 1))
                let checker: Float = ((x / 3 + y / 5) % 2 == 0) ? 0.06 : -0.06
                pixel[0] = Float16(min(max(0.05 + 0.75 * fx + checker, 0.0), 1.0))
                pixel[1] = Float16(min(max(0.05 + 0.65 * fy - checker, 0.0), 1.0))
                pixel[2] = Float16(min(max(0.10 + 0.30 * ((fx + fy) * 0.5), 0.0), 1.0))
                pixel[3] = Float16(1.0)
            }
        }
    }

    private func makeCheckpointState(
        jobID: UUID,
        config: UpscaleJobConfig? = nil,
        tileConfig: TileConfiguration = TileConfiguration(tier: .tierB_ConstrainedMemory),
        sourceWidth: Int = 64,
        sourceHeight: Int = 48,
        outputWidth: Int = 128,
        outputHeight: Int = 96,
        lastCompletedTileIndex: Int,
        totalTiles: Int = 6,
        sourceMMapFileName: String = "source.bin",
        outputMMapFileName: String = "output.bin",
        metadataPacketFileName: String = "metadata.json",
        updatedAt: Date = Date()
    ) -> JobCheckpointState {
        let resolvedConfig = config ?? UpscaleJobConfig(
            id: jobID,
            sourceImageURL: URL(fileURLWithPath: "/tmp/truongscaler_synthetic_source.png"),
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .png16Bit
        )
        return JobCheckpointState(
            jobID: jobID,
            config: resolvedConfig,
            tileConfig: tileConfig,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            paddedSourceWidth: sourceWidth,
            paddedSourceHeight: sourceHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            globalMaxLuminance: 1.0,
            alphaCurveConstant: 16.0,
            didRunDenoise: false,
            sourceMMapFileName: sourceMMapFileName,
            outputMMapFileName: outputMMapFileName,
            metadataPacketFileName: metadataPacketFileName,
            lastCompletedTileIndex: lastCompletedTileIndex,
            totalTiles: totalTiles,
            updatedAt: updatedAt
        )
    }

    /// Builds a synthetic resumable job. When `existingDirectory` is supplied the job's sidecars use
    /// job-unique names so a second real job (a distinct config/checkpoint, e.g. a replacement run) can
    /// live in the same executor working directory for identity/pause-ownership tests.
    private func makeSyntheticJob(
        sourceWidth: Int,
        sourceHeight: Int,
        scale: ScaleFactor,
        tier: DeviceTier,
        lastCompletedTileIndex: Int = -1,
        label: String,
        in existingDirectory: URL? = nil
    ) async throws -> SyntheticJob {
        let directory = try existingDirectory ?? makeTemporaryDirectory(label: label)
        let jobID = UUID()
        // A shared directory must not collide with the first job's default sidecar names.
        let suffix = existingDirectory == nil ? "" : "_\(jobID.uuidString)"
        let sourceMMapFileName = "source\(suffix).bin"
        let outputMMapFileName = "output\(suffix).bin"
        let metadataPacketFileName = "metadata\(suffix).json"
        let config = UpscaleJobConfig(
            id: jobID,
            sourceImageURL: directory.appendingPathComponent("synthetic_source\(suffix).png"),
            scaleFactor: scale,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .png16Bit
        )
        let tileConfig = TileConfiguration(tier: tier)
        let plan = TileGridPlanner.makePlan(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            scaleFactor: scale,
            tileConfig: tileConfig
        )

        let sourceBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent(sourceMMapFileName),
            width: sourceWidth,
            height: sourceHeight,
            createIfMissing: true
        )
        fillSyntheticRGBA16F(sourceBuffer)
        try sourceBuffer.flushToDisk(synchronous: true)

        let outputBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent(outputMMapFileName),
            width: plan.outputWidth,
            height: plan.outputHeight,
            createIfMissing: true
        )

        let metadata = ImageMetadataPacket(
            sourceURL: config.sourceImageURL,
            utTypeIdentifier: "public.png",
            category: .standardOpaqueRaster,
            originalWidth: sourceWidth,
            originalHeight: sourceHeight,
            bitsPerComponent: 16,
            hasAlpha: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent(metadataPacketFileName),
            options: .atomic
        )

        let checkpoint = makeCheckpointState(
            jobID: jobID,
            config: config,
            tileConfig: tileConfig,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            outputWidth: plan.outputWidth,
            outputHeight: plan.outputHeight,
            lastCompletedTileIndex: lastCompletedTileIndex,
            totalTiles: plan.totalTiles,
            sourceMMapFileName: sourceMMapFileName,
            outputMMapFileName: outputMMapFileName,
            metadataPacketFileName: metadataPacketFileName,
            updatedAt: Date()
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        try await store.save(checkpoint)

        return SyntheticJob(
            workingDirectory: directory,
            jobID: jobID,
            config: config,
            tileConfig: tileConfig,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer,
            plan: plan,
            checkpoint: checkpoint,
            checkpointStore: store
        )
    }

    /// Uses the deterministic CPU path of `MetalColorProcessor` so resumed and uninterrupted runs are
    /// compared against a bit-stable baseline even on machines where a Metal device is available.
    private func makeExecutor(
        workingDirectory: URL,
        checkpointStore: JobCheckpointStore
    ) -> TiledPipelineExecutor {
        TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: CoreMLModelRegistry(initialComputeUnits: .cpuOnly),
            checkpointStore: checkpointStore,
            colorProcessor: MetalColorProcessor(preferMetal: false)
        )
    }

    private func nonZeroPixelCount(_ buffer: MMapBuffer) -> Int {
        var count = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                if Float(pixel[0]) > 1e-4 || Float(pixel[1]) > 1e-4 || Float(pixel[2]) > 1e-4 {
                    count += 1
                }
            }
        }
        return count
    }

    private func maxPixelDifference(_ lhs: MMapBuffer, _ rhs: MMapBuffer) -> Float {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return .infinity }
        var maximumDifference: Float = 0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                let lhsPixel = lhs.unsafePixelPointer(x: x, y: y)
                let rhsPixel = rhs.unsafePixelPointer(x: x, y: y)
                for channel in 0..<4 {
                    let lhsValue = Float(lhsPixel[channel])
                    let rhsValue = Float(rhsPixel[channel])
                    if lhsValue.isNaN || rhsValue.isNaN { return .infinity }
                    maximumDifference = max(maximumDifference, abs(lhsValue - rhsValue))
                }
            }
        }
        return maximumDifference
    }

    // MARK: - Phase 5 end-to-end test

    func testEndToEndTiledExecutionAndPauseResumeIdempotency() async throws {
        let pausedJob = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "paused"
        )
        defer { try? FileManager.default.removeItem(at: pausedJob.workingDirectory) }

        // 400x300 at 2x with 192px Tier-B tiles -> 3 x 2 = 6 tiles -> 800x600 output.
        XCTAssertEqual(pausedJob.plan.cols, 3)
        XCTAssertEqual(pausedJob.plan.rows, 2)
        XCTAssertEqual(pausedJob.plan.totalTiles, 6)
        XCTAssertEqual(pausedJob.plan.outputWidth, 800)
        XCTAssertEqual(pausedJob.plan.outputHeight, 600)

        let store = pausedJob.checkpointStore
        let recorder = ProgressRecorder()
        let executor = makeExecutor(workingDirectory: pausedJob.workingDirectory, checkpointStore: store)
        await executor.requestPauseAfterTileForTesting(2)

        do {
            _ = try await executor.executeOrResumeJob(
                config: pausedJob.config,
                existingCheckpoint: pausedJob.checkpoint,
                progressHandler: { recorder.record($0) }
            )
            XCTFail("Expected the executor to pause gracefully after tile 2.")
            return
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let completedTileIndex) = error else {
                XCTFail("Unexpected ScalerError while pausing: \(error)")
                return
            }
            XCTAssertEqual(completedTileIndex, 2)
        } catch {
            XCTFail("Unexpected error while pausing: \(error)")
            return
        }

        let checkpointURL = await store.checkpointFileURL(for: pausedJob.jobID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path), "Checkpoint JSON must exist after a graceful pause.")
        let pausedCheckpoint = try await store.load(jobID: pausedJob.jobID)
        XCTAssertEqual(pausedCheckpoint.lastCompletedTileIndex, 2)
        XCTAssertEqual(pausedCheckpoint.totalTiles, 6)

        let incompleteCheckpoints = await store.listIncompleteCheckpoints()
        XCTAssertEqual(incompleteCheckpoints.count, 1)
        XCTAssertEqual(incompleteCheckpoints.first?.jobID, pausedJob.jobID)
        XCTAssertEqual(incompleteCheckpoints.first?.lastCompletedTileIndex, 2)

        let updates = recorder.updates
        let tileUpdates = updates.filter { $0.stage == .denoisingAndUpscalingTiles }
        XCTAssertFalse(tileUpdates.isEmpty)
        XCTAssertTrue(updates.contains { $0.stage == .pausedOnDisk })
        XCTAssertTrue(tileUpdates.allSatisfy { $0.totalTiles == 6 })
        XCTAssertTrue(tileUpdates.allSatisfy { $0.overallFraction >= 0.10 && $0.overallFraction <= 1.0 })
        XCTAssertTrue(tileUpdates.contains { $0.completedTiles == 3 && $0.currentTileDescriptor?.tileIndex == 2 })
        XCTAssertTrue(tileUpdates.contains { $0.estimatedSecondsRemaining != nil })
        XCTAssertGreaterThan(nonZeroPixelCount(pausedJob.outputBuffer), 0)

        // Resume from the persisted checkpoint (fresh executor == app relaunch) and finish the job.
        let resumedArtifacts = try await makeExecutor(
            workingDirectory: pausedJob.workingDirectory,
            checkpointStore: store
        ).executeOrResumeJob(
            config: pausedJob.config,
            existingCheckpoint: pausedCheckpoint,
            progressHandler: nil
        )
        XCTAssertEqual(resumedArtifacts.outputBuffer.width, 800)
        XCTAssertEqual(resumedArtifacts.outputBuffer.height, 600)
        XCTAssertEqual(resumedArtifacts.checkpoint.lastCompletedTileIndex, 5)
        XCTAssertEqual(resumedArtifacts.checkpoint.totalTiles, 6)
        XCTAssertGreaterThan(nonZeroPixelCount(resumedArtifacts.outputBuffer), (800 * 600) / 2)

        let remainingCheckpoints = await store.listIncompleteCheckpoints()
        XCTAssertTrue(remainingCheckpoints.isEmpty, "Completed jobs must not be listed as incomplete.")

        // Independent uninterrupted baseline run over the identical synthetic source.
        let baselineJob = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "baseline"
        )
        defer { try? FileManager.default.removeItem(at: baselineJob.workingDirectory) }
        let baselineArtifacts = try await makeExecutor(
            workingDirectory: baselineJob.workingDirectory,
            checkpointStore: baselineJob.checkpointStore
        ).executeOrResumeJob(
            config: baselineJob.config,
            existingCheckpoint: baselineJob.checkpoint,
            progressHandler: nil
        )

        let difference = maxPixelDifference(resumedArtifacts.outputBuffer, baselineArtifacts.outputBuffer)
        XCTAssertLessThanOrEqual(
            difference,
            1e-3,
            "Resuming after a graceful pause must reproduce the uninterrupted canvas (max diff \(difference))."
        )
    }

    // MARK: - vImage Lanczos / AI grain blender

    func testLanczosGrainBlenderInteractiveEndpoints() throws {
        let directory = try makeTemporaryDirectory(label: "lanczos")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSize = 32
        let scale = 2
        let outputSize = sourceSize * scale
        let sourceBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent("lanczos_source.bin"),
            width: sourceSize,
            height: sourceSize,
            createIfMissing: true
        )
        let constantR = Float16(0.25)
        let constantG = Float16(0.5)
        let constantB = Float16(0.75)
        let constantA = Float16(1.0)
        for y in 0..<sourceSize {
            for x in 0..<sourceSize {
                let pixel = sourceBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = constantR
                pixel[1] = constantG
                pixel[2] = constantB
                pixel[3] = constantA
            }
        }
        try sourceBuffer.flushToDisk(synchronous: true)

        let hatBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent("lanczos_hat.bin"),
            width: outputSize,
            height: outputSize,
            createIfMissing: true
        )
        let hatR = Float16(0.10)
        let hatG = Float16(0.20)
        let hatB = Float16(0.30)
        let hatA = Float16(0.40)
        for y in 0..<outputSize {
            for x in 0..<outputSize {
                let pixel = hatBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = hatR
                pixel[1] = hatG
                pixel[2] = hatB
                pixel[3] = hatA
            }
        }
        try hatBuffer.flushToDisk(synchronous: true)

        let rowBytes = outputSize * 8
        let byteCount = rowBytes * outputSize

        func render(grain: Float) -> UnsafeMutableRawPointer {
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            memset(pointer, 0, byteCount)
            LanczosGrainBlender.renderBlendedRegion(
                outX: 0,
                outY: 0,
                outWidth: outputSize,
                outHeight: outputSize,
                scaleFactor: scale,
                naturalGrainAmount: grain,
                sourceBuffer: sourceBuffer,
                hatOutputBuffer: hatBuffer,
                destinationRGBA16F: pointer,
                destinationRowBytes: rowBytes
            )
            return pointer
        }

        let pureAI = render(grain: 0.0)
        defer { pureAI.deallocate() }
        let blended = render(grain: 0.25)
        defer { blended.deallocate() }
        let pureLanczos = render(grain: 1.0)
        defer { pureLanczos.deallocate() }

        let aiPixels = pureAI.assumingMemoryBound(to: Float16.self)
        let blendedPixels = blended.assumingMemoryBound(to: Float16.self)
        let lanczosPixels = pureLanczos.assumingMemoryBound(to: Float16.self)

        // Sampling grid that includes all four canvas corners and the center.
        let sampleCoordinates: [(Int, Int)] = [
            (0, 0), (outputSize - 1, 0), (0, outputSize - 1),
            (outputSize - 1, outputSize - 1), (outputSize / 2, outputSize / 2),
            (7, 23), (31, 41), (55, 3)
        ]
        let hatChannels: [Float] = [Float(hatR), Float(hatG), Float(hatB), Float(hatA)]
        let lanczosChannels: [Float] = [Float(constantR), Float(constantG), Float(constantB), Float(constantA)]

        for (x, y) in sampleCoordinates {
            let offset = (y * outputSize + x) * 4
            for channel in 0..<4 {
                let aiValue = Float(aiPixels[offset + channel])
                let endpointValue = Float(lanczosPixels[offset + channel])
                let blendedValue = Float(blendedPixels[offset + channel])

                XCTAssertEqual(aiValue, hatChannels[channel], accuracy: 1e-4, "α = 0 must be 100% AI/HAT output.")
                XCTAssertEqual(endpointValue, lanczosChannels[channel], accuracy: 1e-3, "α = 1 must be 100% vImage Lanczos output.")
                let expectedBlend = 0.75 * hatChannels[channel] + 0.25 * lanczosChannels[channel]
                XCTAssertEqual(blendedValue, expectedBlend, accuracy: 1e-3, "α = 0.25 must linearly interpolate.")
                XCTAssertFalse(blendedValue.isNaN)
            }
        }

        // Monotonic blend behavior: HAT R (0.10) < source R (0.25), so R must strictly increase with α.
        let probeOffset = ((outputSize / 2) * outputSize + outputSize / 2) * 4
        let aiRed = Float(aiPixels[probeOffset])
        let blendedRed = Float(blendedPixels[probeOffset])
        let lanczosRed = Float(lanczosPixels[probeOffset])
        XCTAssertLessThan(aiRed, blendedRed)
        XCTAssertLessThan(blendedRed, lanczosRed)
        XCTAssertEqual(aiRed, 0.10, accuracy: 1e-4)
        XCTAssertEqual(lanczosRed, 0.25, accuracy: 1e-3)

        // 1x1 region must not crash and must produce finite values.
        let tinyRowBytes = 8
        let tiny = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 16)
        defer { tiny.deallocate() }
        memset(tiny, 0, 8)
        LanczosGrainBlender.renderBlendedRegion(
            outX: 5,
            outY: 7,
            outWidth: 1,
            outHeight: 1,
            scaleFactor: scale,
            naturalGrainAmount: 0.5,
            sourceBuffer: sourceBuffer,
            hatOutputBuffer: hatBuffer,
            destinationRGBA16F: tiny,
            destinationRowBytes: tinyRowBytes
        )
        let tinyPixel = tiny.assumingMemoryBound(to: Float16.self)
        for channel in 0..<4 {
            XCTAssertTrue(Float(tinyPixel[channel]).isFinite, "1x1 blended region must be finite.")
        }

        // ROI larger than the source canvas must clamp/reflect safely instead of over-reading.
        let oversizedWidth = sourceSize * scale * 2
        let oversizedRowBytes = oversizedWidth * 8
        let oversized = UnsafeMutableRawPointer.allocate(
            byteCount: oversizedRowBytes * oversizedWidth,
            alignment: 64
        )
        defer { oversized.deallocate() }
        memset(oversized, 0, oversizedRowBytes * oversizedWidth)
        LanczosGrainBlender.renderBlendedRegion(
            outX: 0,
            outY: 0,
            outWidth: oversizedWidth,
            outHeight: oversizedWidth,
            scaleFactor: scale,
            naturalGrainAmount: 1.0,
            sourceBuffer: sourceBuffer,
            hatOutputBuffer: hatBuffer,
            destinationRGBA16F: oversized,
            destinationRowBytes: oversizedRowBytes
        )
        let oversizedPixels = oversized.assumingMemoryBound(to: Float16.self)
        for index in 0..<(oversizedWidth * oversizedWidth * 4) {
            XCTAssertFalse(oversizedPixels[index].isNaN)
        }
    }

    // MARK: - Checkpoint persistence

    func testLanczosNonconstantRegionMatchesFullFrameReference() throws {
        let directory = try makeTemporaryDirectory(label: "lanczos-gradient")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 37
        let height = 29
        let scale = 4
        let source = try MMapBuffer(fileURL: directory.appendingPathComponent("source.bin"),
                                    width: width, height: height)
        fillSyntheticRGBA16F(source)
        let hat = try MMapBuffer(fileURL: directory.appendingPathComponent("hat.bin"),
                                 width: width * scale, height: height * scale)
        var input = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<4 {
                    input[(y * width + x) * 4 + channel] = Float(source.unsafePixelPointer(x: x, y: y)[channel])
                }
            }
        }
        var reference = [Float](repeating: 0, count: width * height * scale * scale * 4)
        let status = input.withUnsafeMutableBytes { inputBytes in
            reference.withUnsafeMutableBytes { outputBytes in
                var inputImage = vImage_Buffer(data: inputBytes.baseAddress!, height: UInt(height),
                                                width: UInt(width), rowBytes: width * 16)
                var outputImage = vImage_Buffer(data: outputBytes.baseAddress!, height: UInt(height * scale),
                                                 width: UInt(width * scale), rowBytes: width * scale * 16)
                return vImageScale_ARGBFFFF(&inputImage, &outputImage, nil,
                                           vImage_Flags(kvImageHighQualityResampling | kvImageEdgeExtend))
            }
        }
        XCTAssertEqual(status, kvImageNoError)

        let regionWidth = 93
        let regionHeight = 64
        let rowBytes = regionWidth * 8 + 64
        let output = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * regionHeight, alignment: 64)
        defer { output.deallocate() }
        memset(output, 0x5a, rowBytes * regionHeight)
        LanczosGrainBlender.renderBlendedRegion(
            outX: 5, outY: 7, outWidth: regionWidth, outHeight: regionHeight,
            scaleFactor: scale, naturalGrainAmount: 1,
            sourceBuffer: source, hatOutputBuffer: hat,
            destinationRGBA16F: output, destinationRowBytes: rowBytes
        )
        for y in 0..<regionHeight {
            let pixels = output.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<regionWidth {
                for channel in 0..<4 {
                    let expected = reference[((y + 7) * width * scale + x + 5) * 4 + channel]
                    XCTAssertEqual(Float(pixels[x * 4 + channel]), expected, accuracy: 0.001)
                }
            }
            let padding = output.advanced(by: y * rowBytes + regionWidth * 8).assumingMemoryBound(to: UInt8.self)
            for index in 0..<64 { XCTAssertEqual(padding[index], 0x5a) }
        }
    }

    func testCorruptResumeRejectedBeforeOpeningSidecars() async throws {
        let job = try await makeSyntheticJob(sourceWidth: 32, sourceHeight: 24, scale: .x2,
                                             tier: .tierB_ConstrainedMemory, label: "corrupt-resume")
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let encoded = try JSONEncoder().encode(job.checkpoint)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let corruptions: [[String: Any]] = [
            ["lastCompletedTileIndex": Int.max],
            ["lastCompletedTileIndex": -2],
            ["sourceWidth": Int.max],
            ["globalMaxLuminance": 0],
            ["sourceMMapFileName": "output.bin"],
            ["tileConfig": ["tier": "tierB_ConstrainedMemory", "inputTileSize": 0, "inputOverlap": 16]]
        ]
        for corruption in corruptions {
            let changed = original.merging(corruption) { _, replacement in replacement }
            let state = try JSONDecoder().decode(JobCheckpointState.self,
                                                 from: JSONSerialization.data(withJSONObject: changed))
            do {
                _ = try await makeExecutor(workingDirectory: job.workingDirectory,
                                           checkpointStore: job.checkpointStore)
                    .executeOrResumeJob(config: job.config, existingCheckpoint: state)
                XCTFail("Corrupt resume must be rejected: \(corruption)")
            } catch let error as ScalerError {
                guard case .checkpointCorrupted = error else {
                    XCTFail("Expected checkpointCorrupted, got \(error)")
                    continue
                }
            }
        }

        let overflowing = original.merging(["lastCompletedTileIndex": Int.max]) { _, replacement in replacement }
        let overflowingState = try JSONDecoder().decode(
            JobCheckpointState.self, from: JSONSerialization.data(withJSONObject: overflowing)
        )
        try await job.checkpointStore.save(overflowingState)
        let incomplete = await job.checkpointStore.listIncompleteCheckpoints()
        XCTAssertTrue(incomplete.isEmpty, "A corrupt index must be skipped without overflowing during listing.")

        let checkpointURL = await job.checkpointStore.checkpointFileURL(for: job.jobID)
        let wrongIdentity = original.merging(["jobID": UUID().uuidString]) { _, replacement in replacement }
        try JSONSerialization.data(withJSONObject: wrongIdentity).write(to: checkpointURL)
        do {
            _ = try await job.checkpointStore.load(jobID: job.jobID)
            XCTFail("Checkpoint contents must belong to the requested job UUID.")
        } catch let error as ScalerError {
            guard case .checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }

        let sourceURL = job.sourceBuffer.fileURL
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: 8)
        try handle.close()
        do {
            _ = try await makeExecutor(workingDirectory: job.workingDirectory,
                                       checkpointStore: job.checkpointStore)
                .executeOrResumeJob(config: job.config, existingCheckpoint: job.checkpoint)
            XCTFail("Truncated mmap must fail instead of being extended with zero pixels.")
        } catch let error as ScalerError {
            guard case .checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 8)
    }

    func testIncompatibleResumePlanCannotPublishIncomingSessionMetadata() async throws {
        let job = try await makeSyntheticJob(sourceWidth: 32, sourceHeight: 24, scale: .x2,
                                             tier: .tierB_ConstrainedMemory, label: "resume-metadata-preflight")
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let metadataURL = job.workingDirectory.appendingPathComponent(job.checkpoint.metadataPacketFileName)
        let checkpointURL = await job.checkpointStore.checkpointFileURL(for: job.jobID)
        let protectedURLs = [metadataURL, checkpointURL, job.sourceBuffer.fileURL, job.outputBuffer.fileURL]
        let before = try protectedURLs.map { try Data(contentsOf: $0) }
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: job.workingDirectory.path).sorted()
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job.checkpoint)) as? [String: Any])
        encoded["totalTiles"] = job.plan.totalTiles + 1 // Structurally valid, but not this canvas's plan.
        let incompatible = try JSONDecoder().decode(JobCheckpointState.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        var incomingConfig = job.config
        incomingConfig.sessionState = PipelineSessionState(isDenoised: true, isUpscaled: true, upscaleFactor: 2)
        do {
            _ = try await makeExecutor(workingDirectory: job.workingDirectory, checkpointStore: job.checkpointStore)
                .executeOrResumeJob(config: incomingConfig, existingCheckpoint: incompatible)
            XCTFail("An incompatible tile plan must be refused.")
        } catch let error as ScalerError {
            guard case .checkpointCorrupted = error else { return XCTFail("Unexpected error: \(error)") }
        }
        for (url, original) in zip(protectedURLs, before) {
            XCTAssertEqual(try Data(contentsOf: url), original,
                "Rejected resume must not publish metadata or change any saved artifact: \(url.lastPathComponent)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.workingDirectory.path).sorted(), namesBefore)
    }

    func testCheckpointPersistenceAndIncompleteListing() async throws {
        let directory = try makeTemporaryDirectory(label: "checkpoints")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobCheckpointStore(workingDirectory: directory)

        let olderJobID = UUID()
        let newerJobID = UUID()
        let completedJobID = UUID()
        let older = makeCheckpointState(
            jobID: olderJobID,
            lastCompletedTileIndex: 1,
            totalTiles: 6,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = makeCheckpointState(
            jobID: newerJobID,
            lastCompletedTileIndex: 2,
            totalTiles: 6,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let completed = makeCheckpointState(
            jobID: completedJobID,
            lastCompletedTileIndex: 5,
            totalTiles: 6,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try await store.save(older)
        try await store.save(newer)
        try await store.save(completed)

        // Corrupted and unrelated files must be skipped, never crash the listing.
        let corruptedJobID = UUID()
        let corruptedURL = await store.checkpointFileURL(for: corruptedJobID)
        try Data("this is not valid checkpoint json".utf8).write(to: corruptedURL)
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let listed = await store.listIncompleteCheckpoints()
        XCTAssertEqual(listed.map { $0.jobID }, [newerJobID, olderJobID], "Incomplete checkpoints must sort by updatedAt descending.")
        XCTAssertEqual(listed.first?.lastCompletedTileIndex, 2)
        XCTAssertEqual(listed.last?.lastCompletedTileIndex, 1)

        let loadedOlder = try await store.load(jobID: olderJobID)
        XCTAssertEqual(loadedOlder, older, "Save/load must round-trip every field.")

        do {
            _ = try await store.load(jobID: corruptedJobID)
            XCTFail("Loading a corrupted checkpoint must throw.")
        } catch let error as ScalerError {
            guard case .checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }

        let removed = await store.remove(jobID: olderJobID)
        XCTAssertTrue(removed)
        let afterRemoval = await store.listIncompleteCheckpoints()
        XCTAssertEqual(afterRemoval.map { $0.jobID }, [newerJobID])

        // `deleteJobFiles` must containment-check filenames so a corrupted checkpoint cannot delete
        // files outside the job working directory.
        let traversalJobID = UUID()
        let outsideFileName = "outside_\(traversalJobID.uuidString).txt"
        let outsideURL = directory.deletingLastPathComponent().appendingPathComponent(outsideFileName)
        try Data("must survive".utf8).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        let sisterOutputURL = directory.appendingPathComponent("traversal_output.bin")
        let sisterMetadataURL = directory.appendingPathComponent("traversal_metadata.json")
        try Data("output".utf8).write(to: sisterOutputURL)
        try Data("metadata".utf8).write(to: sisterMetadataURL)

        let traversalState = makeCheckpointState(
            jobID: traversalJobID,
            outputWidth: 128,
            outputHeight: 96,
            lastCompletedTileIndex: 0,
            totalTiles: 6,
            sourceMMapFileName: "../\(outsideFileName)",
            outputMMapFileName: "traversal_output.bin",
            metadataPacketFileName: "traversal_metadata.json"
        )
        try await store.save(traversalState)
        await store.deleteJobFiles(state: traversalState)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideURL.path),
            "PathSafety must prevent deleting files outside the working directory."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sisterOutputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sisterMetadataURL.path))
        let traversalCheckpointURL = await store.checkpointFileURL(for: traversalJobID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: traversalCheckpointURL.path))
    }

    // MARK: - Registry fallback + compute-unit mapping

    func testModelRegistryFallbackPredictorAndComputeUnitMapping() async throws {
        XCTAssertEqual(ModelExecutionTier.gpuAndANE.computeUnits.rawValue, MLComputeUnits.all.rawValue)
        XCTAssertEqual(ModelExecutionTier.cpuAndANE.computeUnits.rawValue, MLComputeUnits.cpuAndNeuralEngine.rawValue)
        XCTAssertEqual(ModelExecutionTier.cpuOnly.computeUnits.rawValue, MLComputeUnits.cpuOnly.rawValue)
        XCTAssertEqual(ModelExecutionTier.forBackgroundMode(true), .cpuAndANE)
        XCTAssertEqual(ModelExecutionTier.forBackgroundMode(false), .gpuAndANE)

        let registry = CoreMLModelRegistry(initialComputeUnits: .cpuOnly)
        let initialUnits = await registry.currentUnits()
        XCTAssertEqual(initialUnits.rawValue, MLComputeUnits.cpuOnly.rawValue)
        await registry.setExecutionTier(.cpuAndANE)
        let backgroundUnits = await registry.currentUnits()
        XCTAssertEqual(backgroundUnits.rawValue, MLComputeUnits.cpuAndNeuralEngine.rawValue)
        await registry.setExecutionTier(.cpuOnly)

        let inputHeight = 4
        let inputWidth = 6
        let inputPlaneSize = inputHeight * inputWidth
        var input = [Float16](repeating: 0, count: 3 * inputPlaneSize)
        for channel in 0..<3 {
            for y in 0..<inputHeight {
                for x in 0..<inputWidth {
                    let value = 0.05 * Float(channel + 1)
                        + 0.30 * Float(y) / Float(inputHeight)
                        + 0.20 * Float(x) / Float(inputWidth)
                    input[channel * inputPlaneSize + y * inputWidth + x] = Float16(value)
                }
            }
        }

        // Fallback resampler is deterministic, finite, correctly shaped and identity for equal dims.
        let first = try CoreMLModelRegistry.deterministicFallbackResample(
            input,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            outputHeight: 12,
            outputWidth: 18,
            modelName: "unit-test",
            tileIndex: 0
        )
        let second = try CoreMLModelRegistry.deterministicFallbackResample(
            input,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            outputHeight: 12,
            outputWidth: 18,
            modelName: "unit-test",
            tileIndex: 0
        )
        XCTAssertEqual(first.count, 3 * 12 * 18)
        XCTAssertEqual(first, second, "Fallback resampling must be deterministic.")
        XCTAssertTrue(first.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(Set(first.map { Float($0) }).count, 1)

        let identity = try CoreMLModelRegistry.deterministicFallbackResample(
            input,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            outputHeight: inputHeight,
            outputWidth: inputWidth,
            modelName: "unit-test",
            tileIndex: 0
        )
        XCTAssertEqual(identity, input, "Equal input/output dimensions must reduce to an identity copy.")

        do {
            _ = try await registry.predict(modelID: .quickSRx2_192, inputPlanarFP16: [],
                                            inputHeight: Int.max, inputWidth: Int.max,
                                            outputHeight: 384, outputWidth: 384, tileIndex: 0)
            XCTFail("Overflowing dimensions must throw before tensor arithmetic.")
        } catch let error as ScalerError {
            guard case .modelInferenceFailed = error else {
                XCTFail("Expected modelInferenceFailed, got \(error)")
                return
            }
        }

        do {
            _ = try CoreMLModelRegistry.deterministicFallbackResample(
                [Float16(1.0), Float16(2.0)],
                inputHeight: inputHeight,
                inputWidth: inputWidth,
                outputHeight: 12,
                outputWidth: 18,
                modelName: "unit-test",
                tileIndex: 0
            )
            XCTFail("A malformed planar tensor must throw.")
        } catch let error as ScalerError {
            guard case .modelInferenceFailed = error else {
                XCTFail("Expected modelInferenceFailed, got \(error)")
                return
            }
        }

        // The registry must still produce the full contract shape whether it resolves a bundled model
        // or falls back to the deterministic Lanczos path; dims match the QuickSRNet-Large x2 Tier-B contract.
        let contractInput = [Float16](repeating: 0.5, count: 3 * 192 * 192)
        let prediction = try await registry.predict(
            modelID: .quickSRx2_192,
            inputPlanarFP16: contractInput,
            inputHeight: 192,
            inputWidth: 192,
            outputHeight: 384,
            outputWidth: 384,
            tileIndex: 0
        )
        XCTAssertEqual(prediction.count, 3 * 384 * 384)
        XCTAssertTrue(prediction.allSatisfy { $0.isFinite })
    }

    // MARK: - Stage 1 fresh-job decode

    func testFreshJobStage1DecodeThroughUniversalStripDecoder() async throws {
        let directory = try makeTemporaryDirectory(label: "stage1")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Generate a 64x32 16-bit RGBA PNG (4:2 from 64x32 -> x2 output of 128x64).
        let width = 64
        let height = 32
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
        let pngURL = directory.appendingPathComponent("synthetic_64x32.png")
        let pixelData = rgba16.withUnsafeBytes { Data($0) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: pixelData as CFData),
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
              let destination = CGImageDestinationCreateWithURL(
                  pngURL as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            XCTFail("Failed to synthesize the 16-bit PNG fixture.")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            XCTFail("Failed to write the synthetic PNG.")
            return
        }

        let jobID = UUID()
        let config = UpscaleJobConfig(
            id: jobID,
            sourceImageURL: pngURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .png16Bit
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)

        let artifacts = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory,
            progressHandler: nil
        )

        XCTAssertEqual(artifacts.metadata.originalWidth, width)
        XCTAssertEqual(artifacts.metadata.originalHeight, height)
        XCTAssertEqual(artifacts.sourceBuffer.width, width)
        XCTAssertEqual(artifacts.sourceBuffer.height, height)
        XCTAssertEqual(artifacts.outputBuffer.width, width * 2)
        XCTAssertEqual(artifacts.outputBuffer.height, height * 2)
        XCTAssertEqual(artifacts.checkpoint.totalTiles, 1)
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, 0)
        XCTAssertEqual(artifacts.checkpoint.config.id, jobID)
        XCTAssertGreaterThan(nonZeroPixelCount(artifacts.outputBuffer), 0)
        XCTAssertEqual(nonZeroPixelCount(artifacts.outputBuffer), width * 2 * height * 2)

        let checkpointURL = await store.checkpointFileURL(for: jobID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
        let listed = await store.listIncompleteCheckpoints()
        XCTAssertTrue(listed.isEmpty)

        let highMemoryConfig = UpscaleJobConfig(sourceImageURL: pngURL, scaleFactor: .x2,
                                                backbone: .quickSRNet, denoiseMode: .off)
        let highMemoryArtifacts = try await executor.executeOrResumeJob(config: highMemoryConfig, overrideTier: .tierA_HighMemory)
        XCTAssertEqual(highMemoryArtifacts.checkpoint.tileConfig.inputTileSize, 256)
        XCTAssertEqual(highMemoryArtifacts.outputBuffer.width, width * 2)
        XCTAssertEqual(highMemoryArtifacts.outputBuffer.height, height * 2)
    }

    // MARK: - Small-source robustness

    /// Documented direct/test behavior: with no active execution and no registered coordinator run,
    /// `requestGracefulPause()` is the explicit unscoped Stop/test marker and the next direct
    /// (unregistered) execution honors it. `registerJobRun` retires this marker for a distinct run;
    /// see `testIdleUnscopedPauseMarkerIsRetiredByDistinctRegistration`.
    func testSmallSyntheticSourceAndPauseAtStartResume() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 64,
            sourceHeight: 48,
            scale: .x4,
            tier: .tierB_ConstrainedMemory,
            label: "small"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }

        XCTAssertEqual(job.plan.totalTiles, 1, "A 64x48 source fits in a single Tier-B tile.")
        XCTAssertEqual(job.plan.outputWidth, 256)
        XCTAssertEqual(job.plan.outputHeight, 192)

        let store = job.checkpointStore
        let executor = makeExecutor(workingDirectory: job.workingDirectory, checkpointStore: store)
        await executor.requestGracefulPause()

        do {
            _ = try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint,
                progressHandler: nil
            )
            XCTFail("A pause requested before the first tile must be honored.")
            return
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let completedTileIndex) = error else {
                XCTFail("Unexpected ScalerError: \(error)")
                return
            }
            XCTAssertEqual(completedTileIndex, -1, "Pausing before the first tile reports the initial checkpoint index.")
        } catch {
            XCTFail("Unexpected error: \(error)")
            return
        }

        let pausedState = try await store.load(jobID: job.jobID)
        XCTAssertEqual(pausedState.lastCompletedTileIndex, -1)

        let resumedArtifacts = try await makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: store
        ).executeOrResumeJob(
            config: job.config,
            existingCheckpoint: pausedState,
            progressHandler: nil
        )

        XCTAssertEqual(resumedArtifacts.outputBuffer.width, 256)
        XCTAssertEqual(resumedArtifacts.outputBuffer.height, 192)
        XCTAssertEqual(resumedArtifacts.checkpoint.lastCompletedTileIndex, 0)
        XCTAssertEqual(resumedArtifacts.checkpoint.totalTiles, 1)

        // Every pixel inside the small output canvas must be finite and the image must be non-empty.
        for (x, y) in [(0, 0), (255, 0), (0, 191), (255, 191), (128, 96)] {
            let pixel = resumedArtifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
            for channel in 0..<4 {
                XCTAssertTrue(Float(pixel[channel]).isFinite)
            }
        }
        XCTAssertGreaterThan(nonZeroPixelCount(resumedArtifacts.outputBuffer), 0)
        XCTAssertEqual(nonZeroPixelCount(resumedArtifacts.outputBuffer), 256 * 192)
    }

    // MARK: - Durable per-tile undo transaction

    func testDurableTileTransactionRecoveryIsExactAtEveryInterruptionPoint() async throws {
        let points: [TransactionInterruptionPoint] = [
            .afterJournalPublished,
            .afterCanvasMutation,
            .afterCanvasFlushBeforeCheckpoint,
            .afterCheckpointBeforeJournalCleanup,
        ]
        for point in points {
            try await verifyTransactionRecovery(after: point)
        }
    }

    /// Runs a 6-tile job, throws at `point` for the second tile, then resumes from the checkpoint left
    /// on disk (equivalent to a relaunch) and compares every pixel with an uninterrupted baseline.
    /// Exact equality proves the uncommitted tile was rolled back, not blended a second time.
    private func verifyTransactionRecovery(after point: TransactionInterruptionPoint) async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "transaction-\(point)"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let store = job.checkpointStore

        let interruptedExecutor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: store
        )
        let injector = TransactionInterruptionInjector(target: point, skipCount: 1)
        await interruptedExecutor.setTransactionInterruptionHookForTesting(injector.hook)

        do {
            _ = try await interruptedExecutor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint,
                progressHandler: nil
            )
            XCTFail("Interruption at \(point) must abort the run.")
            return
        } catch let error as InjectedTransactionInterruption {
            XCTAssertEqual(error.point, point)
        }
        XCTAssertTrue(injector.didThrow, "The injector must have fired at \(point).")

        let committed = try await store.load(jobID: job.jobID)
        let pendingJournals = try journalFileNames(in: job.workingDirectory, jobID: job.jobID)
        XCTAssertEqual(
            pendingJournals.count,
            2,
            "Exactly one undo+manifest journal must remain pending at \(point): \(pendingJournals)"
        )
        XCTAssertEqual(committed.totalTiles, 6)
        switch point {
        case .afterCheckpointBeforeJournalCleanup:
            XCTAssertEqual(committed.lastCompletedTileIndex, 1, "The checkpoint commit must already be durable.")
        default:
            XCTAssertEqual(committed.lastCompletedTileIndex, 0, "Only the fully committed tile may be recorded.")
        }

        // Fresh executor == app relaunch. Resume must roll back the uncommitted tile and replay it once.
        let resumed = try await makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: store
        ).executeOrResumeJob(
            config: job.config,
            existingCheckpoint: committed,
            progressHandler: nil
        )
        XCTAssertEqual(resumed.checkpoint.lastCompletedTileIndex, 5)
        XCTAssertTrue(
            try journalFileNames(in: job.workingDirectory, jobID: job.jobID).isEmpty,
            "Completed recovery must leave no journal sidecars."
        )

        let baselineJob = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "transaction-baseline-\(point)"
        )
        defer { try? FileManager.default.removeItem(at: baselineJob.workingDirectory) }
        let baseline = try await makeExecutor(
            workingDirectory: baselineJob.workingDirectory,
            checkpointStore: baselineJob.checkpointStore
        ).executeOrResumeJob(
            config: baselineJob.config,
            existingCheckpoint: baselineJob.checkpoint,
            progressHandler: nil
        )

        XCTAssertEqual(resumed.outputBuffer.width, baseline.outputBuffer.width)
        XCTAssertEqual(resumed.outputBuffer.height, baseline.outputBuffer.height)
        let difference = maxPixelDifference(resumed.outputBuffer, baseline.outputBuffer)
        XCTAssertEqual(
            difference,
            0,
            "Recovery after \(point) must match the uninterrupted canvas exactly; a double blend changes seams (max diff \(difference))."
        )
    }

    func testResumeRejectsCorruptJournalWithoutModifyingOutputOrGrowingFiles() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "corrupt-journal"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let store = job.checkpointStore

        let executor = makeExecutor(workingDirectory: job.workingDirectory, checkpointStore: store)
        let injector = TransactionInterruptionInjector(target: .afterCanvasFlushBeforeCheckpoint, skipCount: 1)
        await executor.setTransactionInterruptionHookForTesting(injector.hook)
        do {
            _ = try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint,
                progressHandler: nil
            )
            XCTFail("Expected an injected interruption.")
            return
        } catch let error as InjectedTransactionInterruption {
            XCTAssertEqual(error.point, .afterCanvasFlushBeforeCheckpoint)
        }

        let committed = try await store.load(jobID: job.jobID)
        XCTAssertEqual(committed.lastCompletedTileIndex, 0)
        let journal = TileUndoJournal(workingDirectory: job.workingDirectory)
        let records = try journal.scan(jobID: job.jobID)
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.manifest.tileIndex, 1)

        let originalUndo = try Data(contentsOf: record.undoURL)
        let originalManifest = try Data(contentsOf: record.manifestURL)
        let canvasBefore = snapshotPixels(job.outputBuffer)
        let canvasByteSize = try fileSize(job.outputBuffer.fileURL)
        let metadataURL = job.workingDirectory.appendingPathComponent(committed.metadataPacketFileName)
        let metadataBefore = try Data(contentsOf: metadataURL)
        var incomingConfig = job.config
        incomingConfig.sessionState = PipelineSessionState(isDenoised: true, isUpscaled: true, upscaleFactor: 2)

        func assertResumeRejected(_ label: String, expectedUndoSize: Int?) async throws {
            do {
                _ = try await makeExecutor(
                    workingDirectory: job.workingDirectory,
                    checkpointStore: store
                ).executeOrResumeJob(
                    config: incomingConfig,
                    existingCheckpoint: committed,
                    progressHandler: nil
                )
                XCTFail("Corrupt journal (\(label)) must be rejected.")
            } catch let error as ScalerError {
                guard case .checkpointCorrupted = error else {
                    XCTFail("Expected checkpointCorrupted for \(label), got \(error)")
                    return
                }
            }
            XCTAssertEqual(
                snapshotPixels(job.outputBuffer),
                canvasBefore,
                "A rejected journal (\(label)) must not modify the output canvas."
            )
            XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore,
                "A rejected journal (\(label)) must not publish incoming handoff/history metadata.")
            XCTAssertEqual(
                try fileSize(job.outputBuffer.fileURL),
                canvasByteSize,
                "A rejected journal (\(label)) must not grow the output canvas."
            )
            if let expectedUndoSize {
                XCTAssertEqual(
                    try fileSize(record.undoURL),
                    expectedUndoSize,
                    "A rejected journal (\(label)) must not rewrite or grow the undo sidecar."
                )
            }
        }

        // Truncated undo bytes: the rejection must leave the truncated file exactly as-is.
        try Data(originalUndo.prefix(9)).write(to: record.undoURL)
        try await assertResumeRejected("truncated undo", expectedUndoSize: 9)
        XCTAssertEqual(try fileSize(record.undoURL), 9)

        // Digest mismatch with the original size.
        var flipped = originalUndo
        flipped[0] ^= 0xFF
        try flipped.write(to: record.undoURL)
        try await assertResumeRejected("digest mismatch", expectedUndoSize: originalUndo.count)

        // Manifest claims a journal whose undo bytes are gone.
        try originalManifest.write(to: record.manifestURL)
        try FileManager.default.removeItem(at: record.undoURL)
        try await assertResumeRejected("missing undo", expectedUndoSize: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.undoURL.path))

        // Two uncommitted journals cannot result from the correct ordering: fail safely.
        try originalUndo.write(to: record.undoURL)
        let tileIndex = 2
        let planTile = job.plan.tiles[tileIndex]
        let rect = try XCTUnwrap(TileJournalRect.clipped(
            destX: planTile.outputOriginX,
            destY: planTile.outputOriginY,
            size: planTile.outputSize,
            canvasWidth: job.plan.outputWidth,
            canvasHeight: job.plan.outputHeight
        ))
        _ = try journal.publish(
            jobID: job.jobID,
            tileIndex: tileIndex,
            rect: rect,
            from: job.outputBuffer
        )
        try await assertResumeRejected("unexpected second journal", expectedUndoSize: originalUndo.count)
    }

    // MARK: - Frozen Group D pause API

    func testRequestGracefulPauseAndWaitReturnsOnlyAfterDurablePause() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "pause-and-wait"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let store = job.checkpointStore
        let executor = makeExecutor(workingDirectory: job.workingDirectory, checkpointStore: store)
        let recorder = ProgressRecorder()

        let run = Task {
            try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint,
                progressHandler: { recorder.record($0) }
            )
        }

        // Let at least one tile commit so the pause cannot be the pre-first-tile boundary.
        var observedCommit: JobCheckpointState?
        for _ in 0..<800 {
            if let state = try? await store.load(jobID: job.jobID), state.lastCompletedTileIndex >= 0 {
                observedCommit = state
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let observed = try XCTUnwrap(observedCommit, "The tile loop must commit a tile before the pause request.")

        await executor.requestGracefulPauseAndWait()

        do {
            _ = try await run.value
            XCTFail("Expected a graceful pause.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let pausedIndex) = error else {
                XCTFail("Expected jobPausedForBackgroundExpiration, got \(error)")
                return
            }
            let persisted = try await store.load(jobID: job.jobID)
            XCTAssertEqual(persisted.lastCompletedTileIndex, pausedIndex)
            XCTAssertGreaterThanOrEqual(pausedIndex, observed.lastCompletedTileIndex)
            XCTAssertTrue(
                try journalFileNames(in: job.workingDirectory, jobID: job.jobID).isEmpty,
                "`requestGracefulPauseAndWait` must only return after the journal has been cleaned up."
            )
            let pauseUpdates = recorder.updates.filter { $0.stage == .pausedOnDisk }
            XCTAssertEqual(pauseUpdates.last?.completedTiles, pausedIndex + 1)
        }
    }

    func testIdlePauseWaitReturnsAndClearPauseRequestAllowsResume() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "pause-idle"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let store = job.checkpointStore
        let executor = makeExecutor(workingDirectory: job.workingDirectory, checkpointStore: store)

        let returned = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(returned, "requestGracefulPauseAndWait must return immediately when no job is active.")
        await executor.clearPauseRequest()

        let artifacts = try await executor.executeOrResumeJob(
            config: job.config,
            existingCheckpoint: job.checkpoint,
            progressHandler: nil
        )
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, 5)
    }

    private func requestPauseAndWaitWithTimeout(
        _ executor: TiledPipelineExecutor,
        seconds: Double
    ) async -> Bool {
        let flag = CompletionFlag()
        let task = Task {
            await executor.requestGracefulPauseAndWait()
            flag.set()
        }
        let pollCount = max(1, Int(seconds * 200))
        for _ in 0..<pollCount {
            if flag.value {
                task.cancel()
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        return flag.value
    }

    func testScopedPauseFromSupersededOwnerCannotPauseReplacementRun() async throws {
        let jobA = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "scoped-pause-superseded-A"
        )
        defer { try? FileManager.default.removeItem(at: jobA.workingDirectory) }
        // A real replacement job: distinct job ID, config, checkpoint and canvases in the same
        // executor directory. Executing A under B's registered identity is exactly what E2 forbids.
        let jobB = try await makeSyntheticJob(
            sourceWidth: 320,
            sourceHeight: 240,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "scoped-pause-superseded-B",
            in: jobA.workingDirectory
        )
        XCTAssertNotEqual(jobA.jobID, jobB.jobID)
        let executor = makeExecutor(
            workingDirectory: jobA.workingDirectory,
            checkpointStore: jobA.checkpointStore
        )
        let ownerA = ExecutionPauseOwner(jobID: jobA.jobID, generation: 1)
        await executor.registerJobRun(ownerA)
        let armed = await executor.requestGracefulPauseAndWait(ifOwner: ownerA)
        XCTAssertTrue(armed, "An idle matching run may arm a pause for its own next execution.")

        // Registering a newer run must discard the previous owner's queued pause.
        let ownerB = ExecutionPauseOwner(jobID: jobB.jobID, generation: 2)
        await executor.registerJobRun(ownerB)
        let stale = await executor.requestGracefulPauseAndWait(ifOwner: ownerA)
        XCTAssertFalse(stale, "A stale owner must be refused without side effects.")

        // The superseded A execution is refused explicitly instead of being attributed to B.
        do {
            _ = try await executor.executeOrResumeJob(
                config: jobA.config,
                existingCheckpoint: jobA.checkpoint
            )
            XCTFail("A stale A execution must not run under B's registered identity.")
        } catch let error as ScalerError {
            guard case .executionOwnerMismatch(let submitted, let registered) = error else { throw error }
            XCTAssertEqual(submitted, jobA.jobID)
            XCTAssertEqual(registered, jobB.jobID)
        }

        // B's own real config/checkpoint executes and is not paused by A's superseded pause.
        let artifacts = try await executor.executeOrResumeJob(
            config: jobB.config,
            existingCheckpoint: jobB.checkpoint
        )
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, jobB.plan.totalTiles - 1,
                       "The superseded owner's pause must not pause the real replacement execution.")
    }

    func testQueuedScopedPauseForReplacementIsNotResolvedByOutgoingExecution() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "scoped-pause-queued-replacement"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let executor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: job.checkpointStore
        )
        let ownerA = ExecutionPauseOwner(jobID: job.jobID, generation: 1)
        await executor.registerJobRun(ownerA)
        let runA = Task {
            try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint
            )
        }

        // Wait until A has genuinely started and committed at least one tile.
        var didStart = false
        for _ in 0..<800 {
            if let state = try? await job.checkpointStore.load(jobID: job.jobID),
               state.lastCompletedTileIndex >= 0 {
                didStart = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(didStart, "The outgoing run must be active before the replacement registers.")

        let ownerB = ExecutionPauseOwner(jobID: UUID(), generation: 2)
        await executor.registerJobRun(ownerB)
        let result = ScopedPauseResult()
        let queuedPause = Task {
            let value = await executor.requestGracefulPauseAndWait(ifOwner: ownerB)
            result.set(value)
        }

        let completedA = try await runA.value
        XCTAssertEqual(completedA.checkpoint.lastCompletedTileIndex, job.plan.totalTiles - 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(result.value,
                     "B's queued pause must not be resolved by A's stable boundary; B has not executed yet.")
        XCTAssertFalse(queuedPause.isCancelled)

        // Superseding B must answer its queued wait with `false` and leave no stale pause behind.
        let ownerC = ExecutionPauseOwner(jobID: UUID(), generation: 3)
        await executor.registerJobRun(ownerC)
        _ = await queuedPause.value
        XCTAssertEqual(result.value, false)
    }

    // MARK: - E1: unscoped pause lifecycle

    func testIdleResetBeforeAnyJobDoesNotLeavePersistablePause() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "idle-reset-no-owner"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let executor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: job.checkpointStore
        )

        // `StudioViewModel.resetSession` calls this unconditionally, including before any job exists.
        let first = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(first, "An idle reset with no registered run must return immediately.")
        let second = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(second, "A repeated idle reset must stay an immediate no-op.")

        // The next registered run is a distinct lifecycle and must start unpaused.
        await executor.registerJobRun(ExecutionPauseOwner(jobID: job.jobID, generation: 1))
        let artifacts = try await executor.executeOrResumeJob(
            config: job.config,
            existingCheckpoint: job.checkpoint
        )
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, job.plan.totalTiles - 1,
                       "An idle reset must not leave a pause that stops the next registered run.")
    }

    func testPauseForCurrentRegisteredRunBeforeExecuteIsHonored() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "pause-registered-before-execute"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let executor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: job.checkpointStore
        )
        let owner = ExecutionPauseOwner(jobID: job.jobID, generation: 1)
        await executor.registerJobRun(owner)

        // A legitimate Stop/reset between registration and executor entry binds to the current run.
        let armed = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(armed, "The pre-execution pause must return immediately; it has no tile loop to wait for.")

        do {
            _ = try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint
            )
            XCTFail("A pause armed for the current registered run must pause before its first tile.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let index) = error else { throw error }
            XCTAssertEqual(index, -1)
        }
    }

    func testSameOwnerReRegistrationPreservesPauseBeforeExecute() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "pause-same-owner-register"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let executor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: job.checkpointStore
        )
        let owner = ExecutionPauseOwner(jobID: job.jobID, generation: 1)
        await executor.registerJobRun(owner)
        let armed = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(armed)

        // Idempotent same-owner re-registration must not clear the run's own legitimate pause.
        await executor.registerJobRun(owner)

        do {
            _ = try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint
            )
            XCTFail("Same-owner re-registration must preserve the current run's pause.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let index) = error else { throw error }
            XCTAssertEqual(index, -1)
        }
    }

    func testDistinctOwnerRegistrationRetiresCurrentRunPause() async throws {
        let jobA = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "distinct-owner-retires-A"
        )
        defer { try? FileManager.default.removeItem(at: jobA.workingDirectory) }
        let jobB = try await makeSyntheticJob(
            sourceWidth: 320,
            sourceHeight: 240,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "distinct-owner-retires-B",
            in: jobA.workingDirectory
        )
        let executor = makeExecutor(
            workingDirectory: jobA.workingDirectory,
            checkpointStore: jobA.checkpointStore
        )
        let ownerA = ExecutionPauseOwner(jobID: jobA.jobID, generation: 1)
        let ownerB = ExecutionPauseOwner(jobID: jobB.jobID, generation: 2)
        await executor.registerJobRun(ownerA)
        let armed = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(armed)

        await executor.registerJobRun(ownerB)
        let stale = await executor.requestGracefulPauseAndWait(ifOwner: ownerA)
        XCTAssertFalse(stale, "The superseded owner's pause and waiter must be retired.")

        // B is a distinct run: A's old idle pause cannot target it.
        let artifacts = try await executor.executeOrResumeJob(
            config: jobB.config,
            existingCheckpoint: jobB.checkpoint
        )
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, jobB.plan.totalTiles - 1)
    }

    func testActiveUnscopedStopWaitsForRegisteredRunStableBoundary() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "active-unscoped-stop"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let store = job.checkpointStore
        let executor = makeExecutor(workingDirectory: job.workingDirectory, checkpointStore: store)
        let owner = ExecutionPauseOwner(jobID: job.jobID, generation: 1)
        await executor.registerJobRun(owner)

        let run = Task {
            try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint
            )
        }
        var observed: JobCheckpointState?
        for _ in 0..<800 {
            if let state = try? await store.load(jobID: job.jobID), state.lastCompletedTileIndex >= 0 {
                observed = state
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let observedCommit = try XCTUnwrap(observed, "The run must commit a tile before the Stop.")

        // The unscoped Stop binds to the registered active run and waits for its own boundary.
        await executor.requestGracefulPauseAndWait()

        do {
            _ = try await run.value
            XCTFail("Expected a graceful pause from the active unscoped Stop.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let pausedIndex) = error else { throw error }
            let persisted = try await store.load(jobID: job.jobID)
            XCTAssertEqual(persisted.lastCompletedTileIndex, pausedIndex)
            XCTAssertGreaterThanOrEqual(pausedIndex, observedCommit.lastCompletedTileIndex)
            XCTAssertTrue(
                try journalFileNames(in: job.workingDirectory, jobID: job.jobID).isEmpty,
                "The Stop waiter must only return after the journal has been cleaned up."
            )
        }
    }

    // MARK: - E1: documented direct/test unscoped marker

    func testDirectUnscopedPauseMarkerAppliesToNextDirectExecution() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "direct-unscoped-marker"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let executor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: job.checkpointStore
        )

        // With neither an active execution nor a registered run, `requestGracefulPause()` is the
        // explicit direct/test marker and the next direct unregistered execution honors it.
        await executor.requestGracefulPause()
        do {
            _ = try await executor.executeOrResumeJob(
                config: job.config,
                existingCheckpoint: job.checkpoint
            )
            XCTFail("A direct/test pause marker must pause the next direct execution before tile 0.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let index) = error else { throw error }
            XCTAssertEqual(index, -1)
        }
    }

    func testIdleUnscopedPauseMarkerIsRetiredByDistinctRegistration() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "idle-marker-retired"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let executor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: job.checkpointStore
        )

        // An explicit direct/test marker has no ownership over a run registered afterwards.
        await executor.requestGracefulPause()
        await executor.registerJobRun(ExecutionPauseOwner(jobID: job.jobID, generation: 1))

        let artifacts = try await executor.executeOrResumeJob(
            config: job.config,
            existingCheckpoint: job.checkpoint
        )
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, job.plan.totalTiles - 1,
                       "Registration must retire an idle unscoped marker instead of pausing a new run.")
    }

    // MARK: - E2: execution/job identity

    func testSameJobNewerGenerationRegistrationResumesWithoutMismatch() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "same-job-newer-generation"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }
        let executor = makeExecutor(
            workingDirectory: job.workingDirectory,
            checkpointStore: job.checkpointStore
        )
        let gen1 = ExecutionPauseOwner(jobID: job.jobID, generation: 1)
        await executor.registerJobRun(gen1)
        let armed = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(armed)

        let gen2 = ExecutionPauseOwner(jobID: job.jobID, generation: 2)
        await executor.registerJobRun(gen2)
        let stale = await executor.requestGracefulPauseAndWait(ifOwner: gen1)
        XCTAssertFalse(stale, "The newer same-job generation replaced the paused lifecycle.")

        let artifacts = try await executor.executeOrResumeJob(
            config: job.config,
            existingCheckpoint: job.checkpoint
        )
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, job.plan.totalTiles - 1,
                       "A same-job resume under the current owner must still execute.")
    }

    func testEqualGenerationConflictingRegistrationKeepsCurrentOwnerAndPause() async throws {
        let jobA = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "equal-generation-A"
        )
        defer { try? FileManager.default.removeItem(at: jobA.workingDirectory) }
        let jobB = try await makeSyntheticJob(
            sourceWidth: 320,
            sourceHeight: 240,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "equal-generation-B",
            in: jobA.workingDirectory
        )
        let executor = makeExecutor(
            workingDirectory: jobA.workingDirectory,
            checkpointStore: jobA.checkpointStore
        )
        let ownerA = ExecutionPauseOwner(jobID: jobA.jobID, generation: 1)
        let ownerB = ExecutionPauseOwner(jobID: jobB.jobID, generation: 1)
        await executor.registerJobRun(ownerA)
        let armed = await requestPauseAndWaitWithTimeout(executor, seconds: 2.0)
        XCTAssertTrue(armed)

        // Conflicting equal-generation identities must not silently trade places.
        await executor.registerJobRun(ownerB)

        do {
            _ = try await executor.executeOrResumeJob(
                config: jobB.config,
                existingCheckpoint: jobB.checkpoint
            )
            XCTFail("An equal-generation conflicting registration must not replace the current owner.")
        } catch let error as ScalerError {
            guard case .executionOwnerMismatch(let submitted, let registered) = error else { throw error }
            XCTAssertEqual(submitted, jobB.jobID)
            XCTAssertEqual(registered, jobA.jobID)
        }

        // A is still current, so A's legitimate pre-execution pause is still armed.
        do {
            _ = try await executor.executeOrResumeJob(
                config: jobA.config,
                existingCheckpoint: jobA.checkpoint
            )
            XCTFail("A's pause must survive the conflicting equal-generation registration.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let index) = error else { throw error }
            XCTAssertEqual(index, -1)
        }
    }

    func testLowerGenerationRegistrationCannotOverwriteNewerOwner() async throws {
        let jobA = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "lower-generation-A"
        )
        defer { try? FileManager.default.removeItem(at: jobA.workingDirectory) }
        let jobB = try await makeSyntheticJob(
            sourceWidth: 320,
            sourceHeight: 240,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "lower-generation-B",
            in: jobA.workingDirectory
        )
        let executor = makeExecutor(
            workingDirectory: jobA.workingDirectory,
            checkpointStore: jobA.checkpointStore
        )
        let ownerB = ExecutionPauseOwner(jobID: jobB.jobID, generation: 5)
        await executor.registerJobRun(ownerB)
        await executor.registerJobRun(ExecutionPauseOwner(jobID: jobA.jobID, generation: 4))

        do {
            _ = try await executor.executeOrResumeJob(
                config: jobA.config,
                existingCheckpoint: jobA.checkpoint
            )
            XCTFail("A lower-generation registration must not overwrite the newer owner.")
        } catch let error as ScalerError {
            guard case .executionOwnerMismatch(let submitted, let registered) = error else { throw error }
            XCTAssertEqual(submitted, jobA.jobID)
            XCTAssertEqual(registered, jobB.jobID)
        }

        let artifacts = try await executor.executeOrResumeJob(
            config: jobB.config,
            existingCheckpoint: jobB.checkpoint
        )
        XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex, jobB.plan.totalTiles - 1)
    }

    func testDirectUnregisteredExecutionAcceptsGenerationZeroOwnerReplacement() async throws {
        let jobA = try await makeSyntheticJob(
            sourceWidth: 400,
            sourceHeight: 300,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "direct-gen-zero-A"
        )
        defer { try? FileManager.default.removeItem(at: jobA.workingDirectory) }
        let jobB = try await makeSyntheticJob(
            sourceWidth: 320,
            sourceHeight: 240,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "direct-gen-zero-B",
            in: jobA.workingDirectory
        )
        let executor = makeExecutor(
            workingDirectory: jobA.workingDirectory,
            checkpointStore: jobA.checkpointStore
        )

        // No coordinator registration: a generation-0 direct owner must not block another direct job.
        let a = try await executor.executeOrResumeJob(
            config: jobA.config,
            existingCheckpoint: jobA.checkpoint
        )
        XCTAssertEqual(a.checkpoint.lastCompletedTileIndex, jobA.plan.totalTiles - 1)
        let b = try await executor.executeOrResumeJob(
            config: jobB.config,
            existingCheckpoint: jobB.checkpoint
        )
        XCTAssertEqual(b.checkpoint.lastCompletedTileIndex, jobB.plan.totalTiles - 1)
    }

    func testStaleJobEntryCannotConsumeReplacementPauseOrResolveItsWaiter() async throws {
        // A is large enough to stay active while B registers and queues its pause.
        let jobA = try await makeSyntheticJob(
            sourceWidth: 1024,
            sourceHeight: 768,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "stale-entry-A"
        )
        defer { try? FileManager.default.removeItem(at: jobA.workingDirectory) }
        let jobB = try await makeSyntheticJob(
            sourceWidth: 320,
            sourceHeight: 240,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "stale-entry-B",
            in: jobA.workingDirectory
        )
        let executor = makeExecutor(
            workingDirectory: jobA.workingDirectory,
            checkpointStore: jobA.checkpointStore
        )
        let ownerA = ExecutionPauseOwner(jobID: jobA.jobID, generation: 1)
        await executor.registerJobRun(ownerA)
        let runA = Task {
            try await executor.executeOrResumeJob(
                config: jobA.config,
                existingCheckpoint: jobA.checkpoint
            )
        }

        var didStart = false
        for _ in 0..<1000 {
            if let state = try? await jobA.checkpointStore.load(jobID: jobA.jobID),
               state.lastCompletedTileIndex >= 0 {
                didStart = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(didStart, "A must be actively executing before the replacement registers.")

        let ownerB = ExecutionPauseOwner(jobID: jobB.jobID, generation: 2)
        await executor.registerJobRun(ownerB)
        let result = ScopedPauseResult()
        let queuedPause = Task {
            result.set(await executor.requestGracefulPauseAndWait(ifOwner: ownerB))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(result.value, "B's pause is queued behind the still-active A run.")

        // A stale A entry after B's registration is refused explicitly and mutates nothing.
        do {
            _ = try await executor.executeOrResumeJob(
                config: jobA.config,
                existingCheckpoint: jobA.checkpoint
            )
            XCTFail("A stale A entry after B's registration must be refused.")
        } catch let error as ScalerError {
            guard case .executionOwnerMismatch(let submitted, let registered) = error else { throw error }
            XCTAssertEqual(submitted, jobA.jobID)
            XCTAssertEqual(registered, jobB.jobID)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(result.value, "A stale entry must not consume B's armed pause or answer B's waiter.")

        // Draining A must not be reported as B's stable boundary either.
        runA.cancel()
        _ = try? await runA.value
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(result.value, "A's boundary must never resolve B's queued waiter.")

        // B's real config/checkpoint honors its own pause and resolves its own waiter.
        do {
            _ = try await executor.executeOrResumeJob(
                config: jobB.config,
                existingCheckpoint: jobB.checkpoint
            )
            XCTFail("B's own queued pause must apply to B's real execution.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration(let index) = error else { throw error }
            XCTAssertEqual(index, -1)
        }
        _ = await queuedPause.value
        XCTAssertEqual(result.value, true, "B must reach its own stable boundary when it honors its pause.")
    }

    func testLegacyCheckpointJSONDecodesTransactionDefaults() async throws {
        let job = try await makeSyntheticJob(
            sourceWidth: 64,
            sourceHeight: 48,
            scale: .x2,
            tier: .tierB_ConstrainedMemory,
            label: "legacy-checkpoint"
        )
        defer { try? FileManager.default.removeItem(at: job.workingDirectory) }

        let encoded = try JSONEncoder().encode(job.checkpoint)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["globalMaxLinearComponent"])
        XCTAssertNotNil(object["transactionJournalVersion"])
        object.removeValue(forKey: "globalMaxLinearComponent")
        object.removeValue(forKey: "transactionJournalVersion")

        let legacy = try JSONDecoder().decode(
            JobCheckpointState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(legacy.globalMaxLinearComponent, legacy.globalMaxLuminance)
        XCTAssertEqual(legacy.transactionJournalVersion, JobCheckpointState.currentTransactionJournalVersion)
        XCTAssertEqual(legacy, job.checkpoint)
    }

    // MARK: - Recovery helpers

    private func snapshotPixels(_ buffer: MMapBuffer) -> [Float16] {
        var pixels = [Float16](repeating: 0, count: buffer.width * buffer.height * 4)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let source = buffer.unsafePixelPointer(x: x, y: y)
                let offset = (y * buffer.width + x) * 4
                pixels[offset] = source[0]
                pixels[offset + 1] = source[1]
                pixels[offset + 2] = source[2]
                pixels[offset + 3] = source[3]
            }
        }
        return pixels
    }

    private func journalFileNames(in directory: URL, jobID: UUID) throws -> [String] {
        let prefix = "journal_\(jobID.uuidString)_"
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries
            .map { $0.lastPathComponent }
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }
}

// MARK: - Repair-cycle regressions: R1 saturated HDR + executor half of R6

/// End-to-end regressions for the two reviewed executor/color findings:
///
/// * **R1** — the real executor must normalize by the decoded RGB *component* peak, not luminance.
///   A saturated red of 4.0 has luminance ~0.916, so the previous denominator of 1.0 clipped it.
///   The fixture is the reviewer's real bridge-produced 64x64 `H=4` Linear DNG (copied under
///   `Fixtures/`); the only peak oracle is the checkpoint/decoder value, never a manual constant.
/// * **R6** — `UpscaleJobConfig.sessionState` must be merged into the decoded/loaded metadata
///   *before* the denoise decision and must survive pause/resume, while `didRunDenoise` stays
///   truthful about what this job actually ran.
final class PipelineHDRAndSessionStateTests: XCTestCase {
    private struct FixtureError: Error {
        let message: String
    }

    /// Real decoder telemetry for the saturated fixture: the red quadrant is 4.0, so the luminance
    /// peak is only `0.22897456 * 4 ≈ 0.916` (floored at 1.0 by the decoder).
    private let expectedComponentPeak: Float = 4.0
    private let expectedLuminancePeak: Float = 1.0

    // MARK: Fixtures / executors

    private func makeTemporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineHDRAndSession_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Committed copy of the reviewer's real bridge-produced saturated-HDR Linear DNG (`H = 4`,
    /// 64x64: top-right quadrant is red 4.0, top-left neutral 0.5, bottom half neutral 1.0).
    private func saturatedHDRFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("saturatedComponentPeak.dng", isDirectory: false)
    }

    private func makeExecutor(
        workingDirectory: URL,
        checkpointStore: JobCheckpointStore,
        metalColor: Bool = false
    ) -> TiledPipelineExecutor {
        TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: CoreMLModelRegistry(
                initialComputeUnits: .cpuOnly,
                availabilityPolicy: .allowDeterministicFallback
            ),
            checkpointStore: checkpointStore,
            colorProcessor: MetalColorProcessor(preferMetal: metalColor)
        )
    }

    private func makeSaturatedHDRConfig() -> UpscaleJobConfig {
        UpscaleJobConfig(
            sourceImageURL: saturatedHDRFixtureURL(),
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0,
            exportFormat: .linearDNG16Bit
        )
    }

    private func makeJPEGConfig(
        url: URL,
        denoiseMode: DenoiseMode,
        sessionState: PipelineSessionState? = nil
    ) -> UpscaleJobConfig {
        UpscaleJobConfig(
            sourceImageURL: url,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: denoiseMode,
            naturalGrainAmount: 0,
            exportFormat: .jpeg95,
            sessionState: sessionState
        )
    }

    private func writeJPEG(
        at url: URL,
        width: Int,
        height: Int,
        exifUserComment: String?
    ) throws {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                rgba[offset + 0] = UInt8((x * 255) / max(1, width - 1))
                rgba[offset + 1] = UInt8((y * 255) / max(1, height - 1))
                rgba[offset + 2] = 96
                rgba[offset + 3] = 255
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            throw FixtureError(message: "Failed to synthesize the JPEG fixture at \(url.path)")
        }
        var properties: [CFString: Any] = [:]
        if let exifUserComment {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: exifUserComment,
            ]
        }
        CGImageDestinationAddImage(destination, image, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError(message: "Failed to finalize the JPEG fixture at \(url.path)")
        }
    }

    // MARK: Assertions

    private func assertInteriorSaturatedRed(_ buffer: MMapBuffer, label: String) {
        // 2x output of the 64x64 fixture: the interior of the top-right red-4 quadrant maps to
        // output (80, 10), exactly where the reviewer's direct probe looks.
        let pixel = buffer.unsafePixelPointer(x: 80, y: 10)
        print("[GroupB] \(label) interior(80,10) = (\(pixel[0]), \(pixel[1]), \(pixel[2]), \(pixel[3]))")
        XCTAssertEqual(Float(pixel[0]), expectedComponentPeak, accuracy: 0.05,
                       "\(label): interior red-4 patch was clipped or rescaled")
        XCTAssertEqual(Float(pixel[1]), 0, accuracy: 0.01, "\(label): red patch gained green")
        XCTAssertEqual(Float(pixel[2]), 0, accuracy: 0.01, "\(label): red patch gained blue")
    }

    /// Locates the canvas maximum nonnegative R/G/B component. Bicubic chroma interpolation legitimately
    /// overshoots across the red/neutral quadrant edge (Catmull-Rom is not monotonic), so the export
    /// headroom pre-pass may legitimately measure > 4.0 even though the interior patch is exactly 4.0.
    private func maxComponent(_ buffer: MMapBuffer) -> (value: Float, x: Int, y: Int) {
        var maximum: Float = 0
        var location = (x: 0, y: 0)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                for channel in 0..<3 {
                    let value = Float(pixel[channel])
                    if value.isFinite && value > maximum {
                        maximum = value
                        location = (x, y)
                    }
                }
            }
        }
        return (maximum, location.x, location.y)
    }

    private func maxPixelDifference(_ lhs: MMapBuffer, _ rhs: MMapBuffer) -> Float {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return .infinity }
        var maximum: Float = 0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                let left = lhs.unsafePixelPointer(x: x, y: y)
                let right = rhs.unsafePixelPointer(x: x, y: y)
                for channel in 0..<4 {
                    let a = Float(left[channel])
                    let b = Float(right[channel])
                    if a.isNaN || b.isNaN { return .infinity }
                    maximum = max(maximum, abs(a - b))
                }
            }
        }
        return maximum
    }

    private func runExpectingPause(
        _ executor: TiledPipelineExecutor,
        config: UpscaleJobConfig,
        existingCheckpoint: JobCheckpointState? = nil
    ) async throws {
        do {
            _ = try await executor.executeOrResumeJob(
                config: config,
                existingCheckpoint: existingCheckpoint,
                overrideTier: .tierB_ConstrainedMemory
            )
            XCTFail("Expected the executor to pause gracefully.")
        } catch let error as ScalerError {
            guard case .jobPausedForBackgroundExpiration = error else { throw error }
        }
    }

    private func checkpointObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError(message: "Checkpoint JSON was not an object at \(url.path)")
        }
        return object
    }

    private func writeCheckpointObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - R1: fresh pipeline

    func testCodexReviewActualPipelinePreservesSaturatedComponentPeak() async throws {
        let directory = try makeTemporaryDirectory(label: "fresh")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.switchExecutionTier(.cpuOnly)
        let config = makeSaturatedHDRConfig()

        let artifacts = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )

        // The checkpoint must record the decoded *component* peak and keep luminance separate telemetry.
        XCTAssertEqual(artifacts.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01,
                       "The production caller dropped the decoded component peak.")
        XCTAssertEqual(artifacts.checkpoint.globalMaxLuminance, expectedLuminancePeak, accuracy: 0.01,
                       "Luminance telemetry must stay distinct from the component denominator.")
        XCTAssertGreaterThan(artifacts.checkpoint.globalMaxLinearComponent,
                             artifacts.checkpoint.globalMaxLuminance)
        XCTAssertEqual(artifacts.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion,
                       "A fresh job must write the component-bounding normalization version.")
        assertInteriorSaturatedRed(artifacts.outputBuffer, label: "fresh")
        let freshMax = maxComponent(artifacts.outputBuffer)
        print("[GroupB] fresh canvas max component=\(freshMax.value) at (\(freshMax.x),\(freshMax.y)); checkpoint component=\(artifacts.checkpoint.globalMaxLinearComponent) luminance=\(artifacts.checkpoint.globalMaxLuminance) version=\(artifacts.checkpoint.normalizationPeakVersion)")

        // The durably persisted checkpoint carries the same component peak.
        let persisted = try await store.load(jobID: config.id)
        XCTAssertEqual(persisted.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01)
        XCTAssertEqual(persisted.globalMaxLuminance, expectedLuminancePeak, accuracy: 0.01)

        // Export (Group E's detailed result) measures the FINAL rendered component peak, which is the
        // container headroom source. It is NOT the checkpoint's source-normalization telemetry: chroma
        // bicubic overshoot at the red/neutral boundary can legitimately exceed 4.0 (bounded by the
        // 1.2 normalized clamp). What must hold is that the saturated 4.0 component is never clipped.
        let exportURL = directory.appendingPathComponent("saturated_fresh.dng")
        let exportResult = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: exportURL,
            overrideFormat: .linearDNG16Bit,
            overrideGrainAmount: 0
        )
        XCTAssertGreaterThanOrEqual(exportResult.finalLinearPeak, expectedComponentPeak - 0.05,
                                    "Export pre-pass clipped the saturated component.")
        XCTAssertLessThanOrEqual(exportResult.finalLinearPeak, 9.5,
                                 "Export peak exceeded the normalized safety-clamp bound.")
        let exportMax = maxComponent(artifacts.outputBuffer)
        print("[GroupB] export finalLinearPeak=\(exportResult.finalLinearPeak) canvasMax=\(exportMax.value) at (\(exportMax.x),\(exportMax.y)) dngHeadroom=\(exportResult.dngHeadroomScale)")
        XCTAssertEqual(exportResult.dngHeadroomScale, max(1, exportResult.finalLinearPeak), accuracy: 1e-5,
                       "DNG headroom must be the measured final component peak.")
        XCTAssertEqual(exportResult.actualScaleFactor, 2)

        let reingestMMapURL = directory.appendingPathComponent("reingest_fresh.rgba16f.bin")
        let reingested = try UniversalStripDecoder.decodeToMMap(
            imageURL: exportURL,
            destinationMMapURL: reingestMMapURL
        )
        XCTAssertEqual(reingested.globalMaxLinearComponent, exportResult.finalLinearPeak, accuracy: 0.05,
                       "Re-ingested export peak disagrees with the measured export peak.")
        XCTAssertGreaterThanOrEqual(reingested.globalMaxLinearComponent, expectedComponentPeak - 0.05,
                                    "Re-ingested export lost the saturated component peak.")
        assertInteriorSaturatedRed(reingested.sourceBuffer, label: "re-ingested export")
    }

    // MARK: - R1: pause / resume

    func testSaturatedComponentPeakSurvivesGracefulPauseAndResume() async throws {
        let directory = try makeTemporaryDirectory(label: "resume")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try JobCheckpointStore(workingDirectory: directory)
        let config = makeSaturatedHDRConfig()
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.switchExecutionTier(.cpuOnly)
        // Pause before the first tile so every pixel (including the red quadrant) is produced by the
        // resumed denominator rather than the fresh one.
        await executor.requestGracefulPause()
        try await runExpectingPause(executor, config: config)

        let paused = try await store.load(jobID: config.id)
        XCTAssertEqual(paused.lastCompletedTileIndex, -1)
        XCTAssertEqual(paused.normalizationPeakVersion, JobCheckpointState.currentNormalizationPeakVersion)
        XCTAssertEqual(paused.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01)

        let resumedExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await resumedExecutor.switchExecutionTier(.cpuOnly)
        let resumed = try await resumedExecutor.executeOrResumeJob(
            config: config,
            existingCheckpoint: paused
        )
        XCTAssertEqual(resumed.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01)
        XCTAssertEqual(resumed.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        assertInteriorSaturatedRed(resumed.outputBuffer, label: "resumed")

        // The exported artifact of the resumed run must also preserve the saturated patch.
        let exportURL = directory.appendingPathComponent("saturated_resumed.dng")
        let exportResult = try FormatAwareExporter.exportImageDetailed(
            artifacts: resumed,
            destinationURL: exportURL,
            overrideFormat: .linearDNG16Bit,
            overrideGrainAmount: 0
        )
        XCTAssertGreaterThanOrEqual(exportResult.finalLinearPeak, expectedComponentPeak - 0.05,
                                    "Resumed export clipped the saturated component.")
        print("[GroupB] resumed checkpoint component=\(resumed.checkpoint.globalMaxLinearComponent) version=\(resumed.checkpoint.normalizationPeakVersion) exportPeak=\(exportResult.finalLinearPeak) canvasMax=\(maxComponent(resumed.outputBuffer).value)")
    }

    func testResumeRescansLuminanceDerivedCheckpointBeforeReplay() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-rescan")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try JobCheckpointStore(workingDirectory: directory)
        let config = makeSaturatedHDRConfig()
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.switchExecutionTier(.cpuOnly)
        await executor.requestGracefulPause()
        try await runExpectingPause(executor, config: config)

        // Simulate a pre-repair checkpoint: the denominator is the luminance peak (1.0) and the
        // normalization version field is absent (decodes as version 1).
        let checkpointURL = await store.checkpointFileURL(for: config.id)
        var object = try checkpointObject(at: checkpointURL)
        object["globalMaxLinearComponent"] = 1.0
        object.removeValue(forKey: "normalizationPeakVersion")
        try writeCheckpointObject(object, to: checkpointURL)

        let legacy = try await store.load(jobID: config.id)
        XCTAssertEqual(legacy.normalizationPeakVersion, 1)
        XCTAssertEqual(legacy.globalMaxLinearComponent, 1.0, accuracy: 1e-6)

        let resumedExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await resumedExecutor.switchExecutionTier(.cpuOnly)
        let resumed = try await resumedExecutor.executeOrResumeJob(
            config: config,
            existingCheckpoint: legacy
        )

        XCTAssertEqual(resumed.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01,
                       "Resume did not rescan the mapped source for the true component peak.")
        XCTAssertEqual(resumed.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion,
                       "Resume did not upgrade the normalization peak version.")
        assertInteriorSaturatedRed(resumed.outputBuffer, label: "legacy-rescan replay")
        print("[GroupB] rescanned checkpoint component=\(resumed.checkpoint.globalMaxLinearComponent) version=\(resumed.checkpoint.normalizationPeakVersion) max=\(maxComponent(resumed.outputBuffer).value)")

        // The rescanned checkpoint must have been saved durably, not only in memory.
        let durable = try await store.load(jobID: config.id)
        XCTAssertEqual(durable.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01)
        XCTAssertEqual(durable.normalizationPeakVersion, JobCheckpointState.currentNormalizationPeakVersion)
    }

    func testResumeKeepsAdequateStoredComponentPeak() async throws {
        let directory = try makeTemporaryDirectory(label: "adequate-peak")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try JobCheckpointStore(workingDirectory: directory)
        let config = makeSaturatedHDRConfig()
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.switchExecutionTier(.cpuOnly)
        await executor.requestGracefulPause()
        try await runExpectingPause(executor, config: config)

        // Only the version marker is stale: the stored component peak (4.0) is already adequate and must
        // be preserved, not replaced by a worse estimate.
        let checkpointURL = await store.checkpointFileURL(for: config.id)
        var object = try checkpointObject(at: checkpointURL)
        object.removeValue(forKey: "normalizationPeakVersion")
        try writeCheckpointObject(object, to: checkpointURL)
        let legacy = try await store.load(jobID: config.id)
        XCTAssertEqual(legacy.normalizationPeakVersion, 1)
        XCTAssertEqual(legacy.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01)

        let resumedExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await resumedExecutor.switchExecutionTier(.cpuOnly)
        let resumed = try await resumedExecutor.executeOrResumeJob(
            config: config,
            existingCheckpoint: legacy
        )
        XCTAssertEqual(resumed.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01)
        XCTAssertEqual(resumed.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        assertInteriorSaturatedRed(resumed.outputBuffer, label: "adequate-peak replay")
    }

    // MARK: - R1: Metal / CPU parity with the actual decoder peak

    func testSaturatedComponentPeakMetalAndCPUParity() async throws {
        let cpuDirectory = try makeTemporaryDirectory(label: "parity-cpu")
        defer { try? FileManager.default.removeItem(at: cpuDirectory) }
        let cpuStore = try JobCheckpointStore(workingDirectory: cpuDirectory)
        let cpuExecutor = makeExecutor(workingDirectory: cpuDirectory, checkpointStore: cpuStore)
        await cpuExecutor.switchExecutionTier(.cpuOnly)
        let config = makeSaturatedHDRConfig()
        let cpu = try await cpuExecutor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )
        assertInteriorSaturatedRed(cpu.outputBuffer, label: "CPU")

        guard MetalColorProcessor().isMetalAccelerationAvailable else {
            throw XCTSkip("Metal color acceleration is unavailable on this host; CPU parity path verified.")
        }

        let metalDirectory = try makeTemporaryDirectory(label: "parity-metal")
        defer { try? FileManager.default.removeItem(at: metalDirectory) }
        let metalStore = try JobCheckpointStore(workingDirectory: metalDirectory)
        let metalExecutor = TiledPipelineExecutor(
            workingDirectory: metalDirectory,
            modelRegistry: CoreMLModelRegistry(
                initialComputeUnits: .cpuOnly,
                availabilityPolicy: .allowDeterministicFallback
            ),
            checkpointStore: metalStore,
            colorProcessor: MetalColorProcessor()
        )
        // Foreground policy: the color engine uses its Metal kernels while the deterministic fallback
        // models remain the test stand-ins.
        await metalExecutor.switchExecutionTier(.gpuAndANE)
        let metal = try await metalExecutor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )

        XCTAssertEqual(metal.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 0.01)
        assertInteriorSaturatedRed(metal.outputBuffer, label: "Metal")
        let difference = maxPixelDifference(cpu.outputBuffer, metal.outputBuffer)
        print("[GroupB] Metal/CPU executor parity maxPixelDifference=\(difference) cpuMax=\(maxComponent(cpu.outputBuffer).value) metalMax=\(maxComponent(metal.outputBuffer).value)")
        XCTAssertLessThanOrEqual(
            difference,
            0.05,
            "Metal vs CPU pipeline parity failed with the decoder-derived component peak (max diff \(difference))."
        )
    }

    // MARK: - R6: session state through execution/resume

    func testSessionStateSuppressesAutoDenoiseOnUntaggedJPEG() async throws {
        let directory = try makeTemporaryDirectory(label: "session-untagged")
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpegURL = directory.appendingPathComponent("untagged.jpg")
        try writeJPEG(at: jpegURL, width: 64, height: 48, exifUserComment: nil)

        let store = try JobCheckpointStore(workingDirectory: directory)

        let controlExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        let control = try await controlExecutor.executeOrResumeJob(
            config: makeJPEGConfig(url: jpegURL, denoiseMode: .off),
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertFalse(control.checkpoint.didRunDenoise,
                      "New SR-only jobs never denoise.")

        // Handed off as already denoised: the merge must happen before the auto decision.
        let handedOffConfig = makeJPEGConfig(
            url: jpegURL,
            denoiseMode: .off,
            sessionState: PipelineSessionState(isDenoised: true)
        )
        let handedOffExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        let handedOff = try await handedOffExecutor.executeOrResumeJob(
            config: handedOffConfig,
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertFalse(handedOff.checkpoint.didRunDenoise,
                       "A handoff-tagged denoised JPEG must suppress the automatic the retired denoise stage pass.")
        XCTAssertTrue(handedOff.metadata.isAlreadyDenoisedBySuite)
        XCTAssertEqual(handedOff.checkpoint.config.sessionState?.isDenoised, true,
                       "The checkpoint config must persist the handoff session state.")

        // The merged metadata, not just the in-memory object, is durable for resume.
        let metadataURL = directory.appendingPathComponent(
            "metadata_\(handedOffConfig.id.uuidString).json"
        )
        let persistedMetadata = try JSONDecoder().decode(
            ImageMetadataPacket.self,
            from: try Data(contentsOf: metadataURL)
        )
        XCTAssertTrue(persistedMetadata.isAlreadyDenoisedBySuite)
    }

    func testSessionStateExplicitFalseClearsInheritedMarkerAndDenoiseOffStaysOff() async throws {
        let directory = try makeTemporaryDirectory(label: "session-explicit-false")
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpegURL = directory.appendingPathComponent("tagged.jpg")
        try writeJPEG(
            at: jpegURL,
            width: 64,
            height: 48,
            exifUserComment: "ImagingSuite:Denoised=true"
        )
        let store = try JobCheckpointStore(workingDirectory: directory)

        // The embedded marker alone suppresses the auto denoiser.
        let inheritedExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        let inherited = try await inheritedExecutor.executeOrResumeJob(
            config: makeJPEGConfig(url: jpegURL, denoiseMode: .off),
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertTrue(inherited.metadata.isAlreadyDenoisedBySuite)
        XCTAssertFalse(inherited.checkpoint.didRunDenoise)

        let clearedExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        let cleared = try await clearedExecutor.executeOrResumeJob(
            config: makeJPEGConfig(
                url: jpegURL,
                denoiseMode: .off,
                sessionState: PipelineSessionState(isDenoised: false)
            ),
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertFalse(cleared.metadata.isAlreadyDenoisedBySuite,
                       "An explicit session `isDenoised=false` must clear the inherited marker.")
        XCTAssertFalse(cleared.checkpoint.didRunDenoise,
                      "Clearing upstream history must not enable a processing stage.")

        // `.off` never runs the model regardless of the session state.
        let offExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        let off = try await offExecutor.executeOrResumeJob(
            config: makeJPEGConfig(
                url: jpegURL,
                denoiseMode: .off,
                sessionState: PipelineSessionState(isDenoised: false)
            ),
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertFalse(off.checkpoint.didRunDenoise)
    }

    func testResumePreservesSessionStateAndDoesNotDoubleProcess() async throws {
        let directory = try makeTemporaryDirectory(label: "session-resume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpegURL = directory.appendingPathComponent("handoff.jpg")
        try writeJPEG(at: jpegURL, width: 256, height: 192, exifUserComment: nil)

        let store = try JobCheckpointStore(workingDirectory: directory)
        let sessionState = PipelineSessionState(
            isDenoised: true,
            isUpscaled: true,
            upscaleFactor: 2,
            linearHeadroomScale: 2
        )
        let config = makeJPEGConfig(url: jpegURL, denoiseMode: .off, sessionState: sessionState)

        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.requestPauseAfterTileForTesting(0)
        try await runExpectingPause(executor, config: config)

        let paused = try await store.load(jobID: config.id)
        XCTAssertEqual(paused.lastCompletedTileIndex, 0)
        XCTAssertFalse(paused.didRunDenoise, "Session-tagged denoise must suppress the retired denoise stage on the fresh run.")
        XCTAssertEqual(paused.config.sessionState, sessionState,
                       "The checkpoint config must persist session state for a stable resume.")

        // Resume from a fresh executor (equivalent to an app relaunch) and finish. The explicit tier is
        // documentation only on the resume path (the durable checkpoint owns `tileConfig`), but the
        // strict replay comparison below must never depend on an implicit tier/backend choice.
        let resumedExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        let resumed = try await resumedExecutor.executeOrResumeJob(
            config: config,
            existingCheckpoint: paused,
            overrideTier: .tierB_ConstrainedMemory
        )
        XCTAssertTrue(resumed.metadata.isAlreadyDenoisedBySuite,
                      "Resume discarded handoff-only denoise state.")
        XCTAssertTrue(resumed.metadata.isAlreadyUpscaledBySuite)
        XCTAssertEqual(resumed.metadata.upscaledByAppFactor, 2)
        XCTAssertEqual(resumed.metadata.linearHeadroomScale ?? 0, 2, accuracy: 1e-4)
        XCTAssertFalse(resumed.checkpoint.didRunDenoise,
                       "Resume must not fabricate that this job ran denoise.")
        XCTAssertEqual(resumed.checkpoint.tileConfig, paused.tileConfig,
                       "Resume must replay with the checkpoint's immutable tile policy.")

        // Uninterrupted transaction-replay baseline over the *identical* immutable source samples and
        // the same explicit tile policy / CPU backend. A fresh decoder can legitimately differ from the
        // paused run's mmap by Float16-sized amounts on hardware-decode paths (the original intermittent
        // 0.0014648438 failure), so the strict no-double-processing assertion must not re-decode: it
        // reuses the paused job's exact source canvas with an explicit Tier-B plan instead.
        let baselineReplay = try await makeSameSourceReplayBaseline(
            from: paused,
            pausedWorkingDirectory: directory,
            label: "session-baseline"
        )
        defer { try? FileManager.default.removeItem(at: baselineReplay.directory) }
        let baseline = baselineReplay.artifacts
        let difference = maxPixelDifference(resumed.outputBuffer, baseline.outputBuffer)
        print("[C4] resumed-vs-same-source-replay maxDiff=\(difference) pausedTier=\(paused.tileConfig.tier.rawValue) baselineTier=\(baseline.checkpoint.tileConfig.tier.rawValue)")
        XCTAssertEqual(difference, 0,
                       "Resumed canvas diverged from the uninterrupted same-source replay (max diff \(difference)).")


    }

    // MARK: - C4: same-source transaction-replay baseline

    /// Runs an uninterrupted replay in a fresh directory from the *same* immutable source mmap bytes
    /// that a paused run used. It never re-decodes the image and it uses the explicit Tier-B tile plan
    /// plus the explicit CPU-only model/color backend (`makeExecutor`), so the strict
    /// transaction-equivalence assertion cannot be perturbed by fresh-decoder/backend variation.
    private func makeSameSourceReplayBaseline(
        from paused: JobCheckpointState,
        pausedWorkingDirectory: URL,
        label: String
    ) async throws -> (artifacts: CompletedPipelineArtifacts, directory: URL) {
        let directory = try makeTemporaryDirectory(label: label)
        let jobID = UUID()
        let sourceFileName = "source_\(jobID.uuidString).rgba16f.bin"
        let outputFileName = "output_\(jobID.uuidString).rgba16f.bin"
        let metadataFileName = "metadata_\(jobID.uuidString).json"

        try FileManager.default.copyItem(
            at: pausedWorkingDirectory.appendingPathComponent(paused.sourceMMapFileName),
            to: directory.appendingPathComponent(sourceFileName)
        )
        try FileManager.default.copyItem(
            at: pausedWorkingDirectory.appendingPathComponent(paused.metadataPacketFileName),
            to: directory.appendingPathComponent(metadataFileName)
        )
        let outputCanvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent(outputFileName),
            width: paused.outputWidth,
            height: paused.outputHeight,
            createIfMissing: true
        )
        try outputCanvas.flushToDisk(synchronous: true)

        let config = UpscaleJobConfig(
            id: jobID,
            sourceImageURL: paused.config.sourceImageURL,
            scaleFactor: paused.config.scaleFactor,
            backbone: paused.config.backbone,
            denoiseMode: paused.config.denoiseMode,
            naturalGrainAmount: paused.config.naturalGrainAmount,
            exportFormat: paused.config.exportFormat,
            sessionState: paused.config.sessionState
        )
        let baselineCheckpoint = JobCheckpointState(
            jobID: jobID,
            config: config,
            tileConfig: paused.tileConfig,
            sourceWidth: paused.sourceWidth,
            sourceHeight: paused.sourceHeight,
            paddedSourceWidth: paused.paddedSourceWidth,
            paddedSourceHeight: paused.paddedSourceHeight,
            outputWidth: paused.outputWidth,
            outputHeight: paused.outputHeight,
            globalMaxLuminance: paused.globalMaxLuminance,
            globalMaxLinearComponent: paused.globalMaxLinearComponent,
            alphaCurveConstant: paused.alphaCurveConstant,
            didRunDenoise: paused.didRunDenoise,
            sourceMMapFileName: sourceFileName,
            outputMMapFileName: outputFileName,
            metadataPacketFileName: metadataFileName,
            lastCompletedTileIndex: -1,
            totalTiles: paused.totalTiles,
            updatedAt: Date(),
            transactionJournalVersion: paused.transactionJournalVersion,
            normalizationPeakVersion: paused.normalizationPeakVersion
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        try await store.save(baselineCheckpoint)
        let artifacts = try await makeExecutor(
            workingDirectory: directory,
            checkpointStore: store
        ).executeOrResumeJob(
            config: config,
            existingCheckpoint: baselineCheckpoint,
            overrideTier: .tierB_ConstrainedMemory
        )
        return (artifacts, directory)
    }

    // MARK: - C1: synthetic multi-tile extended-range replay fixtures

    private struct SyntheticHDRReplayJob {
        let directory: URL
        let jobID: UUID
        let config: UpscaleJobConfig
        let checkpoint: JobCheckpointState
        let store: JobCheckpointStore
        let plan: TileGridPlan
        let outputURL: URL
    }

    /// Nonconstant extended-range source canvas: the top-right quadrant carries a saturated red
    /// component of 4.0 while the rest is a bounded gradient. Shared by fresh and legacy-migration jobs.
    private func writeSyntheticHDRSource(
        at url: URL,
        width: Int,
        height: Int,
        peakComponent: Float = 4.0
    ) throws -> MMapBuffer {
        let buffer = try MMapBuffer(fileURL: url, width: width, height: height, createIfMissing: true)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                let fx = Float(x) / Float(max(1, width - 1))
                let fy = Float(y) / Float(max(1, height - 1))
                if x >= width / 2 && y < height / 2 {
                    pixel[0] = Float16(peakComponent)
                    pixel[1] = Float16(0.05 * fx)
                    pixel[2] = Float16(0.05 * fy)
                } else {
                    pixel[0] = Float16(0.05 + 0.9 * fx)
                    pixel[1] = Float16(0.05 + 0.8 * fy)
                    pixel[2] = Float16(0.10 + 0.35 * ((fx + fy) * 0.5))
                }
                pixel[3] = 1.0
            }
        }
        try buffer.flushToDisk(synchronous: true)
        return buffer
    }

    private func writeSyntheticHDRMetadata(
        at url: URL,
        width: Int,
        height: Int
    ) throws {
        let metadata = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/truongscaler_synthetic_hdr_source.dng"),
            utTypeIdentifier: "public.dng",
            category: .standardOpaqueRaster,
            originalWidth: width,
            originalHeight: height,
            bitsPerComponent: 16,
            hasAlpha: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    /// Creates (but does not execute) a resumable job over the shared synthetic source. A non-nil
    /// `legacyOutputFill` simulates a committed canvas that was produced under a too-small denominator
    /// (all channels clipped to that constant), so migration must discard rather than relabel it.
    private func makeSyntheticHDRReplayJob(
        directory: URL,
        sourceFileName: String,
        metadataFileName: String,
        sourceWidth: Int,
        sourceHeight: Int,
        componentPeak: Float,
        luminancePeak: Float = 1.0,
        normalizationVersion: Int,
        lastCompletedTileIndex: Int,
        legacyOutputFill: Float16?,
        useCanonicalOutputName: Bool = false
    ) async throws -> SyntheticHDRReplayJob {
        let jobID = UUID()
        let config = UpscaleJobConfig(
            id: jobID,
            sourceImageURL: directory.appendingPathComponent("synthetic_hdr_source.dng"),
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0,
            exportFormat: .linearDNG16Bit
        )
        let tileConfig = TileConfiguration(tier: .tierB_ConstrainedMemory)
        let plan = TileGridPlanner.makePlan(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            scaleFactor: .x2,
            tileConfig: tileConfig
        )
        let outputFileName = useCanonicalOutputName
            ? "output_\(jobID.uuidString)_norm2.rgba16f.bin"
            : "output_\(jobID.uuidString).rgba16f.bin"
        let outputURL = directory.appendingPathComponent(outputFileName)
        let outputCanvas = try MMapBuffer(
            fileURL: outputURL,
            width: plan.outputWidth,
            height: plan.outputHeight,
            createIfMissing: true
        )
        if let legacyOutputFill {
            for y in 0..<plan.outputHeight {
                for x in 0..<plan.outputWidth {
                    let pixel = outputCanvas.unsafePixelPointer(x: x, y: y)
                    pixel[0] = legacyOutputFill
                    pixel[1] = legacyOutputFill
                    pixel[2] = legacyOutputFill
                    pixel[3] = 1.0
                }
            }
        }
        try outputCanvas.flushToDisk(synchronous: true)

        let checkpoint = JobCheckpointState(
            jobID: jobID,
            config: config,
            tileConfig: tileConfig,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            paddedSourceWidth: sourceWidth,
            paddedSourceHeight: sourceHeight,
            outputWidth: plan.outputWidth,
            outputHeight: plan.outputHeight,
            globalMaxLuminance: luminancePeak,
            globalMaxLinearComponent: componentPeak,
            alphaCurveConstant: 16.0,
            didRunDenoise: false,
            sourceMMapFileName: sourceFileName,
            outputMMapFileName: outputFileName,
            metadataPacketFileName: metadataFileName,
            lastCompletedTileIndex: lastCompletedTileIndex,
            totalTiles: plan.totalTiles,
            updatedAt: Date(),
            transactionJournalVersion: JobCheckpointState.currentTransactionJournalVersion,
            normalizationPeakVersion: normalizationVersion
        )
        let store = try JobCheckpointStore(workingDirectory: directory)
        try await store.save(checkpoint)
        return SyntheticHDRReplayJob(
            directory: directory,
            jobID: jobID,
            config: config,
            checkpoint: checkpoint,
            store: store,
            plan: plan,
            outputURL: outputURL
        )
    }

    private func runSyntheticHDRReplay(
        _ job: SyntheticHDRReplayJob,
        existingCheckpoint: JobCheckpointState? = nil
    ) async throws -> CompletedPipelineArtifacts {
        let executor = makeExecutor(workingDirectory: job.directory, checkpointStore: job.store)
        await executor.switchExecutionTier(.cpuOnly)
        return try await executor.executeOrResumeJob(
            config: job.config,
            existingCheckpoint: existingCheckpoint ?? job.checkpoint,
            overrideTier: .tierB_ConstrainedMemory
        )
    }

    private func migrationArtifactNames(in directory: URL, jobID: UUID) throws -> [String] {
        let prefix = "output_\(jobID.uuidString)_norm2."
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries.map(\.lastPathComponent).filter { $0.hasPrefix(prefix) }
    }

    // MARK: - C1: legacy committed-pixel migration

    func testCodexSecondReviewLegacyCommittedPixelsAreRecomputedWhenPeakChanges() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-committed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobCheckpointStore(workingDirectory: directory)
        let config = makeSaturatedHDRConfig()
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.switchExecutionTier(.cpuOnly)
        let completed = try await executor.executeOrResumeJob(
            config: config,
            overrideTier: .tierB_ConstrainedMemory
        )
        for y in 0..<completed.outputBuffer.height {
            for x in 0..<completed.outputBuffer.width {
                let p = completed.outputBuffer.unsafePixelPointer(x: x, y: y)
                for c in 0..<3 { p[c] = min(p[c], 1) }
            }
        }
        try completed.outputBuffer.flushToDisk(synchronous: true)
        let url = await store.checkpointFileURL(for: config.id)
        var object = try checkpointObject(at: url)
        object["globalMaxLinearComponent"] = 1.0
        object.removeValue(forKey: "normalizationPeakVersion")
        try writeCheckpointObject(object, to: url)
        let legacy = try await store.load(jobID: config.id)
        let resumedExecutor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await resumedExecutor.switchExecutionTier(.cpuOnly)
        let resumed = try await resumedExecutor.executeOrResumeJob(
            config: config,
            existingCheckpoint: legacy
        )
        XCTAssertEqual(resumed.checkpoint.globalMaxLinearComponent, 4, accuracy: 0.01)
        XCTAssertEqual(
            Float(resumed.outputBuffer.unsafePixelPointer(x: 80, y: 10)[0]),
            4,
            accuracy: 0.05,
            "Changing the denominator must not preserve already-clipped committed tiles"
        )
        XCTAssertEqual(
            resumed.checkpoint.normalizationPeakVersion,
            JobCheckpointState.currentNormalizationPeakVersion
        )
        let durable = try await store.load(jobID: config.id)
        XCTAssertEqual(durable.globalMaxLinearComponent, 4, accuracy: 0.01,
                       "The migrated checkpoint must be durable, not only in memory.")
        XCTAssertEqual(durable.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
    }

    func testLegacyMigrationRebuildsPartialAndCompletedCommittedArtifacts() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-multi-tile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceWidth = 300
        let sourceHeight = 220
        let sourceFileName = "synthetic_hdr_source_shared.rgba16f.bin"
        let metadataFileName = "synthetic_hdr_shared.json"
        _ = try writeSyntheticHDRSource(
            at: directory.appendingPathComponent(sourceFileName),
            width: sourceWidth,
            height: sourceHeight
        )
        try writeSyntheticHDRMetadata(
            at: directory.appendingPathComponent(metadataFileName),
            width: sourceWidth,
            height: sourceHeight
        )

        // Uninterrupted corrected reference: version 2, component 4, no committed tiles.
        let freshJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: expectedComponentPeak,
            normalizationVersion: JobCheckpointState.currentNormalizationPeakVersion,
            lastCompletedTileIndex: -1,
            legacyOutputFill: nil
        )
        XCTAssertGreaterThan(freshJob.plan.totalTiles, 1,
                             "The legacy migration fixture must span multiple tiles.")
        let fresh = try await runSyntheticHDRReplay(freshJob)

        // Partial legacy job: two of four tiles committed under denominator 1 / version 1, with a
        // durable canvas that was clipped by that contract (constant 0.25 in every channel).
        let partialJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: 1.0,
            normalizationVersion: 1,
            lastCompletedTileIndex: 1,
            legacyOutputFill: 0.25
        )
        let partialLegacyURL = partialJob.outputURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialLegacyURL.path))
        let partial = try await runSyntheticHDRReplay(partialJob)

        XCTAssertEqual(partial.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 1e-4)
        XCTAssertEqual(partial.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        XCTAssertEqual(partial.checkpoint.lastCompletedTileIndex, partialJob.plan.totalTiles - 1,
                       "A successful migration commits every rebuilt tile.")
        XCTAssertEqual(partial.checkpoint.outputMMapFileName,
                       "output_\(partialJob.jobID.uuidString)_norm2.rgba16f.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialLegacyURL.path),
                       "The clipped pre-migration canvas must be retired after the atomic switch.")
        let partialDifference = maxPixelDifference(partial.outputBuffer, fresh.outputBuffer)
        print("[C1] partial migration vs fresh maxDiff=\(partialDifference) tiles=\(partialJob.plan.totalTiles)")
        XCTAssertEqual(partialDifference, 0,
                       "Partial legacy migration must reproduce the fresh corrected canvas exactly (no reused prefix or doubled seams).")
        let partialSaturated = partial.outputBuffer.unsafePixelPointer(x: 440, y: 40)
        XCTAssertEqual(Float(partialSaturated[0]), expectedComponentPeak, accuracy: 0.05,
                       "Partial migration clipped the saturated red quadrant.")

        // Completed legacy job: every tile was "committed" under the old denominator, so the executor
        // would previously have skipped the whole loop and returned the clipped artifact unchanged.
        let completedJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: 1.0,
            normalizationVersion: 1,
            lastCompletedTileIndex: freshJob.plan.totalTiles - 1,
            legacyOutputFill: 0.25
        )
        let completedLegacyURL = completedJob.outputURL
        let completed = try await runSyntheticHDRReplay(completedJob)
        XCTAssertEqual(completed.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 1e-4)
        XCTAssertEqual(completed.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        XCTAssertEqual(completed.checkpoint.lastCompletedTileIndex, completedJob.plan.totalTiles - 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedLegacyURL.path),
                       "A completed legacy artifact must also be rebuilt and its clipped canvas retired.")
        let completedDifference = maxPixelDifference(completed.outputBuffer, fresh.outputBuffer)
        print("[C1] completed migration vs fresh maxDiff=\(completedDifference)")
        XCTAssertEqual(completedDifference, 0,
                       "Completed legacy migration must reproduce the fresh corrected canvas exactly.")
        XCTAssertEqual(Float(completed.outputBuffer.unsafePixelPointer(x: 440, y: 40)[0]),
                       expectedComponentPeak, accuracy: 0.05)
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: partialJob.jobID),
                       ["output_\(partialJob.jobID.uuidString)_norm2.rgba16f.bin"])
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: completedJob.jobID),
                       ["output_\(completedJob.jobID.uuidString)_norm2.rgba16f.bin"])

        // Crash-after-commit recovery: the canonical checkpoint is durable, but the deterministic
        // pre-migration canvas survived the crash. A resume with the durable canonical checkpoint must
        // retire that stale legacy output without reprocessing the committed norm-2 canvas.
        let durableCompleted = try await completedJob.store.load(jobID: completedJob.jobID)
        XCTAssertEqual(durableCompleted.outputMMapFileName,
                       "output_\(completedJob.jobID.uuidString)_norm2.rgba16f.bin")
        try Data("stale legacy canvas".utf8).write(to: completedLegacyURL)
        let recoveredCompleted = try await runSyntheticHDRReplay(
            completedJob,
            existingCheckpoint: durableCompleted
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedLegacyURL.path),
                       "A canonical checkpoint must retire the stale legacy output on recovery.")
        XCTAssertEqual(maxPixelDifference(recoveredCompleted.outputBuffer, fresh.outputBuffer), 0,
                       "Crash-after-commit recovery must not reprocess the committed norm-2 canvas.")
    }

    func testLegacyCompatibleCommittedFrontierIsRelabeledWithoutRebuild() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-compatible-frontier")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceWidth = 300
        let sourceHeight = 220
        let sourceFileName = "synthetic_hdr_source_compatible.rgba16f.bin"
        let metadataFileName = "synthetic_hdr_compatible.json"
        // The source component peak is 2.0, while this legacy checkpoint recorded a luminance
        // denominator of 4.0. The committed pixels were therefore produced with an *larger*
        // denominator than the corrected component, so they were not clipped and are compatible.
        _ = try writeSyntheticHDRSource(
            at: directory.appendingPathComponent(sourceFileName),
            width: sourceWidth,
            height: sourceHeight,
            peakComponent: 2.0
        )
        try writeSyntheticHDRMetadata(
            at: directory.appendingPathComponent(metadataFileName),
            width: sourceWidth,
            height: sourceHeight
        )
        let job = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: 1.0,
            luminancePeak: 4.0,
            normalizationVersion: 1,
            lastCompletedTileIndex: 1,
            legacyOutputFill: 0.75
        )
        let resumed = try await runSyntheticHDRReplay(job)

        XCTAssertEqual(resumed.checkpoint.globalMaxLinearComponent, 2.0, accuracy: 1e-4,
                       "The compatible frontier must still be relabeled with the rescanned component.")
        XCTAssertEqual(resumed.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        XCTAssertEqual(resumed.checkpoint.lastCompletedTileIndex, job.plan.totalTiles - 1)
        XCTAssertEqual(resumed.checkpoint.outputMMapFileName, job.checkpoint.outputMMapFileName,
                       "A compatible frontier must resume in place instead of rebuilding all tiles.")
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: job.jobID), [],
                       "A compatible frontier must not create migration artifacts.")
        XCTAssertEqual(Float(resumed.outputBuffer.unsafePixelPointer(x: 10, y: 10)[0]),
                       0.75,
                       accuracy: 1e-3,
                       "Compatible committed pixels must be preserved, never rebuilt or relabeled-and-skipped.")
        XCTAssertNotEqual(Float(resumed.outputBuffer.unsafePixelPointer(x: 10, y: 430)[0]),
                          0.75,
                          accuracy: 1e-3,
                          "The remaining tiles must still be processed after the metadata upgrade.")
    }

    func testLegacyMigrationInterruptionLeavesOldStateIntactAndRetriesCleanly() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-migration-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceWidth = 300
        let sourceHeight = 220
        let sourceFileName = "synthetic_hdr_source_retry.rgba16f.bin"
        let metadataFileName = "synthetic_hdr_retry.json"
        _ = try writeSyntheticHDRSource(
            at: directory.appendingPathComponent(sourceFileName),
            width: sourceWidth,
            height: sourceHeight
        )
        try writeSyntheticHDRMetadata(
            at: directory.appendingPathComponent(metadataFileName),
            width: sourceWidth,
            height: sourceHeight
        )
        let freshJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: expectedComponentPeak,
            normalizationVersion: JobCheckpointState.currentNormalizationPeakVersion,
            lastCompletedTileIndex: -1,
            legacyOutputFill: nil
        )
        let fresh = try await runSyntheticHDRReplay(freshJob)

        let legacyJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: 1.0,
            normalizationVersion: 1,
            lastCompletedTileIndex: 1,
            legacyOutputFill: 0.25
        )
        let checkpointURL = await legacyJob.store.checkpointFileURL(for: legacyJob.jobID)
        let originalCheckpointData = try Data(contentsOf: checkpointURL)
        let originalLegacyCanvas = try Data(contentsOf: legacyJob.outputURL)
        let expectedLegacyName = legacyJob.checkpoint.outputMMapFileName

        func assertOldStateIntact(_ label: String) async throws {
            let durable = try await legacyJob.store.load(jobID: legacyJob.jobID)
            XCTAssertEqual(durable.globalMaxLinearComponent, 1.0, accuracy: 1e-6, label)
            XCTAssertEqual(durable.normalizationPeakVersion, 1, label)
            XCTAssertEqual(durable.lastCompletedTileIndex, 1, label)
            XCTAssertEqual(durable.outputMMapFileName, expectedLegacyName, label)
            XCTAssertEqual(try Data(contentsOf: checkpointURL), originalCheckpointData,
                           "\(label): the durable checkpoint must not be rewritten by a failed migration.")
            XCTAssertEqual(try Data(contentsOf: legacyJob.outputURL), originalLegacyCanvas,
                           "\(label): the old output canvas must stay byte-identical.")
            XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: legacyJob.jobID), [],
                           "\(label): an aborted migration must not leave temp or canonical orphans.")
        }

        // Interruption during migration setup: the pause arrives before the first rebuilt tile.
        let setupExecutor = makeExecutor(workingDirectory: directory, checkpointStore: legacyJob.store)
        await setupExecutor.switchExecutionTier(.cpuOnly)
        await setupExecutor.requestGracefulPause()
        try await runExpectingPause(
            setupExecutor,
            config: legacyJob.config,
            existingCheckpoint: legacyJob.checkpoint
        )
        try await assertOldStateIntact("setup interruption")

        // Interruption mid-rebuild: the pause is observed after the first rebuilt tile, proving the temp
        // canvas is discarded instead of being adopted.
        let midExecutor = makeExecutor(workingDirectory: directory, checkpointStore: legacyJob.store)
        await midExecutor.switchExecutionTier(.cpuOnly)
        await midExecutor.requestPauseAfterTileForTesting(0)
        try await runExpectingPause(
            midExecutor,
            config: legacyJob.config,
            existingCheckpoint: legacyJob.checkpoint
        )
        try await assertOldStateIntact("mid-rebuild interruption")

        // Simulate the two crash leftovers a retry must clean: an unreferenced temp canvas and a
        // canonical canvas whose rename completed but whose checkpoint commit did not.
        let orphanTempURL = directory.appendingPathComponent(
            "output_\(legacyJob.jobID.uuidString)_norm2.\(UUID().uuidString).tmp.rgba16f.bin"
        )
        try Data("orphan temp canvas".utf8).write(to: orphanTempURL)
        let orphanCanonicalURL = directory.appendingPathComponent(
            "output_\(legacyJob.jobID.uuidString)_norm2.rgba16f.bin"
        )
        try Data("orphan canonical canvas".utf8).write(to: orphanCanonicalURL)

        // Clean retry completes the migration and matches the fresh corrected canvas exactly.
        let resumed = try await runSyntheticHDRReplay(legacyJob)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanTempURL.path),
                       "The retry must delete an orphan temp canvas left by an interrupted attempt.")
        XCTAssertEqual(resumed.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 1e-4)
        XCTAssertEqual(resumed.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        let retryDifference = maxPixelDifference(resumed.outputBuffer, fresh.outputBuffer)
        print("[C1] retried migration vs fresh maxDiff=\(retryDifference)")
        XCTAssertEqual(retryDifference, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyJob.outputURL.path))
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: legacyJob.jobID),
                       ["output_\(legacyJob.jobID.uuidString)_norm2.rgba16f.bin"])
        let durableAfter = try await legacyJob.store.load(jobID: legacyJob.jobID)
        XCTAssertNotEqual(try Data(contentsOf: checkpointURL), originalCheckpointData)
        XCTAssertEqual(durableAfter.outputMMapFileName,
                       "output_\(legacyJob.jobID.uuidString)_norm2.rgba16f.bin")
    }

    func testAdequateSameContractResumeReplaysExactly() async throws {
        let directory = try makeTemporaryDirectory(label: "adequate-same-contract")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceWidth = 300
        let sourceHeight = 220
        let sourceFileName = "synthetic_hdr_source_same_contract.rgba16f.bin"
        let metadataFileName = "synthetic_hdr_same_contract.json"
        _ = try writeSyntheticHDRSource(
            at: directory.appendingPathComponent(sourceFileName),
            width: sourceWidth,
            height: sourceHeight
        )
        try writeSyntheticHDRMetadata(
            at: directory.appendingPathComponent(metadataFileName),
            width: sourceWidth,
            height: sourceHeight
        )

        let referenceJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: expectedComponentPeak,
            normalizationVersion: JobCheckpointState.currentNormalizationPeakVersion,
            lastCompletedTileIndex: -1,
            legacyOutputFill: nil
        )
        let reference = try await runSyntheticHDRReplay(referenceJob)
        XCTAssertGreaterThan(referenceJob.plan.totalTiles, 2)

        let resumeJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: expectedComponentPeak,
            normalizationVersion: JobCheckpointState.currentNormalizationPeakVersion,
            lastCompletedTileIndex: -1,
            legacyOutputFill: nil
        )
        let pauseExecutor = makeExecutor(workingDirectory: directory, checkpointStore: resumeJob.store)
        await pauseExecutor.switchExecutionTier(.cpuOnly)
        await pauseExecutor.requestPauseAfterTileForTesting(1)
        try await runExpectingPause(
            pauseExecutor,
            config: resumeJob.config,
            existingCheckpoint: resumeJob.checkpoint
        )
        let paused = try await resumeJob.store.load(jobID: resumeJob.jobID)
        XCTAssertEqual(paused.lastCompletedTileIndex, 1)
        XCTAssertEqual(paused.normalizationPeakVersion, JobCheckpointState.currentNormalizationPeakVersion)
        XCTAssertEqual(paused.globalMaxLinearComponent, expectedComponentPeak, accuracy: 1e-4)
        XCTAssertEqual(paused.outputMMapFileName, resumeJob.checkpoint.outputMMapFileName,
                       "An adequate same-contract checkpoint must not be migrated or renamed.")

        let resumed = try await runSyntheticHDRReplay(resumeJob, existingCheckpoint: paused)
        XCTAssertEqual(resumed.checkpoint.outputMMapFileName, paused.outputMMapFileName,
                       "Same-contract resume must keep the original output canvas name.")
        XCTAssertEqual(resumed.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        let difference = maxPixelDifference(resumed.outputBuffer, reference.outputBuffer)
        print("[C1] adequate same-contract resume vs reference maxDiff=\(difference)")
        XCTAssertEqual(difference, 0,
                       "An unchanged adequate checkpoint must replay committed tiles exactly (no rebuild, no seams).")
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: resumeJob.jobID), [],
                       "An adequate same-contract resume must not create migration artifacts.")
    }


    // MARK: - D1: durable migration publication boundaries

    private enum LegacyMigrationFailureMode: String, CaseIterable {
        /// Pause/interruption before the candidate canvas is renamed (only the temp canvas exists).
        case pauseBeforeCandidateRename
        /// The candidate was renamed, but writing the checkpoint fails before it replaces the old file.
        case beforeCheckpointPublication
        /// The new checkpoint JSON is visible, but its directory fsync fails (ambiguous publication).
        case ambiguousCheckpointPublication
        /// Migration committed, but retiring the old canvas fails.
        case cleanup
    }

    private struct LegacyMigrationEnvironment {
        let sourceWidth: Int
        let sourceHeight: Int
        let sourceFileName: String
        let metadataFileName: String
        let fresh: CompletedPipelineArtifacts
    }

    private func makeMigrationExecutor(
        workingDirectory: URL,
        checkpointStore: JobCheckpointStore
    ) async -> TiledPipelineExecutor {
        let executor = makeExecutor(
            workingDirectory: workingDirectory,
            checkpointStore: checkpointStore
        )
        await executor.switchExecutionTier(.cpuOnly)
        return executor
    }

    private func prepareLegacyMigrationEnvironment(
        directory: URL,
        label: String,
        sourceWidth: Int = 300,
        sourceHeight: Int = 220
    ) async throws -> LegacyMigrationEnvironment {
        let sourceFileName = "synthetic_hdr_source_\(label).rgba16f.bin"
        let metadataFileName = "synthetic_hdr_\(label).json"
        _ = try writeSyntheticHDRSource(
            at: directory.appendingPathComponent(sourceFileName),
            width: sourceWidth,
            height: sourceHeight
        )
        try writeSyntheticHDRMetadata(
            at: directory.appendingPathComponent(metadataFileName),
            width: sourceWidth,
            height: sourceHeight
        )
        let freshJob = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            componentPeak: expectedComponentPeak,
            normalizationVersion: JobCheckpointState.currentNormalizationPeakVersion,
            lastCompletedTileIndex: -1,
            legacyOutputFill: nil
        )
        let fresh = try await runSyntheticHDRReplay(freshJob)
        return LegacyMigrationEnvironment(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFileName: sourceFileName,
            metadataFileName: metadataFileName,
            fresh: fresh
        )
    }

    private func makeLegacyReplayJob(
        environment: LegacyMigrationEnvironment,
        directory: URL,
        completed: Bool,
        useCanonicalOutputName: Bool = false
    ) async throws -> SyntheticHDRReplayJob {
        let tileConfig = TileConfiguration(tier: .tierB_ConstrainedMemory)
        let plan = TileGridPlanner.makePlan(
            sourceWidth: environment.sourceWidth,
            sourceHeight: environment.sourceHeight,
            scaleFactor: .x2,
            tileConfig: tileConfig
        )
        guard plan.totalTiles >= 4 else {
            throw FixtureError(message: "The legacy migration fixture must span at least four tiles.")
        }
        let lastCompletedTileIndex = completed ? plan.totalTiles - 1 : 1
        return try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: environment.sourceFileName,
            metadataFileName: environment.metadataFileName,
            sourceWidth: environment.sourceWidth,
            sourceHeight: environment.sourceHeight,
            componentPeak: 1.0,
            normalizationVersion: 1,
            lastCompletedTileIndex: lastCompletedTileIndex,
            legacyOutputFill: 0.25,
            useCanonicalOutputName: useCanonicalOutputName
        )
    }

    private func legacyCanonicalFileName(jobID: UUID) -> String {
        "output_\(jobID.uuidString)_norm2.rgba16f.bin"
    }

    /// Exercises one failure boundary of a legacy normalization rebuild against a fresh, uninterrupted
    /// reference, then retries from the durable disk state and requires an exact (0.0) match.
    private func assertLegacyMigrationFailureRetriesExactly(
        mode: LegacyMigrationFailureMode,
        completed: Bool,
        environment: LegacyMigrationEnvironment,
        directory: URL
    ) async throws {
        let legacy = try await makeLegacyReplayJob(
            environment: environment,
            directory: directory,
            completed: completed
        )
        let store = legacy.store
        let canonicalName = legacyCanonicalFileName(jobID: legacy.jobID)
        let canonicalURL = directory.appendingPathComponent(canonicalName)
        let oldOutputURL = legacy.outputURL
        let oldOutputBytes = try Data(contentsOf: oldOutputURL)
        let legacyState = try await store.load(jobID: legacy.jobID)

        let executor = await makeMigrationExecutor(
            workingDirectory: directory,
            checkpointStore: store
        )
        switch mode {
        case .pauseBeforeCandidateRename:
            await executor.requestPauseAfterTileForTesting(0)
        case .beforeCheckpointPublication:
            await store.injectDurabilityFaultForTesting(.beforePublication)
        case .ambiguousCheckpointPublication:
            await store.injectDurabilityFaultForTesting(.afterPublicationBeforeDirectorySync)
        case .cleanup:
            await executor.setMigrationCleanupInterruptionHookForTesting {
                throw FixtureError(message: "injected cleanup failure")
            }
        }

        var executionError: Error?
        do {
            _ = try await executor.executeOrResumeJob(
                config: legacy.config,
                existingCheckpoint: legacyState,
                overrideTier: .tierB_ConstrainedMemory
            )
        } catch {
            executionError = error
        }
        switch mode {
        case .cleanup:
            XCTAssertNil(executionError,
                         "\(mode.rawValue): a cleanup failure must never fail the committed migration.")
        case .pauseBeforeCandidateRename:
            let scalerError = try XCTUnwrap(executionError as? ScalerError,
                                            "\(mode.rawValue): expected a graceful pause")
            guard case .jobPausedForBackgroundExpiration = scalerError else {
                XCTFail("\(mode.rawValue): expected jobPausedForBackgroundExpiration, got \(scalerError)")
                return
            }
        case .beforeCheckpointPublication, .ambiguousCheckpointPublication:
            let scalerError = try XCTUnwrap(executionError as? ScalerError,
                                            "\(mode.rawValue): expected the injected persistence failure")
            guard case .mmapSyncFailed(let errno) = scalerError, errno == EIO else {
                XCTFail("\(mode.rawValue): expected mmapSyncFailed(EIO), got \(scalerError)")
                return
            }
        }

        // Whatever checkpoint survives must reference an existing canvas, and the old output must be
        // retained/byte-identical until a durable switch (or confirmed canonical checkpoint) retires it.
        let persisted = try await store.load(jobID: legacy.jobID)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(persisted.outputMMapFileName).path
            ),
            "\(mode.rawValue): a persisted checkpoint must never reference a missing canvas."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldOutputURL.path),
                      "\(mode.rawValue): the pre-migration output must be retained on failure.")
        XCTAssertEqual(try Data(contentsOf: oldOutputURL), oldOutputBytes,
                       "\(mode.rawValue): the retained pre-migration output must stay byte-identical.")

        switch mode {
        case .pauseBeforeCandidateRename:
            XCTAssertNotEqual(persisted.outputMMapFileName, canonicalName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path),
                           "A pre-rename interruption must remove only the temp canvas.")
        case .beforeCheckpointPublication:
            XCTAssertNotEqual(persisted.outputMMapFileName, canonicalName,
                              "Failure before checkpoint publication must leave the old checkpoint.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path),
                          "The fully flushed canonical candidate must be retained after its rename.")
        case .ambiguousCheckpointPublication:
            XCTAssertEqual(persisted.outputMMapFileName, canonicalName,
                           "The injected post-rename fsync failure must expose the new checkpoint.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path),
                          "An ambiguous save must never unlink the canvas the visible checkpoint names.")
        case .cleanup:
            XCTAssertEqual(persisted.outputMMapFileName, canonicalName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path),
                          "A cleanup failure must retain the committed canonical artifact.")
        }

        // The canonical checkpoint can be loaded before durability is confirmed. If confirmation fails,
        // the legacy canvas must be retained but the resume must still return the committed canvas.
        if mode == .ambiguousCheckpointPublication {
            await store.injectDurabilityFaultForTesting(.beforeDurabilityConfirmation)
            let canonicalState = try await store.load(jobID: legacy.jobID)
            let confirmingExecutor = await makeMigrationExecutor(
                workingDirectory: directory,
                checkpointStore: store
            )
            let tolerated = try await confirmingExecutor.executeOrResumeJob(
                config: legacy.config,
                existingCheckpoint: canonicalState,
                overrideTier: .tierB_ConstrainedMemory
            )
            XCTAssertEqual(maxPixelDifference(tolerated.outputBuffer, environment.fresh.outputBuffer), 0,
                           "\(mode.rawValue): a failed durability confirmation must still resume the canonical canvas exactly.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldOutputURL.path),
                          "\(mode.rawValue): failed durability confirmation must retain the legacy canvas.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        }

        // Retry from disk only (never reuse the pre-failure in-memory state).
        let retryState = try await store.load(jobID: legacy.jobID)
        let retryExecutor = await makeMigrationExecutor(
            workingDirectory: directory,
            checkpointStore: store
        )
        let retried = try await retryExecutor.executeOrResumeJob(
            config: legacy.config,
            existingCheckpoint: retryState,
            overrideTier: .tierB_ConstrainedMemory
        )
        let difference = maxPixelDifference(retried.outputBuffer, environment.fresh.outputBuffer)
        print("[D1] \(completed ? "completed" : "partial") \(mode.rawValue) retry-vs-fresh maxDiff=\(difference)")
        XCTAssertEqual(difference, 0,
                       "\(mode.rawValue): retry from disk must reproduce the uninterrupted reference exactly.")
        XCTAssertEqual(retried.checkpoint.outputMMapFileName, canonicalName)
        XCTAssertEqual(retried.checkpoint.globalMaxLinearComponent, expectedComponentPeak, accuracy: 1e-4)
        XCTAssertEqual(retried.checkpoint.normalizationPeakVersion,
                       JobCheckpointState.currentNormalizationPeakVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOutputURL.path),
                       "\(mode.rawValue): the legacy canvas is retired only after a durable canonical checkpoint.")
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: legacy.jobID), [canonicalName])

        let finalState = try await store.load(jobID: legacy.jobID)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(finalState.outputMMapFileName).path
            ),
            "\(mode.rawValue): the final checkpoint must reference an existing canvas."
        )
    }

    func testLegacyMigrationPartialJobDurabilityFailuresRetryExactly() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-durability-partial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = try await prepareLegacyMigrationEnvironment(
            directory: directory,
            label: "durability_partial"
        )
        for mode in LegacyMigrationFailureMode.allCases {
            try await assertLegacyMigrationFailureRetriesExactly(
                mode: mode,
                completed: false,
                environment: environment,
                directory: directory
            )
        }
    }

    func testLegacyMigrationCompletedJobDurabilityFailuresRetryExactly() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-durability-completed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = try await prepareLegacyMigrationEnvironment(
            directory: directory,
            label: "durability_completed"
        )
        for mode in LegacyMigrationFailureMode.allCases {
            try await assertLegacyMigrationFailureRetriesExactly(
                mode: mode,
                completed: true,
                environment: environment,
                directory: directory
            )
        }
    }

    func testLegacyCanonicalInputRepairRefusalKeepsAuthoritativeBytes() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-canonical-refusal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = try await prepareLegacyMigrationEnvironment(
            directory: directory,
            label: "canonical_refusal"
        )

        for completed in [false, true] {
            let legacy = try await makeLegacyReplayJob(
                environment: environment,
                directory: directory,
                completed: completed,
                useCanonicalOutputName: true
            )
            let canonicalName = legacyCanonicalFileName(jobID: legacy.jobID)
            XCTAssertEqual(legacy.checkpoint.outputMMapFileName, canonicalName)
            XCTAssertEqual(legacy.outputURL.lastPathComponent, canonicalName)
            let checkpointURL = await legacy.store.checkpointFileURL(for: legacy.jobID)
            let canonicalBytesBefore = try Data(contentsOf: legacy.outputURL)
            let checkpointBytesBefore = try Data(contentsOf: checkpointURL)
            let metadataURL = directory.appendingPathComponent(legacy.checkpoint.metadataPacketFileName)
            let metadataBefore = try Data(contentsOf: metadataURL)
            let state = try await legacy.store.load(jobID: legacy.jobID)
            var incomingConfig = legacy.config
            incomingConfig.sessionState = PipelineSessionState(isDenoised: true, isUpscaled: true, upscaleFactor: 2)

            let executor = await makeMigrationExecutor(
                workingDirectory: directory,
                checkpointStore: legacy.store
            )
            do {
                _ = try await executor.executeOrResumeJob(
                    config: incomingConfig,
                    existingCheckpoint: state,
                    overrideTier: .tierB_ConstrainedMemory
                )
                XCTFail("A canonical-owned checkpoint that still needs a rebuild must refuse safely.")
            } catch let error as ScalerError {
                guard case .normalizationMigrationRequiresRestart(let url, let reason) = error else {
                    throw error
                }
                XCTAssertEqual(url.standardizedFileURL, checkpointURL.standardizedFileURL)
                XCTAssertFalse(reason.isEmpty)
                print("[D1] canonical refusal (\(completed ? "completed" : "partial")): \(reason)")
            }

            XCTAssertEqual(try Data(contentsOf: legacy.outputURL), canonicalBytesBefore,
                           "The authoritative canonical canvas must be byte-identical after refusal.")
            XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointBytesBefore,
                           "The input checkpoint must not be rewritten by a refused rebuild.")
            XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore,
                           "A refused canonical rebuild must not publish incoming session metadata.")
            XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: legacy.jobID),
                           [canonicalName],
                           "A refused canonical rebuild must not create temp artifacts.")
        }
    }

    func testStaleLegacyResumeCannotPublishMetadataOverDurableCanonicalOwner() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-stale-metadata-refusal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = try await prepareLegacyMigrationEnvironment(directory: directory, label: "stale_metadata_refusal")
        let legacy = try await makeLegacyReplayJob(environment: environment, directory: directory, completed: false)
        let checkpointURL = await legacy.store.checkpointFileURL(for: legacy.jobID)
        let canonicalURL = directory.appendingPathComponent(legacyCanonicalFileName(jobID: legacy.jobID))
        try FileManager.default.copyItem(at: legacy.outputURL, to: canonicalURL)
        // A valid old-canvas journal must remain available even when a stale resume is refused.
        // Recovery would visibly restore this changed rectangle and retire both sidecars if the
        // durable canonical-owner check happened only inside the later rebuild.
        let oldCanvas = try MMapBuffer(fileURL: legacy.outputURL,
            width: legacy.plan.outputWidth, height: legacy.plan.outputHeight, createIfMissing: false)
        let nextIndex = legacy.checkpoint.lastCompletedTileIndex + 1
        let nextTile = legacy.plan.tiles[nextIndex]
        let rect = try XCTUnwrap(TileJournalRect.clipped(destX: nextTile.outputOriginX,
            destY: nextTile.outputOriginY, size: nextTile.outputSize,
            canvasWidth: oldCanvas.width, canvasHeight: oldCanvas.height))
        let journal = TileUndoJournal(workingDirectory: directory)
        _ = try journal.publish(jobID: legacy.jobID, tileIndex: nextIndex, rect: rect, from: oldCanvas)
        oldCanvas.unsafePixelPointer(x: rect.x, y: rect.y)[0] = 0.9375
        try oldCanvas.flushRange(startY: rect.y, rowCount: rect.height)
        let manifestURL = try journal.manifestFileURL(jobID: legacy.jobID, tileIndex: nextIndex)
        let undoURL = try journal.undoFileURL(jobID: legacy.jobID, tileIndex: nextIndex)
        var durable = try checkpointObject(at: checkpointURL)
        durable["outputMMapFileName"] = canonicalURL.lastPathComponent
        durable["normalizationPeakVersion"] = JobCheckpointState.currentNormalizationPeakVersion
        durable["globalMaxLinearComponent"] = expectedComponentPeak
        try writeCheckpointObject(durable, to: checkpointURL)
        let metadataURL = directory.appendingPathComponent(legacy.checkpoint.metadataPacketFileName)
        let protectedURLs = [checkpointURL, canonicalURL, legacy.outputURL, metadataURL, manifestURL, undoURL]
        let before = try protectedURLs.map { try Data(contentsOf: $0) }
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var incomingConfig = legacy.config
        incomingConfig.sessionState = PipelineSessionState(isDenoised: true, isUpscaled: true, upscaleFactor: 2)
        let executor = await makeMigrationExecutor(workingDirectory: directory, checkpointStore: legacy.store)
        do {
            _ = try await executor.executeOrResumeJob(config: incomingConfig, existingCheckpoint: legacy.checkpoint)
            XCTFail("A stale checkpoint must not replace the durable canonical owner.")
        } catch let error as ScalerError {
            guard case .normalizationMigrationRequiresRestart = error else { return XCTFail("Unexpected error: \(error)") }
        }
        for (url, bytes) in zip(protectedURLs, before) {
            XCTAssertEqual(try Data(contentsOf: url), bytes,
                           "A refused stale resume must preserve \(url.lastPathComponent)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), namesBefore,
                       "A refused stale resume must not retire its journal or create migration artifacts.")
    }

    func testCheckpointStoreDurabilityFaultSeamsAreOneShot() async throws {
        let directory = try makeTemporaryDirectory(label: "checkpoint-store-faults")
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await makeSyntheticHDRReplayJob(
            directory: directory,
            sourceFileName: "unused_source.rgba16f.bin",
            metadataFileName: "unused_metadata.json",
            sourceWidth: 64,
            sourceHeight: 64,
            componentPeak: 2.0,
            normalizationVersion: JobCheckpointState.currentNormalizationPeakVersion,
            lastCompletedTileIndex: -1,
            legacyOutputFill: nil
        )
        let store = job.store
        let checkpointURL = await store.checkpointFileURL(for: job.jobID)
        let original = try await store.load(jobID: job.jobID)

        var object = try checkpointObject(at: checkpointURL)
        object["lastCompletedTileIndex"] = 0
        let modified = try JSONDecoder().decode(
            JobCheckpointState.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )

        // Before publication: the destination still holds the old checkpoint.
        await store.injectDurabilityFaultForTesting(.beforePublication)
        do {
            try await store.save(modified)
            XCTFail("The injected before-publication fault must throw.")
        } catch let error as ScalerError {
            guard case .mmapSyncFailed(let errno) = error, errno == EIO else { throw error }
        }
        let beforePublicationState = try await store.load(jobID: job.jobID)
        XCTAssertEqual(beforePublicationState, original)

        // After rename/before directory fsync: the new checkpoint is visible and remains loadable.
        await store.injectDurabilityFaultForTesting(.afterPublicationBeforeDirectorySync)
        do {
            try await store.save(modified)
            XCTFail("The injected ambiguous-publication fault must throw.")
        } catch let error as ScalerError {
            guard case .mmapSyncFailed(let errno) = error, errno == EIO else { throw error }
        }
        let ambiguousState = try await store.load(jobID: job.jobID)
        XCTAssertEqual(ambiguousState, modified)

        // One-shot: the next save succeeds and replaces the ambiguous checkpoint durably.
        try await store.save(modified)
        let successfulState = try await store.load(jobID: job.jobID)
        XCTAssertEqual(successfulState, modified)

        // confirmDurability fault is also one-shot and only affects the confirmation boundary.
        await store.injectDurabilityFaultForTesting(.beforeDurabilityConfirmation)
        do {
            try await store.confirmDurability()
            XCTFail("The injected confirmation fault must throw.")
        } catch let error as ScalerError {
            guard case .mmapSyncFailed(let errno) = error, errno == EIO else { throw error }
        }
        try await store.confirmDurability()

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertFalse(entries.contains { $0.lastPathComponent.contains(".tmp-") },
                       "Checkpoint temp files must never survive a thrown publication fault.")
    }


    func testLegacyMigrationCancellationLeavesRetryableOldStateAndRetriesExactly() async throws {
        let directory = try makeTemporaryDirectory(label: "legacy-migration-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = try await prepareLegacyMigrationEnvironment(
            directory: directory,
            label: "migration_cancel"
        )
        let legacy = try await makeLegacyReplayJob(
            environment: environment,
            directory: directory,
            completed: false
        )
        let legacyState = try await legacy.store.load(jobID: legacy.jobID)
        let oldOutputBytes = try Data(contentsOf: legacy.outputURL)
        let canonicalName = legacyCanonicalFileName(jobID: legacy.jobID)
        let canonicalURL = directory.appendingPathComponent(canonicalName)

        let executor = await makeMigrationExecutor(
            workingDirectory: directory,
            checkpointStore: legacy.store
        )
        let task = Task {
            try await executor.executeOrResumeJob(
                config: legacy.config,
                existingCheckpoint: legacyState,
                overrideTier: .tierB_ConstrainedMemory
            )
        }
        task.cancel()
        var didCancel = false
        do {
            _ = try await task.value
            XCTFail("A cancelled migration must not complete successfully.")
        } catch is CancellationError {
            didCancel = true
        } catch let error as ScalerError {
            if case .jobCancelled = error { didCancel = true } else { throw error }
        }
        XCTAssertTrue(didCancel, "Cancellation must surface as CancellationError/jobCancelled.")

        let cancelledState = try await legacy.store.load(jobID: legacy.jobID)
        XCTAssertEqual(cancelledState.outputMMapFileName, legacyState.outputMMapFileName,
                       "Cancellation before the candidate rename must keep the old checkpoint.")
        XCTAssertEqual(try Data(contentsOf: legacy.outputURL), oldOutputBytes,
                       "Cancellation must leave the old canvas byte-identical.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path),
                       "Cancellation before the rename must remove only the temp canvas.")
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: legacy.jobID), [])

        let retryState = try await legacy.store.load(jobID: legacy.jobID)
        let retryExecutor = await makeMigrationExecutor(
            workingDirectory: directory,
            checkpointStore: legacy.store
        )
        let retried = try await retryExecutor.executeOrResumeJob(
            config: legacy.config,
            existingCheckpoint: retryState,
            overrideTier: .tierB_ConstrainedMemory
        )
        let difference = maxPixelDifference(retried.outputBuffer, environment.fresh.outputBuffer)
        print("[D1] cancelled partial migration retry-vs-fresh maxDiff=\(difference)")
        XCTAssertEqual(difference, 0,
                       "Retry after cancellation must reproduce the uninterrupted reference exactly.")
        XCTAssertEqual(retried.checkpoint.outputMMapFileName, canonicalName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.outputURL.path))
        XCTAssertEqual(try migrationArtifactNames(in: directory, jobID: legacy.jobID), [canonicalName])
    }

    // MARK: - Codex fourth-review pause/identity probes (E1/E2)

    /// Exact production API sequence behind the E1 regression: `StudioViewModel.resetSession` calls
    /// `requestGracefulPauseAndWait()` while idle, then Start registers the next job and executes it.
    /// The idle reset has no ownership over that new run, so registration must retire the old state.
    func testCodexFourthReviewIdleResetPauseDoesNotStopNextRegisteredRun() async throws {
        let directory = try makeTemporaryDirectory(label: "idle-reset-new-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.switchExecutionTier(.cpuOnly)
        // StudioViewModel.resetSession calls this even when no execution is active.
        await executor.requestGracefulPauseAndWait()
        let config = makeSaturatedHDRConfig()
        // The production startJob path now relies solely on registration to retire old pauses.
        await executor.registerJobRun(ExecutionPauseOwner(jobID: config.id, generation: 1))
        do {
            let result = try await executor.executeOrResumeJob(
                config: config,
                overrideTier: .tierB_ConstrainedMemory
            )
            XCTAssertEqual(result.checkpoint.lastCompletedTileIndex, result.checkpoint.totalTiles - 1)
        } catch {
            XCTFail("Idle reset's unscoped pause must not stop a newly registered run: \(error)")
        }
    }

    /// The reviewer's foreign-job probe, now asserting the chosen safe refusal: a real A submission is
    /// refused with `.executionOwnerMismatch` before any Stage 1 filesystem mutation, never paused with
    /// (or executed under) B's registered identity.
    func testCodexFourthReviewForeignJobCannotConsumeRegisteredOwnersPause() async throws {
        let directory = try makeTemporaryDirectory(label: "foreign-job-pause-owner")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobCheckpointStore(workingDirectory: directory)
        let executor = makeExecutor(workingDirectory: directory, checkpointStore: store)
        await executor.switchExecutionTier(.cpuOnly)
        let configA = makeSaturatedHDRConfig()
        let ownerB = ExecutionPauseOwner(jobID: UUID(), generation: 2)
        await executor.registerJobRun(ownerB)
        let armed = await executor.requestGracefulPauseAndWait(ifOwner: ownerB)
        XCTAssertTrue(armed)
        do {
            _ = try await executor.executeOrResumeJob(
                config: configA,
                overrideTier: .tierB_ConstrainedMemory
            )
            XCTFail("A foreign job must not be executed under B's registered owner identity.")
        } catch let error as ScalerError {
            guard case .executionOwnerMismatch(let submitted, let registered) = error else {
                XCTFail("A foreign job must be refused explicitly, not paused/executed: \(error)")
                return
            }
            XCTAssertEqual(submitted, configA.id)
            XCTAssertEqual(registered, ownerB.jobID)
        }
        // The refusal precedes every Stage 1 side effect for the rejected job.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("checkpoint_\(configA.id.uuidString).json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("source_\(configA.id.uuidString).rgba16f.bin").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("output_\(configA.id.uuidString).rgba16f.bin").path
        ))
    }

}
