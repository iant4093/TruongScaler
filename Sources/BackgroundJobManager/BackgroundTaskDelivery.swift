import Foundation
import TruongScalerCore
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// MARK: - Delivered task abstraction

/// A delivered continued-processing task, ready to be handed to `BackgroundExecutionCoordinator`.
///
/// `rawTask` is the framework object returned by `BGTaskScheduler` (retained by
/// `BackgroundTaskDeliveryRouter` until the coordinator completes it). The typed adapter is
/// `nil` on platforms without BackgroundTasks, which lets the router and coordinator compile
/// and be unit-tested on macOS.
public struct BackgroundTaskDelivery: @unchecked Sendable {
    public let rawTask: AnyObject
    public let continuedProcessingTask: (any ContinuedProcessingTaskAdapter)?

    public init(
        rawTask: AnyObject,
        continuedProcessingTask: (any ContinuedProcessingTaskAdapter)?
    ) {
        self.rawTask = rawTask
        self.continuedProcessingTask = continuedProcessingTask
    }
}

/// The subset of `BGTask`/`BGContinuedProcessingTask` used by the coordinator. Keeping it behind a
/// protocol lets macOS tests inject a deterministic task instead of requiring iOS services.
public protocol ContinuedProcessingTaskAdapter: AnyObject, Sendable {
    var identifier: String { get }
    /// Installs the system expiration handler. Called at most once per delivery.
    func installExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    /// Reports real pipeline progress through `NSProgressReporting`.
    func setProgress(completedUnitCount: Int64, totalUnitCount: Int64)
    func setStatus(title: String, subtitle: String)
    /// Terminal signal to the scheduler. Callers must invoke this exactly once.
    func setTaskCompleted(success: Bool)
}

public extension ContinuedProcessingTaskAdapter {
    func setStatus(title: String, subtitle: String) {}
}

// MARK: - Thread-safe delivery router

/// Thread-safe bridge between the `BGTaskScheduler` registration callback (arbitrary background
/// queue) and the coordinator owned by `StudioViewModel` (actor + MainActor).
///
/// * Every delivered task is retained until the coordinator reports it complete.
/// * A task delivered before the coordinator installs its handler is queued, then flushed on
///   installation. Continued-processing registrations are exempt from the before-launch rule
///   (`BGTaskScheduler.h`), so a launch-time installation and later delivery are both valid.
public final class BackgroundTaskDeliveryRouter: @unchecked Sendable {
    public typealias DeliveryHandler = @Sendable (BackgroundTaskDelivery) -> Void

    /// The process-wide router used by the SwiftUI app entry point and its view model. Tests use
    /// dedicated instances so they never observe app state.
    public static let shared = BackgroundTaskDeliveryRouter()

    private let lock = NSLock()
    private var handler: DeliveryHandler?
    private var pendingDeliveries: [BackgroundTaskDelivery] = []
    private var retainedTasks: [ObjectIdentifier: AnyObject] = [:]
    private var totalDelivered = 0

    public init() {}

    /// Installs (or replaces) the delivery handler and flushes queued deliveries.
    ///
    /// The flush happens outside the lock so a handler may re-enter the router.
    public func installHandler(_ handler: @escaping DeliveryHandler) {
        lock.lock()
        self.handler = handler
        let queued = pendingDeliveries
        pendingDeliveries.removeAll()
        lock.unlock()

        for delivery in queued {
            handler(delivery)
        }
    }

    public func removeHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    /// Called from the `BGTaskScheduler` registration callback. Retains the task and forwards it,
    /// or queues it until a handler exists.
    public func deliver(_ delivery: BackgroundTaskDelivery) {
        lock.lock()
        totalDelivered += 1
        retainedTasks[ObjectIdentifier(delivery.rawTask)] = delivery.rawTask
        let currentHandler = handler
        if currentHandler == nil {
            pendingDeliveries.append(delivery)
        }
        lock.unlock()

        currentHandler?(delivery)
    }

    /// Releases the retention for a task after `setTaskCompleted` has been called.
    public func release(_ rawTask: AnyObject) {
        lock.lock()
        retainedTasks.removeValue(forKey: ObjectIdentifier(rawTask))
        lock.unlock()
    }

    // MARK: Diagnostics (also used by tests)

    public var retainedTaskCount: Int {
        lock.lock(); defer { lock.unlock() }
        return retainedTasks.count
    }

    public var pendingDeliveryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingDeliveries.count
    }

    public var deliveredTaskCount: Int {
        lock.lock(); defer { lock.unlock() }
        return totalDelivered
    }
}

// MARK: - Scheduler abstraction

/// A submitted continued-processing request (identifier is the concrete, job-scoped identifier).
public struct ContinuedProcessingRequestDescriptor: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let subtitle: String

    public init(identifier: String, title: String, subtitle: String) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
    }
}

