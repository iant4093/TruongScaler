import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers
import TruongScalerCore

public struct LibraryPhotoItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let fileURL: URL
    public let filename: String
    public let capturedAt: Date
    public let byteCount: Int64
    public let badgeLabel: String?
    public let collection: LibraryCollection

    public init(
        id: String,
        fileURL: URL,
        filename: String,
        capturedAt: Date,
        byteCount: Int64,
        badgeLabel: String? = nil,
        collection: LibraryCollection = .input
    ) {
        self.id = id
        self.fileURL = fileURL
        self.filename = filename
        self.capturedAt = capturedAt
        self.byteCount = byteCount
        self.badgeLabel = badgeLabel
        self.collection = collection
    }
}

public struct LibraryDaySection: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayTitle: String
    public let items: [LibraryPhotoItem]

    public var originalCount: Int { items.count }

    public init(id: String, displayTitle: String, items: [LibraryPhotoItem]) {
        self.id = id
        self.displayTitle = displayTitle
        self.items = items
    }
}

public struct LibraryScreen: View {
    @Bindable public var viewModel: StudioViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isViewerPresented = false
    @State private var isProgressDetailsPresented = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var isFolderSheetPresented = false
    @State private var isFileImporterPresented = false
    @State private var pendingTrash: OutputManagementRequest?
    @State private var isTrashPresented = false
    @State private var selectionFrames: [String: CGRect] = [:]

    public init(viewModel: StudioViewModel) {
        self.viewModel = viewModel
    }

