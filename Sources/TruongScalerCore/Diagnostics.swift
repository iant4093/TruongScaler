import Foundation
import os

/// Structured, bounded, privacy-aware diagnostics for TruongScaler.
///
/// The app and the model pipeline emit sanitized events through `Diagnostics.shared`. Events go to:
/// * the unified logging system (`os.Logger`, subsystem `com.iantruong.truongscaler`), so Console.app
///   and `log collect` work on a normal phone build without a debugger or test hook;
/// * a bounded in-memory ring for structured runtime inspection and tests;
/// * a bounded asynchronous on-disk log with one rollover file.
///
/// Nothing here is required for processing to function: logging failures are swallowed, disabled
/// logging is a no-op, and no pixel buffers, photo contents, full paths, bookmarks, credentials or
/// filenames are recorded by design (see `sanitize` / `redactedFields`).
public struct DiagnosticEvent: Sendable, Equatable {
    public let sequence: UInt64
    public let timestamp: Date
    public let category: String
    public let level: DiagnosticLevel
    public let code: String
    public let message: String
    public let fields: [String: String]

    /// Stable one-line representation used by the in-app summary and the bounded disk log.
    public var line: String {
        var parts: [String] = []
        parts.append(String(format: "%.3f", timestamp.timeIntervalSince1970))
        parts.append("[\(category)]")
        parts.append(level.rawValue.uppercased())
        parts.append(code)
        if !message.isEmpty { parts.append(message) }
        if !fields.isEmpty {
            let rendered = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }
            parts.append(rendered.joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }
}

public enum DiagnosticLevel: String, Sendable, Comparable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: return 1
        case .info: return 2
        case .notice: return 3
        case .warning: return 4
        case .error: return 5
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        }
    }
}

public enum DiagnosticCategory: String, Sendable, CaseIterable {
    case app
    case viewer
    case pipeline
    case model
    case background
    case export
}

/// Injection point for tests and optional future log exporters. Implementations must be fast and
/// non-throwing; `Diagnostics` calls them outside the ring lock and treats them as best-effort.
public protocol DiagnosticSink: Sendable {
    func write(_ event: DiagnosticEvent)
}

public struct DiagnosticsConfiguration: Sendable {
    public var isEnabled: Bool
    public var maxEvents: Int
    public var maxRetainedBytes: Int
    public var fileMaxBytes: Int
    public var directory: URL
    public var sinks: [any DiagnosticSink]

    public init(
        isEnabled: Bool = true,
        maxEvents: Int = 500,
        maxRetainedBytes: Int = 256 * 1024,
        fileMaxBytes: Int = 512 * 1024,
        directory: URL? = nil,
        sinks: [any DiagnosticSink] = []
    ) {
        self.isEnabled = isEnabled
        self.maxEvents = max(1, maxEvents)
        self.maxRetainedBytes = max(1024, maxRetainedBytes)
        self.fileMaxBytes = max(1024, fileMaxBytes)
        self.directory = directory ?? Diagnostics.defaultDirectory()
        self.sinks = sinks
    }

    public static func production() -> DiagnosticsConfiguration {
        DiagnosticsConfiguration()
    }
}

/// A measured span ("equivalent signpost interval") that records its duration on `end()`.
public final class DiagnosticSpan: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: Diagnostics
    private let category: DiagnosticCategory
    private let code: String
    private let startNanos: UInt64
    private let baseFields: [String: String]
    private var ended = false

    init(
        owner: Diagnostics,
        category: DiagnosticCategory,
        code: String,
        fields: [String: String]
    ) {
        self.owner = owner
        self.category = category
        self.code = code
        self.startNanos = DispatchTime.now().uptimeNanoseconds
        self.baseFields = fields
    }

    public func end(level: DiagnosticLevel = .info, additionalFields: [String: String] = [:]) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        lock.unlock()
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- startNanos
        let seconds = Double(elapsedNanos) / 1_000_000_000.0
        var fields = baseFields
        for (key, value) in additionalFields { fields[key] = value }
        fields["seconds"] = String(format: "%.3f", seconds)
        owner.record(
            category: category,
            level: level,
            code: code,
            message: "span",
            fields: fields
        )
    }
}

