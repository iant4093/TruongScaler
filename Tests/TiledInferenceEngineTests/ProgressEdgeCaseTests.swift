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
final class ProgressEdgeCaseTests: XCTestCase {
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


    private func setupRun(_ name: String) throws -> (URL, UpscaleJobConfig, JobCheckpointStore, TiledPipelineExecutor) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewProgress-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try makePNG(directory: dir, width: 512, height: 384)
        let config = UpscaleJobConfig(sourceImageURL: url, scaleFactor: .x2, backbone: .quickSRNet, denoiseMode: .off, naturalGrainAmount: 0, exportFormat: .png16Bit)
        let store = JobCheckpointStore(directory: dir)
        let executor = TiledPipelineExecutor(workingDirectory: dir, modelRegistry: CoreMLModelRegistry(initialComputeUnits: .cpuOnly), checkpointStore: store, colorProcessor: MetalColorProcessor(preferMetal: false))
        return (dir,config,store,executor)
    }
    func testResumedBusyCountsNeverDropBelowDurableFrontier() async throws {
        let (dir,config,store,executor) = try setupRun("resume")
        defer { try? FileManager.default.removeItem(at: dir) }
        await executor.requestPauseAfterTileForTesting(1)
        do { _ = try await executor.executeOrResumeJob(config: config, overrideTier: .tierB_ConstrainedMemory); XCTFail("Expected controlled pause") }
        catch ScalerError.jobPausedForBackgroundExpiration {}
        let checkpoint = try await store.load(jobID: config.id)
        let frontier = checkpoint.lastCompletedTileIndex + 1
        XCTAssertEqual(frontier, 2)
        let recorder = ProgressRecorder()
        _ = try await executor.executeOrResumeJob(config: config, existingCheckpoint: checkpoint, progressHandler: { recorder.record($0) })
        let busy = recorder.updates.filter { $0.currentTileIndex != nil && $0.phase != .tileCommitted }
        print("REVIEW_RESUME_FRONTIER \(frontier) BUSY \(busy.map { $0.completedTiles })")
        XCTAssertTrue(busy.allSatisfy { $0.completedTiles >= frontier }, "Resume must report the persisted completed frontier, not the number of tiles processed in this invocation")
    }
    func testSteadyStateEstimateSurvivesIntoTheBusyNextTile() async throws {
        let (dir,config,_,executor) = try setupRun("eta")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ProgressRecorder()
        _ = try await executor.executeOrResumeJob(config: config, overrideTier: .tierB_ConstrainedMemory, progressHandler: { recorder.record($0) })
        let busy = recorder.updates.filter { $0.phase == .predictingSuperResolution && $0.completedTiles >= 2 }
        XCTAssertFalse(busy.isEmpty)
        print("REVIEW_BUSY_ETA \(busy.map { "completed=\($0.completedTiles) avg=\(String(describing: $0.averageSecondsPerTile)) eta=\(String(describing: $0.estimatedSecondsRemaining))" })")
        XCTAssertTrue(busy.allSatisfy { $0.averageSecondsPerTile != nil && $0.estimatedSecondsRemaining != nil }, "An established estimate must remain available while a long tile is running")
    }
    func testPausePublishesPausedPhaseRatherThanReadingSource() async throws {
        let (dir,config,_,executor) = try setupRun("pause-phase")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ProgressRecorder()
        await executor.requestPauseAfterTileForTesting(0)
        do { _ = try await executor.executeOrResumeJob(config: config, overrideTier: .tierB_ConstrainedMemory, progressHandler: { recorder.record($0) }); XCTFail("Expected pause") }
        catch ScalerError.jobPausedForBackgroundExpiration {}
        XCTAssertEqual(recorder.updates.last?.stage, .pausedOnDisk)
        XCTAssertEqual(recorder.updates.last?.phase, .paused, "The new phase must agree with the actual paused durable boundary")
    }
    func testPauseWaiterCannotReturnWhileAnEnteredExecutionIsWaitingForRegistryPolicy() async throws {
        let (dir,config,store,_) = try setupRun("entry-boundary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = CoreMLModelRegistry(initialComputeUnits: .cpuOnly)
        let executor = TiledPipelineExecutor(workingDirectory: dir, modelRegistry: registry, checkpointStore: store, colorProcessor: MetalColorProcessor(preferMetal: false))
        let owner = ExecutionPauseOwner(jobID: config.id, generation: 1)
        await executor.registerJobRun(owner)
        let gate = ReviewPolicyGate()
        let holder = Task { await registry.reviewHoldPolicyActor(gate) }
        await gate.entered.wait()
        defer { gate.release.signal() }
        let started = ReviewSignal()
        let run = Task { () -> Bool in
            started.signal()
            do { _ = try await executor.executeOrResumeJob(config: config, overrideTier: .tierB_ConstrainedMemory); return true }
            catch { return false }
        }
        await started.wait()
        await executor.reviewActorBarrier()
        try await Task.sleep(for: .milliseconds(50))
        let result = ReviewPauseResult()
        let pause = Task { result.set(await executor.requestGracefulPauseAndWait(ifOwner: owner)) }
        try await Task.sleep(for: .milliseconds(50))
        let returnedBeforePolicyReadDrained = result.get() != nil
        print("REVIEW_EARLY_PAUSE_RETURN \(returnedBeforePolicyReadDrained)")
        gate.release.signal()
        await holder.value
        _ = await run.value
        await pause.value
        XCTAssertFalse(returnedBeforePolicyReadDrained, "Once executeOrResumeJob has entered, a scoped pause waiter must not report a stable boundary before that execution drains")
    }

    func testEntryPolicyReadCannotOverwriteANewerRequestedBackgroundPolicy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewPolicyRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let store = JobCheckpointStore(directory: dir)
        let executor = TiledPipelineExecutor(workingDirectory: dir, modelRegistry: registry, checkpointStore: store, colorProcessor: MetalColorProcessor(preferMetal: false))
        let config = UpscaleJobConfig(sourceImageURL: dir.appendingPathComponent("absent-fixture.png"), scaleFactor: .x4, backbone: .quickSRNet, denoiseMode: .off, naturalGrainAmount: 0, exportFormat: .png16Bit)
        let gate = ReviewPolicyGate()
        let holder = Task { await registry.reviewHoldPolicyActor(gate) }
        await gate.entered.wait()
        defer { gate.release.signal() }
        let entered = ReviewSignal()
        let run = Task {
            entered.signal()
            do { _ = try await executor.executeOrResumeJob(config: config) } catch {}
        }
        await entered.wait()
        await executor.reviewActorBarrier()
        try await Task.sleep(for: .milliseconds(50))
        let switched = ReviewSignal()
        let transition = Task {
            switched.signal()
            await executor.switchExecutionTier(.cpuOnly)
        }
        await switched.wait()
        await executor.reviewActorBarrier()
        // The signal above precedes the actor hop. Sanitizer scheduling can let the observation
        // overtake that hop, so wait for the actual request fact while the registry remains gated.
        let requestDeadline = ContinuousClock.now + .seconds(5)
        var requestedBeforeRelease = await executor.currentRequestedComputeDescriptionForTesting()
        while !requestedBeforeRelease.contains("cpuOnly"), ContinuousClock.now < requestDeadline {
            try await Task.sleep(for: .milliseconds(5))
            requestedBeforeRelease = await executor.currentRequestedComputeDescriptionForTesting()
        }
        XCTAssertTrue(requestedBeforeRelease.contains("cpuOnly"))
        gate.release.signal()
        await holder.value
        await transition.value
        await run.value
        let actual = await registry.currentUnits()
        let reported = await executor.currentRequestedComputeDescriptionForTesting()
        print("REVIEW_REQUESTED_POLICY_RACE actual=\(actual) reported=\(reported)")
        XCTAssertEqual(actual, .cpuOnly)
        XCTAssertTrue(reported.contains("cpuOnly"), "A stale entry policy read must not overwrite the newer foreground/background request")
    }

    func testHATEntryReadCannotRestoreForegroundGPUAfterANewerBackgroundRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HATPolicyRace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CoreMLModelRegistry(initialComputeUnits: .all, availabilityPolicy: .requireProductionModels)
        let executor = TiledPipelineExecutor(workingDirectory: directory, modelRegistry: registry,
            checkpointStore: JobCheckpointStore(directory: directory), colorProcessor: MetalColorProcessor(preferMetal: false))
        let config = UpscaleJobConfig(sourceImageURL: directory.appendingPathComponent("missing.png"), backbone: .hatSmall)
        let gate = ReviewPolicyGate()
        let holder = Task { await registry.reviewHoldPolicyActor(gate) }
        await gate.entered.wait()
        defer { gate.release.signal() }
        let entered = ReviewSignal()
        let execution = Task {
            entered.signal()
            do { _ = try await executor.executeOrResumeJob(config: config) } catch {}
        }
        await entered.wait()
        await executor.reviewActorBarrier()
        try await Task.sleep(for: .milliseconds(50))
        let transition = Task { await executor.setBackgroundExecutionMode(true) }
        let deadline = ContinuousClock.now + .seconds(5)
        var pendingDescription = await executor.currentRequestedComputeDescriptionForTesting(modelID: .hatSX2_192)
        while !pendingDescription.contains("cpuAndNeuralEngine"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            pendingDescription = await executor.currentRequestedComputeDescriptionForTesting(modelID: .hatSX2_192)
        }
        XCTAssertTrue(pendingDescription.contains("cpuAndNeuralEngine"), "Publish the safe next-tile request before a busy registry drains")
        gate.release.signal()
        await holder.value
        await transition.value
        await execution.value
        let raw = await registry.currentRequestedUnits()
        let effective = await registry.currentUnits(for: .hatSX2_192)
        let finalDescription = await executor.currentRequestedComputeDescriptionForTesting(modelID: .hatSX2_192)
        XCTAssertEqual(raw, .cpuAndNeuralEngine)
        XCTAssertEqual(effective, .cpuAndNeuralEngine)
        XCTAssertTrue(finalDescription.contains("cpuAndNeuralEngine"), "The stale foreground entry read cannot overwrite a newer background request")
    }
}

private final class ReviewSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func signal() { lock.lock(); signalled = true; let pending = waiters; waiters = []; lock.unlock(); for p in pending { p.resume() } }
    func wait() async { await withCheckedContinuation { c in enqueue(c) } }
    private func enqueue(_ c: CheckedContinuation<Void,Never>) { lock.lock(); if signalled { lock.unlock();c.resume() } else { waiters.append(c);lock.unlock() } }
}
private final class ReviewPolicyGate: @unchecked Sendable {
    let entered = ReviewSignal()
    let release = DispatchSemaphore(value: 0)
}
private final class ReviewPauseResult: @unchecked Sendable {
    private let lock = NSLock(); private var value: Bool?
    func set(_ v: Bool) { lock.lock();value=v;lock.unlock() }
    func get() -> Bool? { lock.lock();defer {lock.unlock()};return value }
}

private extension CoreMLModelRegistry {
    // Test-target-only scheduling gate. Production Sources remain unchanged.
    func reviewHoldPolicyActor(_ gate: ReviewPolicyGate) {
        gate.entered.signal()
        gate.release.wait()
    }
}

private extension TiledPipelineExecutor { func reviewActorBarrier() {} }
