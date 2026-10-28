import Foundation
import TruongScalerCore
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Abstraction over the Live Activity lifecycle so `BackgroundExecutionCoordinator` can be unit
/// tested with a recording double on macOS, where ActivityKit does not exist.
@MainActor
public protocol LiveActivityControlling: AnyObject, Sendable {
    var lastKnownState: UpscaleActivityAttributes.ContentState? { get }

    /// Identity of the activity lifecycle currently representing a job, or `nil` when no activity
    /// lifecycle is current.
    ///
    /// Callers capture this value before an `await` and pass it back to the identity-aware mutators
    /// below. That way a delayed lifecycle call can never publish failure/completion/pause state
    /// into a job that replaced it while the call was suspended.
    var activityLifecycleIdentity: UInt64? { get }

    func startActivity(
        jobID: UUID,
        sourceFileName: String,
        scaleFactor: ScaleFactor,
        targetWidth: Int,
        targetHeight: Int,
        totalTiles: Int
    )

    func updateProgress(
        stageTitle: String,
        completedTiles: Int,
        totalTiles: Int,
        progressFraction: Double,
        estimatedSecondsRemaining: Int?,
        forceImmediate: Bool
    ) async

    func markPaused(completedTiles: Int, totalTiles: Int) async
    func markCompleted(completedTiles: Int, totalTiles: Int, finalMessage: String) async
    func markCancelled(completedTiles: Int, totalTiles: Int, message: String) async
    func markFailed(completedTiles: Int, totalTiles: Int, message: String) async
    func endActivity(finalMessage: String, dismissPolicySeconds: TimeInterval) async

    // MARK: - Identity-aware mutations

    /// Starts a new activity only when `requestIdentity` is newer than the last start request the
    /// controller accepted. Returns `true` when this call published the new activity.
    @discardableResult
    func startActivity(
        jobID: UUID,
        sourceFileName: String,
        scaleFactor: ScaleFactor,
        targetWidth: Int,
        targetHeight: Int,
        totalTiles: Int,
        ifNewerThanRequestIdentity requestIdentity: UInt64
    ) async -> Bool