public final class Diagnostics: @unchecked Sendable {
    public static let subsystem = "com.iantruong.truongscaler"
    public static let shared = Diagnostics(configuration: .production())

    private struct State {
        var nextSequence: UInt64 = 0
        var events: [DiagnosticEvent] = []
        var retainedBytes: Int = 0
        var fileBytes: Int = 0
        var didLogFileFailure = false
        var didLogSinkFailure = false
    }

    private let configuration: DiagnosticsConfiguration
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let ioQueue = DispatchQueue(label: "com.iantruong.truongscaler.diagnostics", qos: .utility)

    public init(configuration: DiagnosticsConfiguration = .production()) {
        self.configuration = configuration
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("TruongScalerDiagnostics", isDirectory: true)
    }

    // MARK: - Recording

    public func record(
        category: DiagnosticCategory,
        level: DiagnosticLevel = .info,
        code: String,
        message: String = "",
        fields: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        guard configuration.isEnabled else { return }
        let sanitizedFields = Self.redactedFields(fields)
        let sanitizedMessage = Self.sanitize(message)
        let safeCode = Self.sanitize(code)

        let event = lock.withLock { state -> DiagnosticEvent in
            state.nextSequence &+= 1
            let event = DiagnosticEvent(
                sequence: state.nextSequence,
                timestamp: timestamp,
                category: category.rawValue,
                level: level,
                code: safeCode,
                message: sanitizedMessage,
                fields: sanitizedFields
            )
            let eventBytes = event.line.utf8.count + 1
            // A single oversized event must not defeat the bounded ring. Drop it rather than retain
            // one unbounded record; callers keep processing/logging-neutral behavior.
            if eventBytes <= configuration.maxRetainedBytes {
                state.events.append(event)
                state.retainedBytes += eventBytes
                while state.events.count > configuration.maxEvents
                    || (state.retainedBytes > configuration.maxRetainedBytes && state.events.count > 1) {
                    let removed = state.events.removeFirst()
                    state.retainedBytes -= removed.line.utf8.count + 1
                }
                state.retainedBytes = max(0, state.retainedBytes)
            }
            return event
        }
        logger(for: category).log(level: event.level.osLogType, "\(event.line, privacy: .public)")

        for sink in configuration.sinks {
            sink.write(event)
        }

        let snapshotLine = event.line + "\n"
        let configurationDirectory = configuration.directory
        let configurationFileMaxBytes = configuration.fileMaxBytes
        ioQueue.async { [weak self] in
            self?.appendToDisk(
                snapshotLine,
                directory: configurationDirectory,
                fileMaxBytes: configurationFileMaxBytes
            )
        }
    }

