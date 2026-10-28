import Foundation
import CryptoKit
import CoreIngestion
import TruongScalerCore

public enum LibraryCollection: String, Sendable, CaseIterable, Identifiable {
    case input, output
    public var id: String { rawValue }
    public var title: String { self == .input ? "Input" : "Output" }
    public var symbol: String { self == .input ? "photo.on.rectangle" : "sparkles.rectangle.stack" }
}

public struct ArchivedOriginal: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64
    public let filename: String
}

/// Portable record. Paths are relative to the user-selected output folder, never private app URLs.
public struct ProcessedPhotoRecord: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let authoredBy: String
    public let id: UUID
    public let original: ArchivedOriginal
    public let outputRelativePath: String
    public let outputSHA256: String
    public let outputByteCount: Int64
    public let modelRawValue: String
    public let scaleFactor: Int
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let grainAmount: Float
    public let processedAt: Date
    public let formatRawValue: String

    public var modelLabel: String {
        let model = BackboneModelKind(rawValue: modelRawValue)
        return model.isSupported ? model.displayName : modelRawValue
    }
    public var thumbnailRelativePath: String {
        "thumbnails/" + (outputRelativePath as NSString).deletingPathExtension + ".jpg"
    }
    public var metadataRelativePath: String {
        "metadata/" + (outputRelativePath as NSString).deletingPathExtension + ".json"
    }
}

struct ProcessedPhotoDraft: Sendable {
    let id: UUID
    let modelRawValue: String
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let scaleFactor: Int
    let grainAmount: Float
    let processedAt: Date
    let formatRawValue: String
}

struct OpenedProcessedPhoto: Sendable {
    let outputURL: URL
    let originalURL: URL?
    let comparisonUnavailableReason: String?
}

enum ProcessedLibraryError: LocalizedError {
    case invalidRecord, changedFile, unsafePath, conflictingFile, unreadableFolder
    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "This result has incomplete or invalid saved information. Its files were left unchanged."
        case .changedFile: return "This saved file has changed since it was processed. Its original and result were left unchanged."
        case .unsafePath: return "A saved result points outside the selected output folder. Choose the original output folder again."
        case .conflictingFile: return "A different file already exists at this result's destination. Nothing was overwritten."
        case .unreadableFolder: return "The output folder is unavailable or cannot be written. Reconnect it or choose another folder."
        }
    }
}

