import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Dynamic Island & Lock Screen Live Activity attributes (`docs/DEVELOPMENT.md` Section 4.6).
public struct UpscaleActivityAttributes: Codable, Sendable, Equatable {
    /// Explicit lifecycle phase so the widget can distinguish success, cancellation, failure and
    /// a resumable pause instead of inferring them from a message string.
    public enum ActivityPhase: String, Codable, Sendable, Equatable {
        case running
        case paused
        case completed
        case cancelled
        case failed
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var stageTitle: String
        public var completedTiles: Int
        public var totalTiles: Int
        public var progressFraction: Double
        public var estimatedSecondsRemaining: Int?
        public var isPaused: Bool
        public var statusMessage: String?
        public var phase: ActivityPhase
        /// Lets WidgetKit advance elapsed time locally during a long uncommitted tile. Optional
        /// for compatibility with activities created by an earlier installed build.
        public var startedAt: Date?

        public init(
            stageTitle: String,
            completedTiles: Int,
            totalTiles: Int,
            progressFraction: Double,
            estimatedSecondsRemaining: Int?,
            isPaused: Bool = false,
            statusMessage: String? = nil,
            phase: ActivityPhase = .running,
            startedAt: Date? = nil
        ) {
            self.stageTitle = stageTitle
            self.completedTiles = completedTiles
            self.totalTiles = totalTiles
            self.progressFraction = progressFraction
            self.estimatedSecondsRemaining = estimatedSecondsRemaining
            self.isPaused = isPaused
            self.statusMessage = statusMessage
            self.phase = phase
            self.startedAt = startedAt
        }

        public var savedTileFraction: Double {
            if phase == .completed { return 1 }
            guard totalTiles > 0 else { return 0 }
            return Double(min(max(0, completedTiles), totalTiles)) / Double(totalTiles)
        }

        public var compactProgressText: String {
            totalTiles > 0 || phase == .completed ? "\(Int(savedTileFraction * 100))%" : "…"
        }

        public var remainingTimeText: String? {
            guard phase == .running, let seconds = estimatedSecondsRemaining, seconds > 0 else { return nil }
            if seconds >= 3600 { return "~\(seconds / 3600)h \((seconds % 3600) / 60)m left" }
            if seconds >= 60 { return "~\(seconds / 60)m left" }
            return "~\(seconds)s left"
        }

        public var isTerminal: Bool {
            switch phase {
            case .completed, .cancelled, .failed: return true
            case .running, .paused: return false
            }
        }
    }

    public var jobID: String
    public var sourceFileName: String
    public var scaleFactorLabel: String
    public var targetResolutionLabel: String

    public init(
        jobID: String,
        sourceFileName: String,
        scaleFactorLabel: String,
        targetResolutionLabel: String
    ) {
        self.jobID = jobID
        self.sourceFileName = sourceFileName
        self.scaleFactorLabel = scaleFactorLabel
        self.targetResolutionLabel = targetResolutionLabel
    }
}

#if canImport(ActivityKit) && os(iOS)
extension UpscaleActivityAttributes: ActivityAttributes {}
#endif
