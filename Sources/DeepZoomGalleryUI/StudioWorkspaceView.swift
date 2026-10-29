import SwiftUI
import TruongScalerCore
import MMapCanvas
import CoreExport
#if canImport(UIKit)
import UIKit
#endif

public struct StudioWorkspaceView: View {
    @Bindable public var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isInspectorPresented = false
    @State private var pendingTrash: OutputManagementRequest?
    @State private var isOptionsSheetPresented = false
    @State private var confirmingHandoff = false
    @State private var splitFraction: CGFloat = 0.5
    @State private var chromeVisible = true
    @State private var isProgressDetailsPresented = false

    public init(viewModel: StudioViewModel) {
        self.viewModel = viewModel
    }

    private var viewerHeader: some View {
        HStack {
            Button { dismiss() } label: { ViewerGlassIcon(symbol: "chevron.left") }
                .accessibilityLabel("Back to library")
                .accessibilityIdentifier("viewerBack")
            Spacer()
            Text(viewerCounterText).font(.caption).foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button { isInspectorPresented = true } label: { ViewerGlassIcon(symbol: "info") }
                .disabled(viewModel.metadata == nil || !viewModel.inputPreviewMatchesSelection)
                .accessibilityLabel("Photo information")
        }
        .padding(.horizontal, 8)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    public var body: some View {
        let viewerShare = viewModel.shareBinding(for: .viewer)
        ZStack {
            Color.black.ignoresSafeArea()
            #if canImport(UIKit)
            if let input = viewModel.viewerInputURL {
                InputPhotoBrowserSurface(viewModel: viewModel, requestedURL: input,
                    toggleChrome: { chromeVisible.toggle() }, dismiss: { dismiss() })
                    .ignoresSafeArea()
                    .opacity(viewModel.currentStage == .readyForInspection ? 0 : 1)
                    .allowsHitTesting(viewModel.currentStage != .readyForInspection)
            }
            #endif
            if let sourceBuffer = viewModel.sourceBuffer, let metadata = viewModel.metadata {
                ZStack {
                    if let outputBuffer = viewModel.outputBuffer, viewModel.currentStage == .readyForInspection {
                        SynchronizedSplitZoomView(
                            sourceBuffer: sourceBuffer,
                            outputBuffer: outputBuffer,
                            scaleFactor: viewModel.scaleFactor.rawValue,
                            grainAmount: viewModel.viewerGrainAmount,
                            splitFraction: $splitFraction,
                            onSingleTap: { chromeVisible.toggle() },
                            onStep: viewModel.isProcessing ? nil : { viewModel.stepPhoto($0) },
                            onDismiss: { dismiss() }
                        )
                        .ignoresSafeArea()
                    } else if viewModel.viewerInputURL == nil {
                        SynchronizedSplitZoomView(
                            sourceBuffer: sourceBuffer,
                            outputBuffer: sourceBuffer,
                            scaleFactor: 1,
                            grainAmount: 0.0,
                            splitFraction: .constant(0.0),
                            onSingleTap: { chromeVisible.toggle() },
                            onStep: viewModel.isProcessing ? nil : { viewModel.stepPhoto($0) },
                            onDismiss: { dismiss() }
                        )
                        .ignoresSafeArea()
                    }

                    if chromeVisible {
                        VStack {
                            viewerHeader

                            Spacer()

                            // Single-line camera settings below photo (1/20s · ISO 1000 · f/1.6 · 26 mm)
                            PhotoSettingsBelowImage(metadata: metadata)
                                .opacity(viewModel.inputPreviewMatchesSelection ? 1 : 0)
                                .padding(.bottom, 6)

                            viewerBottomBar
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // Ingestion and Stop/reselection can temporarily remove both buffers. Navigation
                // must remain available even if decode fails or is cancelled; an empty black cover
                // previously trapped the user with no Back control.
                VStack(spacing: 18) {
                    viewerHeader
                    Spacer()
                    if viewModel.currentStage == .ingestingAndDecodingStrips {
                        if viewModel.viewerInputURL == nil {
                            ProgressView("Opening photo…").tint(.white)
                                .accessibilityIdentifier("output-photo-loading")
                        }
                    } else if viewModel.viewerInputURL == nil || viewModel.currentStage == .failed {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                        Text(viewModel.errorMessage ?? "The photo is not open.")
                            .multilineTextAlignment(.center)
                        if viewModel.sourceURL != nil {
                            Button("Try opening again") {
                                Task { await viewModel.retryOpeningCurrentPhoto() }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    Spacer()
                    if viewModel.viewerInputURL != nil { viewerBottomBar }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("viewerRecovery")
                .simultaneousGesture(DragGesture(minimumDistance: 50).onEnded { value in
                    if value.translation.height > 80 && value.translation.height > abs(value.translation.width) { dismiss() }
                })
            }
        }
        .overlay(alignment: .top) {
            if let reason = viewModel.comparisonUnavailableReason {
                Text(reason).font(.footnote).padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal).padding(.top, 60)
                    .accessibilityIdentifier("comparison-unavailable")
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .onChange(of: viewModel.isStopping) { _, stopping in
            if !stopping { chromeVisible = true }
        }
        .onChange(of: viewModel.sourceURL) { _, _ in chromeVisible = true; pendingTrash = nil }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .safeAreaInset(edge: .bottom) {
            if viewModel.isProcessing || viewModel.isBatchProcessing {
                ProcessingProgressBarView(
                    progress: viewModel.jobProgress,
                    onStop: { viewModel.cancelProcessing() },
                    onShowDetails: { isProgressDetailsPresented = true }
                )
            }
        }
        .sheet(isPresented: $isProgressDetailsPresented) {
            ProcessingDetailsSheet(progress: viewModel.jobProgress)
        }
        .confirmationDialog("Send to TruongNoiser?", isPresented: $confirmingHandoff, titleVisibility: .visible) {
            Button("Open in TruongNoiser") {
                Task { await viewModel.sendToTruongNoiser() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The 16-bit linear DNG and its original camera metadata will open directly in TruongNoiser with zero recompression.")
        }
        #if canImport(UIKit)
        .background { NativePhotoSharePresenter(session: viewerShare, onDismiss: { viewModel.shareDidDisappear(surface: .viewer, sessionID: $0) }) }
        #endif
        .sheet(isPresented: $isInspectorPresented) {
            if let metadata = viewModel.inspectionMetadata {
                MetadataInspectorSheet(
                    metadata: metadata,
                    sourceFilename: viewModel.inspectionFilename,
                    outputDimensionsText: viewModel.inspectionDimensionsText,
                    pipelineSummaryText: "",
                    upscaleModelText: viewModel.inspectionModelLabel,
                    fileByteCountOverride: viewModel.inspectionByteCount
                )
            }
        }
        .sheet(isPresented: $isOptionsSheetPresented) {
            UpscaleOptionsFormSheet(
                viewModel: viewModel,
                onPickFileOrFolder: { isOptionsSheetPresented = false; dismiss() }
            )
        }
    }

    private var viewerBottomBar: some View {
        HStack {
            Button {
                viewModel.stepPhoto(-1)
            } label: {
                ViewerGlassIcon(symbol: "chevron.left")
            }
            .disabled(!viewModel.canStepPhoto(-1))
            .accessibilityLabel("Previous photo")

            Spacer()

            HStack(spacing: 10) {
                if viewModel.canTrashDisplayedOutput {
                    Button(role: .destructive) { pendingTrash = viewModel.displayedTrashRequest() } label: { ViewerGlassIcon(symbol: "trash") }
                        .accessibilityLabel("Delete processed photo")
                        .background {
                            GalleryTrashConfirmation(requestID: pendingTrash?.id, count: pendingTrash?.count ?? 0,
                                onConfirm: { id in
                                    guard let request = pendingTrash, request.id == id else { return }
                                    pendingTrash = nil
                                    Task { await viewModel.trashOutputs(request) }
                                }, onDismiss: { id in if pendingTrash?.id == id { pendingTrash = nil } })
                        }
                }
                if !viewModel.isProcessedPhoto {
                    Button { isOptionsSheetPresented = true } label: {
                        ViewerGlassIcon(symbol: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Upscale options")
                }

                Button {
                    confirmingHandoff = true
                } label: {
                    ViewerGlassIcon(symbol: "arrow.up.forward.app")
                }
                .disabled(viewModel.isProcessing || viewModel.metadata == nil)
                .accessibilityLabel("Send to TruongNoiser")

                Button {
                    viewModel.stepPhoto(1)
                } label: {
                    ViewerGlassIcon(symbol: "chevron.right")
                }
                .disabled(!viewModel.canStepPhoto(1))
                .accessibilityLabel("Next photo")
            }
        }
        .overlay {
            if viewModel.currentStage == .readyForInspection {
                Button {
                    Task { await viewModel.exportFinalImage(presentShareSheet: true) }
                } label: {
                    ViewerGlassIcon(symbol: "square.and.arrow.up")
                }
                .disabled(viewModel.isPreparingShare || viewModel.shareSession != nil)
                .accessibilityLabel(viewModel.isPreparingShare ? "Preparing share…" : "Export upscaled photo")
            } else {
                Button {
                    viewModel.startProcessing()
                } label: {
                    ViewerGlassIcon(symbol: "sparkles")
                }
                .disabled(viewModel.metadata == nil || viewModel.isProcessing || viewModel.isBatchProcessing || viewModel.currentStage == .ingestingAndDecodingStrips || !viewModel.inputPreviewMatchesSelection)
                .accessibilityLabel("Run upscale")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var viewerCounterText: String {
        let displayed = viewModel.viewerInputURL == nil ? viewModel.sourceURL : (viewModel.displayedInputURL ?? viewModel.sourceURL)
        if let displayed, let idx = viewModel.orderedLibraryItems.firstIndex(where: { $0.fileURL == displayed }) {
            return "\(idx + 1) / \(viewModel.orderedLibraryItems.count)"
        }
        return "1 / 1"
    }
}

// MARK: - Native Inset-Grouped Options & Library Folder Sheet (Exact TruongCam FolderSheet / ToolsSheet Style)

public struct UpscaleOptionsFormSheet: View {
    @Bindable public var viewModel: StudioViewModel
    public let onPickFileOrFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingStopUsingFolder = false
    @State private var choosingOutputFolder = false

    public init(viewModel: StudioViewModel, onPickFileOrFolder: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onPickFileOrFolder = onPickFileOrFolder
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Location", value: viewModel.libraryLocationLabel)
                    LabeledContent("Status", value: viewModel.libraryStatusLine)
                    LabeledContent("Input photos", value: "\(viewModel.daySections.reduce(0) { $0 + $1.items.count })")
                } header: {
                    Text("Input folder")
                } footer: {
                    Text("Read originals from any folder, including a TruongCam library. Processed photos save to your separate output folder.")
                }

                if let recovery = viewModel.savedLibraryRecoveryMessage {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(recovery)
                                .font(.footnote)
                        }
                        if viewModel.hasSavedLibraryBookmark {
                            Button("Reconnect saved folder") {
                                Task { await viewModel.reconnectSavedLibraryFolder() }
                            }
                            .frame(minHeight: 44)
                        }
                        Button("Choose a different folder") {
                            onPickFileOrFolder()
                        }
                        .frame(minHeight: 44)
                    } header: {
                        Text("Saved folder needs attention")
                    } footer: {
                        Text("Your saved selection has not been deleted. Reconnect it, choose another folder, or stop using it explicitly.")
                    }
                }

                Section {
                    Button("Select or reconnect folder") {
                        onPickFileOrFolder()
                    }
                    .frame(minHeight: 44)

                    if viewModel.hasSavedLibraryBookmark || viewModel.libraryFolderURL != nil {
                        Button("Stop using this folder", role: .destructive) {
                            confirmingStopUsingFolder = true
                        }
                        .frame(minHeight: 44)
                    }
                } footer: {
                    Text("Choose a folder in Files. A folder outside TruongScaler survives deleting the app. Keep its storage provider available.")
                }

                Section("Output folder") {
                    LabeledContent("Location", value: viewModel.outputLocationLabel)
                    Text(viewModel.outputStatusLine).font(.footnote).foregroundStyle(.secondary)
                    Button("Choose output folder") { choosingOutputFolder = true }
                        .frame(minHeight: 44)
                        .disabled(viewModel.isProcessing)
                }

                Section {
                    LabeledContent("Upscale", value: "2×")
                    Picker("Model", selection: $viewModel.selectedModel) {
                        ForEach(BackboneModelKind.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .disabled(viewModel.isProcessing)
                    Text(viewModel.selectedModel.processingHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let metadata = viewModel.metadata {
                        let factor = ScalerSRPolicy.scaleFactor.rawValue
                        let (width, widthOverflow) = metadata.originalWidth.multipliedReportingOverflow(by: factor)
                        let (height, heightOverflow) = metadata.originalHeight.multipliedReportingOverflow(by: factor)
                        if !widthOverflow, !heightOverflow, width > 0, height > 0 {
                            LabeledContent("Result", value: "\(width) × \(height) · \(String(format: "%.1f", Double(width) * Double(height) / 1_000_000)) MP")
                        }
                    }

                    LabeledContent("Processing", value: ScalerSRPolicy.summary)

                    Picker("Output format", selection: $viewModel.exportFormat) {
                        ForEach(ExportFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    Text(viewModel.exportFormat.shortHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Upscale settings")
                } footer: {
                    Text("Doubles the width and height for four times as many pixels. Photos use 16-bit linear Display P3; TIFF/DNG preserve HDR highlights, and 16-bit PNG is SDR-only.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Natural grain")
                            Spacer()
                            Text("\(Int(viewModel.grainRetention * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $viewModel.grainRetention, in: 0.0...1.0, step: 0.05)
                    }
                } header: {
                    Text("Grain & texture")
                } footer: {
                    Text("Blends Lanczos-3 source luminance with the super-resolution output in real time so fine organic film or sensor grain is preserved.")
                }

            }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Stop using this folder?",
                isPresented: $confirmingStopUsingFolder,
                titleVisibility: .visible
            ) {
                Button("Stop using this folder", role: .destructive) {
                    viewModel.releaseLibraryFolder()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("TruongScaler will forget the saved folder bookmark. Your photos and the folder itself are not deleted. You can choose the folder again at any time.")
            }
        }
        // Contextual native controls stay white like current TruongCam's RootView/ledger chrome.
        // The app AccentColor asset is the current system green and is used by system roles; do not
        // force every control green.
        .fileImporter(isPresented: $choosingOutputFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await viewModel.setOutputFolder(url: url) }
            }
        }
        .tint(.white)
    }
}
