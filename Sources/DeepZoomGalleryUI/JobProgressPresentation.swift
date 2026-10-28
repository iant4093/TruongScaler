import Foundation
import TruongScalerCore
import TiledInferenceEngine

/// User-facing, truthful progress for one Scaler job.
///
/// The values come from real pipeline phases/tile commits; a long uncommitted tile is represented by
/// `currentTileNumber` plus the latest phase and a ticking elapsed time, never by a fake completed
/// count. `estimatedSecondsRemaining` is only populated after measured tile samples exist.
public struct JobProgressPresentation: Sendable, Equatable {
    public var batchPhotoNumber: Int?
    public var batchPhotoCount: Int?
    public var jobID: UUID?
    public var phase: PipelinePhase
    public var title: String
    public var detail: String
    public var completedTiles: Int
    public var totalTiles: Int
    public var currentTileNumber: Int?
    public var elapsedSeconds: Double
    public var tileLoopElapsedSeconds: Double?
    public var estimatedSecondsRemaining: Int?
    public var averageSecondsPerTile: Double?
    public var sourceWidth: Int?
    public var sourceHeight: Int?
    public var outputWidth: Int?
    public var outputHeight: Int?
    public var modelName: String?
    public var requestedCompute: String?
    public var tileSize: Int?
    public var tileOverlap: Int?
    public var gridColumns: Int?
    public var gridRows: Int?
    public var timings: PipelineTileTimings?
    public var didRunDenoise: Bool?
    public var isWaitingForForeground: Bool = false
    public var isSavingOutput: Bool = false
    public var isStopping: Bool

    public init(
        jobID: UUID? = nil,
        phase: PipelinePhase = .decodingSource,
        title: String = "Preparing…",
        detail: String = "",
        completedTiles: Int = 0,
        totalTiles: Int = 0,
        currentTileNumber: Int? = nil,
        elapsedSeconds: Double = 0,
        tileLoopElapsedSeconds: Double? = nil,
        estimatedSecondsRemaining: Int? = nil,
        averageSecondsPerTile: Double? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        modelName: String? = nil,
        requestedCompute: String? = nil,
        tileSize: Int? = nil,
        tileOverlap: Int? = nil,
        gridColumns: Int? = nil,
        gridRows: Int? = nil,
        timings: PipelineTileTimings? = nil,
        didRunDenoise: Bool? = nil,
        isStopping: Bool = false
    ) {
        self.jobID = jobID
        self.phase = phase
        self.title = title
        self.detail = detail
        self.completedTiles = completedTiles
        self.totalTiles = totalTiles
        self.currentTileNumber = currentTileNumber
        self.elapsedSeconds = elapsedSeconds
        self.tileLoopElapsedSeconds = tileLoopElapsedSeconds
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.averageSecondsPerTile = averageSecondsPerTile
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.modelName = modelName
        self.requestedCompute = requestedCompute
        self.tileSize = tileSize
        self.tileOverlap = tileOverlap
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.timings = timings
        self.didRunDenoise = didRunDenoise
        self.isStopping = isStopping
    }

    /// `true` while the latest plan/index facts are usable. A preparing job has no `1 / 1`.
    public var hasTilePlan: Bool { !isWaitingForForeground && totalTiles > 0 }

    /// Stable compact chrome; per-tile phase changes belong to Details, not the bottom bar.
    public var compactTitle: String {
        if isStopping { return "Stopping…" }
        if isWaitingForForeground { return "Open app to continue" }
        if let batchPhotoNumber, let batchPhotoCount, batchPhotoCount > 1 { return "Processing \(batchPhotoNumber)/\(batchPhotoCount)" }
        if isSavingOutput { return "Saving photo…" }
        switch phase {
        case .completed: return "Complete"
        case .paused: return "Paused"
        case .failed: return "Unable to finish"
        default: return "Upscaling photo"
        }
    }

    public var compactFraction: Double {
        guard hasTilePlan else { return 0 }
        return Double(min(max(completedTiles, 0), totalTiles)) / Double(totalTiles)
    }

    public var compactPercentText: String {
        hasTilePlan ? "\(Int((compactFraction * 100).rounded(.down)))%" : ""
    }

    public var currentTileDisplayNumber: Int? {
        guard let currentTileNumber else { return nil }
        return currentTileNumber + 1
    }

