import XCTest
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import BackgroundJobManager
@testable import TiledInferenceEngine
@testable import TruongScalerCore

extension CoreMLModelRegistry {
    fileprivate func holdModelQueueForBackgroundTest(entered: LockedValue<Bool>, gate: DispatchSemaphore) {
        entered.set(true)
        gate.wait()
    }
}

// MARK: - Deterministic adapters (macOS has no BackgroundTasks / ActivityKit)

/// Thread-safe recorder shared by fakes when a test must assert cross-adapter ordering.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func index(of event: String) -> Int? {
        events.firstIndex(of: event)
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    init(_ value: Value? = nil) {
        self.value = value
    }

    var current: Value? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

final class RecordingBackgroundTaskScheduler: BackgroundTaskScheduling, @unchecked Sendable {
    struct Submission: Sendable, Equatable {
        let identifier: String
        let title: String
        let subtitle: String
    }

    private let lock = NSLock()
    private var registered: [String] = []
    private var handlers: [String: @Sendable (AnyObject) -> Void] = [:]
    private var submitted: [Submission] = []
    private var cancelled: [String] = []

    var registerError: Error?
    var submitError: Error?
    /// Runs (and is awaited) at the start of every submission; used to observe executor tier ordering.
    var submissionObserver: (@Sendable () async -> Void)?
    /// Invoked synchronously at the end of every successful registration (order assertions).
    var registrationObserver: (@Sendable (String) -> Void)?

    var registeredIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    var registrationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return registered.count
    }

    /// Simulates the system invoking the launch handler for a registered concrete identifier.
    func launch(identifier: String, task: AnyObject) -> Bool {
        lock.lock()
        let handler = handlers[identifier]
        lock.unlock()
        guard let handler else { return false }
        handler(task)
        return true
    }

    var submissions: [Submission] {
        lock.lock(); defer { lock.unlock() }
        return submitted
    }

    var cancelledIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func registerContinuedProcessing(
        identifier: String,
        launchHandler: @escaping @Sendable (AnyObject) -> Void
    ) throws {
        if let registerError { throw registerError }
        lock.lock()
        registered.append(identifier)
        handlers[identifier] = launchHandler
        lock.unlock()
        registrationObserver?(identifier)
    }

    func submitContinuedProcessing(_ descriptor: ContinuedProcessingRequestDescriptor) async throws {
        if let observer = submissionObserver {
            await observer()
        }
        if let submitError { throw submitError }
        recordSubmission(Submission(
            identifier: descriptor.identifier,
            title: descriptor.title,
            subtitle: descriptor.subtitle
        ))
    }

    private func recordSubmission(_ submission: Submission) {
        lock.lock()
        submitted.append(submission)
        lock.unlock()
    }

    func cancelContinuedProcessing(identifier: String) {
        lock.lock()
        cancelled.append(identifier)
        lock.unlock()
    }
}

final class FakeContinuedProcessingTask: ContinuedProcessingTaskAdapter, @unchecked Sendable {
    let identifier: String
    private let lock = NSLock()
    private var expirationHandler: (@Sendable () -> Void)?
    private var expirationHandlerInstallCount = 0
    private var completedUnits: Int64 = 0
    private var totalUnits: Int64 = 0
    private var progressUpdateCount = 0
    private var completions: [Bool] = []
    private var statuses: [(String, String)] = []

    init(identifier: String) {
        self.identifier = identifier
    }

    var hasExpirationHandler: Bool {
        lock.lock(); defer { lock.unlock() }
        return expirationHandler != nil
    }

    var installCount: Int {
        lock.lock(); defer { lock.unlock() }
        return expirationHandlerInstallCount
    }

    var completedUnitCount: Int64 {
        lock.lock(); defer { lock.unlock() }
        return completedUnits
    }

    var totalUnitCount: Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalUnits
    }

    var progressSyncCount: Int {
        lock.lock(); defer { lock.unlock() }
        return progressUpdateCount
    }

    var completionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return completions.count
    }

    var statusValues: [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        return statuses
    }

    func setStatus(title: String, subtitle: String) {
        lock.lock(); defer { lock.unlock() }
        statuses.append((title, subtitle))
    }

    var lastCompletionSuccess: Bool? {
        lock.lock(); defer { lock.unlock() }
        return completions.last
    }

    func installExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        expirationHandler = handler
        expirationHandlerInstallCount += 1
        lock.unlock()
    }

    func setProgress(completedUnitCount: Int64, totalUnitCount: Int64) {
        lock.lock()
        completedUnits = completedUnitCount
        totalUnits = totalUnitCount
        progressUpdateCount += 1
        lock.unlock()
    }

    func setTaskCompleted(success: Bool) {
        lock.lock()
        completions.append(success)
        lock.unlock()
    }

    func fireExpiration() {
        lock.lock()
        let handler = expirationHandler
        lock.unlock()
        handler?()
    }
}

final class RecordingLegacyAssertionProvider: LegacyBackgroundAssertionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0
    private var expirationHandler: (@Sendable () -> Void)?
    private let recorder: EventRecorder?

    init(recorder: EventRecorder? = nil) {
        self.recorder = recorder
    }

    var beginCount: Int {
        lock.lock(); defer { lock.unlock() }
        return begun
    }

    var endCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UUID? {
        recordBegin(expirationHandler)
        return UUID()
    }

    func endBackgroundTask(token: UUID) async {
        recordEnd()
        recorder?.record("endLegacyAssertion")
    }

    private func recordBegin(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        begun += 1
        self.expirationHandler = handler
        lock.unlock()
    }

    private func recordEnd() {
        lock.lock()
        ended += 1
        lock.unlock()
    }

    func fireExpiration() {
        lock.lock()
        let handler = expirationHandler
        lock.unlock()
        handler?()
    }
}

@MainActor
final class RecordingLiveActivityController: LiveActivityControlling {
    private(set) var lastKnownState: UpscaleActivityAttributes.ContentState?
    private(set) var events: [String] = []
    private(set) var activityLifecycleIdentity: UInt64?
    private var latestStartRequestIdentity: UInt64 = 0
    private var lifecycleCounter: UInt64 = 0
    private let recorder: EventRecorder?

    /// Gated reentrancy seams: awaited after the state mutation and before the call returns, so a
    /// test can start/complete another job while this activity call is suspended.
    var startActivityHook: (@Sendable () async -> Void)?
    var updateProgressHook: (@Sendable () async -> Void)?
    var markCompletedHook: (@Sendable () async -> Void)?
    var markFailedHook: (@Sendable () async -> Void)?
    var markCancelledHook: (@Sendable () async -> Void)?
    var markPausedHook: (@Sendable () async -> Void)?
    /// Awaited before the identity gate of the gated `markFailed`, modelling a failure call that is
    /// scheduled onto the MainActor only after a newer job has started.
    var markFailedGateHook: (@Sendable () async -> Void)?

    init(recorder: EventRecorder? = nil) {
        self.recorder = recorder
    }

    func startActivity(
        jobID: UUID,
        sourceFileName: String,
        scaleFactor: ScaleFactor,
        targetWidth: Int,
        targetHeight: Int,
        totalTiles: Int
    ) {
        events.append("start")
        lifecycleCounter &+= 1
        activityLifecycleIdentity = lifecycleCounter
        lastKnownState = UpscaleActivityAttributes.ContentState(
            stageTitle: "Preparing tiles…",
            completedTiles: 0,
            totalTiles: max(0, totalTiles),
            progressFraction: 0.0,
            estimatedSecondsRemaining: nil
        )
    }

    func updateProgress(
        stageTitle: String,
        completedTiles: Int,
        totalTiles: Int,
        progressFraction: Double,
        estimatedSecondsRemaining: Int?,
        forceImmediate: Bool
    ) async {
        events.append("update")
        lastKnownState = UpscaleActivityAttributes.ContentState(
            stageTitle: stageTitle,
            completedTiles: min(max(0, completedTiles), max(0, totalTiles)),
            totalTiles: max(0, totalTiles),
            progressFraction: progressFraction,
            estimatedSecondsRemaining: estimatedSecondsRemaining
        )
        if let hook = updateProgressHook { await hook() }
    }

    func markPaused(completedTiles: Int, totalTiles: Int) async {
        events.append("paused")
        recorder?.record("paused")
        lastKnownState = UpscaleActivityAttributes.ContentState(
            stageTitle: "Paused",
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            progressFraction: totalTiles > 0 ? Double(completedTiles) / Double(totalTiles) : 0,
            estimatedSecondsRemaining: nil,
            isPaused: true,
            statusMessage: "Paused at \(completedTiles)/\(totalTiles)",
            phase: .paused
        )
        if let hook = markPausedHook { await hook() }
    }

    func markCompleted(completedTiles: Int, totalTiles: Int, finalMessage: String) async {
        events.append("completed")
        lastKnownState = UpscaleActivityAttributes.ContentState(
            stageTitle: finalMessage,
            completedTiles: totalTiles,
            totalTiles: totalTiles,
            progressFraction: 1.0,
            estimatedSecondsRemaining: 0,
            statusMessage: finalMessage,
            phase: .completed
        )
        activityLifecycleIdentity = nil
        if let hook = markCompletedHook { await hook() }
    }

    func markCancelled(completedTiles: Int, totalTiles: Int, message: String) async {
        events.append("cancelled")
        lastKnownState = UpscaleActivityAttributes.ContentState(
            stageTitle: message,
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            progressFraction: totalTiles > 0 ? Double(completedTiles) / Double(totalTiles) : 0,
            estimatedSecondsRemaining: nil,
            statusMessage: message,
            phase: .cancelled
        )
        activityLifecycleIdentity = nil
        if let hook = markCancelledHook { await hook() }
    }

    func markFailed(completedTiles: Int, totalTiles: Int, message: String) async {
        events.append("failed")
        lastKnownState = UpscaleActivityAttributes.ContentState(
            stageTitle: message,
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            progressFraction: totalTiles > 0 ? Double(completedTiles) / Double(totalTiles) : 0,
            estimatedSecondsRemaining: nil,
            statusMessage: message,
            phase: .failed
        )
        activityLifecycleIdentity = nil
        if let hook = markFailedHook { await hook() }
    }

    func endActivity(finalMessage: String, dismissPolicySeconds: TimeInterval) async {
        events.append("ended")
        lastKnownState = UpscaleActivityAttributes.ContentState(
            stageTitle: finalMessage,
            completedTiles: lastKnownState?.completedTiles ?? 0,
            totalTiles: lastKnownState?.totalTiles ?? 0,
            progressFraction: 1.0,
            estimatedSecondsRemaining: 0,
            statusMessage: finalMessage,
            phase: .completed
        )
        activityLifecycleIdentity = nil
    }

    // MARK: - Identity-aware mutations (mirrors LiveActivityController)

    @discardableResult
    func startActivity(
        jobID: UUID,
        sourceFileName: String,
        scaleFactor: ScaleFactor,
        targetWidth: Int,
        targetHeight: Int,
        totalTiles: Int,
        ifNewerThanRequestIdentity requestIdentity: UInt64
    ) async -> Bool {
        guard requestIdentity > latestStartRequestIdentity else { return false }
        latestStartRequestIdentity = requestIdentity
        startActivity(
            jobID: jobID,
            sourceFileName: sourceFileName,
            scaleFactor: scaleFactor,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            totalTiles: totalTiles
        )
        activityLifecycleIdentity = requestIdentity
        if let hook = startActivityHook { await hook() }
        return true
    }

