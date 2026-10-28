import Foundation
import CoreIngestion

public struct OutputTrashEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let schemaVersion: Int
    public let authoredBy: String
    public let deletedAt: Date
    public let filename: String
    public let record: ProcessedPhotoRecord?
    var state: State
    var files: [File]
    enum State: String, Codable, Sendable { case moving, trashed, restoring, purging }
    struct File: Codable, Sendable, Equatable {
        let originalPath: String
        let storedName: String
        let sha256: String
        let bytes: Int64
    }
    public var canRestore: Bool { state != .purging }
    public var byteCount: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var directory: String { ".trash/" + id.uuidString.lowercased() }
}

extension ProcessedLibraryStore {
    func trashPreviewURL(_ expected: OutputTrashEntry, under root: URL) async throws -> URL {
        try await io.run {
            guard let entry = try Self.readTrash(in: root).first(where: { $0.id == expected.id }), entry == expected,
                  let file = entry.files.first(where: { $0.originalPath.hasPrefix("thumbnails/") }) ?? entry.files.first else { throw ProcessedLibraryError.changedFile }
            let url = try Self.resolve(entry.directory + "/" + file.storedName, under: root)
            try Self.verifyTrashFile(file, at: url)
            return url
        }
    }

    func trash(record: ProcessedPhotoRecord, under root: URL) async throws {
        try await io.run {
            try Self.coordinatedWrite(root) { folder in
                try Self.validate(record)
                let metadata = try Self.resolve(record.metadataRelativePath, under: folder)
                guard try JSONDecoder().decode(ProcessedPhotoRecord.self, from: Data(contentsOf: metadata)) == record else {
                    throw ProcessedLibraryError.changedFile
                }
                var paths = [record.outputRelativePath]
                if FileManager.default.fileExists(atPath: try Self.resolve(record.thumbnailRelativePath, under: folder).path) {
                    paths.append(record.thumbnailRelativePath)
                }
                paths.append(record.metadataRelativePath) // publishing/unpublishing metadata is always last
                let entry = try Self.makeTrash(paths: paths, record: record, under: folder)
                guard entry.files.first?.sha256 == record.outputSHA256,
                      entry.files.first?.bytes == record.outputByteCount else { throw ProcessedLibraryError.changedFile }
                try Self.writeTrash(entry, under: folder)
                try Self.finishTrash(entry, under: folder)
            }
        }
    }

    func trashLegacy(at url: URL, under root: URL) async throws {
        try await io.run {
            try Self.coordinatedWrite(root) { folder in
                let base = folder.standardizedFileURL.path + "/"
                guard url.standardizedFileURL.path.hasPrefix(base) else { throw ProcessedLibraryError.unsafePath }
                let path = String(url.standardizedFileURL.path.dropFirst(base.count))
                let safe = try Self.resolve(path, under: folder)
                let packet = try MetadataExtractor.extractMetadata(from: safe)
                let marker = packet.rawPropertiesPlistData.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
                let software = LinearDNGTIFFReader.probe(imageURL: safe)?.software ?? ""
                guard packet.isAlreadyUpscaledBySuite,
                      String(describing: marker).contains("TruongScaler") || software.contains("TruongScaler"),
                      Self.allowedLegacyTrashPath(path) else { throw ProcessedLibraryError.invalidRecord }
                let entry = try Self.makeTrash(paths: [path], record: nil, under: folder)
                try Self.writeTrash(entry, under: folder)
                try Self.finishTrash(entry, under: folder)
            }
        }
    }

    func trashed(under root: URL) async throws -> [OutputTrashEntry] {
        try await io.run {
            try Self.coordinatedWrite(root) { folder in
                try Self.recoverTrash(in: folder)
                return try Self.readTrash(in: folder).sorted { $0.deletedAt > $1.deletedAt }
            }
        }
    }

    /// The frozen entry must still match exactly. A stale confirmation cannot act on a changed entry.
    func restore(_ expected: OutputTrashEntry, under root: URL) async throws {
        try await mutateTrash(expected, under: root, state: .restoring)
    }
    func permanentlyDelete(_ expected: OutputTrashEntry, under root: URL) async throws {
        try await mutateTrash(expected, under: root, state: .purging)
    }
    private func mutateTrash(_ expected: OutputTrashEntry, under root: URL, state: OutputTrashEntry.State) async throws {
        try await io.run {
            try Self.coordinatedWrite(root) { folder in
                guard var entry = try Self.readTrash(in: folder).first(where: { $0.id == expected.id }), entry == expected,
                      state != .restoring || entry.canRestore else { throw ProcessedLibraryError.changedFile }
                guard state == .restoring || entry.state == .trashed || entry.state == .purging else { throw ProcessedLibraryError.conflictingFile }
                // Validate every file and every restore destination BEFORE writing intent or moving bytes.
                try Self.preflight(entry, under: folder, action: state)
                entry.state = state
                try Self.writeTrash(entry, under: folder)
                try Self.finishTrash(entry, under: folder)
            }
        }
    }

