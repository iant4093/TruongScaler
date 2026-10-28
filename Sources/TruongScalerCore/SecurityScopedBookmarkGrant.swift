import Foundation

/// Adapted directly from `TruongCam shared Files-grant design`.
/// NOTE: `URL.BookmarkCreationOptions.withSecurityScope` is `API_UNAVAILABLE(ios)`.
/// On iOS, bookmarks created from a security-scoped URL via `.minimalBookmark` carry
/// their security scope automatically when resolved during an active scope lease.
public enum BookmarkRootGrant {
    public static func createBookmarkData(for url: URL) throws -> Data {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func resolveBookmarkData(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (resolved, stale)
    }
}
