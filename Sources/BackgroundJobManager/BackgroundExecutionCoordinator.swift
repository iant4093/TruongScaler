import Foundation
import TruongScalerCore
import TiledInferenceEngine

/// Weak, pointer-identity registry of *actual delivered raw tasks* that already received their one
/// and only framework completion.
///
/// It deliberately does not retain its members and purges entries as soon as the object is
/// deallocated. If the allocator later reuses that address for a distinct task, the fresh object is
/// a new identity and must be completed normally. This replaces the previous immortal
/// `Set<ObjectIdentifier>` history, which conflated recycled addresses with completed tasks.
private final class WeakTaskIdentityRegistry: @unchecked Sendable {
    private final class Entry {
        weak var object: AnyObject?

        init(_ object: AnyObject) {
            self.object = object
        }
    }

    // Actor-isolated in `BackgroundExecutionCoordinator`; `@unchecked Sendable` only documents that
    // the registry itself performs no cross-thread access.
    private var entries: [ObjectIdentifier: Entry] = [:]

    func contains(_ object: AnyObject) -> Bool {
        let key = ObjectIdentifier(object)
        guard let entry = entries[key] else { return false }
        guard let existing = entry.object else {
            // The previous owner at this address is gone; this is a distinct task identity.
            entries.removeValue(forKey: key)
            return false
        }
        return existing === object
    }

    func insert(_ object: AnyObject) {
        purgeReleased()
        entries[ObjectIdentifier(object)] = Entry(object)
    }

    func purgeReleased() {
        entries = entries.filter { $0.value.object != nil }
    }

    var liveCount: Int {
        purgeReleased()
        return entries.count
    }
}

/// Identifies the running upscale job for the coordinator / Live Activity.
public struct BackgroundJobDescriptor: Sendable, Equatable {
    public let jobID: UUID
    public let sourceFileName: String
    public let scaleFactor: ScaleFactor
    public let targetWidth: Int
    public let targetHeight: Int
    public let totalTiles: Int
    public let includesOutputPublication: Bool

    public init(
        jobID: UUID,
        sourceFileName: String,
        scaleFactor: ScaleFactor,
        targetWidth: Int,
        targetHeight: Int,
        totalTiles: Int,
        includesOutputPublication: Bool = false
    ) {
        self.jobID = jobID
        self.sourceFileName = sourceFileName
        self.scaleFactor = scaleFactor
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.totalTiles = totalTiles
        self.includesOutputPublication = includesOutputPublication
    }
}

/// Whether a requested lifecycle was adopted. Batch callers may wait for foreground before retrying
/// a deferred descriptor; a superseded request must never execute its retired job.
public enum BackgroundJobStartResult: Sendable, Equatable {
    case started
    case deferred
    case superseded
}

