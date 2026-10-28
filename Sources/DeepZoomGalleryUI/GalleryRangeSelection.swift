import Foundation

/// One Photos-style sweep, frozen to the loaded ordering and selection at touch
/// down. Reversing restores the original selection outside the current range.
struct GalleryRangeSelection: Sendable {
    let orderedIDs: [String]
    let baseline: Set<String>
    let anchor: Int
    let selects: Bool

    init?(orderedIDs: [String], anchorID: String, baseline: Set<String>) {
        guard let anchor = orderedIDs.firstIndex(of: anchorID) else { return nil }
        self.orderedIDs = orderedIDs
        self.baseline = baseline
        self.anchor = anchor
        selects = !baseline.contains(anchorID)
    }

    func selection(through id: String) -> Set<String>? {
        guard let end = orderedIDs.firstIndex(of: id) else { return nil }
        let range = Set(orderedIDs[min(anchor, end)...max(anchor, end)])
        return selects ? baseline.union(range) : baseline.subtracting(range)
    }
}
