#if canImport(UIKit)
import SwiftUI
import UIKit
import Observation

/// Display-only, bounded 2,048-pixel previews. Full RAW mmap pixels still belong to the existing
/// ingest/pipeline owner; these canvases can never become inference/export inputs.
@Observable @MainActor
final class InputPhotoBrowser {
    private(set) var image: CGImage?
    private(set) var displayedURL: URL?
    private(set) var failedURL: URL?
    private(set) var cache: [URL: CGImage] = [:]
    private var target: URL?
    private var items: [LibraryPhotoItem] = []
    private var context = ""
    private var epoch = UUID()
    private var worker: Task<Void, Never>?
    private var load: (@MainActor (URL) async -> CGImage?)?

    func request(_ url: URL, items: [LibraryPhotoItem], context: String, load: @escaping @MainActor (URL) async -> CGImage?) {
        if self.context != context { cancel(); self.context = context; image = nil; displayedURL = nil; cache = [:] }
        self.items = items; self.load = load
        failedURL = nil
        target = url
        if let cached = cache[url] { image = cached; displayedURL = url; target = nil }
        startWorker()
    }
    private func neighbors(of url: URL) -> [URL] {
        guard let index = items.firstIndex(where: { $0.fileURL == url }) else { return [] }
        return [index + 1, index - 1].filter { items.indices.contains($0) }.map { items[$0].fileURL }
    }
    private func startWorker() {
        guard worker == nil, let load else { return }
        let generation = epoch
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if epoch == generation { worker = nil } }
            while !Task.isCancelled, epoch == generation {
                let next = target ?? displayedURL.flatMap { neighbors(of: $0).first { cache[$0] == nil } }
                guard let next else { break }
                let decoded: CGImage?
                if let existing = cache[next] { decoded = existing } else { decoded = await load(next) }
                guard !Task.isCancelled, epoch == generation else { return }
                if let decoded { cache[next] = decoded }
                if target == next {
                    if let decoded { image = decoded; displayedURL = next; failedURL = nil }
                    else { failedURL = next }
                    target = nil
                } else if decoded == nil { break }
                let keep = Set(([displayedURL, target].compactMap { $0 }) + (displayedURL.map { neighbors(of: $0) } ?? []))
                cache = cache.filter { keep.contains($0.key) }
                // At most current + two neighbors, including a foreground target during a rapid swipe.
                while cache.count > 3, let obsolete = cache.keys.first(where: { $0 != displayedURL && $0 != target }) { cache[obsolete] = nil }
            }
        }
    }
    func cancel() { epoch = UUID(); worker?.cancel(); worker = nil; target = nil }
    func releaseIdlePreviews() {
        let requested = target
        cancel()
        cache = cache.filter { $0.key == displayedURL }
        if let requested { target = requested; startWorker() }
    }
}

struct InputPhotoBrowserSurface: View {
    let viewModel: StudioViewModel
    let requestedURL: URL
    let toggleChrome: () -> Void
    let dismiss: () -> Void
    @State private var browser = InputPhotoBrowser()
    @State private var delayedLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var items: [LibraryPhotoItem] { viewModel.daySections.flatMap(\.items) }
    private var context: String { viewModel.inputBrowsingContext }
    private func adjacent(_ delta: Int) -> LibraryPhotoItem? {
        guard let url = browser.displayedURL, let index = items.firstIndex(where: { $0.fileURL == url }), items.indices.contains(index + delta) else { return nil }
        return items[index + delta]
    }
    var body: some View {
        ZStack {
            Color.black
            if browser.failedURL == requestedURL, viewModel.sourceURL == requestedURL, let buffer = viewModel.sourceBuffer {
                // Some supported RAW/Linear DNG containers have no ImageIO display thumbnail.
                // The full decoder can still succeed; retain its real renderer as a safe fallback.
                SynchronizedSplitZoomView(sourceBuffer: buffer, outputBuffer: buffer, scaleFactor: 1, grainAmount: 0,
                    splitFraction: .constant(0), onSingleTap: toggleChrome,
                    onStep: viewModel.isProcessing ? nil : { viewModel.stepPhoto($0) }, onDismiss: dismiss)
                    .onAppear { viewModel.inputPreviewDidDisplay(requestedURL) }
            } else if let image = browser.image, let url = browser.displayedURL {
                InteractiveOriginalPager(image: image, captureID: url.absoluteString,
                    position: items.firstIndex(where: { $0.fileURL == url }) ?? 0,
                    previousCaptureID: adjacent(-1)?.fileURL.absoluteString, nextCaptureID: adjacent(1)?.fileURL.absoluteString,
                    previousPage: page(-1), nextPage: page(1), hasPrevious: adjacent(-1) != nil, hasNext: adjacent(1) != nil,
                    navigationEnabled: !viewModel.isProcessing && !viewModel.isBatchProcessing && !viewModel.isPreparingShare && viewModel.shareSession == nil,
                    context: ViewerPagingContext(revision: context, rootURL: viewModel.libraryFolderURL), reduceMotion: reduceMotion,
                    toggleChrome: toggleChrome, previous: { step(-1) }, next: { step(1) },
                    selectPage: { displayed, target in
                        guard browser.displayedURL?.absoluteString == displayed,
                              let item = [adjacent(-1), adjacent(1)].compactMap({ $0 }).first(where: { $0.fileURL.absoluteString == target }) else { return false }
                        select(item); return true
                    }, dismissViewer: dismiss)
            } else if delayedLoading { ProgressView().tint(.white) }
        }
        .task(id: requestedURL.absoluteString + context) {
            delayedLoading = false
            browser.request(requestedURL, items: items, context: context) { await viewModel.loadInputDisplayPreview(at: $0) }
            viewModel.inputPreviewDidDisplay(browser.displayedURL)
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled, browser.image == nil { delayedLoading = true }
        }
        .onChange(of: browser.displayedURL) { _, url in viewModel.inputPreviewDidDisplay(url) }
        .onDisappear { browser.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in browser.releaseIdlePreviews() }
        .accessibilityIdentifier("inputPhotoBrowser")
    }
    private func page(_ delta: Int) -> ViewerAdjacentPage? {
        guard let item = adjacent(delta), let image = browser.cache[item.fileURL] else { return nil }
        return ViewerAdjacentPage(captureID: item.fileURL.absoluteString, image: image)
    }
    private func step(_ delta: Int) { if let item = adjacent(delta) { select(item) } }
    private func select(_ item: LibraryPhotoItem) {
        // Identity/pixels change only after a correctly associated preview arrives. The existing
        // full-resolution ingest keeps its own generation and processing remains disabled until ready.
        browser.request(item.fileURL, items: items, context: context) { await viewModel.loadInputDisplayPreview(at: $0) }
        Task { await viewModel.openLibraryPhoto(item) }
    }
}
#endif
