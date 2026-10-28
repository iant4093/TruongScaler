import SwiftUI
import CoreGraphics

/// Same three-column gallery, selection sweep, focused preview and anchored actions as TruongCam.
public struct RecentlyDeletedView: View {
    @Bindable var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var frames: [String: CGRect] = [:]
    @State private var focused: UUID?
    @State private var pending: TrashManagementRequest?
    private var rootKey: String { viewModel.outputBrowsingContext }
    private var targets: Set<UUID> {
        if let focused { return [focused] }
        return Set(viewModel.recentlyDeleted.filter { !selecting || selected.contains($0.id.uuidString) }.map(\.id))
    }
    public var body: some View {
        NavigationStack {
            Group {
                if let id = focused, let entry = viewModel.recentlyDeleted.first(where: { $0.id == id }) {
                    DeletedPhotoPreview(entry: entry,
                        loadThumbnail: { await viewModel.loadTrashThumbnail($0, maxPixelSize: 2048) },
                        previous: { step(-1) }, next: { step(1) }, close: { focused = nil })
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if viewModel.recentlyDeleted.isEmpty { ContentUnavailableView("No Recently Deleted Photos", systemImage: "trash") }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 3) {
                                ForEach(viewModel.recentlyDeleted) { entry in
                                    LibraryThumbnailCell(item: item(entry), isSelecting: selecting, isSelected: selected.contains(entry.id.uuidString),
                                        loadThumbnail: { _, size in await viewModel.loadTrashThumbnail(entry, maxPixelSize: size) }) {
                                            guard viewModel.canManageOutput, pending == nil else { return }
                                            if selecting { if !selected.insert(entry.id.uuidString).inserted { selected.remove(entry.id.uuidString) } }
                                            else { focused = entry.id }
                                        }
                                        .background { GeometryReader { proxy in Color.clear.preference(key: GalleryCellFrames.self,
                                            value: [entry.id.uuidString: proxy.frame(in: .named("trash-selection"))]) } }
                                }
                            }
                            .padding(.horizontal, 3)
                            .coordinateSpace(name: "trash-selection")
                            .onPreferenceChange(GalleryCellFrames.self) { frames = $0 }
                            .background { GallerySelectionGesture(frames: frames, orderedIDs: viewModel.recentlyDeleted.map { $0.id.uuidString },
                                selectedIDs: $selected, context: rootKey, isEnabled: selecting && viewModel.canManageOutput && pending == nil) }
                            Text("Photos stay here until you recover or permanently delete them.")
                                .font(.footnote).foregroundStyle(.secondary).padding()
                        }
                    }
                }
            }
            .background {
                #if canImport(UIKit)
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                #else
                Color(.sRGB, white: 0.11, opacity: 1).ignoresSafeArea()
                #endif
            }
            .navigationTitle(focused == nil ? "Recently Deleted" : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if focused != nil { Button { focused = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Back to Recently Deleted") }
                    else { Button(selecting ? "Done" : "Select") { selected = []; selecting.toggle() }.disabled(viewModel.recentlyDeleted.isEmpty) }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back to folders")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(focused != nil ? "Recover" : selecting ? "Recover Selected" : "Recover All") {
                        pending = viewModel.trashManagementRequest(ids: targets, permanent: false)
                    }
                    .disabled(targets.isEmpty || pending != nil || !viewModel.canManageOutput || viewModel.recentlyDeleted.contains { targets.contains($0.id) && !$0.canRestore })
                    .background { confirmation(permanent: false) }
                    Spacer()
                    if selecting { Text("\(selected.count)").monospacedDigit() }
                    Spacer()
                    Button(focused != nil ? "Delete" : selecting ? "Delete Selected" : "Delete All", role: .destructive) {
                        pending = viewModel.trashManagementRequest(ids: targets, permanent: true)
                    }
                    .disabled(targets.isEmpty || pending != nil || !viewModel.canManageOutput)
                    .background { confirmation(permanent: true) }
                }
                .frame(minHeight: 44).padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            }
            .overlay(alignment: .top) {
                if let error = viewModel.errorMessage { LibraryInlineNotice(message: error) { viewModel.errorMessage = nil } }
            }
            .task { await viewModel.reloadRecentlyDeleted() }
            .onChange(of: rootKey) { _, _ in selected = []; focused = nil; pending = nil }
            .onChange(of: viewModel.recentlyDeleted) { _, entries in
                selected.formIntersection(Set(entries.map { $0.id.uuidString }))
                if let id = focused, !entries.contains(where: { $0.id == id }) { focused = nil }
            }
        }.tint(.white).preferredColorScheme(.dark)
    }
    private func confirmation(permanent: Bool) -> some View {
        GalleryTrashConfirmation(requestID: pending?.permanent == permanent ? pending?.id : nil,
            count: pending?.count ?? 0, onConfirm: { id in
                guard let request = pending, request.id == id else { return }
                pending = nil
                Task { await viewModel.manageTrash(request); selected = []; focused = nil }
            }, onDismiss: { id in if pending?.id == id { pending = nil } }, kind: permanent ? .permanentlyDelete : .recover)
    }
    private func item(_ entry: OutputTrashEntry) -> LibraryPhotoItem {
        LibraryPhotoItem(id: entry.id.uuidString, fileURL: (viewModel.outputFolderURL ?? URL(fileURLWithPath: "/"))
            .appendingPathComponent(entry.directory + "/" + (entry.files.first?.storedName ?? "missing")),
            filename: entry.filename, capturedAt: entry.deletedAt, byteCount: entry.byteCount,
            badgeLabel: entry.canRestore ? nil : "Retry deletion", collection: .output)
    }
    private func step(_ delta: Int) {
        guard let id = focused, let i = viewModel.recentlyDeleted.firstIndex(where: { $0.id == id }),
              viewModel.recentlyDeleted.indices.contains(i + delta) else { return }
        focused = viewModel.recentlyDeleted[i + delta].id
    }
}

struct DeletedPhotoPreview: View {
    let entry: OutputTrashEntry
    let loadThumbnail: (OutputTrashEntry) async -> CGImage?
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @State private var image: CGImage?
    @State private var loading = false
    var body: some View {
        ZStack {
            Color.black
            #if canImport(UIKit)
            if let image { ZoomableOriginalView(image: image, toggleChrome: {}, previous: previous, next: next,
                dismissalEnabled: true, dismissViewer: close).ignoresSafeArea() }
            else if loading { ProgressView().tint(.white) }
            else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            #else
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            #endif
        }
        .task(id: entry.id) {
            guard !Task.isCancelled else { return }
            loading = true
            image = nil
            let thumbnail = await loadThumbnail(entry)
            // Cancelling the old task does not cancel an in-flight disk read. Its eventual nil
            // result must not clear the photo or loading state belonging to the next selection.
            guard !Task.isCancelled else { return }
            image = thumbnail
            loading = false
        }
    }
}