    @discardableResult
    func updateProgress(
        stageTitle: String,
        completedTiles: Int,
        totalTiles: Int,
        progressFraction: Double,
        estimatedSecondsRemaining: Int?,
        forceImmediate: Bool,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool {
        guard activityLifecycleIdentity == expectedIdentity else { return false }
        await updateProgress(
            stageTitle: stageTitle,
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            progressFraction: progressFraction,
            estimatedSecondsRemaining: estimatedSecondsRemaining,
            forceImmediate: forceImmediate
        )
        return true
    }

    @discardableResult
    func markPaused(
        completedTiles: Int,
        totalTiles: Int,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool {
        guard activityLifecycleIdentity == expectedIdentity else { return false }
        await markPaused(completedTiles: completedTiles, totalTiles: totalTiles)
        return true
    }

    @discardableResult
    func markCompleted(
        completedTiles: Int,
        totalTiles: Int,
        finalMessage: String,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool {
        guard activityLifecycleIdentity == expectedIdentity else { return false }
        await markCompleted(
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            finalMessage: finalMessage
        )
        return true
    }

    @discardableResult
    func markCancelled(
        completedTiles: Int,
        totalTiles: Int,
        message: String,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool {
        guard activityLifecycleIdentity == expectedIdentity else { return false }
        await markCancelled(
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            message: message
        )
        return true
    }

    @discardableResult
    func markFailed(
        completedTiles: Int,
        totalTiles: Int,
        message: String,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool {
        if let hook = markFailedGateHook { await hook() }
        guard activityLifecycleIdentity == expectedIdentity else { return false }
        await markFailed(
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            message: message
        )
        return true
    }
}

/// One-shot async signal used to suspend a controller call at a deterministic point.
final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Opaque framework-side task token. Two different adapter wrappers can point at one raw task, the
/// same way two `BGContinuedProcessingTaskAdapter` values can wrap one `BGTask`.
final class RawContinuedProcessingTaskToken: @unchecked Sendable {}

// MARK: - Tests

final class BackgroundTaskIntegrationTests: XCTestCase {
    private var workingDirectory: URL!
    private var recorder: EventRecorder!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BackgroundTaskIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        recorder = EventRecorder()
    }

    override func tearDownWithError() throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
        recorder = nil
    }

    // MARK: Harness

    private struct Harness {
        let coordinator: BackgroundExecutionCoordinator
        let registry: CoreMLModelRegistry
        let executor: TiledPipelineExecutor
        let scheduler: RecordingBackgroundTaskScheduler
        let assertions: RecordingLegacyAssertionProvider
        let activity: RecordingLiveActivityController
        let router: BackgroundTaskDeliveryRouter
    }

    private func makeHarness() async throws -> Harness {
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let store = try JobCheckpointStore(workingDirectory: workingDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let recorder = self.recorder
        let activity = await MainActor.run {
            RecordingLiveActivityController(recorder: recorder)
        }
        let scheduler = RecordingBackgroundTaskScheduler()
        let assertions = RecordingLegacyAssertionProvider(recorder: recorder)
        let router = BackgroundTaskDeliveryRouter()
        let coordinator = BackgroundExecutionCoordinator(
            executor: executor,
            liveActivityController: activity,
            scheduler: scheduler,
            legacyAssertionProvider: assertions,
            deliveryRouter: router,
            // The fake scheduler launches our protocol adapter, not an Apple BGTask. Inject
            // that boundary explicitly on both platforms; iOS production must keep rejecting
            // arbitrary objects through its real ContinuedProcessingTaskAdapterFactory.
            deliveryFactory: { rawTask in
                BackgroundTaskDelivery(rawTask: rawTask,
                    continuedProcessingTask: rawTask as? any ContinuedProcessingTaskAdapter)
            }
        )
        coordinator.installDeliveryHandler(on: router)
        return Harness(
            coordinator: coordinator,
            registry: registry,
            executor: executor,
            scheduler: scheduler,
            assertions: assertions,
            activity: activity,
            router: router
        )
    }

    private func descriptor(jobID: UUID = UUID(), totalTiles: Int = 12) -> BackgroundJobDescriptor {
        BackgroundJobDescriptor(
            jobID: jobID,
            sourceFileName: "IMG_0001.dng",
            scaleFactor: .x4,
            targetWidth: 8064,
            targetHeight: 6048,
            totalTiles: totalTiles
        )
    }

    private func progressUpdate(
        jobID: UUID,
        completedTiles: Int,
        totalTiles: Int
    ) -> PipelineProgressUpdate {
        let fraction = totalTiles > 0
            ? 0.10 + 0.90 * (Double(completedTiles) / Double(totalTiles))
            : 0.10
        return PipelineProgressUpdate(
            jobID: jobID,
            stage: .denoisingAndUpscalingTiles,
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            overallFraction: fraction,
            estimatedSecondsRemaining: 30,
            currentTileDescriptor: nil
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 2.0,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - Lifecycle

    func testForegroundGatedBatchStartDefersWithoutDisturbingPreviousContinuation() async throws {
        let h = try await makeHarness(), first = descriptor(), next = descriptor()
        await h.coordinator.startJob(first)
        await h.coordinator.handleWillResignActive()
        let task = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: first.jobID)
        )
        h.router.deliver(.init(rawTask: task, continuedProcessingTask: task))
        let adopted = await waitUntilAsync { await h.coordinator.hasActiveDeliveredTask() }
        XCTAssertTrue(adopted)
        let eventsBefore = await h.activity.events
        let requestsBefore = h.scheduler.submissions
        let cancellationsBefore = h.scheduler.cancelledIdentifiers
        let assertionsBefore = h.assertions.beginCount

        let deferred = await h.coordinator.startJob(next, requiresForegroundStart: true)
        XCTAssertEqual(deferred, .deferred)
        let eventsAfterDeferral = await h.activity.events
        XCTAssertEqual(eventsAfterDeferral, eventsBefore)
        XCTAssertEqual(h.scheduler.submissions, requestsBefore)
        XCTAssertEqual(h.scheduler.cancelledIdentifiers, cancellationsBefore)
        XCTAssertEqual(h.assertions.beginCount, assertionsBefore)
        XCTAssertEqual(task.completionCount, 0, "A refused start must not retire the earlier job's continuation")
        await h.coordinator.updateProgress(progressUpdate(jobID: first.jobID, completedTiles: 3, totalTiles: 12))
        XCTAssertEqual(task.completedUnitCount, 3)

        await h.coordinator.completeJob(success: true, message: "First saved")
        XCTAssertEqual(task.completionCount, 1)
        let eventsAfterCompletion = await h.activity.events
        let deferredAfterCompletion = await h.coordinator.startJob(next, requiresForegroundStart: true)
        XCTAssertEqual(deferredAfterCompletion, .deferred)
        let eventsAfterSecondDeferral = await h.activity.events
        XCTAssertEqual(eventsAfterSecondDeferral, eventsAfterCompletion)
        // Neither deferral advanced the job generation or registered a run for the next photo.
        let incorrectlyRegistered = await h.executor.requestGracefulPauseAndWait(
            ifOwner: ExecutionPauseOwner(jobID: next.jobID, generation: 2)
        )
        XCTAssertFalse(incorrectlyRegistered)

        await h.coordinator.handleDidBecomeActive()
        let retry = await h.coordinator.startJob(next, requiresForegroundStart: true)
        XCTAssertEqual(retry, .started)
        let eventsAfterRetry = await h.activity.events
        XCTAssertEqual(eventsAfterRetry.filter { $0 == "start" }.count, 2)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.scheduler.submissions.last?.identifier,
            BackgroundExecutionCoordinator.submittedTaskIdentifier(for: next.jobID))
        await h.coordinator.completeJob(success: true, message: "Next saved")
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    func testForegroundGatedAdoptionBeforeInactiveKeepsItsNewContinuation() async throws {
        let h = try await makeHarness(), job = descriptor()
        let entered = AsyncSignal(), release = AsyncSignal()
        await MainActor.run {
            h.activity.startActivityHook = { entered.signal(); await release.wait() }
        }
        let start = Task { await h.coordinator.startJob(job, requiresForegroundStart: true) }
        await entered.wait()
        // The coordinator already owns this descriptor while the ActivityKit hop is suspended.
        // Inactive must prepare that same job, rather than deferring an adopted run afterwards.
        await h.coordinator.handleWillResignActive()
        let identifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        XCTAssertEqual(h.scheduler.submissions.map(\.identifier), [identifier])
        XCTAssertEqual(h.assertions.beginCount, 1)
        let task = FakeContinuedProcessingTask(identifier: identifier)
        h.router.deliver(.init(rawTask: task, continuedProcessingTask: task))
        let adopted = await waitUntilAsync { await h.coordinator.hasActiveDeliveredTask() }
        XCTAssertTrue(adopted)
        release.signal()
        let startResult = await start.value
        XCTAssertEqual(startResult, .started)
        await h.coordinator.updateProgress(progressUpdate(jobID: job.jobID, completedTiles: 4, totalTiles: 12))
        XCTAssertEqual(task.completedUnitCount, 4)
        XCTAssertEqual(task.completionCount, 0)
        await h.coordinator.completeJob(success: true, message: "Saved")
        XCTAssertEqual(task.completionCount, 1)
        XCTAssertEqual(task.lastCompletionSuccess, true)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    func testForegroundGatedSuspendedStartReportsSupersededAfterCancellation() async throws {
        let h = try await makeHarness(), job = descriptor()
        let entered = AsyncSignal(), release = AsyncSignal()
        await MainActor.run {
            h.activity.startActivityHook = { entered.signal(); await release.wait() }
        }
        let start = Task { await h.coordinator.startJob(job, requiresForegroundStart: true) }
        await entered.wait()
        await h.coordinator.cancelJob(message: "Stopped before execution")
        release.signal()
        let startResult = await start.value
        XCTAssertEqual(startResult, .superseded)
        let events = await h.activity.events
        XCTAssertEqual(events, ["start", "cancelled"])
        XCTAssertTrue(h.scheduler.submissions.isEmpty)
        XCTAssertEqual(h.assertions.beginCount, 0)
    }

    func testLifecycleTransitionsSubmitOnceWhileForegroundAndBalanceAssertion() async throws {
        let harness = try await makeHarness()
        let job = descriptor()
        let concreteIdentifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        await harness.coordinator.startJob(job)

        var activityEvents = await harness.activity.events
        XCTAssertEqual(activityEvents, ["start"])

        // `.inactive` is the last foregrounded moment: preparation must happen there.
        await harness.coordinator.handleWillResignActive(
            jobTitle: "Upscaling IMG_0001.dng",
            jobSubtitle: "QuickSRNet-Large · 4×"
        )
        XCTAssertEqual(harness.scheduler.submissions.count, 1)
        XCTAssertEqual(harness.scheduler.submissions.first?.identifier, concreteIdentifier)
        XCTAssertEqual(harness.scheduler.submissions.first?.title, "Upscaling IMG_0001.dng")
        XCTAssertEqual(harness.assertions.beginCount, 1)
        var inBackground = await harness.coordinator.isInBackground()
        XCTAssertTrue(inBackground)

        // `.background` arriving after `.inactive` must not submit or assert twice.
        await harness.coordinator.handleDidEnterBackground(
            jobTitle: "Upscaling IMG_0001.dng",
            jobSubtitle: "QuickSRNet-Large · 4×"
        )
        XCTAssertEqual(harness.scheduler.submissions.count, 1)
        XCTAssertEqual(harness.assertions.beginCount, 1)

        // Foreground return cancels the concrete submitted request and balances the assertion.
        await harness.coordinator.handleDidBecomeActive()
        XCTAssertEqual(harness.scheduler.cancelledIdentifiers, [concreteIdentifier])
        XCTAssertEqual(harness.assertions.endCount, 1)
        inBackground = await harness.coordinator.isInBackground()
        XCTAssertFalse(inBackground)
        let computeUnits = await harness.registry.currentUnits()
        XCTAssertEqual(computeUnits, .all)

        // A second background cycle submits exactly one new request and asserts once.
        await harness.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        XCTAssertEqual(harness.scheduler.submissions.count, 2)
        XCTAssertEqual(harness.assertions.beginCount, 2)

        await harness.coordinator.completeJob(success: true, message: "Upscale complete")
        XCTAssertEqual(harness.assertions.endCount, 2, "Every legacy assertion must be balanced")
        activityEvents = await harness.activity.events
        XCTAssertTrue(activityEvents.contains("completed"))
        let state = await harness.activity.lastKnownState
        XCTAssertEqual(state?.phase, .completed)
    }

    func testGrantedContinuationSurvivesForegroundReturnAndDoesNotResubmit() async throws {
        let h = try await makeHarness()
        let job = descriptor()
        await h.coordinator.startJob(job)
        await h.coordinator.handleWillResignActive()
        let task = FakeContinuedProcessingTask(identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID))
        h.router.deliver(.init(rawTask: task, continuedProcessingTask: task))
        let adopted = await waitUntilAsync { await h.coordinator.hasActiveDeliveredTask() }
        XCTAssertTrue(adopted)
        await h.coordinator.handleDidBecomeActive()
        XCTAssertEqual(task.completionCount, 0, "Returning to the foreground must not fail an unfinished system job")
        let remainsActive = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertTrue(remainsActive)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.scheduler.submissions.count, 1, "Reuse the live continuation instead of queueing a duplicate")
        await h.coordinator.updateProgress(progressUpdate(jobID: job.jobID, completedTiles: 3, totalTiles: 10))
        XCTAssertEqual(task.completedUnitCount, 3)
        await h.coordinator.completeJob(success: true, message: "Done")
        XCTAssertEqual(task.completionCount, 1)
        XCTAssertEqual(task.lastCompletionSuccess, true)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    func testGrantedContinuationReleasesShortAssertionAndIgnoresItsLateExpiry() async throws {
        let h = try await makeHarness()
        let job = descriptor()
        await h.coordinator.startJob(job)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 1)
        let task = FakeContinuedProcessingTask(identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID))
        h.router.deliver(.init(rawTask: task, continuedProcessingTask: task))
        let released = await waitUntil { h.assertions.endCount == 1 }
        h.assertions.fireExpiration()
        try await Task.sleep(for: .milliseconds(50))
        let expired = await h.coordinator.didExpire()
        XCTAssertTrue(released, "The short safety assertion must be released once the real continuation is granted")
        XCTAssertFalse(expired, "An already-released short assertion must not pause a valid long-running task")
        XCTAssertEqual(task.completionCount, 0)
        await h.coordinator.cancelJob()
        XCTAssertEqual(task.completionCount, 1)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    func testBackgroundRequestAndAssertionDoNotWaitForAnInFlightModel() async throws {
        let harness = try await makeHarness()
        await harness.coordinator.startJob(descriptor())
        let entered = LockedValue(false)
        let gate = DispatchSemaphore(value: 0)
        let held = Task { await harness.registry.holdModelQueueForBackgroundTest(entered: entered, gate: gate) }
        let didEnter = await waitUntil { entered.current == true }
        XCTAssertTrue(didEnter)
        defer { gate.signal() }

        let transition = Task {
            await harness.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "4×")
        }
        let protectedBeforePredictionFinished = await waitUntil(timeout: 0.5) {
            harness.scheduler.submissions.count == 1 && harness.assertions.beginCount == 1
        }
        gate.signal()
        await held.value
        await transition.value
        await harness.coordinator.handleDidBecomeActive()
        XCTAssertTrue(protectedBeforePredictionFinished,
                      "A long Core ML load/prediction must not delay foreground submission or the safety assertion")
        XCTAssertEqual(harness.assertions.beginCount, harness.assertions.endCount)
    }

    func testForegroundReleasesBridgeBeforeModelFinishesAndNextCycleGetsFreshAssertion() async throws {
        let h = try await makeHarness()
        await h.coordinator.startJob(descriptor())
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 1)

        let entered = LockedValue(false)
        let gate = DispatchSemaphore(value: 0)
        let held = Task { await h.registry.holdModelQueueForBackgroundTest(entered: entered, gate: gate) }
        let didEnter = await waitUntil { entered.current == true }
        XCTAssertTrue(didEnter)
        defer { gate.signal() }
        let foreground = Task { await h.coordinator.handleDidBecomeActive() }
        let releasedBeforePredictionFinished = await waitUntil(timeout: 0.5) { h.assertions.endCount == 1 }
        let backgroundAgain = Task { await h.coordinator.handleWillResignActive() }
        let freshAssertionBeforePredictionFinished = await waitUntil(timeout: 0.5) {
            h.scheduler.submissions.count == 2 && h.assertions.beginCount == 2
        }
        gate.signal()
        await held.value
        await foreground.value
        await backgroundAgain.value
        XCTAssertTrue(releasedBeforePredictionFinished, "Foreground cleanup must not wait behind a model call")
        XCTAssertTrue(freshAssertionBeforePredictionFinished, "The next background cycle needs its own assertion/expiration handler")
        XCTAssertEqual(h.assertions.endCount, 1, "Delayed foreground cleanup must not release the newer cycle's assertion")
        await h.coordinator.handleDidBecomeActive()
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    func testBackgroundModeSwitchesBeforeSubmission() async throws {
        let harness = try await makeHarness()
        let job = descriptor()
        await harness.coordinator.startJob(job)

        let policyAtSubmit = LockedValue<String>()
        harness.scheduler.submissionObserver = { [executor = harness.executor] in
            policyAtSubmit.set(await executor.currentRequestedComputeDescriptionForTesting())
        }

        await harness.coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        XCTAssertTrue(policyAtSubmit.current?.contains("cpuAndNeuralEngine") == true)
        let settledUnits = await harness.registry.currentUnits()
        XCTAssertEqual(settledUnits, .cpuAndNeuralEngine)
        XCTAssertEqual(harness.scheduler.submissions.count, 1)
        await harness.coordinator.handleDidBecomeActive()
    }

    func testSubmitFailureIsSurfacedInsteadOfSwallowed() async throws {
        let harness = try await makeHarness()
        let job = descriptor()
        await harness.coordinator.startJob(job)

        let failure = ScalerError.backgroundTaskSchedulingFailed(reason: "test refusal")
        harness.scheduler.submitError = failure
        await harness.coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")

        let reportedError = await harness.coordinator.schedulingError()
        XCTAssertEqual(reportedError, failure.localizedDescription)
        XCTAssertEqual(harness.assertions.beginCount, 1, "The legacy assertion still protects the work")
        await harness.coordinator.handleDidBecomeActive()
        XCTAssertEqual(harness.assertions.endCount, 1)
    }

    func testSchedulingNoticeBelongsOnlyToItsRunningJob() async throws {
        let harness = try await makeHarness()
        let first = descriptor(), second = descriptor()
        let firstFailure = ScalerError.backgroundTaskSchedulingFailed(reason: "first job refusal")
        let secondFailure = ScalerError.backgroundTaskSchedulingFailed(reason: "second job refusal")
        await harness.coordinator.startJob(first)
        harness.scheduler.submitError = firstFailure
        await harness.coordinator.handleDidEnterBackground(jobTitle: "First", jobSubtitle: "2×")
        let firstNotice = await harness.coordinator.schedulingError(for: first.jobID)
        let wrongNotice = await harness.coordinator.schedulingError(for: second.jobID)
        XCTAssertEqual(firstNotice, firstFailure.localizedDescription)
        XCTAssertNil(wrongNotice)

        await harness.coordinator.handleDidBecomeActive()
        await harness.coordinator.startJob(second)
        let inherited = await harness.coordinator.schedulingError()
        let stale = await harness.coordinator.schedulingError(for: first.jobID)
        let clean = await harness.coordinator.schedulingError(for: second.jobID)
        XCTAssertNil(inherited)
        XCTAssertNil(stale)
        XCTAssertNil(clean)

        harness.scheduler.submitError = secondFailure
        await harness.coordinator.handleDidEnterBackground(jobTitle: "Second", jobSubtitle: "2×")
        let current = await harness.coordinator.schedulingError(for: second.jobID)
        XCTAssertEqual(current, secondFailure.localizedDescription)
        await harness.coordinator.completeJob(success: false, message: "Finished")
        let idle = await harness.coordinator.schedulingError(for: second.jobID)
        let diagnostic = await harness.coordinator.schedulingError()
        XCTAssertNil(idle)
        XCTAssertEqual(diagnostic, secondFailure.localizedDescription)
    }

    func testBackgroundPreparationRegistersConcreteIdentifierBeforeSubmittingAndOnlyOnce() async throws {
        let harness = try await makeHarness()
        let job = descriptor()
        let concreteIdentifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        let order = EventRecorder()
        harness.scheduler.registrationObserver = { identifier in
            order.record("register:\(identifier)")
        }
        harness.scheduler.submissionObserver = {
            order.record("submit")
        }

        await harness.coordinator.startJob(job)
        await harness.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")

        // The wildcard is only the plist family declaration; the registered handler and submitted
        // request are the same concrete job-scoped identifier, registered first.
        XCTAssertEqual(harness.scheduler.registeredIdentifiers, [concreteIdentifier])
        XCTAssertEqual(harness.scheduler.submissions.map(\.identifier), [concreteIdentifier])
        XCTAssertEqual(order.events, ["register:\(concreteIdentifier)", "submit"])

        // Foreground return and a second background cycle for the same job must not re-register
        // (a duplicate BGTaskScheduler registration is fatal), but must re-submit once.
        await harness.coordinator.handleDidBecomeActive()
        await harness.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        XCTAssertEqual(harness.scheduler.registrationCount, 1)
        XCTAssertEqual(harness.scheduler.registeredIdentifiers, [concreteIdentifier])
        XCTAssertEqual(harness.scheduler.submissions.count, 2)
        await harness.coordinator.handleDidBecomeActive()
    }

    func testRegistrationFailureIsNonfatalAndSkipsSubmission() async throws {
        let harness = try await makeHarness()
        let job = descriptor()
        await harness.coordinator.startJob(job)

        let refusal = ScalerError.backgroundTaskSchedulingFailed(
            reason: "The system refused the concrete continued-processing identifier."
        )
        harness.scheduler.registerError = refusal

        await harness.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")

        XCTAssertTrue(harness.scheduler.registeredIdentifiers.isEmpty)
        XCTAssertTrue(harness.scheduler.submissions.isEmpty, "Never submit a request whose handler was refused")
        XCTAssertEqual(harness.assertions.beginCount, 1, "The legacy assertion still protects foreground work")
        let reported = await harness.coordinator.schedulingError()
        XCTAssertNotNil(reported)
        XCTAssertTrue(reported?.contains(refusal.localizedDescription) == true)

        // A second background cycle for the same job does not retry registration or submit. The
        // failure stays actionable and foreground processing remains usable.
        await harness.coordinator.handleDidBecomeActive()
        await harness.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        XCTAssertEqual(harness.scheduler.registrationCount, 0)
        XCTAssertTrue(harness.scheduler.submissions.isEmpty)

        await harness.coordinator.handleDidBecomeActive()
        let units = await harness.registry.currentUnits()
        XCTAssertEqual(units, .all)
        await harness.coordinator.completeJob(success: true, message: "Foreground upscale complete")
    }

    func testRegisteredConcreteHandlerRoutesDeliveredTaskToRouter() async throws {
        let harness = try await makeHarness()
        let job = descriptor()
        let concreteIdentifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        await harness.coordinator.startJob(job)
        await harness.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        XCTAssertEqual(harness.scheduler.registeredIdentifiers, [concreteIdentifier])

        let task = FakeContinuedProcessingTask(identifier: concreteIdentifier)
        let launched = harness.scheduler.launch(identifier: concreteIdentifier, task: task)
        XCTAssertTrue(launched)

        let adopted = await waitUntil { task.hasExpirationHandler }
        let diagnostic = await harness.coordinator.schedulingError()
        XCTAssertTrue(adopted, "delivery was not adopted; schedulingError=\(diagnostic ?? "nil")")
        XCTAssertEqual(harness.router.deliveredTaskCount, 1)
        XCTAssertEqual(harness.router.retainedTaskCount, 1)

        await harness.coordinator.completeJob(success: true, message: "Upscale complete")
        XCTAssertEqual(task.completionCount, 1)
        XCTAssertEqual(harness.router.retainedTaskCount, 0)
        await harness.coordinator.handleDidBecomeActive()
    }

    func testDifferentJobsUseDistinctConcreteRegisteredIdentifiers() async throws {
        let harness = try await makeHarness()
        let first = descriptor(jobID: UUID())
        let second = descriptor(jobID: UUID())
        await harness.coordinator.startJob(first)
        await harness.coordinator.handleWillResignActive()
        await harness.coordinator.completeJob(success: true, message: "First complete")
        await harness.coordinator.handleDidBecomeActive()

        await harness.coordinator.startJob(second)
        await harness.coordinator.handleWillResignActive()

        let expected = [
            BackgroundExecutionCoordinator.submittedTaskIdentifier(for: first.jobID),
            BackgroundExecutionCoordinator.submittedTaskIdentifier(for: second.jobID),
        ]
        XCTAssertEqual(harness.scheduler.registeredIdentifiers, expected)
        XCTAssertEqual(Set(harness.scheduler.registeredIdentifiers).count, 2)
        await harness.coordinator.completeJob(success: true, message: "Second complete")
        await harness.coordinator.handleDidBecomeActive()
    }

    func testSystemProgressReservesPublicationUnitUntilPhotoIsSaved() async throws {
        let harness = try await makeHarness()
        let job = BackgroundJobDescriptor(jobID: UUID(), sourceFileName: "photo.dng", scaleFactor: .x2,
            targetWidth: 96, targetHeight: 64, totalTiles: 12, includesOutputPublication: true)
        let task = FakeContinuedProcessingTask(identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID))
        await harness.coordinator.startJob(job)
        await harness.coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "2×")
        harness.router.deliver(BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task))
        let delivered = await waitUntil { task.hasExpirationHandler }
        XCTAssertTrue(delivered)
        await harness.coordinator.updateProgress(progressUpdate(jobID: job.jobID, completedTiles: 12, totalTiles: 12))
        XCTAssertEqual(task.completedUnitCount, 12)
        XCTAssertEqual(task.totalUnitCount, 13)
        XCTAssertEqual(task.completionCount, 0)
        await harness.coordinator.completeJob(success: true, message: "Photo saved")
        XCTAssertEqual(task.completionCount, 1)
        XCTAssertEqual(task.lastCompletionSuccess, true)
        await harness.coordinator.handleDidBecomeActive()
    }

    func testNativeStatusIsStableAcrossTileSubphasesAndDelayedRefreshCannotOutliveJob() async throws {
        let harness = try await makeHarness(), job = descriptor(jobID: UUID(), totalTiles: 12)
        let task = FakeContinuedProcessingTask(identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID))
        await harness.coordinator.startJob(job)
        await harness.coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "2×")
        harness.router.deliver(BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task))
        let delivered = await waitUntil { task.hasExpirationHandler }
        XCTAssertTrue(delivered)
        let phases: [PipelinePhase] = [.extractingTile, .predictingSuperResolution, .verifyingSuperResolution,
            .reconstructingTile, .blendingTile, .committingTile, .tileCommitted]
        var count: Int?
        for phase in phases {
            await harness.coordinator.updateProgress(PipelineProgressUpdate(jobID: job.jobID,
                stage: .denoisingAndUpscalingTiles, completedTiles: 2, totalTiles: 12, overallFraction: 0.2, estimatedSecondsRemaining: nil,
                phase: phase, currentTileIndex: 2))
            if let count { XCTAssertEqual(task.statusValues.count, count, "Subphases must not re-publish native status") }
            else { count = task.statusValues.count }
            XCTAssertEqual(task.statusValues.last?.0, "Upscaling")
            XCTAssertEqual(task.statusValues.last?.1, "Tile 3/12")
        }
        await harness.coordinator.updateProgress(PipelineProgressUpdate(jobID: job.jobID,
            stage: .denoisingAndUpscalingTiles, completedTiles: 4, totalTiles: 12, overallFraction: 0.4, estimatedSecondsRemaining: nil,
            phase: .predictingSuperResolution, currentTileIndex: 4))
        await harness.coordinator.completeJob(success: false, message: "Stopped")
        let terminalCount = task.statusValues.count
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(task.statusValues.count, terminalCount, "A queued presentation refresh must never revive a completed delivery")
        XCTAssertEqual(task.completionCount, 1)
        await harness.coordinator.handleDidBecomeActive()
    }

    func testDeliveredTaskIsRetainedAndProgressFeedsNSProgress() async throws {
        let harness = try await makeHarness()
        let job = descriptor(jobID: UUID(), totalTiles: 12)
        let concreteIdentifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        let task = FakeContinuedProcessingTask(identifier: concreteIdentifier)

        await harness.coordinator.startJob(job)
        await harness.coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")

        harness.router.deliver(
            BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task)
        )
        let delivered = await waitUntil { task.hasExpirationHandler }
        XCTAssertTrue(delivered)
        XCTAssertEqual(harness.router.deliveredTaskCount, 1)
        XCTAssertEqual(harness.router.retainedTaskCount, 1)

        await harness.coordinator.updateProgress(
            progressUpdate(jobID: job.jobID, completedTiles: 3, totalTiles: 12)
        )
        XCTAssertEqual(task.completedUnitCount, 3)
        XCTAssertEqual(task.totalUnitCount, 12)

        let state = await harness.activity.lastKnownState
        XCTAssertEqual(state?.completedTiles, 3)
        XCTAssertEqual(state?.totalTiles, 12)
        XCTAssertEqual(state?.stageTitle, "Upscaling · tile 3/12")

        // Success completes the delivered task exactly once and releases router retention.
        await harness.coordinator.completeJob(success: true, message: "Upscale complete")
        XCTAssertEqual(task.completionCount, 1)
        XCTAssertEqual(task.lastCompletionSuccess, true)
        XCTAssertEqual(harness.router.retainedTaskCount, 0)

        // A duplicate terminal call must not complete the system task twice.
        await harness.coordinator.completeJob(success: true, message: "Upscale complete")
        XCTAssertEqual(task.completionCount, 1)
        let finalState = await harness.activity.lastKnownState
        XCTAssertEqual(finalState?.phase, .completed)
        XCTAssertEqual(finalState?.progressFraction, 1.0)
    }

    func testExpirationRoutesPauseThenCompletesTaskOnceAndReleasesAssertionAfterPause() async throws {
        let harness = try await makeHarness()
        let job = descriptor(jobID: UUID(), totalTiles: 24)
        let concreteIdentifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        let task = FakeContinuedProcessingTask(identifier: concreteIdentifier)

        await harness.coordinator.startJob(job)
        await harness.coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        XCTAssertEqual(harness.assertions.beginCount, 1)

        harness.router.deliver(BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task))
        let delivered = await waitUntil { task.hasExpirationHandler }
        XCTAssertTrue(delivered)
        await harness.coordinator.updateProgress(
            progressUpdate(jobID: job.jobID, completedTiles: 18, totalTiles: 24)
        )

        // Route through the real expiration handler installed on the delivered task.
        task.fireExpiration()
        let completed = await waitUntil { task.completionCount == 1 }
        XCTAssertTrue(completed)
        XCTAssertEqual(task.lastCompletionSuccess, false)
        XCTAssertEqual(harness.assertions.endCount, 1)

        let expired = await harness.coordinator.didExpire()
        XCTAssertTrue(expired)
        let state = await harness.activity.lastKnownState
        XCTAssertEqual(state?.phase, .paused)
        XCTAssertEqual(state?.isPaused, true)

        // The OS task now owns runtime after delivery, so the short bridge is already released.
        // Actual system-task completion still happens only after the durable pause above.
        let pausedIndex = recorder.index(of: "paused")
        let releaseIndex = recorder.index(of: "endLegacyAssertion")
        XCTAssertNotNil(pausedIndex)
        XCTAssertNotNil(releaseIndex)
        if let pausedIndex, let releaseIndex {
            XCTAssertLessThan(releaseIndex, pausedIndex)
        }

        // Repeated expiration callbacks are idempotent.
        await harness.coordinator.handleBackgroundExpiration(completedTiles: 20, totalTiles: 24)
        XCTAssertEqual(task.completionCount, 1)
        XCTAssertEqual(harness.assertions.endCount, 1)
        XCTAssertEqual(harness.router.retainedTaskCount, 0)
    }

    func testSuccessCancellationAndFailureProduceDistinctTerminalStates() async throws {
        let harness = try await makeHarness()

        // Success
        let successJob = descriptor()
        let successTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: successJob.jobID)
        )
        await harness.coordinator.startJob(successJob)
        harness.router.deliver(BackgroundTaskDelivery(rawTask: successTask, continuedProcessingTask: successTask))
        _ = await waitUntil { successTask.hasExpirationHandler }
        await harness.coordinator.updateProgress(
            progressUpdate(jobID: successJob.jobID, completedTiles: 12, totalTiles: 12)
        )
        await harness.coordinator.completeJob(success: true, message: "Upscale complete")
        var state = await harness.activity.lastKnownState
        XCTAssertEqual(state?.phase, .completed)
        XCTAssertEqual(successTask.lastCompletionSuccess, true)

        // Cancellation
        let cancelJob = descriptor()
        let cancelTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: cancelJob.jobID)
        )
        await harness.coordinator.startJob(cancelJob)
        harness.router.deliver(BackgroundTaskDelivery(rawTask: cancelTask, continuedProcessingTask: cancelTask))
        _ = await waitUntil { cancelTask.hasExpirationHandler }
        await harness.coordinator.cancelJob(message: "Upscale cancelled")
        state = await harness.activity.lastKnownState
        XCTAssertEqual(state?.phase, .cancelled)
        XCTAssertEqual(cancelTask.lastCompletionSuccess, false)

        // Failure
        let failedJob = descriptor()
        let failedTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: failedJob.jobID)
        )
        await harness.coordinator.startJob(failedJob)
        harness.router.deliver(BackgroundTaskDelivery(rawTask: failedTask, continuedProcessingTask: failedTask))
        _ = await waitUntil { failedTask.hasExpirationHandler }
        await harness.coordinator.completeJob(success: false, message: "Model inference failed")
        state = await harness.activity.lastKnownState
        XCTAssertEqual(state?.phase, .failed)
        XCTAssertEqual(failedTask.lastCompletionSuccess, false)

        let events = await harness.activity.events
        XCTAssertTrue(events.contains("completed"))
        XCTAssertTrue(events.contains("cancelled"))
        XCTAssertTrue(events.contains("failed"))
    }

    func testDeliveryWithoutRunningJobIsCompletedVisibly() async throws {
        let harness = try await makeHarness()
        let task = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: UUID())
        )
        harness.router.deliver(BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task))

        let completed = await waitUntil { task.completionCount == 1 }
        XCTAssertTrue(completed)
        XCTAssertEqual(task.lastCompletionSuccess, false)
        XCTAssertEqual(harness.router.retainedTaskCount, 0)
        let state = await harness.activity.lastKnownState
        XCTAssertEqual(state?.phase, .failed)
        let error = await harness.coordinator.schedulingError()
        XCTAssertNotNil(error)
    }

    func testSupersedingDeliveryCompletesTheOlderTaskExactlyOnce() async throws {
        let harness = try await makeHarness()
        let job = descriptor()
        await harness.coordinator.startJob(job)

        let first = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        )
        let second = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        )
        harness.router.deliver(BackgroundTaskDelivery(rawTask: first, continuedProcessingTask: first))
        _ = await waitUntil { first.hasExpirationHandler }
        harness.router.deliver(BackgroundTaskDelivery(rawTask: second, continuedProcessingTask: second))
        _ = await waitUntil { second.hasExpirationHandler }

        XCTAssertEqual(first.completionCount, 1)
        XCTAssertEqual(first.lastCompletionSuccess, false)
        XCTAssertEqual(second.completionCount, 0)
        XCTAssertEqual(harness.router.retainedTaskCount, 1)

        await harness.coordinator.completeJob(success: true, message: "Upscale complete")
        XCTAssertEqual(second.completionCount, 1)
        XCTAssertEqual(harness.router.retainedTaskCount, 0)
    }

    // MARK: - Identifier / plist contract

    func testPermittedIdentifierMatchesInfoPlistAndBundleIdentity() throws {
        let permitted = BackgroundExecutionCoordinator.continuedProcessingTaskIdentifier
        XCTAssertEqual(permitted, "com.iantruong.truongscaler.continued-processing.*")
        XCTAssertTrue(permitted.hasPrefix("com.iantruong.truongscaler."))
        XCTAssertTrue(permitted.hasSuffix(".*"))

        let jobID = UUID()
        let concrete = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: jobID)
        XCTAssertTrue(concrete.hasPrefix("com.iantruong.truongscaler.continued-processing."))
        XCTAssertTrue(BackgroundExecutionCoordinator.isContinuedProcessingIdentifier(concrete))
        XCTAssertTrue(BackgroundExecutionCoordinator.isContinuedProcessingIdentifier(permitted))
        XCTAssertFalse(BackgroundExecutionCoordinator.isContinuedProcessingIdentifier("com.example.other.task"))
        XCTAssertTrue(concrete.contains(jobID.uuidString.replacingOccurrences(of: "-", with: "").uppercased()))

        // The app target plist must declare the same wildcard identifier used at registration.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BackgroundJobManagerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let plistURL = repositoryRoot
            .appendingPathComponent("Targets/TruongScalerApp/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let identifiers = try XCTUnwrap(plist["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        XCTAssertEqual(identifiers, [permitted])

        // Bundle identity is generated from project.yml's PRODUCT_BUNDLE_IDENTIFIER.
        let projectYAML = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(projectYAML.contains("PRODUCT_BUNDLE_IDENTIFIER: com.iantruong.truongscaler"))
    }

    // MARK: - Router contract

    func testRouterQueuesDeliveriesUntilHandlerInstalledAndRetainsThem() {
        let router = BackgroundTaskDeliveryRouter()
        let first = FakeContinuedProcessingTask(identifier: "task.one")
        let second = FakeContinuedProcessingTask(identifier: "task.two")

        router.deliver(BackgroundTaskDelivery(rawTask: first, continuedProcessingTask: first))
        XCTAssertEqual(router.pendingDeliveryCount, 1)
        XCTAssertEqual(router.retainedTaskCount, 1)

        let received = LockedValue<[String]>([String]())
        router.installHandler { delivery in
            if let adapter = delivery.continuedProcessingTask {
                received.set((received.current ?? []) + [adapter.identifier])
            }
        }
        XCTAssertEqual(received.current, ["task.one"])
        XCTAssertEqual(router.pendingDeliveryCount, 0)

        router.deliver(BackgroundTaskDelivery(rawTask: second, continuedProcessingTask: second))
        XCTAssertEqual(received.current, ["task.one", "task.two"])
        XCTAssertEqual(router.retainedTaskCount, 2)
        XCTAssertEqual(router.deliveredTaskCount, 2)

        router.release(first)
        XCTAssertEqual(router.retainedTaskCount, 1)
    }

    // MARK: - Live Activity generation / end race

    func testDelayedEndCannotClearActivityStartedAfterIt() async throws {
        let controller = await MainActor.run { LiveActivityController() }
        let endEntered = AsyncSignal()
        let endRelease = AsyncSignal()

        await MainActor.run {
            controller.startActivity(
                jobID: UUID(),
                sourceFileName: "old.dng",
                scaleFactor: .x2,
                targetWidth: 100,
                targetHeight: 80,
                totalTiles: 4
            )
            controller.endSuspensionHook = {
                endEntered.signal()
                await endRelease.wait()
            }
        }

        let oldGeneration = await MainActor.run { controller.activityGeneration }
        let endTask = Task { @MainActor in
            await controller.endActivity(finalMessage: "Old job done")
        }
        await endEntered.wait()

        // A new job starts while the old handle's end() is still suspended.
        await MainActor.run {
            controller.startActivity(
                jobID: UUID(),
                sourceFileName: "new.dng",
                scaleFactor: .x4,
                targetWidth: 200,
                targetHeight: 160,
                totalTiles: 8
            )
        }
        let newGeneration = await MainActor.run { controller.activityGeneration }
        XCTAssertGreaterThan(newGeneration, oldGeneration)
        var currentGeneration = await MainActor.run { controller.currentActivityGeneration }
        XCTAssertEqual(currentGeneration, newGeneration)

        endRelease.signal()
        await endTask.value

        // The delayed end must NOT clear the newer activity.
        currentGeneration = await MainActor.run { controller.currentActivityGeneration }
        XCTAssertEqual(currentGeneration, newGeneration)
        let state = await MainActor.run { controller.lastKnownState }
        XCTAssertEqual(state?.stageTitle, "Preparing tiles…")
        XCTAssertEqual(state?.phase, .running)
        let ended = await MainActor.run { controller.endedGeneration }
        XCTAssertEqual(ended, oldGeneration)
    }

    func testUpdatesOnlyReachTheCurrentActivityHandle() async throws {
        let controller = await MainActor.run { LiveActivityController() }
        await MainActor.run {
            controller.startActivity(
                jobID: UUID(),
                sourceFileName: "job.dng",
                scaleFactor: .x4,
                targetWidth: 10,
                targetHeight: 10,
                totalTiles: 4
            )
        }
        let generation = await MainActor.run { controller.activityGeneration }

        await controller.updateProgress(
            stageTitle: "Upscaling tile 1/4",
            completedTiles: 1,
            totalTiles: 4,
            progressFraction: 0.33,
            estimatedSecondsRemaining: 9,
            forceImmediate: true
        )
        var state = await MainActor.run { controller.lastKnownState }
        XCTAssertEqual(state?.completedTiles, 1)
        let generationAfterUpdate = await MainActor.run { controller.activityGeneration }
        XCTAssertEqual(generation, generationAfterUpdate)

        await MainActor.run { controller.endSuspensionHook = nil }
        await controller.endActivity(finalMessage: "Done")
        let endedGeneration = await MainActor.run { controller.currentActivityGeneration }
        XCTAssertNil(endedGeneration)

        // A late update after end() may update lastKnownState, but the ended activity generation is gone.
        await controller.updateProgress(
            stageTitle: "Late update",
            completedTiles: 2,
            totalTiles: 4,
            progressFraction: 0.5,
            estimatedSecondsRemaining: 5,
            forceImmediate: true
        )
        state = await MainActor.run { controller.lastKnownState }
        XCTAssertEqual(state?.completedTiles, 2)
        let generationAfterLateUpdate = await MainActor.run { controller.currentActivityGeneration }
        XCTAssertNil(generationAfterLateUpdate)
    }
}