/// Coordinates foreground/background transitions, submits iOS 26/27 `BGContinuedProcessingTaskRequest`,
/// switches CoreML compute units to `.cpuAndNeuralEngine` before background transition, updates the
/// tile loop's `NSProgress`, and triggers a clean `msync()` + checkpoint pause on OS expiration.
///
/// Identifier rules (installed iOS 27 `BGTaskRequest.h`):
/// * `Info.plist` / `BGTaskSchedulerPermittedIdentifiers` advertises the wildcard family
///   `com.iantruong.truongscaler.continued-processing.*`;
/// * the launch handler is registered for a concrete job-scoped identifier below that family;
/// * every submission uses that same concrete job-scoped identifier;
/// * cancellation targets the concrete submitted identifier.
/// Registering the literal wildcard is rejected by the system even when the plist contains it.
///
/// Generation rules (`docs/DEVELOPMENT.md` §1.2):
/// * a delivered system task is adopted only when its concrete identifier equals the current job's
///   concrete identifier (and the submitted identifier, when one exists) *and* the job generation
///   captured at delivery is still current;
/// * every expiration handler captures `(deliveryID, jobID, jobGeneration, deliveryGeneration)` and
///   re-checks all of them before pausing or completing anything;
/// * every multi-`await` lifecycle path revalidates its generation after the `await`, so a delayed
///   submission/assertion/activity call can never act on a newer job;
/// * every expiration captures its job/transition/delivery/activity/assertion/executor-run identity
///   before awaiting and revalidates it immediately after the activity-identity hop and before any
///   pause side effect; the pause itself is scoped to the captured `ExecutionPauseOwner`, so even a
///   request already queued across actors is refused once a newer run registered;
/// * activity mutations are additionally identity-gated by `LiveActivityControlling`, so a delayed
///   failure/pause/terminal/start call cannot publish into a newer activity;
/// * a delivered task is completed (`setTaskCompleted(success:)`) exactly once, including stale,
///   superseded and different-job deliveries. The completion identity is the *live raw task*
///   (weak, pointer personality), never an immortal history of adapter addresses.
///
/// Continued-processing registration is explicitly exempt from the before-launch registration rule
/// (`BGTaskScheduler.h`), so registering from the SwiftUI app entry point is valid.
///
/// Specification: `docs/DEVELOPMENT.md`.
public actor BackgroundExecutionCoordinator {
    /// Wildcard identifier used for `BGTaskSchedulerPermittedIdentifiers` and launch registration.
    public static let continuedProcessingTaskIdentifier = "com.iantruong.truongscaler.continued-processing.*"
    /// Bundle-prefixed semantic context without the wildcard suffix.
    public static let continuedProcessingTaskIdentifierPrefix = "com.iantruong.truongscaler.continued-processing"

    /// Concrete identifier for one submitted request. The scheduler matches it against the
    /// wildcard permitted identifier.
    public static func submittedTaskIdentifier(for jobID: UUID) -> String {
        let suffix = jobID.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        return "\(continuedProcessingTaskIdentifierPrefix).\(suffix)"
    }

    /// True when an identifier is the wildcard pattern itself or a concrete identifier below it.
    public static func isContinuedProcessingIdentifier(_ identifier: String) -> Bool {
        identifier == continuedProcessingTaskIdentifier
            || identifier == continuedProcessingTaskIdentifierPrefix
            || identifier.hasPrefix("\(continuedProcessingTaskIdentifierPrefix).")
    }

    // MARK: - Identity records

    /// Concrete identity of one delivered system task. Expiration handlers and delayed continuations
    /// capture this value and compare it against the coordinator's live state before acting.
    private struct DeliveryIdentity: Sendable, Equatable {
        let deliveryID: UUID
        let jobID: UUID
        let jobGeneration: UInt64
        let deliveryGeneration: UInt64
    }

    /// Every identity/resource an expiration continuation owns across its `await`s.
    ///
    /// The continuation must compare this capture against the coordinator's live state immediately
    /// after each `await` and before any side effect. It may only touch these exact values; in
    /// particular a stale capture can only drain the delivery record/token it captured, never the
    /// replacement job's resources.
    private struct ExpirationCapture {
        let jobID: UUID?
        let jobGeneration: UInt64
        let transitionGeneration: UInt64
        let owner: ExecutionPauseOwner?
        let delivery: DeliveryIdentity?
        let record: DeliveredTaskRecord?
        let deliveryGeneration: UInt64
        let assertionToken: UUID?
    }

    /// One delivered task owned by the coordinator. A reference type so "completed exactly once" is
    /// tracked per delivery even after the coordinator stops treating it as the active delivery.
    private final class DeliveredTaskRecord: @unchecked Sendable {
        let deliveryID: UUID
        let jobID: UUID?
        let jobGeneration: UInt64
        let deliveryGeneration: UInt64
        let adapter: any ContinuedProcessingTaskAdapter
        let rawTask: AnyObject
        var isCompleted = false
        var lastStatusTitle: String?
        var lastStatusSubtitle: String?
        var lastStatusAt: ContinuousClock.Instant?
        var lastStatusCompleted = 0
        var statusFlush: Task<Void, Never>?
        var lastProgressCompleted: Int64 = -1
        var lastProgressTotal: Int64 = -1

        init(
            deliveryID: UUID,
            jobID: UUID?,
            jobGeneration: UInt64,
            deliveryGeneration: UInt64,
            adapter: any ContinuedProcessingTaskAdapter,
            rawTask: AnyObject
        ) {
            self.deliveryID = deliveryID
            self.jobID = jobID
            self.jobGeneration = jobGeneration
            self.deliveryGeneration = deliveryGeneration
            self.adapter = adapter
            self.rawTask = rawTask
        }
    }

    private let executor: TiledPipelineExecutor
    private let liveActivityController: any LiveActivityControlling
    private let scheduler: any BackgroundTaskScheduling
    private let legacyAssertionProvider: any LegacyBackgroundAssertionProviding
    private let deliveryRouter: BackgroundTaskDeliveryRouter?
    /// Platform delivery construction seam. The production default wraps the system `BGTask` in
    /// the iOS adapter; non-iOS builds (and deterministic tests) use the object directly when it
    /// already conforms to the adapter protocol, so the registration→routing path is testable.
    private let makeTaskDelivery: @Sendable (AnyObject) -> BackgroundTaskDelivery

    private var job: BackgroundJobDescriptor?
    private var isJobRunning = false
    private var latestUpdate: PipelineProgressUpdate?

    private var isCurrentlyInBackground = false
    private var didTriggerExpirationPause = false
    private var didPrepareBackgroundCycle = false

    /// Monotonic identity of the current job lifecycle (start → terminal/expiration).
    private var jobGeneration: UInt64 = 0
    /// Monotonic identity of the newest `startJob` request. It lets a start that suspends inside
    /// `supersedePreviousJobIfNeeded` detect that a newer start request adopted in the meantime.
    private var startRequestGeneration: UInt64 = 0
    /// Monotonic identity of the current scene/expiration transition. Bumped by every path that
    /// begins a new lifecycle transition so a suspended transition can detect it was superseded.
    private var transitionGeneration: UInt64 = 0
    /// Monotonic identity of the currently adopted delivered task.
    private var deliveryGeneration: UInt64 = 0

    private var submittedTaskIdentifier: String?
    /// A job reuses its concrete identifier across scene cycles. Cleanup must also match the
    /// cycle that submitted it, or an old async submit can cancel the replacement request.
    private var submittedRequestTransition: UInt64?
    private var legacyAssertionToken: UUID?

    /// Concrete identifiers whose launch handler was successfully registered with the system in
    /// this process. BGTaskScheduler has no unregister API and kills the app on a duplicate
    /// registration, so every concrete job identifier is registered at most once.
    private var registeredTaskIdentifiers: Set<String> = []
    /// Concrete identifiers this process already attempted (success or failure), so a repeatedly
    /// backgrounded foreground job cannot spam registration or retry in a tight loop.
    private var attemptedTaskRegistrations: Set<String> = []
    /// Registration failures by concrete identifier. Nonfatal: foreground processing continues.
    private var taskRegistrationErrors: [String: String] = [:]

    /// The executor run registered for the current job lifecycle (`jobGeneration`).
    ///
    /// Every expiration continuation captures this owner *before* its first `await` and passes it to
    /// `executor.requestGracefulPauseAndWait(ifOwner:)`. The executor only accepts the pause while
    /// this is still the registered run, so a stale continuation whose `await` loses the ownership
    /// race cannot pause a replacement job. A captured `nil` means no run was registered (for example
    /// a no-active-run expiration); such a continuation never issues an unscoped pause.
    private var executionPauseOwner: ExecutionPauseOwner?

    private var activeDeliveryRecord: DeliveredTaskRecord?
    /// Actual raw tasks that already received their one and only `setTaskCompleted(success:)`.
    /// Weak and lifetime-bounded: a distinct task allocated at a recycled address completes
    /// normally instead of inheriting the previous task's completion.
    private let completedTaskIdentities = WeakTaskIdentityRegistry()

    private var lastSchedulingError: String?

    public init(
        executor: TiledPipelineExecutor,
        liveActivityController: any LiveActivityControlling,
        scheduler: (any BackgroundTaskScheduling)? = nil,
        legacyAssertionProvider: (any LegacyBackgroundAssertionProviding)? = nil,
        deliveryRouter: BackgroundTaskDeliveryRouter? = nil,
        deliveryFactory: (@Sendable (AnyObject) -> BackgroundTaskDelivery)? = nil
    ) {
        self.executor = executor
        self.liveActivityController = liveActivityController
        self.scheduler = scheduler ?? BackgroundTaskPlatform.makeDefaultScheduler()
        self.legacyAssertionProvider = legacyAssertionProvider
            ?? BackgroundTaskPlatform.makeDefaultLegacyAssertionProvider()
        self.deliveryRouter = deliveryRouter
        if let deliveryFactory {
            self.makeTaskDelivery = deliveryFactory
        } else {
            #if canImport(BackgroundTasks) && os(iOS)
            self.makeTaskDelivery = { rawTask in
                ContinuedProcessingTaskAdapterFactory.makeDelivery(for: rawTask)
            }
            #else
            self.makeTaskDelivery = { rawTask in
                BackgroundTaskDelivery(
                    rawTask: rawTask,
                    continuedProcessingTask: rawTask as? any ContinuedProcessingTaskAdapter
                )
            }
            #endif
        }
    }

    // MARK: - Registration

    /// Registers the concrete, job-scoped continued-processing identifier with the scheduler.
    ///
    /// Apple's iOS 26/27 headers define the wildcard (`<MainBundle>.<SemanticContext>.*`) as the
    /// identifier advertised in `BGTaskSchedulerPermittedIdentifiers`, while a submitted request
    /// uses a concrete suffix below it (`BGTaskRequest.h`). The system-matched launch handler must
    /// be registered for that concrete submitted identifier; registering the literal wildcard is
    /// rejected by `BGTaskScheduler` even when the plist contains it (reproduced on the iOS 27
    /// simulator). Continued-processing registration is exempt from the before-launch rule, so
    /// this happens immediately before the first submission for the job, while the app is still
    /// foregrounded.
    ///
    /// Returns `nil` on success, or an actionable failure description. Registration failure is
    /// nonfatal and callers must not submit in that case; foreground processing continues.
    private func ensureRegisteredForDelivery(_ identifier: String) -> String? {
        if registeredTaskIdentifiers.contains(identifier) { return nil }
        if let existing = taskRegistrationErrors[identifier] { return existing }
        guard !attemptedTaskRegistrations.contains(identifier) else {
            return taskRegistrationErrors[identifier]
                ?? "Registration for '\(identifier)' was already attempted."
        }
        attemptedTaskRegistrations.insert(identifier)

        guard let deliveryRouter else {
            let message = "No delivery router is installed for '\(identifier)'."
            taskRegistrationErrors[identifier] = message
            return message
        }

        let makeTaskDelivery = self.makeTaskDelivery
        do {
            try scheduler.registerContinuedProcessing(identifier: identifier) { rawTask in
                deliveryRouter.deliver(makeTaskDelivery(rawTask))
            }
            registeredTaskIdentifiers.insert(identifier)
            return nil
        } catch {
            let message = error.localizedDescription
            taskRegistrationErrors[identifier] = message
            return message
        }
    }

    /// Installs the coordinator as the router's delivery handler. A task delivered before this call
    /// is queued by the router and flushed immediately.
    public nonisolated func installDeliveryHandler(on router: BackgroundTaskDeliveryRouter) {
        router.installHandler { [weak self] delivery in
            guard let self else { return }
            Task { await self.handleDeliveredTask(delivery) }
        }
    }

    // MARK: - Job lifecycle

    /// Called by `StudioViewModel` when a real upscale job starts: begins the Live Activity.
    ///
    /// Supersedes any leftover job/delivery/submission from a previous lifecycle before adopting
    /// the new descriptor, then advances `jobGeneration`.
    /// A foreground-gated request is refused before disturbing an existing lifecycle when the
    /// previous photo has already used up its continuation. Once adopted, a later scene transition
    /// prepares a continuation for this job through the normal inactive/background lifecycle.
    @discardableResult
    public func startJob(
        _ descriptor: BackgroundJobDescriptor,
        requiresForegroundStart: Bool = false
    ) async -> BackgroundJobStartResult {
        guard !requiresForegroundStart || !isCurrentlyInBackground else { return .deferred }
        startRequestGeneration &+= 1
        let startRequest = startRequestGeneration

        if job != nil || isJobRunning || activeDeliveryRecord != nil {
            await supersedePreviousJobIfNeeded(for: descriptor)
            // A newer start request may have adopted while the supersede awaited assertion cleanup.
            // This request is stale then and must not overwrite the newer job/activity.
            guard startRequestGeneration == startRequest else { return .superseded }
        }

        // Superseding can await assertion cleanup. An inactive transition during that wait must
        // not leave the next batch photo adopted after the foreground-only preparation window.
        guard !requiresForegroundStart || !isCurrentlyInBackground else { return .deferred }

        jobGeneration &+= 1
        transitionGeneration &+= 1
        job = descriptor
        isJobRunning = true
        latestUpdate = nil
        // Scheduling failures belong to the adopted run. A different photo must not inherit
        // the previous job's refusal before its own first background request has happened.
        lastSchedulingError = nil
        didTriggerExpirationPause = false
        didPrepareBackgroundCycle = false

        let generation = jobGeneration
        // Bind this lifecycle to a job-scoped executor run before any side effect. The executor keeps
        // the newest generation, so a delayed older registration can never overwrite a newer run.
        let owner = ExecutionPauseOwner(jobID: descriptor.jobID, generation: generation)
        executionPauseOwner = owner
        await executor.registerJobRun(owner)

        // Registration is a suspension point: a newer start may have adopted in the meantime. The
        // executor already ignores this older generation; do not publish its activity either.
        guard startRequestGeneration == startRequest,
              isJobRunning,
              jobGeneration == generation,
              job?.jobID == descriptor.jobID else { return .superseded }

        // Identity-gated: a delayed start whose job was replaced while the hop was suspended is a
        // no-op, so it can never replace a newer job's activity.
        _ = await liveActivityController.startActivity(
            jobID: descriptor.jobID,
            sourceFileName: descriptor.sourceFileName,
            scaleFactor: descriptor.scaleFactor,
            targetWidth: descriptor.targetWidth,
            targetHeight: descriptor.targetHeight,
            totalTiles: descriptor.totalTiles,
            ifNewerThanRequestIdentity: generation
        )
        // Revalidate after the activity hop: the job may have completed or been replaced.
        guard isJobRunning, jobGeneration == generation else { return .superseded }
        syncDeliveredTaskProgress(nil)
        return .started
    }

    /// Feeds real pipeline progress to the Live Activity and the continued-processing `Progress`.
    public func updateProgress(_ update: PipelineProgressUpdate) async {
        guard isJobRunning, let job, job.jobID == update.jobID else { return }
        guard !didTriggerExpirationPause else { return }
        latestUpdate = update
        syncDeliveredTaskProgress(nil)

        guard update.stage != .pausedOnDisk else { return }
        let generation = jobGeneration
        // A newer job may replace this one while the activity hop is suspended. The identity gate
        // makes that delayed update a no-op instead of publishing old progress into the new activity.
        _ = await liveActivityController.updateProgress(
            stageTitle: Self.stageTitle(for: update),
            completedTiles: update.completedTiles,
            totalTiles: update.totalTiles,
            progressFraction: update.overallFraction,
            estimatedSecondsRemaining: update.estimatedSecondsRemaining,
            forceImmediate: false,
            ifActivityIdentity: generation
        )
        // No state is published after this await; a newer job owns the coordinator from then on.
    }

    /// Terminal success path. Ends the Live Activity with a completed state and completes the
    /// delivered system task exactly once.
    public func completeJob(success: Bool, message: String) async {
        await finishJob(success: success, message: message, cancelling: false)
    }

    /// Terminal cancellation path (user pressed Stop). Distinct from failure and success states.
    public func cancelJob(message: String = "Upscale cancelled") async {
        await finishJob(success: false, message: message, cancelling: true)
    }

    private func finishJob(success: Bool, message: String, cancelling: Bool) async {
        guard isJobRunning, let descriptor = job else { return }
        let generation = jobGeneration
        // Claim the terminal transition synchronously: duplicate/interleaved terminal calls become
        // no-ops instead of marking two states or completing the system task twice.
        isJobRunning = false
        transitionGeneration &+= 1

        let completed = latestUpdate?.completedTiles ?? (cancelling ? 0 : descriptor.totalTiles)
        let total = latestUpdate?.totalTiles ?? descriptor.totalTiles

        if cancelling {
            _ = await liveActivityController.markCancelled(
                completedTiles: max(0, completed),
                totalTiles: max(0, total),
                message: message,
                ifActivityIdentity: generation
            )
        } else if success {
            let finalCompleted = max(completed, total)
            let finalTotal = max(total, finalCompleted)
            _ = await liveActivityController.markCompleted(
                completedTiles: finalCompleted,
                totalTiles: finalTotal,
                finalMessage: message,
                ifActivityIdentity: generation
            )
        } else {
            _ = await liveActivityController.markFailed(
                completedTiles: max(0, completed),
                totalTiles: max(0, total),
                message: message,
                ifActivityIdentity: generation
            )
        }

        // A scene change can advance the transition while the terminal activity hop suspends,
        // but it cannot retire this job's delivered task. Only replacement/removal of the job
        // supersedes terminal cleanup; otherwise the completed task would remain retained forever.
        guard jobGeneration == generation, job?.jobID == descriptor.jobID else { return }
        await finishTerminalState(success: success, generation: generation)
    }

    private func finishTerminalState(success: Bool, generation: UInt64) async {
        guard jobGeneration == generation else { return }
        didTriggerExpirationPause = false
        didPrepareBackgroundCycle = false
        transitionGeneration &+= 1

        cancelSubmittedRequestIfNeeded()
        let record = activeDeliveryRecord
        job = nil
        executionPauseOwner = nil
        if let record { completeDeliveredTask(record, success: success) }
        // This function revalidated `jobGeneration` immediately before clearing the job, so it is
        // the explicit current owner of whatever assertion token is still installed.
        await releaseCurrentLegacyAssertion()
    }

    private func supersedePreviousJobIfNeeded(for descriptor: BackgroundJobDescriptor) async {
        // Starting the same job again is a restart, not a replacement: keep any adopted delivery.
        if let current = job, current.jobID == descriptor.jobID, isJobRunning { return }

        isJobRunning = false
        transitionGeneration &+= 1
        // This lifecycle is retired; its registered executor run must no longer be the pause target.
        executionPauseOwner = nil
        cancelSubmittedRequestIfNeeded()
        let record = activeDeliveryRecord
        job = nil
        if let record { completeDeliveredTask(record, success: false) }
        // No await occurred since this supersede began, so the coordinator is still the explicit
        // current owner of the installed assertion.
        await releaseCurrentLegacyAssertion()
    }

    // MARK: - Scene transitions

    /// Called for `.inactive`. The continued-processing request must be created while the app is
    /// still foregrounded, so preparation happens here and `.background` is idempotent.
    public func handleWillResignActive(jobTitle: String? = nil, jobSubtitle: String? = nil) async {
        await prepareForBackgroundTransition(jobTitle: jobTitle, jobSubtitle: jobSubtitle)
    }

    /// Called when SwiftUI `scenePhase` changes to `.background`.
    ///
    /// 1. Switches `executor` to background mode (`.cpuAndNeuralEngine` + CPU color kernels) BEFORE
    ///    acknowledging the transition.
    /// 2. Submits `BGContinuedProcessingTaskRequest` while the app is still foregrounded.
    /// 3. Acquires the legacy `beginBackgroundTask` safety net.
    public func handleDidEnterBackground(jobTitle: String, jobSubtitle: String) async {
        await prepareForBackgroundTransition(jobTitle: jobTitle, jobSubtitle: jobSubtitle)
    }

    private func prepareForBackgroundTransition(jobTitle: String?, jobSubtitle: String?) async {
        isCurrentlyInBackground = true
        guard !didPrepareBackgroundCycle else { return }
        // Only a preparation that actually begins advances the transition. A `.background` callback
        // that arrives while `.inactive` preparation is still awaiting must not invalidate the
        // in-flight submission (it is the same transition).
        transitionGeneration &+= 1
        let transition = transitionGeneration
        didPrepareBackgroundCycle = true
        didTriggerExpirationPause = false

        // Publish CPU color / next-prediction policy first, without waiting for an in-flight Core ML
        // call on the registry actor. Waiting here used to delay BOTH the foreground-only request
        // and beginBackgroundTask until a potentially minute-long HAT tile finished.
        let policyTransition = await executor.beginBackgroundExecutionMode(true)

        guard transitionGeneration == transition,
              isCurrentlyInBackground,
              isJobRunning,
              let job else {
            await policyTransition.value
            return
        }

        let generation = jobGeneration
        if let record = activeDeliveryRecord, isCurrent(record: record) {
            // The OS continuation belongs to the job, not one foreground/background cycle.
            // Reuse it until success, Stop, failure or actual system expiration.
            await policyTransition.value
            return
        }
        await acquireLegacyAssertion(
            expectedJobGeneration: generation,
            expectedTransition: transition
        )
        guard transitionGeneration == transition,
              isCurrentlyInBackground,
              isJobRunning,
              jobGeneration == generation else { return }
        let identifier = Self.submittedTaskIdentifier(for: job.jobID)
        submittedTaskIdentifier = identifier
        submittedRequestTransition = transition
        let descriptor = ContinuedProcessingRequestDescriptor(
            identifier: identifier,
            title: jobTitle ?? "Upscaling \(job.sourceFileName)",
            subtitle: jobSubtitle ?? "\(job.scaleFactor.rawValue)× super-resolution"
        )

        // The wildcard is only the Info.plist family declaration. The system-matched launch handler
        // and the submitted request must use the same concrete identifier, and the handler must be
        // registered before submitting. Registration is exempt from the before-launch rule.
        if let registrationError = ensureRegisteredForDelivery(identifier) {
            guard transitionGeneration == transition,
                  isCurrentlyInBackground,
                  isJobRunning,
                  jobGeneration == generation else { return }
            lastSchedulingError = "Background continuation is unavailable for this job "
                + "(the system refused its continued-processing registration). Foreground processing "
                + "continues normally. \(registrationError)"
            Diagnostics.shared.record(category: .background, level: .warning,
                code: "background.registration.failed", message: "continuation registration refused",
                fields: ["correlationID": job.jobID.uuidString])
        } else {
            do {
                try await scheduler.submitContinuedProcessing(descriptor)
                guard transitionGeneration == transition,
                      isCurrentlyInBackground,
                      isJobRunning,
                      jobGeneration == generation else {
                    cancelObsoleteSubmissionIfNeeded(identifier, transition: transition)
                    return
                }
                lastSchedulingError = nil
                Diagnostics.shared.record(category: .background, level: .notice,
                    code: "background.request.submitted", message: "continuation requested; awaiting system delivery",
                    fields: ["correlationID": job.jobID.uuidString, "computeRequested": "cpuAndNeuralEngine"])
            } catch {
                guard transitionGeneration == transition,
                      isCurrentlyInBackground,
                      isJobRunning,
                      jobGeneration == generation else {
                    cancelObsoleteSubmissionIfNeeded(identifier, transition: transition)
                    return
                }
                lastSchedulingError = error.localizedDescription
                Diagnostics.shared.recordError(error, category: .background,
                    code: "background.request.failed", context: ["correlationID": job.jobID.uuidString])
            }
        }

        await policyTransition.value
    }

    /// Cancels a request submitted by a transition whose job/transition is no longer current.
    private func cancelObsoleteSubmissionIfNeeded(_ identifier: String, transition: UInt64) {
        if submittedTaskIdentifier == identifier, submittedRequestTransition != transition,
           isJobRunning, isCurrentlyInBackground {
            // A newer scene cycle now owns this same concrete identifier. The scheduler's
            // cancellation API cannot distinguish A from B, so leave B's request/bookkeeping intact.
            return
        }
        if let record = activeDeliveryRecord, record.adapter.identifier == identifier, isCurrent(record: record) {
            // A continuation can be delivered before submitTaskRequest returns. Foregrounding
            // preserves that granted task; the old submit's late return must preserve it too.
            return
        }
        scheduler.cancelContinuedProcessing(identifier: identifier)
        if submittedTaskIdentifier == identifier {
            submittedTaskIdentifier = nil
            submittedRequestTransition = nil
        }
    }

    /// Called when SwiftUI `scenePhase` returns to `.active`.
    /// Restores foreground `.all` compute units and ends any temporary background task assertion.
    public func handleDidBecomeActive() async {
        transitionGeneration &+= 1
        isCurrentlyInBackground = false
        didTriggerExpirationPause = false
        didPrepareBackgroundCycle = false

        // Cancel a request still queued for later delivery, but retain an already granted task.
        // Completing that task false here made normal app switching look like a failed job.
        if activeDeliveryRecord == nil { cancelSubmittedRequestIfNeeded() }
        let token = legacyAssertionToken

        // Clear the old bridge before waiting behind an in-flight model call. Otherwise a quick
        // second background cycle reuses its stale expiration handler and this delayed cleanup
        // can then release the assertion that cycle was relying on. Release only the captured token.
        let policyTransition = await executor.beginBackgroundExecutionMode(false)
        await releaseLegacyAssertion(token)
        await policyTransition.value
    }

    /// Invoked by the OS expiration handler (system task or legacy assertion).
    ///
    /// Captures the active job/transition/delivery/activity/assertion/executor-run identity, waits
    /// for the captured executor run's stable paused boundary, and only then publishes the paused
    /// activity, releases the captured legacy assertion and completes the captured delivered task.
    /// A replacement job adopted during any `await` makes every later step a no-op.
    public func handleBackgroundExpiration(completedTiles: Int, totalTiles: Int) async {
        await handleBackgroundExpiration(
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            identity: nil,
            expectedJobGeneration: nil
        )
    }

    private func handleBackgroundExpiration(
        completedTiles: Int,
        totalTiles: Int,
        identity: DeliveryIdentity?,
        expectedJobGeneration: UInt64?
    ) async {
        if let identity, !deliveryIdentityIsCurrent(identity) { return }
        if let expectedJobGeneration {
            guard isJobRunning, jobGeneration == expectedJobGeneration else { return }
        }
        guard !didTriggerExpirationPause else { return }

        // Claim the expiration synchronously, then capture every identity/resource this continuation
        // may touch. No other coordinator work can interleave between these synchronous statements.
        didTriggerExpirationPause = true
        Diagnostics.shared.record(category: .background, level: .notice,
            code: "background.expired", message: "system requested a durable pause",
            fields: ["correlationID": job?.jobID.uuidString ?? "none",
                     "completed": "\(completedTiles)", "total": "\(totalTiles)"])
        isJobRunning = false
        didPrepareBackgroundCycle = false
        transitionGeneration &+= 1
        let capture = ExpirationCapture(
            jobID: job?.jobID,
            jobGeneration: jobGeneration,
            transitionGeneration: transitionGeneration,
            owner: executionPauseOwner,
            delivery: identity,
            record: activeDeliveryRecord,
            deliveryGeneration: deliveryGeneration,
            assertionToken: legacyAssertionToken
        )

        // Capture the activity identity. A replacement job can adopt while this MainActor hop is
        // suspended; the capture is revalidated immediately afterwards, BEFORE any pause side effect.
        // When no activity exists this is nil; the identity gate then matches only the still-absent
        // activity, so a newer job's activity cannot receive this pause.
        let activityIdentity = await liveActivityController.activityLifecycleIdentity

        // Revalidate job/transition/delivery/activity/assertion/owner identity after the awaited
        // identity read and before the pause. A stale continuation drains only its captured old
        // resources and must never pause/complete/release the replacement job.
        guard expirationCaptureIsCurrent(capture) else {
            await drainCapturedExpirationResources(capture)
            return
        }

        // The scoped pause is the only pause side effect. The executor rejects it when `owner` is no
        // longer the registered run, including when a newer registration lands while this call is
        // queued. A captured `nil` owner means no run was registered (no-active-run expiration):
        // never send an unscoped pause that could stop a run registered by a later job.
        if let owner = capture.owner {
            let paused = await executor.requestGracefulPauseAndWait(ifOwner: owner)
            // The pause wait is another suspension point. Only a still-current capture may publish
            // the paused state or drain its delivery/assertion.
            guard expirationCaptureIsCurrent(capture) else {
                await drainCapturedExpirationResources(capture)
                return
            }
            guard paused else {
                // The executor refused the captured run. There is no stable boundary to wait for;
                // drain exactly the captured old resources and do not publish B's paused state.
                await drainCapturedExpirationResources(capture)
                return
            }
        }

        _ = await liveActivityController.markPaused(
            completedTiles: max(0, completedTiles),
            totalTiles: max(0, totalTiles),
            ifActivityIdentity: activityIdentity
        )

        // A replacement job/transition may have adopted while the paused-activity hop was suspended.
        guard expirationCaptureIsCurrent(capture) else {
            await drainCapturedExpirationResources(capture)
            return
        }
        if let record = capture.record {
            completeDeliveredTask(record, success: false)
        }
        // The captured run reached its stable boundary; release exactly the captured assertion.
        await releaseLegacyAssertion(capture.assertionToken)
    }

    /// Revalidates every value captured by an expiration continuation against live coordinator state.
    ///
    /// The owner must still be the registered run for the captured generation; the captured delivery
    /// record must still be the active record; and the job/transition/delivery generations must be
    /// unchanged. `nil` captured values only match `nil` live values, so a captured no-activity or
    /// no-assertion cleanup can never be retargeted at a newer resource.
    private func expirationCaptureIsCurrent(_ capture: ExpirationCapture) -> Bool {
        guard capture.jobGeneration == jobGeneration,
              capture.transitionGeneration == transitionGeneration,
              capture.jobID == job?.jobID,
              capture.owner == executionPauseOwner,
              capture.deliveryGeneration == deliveryGeneration else { return false }

        switch (capture.record, activeDeliveryRecord) {
        case (nil, nil):
            break
        case (let captured?, let current?):
            guard captured === current else { return false }
        default:
            return false
        }

        if let delivery = capture.delivery {
            guard let record = activeDeliveryRecord,
                  record.deliveryID == delivery.deliveryID,
                  record.jobGeneration == delivery.jobGeneration,
                  record.jobID == delivery.jobID,
                  record.deliveryGeneration == delivery.deliveryGeneration,
                  delivery.jobGeneration == jobGeneration,
                  delivery.deliveryGeneration == deliveryGeneration else { return false }
        }
        return true
    }

    /// Releases exactly the captured old delivery record and assertion token, never a newer job's.
    ///
    /// `completeDeliveredTask` is idempotent and keyed by the captured record, so a replacement that
    /// already drained the old delivery makes this a no-op. `releaseLegacyAssertion` requires token
    /// identity and a captured `nil` means this continuation owned no assertion.
    private func drainCapturedExpirationResources(_ capture: ExpirationCapture) async {
        if let record = capture.record {
            completeDeliveredTask(record, success: false)
        }
        await releaseLegacyAssertion(capture.assertionToken)
    }

    /// Expiration routed from the delivered task's `expirationHandler`. The concrete delivery/job
    /// identity captured when the handler was installed is re-checked before anything is paused.
    private func handleDeliveryExpiration(_ identity: DeliveryIdentity) async {
        guard deliveryIdentityIsCurrent(identity) else { return }
        let completed = latestUpdate?.completedTiles ?? 0
        let total = latestUpdate?.totalTiles ?? job?.totalTiles ?? 0
        await handleBackgroundExpiration(
            completedTiles: completed,
            totalTiles: total,
            identity: identity,
            expectedJobGeneration: identity.jobGeneration
        )
    }

    /// Public compatibility entry point. Captures the current delivery/job identity before awaiting
    /// so a queued call cannot pause a job that replaced it while it was suspended.
    public func handleSystemExpiration() async {
        let generation = jobGeneration
        let identity = activeDeliveryRecord.map { record in
            DeliveryIdentity(
                deliveryID: record.deliveryID,
                jobID: record.jobID ?? job?.jobID ?? UUID(),
                jobGeneration: record.jobGeneration,
                deliveryGeneration: record.deliveryGeneration
            )
        }
        let completed = latestUpdate?.completedTiles ?? 0
        let total = latestUpdate?.totalTiles ?? job?.totalTiles ?? 0
        await handleBackgroundExpiration(
            completedTiles: completed,
            totalTiles: total,
            identity: identity,
            expectedJobGeneration: isJobRunning ? generation : nil
        )
    }

    private func deliveryIdentityIsCurrent(_ identity: DeliveryIdentity) -> Bool {
        guard isJobRunning, let job else { return false }
        guard job.jobID == identity.jobID, jobGeneration == identity.jobGeneration else { return false }
        guard let record = activeDeliveryRecord else { return false }
        guard record.deliveryID == identity.deliveryID,
              record.deliveryGeneration == identity.deliveryGeneration,
              deliveryGeneration == identity.deliveryGeneration,
              record.jobGeneration == identity.jobGeneration,
              record.jobID == identity.jobID else { return false }
        return true
    }

    // MARK: - Delivered task handling

    /// Adopts a delivered continued-processing task only when its concrete identifier belongs to the
    /// current submitted request/job and the current generation. Stale, superseded and different-job
    /// deliveries are completed `false` exactly once and never affect the current job.
    func handleDeliveredTask(_ delivery: BackgroundTaskDelivery) async {
        guard let adapter = delivery.continuedProcessingTask else {
            lastSchedulingError = "A continued-processing task without a typed adapter cannot be validated or completed."
            deliveryRouter?.release(delivery.rawTask)
            return
        }

        guard BackgroundExecutionCoordinator.isContinuedProcessingIdentifier(adapter.identifier) else {
            refuseDelivery(
                delivery,
                adapter: adapter,
                reason: "Refused continued-processing task '\(adapter.identifier)': not a TruongScaler continued-processing identifier."
            )
            return
        }

        // A delivery without an in-process job cannot be advanced: the view model persists no
        // resumable descriptor. Finish it visibly instead of leaving the system task running.
        guard isJobRunning, let job else {
            let generation = jobGeneration
            let transition = transitionGeneration
            // Capture every resource this stale operation might touch before awaiting.
            let capturedAssertionToken = legacyAssertionToken
            lastSchedulingError = "A continued-processing task was delivered without an active upscale job. "
                + "The app does not persist a resumable job descriptor across process launches."
            let capturedActivityIdentity = await liveActivityController.activityLifecycleIdentity

            // A newer job may have started and acquired its own activity/assertion while the
            // identity read was suspended. Report the failure only for the still-unowned state.
            let stillUnaffiliated = !isJobRunning
                && jobGeneration == generation
                && transitionGeneration == transition
            if stillUnaffiliated {
                _ = await liveActivityController.markFailed(
                    completedTiles: 0,
                    totalTiles: 0,
                    message: "Could not restore the background job",
                    ifActivityIdentity: capturedActivityIdentity
                )
            }

            // The delivered task itself is always refused/completed exactly once and its router
            // retention released. It is not the newer job's active delivery.
            refuseDelivery(delivery, adapter: adapter, reason: nil)

            // Revalidate after the failure publication: a newer job started during the await owns
            // the coordinator (and possibly the installed assertion) now. Release only the exact
            // token captured while nothing owned it; nil means this operation owned no resource.
            guard !isJobRunning,
                  jobGeneration == generation,
                  transitionGeneration == transition else { return }
            await releaseLegacyAssertion(capturedAssertionToken)
            return
        }

        let generation = jobGeneration
        let expectedIdentifier = Self.submittedTaskIdentifier(for: job.jobID)
        let submittedMatches = submittedTaskIdentifier == nil || submittedTaskIdentifier == expectedIdentifier
        guard submittedMatches, adapter.identifier == expectedIdentifier else {
            let currentIdentifier = submittedTaskIdentifier ?? expectedIdentifier
            lastSchedulingError = "Refused continued-processing task '\(adapter.identifier)' "
                + "because it does not match the current job's request '\(currentIdentifier)'."
            refuseDelivery(delivery, adapter: adapter, reason: nil)
            return
        }

        // Superseding delivery for the same job: finish the older one exactly once.
        if let existing = activeDeliveryRecord {
            completeDeliveredTask(existing, success: false)
        }

        deliveryGeneration &+= 1
        let record = DeliveredTaskRecord(
            deliveryID: UUID(),
            jobID: job.jobID,
            jobGeneration: generation,
            deliveryGeneration: deliveryGeneration,
            adapter: adapter,
            rawTask: delivery.rawTask
        )
        activeDeliveryRecord = record
        Diagnostics.shared.record(category: .background, level: .notice,
            code: "background.task.delivered", message: "system granted continuation",
            fields: ["correlationID": job.jobID.uuidString])
        let identity = DeliveryIdentity(
            deliveryID: record.deliveryID,
            jobID: job.jobID,
            jobGeneration: generation,
            deliveryGeneration: record.deliveryGeneration
        )
        adapter.installExpirationHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleDeliveryExpiration(identity) }
        }

        // beginBackgroundTask is only the bridge until the long-running grant arrives. Its much
        // shorter expiration must not pause a valid BGContinuedProcessingTask later.
        let shortAssertion = legacyAssertionToken
        await releaseLegacyAssertion(shortAssertion)
        guard isCurrent(record: record) else {
            completeDeliveredTask(record, success: false)
            return
        }

        let state = await liveActivityController.lastKnownState
        guard isCurrent(record: record) else {
            completeDeliveredTask(record, success: false)
            return
        }
        if state == nil {
            _ = await liveActivityController.startActivity(
                jobID: job.jobID,
                sourceFileName: job.sourceFileName,
                scaleFactor: job.scaleFactor,
                targetWidth: job.targetWidth,
                targetHeight: job.targetHeight,
                totalTiles: job.totalTiles,
                ifNewerThanRequestIdentity: generation
            )
            guard isCurrent(record: record) else {
                completeDeliveredTask(record, success: false)
                return
            }
        }
        if let update = latestUpdate {
            _ = await liveActivityController.updateProgress(
                stageTitle: Self.stageTitle(for: update),
                completedTiles: update.completedTiles,
                totalTiles: update.totalTiles,
                progressFraction: update.overallFraction,
                estimatedSecondsRemaining: update.estimatedSecondsRemaining,
                forceImmediate: false,
                ifActivityIdentity: record.jobGeneration
            )
            guard isCurrent(record: record) else {
                completeDeliveredTask(record, success: false)
                return
            }
        }

        syncDeliveredTaskProgress(record)
    }

    private func isCurrent(record: DeliveredTaskRecord) -> Bool {
        guard isJobRunning, let job else { return false }
        guard job.jobID == record.jobID, jobGeneration == record.jobGeneration else { return false }
        guard let active = activeDeliveryRecord, active === record else { return false }
        guard deliveryGeneration == record.deliveryGeneration else { return false }
        return true
    }

    /// Refuses a delivery that does not belong to the current job: completes it exactly once and
    /// never touches the active job, activity or progress.
    private func refuseDelivery(
        _ delivery: BackgroundTaskDelivery,
        adapter: any ContinuedProcessingTaskAdapter,
        reason: String?
    ) {
        if let reason { lastSchedulingError = reason }
        let record = DeliveredTaskRecord(
            deliveryID: UUID(),
            jobID: nil,
            jobGeneration: jobGeneration,
            deliveryGeneration: 0,
            adapter: adapter,
            rawTask: delivery.rawTask
        )
        completeDeliveredTask(record, success: false)
    }

    /// Completes the delivered system task exactly once (`setTaskCompleted(success:)`).
    ///
    /// Deduplication is by the *actual raw task's live identity*, not by an immortal adapter address:
    /// wrappers around one raw task complete once, while a distinct new task allocated at a recycled
    /// address is a new identity and completes normally.
    private func completeDeliveredTask(_ record: DeliveredTaskRecord, success: Bool) {
        guard !record.isCompleted else { return }
        let rawTask = record.rawTask
        guard !completedTaskIdentities.contains(rawTask) else {
            // Already completed through another wrapper for the same live raw task. This delivery
            // still owns the router's retention entry, so drain it before returning.
            record.isCompleted = true
            if activeDeliveryRecord === record { activeDeliveryRecord = nil }
            deliveryRouter?.release(rawTask)
            return
        }
        // Flip every guard before calling into the framework so re-entrant expiration cannot
        // double-complete.
        completedTaskIdentities.insert(rawTask)
        record.isCompleted = true
        record.statusFlush?.cancel()
        record.statusFlush = nil
        if activeDeliveryRecord === record { activeDeliveryRecord = nil }
        record.adapter.setTaskCompleted(success: success)
        deliveryRouter?.release(rawTask)
    }

    private func syncDeliveredTaskProgress(_ record: DeliveredTaskRecord?, forceStatus: Bool = false) {
        guard let record = record ?? activeDeliveryRecord, !record.isCompleted else { return }
        guard activeDeliveryRecord === record, let job, record.jobID == job.jobID,
              record.jobGeneration == jobGeneration else { return }

        let total = latestUpdate?.totalTiles ?? job.totalTiles
        let completed = latestUpdate?.completedTiles ?? 0
        let status = job.includesOutputPublication && total > 0 && completed >= total
            ? "Saving photo…" : (latestUpdate.map(Self.stageTitle) ?? "Preparing image…")
        let title = status.hasPrefix("Upscaling") ? "Upscaling" : status
        let subtitle = total > 0 ? "Tile \(min(total, max(1, max(completed, (latestUpdate?.currentTileIndex ?? 0) + 1))))/\(total)" : ""
        let changed = record.lastStatusTitle != title || record.lastStatusSubtitle != subtitle
        let now = ContinuousClock.now
        let elapsed = record.lastStatusAt.map { now - $0 >= .milliseconds(750) } ?? true
        let majorTransition = record.lastStatusTitle != title || (record.lastStatusCompleted == 0 && completed > 0) || completed >= total
        if changed && (forceStatus || majorTransition || elapsed) {
            record.adapter.setStatus(title: title, subtitle: subtitle)
            record.lastStatusTitle = title; record.lastStatusSubtitle = subtitle
            record.lastStatusAt = now; record.lastStatusCompleted = completed
        } else if changed && record.statusFlush == nil {
            record.statusFlush = Task { [weak self, weak record] in
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled, let self, let record else { return }
                await self.flushStatus(record)
            }
        }
        let done = total > 0 ? Int64(max(0, min(completed, total))) : 0
        let units = total > 0 ? Int64(total) + (job.includesOutputPublication ? 1 : 0) : 1
        if record.lastProgressCompleted != done || record.lastProgressTotal != units {
            record.adapter.setProgress(completedUnitCount: done, totalUnitCount: units)
            record.lastProgressCompleted = done; record.lastProgressTotal = units
        }
    }

    private func flushStatus(_ record: DeliveredTaskRecord) {
        record.statusFlush = nil
        syncDeliveredTaskProgress(record, forceStatus: true)
    }

    // MARK: - Submitted request bookkeeping

    private func cancelSubmittedRequestIfNeeded() {
        guard let identifier = submittedTaskIdentifier else { return }
        submittedTaskIdentifier = nil
        submittedRequestTransition = nil
        scheduler.cancelContinuedProcessing(identifier: identifier)
    }

    // MARK: - Legacy assertion balance

    /// Acquires the legacy assertion only while the job/transition that requested it is still
    /// current. If the resource finishes acquiring after its owner ended, it is released immediately
    /// and remains balanced.
    private func acquireLegacyAssertion(
        expectedJobGeneration: UInt64,
        expectedTransition: UInt64
    ) async {
        guard isJobRunning,
              jobGeneration == expectedJobGeneration,
              transitionGeneration == expectedTransition,
              activeDeliveryRecord == nil,
              legacyAssertionToken == nil else { return }

        let token = await legacyAssertionProvider.beginBackgroundTask(
            name: "TruongScalerContinuedProcessing"
        ) { [weak self] in
            guard let self else { return }
            Task {
                await self.handleLegacyAssertionExpiration(
                    expectedJobGeneration: expectedJobGeneration,
                    expectedTransition: expectedTransition
                )
            }
        }
        guard let token else { return }

        guard isJobRunning,
              jobGeneration == expectedJobGeneration,
              transitionGeneration == expectedTransition,
              activeDeliveryRecord == nil,
              legacyAssertionToken == nil else {
            await legacyAssertionProvider.endBackgroundTask(token: token)
            return
        }
        legacyAssertionToken = token
    }

    private func handleLegacyAssertionExpiration(
        expectedJobGeneration: UInt64,
        expectedTransition: UInt64
    ) async {
        guard isJobRunning,
              jobGeneration == expectedJobGeneration,
              transitionGeneration == expectedTransition,
              legacyAssertionToken != nil,
              activeDeliveryRecord == nil else { return }
        let completed = latestUpdate?.completedTiles ?? 0
        let total = latestUpdate?.totalTiles ?? job?.totalTiles ?? 0
        await handleBackgroundExpiration(
            completedTiles: completed,
            totalTiles: total,
            identity: nil,
            expectedJobGeneration: expectedJobGeneration
        )
    }

    /// Releases exactly the assertion token captured before an `await`.
    ///
    /// A captured `nil` means that operation owned no resource; it must never fall back to
    /// "release whatever is current now", because a newer job may have acquired an assertion while
    /// the operation was suspended.
    private func releaseLegacyAssertion(_ token: UUID?) async {
        guard let token, legacyAssertionToken == token else { return }
        legacyAssertionToken = nil
        await legacyAssertionProvider.endBackgroundTask(token: token)
    }

    /// Releases the assertion currently installed by this coordinator.
    ///
    /// Only for synchronous current-owner cleanup paths that have already revalidated the owning
    /// job/transition identity (terminal or supersede), where no newer job can have adopted between
    /// the revalidation and this call.
    private func releaseCurrentLegacyAssertion() async {
        guard let token = legacyAssertionToken else { return }
        legacyAssertionToken = nil
        await legacyAssertionProvider.endBackgroundTask(token: token)
    }

    // MARK: - Queries

    public func isInBackground() -> Bool {
        isCurrentlyInBackground
    }

    public func didExpire() -> Bool {
        didTriggerExpirationPause
    }

    /// The last registration/submission/cancellation failure, if any. Cleared by a new job or
    /// successful submit. Kept unscoped for diagnostics and compatibility callers.
    public func schedulingError() -> String? {
        lastSchedulingError
    }

    /// A UI continuation may query after its scene/pipeline await outlives the originating job.
    /// Return a notice only while that exact job is still running, never for idle or replacement work.
    public func schedulingError(for jobID: UUID) -> String? {
        guard isJobRunning, job?.jobID == jobID else { return nil }
        return lastSchedulingError
    }

    public func hasActiveDeliveredTask() -> Bool {
        guard let record = activeDeliveryRecord else { return false }
        return !record.isCompleted
    }

    /// Number of live raw-task completion identities still weakly tracked.
    ///
    /// The registry holds no strong references and purges released tasks, so this count is bounded
    /// by live task lifetimes (never an immortal address history). Used by the integration tests to
    /// prove the completion identity drains.
    func completedTaskIdentityLifetimeCount() -> Int {
        completedTaskIdentities.liveCount
    }

    // MARK: - Activity presentation

    private static func stageTitle(for update: PipelineProgressUpdate) -> String {
        // Older progress producers supply the stage without a phase. Preserve their tile facts.
        if update.phase == .decodingSource, update.stage == .denoisingAndUpscalingTiles, update.totalTiles > 0 {
            return "Upscaling · tile \(max(1, min(update.completedTiles, update.totalTiles)))/\(update.totalTiles)"
        }
        switch update.phase {
        case .decodingSource, .preparingModels: return "Preparing photo…"
        case .extractingTile, .predictingSuperResolution, .verifyingSuperResolution,
             .reconstructingTile, .blendingTile, .committingTile, .tileCommitted:
            guard update.totalTiles > 0 else { return "Upscaling…" }
            let number = min(update.totalTiles, max(1, max(update.completedTiles, (update.currentTileIndex ?? 0) + 1)))
            return "Upscaling · tile \(number)/\(update.totalTiles)"
        case .finalizing, .completed: return "Saving photo…"
        case .paused: return "Paused"
        case .failed: return "Unable to finish"
        }
    }
}