    nonisolated static func allowedLegacyTrashPath(_ path: String) -> Bool {
        guard let first = path.split(separator: "/").first else { return false }
        return !first.hasPrefix(".") && !["comparison-originals", "metadata", "thumbnails"].contains(String(first))
    }
    nonisolated static func makeTrash(paths: [String], record: ProcessedPhotoRecord?, under root: URL) throws -> OutputTrashEntry {
        let files = try paths.enumerated().map { index, path in
            let url = try resolve(path, under: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let bytes = values.fileSize else { throw ProcessedLibraryError.changedFile }
            return OutputTrashEntry.File(originalPath: path, storedName: "\(index)." + url.pathExtension,
                sha256: try hash(url), bytes: Int64(bytes))
        }
        return OutputTrashEntry(id: UUID(), schemaVersion: 1, authoredBy: "com.iantruong.truongscaler", deletedAt: Date(),
            filename: (paths[0] as NSString).lastPathComponent, record: record, state: .moving, files: files)
    }
    nonisolated static func validateTrash(_ entry: OutputTrashEntry) throws {
        guard entry.schemaVersion == 1, entry.authoredBy == "com.iantruong.truongscaler", (1...3).contains(entry.files.count),
              Set(entry.files.map(\.originalPath)).count == entry.files.count,
              Set(entry.files.map(\.storedName)).count == entry.files.count else { throw ProcessedLibraryError.invalidRecord }
        var totalBytes: Int64 = 0
        for (index, file) in entry.files.enumerated() {
            guard file.bytes >= 0, file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }),
                  file.storedName == "\(index)." + (file.originalPath as NSString).pathExtension else { throw ProcessedLibraryError.invalidRecord }
            let (nextBytes, overflow) = totalBytes.addingReportingOverflow(file.bytes)
            guard !overflow else { throw ProcessedLibraryError.invalidRecord }
            totalBytes = nextBytes
        }
        if let record = entry.record {
            try validate(record)
            let allowed = Set([record.outputRelativePath, record.thumbnailRelativePath, record.metadataRelativePath])
            guard entry.files.first?.originalPath == record.outputRelativePath,
                  entry.files.first?.sha256 == record.outputSHA256,
                  entry.files.first?.bytes == record.outputByteCount,
                  entry.files.last?.originalPath == record.metadataRelativePath,
                  entry.files.allSatisfy({ allowed.contains($0.originalPath) }) else { throw ProcessedLibraryError.invalidRecord }
        } else {
            guard entry.files.count == 1, allowedLegacyTrashPath(entry.files[0].originalPath) else { throw ProcessedLibraryError.invalidRecord }
        }
    }
    nonisolated static func readTrash(in root: URL) throws -> [OutputTrashEntry] {
        let directory = try resolve(".trash", under: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent), folder.lastPathComponent == id.uuidString.lowercased() else { return nil }
            // One damaged or unsafe sidecar must not hide unrelated results/trash entries.
            // The root/listing errors above still propagate; skipped entry bytes stay untouched.
            guard let url = try? resolve(".trash/\(folder.lastPathComponent)/entry.json", under: root) else { return nil }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024 else { return nil }
            guard let entry = try? JSONDecoder().decode(OutputTrashEntry.self, from: Data(contentsOf: url)),
                  entry.authoredBy == "com.iantruong.truongscaler", entry.schemaVersion == 1 else { return nil }
            guard (try? validateTrash(entry)) != nil, entry.id == id else { return nil }
            return entry
        }
    }
    nonisolated static func writeTrash(_ entry: OutputTrashEntry, under root: URL) throws {
        try validateTrash(entry)
        let url = try resolve(entry.directory + "/entry.json", under: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize(); try handle.close()
    }
    nonisolated static func verifyTrashFile(_ file: OutputTrashEntry.File, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize.map(Int64.init) == file.bytes,
              try hash(url) == file.sha256 else { throw ProcessedLibraryError.changedFile }
    }
    nonisolated static func preflight(_ entry: OutputTrashEntry, under root: URL, action: OutputTrashEntry.State) throws {
        for file in entry.files {
            let original = try resolve(file.originalPath, under: root)
            let stored = try resolve(entry.directory + "/" + file.storedName, under: root)
            let from = action == .moving ? original : stored
            let to = action == .moving ? stored : original
            if action == .purging {
                if FileManager.default.fileExists(atPath: stored.path) { try verifyTrashFile(file, at: stored) }
            } else {
                let fromExists = FileManager.default.fileExists(atPath: from.path)
                let toExists = FileManager.default.fileExists(atPath: to.path)
                guard fromExists != toExists else { throw ProcessedLibraryError.conflictingFile }
                try verifyTrashFile(file, at: fromExists ? from : to)
            }
        }
    }
    nonisolated static func finishTrash(_ initial: OutputTrashEntry, under root: URL) throws {
        var entry = initial
        guard entry.state != .trashed else { return }
        try preflight(entry, under: root, action: entry.state)
        for file in entry.files {
            let original = try resolve(file.originalPath, under: root)
            let stored = try resolve(entry.directory + "/" + file.storedName, under: root)
            if entry.state == .purging {
                if FileManager.default.fileExists(atPath: stored.path) {
                    try verifyTrashFile(file, at: stored)
                    try FileManager.default.removeItem(at: stored)
                }
            } else {
                let from = entry.state == .moving ? original : stored
                let to = entry.state == .moving ? stored : original
                if FileManager.default.fileExists(atPath: from.path) {
                    try verifyTrashFile(file, at: from)
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: from, to: to)
                }
            }
        }
        if entry.state == .moving {
            entry.state = .trashed
            try writeTrash(entry, under: root)
        } else {
            // Never recursively delete a folder: unknown/unverified contents must remain untouched.
            let manifest = try resolve(entry.directory + "/entry.json", under: root)
            try FileManager.default.removeItem(at: manifest)
            let directory = manifest.deletingLastPathComponent()
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { try FileManager.default.removeItem(at: directory) }
        }
    }
    nonisolated static func recoverTrash(in root: URL) throws {
        for entry in try readTrash(in: root) where entry.state != .trashed {
            // A conflicting/changed entry stays recoverable and visible for a later retry.
            try? finishTrash(entry, under: root)
        }
    }
}
