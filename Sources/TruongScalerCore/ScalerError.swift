import Foundation

/// Exhaustive domain error enum for TruongScaler & TruongNoiser (`docs/DEVELOPMENT.md` Section 4.1).
public enum ScalerError: Error, LocalizedError, Sendable, Equatable {
    case fileNotFound(URL)
    case unsupportedImageFormat(String)
    case imageSourceCreationFailed(URL)
    case metadataExtractionFailed
    /// The host returned the SDR base instead of applying a source's HDR gain map.
    case hdrGainMapExpansionUnavailable
    case invalidImageDimensions(width: Int, height: Int)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case mmapAllocationFailed(errno: Int32, requestedBytes: Int)
    case mmapSyncFailed(errno: Int32)
    case stripDecodingFailed(stripIndex: Int, rectDescription: String)
    case metalDeviceUnavailable
    case metalShaderCompilationFailed(String)
    case metalExecutionFailed(String)
    case modelNotFound(modelName: String)
    case modelInferenceFailed(modelName: String, tileIndex: Int, reason: String)
    case checkpointCorrupted(URL)
    /// A legacy normalization migration cannot safely replace an already-migrated canonical canvas
    /// in place; the job must be restarted from its source rather than risk deleting authoritative data.
    case normalizationMigrationRequiresRestart(URL, reason: String)
    /// A job execution was submitted while the executor is registered to a different job lifecycle.
    case executionOwnerMismatch(submittedJobID: UUID, registeredJobID: UUID)
    case exportDestinationCreationFailed(URL)
    case dngWriteFailed(String)
    case jobCancelled
    case jobPausedForBackgroundExpiration(completedTileIndex: Int)
    /// The shared App Group container is unavailable on the production handoff path.
    case appGroupUnavailable(identifier: String)
    /// A requested export container cannot represent the completed image's dynamic range.
    case unsupportedFormatExport(format: String, reason: String)
    /// iOS refused to register, submit, or cancel a background processing task.
    case backgroundTaskSchedulingFailed(reason: String)
    /// A required production CoreML model is missing; no fallback may be substituted.
    case productionModelUnavailable(modelName: String, searchDirectories: [String])
    /// configured to) cannot be resumed without mixing two processing contracts across tiles. The
    /// checkpoint/output are left untouched; the caller must restart the job from its source.
    case srOnlyResumeOfLegacyDenoiseJob(completedTiles: Int, totalTiles: Int)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found at \(url.path)."
        case .unsupportedImageFormat(let fmt):
            return "Unsupported image format: \(fmt)."
        case .imageSourceCreationFailed(let url):
            return "Failed to create CGImageSource for \(url.lastPathComponent)."
        case .metadataExtractionFailed:
            return "Failed to extract image metadata properties."
        case .hdrGainMapExpansionUnavailable:
            return "This system could not expand this photo's HDR gain map. Open a 16-bit linear DNG or TIFF instead to preserve HDR. The source photo was left unchanged."
        case .invalidImageDimensions(let width, let height):
            return "Invalid image dimensions: \(width) × \(height)."
        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            return "Insufficient disk space: requires \(requiredBytes) bytes, available \(availableBytes) bytes."
        case .mmapAllocationFailed(let err, let requestedBytes):
            return "POSIX mmap allocation failed (errno \(err)) for \(requestedBytes) bytes."
        case .mmapSyncFailed(let err):
            return "POSIX msync failed (errno \(err))."
        case .stripDecodingFailed(let stripIndex, let rectDescription):
            return "Failed to decode strip #\(stripIndex) (\(rectDescription))."
        case .metalDeviceUnavailable:
            return "Metal GPU device is unavailable."
        case .metalShaderCompilationFailed(let reason):
            return "Metal shader compilation failed: \(reason)."
        case .metalExecutionFailed(let reason):
            return "Metal compute execution failed: \(reason)."
        case .modelNotFound(let modelName):
            return "CoreML model bundle '\(modelName)' was not found."
        case .modelInferenceFailed(let modelName, let tileIndex, let reason):
            return "Model '\(modelName)' failed on tile #\(tileIndex): \(reason)."
        case .checkpointCorrupted(let url):
            return "Checkpoint file is corrupted or unreadable: \(url.lastPathComponent)."
        case .normalizationMigrationRequiresRestart(let url, let reason):
            return "The job \(url.lastPathComponent) needs another normalization rebuild but already owns a migrated canvas. Restart this job from its source (remove its checkpoint and output) before retrying; refusing to overwrite authoritative pixels. \(reason)"
        case .executionOwnerMismatch(let submitted, let registered):
            return "Refused to execute job \(submitted.uuidString) because the executor is registered to a different job lifecycle (\(registered.uuidString)). Finish or cancel the current run before starting a different job; pause ownership is job-scoped."
        case .exportDestinationCreationFailed(let url):
            return "Failed to create or finalize export file at \(url.lastPathComponent)."
        case .dngWriteFailed(let reason):
            return "16-bit Linear DNG export failed: \(reason)."
        case .jobCancelled:
            return "Processing job was cancelled."
        case .jobPausedForBackgroundExpiration(let completedTileIndex):
            return "Processing paused cleanly at tile #\(completedTileIndex) due to background time expiration."
        case .appGroupUnavailable(let identifier):
            return "The shared App Group container '\(identifier)' is unavailable. Cross-app handoff requires the signed app's App Group entitlement and a valid container; no app-private fallback is used."
        case .unsupportedFormatExport(let format, let reason):
            return "\(format) cannot represent this image: \(reason)"
        case .backgroundTaskSchedulingFailed(let reason):
            return "Background processing could not be scheduled: \(reason)"
        case .productionModelUnavailable(let modelName, let searchDirectories):
            let paths = searchDirectories.isEmpty ? "(no search paths)" : searchDirectories.joined(separator: ", ")
            return "Required CoreML model '\(modelName)' is missing. Install the production model bundle in one of: \(paths). Deterministic fallback is disabled in the released app."
        case .srOnlyResumeOfLegacyDenoiseJob(let completed, let total):
            return "This saved job was created before TruongScaler became super-resolution only and already used the retired denoise stage (tile \(completed) of \(total)). It cannot be resumed without mixing denoised and non-denoised tiles. The checkpoint and existing output were left untouched; start a new SR-only job from the original photo. Denoising belongs to TruongNoiser."
        }
    }
}