    private var trailingToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    public var body: some View {
        let libraryShare = isViewerPresented ? nil : viewModel.shareBinding(for: .library)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    FolderStatusRow(
                        locationLabel: viewModel.selectedCollection == .input ? viewModel.libraryLocationLabel : viewModel.outputLocationLabel,
                        statusLine: viewModel.selectedCollection == .input ? viewModel.libraryStatusLine : viewModel.outputStatusLine,
                        isReady: viewModel.visibleFolderURL != nil,
                        recoveryActive: viewModel.selectedCollection == .input ? viewModel.savedLibraryRecoveryMessage != nil : viewModel.savedOutputRecoveryMessage != nil,
                        isValidating: viewModel.selectedCollection == .input ? viewModel.isValidatingLibraryFolder : viewModel.isValidatingOutputFolder,
                        onTap: {
                            isFolderSheetPresented = true
                        }
                    )

                    if viewModel.selectedCollection == .input, let recoveryMessage = viewModel.savedLibraryRecoveryMessage {
                        SavedFolderRecoveryRow(
                            message: recoveryMessage,
                            canReconnect: viewModel.hasSavedLibraryBookmark,
                            onReconnect: { Task { await viewModel.reconnectSavedLibraryFolder() } },
                            onChangeFolder: {
                                isFolderSheetPresented = false
                                isFileImporterPresented = true
                            }
                        )
                    }

                    if let errorMessage = viewModel.errorMessage {
                        LibraryInlineNotice(message: errorMessage) {
                            viewModel.errorMessage = nil
                        }
                    }

                    if !viewModel.visibleDaySections.isEmpty {
                        if isSelecting {
                            Text("Select photos")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }

                        ForEach(viewModel.visibleDaySections) { group in
                            Section {
                                LazyVGrid(
                                    columns: Array(
                                        repeating: GridItem(.flexible(), spacing: 3),
                                        count: dynamicTypeSize.isAccessibilitySize ? 2 : 3
                                    ),
                                    spacing: 4
                                ) {
                                    ForEach(group.items) { item in
                                        LibraryThumbnailCell(
                                            item: item,
                                            isSelecting: isSelecting,
                                            isSelected: selectedIDs.contains(item.id),
                                            loadThumbnail: { item, maxPixelSize in
                                                await viewModel.loadLibraryThumbnail(
                                                    for: item,
                                                    maxPixelSize: maxPixelSize
                                                )
                                            }
                                        ) {
                                            if isSelecting {
                                                if !selectedIDs.insert(item.id).inserted {
                                                    selectedIDs.remove(item.id)
                                                }
                                            } else {
                                                Task {
                                                    // Present a navigable loading state immediately. Waiting until
                                                    // decode finished used to reopen a dismissed cover late, or
                                                    // present a completely empty cover after a failed decode.
                                                    isViewerPresented = true
                                                    await viewModel.openLibraryPhoto(item)
                                                }
                                            }
                                        }
                                        .disabled(viewModel.isProcessing || viewModel.isBatchProcessing || viewModel.isManagingOutput || pendingTrash != nil)
                                        .background { GeometryReader { proxy in
                                            Color.clear.preference(key: GalleryCellFrames.self, value: [item.id: proxy.frame(in: .named("gallery-selection"))])
                                        } }
                                    }
                                }
                                .padding(.horizontal, 3)
                            } header: {
                                DayHeader(title: group.displayTitle, count: group.originalCount)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            viewModel.selectedCollection == .input ? "No input photos" : "No processed photos yet",
                            systemImage: viewModel.selectedCollection.symbol,
                            description: Text(viewModel.selectedCollection == .input
                                ? "Choose any folder with RAWs or images, including a TruongCam library. Use the folder menu to open a single photo."
                                : "Completed upscales appear here automatically. Choose an output folder to keep results and their before/after comparisons.")
                        )
                        .padding(.top, 40)
                        .accessibilityIdentifier("emptyLibrary")
                    }
                }
                .coordinateSpace(name: "gallery-selection")
                .onPreferenceChange(GalleryCellFrames.self) { selectionFrames = $0 }
                .background {
                    GallerySelectionGesture(frames: selectionFrames, orderedIDs: viewModel.visibleDaySections.flatMap(\.items).map(\.id),
                        selectedIDs: $selectedIDs, context: viewModel.gallerySelectionContext,
                        isEnabled: isSelecting && !viewModel.isProcessing && !viewModel.isBatchProcessing && !viewModel.isManagingOutput && pendingTrash == nil)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { value in
                guard !isSelecting, abs(value.translation.width) > abs(value.translation.height) * 1.5,
                      abs(value.translation.width) > 55 else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    viewModel.selectedCollection = value.translation.width < 0 ? .output : .input
                }
            })
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(viewModel.selectedCollection == .input ? "Input photos" : "Processed photos")
            .toolbar {
                ToolbarItem(placement: trailingToolbarPlacement) {
                    Button(isSelecting ? "Done" : "Select") {
                        selectedIDs.removeAll()
                        isSelecting.toggle()
                    }
                    .frame(minHeight: 44)
                    .disabled(viewModel.isProcessing || viewModel.visibleDaySections.isEmpty)
                    .accessibilityLabel(isSelecting ? "Done selecting" : "Select photos")
                    .accessibilityIdentifier("librarySelect")
                }

                #if os(iOS)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                #endif

                ToolbarItem(placement: trailingToolbarPlacement) {
                    if viewModel.selectedCollection == .output {
                        Button { isTrashPresented = true } label: { Label("Recently Deleted", systemImage: "trash") }
                            .accessibilityIdentifier("outputRecentlyDeleted")
                    }
                }
                ToolbarItem(placement: trailingToolbarPlacement) {
                    Button {
                        isFolderSheetPresented = true
                    } label: {
                        Label("Folder", systemImage: "folder")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("libraryFolder")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if viewModel.isProcessing || viewModel.isBatchProcessing {
                        ProcessingProgressBarView(progress: viewModel.jobProgress,
                            onStop: { viewModel.cancelProcessing() },
                            onShowDetails: { isProgressDetailsPresented = true })
                    } else if isSelecting { selectionActionsBar }
                    HStack {
                        Spacer(minLength: 0)
                        LibraryCollectionBar(selection: $viewModel.selectedCollection)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: viewModel.gallerySelectionContext) { _, _ in selectedIDs = []; pendingTrash = nil; isSelecting = false }
            .onChange(of: viewModel.selectedCollection) { _, _ in
                selectedIDs.removeAll()
                pendingTrash = nil
                isSelecting = false
                Task { await viewModel.reloadVisibleLibrary() }
            }
            .sheet(isPresented: $isTrashPresented) { RecentlyDeletedView(viewModel: viewModel) }
            .sheet(isPresented: $viewModel.isOutputSetupPresented) {
                OutputFolderSetupView(viewModel: viewModel)
            }
            .refreshable {
                await viewModel.reloadVisibleLibrary()
            }
            .sheet(isPresented: $isProgressDetailsPresented) {
                ProcessingDetailsSheet(progress: viewModel.jobProgress)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $isViewerPresented, onDismiss: { viewModel.viewerDidDismiss() }) {
                StudioWorkspaceView(viewModel: viewModel)
            }
            #else
            .sheet(isPresented: $isViewerPresented, onDismiss: { viewModel.viewerDidDismiss() }) {
                StudioWorkspaceView(viewModel: viewModel)
            }
            #endif
            .sheet(isPresented: $isFolderSheetPresented) {
                UpscaleOptionsFormSheet(
                    viewModel: viewModel,
                    onPickFileOrFolder: {
                        isFolderSheetPresented = false
                        isFileImporterPresented = true
                    }
                )
            }
            #if canImport(UIKit)
            .background { NativePhotoSharePresenter(session: libraryShare, onDismiss: { viewModel.shareDidDisappear(surface: .library, sessionID: $0) }) }
            #endif
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.image, .rawImage, .tiff, .folder]
            ) { result in
                if case .success(let url) = result {
                    Task {
                        // The view model opens the picker URL's security scope before any
                        // filesystem classification; do not call FileManager on the raw URL here.
                        let openedAsFile = await viewModel.handlePickedURL(url)
                        if openedAsFile {
                            isViewerPresented = true
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private var selectionActionsBar: some View {
        HStack(spacing: 16) {
            Button("Select loaded") {
                let allIDs = viewModel.visibleDaySections.flatMap(\.items).map(\.id)
                selectedIDs = Set(allIDs)
            }
            Spacer(minLength: 4)
            Text("\(selectedIDs.count)")
                .monospacedDigit()
            if viewModel.selectedCollection == .input {
                Button { Task { await viewModel.batchProcessSelected(ids: selectedIDs) } } label: {
                    ViewerGlassIcon(symbol: "sparkles")
                }
                .disabled(selectedIDs.isEmpty || viewModel.isProcessing)
                .accessibilityLabel("Batch upscale selected")
            }

            if viewModel.selectedCollection == .output {
                Button(role: .destructive) { pendingTrash = viewModel.trashRequest(ids: selectedIDs) } label: {
                    ViewerGlassIcon(symbol: "trash")
                }.disabled(selectedIDs.isEmpty || !viewModel.canManageOutput || pendingTrash != nil)
                    .accessibilityLabel("Delete selected outputs")
                    .background {
                        GalleryTrashConfirmation(requestID: pendingTrash?.id, count: pendingTrash?.count ?? 0,
                            onConfirm: { id in
                                guard let request = pendingTrash, request.id == id else { return }
                                pendingTrash = nil
                                Task { await viewModel.trashOutputs(request); selectedIDs = [] }
                            }, onDismiss: { id in if pendingTrash?.id == id { pendingTrash = nil } })
                    }
            }
            Button {
                Task { await viewModel.exportSelected(ids: selectedIDs) }
            } label: {
                ViewerGlassIcon(symbol: "square.and.arrow.up")
            }
            .disabled(selectedIDs.isEmpty || viewModel.isProcessing || viewModel.isPreparingShare || viewModel.isManagingOutput)
            .accessibilityLabel("Share selected photos")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.horizontal, 12)
    }
}

/// Chosen folder path and availability, opening the same folder sheet. Mirrors current
/// TruongCam's `FolderStatusRow` status-icon roles while keeping Scaler's recovery state.
public struct FolderStatusRow: View {
    public let locationLabel: String
    public let statusLine: String
    public let isReady: Bool
    public let recoveryActive: Bool
    public let isValidating: Bool
    public let onTap: () -> Void

    public init(
        locationLabel: String,
        statusLine: String,
        isReady: Bool,
        recoveryActive: Bool = false,
        isValidating: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.locationLabel = locationLabel
        self.statusLine = statusLine
        self.isReady = isReady
        self.recoveryActive = recoveryActive
        self.isValidating = isValidating
        self.onTap = onTap
    }

    private var statusIcon: String {
        if isValidating { return "arrow.triangle.2.circlepath" }
        if recoveryActive { return "folder.badge.questionmark" }
        return isReady ? "folder.fill" : "folder"
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(locationLabel)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected folder")
        .accessibilityValue(isValidating ? "Checking folder. \(statusLine)" : "\(locationLabel). \(statusLine)")
        .accessibilityIdentifier("libraryFolderStatus")
    }
}

/// Actionable reconnect/change-folder state for a saved bookmark that could not be opened.
/// The saved bookmark is never cleared here; that requires an explicit destructive confirmation.
public struct SavedFolderRecoveryRow: View {
    public let message: String
    public let canReconnect: Bool
    public let onReconnect: () -> Void
    public let onChangeFolder: () -> Void

    public init(
        message: String,
        canReconnect: Bool,
        onReconnect: @escaping () -> Void,
        onChangeFolder: @escaping () -> Void
    ) {
        self.message = message
        self.canReconnect = canReconnect
        self.onReconnect = onReconnect
        self.onChangeFolder = onChangeFolder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if canReconnect {
                    Button("Reconnect", action: onReconnect)
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityHint("Retries access to the folder you previously selected.")
                }
                Button("Choose folder", action: onChangeFolder)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("savedFolderRecovery")
    }
}

/// Inline, dismissible app error (for example a background-continuation refusal). Foreground
/// processing stays usable; this never blocks the library.
public struct LibraryInlineNotice: View {
    public let message: String
    public let onDismiss: () -> Void

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: onDismiss)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }
}

public struct DayHeader: View {
    public let title: String
    public let count: Int

    public init(title: String, count: Int) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) photos")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

public struct LibraryThumbnailCell: View {
    public let item: LibraryPhotoItem
    public let isSelecting: Bool
    public let isSelected: Bool
    /// The owning view model's selected-root thumbnail read. It captures the current library scope,
    /// holds its own grant through ImageIO, and returns nil for a superseded/cancelled read.
    public let loadThumbnail: @MainActor (LibraryPhotoItem, Int) async -> CGImage?
    public let onTap: () -> Void

    @State private var thumbnailImage: CGImage?
    @State private var thumbnailFinished = false
    @State private var requestGeneration: UInt64 = 0

    public init(
        item: LibraryPhotoItem,
        isSelecting: Bool,
        isSelected: Bool,
        loadThumbnail: @escaping @MainActor (LibraryPhotoItem, Int) async -> CGImage?,
        onTap: @escaping () -> Void
    ) {
        self.item = item
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.loadThumbnail = loadThumbnail
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let cgImage = thumbnailImage {
                            Image(decorative: cgImage, scale: 1.0)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                        } else if thumbnailFinished {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        } else {
                            ProgressView().tint(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipped()

                if let badge = item.badgeLabel {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay {
                if isSelected {
                    Color.gray.opacity(0.32).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .blue : .white)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.filename)
        .accessibilityValue(
            (isSelecting ? (isSelected ? "Selected" : "Not selected") : "Original photo")
                + (item.badgeLabel.map { ", \($0)" } ?? "")
        )
        .accessibilityHint(isSelecting ? "Double-tap to toggle selection." : "Double-tap to open the split viewer.")
        .task(id: item) {
            // Request identity: a cancelled/replaced read must never replace the newer item's image.
            requestGeneration &+= 1
            let request = requestGeneration
            thumbnailImage = nil
            thumbnailFinished = false
            let image = await loadThumbnail(item, 256)
            guard !Task.isCancelled, request == requestGeneration else { return }
            thumbnailImage = image
            thumbnailFinished = true
        }
    }
}