// MARK: - Codex review probes: delivery/job/transition generations (R4)

/// Submission gate used to suspend `BGTaskScheduler.submitTaskRequest` deterministically.
private actor ReviewSubmissionGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// Legacy assertion provider whose `beginBackgroundTask` can be suspended after it has started.
/// This models UIKit/OS completing an acquisition after the owning job already ended.
final class GatedLegacyAssertionProvider: LegacyBackgroundAssertionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0
    private var expirationHandler: (@Sendable () -> Void)?
    let beginEntered = AsyncSignal()
    let beginRelease = AsyncSignal()

    var beginCount: Int {
        lock.lock(); defer { lock.unlock() }
        return begun
    }

    var endCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UUID? {
        recordBegin(expirationHandler)
        beginEntered.signal()
        await beginRelease.wait()
        return UUID()
    }

    func endBackgroundTask(token: UUID) async {
        recordEnd()
    }

    private func recordBegin(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        begun += 1
        self.expirationHandler = handler
        lock.unlock()
    }

    private func recordEnd() {
        lock.lock()
        ended += 1
        lock.unlock()
    }

    func fireExpiration() {
        lock.lock()
        let handler = expirationHandler
        lock.unlock()
        handler?()
    }
}

/// Legacy assertion provider whose `endBackgroundTask` can be suspended. Models a supersede that
/// is still awaiting assertion cleanup when a newer start request adopts.
final class GatedEndLegacyAssertionProvider: LegacyBackgroundAssertionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0
    let endEntered = AsyncSignal()
    let endRelease = AsyncSignal()

    var beginCount: Int {
        lock.lock(); defer { lock.unlock() }
        return begun
    }

    var endCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UUID? {
        _ = name
        _ = expirationHandler
        recordBegin()
        return UUID()
    }

    func endBackgroundTask(token: UUID) async {
        _ = token
        endEntered.signal()
        await endRelease.wait()
        recordEnd()
    }

    private func recordBegin() {
        lock.lock()
        begun += 1
        lock.unlock()
    }

    private func recordEnd() {
        lock.lock()
        ended += 1
        lock.unlock()
    }
}

