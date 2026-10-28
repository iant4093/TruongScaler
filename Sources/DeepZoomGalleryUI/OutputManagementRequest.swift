import Foundation

/// Frozen at the moment a confirmation is requested, never reinterpreted against a new folder.
public struct OutputManagementRequest: Identifiable, Sendable {
    public let id = UUID()
    let generation: UInt64
    let root: URL
    let records: [ProcessedPhotoRecord]
    let legacyURLs: [URL]
    public var count: Int { records.count + legacyURLs.count }
}
public struct TrashManagementRequest: Identifiable, Sendable {
    public let id = UUID()
    let generation: UInt64
    let root: URL
    let entries: [OutputTrashEntry]
    let permanent: Bool
    public var count: Int { entries.count }
}