    public var compactSubtitle: String {
        if isWaitingForForeground {
            if let batchPhotoNumber, let batchPhotoCount { return "Photo \(batchPhotoNumber) of \(batchPhotoCount) is queued" }
            return "Batch waiting"
        }
        return hasTilePlan ? "\(completedTiles) / \(totalTiles) tiles" : "Preparing photo"
    }

    public var remainingText: String {
        if isWaitingForForeground { return "Waiting for app" }
        if isSavingOutput { return "Finishing…" }
        return estimatedSecondsRemaining.map { "About " + Self.format(seconds: Double($0)) } ?? "Estimating…"
    }

    public var processTitle: String {
        if isStopping { return "Stopping" }
        if isWaitingForForeground { return "Waiting for app" }
        if isSavingOutput { return "Saving photo" }
        switch phase {
        case .decodingSource: return "Opening photo"
        case .preparingModels: return "Preparing"
        case .finalizing: return "Saving photo"
        case .paused: return "Paused"
        case .completed: return "Complete"
        case .failed: return "Unable to finish"
        default: return "Upscaling"
        }
    }

    public static func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    /// Builds a presentation from the latest real update + the view model's ticking elapsed clock.
    public static func make(
        update: PipelineProgressUpdate?,
        elapsedSeconds: Double,
        isStopping: Bool
    ) -> JobProgressPresentation {
        guard let update else {
            return JobProgressPresentation(
                phase: .decodingSource,
                title: isStopping ? "Stopping…" : "Preparing…",
                detail: "Reading the source and preparing the work plan.",
                elapsedSeconds: elapsedSeconds,
                isStopping: isStopping
            )
        }
        let total = update.totalTiles
        let completed = max(0, min(update.completedTiles, total == 0 ? 0 : total))
        let currentDisplay = update.currentTileIndex.map { $0 + 1 }
        let tileCount = total > 0 ? "tile \(currentDisplay ?? min(completed + 1, total)) of \(total)" : ""
        let title: String
        let detail: String
        switch update.phase {
        case .decodingSource:
            title = "Reading source"
            detail = "Decoding and mapping the full-resolution image."
        case .preparingModels:
            title = "Preparing model"
            detail = "Planning tiles and preparing the super-resolution model."
        case .extractingTile, .predictingSuperResolution, .verifyingSuperResolution,
             .reconstructingTile, .blendingTile, .committingTile, .tileCommitted:
            title = total > 0 ? "Upscaling \(tileCount)" : "Upscaling"
            detail = "Super-resolution"
        case .finalizing:
            title = "Saving result"
            detail = "Flushing the output canvas and releasing model memory."
        case .paused:
            title = "Paused"
            detail = "Stopped at a durable tile boundary."
        case .completed:
            title = "Complete"
            detail = "Result is ready to inspect."
        case .failed:
            title = "Failed"
            detail = "Processing failed."
        }
        var presentation = JobProgressPresentation(
            jobID: update.jobID,
            phase: update.phase,
            title: isStopping ? "Stopping…" : title,
            detail: isStopping ? "Finishing the current durable boundary before stopping." : detail,
            completedTiles: completed,
            totalTiles: total,
            currentTileNumber: update.currentTileIndex,
            // A phase/tile snapshot can remain unchanged during a long Core ML call. Keep the
            // app's live clock advancing instead of freezing at that snapshot's timestamp.
            elapsedSeconds: max(update.elapsedSeconds ?? 0, elapsedSeconds),
            tileLoopElapsedSeconds: update.tileLoopElapsedSeconds,
            estimatedSecondsRemaining: update.estimatedSecondsRemaining,
            averageSecondsPerTile: update.averageSecondsPerTile,
            sourceWidth: update.sourceWidth,
            sourceHeight: update.sourceHeight,
            outputWidth: update.outputWidth,
            outputHeight: update.outputHeight,
            modelName: update.modelName,
            requestedCompute: update.requestedCompute,
            tileSize: update.tileSize,
            tileOverlap: update.tileOverlap,
            gridColumns: update.gridColumns,
            gridRows: update.gridRows,
            timings: update.timings,
            didRunDenoise: update.didRunDenoise,
            isStopping: isStopping
        )
        if presentation.elapsedSeconds < elapsedSeconds {
            presentation.elapsedSeconds = elapsedSeconds
        }
        return presentation
    }
}