extension BackgroundTaskIntegrationTests {
    func testCodexReviewObsoleteDeliveryCannotExpireCurrentDelivery() async throws {
        let h = try await makeHarness(), job = descriptor()
        await h.coordinator.startJob(job)
        let first = FakeContinuedProcessingTask(identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID))
        let second = FakeContinuedProcessingTask(identifier: first.identifier)
        h.router.deliver(BackgroundTaskDelivery(rawTask: first, continuedProcessingTask: first))
        let firstReady = await waitUntil { first.hasExpirationHandler }; XCTAssertTrue(firstReady)
        h.router.deliver(BackgroundTaskDelivery(rawTask: second, continuedProcessingTask: second))
        let secondReady = await waitUntil { second.hasExpirationHandler }; XCTAssertTrue(secondReady)
        XCTAssertEqual(first.completionCount, 1)
        first.fireExpiration()
        try await Task.sleep(for: .milliseconds(50))
        let expired = await h.coordinator.didExpire()
        XCTAssertFalse(expired, "An obsolete task's queued expiration must not pause the current task")
        XCTAssertEqual(second.completionCount, 0, "Current task must remain owned and running")
        await h.coordinator.cancelJob()
    }

    func testCodexReviewRejectsDeliveryForDifferentJob() async throws {
        let h = try await makeHarness(), current = descriptor()
        await h.coordinator.startJob(current)
        let old = FakeContinuedProcessingTask(identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: UUID()))
        h.router.deliver(BackgroundTaskDelivery(rawTask: old, continuedProcessingTask: old))
        let completed = await waitUntil { old.completionCount == 1 }; XCTAssertTrue(completed)
        XCTAssertFalse(old.hasExpirationHandler, "A refused delivery must not be adopted or get an expiration handler")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(old.completionCount, 1, "Delivery for another job must be refused/completed")
        let active = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertFalse(active, "A mismatched task may not own the current job")
        await h.coordinator.cancelJob()
    }

    func testCodexReviewJobFinishingDuringSubmitDoesNotAcquireLeakedAssertion() async throws {
        let h = try await makeHarness(), job = descriptor()
        await h.coordinator.startJob(job)
        let entered = LockedValue<Bool>(), gate = ReviewSubmissionGate()
        h.scheduler.submissionObserver = { entered.set(true); await gate.wait() }
        let transition = Task { await h.coordinator.handleWillResignActive() }
        let pending = await waitUntil { entered.current == true }; XCTAssertTrue(pending)
        await h.coordinator.completeJob(success: true, message: "done while submit awaits")
        await gate.release()
        await transition.value
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount, "Ended job must not acquire a new, unreleased assertion after submit returns")
        await h.coordinator.handleDidBecomeActive()
    }
}