/// Scheduling seam so the coordinator can be exercised without iOS `BGTaskScheduler`.
public protocol BackgroundTaskScheduling: Sendable {
    /// Registers the launch handler for an identifier pattern.
    /// Throws `ScalerError.backgroundTaskSchedulingFailed` if the scheduler refuses it.
    func registerContinuedProcessing(
        identifier: String,
        launchHandler: @escaping @Sendable (AnyObject) -> Void
    ) throws
    /// Submits a continued-processing request. Throws `ScalerError.backgroundTaskSchedulingFailed`.
    func submitContinuedProcessing(_ descriptor: ContinuedProcessingRequestDescriptor) async throws
    /// Cancels a previously submitted (concrete) identifier.
    func cancelContinuedProcessing(identifier: String)
}

/// macOS / non-iOS scheduler: BackgroundTasks is unavailable, so scheduling is refused visibly.
public struct UnavailableBackgroundTaskScheduler: BackgroundTaskScheduling {
    public init() {}

    public func registerContinuedProcessing(
        identifier: String,
        launchHandler: @escaping @Sendable (AnyObject) -> Void
    ) throws {
        throw ScalerError.backgroundTaskSchedulingFailed(
            reason: "BackgroundTasks is unavailable on this platform; identifier '\(identifier)' cannot be registered."
        )
    }

    public func submitContinuedProcessing(_ descriptor: ContinuedProcessingRequestDescriptor) async throws {
        throw ScalerError.backgroundTaskSchedulingFailed(
            reason: "BackgroundTasks is unavailable on this platform; identifier '\(descriptor.identifier)' cannot be submitted."
        )
    }

    public func cancelContinuedProcessing(identifier: String) {}
}

#if canImport(BackgroundTasks) && os(iOS)
/// Real `BGTaskScheduler` adapter.
///
/// Identifier rules from the installed iOS 27 `BGTaskRequest.h`:
/// * `BGTaskSchedulerPermittedIdentifiers` advertises the wildcard family
///   `<MainBundleID>.<SemanticContext>.*`.
/// * Registration and each submitted request use the same concrete suffix appended to that prefix
///   (the job UUID here); registering the literal wildcard itself is rejected.
/// * `requiredResources = []` (the SDK's default resource set; `.default` is unavailable for the
///   OptionSet): no background GPU entitlement is requested or claimed.
public struct BGTaskSchedulerAdapter: BackgroundTaskScheduling {
    public init() {}

    public func registerContinuedProcessing(
        identifier: String,
        launchHandler: @escaping @Sendable (AnyObject) -> Void
    ) throws {
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            launchHandler(task)
        }
        guard accepted else {
            throw ScalerError.backgroundTaskSchedulingFailed(
                reason: "BGTaskScheduler refused to register the concrete identifier '\(identifier)'. "
                    + "Its wildcard family must be advertised in BGTaskSchedulerPermittedIdentifiers; "
                    + "continued-processing handlers are registered per concrete job identifier, not as "
                    + "the literal wildcard."
            )
        }
    }

    /// Turns the framework error into an actionable, nonfatal explanation. Simulator and physical
    /// device conditions differ; this never claims background execution works.
    private func describeSchedulingFailure(_ error: Error) -> String {
        let nsError = error as NSError
        let hint: String
        if nsError.domain == BGTaskScheduler.errorDomain {
            switch nsError.code {
            case 1:
                hint = "Background processing is unavailable on this platform/Simulator, or background refresh is disabled."
            case 2:
                hint = "Too many pending background task requests are already scheduled."
            case 3:
                hint = "The request is not permitted. Check BGTaskSchedulerPermittedIdentifiers, the required Background Modes, and the requested resources."
            case 4:
                hint = "The system could not begin the continued processing task immediately."
            default:
                hint = "The background scheduler reported error code \(nsError.code)."
            }
        } else {
            hint = nsError.localizedDescription
        }
        return hint
    }

    public func submitContinuedProcessing(_ descriptor: ContinuedProcessingRequestDescriptor) async throws {
        guard #available(iOS 26.0, *) else {
            throw ScalerError.backgroundTaskSchedulingFailed(
                reason: "BGContinuedProcessingTaskRequest requires iOS 26 or newer."
            )
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: descriptor.identifier,
            title: descriptor.title,
            subtitle: descriptor.subtitle
        )
        request.strategy = .queue
        // Background GPU is deliberately not requested: no such entitlement exists in this app.
        // `Resources` is an NS_OPTIONS OptionSet whose zero value is spelled `[]` in Swift; the
        // SDK marks the `.default` spelling unavailable. `[]` is the documented default resource set.
        request.requiredResources = []

        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
        } catch {
            let nsError = error as NSError
            throw ScalerError.backgroundTaskSchedulingFailed(
                reason: "BGTaskScheduler rejected '\(descriptor.identifier)': "
                    + "\(describeSchedulingFailure(error)) (\(nsError.domain) \(nsError.code))"
            )
        }
    }

    public func cancelContinuedProcessing(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Wraps the framework task returned by the registration callback.
///
/// `BGContinuedProcessingTask` reports progress through `NSProgressReporting`; `BGTask` is not
/// declared `Sendable`, so the adapter owns the only mutable reference and keeps its state
/// isolated behind the adapter protocol.
public final class BGContinuedProcessingTaskAdapter: ContinuedProcessingTaskAdapter, @unchecked Sendable {
    private let task: BGTask

    public init(task: BGTask) {
        self.task = task
    }

    public var identifier: String { task.identifier }

    public func installExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    public func setProgress(completedUnitCount: Int64, totalUnitCount: Int64) {
        guard let continuedTask = task as? BGContinuedProcessingTask else { return }
        let total = max(1, totalUnitCount)
        let completed = min(max(0, completedUnitCount), total)
        continuedTask.progress.totalUnitCount = total
        continuedTask.progress.completedUnitCount = completed
    }

    public func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }

    public func setStatus(title: String, subtitle: String) {
        (task as? BGContinuedProcessingTask)?.updateTitle(title, subtitle: subtitle)
    }
}