    private func logger(for category: DiagnosticCategory) -> Logger {
        Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    public func startSpan(
        category: DiagnosticCategory,
        code: String,
        fields: [String: String] = [:]
    ) -> DiagnosticSpan {
        DiagnosticSpan(owner: self, category: category, code: code, fields: fields)
    }

    // MARK: - Error context

    public func recordError(
        _ error: Error,
        category: DiagnosticCategory,
        code: String,
        context: [String: String] = [:]
    ) {
        let info = Self.describe(error)
        var fields = context
        fields["errorDomain"] = info.domain
        fields["errorCode"] = info.code
        if !info.detail.isEmpty { fields["errorDetail"] = info.detail }
        record(category: category, level: .error, code: code, message: "error", fields: fields)
    }

    public struct ErrorInfo: Sendable, Equatable {
        public let domain: String
        public let code: String
        public let detail: String
    }

    public static func describe(_ error: Error) -> ErrorInfo {
        if let scaler = error as? ScalerError {
            return describeScalerError(scaler)
        }
        if error is CancellationError {
            return ErrorInfo(domain: "Swift.CancellationError", code: "cancelled", detail: "")
        }
        let nsError = error as NSError
        return ErrorInfo(
            domain: sanitize(nsError.domain),
            code: "\(nsError.code)",
            detail: sanitize(String(describing: type(of: error)))
        )
    }

    private static func describeScalerError(_ error: ScalerError) -> ErrorInfo {
        let code: String
        var detail = ""
        switch error {
        case .fileNotFound:
            code = "fileNotFound"
        case .unsupportedImageFormat(let format):
            code = "unsupportedImageFormat"
            detail = sanitize(format)
        case .imageSourceCreationFailed:
            code = "imageSourceCreationFailed"
        case .metadataExtractionFailed:
            code = "metadataExtractionFailed"
        case .hdrGainMapExpansionUnavailable:
            code = "hdrGainMapExpansionUnavailable"
        case .invalidImageDimensions(let width, let height):
            code = "invalidImageDimensions"
            detail = "\(width)x\(height)"
        case .insufficientDiskSpace(let required, let available):
            code = "insufficientDiskSpace"
            detail = "required=\(required) available=\(available)"
        case .mmapAllocationFailed(let errno, let requested):
            code = "mmapAllocationFailed"
            detail = "errno=\(errno) bytes=\(requested)"
        case .mmapSyncFailed(let errno):
            code = "mmapSyncFailed"
            detail = "errno=\(errno)"
        case .stripDecodingFailed(let strip, let rect):
            code = "stripDecodingFailed"
            detail = "strip=\(strip) rect=\(sanitize(rect))"
        case .metalDeviceUnavailable:
            code = "metalDeviceUnavailable"
        case .metalShaderCompilationFailed:
            code = "metalShaderCompilationFailed"
        case .metalExecutionFailed:
            code = "metalExecutionFailed"
        case .modelNotFound(let name):
            code = "modelNotFound"
            detail = "model=\(sanitize(name))"
        case .modelInferenceFailed(let name, let tile, let reason):
            code = "modelInferenceFailed"
            detail = "model=\(sanitize(name)) tile=\(tile) reason=\(sanitize(reason))"
        case .checkpointCorrupted:
            code = "checkpointCorrupted"
        case .normalizationMigrationRequiresRestart:
            code = "normalizationMigrationRequiresRestart"
        case .executionOwnerMismatch:
            code = "executionOwnerMismatch"
        case .exportDestinationCreationFailed:
            code = "exportDestinationCreationFailed"
        case .dngWriteFailed(let reason):
            code = "dngWriteFailed"
            detail = sanitize(reason)
        case .jobCancelled:
            code = "jobCancelled"
        case .jobPausedForBackgroundExpiration(let tile):
            code = "jobPausedForBackgroundExpiration"
            detail = "tile=\(tile)"
        case .appGroupUnavailable(let identifier):
            code = "appGroupUnavailable"
            detail = "group=\(sanitize(identifier))"
        case .unsupportedFormatExport(let format, let reason):
            code = "unsupportedFormatExport"
            detail = "format=\(sanitize(format)) reason=\(sanitize(reason))"
        case .backgroundTaskSchedulingFailed(let reason):
            code = "backgroundTaskSchedulingFailed"
            detail = sanitize(reason)
        case .productionModelUnavailable(let name, _):
            code = "productionModelUnavailable"
            detail = "model=\(sanitize(name))"
        case .srOnlyResumeOfLegacyDenoiseJob(let completed, let total):
            code = "srOnlyResumeOfLegacyDenoiseJob"
            detail = "completed=\(completed) total=\(total)"
        }
        return ErrorInfo(domain: "TruongScaler.ScalerError", code: code, detail: detail)
    }

    // MARK: - Bounded snapshot / export

    public func recentEvents(limit: Int = 500) -> [DiagnosticEvent] {
        lock.withLock { state in
            Array(state.events.suffix(max(1, limit)))
        }
    }

    public func snapshot() -> String {
        let events = lock.withLock { $0.events }
        var lines: [String] = ["TruongScaler diagnostics v1 (bounded)"]
        for event in events { lines.append(event.line) }
        return lines.joined(separator: "\n")
    }

    /// Flushes pending asynchronous disk writes (tests / controlled handoff only).
    public func flush() {
        ioQueue.sync {}
    }

    public func clearForTesting() {
        ioQueue.sync {}
        lock.withLock { state in
            state.events.removeAll()
            state.retainedBytes = 0
        }
    }

    // MARK: - File retention

    private func appendToDisk(_ line: String, directory: URL, fileMaxBytes: Int) {
        let fileManager = FileManager.default
        let data = Data(line.utf8)
        let lineBytes = data.count
        // An oversized record cannot fit any bounded file; drop disk output rather than exceed the cap.
        guard lineBytes <= fileMaxBytes else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = directory.appendingPathComponent("truongscaler.log")
            let previous = directory.appendingPathComponent("truongscaler.log.1")
            let attributes = try? fileManager.attributesOfItem(atPath: current.path)
            let existingSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0

            if existingSize + lineBytes > fileMaxBytes {
                // Rotation must fully succeed before any append. If the previous entry cannot be
                // removed/moved (immutable directory, permissions, etc.), fail closed and skip disk
                // output; otherwise repeated failures would grow the current file without bound.
                if fileManager.fileExists(atPath: previous.path) {
                    do { try fileManager.removeItem(at: previous) } catch { return }
                }
                if existingSize > fileMaxBytes {
                    // A pre-existing oversized current file cannot become a valid rollover entry.
                    do { try fileManager.removeItem(at: current) } catch { return }
                } else if fileManager.fileExists(atPath: current.path) {
                    do { try fileManager.moveItem(at: current, to: previous) } catch { return }
                }
                guard !fileManager.fileExists(atPath: current.path) else { return }
            }

            if fileManager.fileExists(atPath: current.path) {
                let currentSize = (try? fileManager.attributesOfItem(atPath: current.path))?[.size] as? NSNumber
                guard (currentSize?.intValue ?? 0) + lineBytes <= fileMaxBytes else { return }
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: current, options: .atomic)
            }
        } catch {
            lock.withLock { state in
                guard !state.didLogFileFailure else { return }
                state.didLogFileFailure = true
            }
        }
    }

    // MARK: - Sanitization

    /// Removes user/home paths and caps field/message length. Call sites also avoid filenames.
    public static func sanitize(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        var result = value
        let home = NSHomeDirectory()
        if !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        // Normalize escaped slash forms before the path scrub so `\/Users\/...` cannot leave a
        // private suffix behind.
        result = result.replacingOccurrences(of: "\\/", with: "/")
        // Localized filesystem errors frequently quote the private folder/file name. No diagnostic
        // consumer needs that text; keep the stable code/context instead.
        if let quoted = try? NSRegularExpression(
            pattern: "“[^”]*”|\"[^\"]*\"|'[^']*'",
            options: []
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = quoted.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "<redacted>")
        }
        // Replace any remaining known absolute-path prefix through the rest of the line. Paths can
        // contain spaces (`Private Client Photos/ConfidentialCapture.dng`); stopping at the first
        // space leaked the private suffix in the old implementation.
        if let regex = try? NSRegularExpression(
            pattern: "(?:file://)?(?:~|/(?:Users|private|var|tmp|Volumes|System|Library|Applications|Developer))/[^\\n;\"“”'<>]*",
            options: []
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "<path>")
        }
        result = result.replacingOccurrences(of: "\n", with: " ")
        if result.count > 300 {
            result = String(result.prefix(300)) + "…"
        }
        return result
    }

    /// Drops fields that could carry private paths/secrets before they ever enter the ring or log.
    public static func redactedFields(_ fields: [String: String]) -> [String: String] {
        let forbidden = ["path", "url", "filename", "bookmark", "token", "secret", "credential", "photo", "reason", "folder"]
        var result: [String: String] = [:]
        for (key, value) in fields {
            let lower = key.lowercased()
            if forbidden.contains(where: { lower.contains($0) }) { continue }
            result[key] = sanitize(value)
        }
        return result
    }
}

// MARK: - Build/config diagnostics

public extension Diagnostics {
    /// Normal app launch/build/OS facts. Call from `TruongScalerApp.init()` and from tests that need
    /// the same event shape. Deliberately no device serial, user id, or personal path.
    func recordLaunch(
        configuration: String,
        appVersion: String,
        buildNumber: String,
        osVersion: String
    ) {
        record(
            category: .app,
            level: .notice,
            code: "app.launch",
            message: "TruongScaler started",
            fields: [
                "configuration": configuration,
                "appVersion": appVersion,
                "buildNumber": buildNumber,
                "osVersion": osVersion,
                "diagnosticsVersion": "1"
            ]
        )
    }
}