extension BackgroundTaskIntegrationTests {
    /// Foregrounding (or another background cycle) can race the activity terminal hop without
    /// replacing its job. Every terminal kind still owns completion of the delivered task.
    func testReviewTerminalCleanupSurvivesSceneChangesDuringActivityHop() async throws {
        for returnsToBackground in [false, true] {
            for terminal in 0..<3 {
                let h = try await makeHarness(), job = descriptor()
                await h.coordinator.startJob(job)
                await h.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "2×")
                let task = FakeContinuedProcessingTask(
                    identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID))
                h.router.deliver(BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task))
                let adopted = await waitUntil { task.hasExpirationHandler }
                XCTAssertTrue(adopted)
                XCTAssertEqual(h.assertions.beginCount, 1)

                let entered = AsyncSignal(), release = AsyncSignal()
                await MainActor.run {
                    let hook: @Sendable () async -> Void = { entered.signal(); await release.wait() }
                    switch terminal {
                    case 0: h.activity.markCompletedHook = hook
                    case 1: h.activity.markCancelledHook = hook
                    default: h.activity.markFailedHook = hook
                    }
                }
                let completion = Task {
                    if terminal == 1 { await h.coordinator.cancelJob(message: "Stopped") }
                    else { await h.coordinator.completeJob(success: terminal == 0, message: "Finished") }
                }
                await entered.wait()
                await h.coordinator.handleDidBecomeActive()
                if returnsToBackground {
                    await h.coordinator.handleWillResignActive(jobTitle: "Finished", jobSubtitle: "2×")
                }
                release.signal(); await completion.value

                XCTAssertEqual(task.completionCount, 1, "A same-job scene change cannot orphan terminal delivery")
                XCTAssertEqual(task.lastCompletionSuccess, terminal == 0)
                XCTAssertEqual(h.router.retainedTaskCount, 0)
                let active = await h.coordinator.hasActiveDeliveredTask()
                XCTAssertFalse(active)
                XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
                // Duplicate terminal signals must remain idempotent after the raced cleanup.
                await h.coordinator.cancelJob()
                XCTAssertEqual(task.completionCount, 1)
            }
        }
    }

    /// A terminal activity update that suspends must not resume into a newer job: old cleanup cannot
    /// clear the new job, complete its delivery or cancel its submission.
    func testCodexReviewTerminalActivityUpdateCannotResumeIntoNewJob() async throws {
        let h = try await makeHarness()
        let first = descriptor()
        await h.coordinator.startJob(first)
        let firstTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: first.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: firstTask, continuedProcessingTask: firstTask))
        let firstReady = await waitUntil { firstTask.hasExpirationHandler }
        XCTAssertTrue(firstReady)
        await h.coordinator.updateProgress(
            progressUpdate(jobID: first.jobID, completedTiles: 6, totalTiles: 12)
        )

        let entered = AsyncSignal()
        let release = AsyncSignal()
        await MainActor.run {
            h.activity.markCompletedHook = {
                entered.signal()
                await release.wait()
            }
        }
        let completion = Task {
            await h.coordinator.completeJob(success: true, message: "first done")
        }
        await entered.wait()

        // Start a replacement job while the old terminal activity call is still suspended.
        let second = descriptor()
        await h.coordinator.startJob(second)
        XCTAssertEqual(firstTask.completionCount, 1, "Superseding the old job completes its delivery exactly once")

        release.signal()
        await completion.value

        // The old terminal path must not cancel/complete the newer job.
        let secondTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: second.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: secondTask, continuedProcessingTask: secondTask))
        let secondReady = await waitUntil { secondTask.hasExpirationHandler }
        XCTAssertTrue(secondReady)
        let active = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertTrue(active, "The newer job's delivered task must survive the old cleanup")
        await h.coordinator.updateProgress(
            progressUpdate(jobID: second.jobID, completedTiles: 2, totalTiles: 12)
        )
        XCTAssertEqual(secondTask.completedUnitCount, 2)
        XCTAssertEqual(secondTask.totalUnitCount, 12)
        let state = await h.activity.lastKnownState
        XCTAssertEqual(state?.phase, .running)
        XCTAssertEqual(state?.completedTiles, 2)

        await h.coordinator.cancelJob(message: "second cancelled")
        XCTAssertEqual(secondTask.completionCount, 1)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    /// An expiration whose paused-activity update is suspended must not complete or pause a job that
    /// replaced the expired one while that await was in flight.
    func testCodexReviewSuspendedExpirationCannotPauseReplacementJob() async throws {
        let h = try await makeHarness()
        let first = descriptor()
        await h.coordinator.startJob(first)
        let firstTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: first.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: firstTask, continuedProcessingTask: firstTask))
        _ = await waitUntil { firstTask.hasExpirationHandler }
        await h.coordinator.updateProgress(
            progressUpdate(jobID: first.jobID, completedTiles: 3, totalTiles: 12)
        )

        let entered = AsyncSignal()
        let release = AsyncSignal()
        await MainActor.run {
            h.activity.markPausedHook = {
                entered.signal()
                await release.wait()
            }
        }
        let expiration = Task {
            await h.coordinator.handleBackgroundExpiration(completedTiles: 3, totalTiles: 12)
        }
        await entered.wait()

        // A replacement job starts while the old expiration is still suspended in markPaused.
        let second = descriptor()
        await h.coordinator.startJob(second)
        release.signal()
        await expiration.value

        let expired = await h.coordinator.didExpire()
        XCTAssertFalse(expired, "The suspended old expiration must not leave the new job expired")
        let secondTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: second.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: secondTask, continuedProcessingTask: secondTask))
        let ready = await waitUntil { secondTask.hasExpirationHandler }
        XCTAssertTrue(ready)
        await h.coordinator.updateProgress(
            progressUpdate(jobID: second.jobID, completedTiles: 2, totalTiles: 12)
        )
        XCTAssertEqual(secondTask.completedUnitCount, 2)
        XCTAssertEqual(firstTask.completionCount, 1, "The replaced job's delivery completes exactly once")
        XCTAssertEqual(secondTask.completionCount, 0)
        await h.coordinator.cancelJob()
        XCTAssertEqual(secondTask.completionCount, 1)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    /// A legacy assertion whose acquisition completes after the job ended must be released
    /// immediately and remain balanced; it must not fire a stale expiration for the ended job.
    func testCodexReviewAssertionAcquiredAfterCompletionIsReleasedImmediately() async throws {
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let store = try JobCheckpointStore(workingDirectory: workingDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let activity = await MainActor.run { RecordingLiveActivityController() }
        let scheduler = RecordingBackgroundTaskScheduler()
        let assertions = GatedLegacyAssertionProvider()
        let router = BackgroundTaskDeliveryRouter()
        let coordinator = BackgroundExecutionCoordinator(
            executor: executor,
            liveActivityController: activity,
            scheduler: scheduler,
            legacyAssertionProvider: assertions,
            deliveryRouter: router
        )
        coordinator.installDeliveryHandler(on: router)

        let job = descriptor()
        await coordinator.startJob(job)
        let transition = Task {
            await coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        }
        await assertions.beginEntered.wait()
        XCTAssertEqual(assertions.beginCount, 1)

        // The job finishes while the assertion acquisition is still suspended.
        await coordinator.completeJob(success: true, message: "done during assertion acquisition")
        assertions.beginRelease.signal()
        await transition.value

        XCTAssertEqual(assertions.beginCount, 1)
        XCTAssertEqual(assertions.endCount, 1, "An assertion acquired after its job ended must be released immediately")
        let expired = await coordinator.didExpire()
        XCTAssertFalse(expired)
        let state = await activity.lastKnownState
        XCTAssertEqual(state?.phase, .completed)
        await coordinator.handleDidBecomeActive()
        XCTAssertEqual(assertions.beginCount, assertions.endCount)
    }

    /// Foreground return while a background submission is suspended must cancel the in-flight
    /// request, leave no assertion behind and leave the executor in foreground compute mode.
    func testCodexReviewForegroundDuringSubmissionCancelsObsoleteRequestAndLeaksNoAssertion() async throws {
        let h = try await makeHarness()
        let job = descriptor()
        let concrete = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        await h.coordinator.startJob(job)

        let entered = LockedValue<Bool>()
        let gate = ReviewSubmissionGate()
        h.scheduler.submissionObserver = { entered.set(true); await gate.wait() }
        let transition = Task { await h.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×") }
        let pending = await waitUntil { entered.current == true }
        XCTAssertTrue(pending)

        XCTAssertEqual(h.assertions.beginCount, 1, "Protect the app while foreground submission is pending")

        await h.coordinator.handleDidBecomeActive()
        await gate.release()
        await transition.value

        XCTAssertTrue(h.scheduler.cancelledIdentifiers.contains(concrete), "The obsolete in-flight request must be cancelled")
        XCTAssertEqual(h.assertions.beginCount, 1)
        XCTAssertEqual(h.assertions.endCount, 1, "Foreground return must release that exact assertion")
        let inBackground = await h.coordinator.isInBackground()
        XCTAssertFalse(inBackground)
        let units = await h.registry.currentUnits()
        XCTAssertEqual(units, .all)
    }

    /// An old iOS 27 async submission can return after the same job begins a newer background
    /// cycle. Its success/error cleanup must not cancel B's request merely because IDs are equal.
    func testReviewSecondBackgroundCycleSurvivesOldSubmissionCompletion() async throws {
        for lateFailure in [false, true] {
            let h = try await makeHarness(), job = descriptor()
            let identifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
            await h.coordinator.startJob(job)
            let entered = LockedValue<Bool>(), gate = ReviewSubmissionGate()
            h.scheduler.submissionObserver = { entered.set(true); await gate.wait() }
            let oldCycle = Task { await h.coordinator.handleWillResignActive(jobTitle: "A", jobSubtitle: "2×") }
            let pending = await waitUntil { entered.current == true }
            XCTAssertTrue(pending)
            await h.coordinator.handleDidBecomeActive()
            h.scheduler.submissionObserver = nil
            await h.coordinator.handleWillResignActive(jobTitle: "B", jobSubtitle: "2×")
            XCTAssertEqual(h.scheduler.submissions.count, 1)
            let cancelledBeforeOldReturn = h.scheduler.cancelledIdentifiers.count
            XCTAssertEqual(cancelledBeforeOldReturn, 1)
            if lateFailure { h.scheduler.submitError = ScalerError.backgroundTaskSchedulingFailed(reason: "old cycle failed late") }
            await gate.release(); await oldCycle.value
            XCTAssertEqual(h.scheduler.cancelledIdentifiers.count, cancelledBeforeOldReturn,
                "A's late return must not cancel B's pending request with the same identifier")
            await h.coordinator.handleDidBecomeActive()
            XCTAssertEqual(h.scheduler.cancelledIdentifiers.count, cancelledBeforeOldReturn + 1,
                "B's own foreground transition must still own and cancel its pending request")
            XCTAssertTrue(h.scheduler.cancelledIdentifiers.allSatisfy { $0 == identifier })
            XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
            await h.coordinator.cancelJob()
        }
    }

    /// Delivery may beat the async submission's return. Quick foreground/background cycling
    /// must retain the already granted continuation, including when the submit completes late.
    func testReviewLateSubmissionPreservesAlreadyDeliveredContinuation() async throws {
        let h = try await makeHarness(), job = descriptor()
        let identifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        await h.coordinator.startJob(job)
        let entered = LockedValue<Bool>(), gate = ReviewSubmissionGate()
        h.scheduler.submissionObserver = { entered.set(true); await gate.wait() }
        let oldCycle = Task { await h.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "2×") }
        let pending = await waitUntil { entered.current == true }
        XCTAssertTrue(pending)
        let delivered = FakeContinuedProcessingTask(identifier: identifier)
        h.router.deliver(BackgroundTaskDelivery(rawTask: delivered, continuedProcessingTask: delivered))
        let adopted = await waitUntil { delivered.hasExpirationHandler }
        XCTAssertTrue(adopted)
        await h.coordinator.handleDidBecomeActive()
        await h.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "2×")
        await gate.release(); await oldCycle.value
        XCTAssertTrue(h.scheduler.cancelledIdentifiers.isEmpty)
        XCTAssertEqual(delivered.completionCount, 0)
        let active = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertTrue(active)
        await h.coordinator.completeJob(success: true, message: "Done")
        XCTAssertEqual(delivered.completionCount, 1)
        XCTAssertEqual(h.router.retainedTaskCount, 0)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    /// Preserving a live replacement/grant must not preserve a request after its job was stopped
    /// or expired while async submission was pending. The late accepted request still needs cancel.
    func testReviewLateSubmissionIsCancelledAfterDeliveredJobEnds() async throws {
        for cancelled in [false, true] {
            let h = try await makeHarness(), job = descriptor()
            let identifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
            await h.coordinator.startJob(job)
            let entered = LockedValue<Bool>(), gate = ReviewSubmissionGate()
            h.scheduler.submissionObserver = { entered.set(true); await gate.wait() }
            let oldCycle = Task { await h.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "2×") }
            let pending = await waitUntil { entered.current == true }
            XCTAssertTrue(pending)
            let delivered = FakeContinuedProcessingTask(identifier: identifier)
            h.router.deliver(BackgroundTaskDelivery(rawTask: delivered, continuedProcessingTask: delivered))
            let adopted = await waitUntil { delivered.hasExpirationHandler }
            XCTAssertTrue(adopted)
            if cancelled { await h.coordinator.cancelJob() }
            else { await h.coordinator.handleSystemExpiration() }
            XCTAssertEqual(delivered.completionCount, 1)
            let cancellations = h.scheduler.cancelledIdentifiers.count
            await gate.release(); await oldCycle.value
            XCTAssertEqual(h.scheduler.cancelledIdentifiers.count, cancellations + 1,
                "A late accepted request for an ended job must not be left pending")
            XCTAssertEqual(delivered.completionCount, 1)
            XCTAssertEqual(h.router.retainedTaskCount, 0)
            XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
        }
    }

    /// A newer same-ID submission no longer owns cancellation immunity once that cycle expires.
    func testReviewLateOldSubmissionIsCancelledAfterReplacementCycleExpires() async throws {
        let h = try await makeHarness(), job = descriptor()
        await h.coordinator.startJob(job)
        let entered = LockedValue<Bool>(), gate = ReviewSubmissionGate()
        h.scheduler.submissionObserver = { entered.set(true); await gate.wait() }
        let oldCycle = Task { await h.coordinator.handleWillResignActive(jobTitle: "A", jobSubtitle: "2×") }
        let pending = await waitUntil { entered.current == true }
        XCTAssertTrue(pending)
        await h.coordinator.handleDidBecomeActive()
        h.scheduler.submissionObserver = nil
        await h.coordinator.handleWillResignActive(jobTitle: "B", jobSubtitle: "2×")
        await h.coordinator.handleSystemExpiration()
        let cancellations = h.scheduler.cancelledIdentifiers.count
        await gate.release(); await oldCycle.value
        XCTAssertEqual(h.scheduler.cancelledIdentifiers.count, cancellations + 1,
            "An expired replacement must not suppress cancellation of A's late accepted request")
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
        let active = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertFalse(active)
    }

    /// `.background` arriving while `.inactive` preparation is still suspended is the same
    /// transition: it must not invalidate/cancel the in-flight submission or drop the assertion.
    func testCodexReviewDuplicateSceneTransitionDoesNotInvalidateInFlightPreparation() async throws {
        let h = try await makeHarness()
        let job = descriptor()
        let concrete = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        await h.coordinator.startJob(job)

        let entered = LockedValue<Bool>()
        let gate = ReviewSubmissionGate()
        h.scheduler.submissionObserver = { entered.set(true); await gate.wait() }
        let inactive = Task {
            await h.coordinator.handleWillResignActive(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        }
        let pending = await waitUntil { entered.current == true }
        XCTAssertTrue(pending)

        // `.background` arrives before `.inactive`'s submission await returns.
        await h.coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large · 4×")
        await gate.release()
        await inactive.value

        XCTAssertEqual(h.scheduler.submissions.count, 1)
        XCTAssertEqual(h.scheduler.submissions.first?.identifier, concrete)
        XCTAssertTrue(h.scheduler.cancelledIdentifiers.isEmpty, "The same transition must not cancel its own request")
        XCTAssertEqual(h.assertions.beginCount, 1)
        await h.coordinator.handleDidBecomeActive()
        XCTAssertEqual(h.assertions.endCount, 1)
    }

    /// The expiration handler installed for a delivery that belonged to a replaced job must not pause
    /// or complete the current job's delivery, even long after the replacement.
    func testCodexReviewOldJobExpirationCannotPauseReplacementJob() async throws {
        let h = try await makeHarness()
        let first = descriptor()
        await h.coordinator.startJob(first)
        let firstTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: first.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: firstTask, continuedProcessingTask: firstTask))
        _ = await waitUntil { firstTask.hasExpirationHandler }

        let second = descriptor()
        await h.coordinator.startJob(second)
        let secondTask = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: second.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: secondTask, continuedProcessingTask: secondTask))
        _ = await waitUntil { secondTask.hasExpirationHandler }
        XCTAssertEqual(secondTask.completionCount, 0)

        firstTask.fireExpiration()
        try await Task.sleep(for: .milliseconds(50))

        let expired = await h.coordinator.didExpire()
        XCTAssertFalse(expired)
        XCTAssertEqual(secondTask.completionCount, 0)
        let active = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertTrue(active)
        await h.coordinator.updateProgress(
            progressUpdate(jobID: second.jobID, completedTiles: 4, totalTiles: 12)
        )
        XCTAssertEqual(secondTask.completedUnitCount, 4)
        await h.coordinator.cancelJob()
        XCTAssertEqual(secondTask.completionCount, 1)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }
}