/// Builds a typed delivery from the scheduler's raw task.
public enum ContinuedProcessingTaskAdapterFactory {
    public static func makeDelivery(for task: AnyObject) -> BackgroundTaskDelivery {
        guard let bgTask = task as? BGTask else {
            return BackgroundTaskDelivery(rawTask: task, continuedProcessingTask: nil)
        }
        return BackgroundTaskDelivery(
            rawTask: task,
            continuedProcessingTask: BGContinuedProcessingTaskAdapter(task: bgTask)
        )
    }
}
#endif

// MARK: - Legacy background assertion abstraction

/// Balances `UIApplication.beginBackgroundTask`/`endBackgroundTask` so tests can verify the
/// assertion lifecycle without UIKit.
public protocol LegacyBackgroundAssertionProviding: Sendable {
    /// Starts an assertion and returns an identity token, or `nil` when the platform has no UIKit.
    func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UUID?
    func endBackgroundTask(token: UUID) async
}

/// No-op provider for platforms without UIKit.
public struct NoLegacyBackgroundAssertionProvider: LegacyBackgroundAssertionProviding {
    public init() {}

    public func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UUID? {
        _ = name
        _ = expirationHandler
        return nil
    }

    public func endBackgroundTask(token: UUID) async {}
}

/// Platform defaults.
public enum BackgroundTaskPlatform {
    public static func makeDefaultScheduler() -> any BackgroundTaskScheduling {
        #if canImport(BackgroundTasks) && os(iOS)
        return BGTaskSchedulerAdapter()
        #else
        return UnavailableBackgroundTaskScheduler()
        #endif
    }

    public static func makeDefaultLegacyAssertionProvider() -> any LegacyBackgroundAssertionProviding {
        #if canImport(UIKit) && os(iOS)
        return UIKitLegacyBackgroundAssertionProvider()
        #else
        return NoLegacyBackgroundAssertionProvider()
        #endif
    }
}

#if canImport(UIKit) && os(iOS)
/// UIKit-backed legacy assertion. UUID tokens map to `UIBackgroundTaskIdentifier` so the system
/// identifier never crosses an isolation boundary directly.
public struct UIKitLegacyBackgroundAssertionProvider: LegacyBackgroundAssertionProviding {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var identifiers: [UUID: UIBackgroundTaskIdentifier] = [:]

        func set(_ identifier: UIBackgroundTaskIdentifier, for token: UUID) {
            lock.lock()
            identifiers[token] = identifier
            lock.unlock()
        }

        func take(_ token: UUID) -> UIBackgroundTaskIdentifier? {
            lock.lock()
            defer { lock.unlock() }
            return identifiers.removeValue(forKey: token)
        }
    }

    private final class IdentifierBox: @unchecked Sendable {
        var identifier: UIBackgroundTaskIdentifier = .invalid
    }

    private let store = Store()

    public init() {}

    public func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UUID? {
        let token = UUID()
        let box = IdentifierBox()
        await MainActor.run {
            box.identifier = UIApplication.shared.beginBackgroundTask(
                withName: name,
                expirationHandler: expirationHandler
            )
        }
        guard box.identifier != .invalid else { return nil }
        store.set(box.identifier, for: token)
        return token
    }

    public func endBackgroundTask(token: UUID) async {
        guard let identifier = store.take(token) else { return }
        let box = IdentifierBox()
        box.identifier = identifier
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(box.identifier)
        }
    }
}
#endif