/// File coordination, streaming hashes/copies and record publication run off MainActor. The caller
/// holds independent input/output security-scope leases until each awaited operation drains.
actor ProcessedLibraryStore {
    let io = BlockingIOOwner(label: "com.truongscaler.processed-library")

    func validateWritableFolder(_ root: URL) async throws {
        try await io.run {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isWritableKey])
            guard values.isDirectory == true, values.isReadable != false, values.isWritable != false else {
                throw ProcessedLibraryError.unreadableFolder
            }
            try Self.coordinatedWrite(root) { folder in
                let probe = try Self.resolve(".truongscaler-\(UUID().uuidString).probe", under: folder)
                try Data().write(to: probe, options: .withoutOverwriting)
                try FileManager.default.removeItem(at: probe)
            }
        }
    }

    /// Freeze the exact input bytes before inference. A shared SHA-addressed original is copied once.
    func archiveOriginal(at source: URL, named filename: String, under root: URL) async throws -> ArchivedOriginal {
        try await io.run {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<ArchivedOriginal, Error>?
            coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: root,
                options: .forMerging, error: &coordinationError) { input, folder in
                result = Result {
                    let stage = try Self.resolve(".staging/source-\(UUID().uuidString)", under: folder)
                    try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: stage) }
                    let copied = try Self.copyAndHash(input, to: stage)
                    let ext = source.pathExtension.lowercased()
                    guard !ext.isEmpty, ext.count < 16, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                        throw ProcessedLibraryError.unsafePath
                    }
                    let relative = "comparison-originals/\(copied.sha).\(ext)"
                    let final = try Self.resolve(relative, under: folder)
                    try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: final.path) {
                        guard try Self.hash(final) == copied.sha else { throw ProcessedLibraryError.conflictingFile }
                    } else {
                        try FileManager.default.moveItem(at: stage, to: final)
                    }
                    return ArchivedOriginal(relativePath: relative, sha256: copied.sha, byteCount: copied.bytes, filename: filename)
                }
            }
            if let coordinationError { throw coordinationError }
            return try result?.get() ?? { throw ProcessedLibraryError.unreadableFolder }()
        }
    }

    func originalURL(_ original: ArchivedOriginal, under root: URL) async throws -> URL {
        try await io.run {
            let url = try Self.resolve(original.relativePath, under: root)
            guard try Self.hash(url) == original.sha256 else { throw ProcessedLibraryError.changedFile }
            return url
        }
    }

    /// Commit the image and its source association, with metadata published last. A pending record
    /// survives interruption after the image move and is completed by scan/retry after hash checks.
    func publish(exportedURL: URL, original: ArchivedOriginal, draft: ProcessedPhotoDraft, under root: URL, previewURL: URL? = nil) async throws -> ProcessedPhotoRecord {
        try await io.run {
            try Self.coordinatedWrite(root) { folder in
                try Self.recoverPending(in: folder)
                let published = try Self.scan(in: folder).filter { $0.id == draft.id }
                if !published.isEmpty {
                    // A portable folder merge can legitimately contain multiple records for one
                    // saved-job UUID. A retry owns its actual configuration and exported bytes;
                    // UUID/model alone must never select another result's path or metadata.
                    let candidates = published.filter {
                        $0.original == original && $0.modelRawValue == draft.modelRawValue &&
                        $0.scaleFactor == draft.scaleFactor && $0.sourceWidth == draft.sourceWidth &&
                        $0.sourceHeight == draft.sourceHeight && $0.outputWidth == draft.outputWidth &&
                        $0.outputHeight == draft.outputHeight && $0.grainAmount == draft.grainAmount &&
                        $0.formatRawValue == draft.formatRawValue
                    }
                    guard !candidates.isEmpty else { throw ProcessedLibraryError.conflictingFile }
                    let values = try exportedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else {
                        throw ProcessedLibraryError.changedFile
                    }
                    let exportedHash = try Self.hash(exportedURL)
                    let matches = candidates.filter { $0.outputByteCount == Int64(bytes) && $0.outputSHA256 == exportedHash }
                    guard matches.count == 1, let existing = matches.first else {
                        throw ProcessedLibraryError.conflictingFile
                    }
                    guard try Self.hash(Self.resolve(existing.outputRelativePath, under: folder)) == existing.outputSHA256 else {
                        throw ProcessedLibraryError.changedFile
                    }
                    return existing
                }
                let source = try Self.resolve(original.relativePath, under: folder)
                guard try Self.hash(source) == original.sha256 else { throw ProcessedLibraryError.changedFile }
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: draft.processedAt)
                let datePath = String(format: "%04d/%02d/%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
                let ext = exportedURL.pathExtension.lowercased()
                guard ["dng", "tiff", "tif", "heic", "png", "jpg", "jpeg"].contains(ext) else { throw ProcessedLibraryError.invalidRecord }
                let relative = "originals/\(datePath)/TS_\(draft.id.uuidString.lowercased()).\(ext)"
                let staged = try Self.resolve(".staging/\(draft.id.uuidString.lowercased()).image", under: folder)
                try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A previous uncommitted staging file is ours; a final image is never overwritten.
                if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
                // Recovery uses the durable intent and final image, never this private copy. A
                // failed copy/validation/publication must not leak another full-sized image.
                defer { try? FileManager.default.removeItem(at: staged) }
                let copied = try Self.copyAndHash(exportedURL, to: staged)
                var record = ProcessedPhotoRecord(schemaVersion: 1, authoredBy: "com.iantruong.truongscaler", id: draft.id,
                    original: original, outputRelativePath: relative, outputSHA256: copied.sha, outputByteCount: copied.bytes,
                    modelRawValue: draft.modelRawValue, scaleFactor: draft.scaleFactor,
                    sourceWidth: draft.sourceWidth, sourceHeight: draft.sourceHeight,
                    outputWidth: draft.outputWidth, outputHeight: draft.outputHeight, grainAmount: draft.grainAmount,
                    processedAt: draft.processedAt, formatRawValue: draft.formatRawValue)
                try Self.validate(record)
                let pending = try Self.resolve(".staging/\(draft.id.uuidString.lowercased()).pending.json", under: folder)
                let hasPending = FileManager.default.fileExists(atPath: pending.path)
                if hasPending {
                    // A failed recovery may leave a conflicting intent for this same job. Preserve
                    // it byte-for-byte. A retry creates a later timestamp, so compare authoritative
                    // image/configuration fields and retain the original intent's date and path.
                    guard let values = try? pending.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true, let size = values.fileSize, size <= 256 * 1024,
                          let data = try? Data(contentsOf: pending),
                          let saved = try? JSONDecoder().decode(ProcessedPhotoRecord.self, from: data),
                          (try? Self.validate(saved)) != nil,
                          saved.id == record.id, saved.original == record.original,
                          saved.outputSHA256 == record.outputSHA256, saved.outputByteCount == record.outputByteCount,
                          saved.modelRawValue == record.modelRawValue, saved.scaleFactor == record.scaleFactor,
                          saved.sourceWidth == record.sourceWidth, saved.sourceHeight == record.sourceHeight,
                          saved.outputWidth == record.outputWidth, saved.outputHeight == record.outputHeight,
                          saved.grainAmount == record.grainAmount, saved.formatRawValue == record.formatRawValue else {
                        throw ProcessedLibraryError.conflictingFile
                    }
                    record = saved
                }
                let output = try Self.resolve(record.outputRelativePath, under: folder)
                if let previewURL {
                    let preview = try Self.resolve(record.thumbnailRelativePath, under: folder)
                    try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: preview.path) {
                        let temp = try Self.resolve(".staging/preview-\(UUID().uuidString).jpg", under: folder)
                        defer { try? FileManager.default.removeItem(at: temp) }
                        _ = try Self.copyAndHash(previewURL, to: temp)
                        try FileManager.default.moveItem(at: temp, to: preview)
                    }
                }
                if !hasPending { try JSONEncoder().encode(record).write(to: pending, options: .atomic) }
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !FileManager.default.fileExists(atPath: output.path) else { throw ProcessedLibraryError.conflictingFile }
                try FileManager.default.moveItem(at: staged, to: output)
                try Self.commit(record, under: folder)
                try FileManager.default.removeItem(at: pending)
                return record
            }
        }
    }

    func records(under root: URL) async throws -> [ProcessedPhotoRecord] {
        try await io.run {
            try Self.coordinatedWrite(root) { folder in
                try Self.recoverTrash(in: folder)
                try Self.recoverPending(in: folder)
                return try Self.scan(in: folder)
            }
        }
    }

    func thumbnailURL(_ record: ProcessedPhotoRecord, under root: URL) async throws -> URL {
        try await io.run { try Self.resolve(record.thumbnailRelativePath, under: root) }
    }

    func open(_ record: ProcessedPhotoRecord, under root: URL) async throws -> OpenedProcessedPhoto {
        try await io.run {
            try Self.validate(record)
            let output = try Self.resolve(record.outputRelativePath, under: root)
            guard try Self.hash(output) == record.outputSHA256 else { throw ProcessedLibraryError.changedFile }
            var original: URL?
            // The comparison is optional. Refuse an unsafe original without following it,
            // while retaining access to the independently verified result.
            if let candidate = try? Self.resolve(record.original.relativePath, under: root),
               (try? Self.hash(candidate)) == record.original.sha256 {
                original = candidate
            }
            return OpenedProcessedPhoto(outputURL: output, originalURL: original,
                comparisonUnavailableReason: original != nil ? nil : "The saved original is missing or changed. You can still view and share the result, but its before/after comparison is unavailable.")
        }
    }

    /// Older exports have no source/model sidecar. Recognize their embedded app marker, never
    /// a filename alone, and expose them read-only with explicitly unavailable comparisons.
    func legacyPhotos(under root: URL, excluding records: [ProcessedPhotoRecord]) async throws -> [LibraryPhotoItem] {
        try await io.run {
            let recorded = Set(records.map { root.appendingPathComponent($0.outputRelativePath).standardizedFileURL.resolvingSymlinksInPath() })
            let known = StudioViewModel.scanLibraryItemsSynchronously(at: root)
            return known.compactMap { item in
                let canonical = item.fileURL.standardizedFileURL.resolvingSymlinksInPath()
                guard !recorded.contains(canonical), canonical.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { return nil }
                let relative = String(canonical.path.dropFirst(root.standardizedFileURL.resolvingSymlinksInPath().path.count + 1))
                guard !relative.hasPrefix("comparison-originals/"), !relative.hasPrefix("metadata/"), !relative.hasPrefix("thumbnails/"),
                      (try? Self.resolve(relative, under: root)) != nil,
                      let metadata = try? MetadataExtractor.extractMetadata(from: item.fileURL), metadata.isAlreadyUpscaledBySuite else { return nil }
                let marker: String
                if let plist = metadata.rawPropertiesPlistData,
                   let properties = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) {
                    marker = String(describing: properties)
                } else {
                    // Rendered Linear DNGs can lack ImageIO's property dictionary.
                    marker = LinearDNGTIFFReader.probe(imageURL: item.fileURL)?.software ?? ""
                }
                guard marker.contains("TruongScaler") else { return nil }
                return LibraryPhotoItem(id: item.id, fileURL: item.fileURL, filename: item.filename,
                    capturedAt: item.capturedAt, byteCount: item.byteCount, badgeLabel: "Earlier result", collection: .output)
            }
        }
    }

    nonisolated static func resolve(_ relative: String, under root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, !relative.isEmpty, relative.utf8.count < 4096, !relative.hasPrefix("/"), !relative.contains("\\"),
              !relative.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProcessedLibraryError.unsafePath
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relative).standardizedFileURL
        // Resolving a non-existent final leaf may leave existing symlink prefixes unresolved.
        // Never accept a symlink beneath the chosen root, including dangling directory links.
        var prefix = base
        for component in components {
            prefix.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.path)) != nil {
                throw ProcessedLibraryError.unsafePath
            }
        }
        return url
    }

    nonisolated static func validate(_ r: ProcessedPhotoRecord) throws {
        let (width, ow) = r.sourceWidth.multipliedReportingOverflow(by: r.scaleFactor)
        let (height, oh) = r.sourceHeight.multipliedReportingOverflow(by: r.scaleFactor)
        func digest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
        guard r.schemaVersion == 1, r.authoredBy == "com.iantruong.truongscaler", r.scaleFactor > 0, r.scaleFactor <= 8,
              r.sourceWidth > 0, r.sourceHeight > 0, !ow, !oh, width == r.outputWidth, height == r.outputHeight,
              digest(r.outputSHA256), digest(r.original.sha256), r.outputByteCount > 0, r.original.byteCount > 0,
              r.modelRawValue.count <= 128, !r.modelRawValue.isEmpty, r.grainAmount.isFinite,
              r.outputRelativePath.hasPrefix("originals/"), r.original.relativePath.hasPrefix("comparison-originals/") else {
            throw ProcessedLibraryError.invalidRecord
        }
    }

    nonisolated static func scan(in root: URL) throws -> [ProcessedPhotoRecord] {
        let directory = try resolve("metadata/originals", under: root)
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [ProcessedPhotoRecord] = []
        for case let file as URL in enumerator where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("TS_") {
            let basePath = root.standardizedFileURL.resolvingSymlinksInPath().path
            let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(basePath + "/") else { continue }
            let relative = String(filePath.dropFirst(basePath.count + 1))
            guard let safe = try? resolve(relative, under: root), let values = try? safe.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 256 * 1024,
                  let record = try? JSONDecoder().decode(ProcessedPhotoRecord.self, from: Data(contentsOf: safe)),
                  (try? validate(record)) != nil, record.metadataRelativePath == relative,
                  let output = try? resolve(record.outputRelativePath, under: root),
                  FileManager.default.fileExists(atPath: output.path) else { continue }
            result.append(record)
        }
        return result.sorted { $0.processedAt > $1.processedAt }
    }

    nonisolated static func commit(_ record: ProcessedPhotoRecord, under root: URL) throws {
        let target = try resolve(record.metadataRelativePath, under: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try JSONDecoder().decode(ProcessedPhotoRecord.self, from: Data(contentsOf: target)) == record else {
                throw ProcessedLibraryError.conflictingFile
            }
        } else {
            let stage = target.deletingLastPathComponent().appendingPathComponent(".record-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            try JSONEncoder().encode(record).write(to: stage, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: stage)
            try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: stage, to: target)
        }
    }

    nonisolated static func recoverPending(in root: URL) throws {
        let directory = try resolve(".staging", under: root)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".pending.json") {
            guard let safe = try? resolve(".staging/" + file.lastPathComponent, under: root),
                  let size = try? safe.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024,
                  let record = try? JSONDecoder().decode(ProcessedPhotoRecord.self, from: Data(contentsOf: safe)),
                  (try? validate(record)) != nil else { continue }
            guard let output = try? resolve(record.outputRelativePath, under: root),
                  let original = try? resolve(record.original.relativePath, under: root),
                  (try? hash(output)) == record.outputSHA256,
                  (try? hash(original)) == record.original.sha256 else { continue }
            do {
                try commit(record, under: root)
                try FileManager.default.removeItem(at: safe)
            } catch {
                // Leave conflicting/uncommitted intent available for repair. A failure confined
                // to this record must not prevent listing or publishing unrelated healthy photos.
                continue
            }
        }
    }

    nonisolated static func copyAndHash(_ input: URL, to destination: URL) throws -> (sha: String, bytes: Int64) {
        try Data().write(to: destination, options: .withoutOverwriting)
        let reader = try FileHandle(forReadingFrom: input), writer = try FileHandle(forWritingTo: destination)
        defer { try? reader.close(); try? writer.close() }
        var digest = SHA256(), count: Int64 = 0
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data); count += Int64(data.count); try writer.write(contentsOf: data)
        }
        try writer.synchronize()
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    nonisolated static func hash(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var digest = SHA256()
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func coordinatedWrite<T>(_ root: URL, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &error) { folder in
            result = Result { try body(folder) }
        }
        if let error { throw error }
        guard let result else { throw ProcessedLibraryError.unreadableFolder }
        return try result.get()
    }
}