// MARK: - C2 lifetime-safe task identity and exact-token cleanup

extension BackgroundTaskIntegrationTests {
    /// Port of the second-review address-reuse probe: 64 distinct short-lived adapters/jobs, with
    /// many allocator address recycles. Every distinct task must complete exactly once and the
    /// router's raw-task retention must drain for every cycle. The weak identity registry must not
    /// grow an immortal address history.
    func testCodexSecondReviewDistinctTasksRemainCompletableAfterAllocationReuse() async throws {
        let h = try await makeHarness()
        var seen = Set<ObjectIdentifier>()
        var reused = 0
        var suppressed = 0

        for cycle in 0..<64 {
            let job = descriptor()
            await h.coordinator.startJob(job)
            let task = FakeContinuedProcessingTask(
                identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
            )
            let identity = ObjectIdentifier(task)
            if !seen.insert(identity).inserted { reused += 1 }

            h.router.deliver(BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task))
            let adopted = await waitUntil { task.installCount == 1 && task.progressSyncCount == 1 }
            XCTAssertTrue(adopted, "cycle \(cycle): the delivered task must be adopted")
            await h.coordinator.completeJob(success: true, message: "cycle \(cycle) done")

            if task.completionCount != 1 { suppressed += 1 }
            XCTAssertEqual(
                task.completionCount,
                1,
                "cycle \(cycle): a distinct task (even at a recycled address) must complete exactly once"
            )
            XCTAssertEqual(task.lastCompletionSuccess, true, "cycle \(cycle): terminal state must be success")
            XCTAssertEqual(h.router.retainedTaskCount, 0, "cycle \(cycle): router retention must drain")
        }

        print("[SecondReview] allocator-address-reuses=\(reused) uncompleted-distinct-tasks=\(suppressed)")
        XCTAssertEqual(suppressed, 0, "A new task at a previous adapter address must still be completed exactly once")
        XCTAssertGreaterThan(reused, 0, "The probe must actually exercise allocator address reuse")

        let drained = await waitUntilAsync {
            await h.coordinator.completedTaskIdentityLifetimeCount() == 0
        }
        XCTAssertTrue(drained, "Completed-task identities must be released with the tasks, not retained forever")
    }

    /// Repeated delivery of the same live raw task (same wrapper) must complete the framework task
    /// exactly once: the second adoption supersedes the first record, not double-completes it.
    func testCodexSecondReviewRepeatedSameTaskDeliveryCompletesExactlyOnce() async throws {
        let h = try await makeHarness()
        let job = descriptor()
        await h.coordinator.startJob(job)
        let task = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        )
        let delivery = BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task)

        h.router.deliver(delivery)
        let firstAdopted = await waitUntil { task.installCount == 1 && task.progressSyncCount == 1 }
        XCTAssertTrue(firstAdopted)
        XCTAssertEqual(task.completionCount, 0)

        h.router.deliver(delivery)
        let secondAdopted = await waitUntil { task.installCount == 2 && task.progressSyncCount == 2 }
        XCTAssertTrue(secondAdopted)
        XCTAssertEqual(task.completionCount, 1, "Superseding the old record completes the same task exactly once")
        XCTAssertFalse(task.lastCompletionSuccess ?? true)
        let active = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertTrue(active, "The second delivery remains the active record")

        await h.coordinator.completeJob(success: true, message: "done")
        XCTAssertEqual(task.completionCount, 1, "A repeated delivery must not complete the framework task twice")
        XCTAssertEqual(h.router.retainedTaskCount, 0)

        // Re-delivery after completion re-retains the raw task. The already-completed identity path
        // must still drain that router retention even though it calls no framework completion.
        h.router.deliver(delivery)
        let retentionDrained = await waitUntil { h.router.retainedTaskCount == 0 }
        XCTAssertTrue(retentionDrained, "An already-completed identity must still release router retention")
        XCTAssertEqual(task.completionCount, 1)
    }

    /// Two adapter wrappers around one actual raw task are one framework identity: whichever wrapper
    /// reaches the framework first completes it, and the other must not complete it again.
    func testCodexSecondReviewWrappersAroundOneRawTaskCompleteExactlyOnce() async throws {
        let h = try await makeHarness()
        let job = descriptor()
        let identifier = BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        await h.coordinator.startJob(job)
        let rawTask = RawContinuedProcessingTaskToken()
        let firstAdapter = FakeContinuedProcessingTask(identifier: identifier)
        let secondAdapter = FakeContinuedProcessingTask(identifier: identifier)

        h.router.deliver(
            BackgroundTaskDelivery(rawTask: rawTask, continuedProcessingTask: firstAdapter)
        )
        let firstAdopted = await waitUntil { firstAdapter.installCount == 1 && firstAdapter.progressSyncCount == 1 }
        XCTAssertTrue(firstAdopted)

        h.router.deliver(
            BackgroundTaskDelivery(rawTask: rawTask, continuedProcessingTask: secondAdapter)
        )
        let secondAdopted = await waitUntil { secondAdapter.installCount == 1 && secondAdapter.progressSyncCount == 1 }
        XCTAssertTrue(secondAdopted)

        XCTAssertEqual(firstAdapter.completionCount, 1)
        XCTAssertFalse(firstAdapter.lastCompletionSuccess ?? true)
        XCTAssertEqual(secondAdapter.completionCount, 0)
        let active = await h.coordinator.hasActiveDeliveredTask()
        XCTAssertTrue(active)

        await h.coordinator.completeJob(success: true, message: "done")
        XCTAssertEqual(
            firstAdapter.completionCount + secondAdapter.completionCount,
            1,
            "Wrappers around one raw task must not cause duplicate framework completion"
        )
        XCTAssertEqual(secondAdapter.completionCount, 0)
        XCTAssertEqual(h.router.retainedTaskCount, 0)
    }

    /// Rejection, replacement and terminal paths all use the actual raw-task identity: a rejected
    /// task can be redelivered without a second completion, a replacement completes the older task
    /// once, and duplicate terminal calls stay no-ops.
    func testCodexSecondReviewRejectionReplacementTerminalRespectRawTaskIdentity() async throws {
        let h = try await makeHarness()
        let job = descriptor()
        await h.coordinator.startJob(job)

        // Rejection: a different job's task is completed once and its retention drains.
        let rejected = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: UUID())
        )
        let rejectedDelivery = BackgroundTaskDelivery(rawTask: rejected, continuedProcessingTask: rejected)
        h.router.deliver(rejectedDelivery)
        let rejectedCompleted = await waitUntil { rejected.completionCount == 1 }
        XCTAssertTrue(rejectedCompleted)
        XCTAssertEqual(rejected.lastCompletionSuccess, false)
        XCTAssertEqual(h.router.retainedTaskCount, 0)

        // Re-delivering the same rejected task must not complete it twice.
        h.router.deliver(rejectedDelivery)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rejected.completionCount, 1)
        XCTAssertEqual(h.router.retainedTaskCount, 0)

        // Replacement: a superseding delivery for the same job completes the older task once.
        let first = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: job.jobID)
        )
        let second = FakeContinuedProcessingTask(identifier: first.identifier)
        h.router.deliver(BackgroundTaskDelivery(rawTask: first, continuedProcessingTask: first))
        let firstAdopted = await waitUntil { first.installCount == 1 && first.progressSyncCount == 1 }
        XCTAssertTrue(firstAdopted)
        h.router.deliver(BackgroundTaskDelivery(rawTask: second, continuedProcessingTask: second))
        let secondAdopted = await waitUntil { second.installCount == 1 && second.progressSyncCount == 1 }
        XCTAssertTrue(secondAdopted)
        XCTAssertEqual(first.completionCount, 1)
        XCTAssertEqual(first.lastCompletionSuccess, false)
        XCTAssertEqual(second.completionCount, 0)

        // Terminal: success completes the current replacement exactly once, including duplicates.
        await h.coordinator.completeJob(success: true, message: "done")
        XCTAssertEqual(second.completionCount, 1)
        XCTAssertEqual(second.lastCompletionSuccess, true)
        await h.coordinator.completeJob(success: true, message: "duplicate")
        XCTAssertEqual(second.completionCount, 1)
        XCTAssertEqual(h.router.retainedTaskCount, 0)
    }
}

// MARK: - C2 stale no-job cleanup ownership

extension BackgroundTaskIntegrationTests {
    /// Port of the second-review gated stale no-job probe: `markFailed` is suspended, a newer job
    /// starts and acquires its legacy assertion, then the stale delivery resumes. It must not end
    /// the newer job's assertion and must not publish failure into the newer activity.
    func testCodexSecondReviewNoJobDeliveryCannotReleaseANewerJobsAssertion() async throws {
        let h = try await makeHarness()
        let entered = AsyncSignal()
        let release = AsyncSignal()
        await MainActor.run {
            h.activity.markFailedHook = {
                entered.signal()
                await release.wait()
            }
        }

        let stale = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: UUID())
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: stale, continuedProcessingTask: stale))
        await entered.wait()

        // A newer job starts and prepares its own background cycle while the stale failure is
        // still suspended inside `markFailed`.
        let newer = descriptor()
        await h.coordinator.startJob(newer)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 1)
        XCTAssertEqual(h.assertions.endCount, 0)

        release.signal()
        let staleCompleted = await waitUntil { stale.completionCount == 1 }
        XCTAssertTrue(staleCompleted, "The stale delivery itself must still be completed exactly once")
        XCTAssertEqual(stale.lastCompletionSuccess, false)
        XCTAssertEqual(h.assertions.endCount, 0, "Stale no-job delivery released the newer job's assertion")
        XCTAssertEqual(h.router.retainedTaskCount, 0)

        let state = await h.activity.lastKnownState
        XCTAssertEqual(state?.phase, .running, "A stale failure must not be published into the newer activity")
        XCTAssertEqual(state?.stageTitle, "Preparing tiles…")

        await h.coordinator.cancelJob()
        XCTAssertEqual(h.assertions.endCount, 1, "The newer job still owns and balances its own assertion")
    }

    /// Captured nil means "no resource": after a prior lifecycle released its assertion, a stale
    /// no-job cleanup must not end the distinct assertion a newer job acquired while it awaited.
    func testCodexSecondReviewStaleCleanupCapturedNilCannotReleaseANewResource() async throws {
        let h = try await makeHarness()

        // Prior lifecycle acquires and releases its own assertion.
        let prior = descriptor()
        await h.coordinator.startJob(prior)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 1)
        await h.coordinator.completeJob(success: true, message: "prior done")
        XCTAssertEqual(h.assertions.endCount, 1)

        let entered = AsyncSignal()
        let release = AsyncSignal()
        await MainActor.run {
            h.activity.markFailedHook = {
                entered.signal()
                await release.wait()
            }
        }
        let stale = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: UUID())
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: stale, continuedProcessingTask: stale))
        await entered.wait()

        // The newer job acquires a *new* resource while the stale operation has captured nil.
        let newer = descriptor()
        await h.coordinator.startJob(newer)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 2)
        XCTAssertEqual(h.assertions.endCount, 1)

        release.signal()
        let staleCompleted = await waitUntil { stale.completionCount == 1 }
        XCTAssertTrue(staleCompleted)
        XCTAssertEqual(
            h.assertions.endCount,
            1,
            "Captured nil must not release the newer job's newly acquired assertion"
        )
        XCTAssertEqual(h.router.retainedTaskCount, 0)

        await h.coordinator.cancelJob()
        XCTAssertEqual(h.assertions.endCount, 2)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }
}