    /// Applies the update only while `expectedIdentity` still identifies the current activity.
    @discardableResult
    func updateProgress(
        stageTitle: String,
        completedTiles: Int,
        totalTiles: Int,
        progressFraction: Double,
        estimatedSecondsRemaining: Int?,
        forceImmediate: Bool,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool

    /// Applies the pause only while `expectedIdentity` still identifies the current activity.
    @discardableResult
    func markPaused(
        completedTiles: Int,
        totalTiles: Int,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool

    /// Applies the terminal state only while `expectedIdentity` still identifies the current activity.
    @discardableResult
    func markCompleted(
        completedTiles: Int,
        totalTiles: Int,
        finalMessage: String,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool

    /// Applies the terminal state only while `expectedIdentity` still identifies the current activity.
    @discardableResult
    func markCancelled(
        completedTiles: Int,
        totalTiles: Int,
        message: String,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool

    /// Applies the failure state only while `expectedIdentity` still identifies the current activity.
    /// A captured `nil` matches only when no activity lifecycle is current.
    @discardableResult
    func markFailed(
        completedTiles: Int,
        totalTiles: Int,
        message: String,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool
}

public extension LiveActivityControlling {
    func updateProgress(
        stageTitle: String,
        completedTiles: Int,
        totalTiles: Int,
        progressFraction: Double,
        estimatedSecondsRemaining: Int?
    ) async {
        await updateProgress(
            stageTitle: stageTitle,
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            progressFraction: progressFraction,
            estimatedSecondsRemaining: estimatedSecondsRemaining,
            forceImmediate: false
        )
    }

    func endActivity(finalMessage: String) async {
        await endActivity(finalMessage: finalMessage, dismissPolicySeconds: 4.0)
    }

    // Defaults keep simple doubles source-compatible. The production controller and the
    // integration-test double implement real identity gating.
    var activityLifecycleIdentity: UInt64? { nil }

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
        _ = requestIdentity
        startActivity(
            jobID: jobID,
            sourceFileName: sourceFileName,
            scaleFactor: scaleFactor,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            totalTiles: totalTiles
        )
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
        _ = expectedIdentity
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
        _ = expectedIdentity
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
        _ = expectedIdentity
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
        _ = expectedIdentity
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
        _ = expectedIdentity
        await markFailed(
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            message: message
        )
        return true
    }
}

/// Manages the Dynamic Island & Lock Screen Live Activity (`Activity<UpscaleActivityAttributes>`).
///
/// Race safety: every start/end advances a monotonic generation. A delayed `end()` detaches its
/// handle and generation *before* awaiting ActivityKit, so it can never clear an activity started
/// while it was suspended; an `update` only ever targets the handle current when the call began.
///
/// Specification: `docs/DEVELOPMENT.md`.
@MainActor
public final class LiveActivityController: LiveActivityControlling {
    private static var didCleanUpAfterColdLaunch = false

    /// The app currently restores its library, not an in-flight processing descriptor, after a
    /// process restart. End only the typed activities captured at cold launch so a killed run
    /// cannot leave a frozen Island competing with the next job. New activities are never queried
    /// or touched after the asynchronous end begins.
    public static func endOrphanedActivitiesAfterColdLaunch() {
        guard !didCleanUpAfterColdLaunch else { return }
        didCleanUpAfterColdLaunch = true
        #if canImport(ActivityKit) && os(iOS)
        let previous = Activity<UpscaleActivityAttributes>.activities
        for activity in previous {
            var final = activity.content.state
            final.phase = .cancelled
            final.isPaused = false
            final.stageTitle = "Previous session ended"
            final.statusMessage = "Open TruongScaler to start another run."
            final.startedAt = nil
            let handle = LiveActivityHandle(activity)
            Task { await handle.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate) }
        }
        if !previous.isEmpty {
            Diagnostics.shared.record(category: .background, level: .notice,
                code: "activity.orphans.ended", message: "ended activities from a previous process",
                fields: ["count": "\(previous.count)"])
        }
        #endif
    }

    public private(set) var lastKnownState: UpscaleActivityAttributes.ContentState?
    private var lastUpdateTimestamp: ContinuousClock.Instant?
    private var activityStartedAt: Date?
    private let minimumUpdateInterval: Duration = .milliseconds(450)

    /// Number of progress pushes that were not dropped by the 450 ms throttle. Internal so the
    /// macOS unit tests can verify throttling without ActivityKit.
    private(set) var deliveredUpdateCount: Int = 0
    /// Number of non-terminal updates suppressed by the throttle.
    private(set) var throttledUpdateCount: Int = 0

    /// Monotonic identity of the newest activity start. Public for diagnostics/tests.
    public private(set) var activityGeneration: UInt64 = 0
    /// Generation of the activity that most recently finished (ended or replaced).
    public private(set) var endedGeneration: UInt64?

    /// Generation of the activity currently representing the running job, or `nil` between jobs.
    public private(set) var currentActivityGeneration: UInt64?

    /// Identity of the activity lifecycle currently published by this controller. Every start
    /// publishes a new identity and every terminal mutation clears it. Callers capture this value
    /// before an `await` and pass it to the identity-aware mutators so a delayed call cannot publish
    /// into a newer activity.
    public private(set) var activityLifecycleIdentity: UInt64?

    /// Highest activity start request accepted by `startActivity(...ifNewerThanRequestIdentity:)`.
    /// It gives the coordinator a way to make a delayed start a no-op instead of replacing a newer
    /// activity that was published while the start was suspended.
    private var latestStartRequestIdentity: UInt64 = 0

    /// Test seam: awaited after the outgoing handle/generation is detached and before its async
    /// end completes, so a test can start a replacement activity during a delayed `end()`.
    var endSuspensionHook: (@Sendable () async -> Void)?

    #if canImport(ActivityKit) && os(iOS)
    private struct Handle {
        let generation: UInt64
        let activity: LiveActivityHandle
    }

    private var currentHandle: Handle?
    #endif

    public enum PresentationMode: Sendable, Equatable {
        case customActivity
        /// BGContinuedProcessingTask provides its own system Live Activity and Stop control.
        /// Keep lifecycle state for the coordinator without creating a second ActivityKit card.
        case systemContinuation
    }
    public let presentationMode: PresentationMode

    public init(presentationMode: PresentationMode = .customActivity) {
        self.presentationMode = presentationMode
    }

    // MARK: - Start

    /// Starts a new Live Activity when a real job begins. Any activity left over from the previous
    /// job is detached and ended; it can never clear the new handle.
    public func startActivity(
        jobID: UUID,
        sourceFileName: String,
        scaleFactor: ScaleFactor,
        targetWidth: Int,
        targetHeight: Int,
        totalTiles: Int
    ) {
        let previousState = lastKnownState
        activityStartedAt = Date()
        let initialState = UpscaleActivityAttributes.ContentState(
            stageTitle: "Preparing tiles…",
            completedTiles: 0,
            totalTiles: max(0, totalTiles),
            progressFraction: 0.0,
            estimatedSecondsRemaining: nil,
            phase: .running,
            startedAt: activityStartedAt
        )
        self.lastKnownState = initialState
        self.lastUpdateTimestamp = nil

        activityGeneration &+= 1
        let newGeneration = activityGeneration
        currentActivityGeneration = newGeneration
        activityLifecycleIdentity = newGeneration

        #if canImport(ActivityKit) && os(iOS)
        let staleHandle = currentHandle
        currentHandle = nil
        if let staleHandle {
            // Detached before the request below; its generation is already obsolete.
            let staleContent = ActivityContent(
                state: previousState ?? initialState,
                staleDate: nil
            )
            Task { await staleHandle.activity.end(staleContent, dismissalPolicy: .immediate) }
        }

        guard presentationMode == .customActivity,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let attributes = UpscaleActivityAttributes(
            jobID: jobID.uuidString,
            sourceFileName: sourceFileName,
            scaleFactorLabel: "\(scaleFactor.rawValue)×",
            targetResolutionLabel: "\(targetWidth) × \(targetHeight)"
        )
        do {
            let activity = try Activity<UpscaleActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil),
                pushType: nil
            )
            // `request` is synchronous, so no newer start can have intervened; keep the guard for
            // future async request APIs and defensiveness.
            guard newGeneration == activityGeneration else {
                Task {
                    await LiveActivityHandle(activity).end(
                        ActivityContent(state: initialState, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                }
                return
            }
            currentHandle = Handle(generation: newGeneration, activity: LiveActivityHandle(activity))
        } catch {
            currentHandle = nil
        }
        #else
        _ = jobID
        _ = sourceFileName
        _ = scaleFactor
        _ = targetWidth
        _ = targetHeight
        #endif
    }

    /// Identity-gated start. A delayed start whose request identity is older than an already
    /// accepted start is ignored; the newer activity stays authoritative.
    @discardableResult
    public func startActivity(
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
        // The coordinator's monotonic lifecycle identity replaces the controller-local generation
        // so every later mutation can be gated against the job that requested this activity.
        activityLifecycleIdentity = requestIdentity
        return true
    }

    // MARK: - Updates

    /// Updates Live Activity progress. Automatically throttles non-terminal updates to <= ~2.2 Hz.
    public func updateProgress(
        stageTitle: String,
        completedTiles: Int,
        totalTiles: Int,
        progressFraction: Double,
        estimatedSecondsRemaining: Int?,
        forceImmediate: Bool = false
    ) async {
        let clampedTotal = max(0, totalTiles)
        let clampedCompleted = min(max(0, completedTiles), clampedTotal)
        let clampedFraction = progressFraction.isFinite ? min(max(progressFraction, 0.0), 1.0) : 0.0
        let state = UpscaleActivityAttributes.ContentState(
            stageTitle: stageTitle,
            completedTiles: clampedCompleted,
            totalTiles: clampedTotal,
            progressFraction: clampedFraction,
            estimatedSecondsRemaining: estimatedSecondsRemaining,
            phase: .running,
            startedAt: activityStartedAt
        )
        // `lastKnownState` is the source of truth for the in-app UI and is never throttled.
        self.lastKnownState = state

        let now = ContinuousClock.now
        let isTerminal = clampedFraction >= 1.0
        let elapsed: Bool
        if let lastUpdateTimestamp {
            elapsed = (now - lastUpdateTimestamp) >= minimumUpdateInterval
        } else {
            elapsed = true
        }

        guard forceImmediate || isTerminal || elapsed else {
            self.throttledUpdateCount += 1
            return
        }

        self.lastUpdateTimestamp = now
        self.deliveredUpdateCount += 1
        await push(state: state)
    }

    /// Updates the Live Activity to "Paused at X% — Tap to finish" when background time expires.
    /// The activity is kept alive so the user can tap it to resume.
    public func markPaused(completedTiles: Int, totalTiles: Int) async {
        let clampedTotal = max(0, totalTiles)
        let clampedCompleted = min(max(0, completedTiles), clampedTotal)
        let fraction = clampedTotal > 0
            ? min(1.0, Double(clampedCompleted) / Double(clampedTotal))
            : 0.0
        let percentage = clampedTotal > 0
            ? Int((Double(clampedCompleted) / Double(clampedTotal) * 100.0).rounded())
            : 0
        let message = "Paused at \(percentage)% — Tap to finish"
        let state = UpscaleActivityAttributes.ContentState(
            stageTitle: message,
            completedTiles: clampedCompleted,
            totalTiles: clampedTotal,
            progressFraction: fraction,
            estimatedSecondsRemaining: nil,
            isPaused: true,
            statusMessage: message,
            phase: .paused
        )
        self.lastKnownState = state
        self.lastUpdateTimestamp = ContinuousClock.now
        self.deliveredUpdateCount += 1
        await push(state: state)
    }

    /// Terminal success: progress reaches 100 %, phase `.completed`, activity dismissed.
    public func markCompleted(completedTiles: Int, totalTiles: Int, finalMessage: String) async {
        let total = max(0, totalTiles)
        let completed = total
        let state = UpscaleActivityAttributes.ContentState(
            stageTitle: finalMessage,
            completedTiles: completed,
            totalTiles: total,
            progressFraction: 1.0,
            estimatedSecondsRemaining: 0,
            statusMessage: finalMessage,
            phase: .completed
        )
        await finish(state: state, dismissPolicySeconds: 4.0)
    }

    /// Terminal cancellation (user Stop): distinct `.cancelled` phase; activity dismissed.
    public func markCancelled(completedTiles: Int, totalTiles: Int, message: String) async {
        let clampedTotal = max(0, totalTiles)
        let clampedCompleted = min(max(0, completedTiles), clampedTotal)
        let fraction = clampedTotal > 0
            ? min(1.0, Double(clampedCompleted) / Double(clampedTotal))
            : 0.0
        let state = UpscaleActivityAttributes.ContentState(
            stageTitle: message,
            completedTiles: clampedCompleted,
            totalTiles: clampedTotal,
            progressFraction: fraction,
            estimatedSecondsRemaining: nil,
            statusMessage: message,
            phase: .cancelled
        )
        await finish(state: state, dismissPolicySeconds: 8.0)
    }

    /// Terminal failure: distinct `.failed` phase; activity dismissed.
    public func markFailed(completedTiles: Int, totalTiles: Int, message: String) async {
        let clampedTotal = max(0, totalTiles)
        let clampedCompleted = min(max(0, completedTiles), clampedTotal)
        let fraction = clampedTotal > 0
            ? min(1.0, Double(clampedCompleted) / Double(clampedTotal))
            : 0.0
        let state = UpscaleActivityAttributes.ContentState(
            stageTitle: message,
            completedTiles: clampedCompleted,
            totalTiles: clampedTotal,
            progressFraction: fraction,
            estimatedSecondsRemaining: nil,
            statusMessage: message,
            phase: .failed
        )
        await finish(state: state, dismissPolicySeconds: 8.0)
    }

    /// Ends the Live Activity upon job completion or cancellation.
    public func endActivity(
        finalMessage: String,
        dismissPolicySeconds: TimeInterval = 4.0
    ) async {
        let previous = lastKnownState
        let finalState = UpscaleActivityAttributes.ContentState(
            stageTitle: finalMessage,
            completedTiles: previous?.completedTiles ?? 0,
            totalTiles: previous?.totalTiles ?? 0,
            progressFraction: previous?.progressFraction ?? 1.0,
            estimatedSecondsRemaining: 0,
            statusMessage: finalMessage,
            phase: .completed
        )
        await finish(state: finalState, dismissPolicySeconds: dismissPolicySeconds)
    }

    // MARK: - Identity-aware mutations

    @discardableResult
    public func updateProgress(
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
    public func markPaused(
        completedTiles: Int,
        totalTiles: Int,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool {
        guard activityLifecycleIdentity == expectedIdentity else { return false }
        await markPaused(completedTiles: completedTiles, totalTiles: totalTiles)
        return true
    }

    @discardableResult
    public func markCompleted(
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
    public func markCancelled(
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
    public func markFailed(
        completedTiles: Int,
        totalTiles: Int,
        message: String,
        ifActivityIdentity expectedIdentity: UInt64?
    ) async -> Bool {
        guard activityLifecycleIdentity == expectedIdentity else { return false }
        await markFailed(
            completedTiles: completedTiles,
            totalTiles: totalTiles,
            message: message
        )
        return true
    }

    // MARK: - Termination

    private func finish(
        state: UpscaleActivityAttributes.ContentState,
        dismissPolicySeconds: TimeInterval
    ) async {
        self.lastKnownState = state
        self.lastUpdateTimestamp = ContinuousClock.now
        self.deliveredUpdateCount += 1

        // Detach synchronously: a replacement activity started during the awaited end below has a
        // newer generation and can never be cleared by this call.
        let finishedGeneration = currentActivityGeneration
        currentActivityGeneration = nil
        activityLifecycleIdentity = nil
        activityGeneration &+= 1
        endedGeneration = finishedGeneration

        #if canImport(ActivityKit) && os(iOS)
        let handle = currentHandle
        currentHandle = nil
        #endif

        if let hook = endSuspensionHook {
            await hook()
        }

        #if canImport(ActivityKit) && os(iOS)
        guard let handle else { return }
        let dismissalPolicy: ActivityUIDismissalPolicy
        if dismissPolicySeconds > 0 {
            dismissalPolicy = .after(Date().addingTimeInterval(dismissPolicySeconds))
        } else {
            dismissalPolicy = .default
        }
        await handle.activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: dismissalPolicy
        )
        #else
        _ = dismissPolicySeconds
        #endif
    }

    // MARK: - ActivityKit Bridge

    private func push(state: UpscaleActivityAttributes.ContentState) async {
        #if canImport(ActivityKit) && os(iOS)
        guard let handle = currentHandle, handle.generation == currentActivityGeneration else { return }
        await handle.activity.update(ActivityContent(state: state, staleDate: nil))
        #else
        _ = state
        #endif
    }
}

#if canImport(ActivityKit) && os(iOS)
/// ActivityKit's iOS 27 interface has not declared Activity Sendable. Keep the immutable framework
/// reference behind a narrow bridge instead of sending MainActor-owned mutable state to its async
/// API. This handle exposes only ActivityKit's asynchronous update/end operations and never mutates
/// or exposes the reference; controller lifecycle state remains isolated to MainActor.
private final class LiveActivityHandle: @unchecked Sendable {
    private let activity: Activity<UpscaleActivityAttributes>

    init(_ activity: Activity<UpscaleActivityAttributes>) {
        self.activity = activity
    }

    func update(_ content: ActivityContent<UpscaleActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(
        _ content: ActivityContent<UpscaleActivityAttributes.ContentState>,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
}
#endif
