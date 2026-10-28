import Foundation

/// Adapted directly from `TruongCam shared BlockingIOOwner design`.
/// Runs synchronous file/disk work on a dedicated serial DispatchQueue off the Swift concurrency cooperative pool.
public final class BlockingIOOwner: Sendable {
    private let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        self.queue = DispatchQueue(label: label, qos: qos)
    }

    public func run<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func runInfallible<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