extension BackgroundTaskIntegrationTests {
    /// A no-job failure whose MainActor hop is delayed until after a newer job started must be
    /// suppressed by the activity identity gate instead of publishing `.failed` over the newer
    /// running activity.
    func testCodexSecondReviewDelayedNoJobFailureCannotPublishIntoNewerActivity() async throws {
        let h = try await makeHarness()
        let entered = AsyncSignal()
        let release = AsyncSignal()
        await MainActor.run {
            h.activity.markFailedGateHook = {
                entered.signal()
                await release.wait()
            }
        }

        let stale = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: UUID())
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: stale, continuedProcessingTask: stale))
        await entered.wait()

        // The newer job starts before the stale failure call reaches its identity gate.
        let newer = descriptor()
        await h.coordinator.startJob(newer)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 1)
        XCTAssertEqual(h.assertions.endCount, 0)

        release.signal()
        let staleCompleted = await waitUntil { stale.completionCount == 1 }
        XCTAssertTrue(staleCompleted)
        XCTAssertEqual(stale.lastCompletionSuccess, false)
        XCTAssertEqual(h.assertions.endCount, 0, "The gate must also protect the newer assertion")

        let state = await h.activity.lastKnownState
        XCTAssertEqual(state?.phase, .running, "A delayed stale failure must not publish into the newer activity")
        XCTAssertEqual(state?.stageTitle, "Preparing tiles…")

        await h.coordinator.cancelJob()
        XCTAssertEqual(h.assertions.endCount, 1)
    }
}

extension BackgroundTaskIntegrationTests {
    /// A start request that suspends in the pre-adoption supersede assertion cleanup must not adopt
    /// after a newer start request took over. Otherwise the delayed older request would overwrite
    /// the newer job/activity and its delivered task.
    func testCodexSecondReviewSupersedeAwaitCannotOverwriteNewerStart() async throws {
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let store = try JobCheckpointStore(workingDirectory: workingDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let activity = await MainActor.run { RecordingLiveActivityController() }
        let scheduler = RecordingBackgroundTaskScheduler()
        let assertions = GatedEndLegacyAssertionProvider()
        let router = BackgroundTaskDeliveryRouter()
        let coordinator = BackgroundExecutionCoordinator(
            executor: executor,
            liveActivityController: activity,
            scheduler: scheduler,
            legacyAssertionProvider: assertions,
            deliveryRouter: router
        )
        coordinator.installDeliveryHandler(on: router)

        // Job A owns an assertion.
        let jobA = descriptor()
        await coordinator.startJob(jobA)
        await coordinator.handleWillResignActive()
        XCTAssertEqual(assertions.beginCount, 1)

        // Job B supersedes A, then suspends in A's assertion release.
        let jobB = descriptor()
        let supersedingStart = Task { await coordinator.startJob(jobB) }
        await assertions.endEntered.wait()

        // Job C adopts while B is still suspended in the pre-adoption cleanup.
        let jobC = descriptor()
        await coordinator.startJob(jobC)

        assertions.endRelease.signal()
        _ = await supersedingStart.value

        // C must still own the coordinator: its delivered task is adopted and completed normally.
        let taskC = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: jobC.jobID)
        )
        router.deliver(BackgroundTaskDelivery(rawTask: taskC, continuedProcessingTask: taskC))
        let cAdopted = await waitUntil { taskC.installCount == 1 && taskC.progressSyncCount == 1 }
        XCTAssertTrue(cAdopted, "The newer start's job must remain current after the stale supersede resumes")
        await coordinator.completeJob(success: true, message: "C done")
        XCTAssertEqual(taskC.completionCount, 1)
        XCTAssertEqual(taskC.lastCompletionSuccess, true)

        // B was never adopted: its identifier is now a no-job delivery and is refused, not completed
        // as the active job.
        let taskB = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: jobB.jobID)
        )
        router.deliver(BackgroundTaskDelivery(rawTask: taskB, continuedProcessingTask: taskB))
        let bRefused = await waitUntil { taskB.completionCount == 1 }
        XCTAssertTrue(bRefused)
        XCTAssertEqual(taskB.lastCompletionSuccess, false)
        XCTAssertEqual(router.retainedTaskCount, 0)
        XCTAssertEqual(assertions.beginCount, assertions.endCount)
    }
}

extension BackgroundTaskIntegrationTests {
    /// The additive identity-aware controller API rejects a delayed start that is older than an
    /// accepted one and suppresses terminal/pause mutations captured for a superseded identity.
    func testLiveActivityIdentityGateRejectsStaleAndOutOfOrderMutations() async throws {
        let controller = await MainActor.run { LiveActivityController() }

        let started = await controller.startActivity(
            jobID: UUID(),
            sourceFileName: "current.dng",
            scaleFactor: .x4,
            targetWidth: 100,
            targetHeight: 80,
            totalTiles: 8,
            ifNewerThanRequestIdentity: 7
        )
        XCTAssertTrue(started)

        let staleStart = await controller.startActivity(
            jobID: UUID(),
            sourceFileName: "stale.dng",
            scaleFactor: .x2,
            targetWidth: 50,
            targetHeight: 40,
            totalTiles: 4,
            ifNewerThanRequestIdentity: 6
        )
        XCTAssertFalse(staleStart, "An out-of-order start request must not replace a newer activity")
        var identity = await MainActor.run { controller.activityLifecycleIdentity }
        XCTAssertEqual(identity, 7)

        let staleFailure = await controller.markFailed(
            completedTiles: 0,
            totalTiles: 0,
            message: "stale failure",
            ifActivityIdentity: 6
        )
        XCTAssertFalse(staleFailure)
        let stalePause = await controller.markPaused(
            completedTiles: 1,
            totalTiles: 8,
            ifActivityIdentity: 6
        )
        XCTAssertFalse(stalePause)
        let staleUpdate = await controller.updateProgress(
            stageTitle: "stale update",
            completedTiles: 1,
            totalTiles: 8,
            progressFraction: 0.125,
            estimatedSecondsRemaining: 5,
            forceImmediate: true,
            ifActivityIdentity: 6
        )
        XCTAssertFalse(staleUpdate)

        var state = await MainActor.run { controller.lastKnownState }
        XCTAssertEqual(state?.phase, .running)
        XCTAssertEqual(state?.stageTitle, "Preparing tiles…")

        let currentFailure = await controller.markFailed(
            completedTiles: 0,
            totalTiles: 0,
            message: "current failure",
            ifActivityIdentity: 7
        )
        XCTAssertTrue(currentFailure)
        state = await MainActor.run { controller.lastKnownState }
        XCTAssertEqual(state?.phase, .failed)
        identity = await MainActor.run { controller.activityLifecycleIdentity }
        XCTAssertNil(identity, "A terminal mutation must clear the activity identity")
    }
}

// MARK: - D2 job-scoped expiration ownership (repair cycle 73ba5)
//
// The reviewer's identity-hop probe is ported verbatim below (`ThirdReviewIdentityReadGate` /
// `ThirdReviewIdentityReadActivity`). The gate blocks the `activityLifecycleIdentity` MainActor hop
// with a semaphore so a replacement job can adopt while an expiry is between its identity capture
// and its pause side effect.

/// One-shot blocking gate for the synchronous `activityLifecycleIdentity` getter.
private final class ThirdReviewIdentityReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let entered = AsyncSignal()
    let release = DispatchSemaphore(value: 0)
    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func blockIfArmed() {
        lock.lock()
        let mustBlock = armed
        armed = false
        lock.unlock()
        if mustBlock {
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }
}

/// Real controller wrapped so the identity read can be suspended deterministically. The reviewer
/// probe used exactly this adapter (non-identity mutations fall back to the protocol defaults).
@MainActor
private final class ThirdReviewIdentityReadActivity: LiveActivityControlling {
    private let actual = LiveActivityController()
    private let gate: ThirdReviewIdentityReadGate

    init(gate: ThirdReviewIdentityReadGate) {
        self.gate = gate
    }

    var lastKnownState: UpscaleActivityAttributes.ContentState? { actual.lastKnownState }

    var activityLifecycleIdentity: UInt64? {
        let captured = actual.activityLifecycleIdentity
        gate.blockIfArmed()
        return captured
    }

    func startActivity(
        jobID: UUID,
        sourceFileName: String,
        scaleFactor: ScaleFactor,
        targetWidth: Int,
        targetHeight: Int,
        totalTiles: Int
    ) {
        actual.startActivity(
            jobID: jobID,
            sourceFileName: sourceFileName,
            scaleFactor: scaleFactor,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            totalTiles: totalTiles
        )
    }

    func updateProgress(
        stageTitle: String,
        completedTiles: Int,
        totalTiles: Int,
        progressFraction: Double,
        estimatedSecondsRemaining: Int?,
        forceImmediate: Bool
    ) async {
        await actual.updateProgress(
            stageTitle: stageTitle,
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            progressFraction: progressFraction,
            estimatedSecondsRemaining: estimatedSecondsRemaining,
            forceImmediate: forceImmediate
        )
    }

    func markPaused(completedTiles: Int, totalTiles: Int) async {
        await actual.markPaused(completedTiles: completedTiles, totalTiles: totalTiles)
    }

    func markCompleted(completedTiles: Int, totalTiles: Int, finalMessage: String) async {
        await actual.markCompleted(completedTiles: completedTiles, totalTiles: totalTiles, finalMessage: finalMessage)
    }

    func markCancelled(completedTiles: Int, totalTiles: Int, message: String) async {
        await actual.markCancelled(completedTiles: completedTiles, totalTiles: totalTiles, message: message)
    }

    func markFailed(completedTiles: Int, totalTiles: Int, message: String) async {
        await actual.markFailed(completedTiles: completedTiles, totalTiles: totalTiles, message: message)
    }

    func endActivity(finalMessage: String, dismissPolicySeconds: TimeInterval) async {
        await actual.endActivity(finalMessage: finalMessage, dismissPolicySeconds: dismissPolicySeconds)
    }
}

private struct DeterministicScopedHarness {
    let coordinator: BackgroundExecutionCoordinator
    let executor: TiledPipelineExecutor
    let scheduler: RecordingBackgroundTaskScheduler
    let assertions: RecordingLegacyAssertionProvider
    let router: BackgroundTaskDeliveryRouter
}

/// Thread-safe ordered progress log for a real executor run.
private final class PipelineProgressLog: @unchecked Sendable {
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

private enum ScopedPauseTestError: Error {
    case pngSynthesisFailed
}

extension BackgroundTaskIntegrationTests {
    // MARK: D2 harness / fixtures

    private func dngFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TiledInferenceEngineTests/Fixtures/saturatedComponentPeak.dng")
    }

    /// Real executor with the deterministic CPU/fallback policy required by the contract.
    private func deterministicDNGConfig(jobID: UUID = UUID()) -> UpscaleJobConfig {
        UpscaleJobConfig(
            id: jobID,
            sourceImageURL: dngFixtureURL(),
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0,
            exportFormat: .linearDNG16Bit
        )
    }

    private func makeDeterministicScopedHarness(
        activity: any LiveActivityControlling
    ) throws -> DeterministicScopedHarness {
        let store = try JobCheckpointStore(workingDirectory: workingDirectory)
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            availabilityPolicy: .allowDeterministicFallback
        )
        let executor = TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let scheduler = RecordingBackgroundTaskScheduler()
        let assertions = RecordingLegacyAssertionProvider()
        let router = BackgroundTaskDeliveryRouter()
        let coordinator = BackgroundExecutionCoordinator(
            executor: executor,
            liveActivityController: activity,
            scheduler: scheduler,
            legacyAssertionProvider: assertions,
            deliveryRouter: router
        )
        coordinator.installDeliveryHandler(on: router)
        return DeterministicScopedHarness(
            coordinator: coordinator,
            executor: executor,
            scheduler: scheduler,
            assertions: assertions,
            router: router
        )
    }

    private func makeDeterministicRecordingHarness() async throws -> (DeterministicScopedHarness, RecordingLiveActivityController) {
        let activity = await MainActor.run { RecordingLiveActivityController() }
        let harness = try makeDeterministicScopedHarness(activity: activity)
        return (harness, activity)
    }

    /// Executes on the real deterministic executor and fails only if a stale expiration paused it.
    private func assertExecutesWithoutBackgroundPause(
        _ executor: TiledPipelineExecutor,
        config: UpscaleJobConfig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await executor.executeOrResumeJob(
                config: config,
                overrideTier: .tierB_ConstrainedMemory
            )
        } catch let error as ScalerError {
            if case .jobPausedForBackgroundExpiration(let completedTileIndex) = error {
                XCTFail(
                    "A stale expiration must not pause the replacement executor run "
                        + "(jobPausedForBackgroundExpiration(completedTileIndex: \(completedTileIndex)))",
                    file: file,
                    line: line
                )
            } else {
                XCTFail("Replacement execution failed unexpectedly: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Replacement execution failed unexpectedly: \(error)", file: file, line: line)
        }
    }

    /// 16-bit RGBA PNG large enough for a multi-tile tier-B plan (800x600 -> 20 tiles at x2).
    private func makeGradientPNG(width: Int, height: Int) throws -> URL {
        var rgba16 = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                rgba16[offset] = UInt16((x * 65_535) / max(1, width - 1))
                rgba16[offset + 1] = UInt16((y * 65_535) / max(1, height - 1))
                rgba16[offset + 2] = UInt16((((x + y) % 251) * 65_535) / 250)
                rgba16[offset + 3] = 65_535
            }
        }
        let pixelData = rgba16.withUnsafeBytes { Data($0) }
        let url = workingDirectory.appendingPathComponent(
            "scoped_pause_\(width)x\(height)_\(UUID().uuidString).png"
        )
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
                      rawValue: CGImageAlphaInfo.last.rawValue
                          | CGBitmapInfo.byteOrder16Little.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw ScopedPauseTestError.pngSynthesisFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScopedPauseTestError.pngSynthesisFailed
        }
        return url
    }

    private func journalFileNames(jobID: UUID) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path)
            .filter { $0.hasPrefix("journal_\(jobID.uuidString)_") }
    }

    // MARK: Exact reviewer identity-hop probe

    func testCodexThirdReviewExpirationIdentityHopCannotPauseNewExecutorJob() async throws {
        let gate = ThirdReviewIdentityReadGate()
        let activity = await MainActor.run { ThirdReviewIdentityReadActivity(gate: gate) }
        let store = try JobCheckpointStore(workingDirectory: workingDirectory)
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            availabilityPolicy: .allowDeterministicFallback
        )
        let executor = TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let coordinator = BackgroundExecutionCoordinator(
            executor: executor,
            liveActivityController: activity,
            scheduler: RecordingBackgroundTaskScheduler(),
            legacyAssertionProvider: RecordingLegacyAssertionProvider()
        )
        await coordinator.startJob(descriptor())
        await executor.clearPauseRequest()
        gate.arm()
        let expiration = Task { await coordinator.handleSystemExpiration() }
        await gate.entered.wait()
        let config = UpscaleJobConfig(
            sourceImageURL: dngFixtureURL(),
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0,
            exportFormat: .linearDNG16Bit
        )
        let replacement = descriptor(jobID: config.id)
        let start = Task { await coordinator.startJob(replacement) }
        // didExpire is reset synchronously when B adopts, before its MainActor activity hop.
        for _ in 0..<10_000 {
            if !(await coordinator.didExpire()) { break }
            await Task.yield()
        }
        let stillExpired = await coordinator.didExpire()
        XCTAssertFalse(stillExpired, "Replacement must adopt while A's identity read is blocked")
        let task = FakeContinuedProcessingTask(identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: config.id))
        let delivery = Task {
            await coordinator.handleDeliveredTask(
                BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task)
            )
        }
        for _ in 0..<10_000 {
            if task.hasExpirationHandler { break }
            await Task.yield()
        }
        XCTAssertTrue(task.hasExpirationHandler, "B's delivery must be adopted before old identity read returns")
        gate.release.signal()
        _ = await start.value
        await delivery.value
        await expiration.value
        await executor.switchExecutionTier(.cpuOnly)
        do {
            _ = try await executor.executeOrResumeJob(
                config: config,
                overrideTier: .tierB_ConstrainedMemory
            )
        } catch {
            XCTFail("Stale A expiration must not send a pause request to B's executor after the identity-read await: \(error)")
        }
        await coordinator.cancelJob()
    }

    // MARK: Old scoped pause vs replacement run

    func testCodexThirdReviewQueuedOldScopedPauseCannotTargetReplacementExecution() async throws {
        let (h, _) = try await makeDeterministicRecordingHarness()
        let configA = deterministicDNGConfig()
        let jobA = descriptor(jobID: configA.id)
        await h.coordinator.startJob(jobA)

        // The captured old run may legitimately pause its own (idle) execution.
        let ownerA = ExecutionPauseOwner(jobID: configA.id, generation: 1)
        let acceptedByOldRun = await h.executor.requestGracefulPauseAndWait(ifOwner: ownerA)
        XCTAssertTrue(acceptedByOldRun, "The current registered owner must be able to pause its own run")

        // Replacement registers a newer run, which must discard the queued old pause.
        let configB = deterministicDNGConfig()
        await h.coordinator.startJob(descriptor(jobID: configB.id))
        let staleAccepted = await h.executor.requestGracefulPauseAndWait(ifOwner: ownerA)
        XCTAssertFalse(staleAccepted, "A stale queued pause must not be accepted after the replacement registered")

        await h.executor.switchExecutionTier(.cpuOnly)
        await assertExecutesWithoutBackgroundPause(h.executor, config: configB)

        let expired = await h.coordinator.didExpire()
        XCTAssertFalse(expired, "The replacement job never expired")
        await h.coordinator.cancelJob()
        XCTAssertEqual(h.router.retainedTaskCount, 0)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    // MARK: Replacement during delivery-expiration await

    func testCodexThirdReviewDeliveryExpirationReplacementCannotPauseNewExecutor() async throws {
        let gate = ThirdReviewIdentityReadGate()
        let activity = await MainActor.run { ThirdReviewIdentityReadActivity(gate: gate) }
        let h = try makeDeterministicScopedHarness(activity: activity)

        let jobA = descriptor()
        await h.coordinator.startJob(jobA)
        let taskA = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: jobA.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: taskA, continuedProcessingTask: taskA))
        let aAdopted = await waitUntil { taskA.hasExpirationHandler }
        XCTAssertTrue(aAdopted)

        gate.arm()
        taskA.fireExpiration()
        await gate.entered.wait()

        // B adopts while A's delivery expiration is suspended after capturing its identity.
        let configB = deterministicDNGConfig()
        let replacement = descriptor(jobID: configB.id)
        let coordinator = h.coordinator
        let startB = Task { await coordinator.startJob(replacement) }
        // `startJob` sets job/isJobRunning/didExpire synchronously before its MainActor activity hop,
        // which is blocked behind A's gated identity read. Wait for that synchronous adoption before
        // delivering B; otherwise the delivery can race the start and be refused as a different job.
        let bJobVisible = await waitUntilAsync { await coordinator.didExpire() == false }
        XCTAssertTrue(bJobVisible, "Replacement job must become visible before its delivery")
        let taskB = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: configB.id)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: taskB, continuedProcessingTask: taskB))
        let bAdopted = await waitUntil { taskB.hasExpirationHandler }
        XCTAssertTrue(bAdopted, "Replacement delivery must be adopted before the old expiration resumes")
        let expiredMeanwhile = await h.coordinator.didExpire()
        XCTAssertFalse(expiredMeanwhile)

        gate.release.signal()
        _ = await startB.value
        try await Task.sleep(for: .milliseconds(50))

        let expiredAfter = await h.coordinator.didExpire()
        XCTAssertFalse(expiredAfter, "The stale delivery expiration must not expire the replacement job")
        XCTAssertEqual(taskA.completionCount, 1, "Old delivery drains exactly once")
        XCTAssertFalse(taskA.lastCompletionSuccess ?? true)
        XCTAssertEqual(taskB.completionCount, 0, "Replacement delivery remains owned")

        await h.executor.switchExecutionTier(.cpuOnly)
        await assertExecutesWithoutBackgroundPause(h.executor, config: configB)

        await h.coordinator.cancelJob()
        XCTAssertEqual(taskB.completionCount, 1)
        XCTAssertEqual(h.router.retainedTaskCount, 0)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    // MARK: Replacement during legacy-assertion expiration await

    func testCodexThirdReviewLegacyAssertionExpirationReplacementCannotPauseNewExecutor() async throws {
        let gate = ThirdReviewIdentityReadGate()
        let activity = await MainActor.run { ThirdReviewIdentityReadActivity(gate: gate) }
        let h = try makeDeterministicScopedHarness(activity: activity)

        let jobA = descriptor()
        await h.coordinator.startJob(jobA)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 1)
        XCTAssertEqual(h.assertions.endCount, 0)

        gate.arm()
        h.assertions.fireExpiration()
        await gate.entered.wait()

        // B adopts while A's legacy-assertion expiration is suspended after capturing its identity.
        let configB = deterministicDNGConfig()
        let replacement = descriptor(jobID: configB.id)
        let coordinator = h.coordinator
        let startB = Task { await coordinator.startJob(replacement) }
        // `startJob` sets job/isJobRunning/didExpire synchronously before its MainActor activity hop,
        // which is blocked behind A's gated identity read. Wait for that synchronous adoption before
        // delivering B; otherwise the delivery can race the start and be refused as a different job.
        let bJobVisible = await waitUntilAsync { await coordinator.didExpire() == false }
        XCTAssertTrue(bJobVisible, "Replacement job must become visible before its delivery")
        let taskB = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: configB.id)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: taskB, continuedProcessingTask: taskB))
        let bAdopted = await waitUntil { taskB.hasExpirationHandler }
        XCTAssertTrue(bAdopted, "Replacement delivery must be adopted before the old expiration resumes")
        XCTAssertEqual(h.assertions.endCount, 1, "The superseded lifecycle's assertion is released exactly once")

        gate.release.signal()
        _ = await startB.value
        try await Task.sleep(for: .milliseconds(50))

        let expiredAfter = await h.coordinator.didExpire()
        XCTAssertFalse(expiredAfter, "The stale assertion expiration must not expire the replacement job")
        XCTAssertEqual(h.assertions.endCount, 1, "Captured old token must not release a newer resource")

        await h.executor.switchExecutionTier(.cpuOnly)
        await assertExecutesWithoutBackgroundPause(h.executor, config: configB)

        await h.coordinator.cancelJob()
        XCTAssertEqual(taskB.completionCount, 1)
        XCTAssertEqual(h.router.retainedTaskCount, 0)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    // MARK: Stale old delivery/assertion callbacks after a replacement

    func testCodexThirdReviewStaleDeliveryAndAssertionCallbacksCannotPauseReplacement() async throws {
        let (h, _) = try await makeDeterministicRecordingHarness()
        let jobA = descriptor()
        await h.coordinator.startJob(jobA)
        await h.coordinator.handleWillResignActive()
        XCTAssertEqual(h.assertions.beginCount, 1)
        let taskA = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: jobA.jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: taskA, continuedProcessingTask: taskA))
        let aAdopted = await waitUntil { taskA.hasExpirationHandler }
        XCTAssertTrue(aAdopted)

        // B replaces A before the old callbacks fire; A's delivery and assertion drain via supersede.
        let configB = deterministicDNGConfig()
        await h.coordinator.startJob(descriptor(jobID: configB.id))
        XCTAssertEqual(taskA.completionCount, 1)
        XCTAssertEqual(h.assertions.endCount, 1)
        let taskB = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: configB.id)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: taskB, continuedProcessingTask: taskB))
        let bAdopted = await waitUntil { taskB.hasExpirationHandler }
        XCTAssertTrue(bAdopted)

        // Both installed expiration handlers from A are stale now; neither may pause/complete B.
        taskA.fireExpiration()
        h.assertions.fireExpiration()
        try await Task.sleep(for: .milliseconds(50))

        let expired = await h.coordinator.didExpire()
        XCTAssertFalse(expired, "Stale callbacks must not expire the replacement job")
        XCTAssertEqual(taskA.completionCount, 1, "The old delivery remains completed exactly once")
        XCTAssertEqual(taskB.completionCount, 0, "The replacement delivery remains owned")
        XCTAssertEqual(h.assertions.endCount, 1, "Stale cleanup cannot release a replacement resource")

        await h.executor.switchExecutionTier(.cpuOnly)
        await assertExecutesWithoutBackgroundPause(h.executor, config: configB)

        await h.coordinator.cancelJob()
        XCTAssertEqual(taskB.completionCount, 1)
        XCTAssertEqual(h.router.retainedTaskCount, 0)
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }

    // MARK: Genuine expiration at an active tile

    func testCodexThirdReviewGenuineExpirationPausesAtActiveTileAndBalancesResources() async throws {
        let (h, activity) = try await makeDeterministicRecordingHarness()
        let jobID = UUID()
        let pngURL = try makeGradientPNG(width: 800, height: 600)
        let config = UpscaleJobConfig(
            id: jobID,
            sourceImageURL: pngURL,
            scaleFactor: .x2,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0,
            exportFormat: .png16Bit
        )
        let job = descriptor(jobID: jobID, totalTiles: 20)
        await h.coordinator.startJob(job)
        await h.coordinator.handleWillResignActive(jobTitle: "Upscaling PNG", jobSubtitle: "QuickSRNet-Large · 2×")
        XCTAssertEqual(h.assertions.beginCount, 1)

        let task = FakeContinuedProcessingTask(
            identifier: BackgroundExecutionCoordinator.submittedTaskIdentifier(for: jobID)
        )
        h.router.deliver(BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: task))
        let adopted = await waitUntil { task.hasExpirationHandler }
        XCTAssertTrue(adopted)

        let progress = PipelineProgressLog()
        let sawFirstTile = LockedValue<Bool>(false)
        let run = Task {
            try await h.executor.executeOrResumeJob(
                config: config,
                overrideTier: .tierB_ConstrainedMemory,
                progressHandler: { update in
                    progress.record(update)
                    if update.stage == .denoisingAndUpscalingTiles, update.completedTiles >= 1 {
                        sawFirstTile.set(true)
                    }
                }
            )
        }
        let observedFirstTile = await waitUntil(timeout: 30) { sawFirstTile.current == true }
        XCTAssertTrue(observedFirstTile, "The real executor must commit at least one tile before expiry")

        // A genuine expiration must wait for the real tile loop's flushed/checkpointed boundary.
        await h.coordinator.handleSystemExpiration()

        let pausedMessage: ScalerError?
        do {
            _ = try await run.value
            pausedMessage = nil
        } catch let error as ScalerError {
            pausedMessage = error
        } catch {
            pausedMessage = nil
        }
        guard let error = pausedMessage,
              case .jobPausedForBackgroundExpiration(let pausedIndex) = error else {
            XCTFail("A genuine expiration must pause the running executor at a stable boundary")
            return
        }
        XCTAssertGreaterThanOrEqual(pausedIndex, 0, "The pause must happen at/after a committed tile")

        let pausedUpdates = progress.updates.filter { $0.stage == .pausedOnDisk }
        let pausedUpdate = try XCTUnwrap(pausedUpdates.last)
        XCTAssertEqual(pausedUpdate.completedTiles, pausedIndex + 1)

        let store = try JobCheckpointStore(workingDirectory: workingDirectory)
        let persisted = try await store.load(jobID: jobID)
        XCTAssertEqual(persisted.lastCompletedTileIndex, pausedIndex)
        XCTAssertTrue(
            try journalFileNames(jobID: jobID).isEmpty,
            "Expiration must return only after the tile transaction journal is cleaned up"
        )
        let outputURL = workingDirectory.appendingPathComponent("output_\(jobID.uuidString).rgba16f.bin")
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let outputBytes = (outputAttributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(
            outputBytes,
            Int64(1600 * 1200 * 8),
            "The flushed output canvas must be the full tier-B x2 canvas"
        )

        let expired = await h.coordinator.didExpire()
        XCTAssertTrue(expired)
        XCTAssertEqual(task.completionCount, 1, "Genuine expiration completes the captured delivery exactly once")
        XCTAssertFalse(task.lastCompletionSuccess ?? true)
        XCTAssertEqual(h.assertions.endCount, 1, "Genuine expiration releases the captured assertion after the pause boundary")
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
        XCTAssertEqual(h.router.retainedTaskCount, 0)
        let state = await activity.lastKnownState
        XCTAssertEqual(state?.phase, .paused)
        XCTAssertEqual(state?.isPaused, true)
    }

    // MARK: No-active-run expiration

    func testCodexThirdReviewNoActiveRunExpirationCannotPauseLaterExecution() async throws {
        let (h, activity) = try await makeDeterministicRecordingHarness()
        await h.coordinator.handleBackgroundExpiration(completedTiles: 0, totalTiles: 4)

        let expired = await h.coordinator.didExpire()
        XCTAssertTrue(expired, "A no-active-run expiration is still reported as an expiration")
        let state = await activity.lastKnownState
        XCTAssertEqual(state?.isPaused, true, "The paused activity state is still published")
        XCTAssertEqual(h.assertions.beginCount, 0)
        XCTAssertEqual(h.assertions.endCount, 0)
        XCTAssertEqual(h.router.retainedTaskCount, 0)

        // A later real job must not inherit a pause from the no-active-run expiration.
        let config = deterministicDNGConfig()
        await h.coordinator.startJob(descriptor(jobID: config.id))
        let resetExpiration = await h.coordinator.didExpire()
        XCTAssertFalse(resetExpiration, "Adopting a new job resets the expiration flag")

        await h.executor.switchExecutionTier(.cpuOnly)
        await assertExecutesWithoutBackgroundPause(h.executor, config: config)

        await h.coordinator.cancelJob()
        XCTAssertEqual(h.assertions.beginCount, h.assertions.endCount)
    }
}
