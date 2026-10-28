import SwiftUI
import TruongScalerCore
import MMapCanvas

public struct SynchronizedSplitZoomView: View {
    public let sourceBuffer: MMapBuffer
    public let outputBuffer: MMapBuffer
    public let scaleFactor: Int
    public let grainAmount: Float
    @Binding public var splitFraction: CGFloat
    public var onSingleTap: (() -> Void)?
    public var onStep: ((Int) -> Void)?
    public var onDismiss: (() -> Void)?

    public init(
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer,
        scaleFactor: Int,
        grainAmount: Float,
        splitFraction: Binding<CGFloat>,
        onSingleTap: (() -> Void)? = nil,
        onStep: ((Int) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.sourceBuffer = sourceBuffer
        self.outputBuffer = outputBuffer
        self.scaleFactor = scaleFactor
        self.grainAmount = grainAmount
        self._splitFraction = splitFraction
        self.onSingleTap = onSingleTap
        self.onStep = onStep
        self.onDismiss = onDismiss
    }

    public var body: some View {
        #if canImport(UIKit)
        SplitZoomScrollRepresentable(
            sourceBuffer: sourceBuffer, outputBuffer: outputBuffer,
            scaleFactor: scaleFactor, grainAmount: grainAmount,
            splitFraction: $splitFraction, onSingleTap: onSingleTap, onStep: onStep, onDismiss: onDismiss
        )
        #else
        Color.black
        #endif
    }
}

#if canImport(UIKit)
import UIKit

/// Scroll view whose layout is the authoritative trigger for the viewer's fit.
///
/// The old representable fitted only from `updateUIView`. SwiftUI can install the view with zero
/// bounds and never call another update once the real viewport arrives; comparing the zoom target's
/// transformed `frame` to the unscaled canvas then reset/re-fit while the user was zoomed. Layout and
/// window attachment are the events that actually know the viewport, so both notify the coordinator.
@MainActor
final class SplitZoomScrollView: UIScrollView {
    weak var layoutObserver: SplitZoomCoordinator?
    let comparisonOverlay = SplitComparisonOverlayView()

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutObserver?.handleLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layoutObserver?.handleLayout()
    }
}

private struct SplitZoomScrollRepresentable: UIViewRepresentable {
    let sourceBuffer: MMapBuffer
    let outputBuffer: MMapBuffer
    let scaleFactor: Int
    let grainAmount: Float
    @Binding var splitFraction: CGFloat
    let onSingleTap: (() -> Void)?
    let onStep: ((Int) -> Void)?
    let onDismiss: (() -> Void)?

    func makeCoordinator() -> SplitZoomCoordinator {
        let owner = SplitZoomCoordinator(onSingleTap: onSingleTap, onSplitChanged: { splitFraction = $0 })
        owner.onStep = onStep
        owner.onDismiss = onDismiss
        return owner
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = SplitZoomScrollView()
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator

        let canvasSize = CGSize(width: outputBuffer.width, height: outputBuffer.height)
        let container = UIView(frame: CGRect(origin: .zero, size: canvasSize))
        container.backgroundColor = .black

        let originalView = MMapTiledImageView(
            sourceBuffer: sourceBuffer,
            hatOutputBuffer: outputBuffer,
            scaleFactor: scaleFactor,
            naturalGrainAmount: grainAmount,
            renderMode: .originalNearestNeighbor
        )
        let processedView = MMapTiledImageView(
            sourceBuffer: sourceBuffer,
            hatOutputBuffer: outputBuffer,
            scaleFactor: scaleFactor,
            naturalGrainAmount: grainAmount,
            renderMode: .upscaledWithLiveGrain
        )
        originalView.frame = CGRect(origin: .zero, size: canvasSize)
        processedView.frame = CGRect(origin: .zero, size: canvasSize)

        container.addSubview(originalView)
        container.addSubview(processedView)
        scrollView.addSubview(container)
        scrollView.contentSize = canvasSize

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(SplitZoomCoordinator.handleSingleTap))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(SplitZoomCoordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = context.coordinator
        doubleTap.delegate = context.coordinator
        scrollView.addGestureRecognizer(singleTap)
        scrollView.addGestureRecognizer(doubleTap)

        let down = UIPanGestureRecognizer(target: context.coordinator, action: #selector(SplitZoomCoordinator.handleDismissPan(_:)))
        down.maximumNumberOfTouches = 1
        down.delegate = context.coordinator
        scrollView.addGestureRecognizer(down)
        scrollView.panGestureRecognizer.require(toFail: down)
        singleTap.require(toFail: down)
        doubleTap.require(toFail: down)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(SplitZoomCoordinator.handlePhotoSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = context.coordinator
            swipe.require(toFail: down)
            scrollView.addGestureRecognizer(swipe)
            scrollView.panGestureRecognizer.require(toFail: swipe)
        }

        context.coordinator.attach(
            scrollView: scrollView,
            containerView: container,
            originalView: originalView,
            processedView: processedView,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer,
            scaleFactor: scaleFactor,
            grainAmount: grainAmount,
            splitFraction: splitFraction,
            onSingleTap: onSingleTap
        )
        scrollView.layoutObserver = context.coordinator
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onStep = onStep
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onSplitChanged = { splitFraction = $0 }
        context.coordinator.update(
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer,
            scaleFactor: scaleFactor,
            grainAmount: grainAmount,
            splitFraction: splitFraction,
            onSingleTap: onSingleTap
        )
    }
}

/// The zoom/centering/split geometry owner for the production viewer.
///
/// Invariants:
/// * `canvasSize` is the *unscaled* logical image size. It never derives from a transformed frame.
/// * Fit is driven by real layout (`SplitZoomScrollView.layoutSubviews`/`didMoveToWindow`), not by
///   incidental SwiftUI configuration updates.
/// * Configuration-only updates (chrome, grain, split, progress counters) never change zoom/offset.
/// * A true image/canvas change fits the new image; a viewport change preserves the relative zoom and
///   the image-relative anchor under the viewport center.
/// * The split mask uses UIKit point conversion, so content offset, centering insets and zoom are all
///   included exactly once.
@MainActor
final class SplitZoomCoordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private struct ImageIdentity: Equatable {
        let sourcePath: String
        let outputPath: String
        let outputWidth: Int
        let outputHeight: Int
        let scaleFactor: Int
    }

    private weak var scrollView: SplitZoomScrollView?
    private weak var containerView: UIView?
    private weak var originalView: MMapTiledImageView?
    private weak var processedView: MMapTiledImageView?
    let maskLayer = CAShapeLayer()

    private(set) var canvasSize: CGSize = .zero
    private(set) var hasCompletedInitialFit = false
    var splitFraction: CGFloat = 0.5
    var onSingleTap: (() -> Void)?
    var onSplitChanged: ((CGFloat) -> Void)?
    var onStep: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private var imageIdentity: ImageIdentity?
    private var lastViewportSize: CGSize = .zero
    private var lastFitScale: CGFloat = 0
    private var isApplyingGeometry = false
    /// Normalized image point under the viewport center. Captured from real gestures/scrolls and used
    /// to keep the same content under the center across rotation/safe-area changes.
    private var centerAnchor = CGPoint(x: 0.5, y: 0.5)

    init(onSingleTap: (() -> Void)?, onSplitChanged: ((CGFloat) -> Void)? = nil) {
        self.onSingleTap = onSingleTap
        self.onSplitChanged = onSplitChanged
        super.init()
    }

    // MARK: - Attachment / configuration

    func attach(
        scrollView: SplitZoomScrollView,
        containerView: UIView,
        originalView: MMapTiledImageView,
        processedView: MMapTiledImageView,
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer,
        scaleFactor: Int,
        grainAmount: Float,
        splitFraction: CGFloat,
        onSingleTap: (() -> Void)?
    ) {
        self.scrollView = scrollView
        self.containerView = containerView
        self.originalView = originalView
        self.processedView = processedView
        self.onSingleTap = onSingleTap
        self.splitFraction = Self.clampedSplit(splitFraction)
        canvasSize = CGSize(width: outputBuffer.width, height: outputBuffer.height)
        imageIdentity = Self.identity(
            source: sourceBuffer,
            output: outputBuffer,
            scaleFactor: scaleFactor
        )
        maskLayer.frame = CGRect(origin: .zero, size: canvasSize)
        maskLayer.fillColor = UIColor.white.cgColor
        processedView.layer.mask = maskLayer
        let overlay = scrollView.comparisonOverlay
        if overlay.superview !== scrollView {
            scrollView.addSubview(overlay)
            scrollView.panGestureRecognizer.require(toFail: overlay.panGesture)
        }
        overlay.onFractionChanged = { [weak self] fraction in
            guard let self else { return }
            self.splitFraction = fraction
            self.updateMask()
            self.onSplitChanged?(fraction)
        }
        hasCompletedInitialFit = false
        lastViewportSize = .zero
        lastFitScale = 0
        handleLayout()
    }

    func update(
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer,
        scaleFactor: Int,
        grainAmount: Float,
        splitFraction: CGFloat,
        onSingleTap: (() -> Void)?
    ) {
        self.onSingleTap = onSingleTap
        let newSplit = Self.clampedSplit(splitFraction)
        let splitChanged = abs(newSplit - self.splitFraction) > 0.0001
        self.splitFraction = newSplit

        let newCanvas = CGSize(width: outputBuffer.width, height: outputBuffer.height)
        let newIdentity = Self.identity(
            source: sourceBuffer,
            output: outputBuffer,
            scaleFactor: scaleFactor
        )
        let imageChanged = newIdentity != imageIdentity

        // Renderer configuration changes (buffers, factor, grain) must never touch zoom geometry
        // unless the actual canvas/identity changed. MMapTiledImageView invalidates only its tiles.
        originalView?.updateConfiguration(
            sourceBuffer: sourceBuffer,
            hatOutputBuffer: outputBuffer,
            scaleFactor: scaleFactor,
            naturalGrainAmount: grainAmount
        )
        processedView?.updateConfiguration(
            sourceBuffer: sourceBuffer,
            hatOutputBuffer: outputBuffer,
            scaleFactor: scaleFactor,
            naturalGrainAmount: grainAmount
        )

        if imageChanged || newCanvas != canvasSize {
            applyNewCanvas(
                newCanvas,
                identity: newIdentity,
                scrollView: scrollView,
                containerView: containerView
            )
        } else if splitChanged {
            updateMask()
        }

        // A zero-bounds first update can arrive before layout; when layout later runs the scroll view
        // itself calls `handleLayout`. Calling here as well covers the reverse ordering without
        // resetting an already-fitted user zoom.
        handleLayout()
    }

    /// Installs a genuinely new logical canvas and requests a fresh fit.
    ///
    /// This is an intentional reset only for true image/canvas changes: a different photo (even at
    /// the same pixel size), or the enlarged output canvas appearing after completion. Chrome/grain/split
    /// updates never take this path.
    private func applyNewCanvas(
        _ newCanvas: CGSize,
        identity: ImageIdentity,
        scrollView: SplitZoomScrollView?,
        containerView: UIView?
    ) {
        guard newCanvas.width > 0, newCanvas.height > 0 else { return }
        isApplyingGeometry = true
        defer { isApplyingGeometry = false }

        // Reset to an unscaled state before mutating the zoom target so UIKit cannot preserve a
        // transform that belongs to the old canvas.
        scrollView?.minimumZoomScale = 1
        scrollView?.maximumZoomScale = max(1, scrollView?.maximumZoomScale ?? 1)
        scrollView?.zoomScale = 1
        containerView?.transform = .identity
        containerView?.frame = CGRect(origin: .zero, size: newCanvas)
        containerView?.bounds = CGRect(origin: .zero, size: newCanvas)
        scrollView?.contentSize = newCanvas
        canvasSize = newCanvas
        imageIdentity = identity
        hasCompletedInitialFit = false
        lastViewportSize = .zero
        lastFitScale = 0
        centerAnchor = CGPoint(x: 0.5, y: 0.5)
        maskLayer.frame = CGRect(origin: .zero, size: newCanvas)
        maskLayer.path = nil
    }

    // MARK: - Layout-driven fit

    /// Fits/keeps the canvas stable for the current real viewport.
    ///
    /// * first valid layout (including zero→non-zero bounds) → aspect-fit centered;
    /// * viewport-only change (rotation/safe area) → keep `zoom / oldFit` and the image anchor;
    /// * repeated layout passes → no-op unless the zoom escaped its valid range.
    func handleLayout() {
        guard !isApplyingGeometry,
              let scrollView, containerView != nil,
              scrollView.bounds.width > 0, scrollView.bounds.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return }

        let viewport = scrollView.bounds.size
        let fitScale = min(viewport.width / canvasSize.width, viewport.height / canvasSize.height)
        guard fitScale.isFinite, fitScale > 0 else { return }

        isApplyingGeometry = true
        defer { isApplyingGeometry = false }

        scrollView.minimumZoomScale = fitScale
        scrollView.maximumZoomScale = max(fitScale, fitScale * 16)

        let viewportChanged = viewport != lastViewportSize
        let needsInitialFit = !hasCompletedInitialFit

        if needsInitialFit {
            scrollView.setZoomScale(fitScale, animated: false)
            Diagnostics.shared.record(
                category: .viewer,
                level: .debug,
                code: "viewer.fit",
                message: "viewer fitted",
                fields: [
                    "canvasWidth": "\(Int(canvasSize.width))",
                    "canvasHeight": "\(Int(canvasSize.height))",
                    "viewportWidth": "\(Int(viewport.width))",
                    "viewportHeight": "\(Int(viewport.height))",
                    "fitScale": String(format: "%.5f", fitScale)
                ]
            )
            hasCompletedInitialFit = true
            lastViewportSize = viewport
            lastFitScale = fitScale
            centerContent()
            updateMask()
            return
        }

        if viewportChanged {
            let previousFit = lastFitScale > 0 ? lastFitScale : fitScale
            let relativeZoom = scrollView.zoomScale / previousFit
            let targetZoom = min(max(fitScale * relativeZoom, fitScale), scrollView.maximumZoomScale)
            scrollView.setZoomScale(targetZoom, animated: false)
            lastViewportSize = viewport
            lastFitScale = fitScale
            centerContent()
            applyAnchor(centerAnchor)
            updateMask()
            return
        }

        // Same viewport: only clamp if the zoom escaped its valid range. Do not otherwise write
        // zoom/offset, so repeated updates cannot compound transforms.
        if scrollView.zoomScale < fitScale - 0.0001 {
            scrollView.setZoomScale(fitScale, animated: false)
            centerContent()
        } else if scrollView.zoomScale > scrollView.maximumZoomScale + 0.0001 {
            scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
            centerContent()
        } else {
            centerContent()
        }
        updateMask()
    }

    /// Centers content that is smaller than the viewport by pairing symmetric insets with the
    /// matching content offset, then centers the visible region after a gesture-driven zoom-out.
    func centerContent() {
        guard let scrollView, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let scaledWidth = canvasSize.width * scrollView.zoomScale
        let scaledHeight = canvasSize.height * scrollView.zoomScale
        let horizontal = max(0, (scrollView.bounds.width - scaledWidth) * 0.5)
        let vertical = max(0, (scrollView.bounds.height - scaledHeight) * 0.5)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)

        if !Self.insetsEqual(scrollView.contentInset, insets) {
            scrollView.contentInset = insets
        }

        // Fit-to-axis content has no scrollable range; UIScrollView keeps the old offset from a
        // previous zoom unless it is explicitly placed at the inset origin. This is the old
        // "tiny corner" failure mode for pinch-out.
        var target = scrollView.contentOffset
        if scaledWidth <= scrollView.bounds.width + 0.5 {
            target.x = -horizontal
        } else {
            let minX = -horizontal
            let maxX = max(minX, scaledWidth - scrollView.bounds.width + horizontal)
            target.x = min(max(target.x, minX), maxX)
        }
        if scaledHeight <= scrollView.bounds.height + 0.5 {
            target.y = -vertical
        } else {
            let minY = -vertical
            let maxY = max(minY, scaledHeight - scrollView.bounds.height + vertical)
            target.y = min(max(target.y, minY), maxY)
        }
        if abs(target.x - scrollView.contentOffset.x) > 0.5 || abs(target.y - scrollView.contentOffset.y) > 0.5 {
            scrollView.setContentOffset(target, animated: false)
        }
    }

    /// Places the captured normalized image anchor under the viewport center (used on rotation).
    private func applyAnchor(_ anchor: CGPoint) {
        guard let scrollView, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let scaledWidth = canvasSize.width * scrollView.zoomScale
        let scaledHeight = canvasSize.height * scrollView.zoomScale
        let horizontal = max(0, (scrollView.bounds.width - scaledWidth) * 0.5)
        let vertical = max(0, (scrollView.bounds.height - scaledHeight) * 0.5)
        let contentPoint = CGPoint(
            x: min(max(anchor.x, 0), 1) * scaledWidth,
            y: min(max(anchor.y, 0), 1) * scaledHeight
        )
        // Apply the anchor independently per axis. A portrait photo rotated to landscape can fit
        // horizontally while still being scrollable vertically; the old both-axes guard discarded
        // the whole anchor in that case. Fitting axes stay at the centering inset.
        var target = scrollView.contentOffset
        if scaledWidth > scrollView.bounds.width + 0.5 {
            let minX = -horizontal
            let maxX = max(minX, scaledWidth - scrollView.bounds.width + horizontal)
            target.x = min(max(contentPoint.x - scrollView.bounds.width * 0.5, minX), maxX)
        } else {
            target.x = -horizontal
        }
        if scaledHeight > scrollView.bounds.height + 0.5 {
            let minY = -vertical
            let maxY = max(minY, scaledHeight - scrollView.bounds.height + vertical)
            target.y = min(max(contentPoint.y - scrollView.bounds.height * 0.5, minY), maxY)
        } else {
            target.y = -vertical
        }
        if abs(target.x - scrollView.contentOffset.x) > 0.5 || abs(target.y - scrollView.contentOffset.y) > 0.5 {
            scrollView.setContentOffset(target, animated: false)
        }
    }

    /// Normalized image point under the viewport center for an offset/zoom pair.
    ///
    /// The offset is clamped to the same scrollable range UIScrollView enforces, so a transient
    /// over-scroll assignment (which UIKit has not clamped yet) cannot become the stored anchor.
    private func normalizedAnchor(viewport: CGSize, zoom: CGFloat, offset: CGPoint) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0, zoom > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let scaledWidth = canvasSize.width * zoom
        let scaledHeight = canvasSize.height * zoom
        guard scaledWidth > 0, scaledHeight > 0 else { return nil }
        let horizontal = max(0, (viewport.width - scaledWidth) * 0.5)
        let vertical = max(0, (viewport.height - scaledHeight) * 0.5)
        let minX = -horizontal
        let maxX = max(minX, scaledWidth - viewport.width + horizontal)
        let minY = -vertical
        let maxY = max(minY, scaledHeight - viewport.height + vertical)
        let clampedX = min(max(offset.x, minX), maxX)
        let clampedY = min(max(offset.y, minY), maxY)
        let contentX = clampedX + viewport.width * 0.5
        let contentY = clampedY + viewport.height * 0.5
        let x = min(max(contentX / scaledWidth, 0), 1)
        let y = min(max(contentY / scaledHeight, 0), 1)
        return CGPoint(x: x, y: y)
    }

    /// Captures the normalized image point currently under the viewport center.
    private func captureCenterAnchor() {
        guard !isApplyingGeometry, let scrollView,
              canvasSize.width > 0, canvasSize.height > 0,
              // During a rotation/safe-area transition UIKit can report scroll callbacks with the
              // new bounds before the first layout pass has applied the anchor. Those transient
              // offsets are not a user gesture and must not replace the pre-rotation anchor.
              scrollView.bounds.size == lastViewportSize else { return }
        if let anchor = normalizedAnchor(
            viewport: scrollView.bounds.size,
            zoom: scrollView.zoomScale,
            offset: scrollView.contentOffset
        ) {
            centerAnchor = anchor
        }
    }

    // MARK: - Split mask

    /// The intersection of the scaled photo with the visible scroll bounds, in the scroll
    /// view's content coordinates. It is shared by the divider, handle and processed-image mask.
    var visiblePhotoRect: CGRect {
        guard let scrollView else { return .zero }
        let photo = CGRect(origin: .zero, size: CGSize(width: canvasSize.width * scrollView.zoomScale,
                                                       height: canvasSize.height * scrollView.zoomScale))
        let visible = photo.intersection(scrollView.bounds)
        return visible.isNull || visible.isEmpty ? .zero : visible
    }

    func updateMask() {
        guard let scrollView else { return }
        if processedView?.layer.mask !== maskLayer { processedView?.layer.mask = maskLayer }
        let canvasWidth = canvasSize.width
        let canvasHeight = canvasSize.height
        guard canvasWidth > 0, canvasHeight > 0 else { return }
        let visible = visiblePhotoRect
        let overlay = scrollView.comparisonOverlay
        overlay.isHidden = visible.isEmpty || splitFraction <= 0.01 || splitFraction >= 0.99
        overlay.frame = visible
        overlay.configure(fraction: splitFraction)
        scrollView.bringSubviewToFront(overlay)
        let splitContentX = visible.minX + visible.width * splitFraction
        let splitCanvasX = splitContentX / max(scrollView.zoomScale, 0.0001)
        let start = min(max(splitCanvasX, 0), canvasWidth)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let desiredFrame = CGRect(origin: .zero, size: CGSize(width: canvasWidth, height: canvasHeight))
        if maskLayer.frame != desiredFrame {
            maskLayer.frame = desiredFrame
        }
        maskLayer.path = CGPath(
            rect: CGRect(x: start, y: 0, width: max(0, canvasWidth - start), height: canvasHeight),
            transform: nil
        )
        CATransaction.commit()
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        containerView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateMask()
        captureCenterAnchor()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateMask()
        captureCenterAnchor()
    }

    // MARK: - Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let overlay = scrollView?.comparisonOverlay, let touched = touch.view else { return true }
        return touched !== overlay && !touched.isDescendant(of: overlay)
    }

    var isAtFitForNavigation: Bool {
        guard let scrollView, hasCompletedInitialFit else { return false }
        return !scrollView.isZooming && scrollView.zoomScale <= scrollView.minimumZoomScale * 1.01
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer { return isAtFitForNavigation && onStep != nil }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            guard let scrollView else { return false }
            let velocity = pan.velocity(in: scrollView.superview)
            return isAtFitForNavigation && onDismiss != nil && velocity.y > abs(velocity.x) * 1.2
        }
        return true
    }

    @objc func handlePhotoSwipe(_ sender: UISwipeGestureRecognizer) {
        navigatePhoto(sender.direction == .left ? 1 : -1)
    }

    func navigatePhoto(_ delta: Int) {
        guard isAtFitForNavigation else { return }
        onStep?(delta)
    }

    @objc func handleDismissPan(_ sender: UIPanGestureRecognizer) {
        guard let scrollView else { return }
        updateDismissal(state: sender.state, translation: sender.translation(in: scrollView.superview),
            velocity: sender.velocity(in: scrollView.superview))
    }

    func updateDismissal(state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint) {
        guard let scrollView else { return }
        guard isAtFitForNavigation, onDismiss != nil else { scrollView.transform = .identity; return }
        let distance = max(0, translation.y)
        switch state {
        case .began, .changed:
            let fraction = min(1, distance / max(1, scrollView.bounds.height * 0.5))
            scrollView.transform = CGAffineTransform(translationX: translation.x * 0.2, y: distance)
                .scaledBy(x: 1 - fraction * 0.15, y: 1 - fraction * 0.15)
        case .ended:
            let far = distance > min(140, max(80, scrollView.bounds.height * 0.16))
            let flick = distance > 32 && velocity.y > 900 && velocity.y > abs(velocity.x)
            if translation.y > abs(translation.x), far || flick { onDismiss?() }
            else { resetDismissal() }
        case .failed, .cancelled: resetDismissal()
        default: break
        }
    }

    private func resetDismissal() {
        guard let scrollView else { return }
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]) { scrollView.transform = .identity }
    }

    @objc func handleSingleTap() {
        onSingleTap?()
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let scrollView else { return }
        let contentPoint = recognizer.location(in: scrollView)
        // Gesture locations for a scroll view are in content coordinates; the zoom logic works in
        // visible viewport coordinates so an over-scrolled/inset state is handled once.
        let viewportPoint = CGPoint(
            x: contentPoint.x - scrollView.bounds.minX,
            y: contentPoint.y - scrollView.bounds.minY
        )
        performDoubleTap(atViewportPoint: viewportPoint)
    }

    /// Double tap toggles between fit and a useful zoom centered at the tap.
    func performDoubleTap(atViewportPoint point: CGPoint) {
        guard let scrollView, containerView != nil else { return }
        let fitScale = scrollView.minimumZoomScale
        if scrollView.zoomScale > fitScale * 1.05 {
            scrollView.setZoomScale(fitScale, animated: true)
            return
        }
        let targetScale = min(scrollView.maximumZoomScale, fitScale * 4.0)
        guard targetScale > 0 else { return }
        let pointInCanvas = CGPoint(
            x: (scrollView.contentOffset.x + point.x) / max(scrollView.zoomScale, 0.0001),
            y: (scrollView.contentOffset.y + point.y) / max(scrollView.zoomScale, 0.0001)
        )
        // Apply the zoom, then explicitly center the tapped image point. `zoom(to:)` plus the
        // centering insets is order-sensitive on UIScrollView (the delegate's inset update can run
        // before the offset is committed), so perform the two steps deterministically.
        scrollView.setZoomScale(targetScale, animated: false)
        centerContent()
        center(onCanvasPoint: pointInCanvas, at: point)
        updateMask()
    }

    /// Places `point` (canvas coordinates) under the tapped viewport point at the current zoom,
    /// clamped to the real scrollable range at the image edges.
    private func center(onCanvasPoint point: CGPoint, at viewportPoint: CGPoint) {
        guard let scrollView, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let zoom = scrollView.zoomScale
        let scaledWidth = canvasSize.width * zoom
        let scaledHeight = canvasSize.height * zoom
        let horizontal = max(0, (scrollView.bounds.width - scaledWidth) * 0.5)
        let vertical = max(0, (scrollView.bounds.height - scaledHeight) * 0.5)
        let contentPoint = CGPoint(x: point.x * zoom, y: point.y * zoom)
        let minX = -horizontal
        let maxX = max(minX, scaledWidth - scrollView.bounds.width + horizontal)
        let minY = -vertical
        let maxY = max(minY, scaledHeight - scrollView.bounds.height + vertical)
        let target = CGPoint(
            x: min(max(contentPoint.x - viewportPoint.x, minX), maxX),
            y: min(max(contentPoint.y - viewportPoint.y, minY), maxY)
        )
        scrollView.setContentOffset(target, animated: false)
        centerContent()
    }

    // MARK: - Helpers

    private static func clampedSplit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    private static func identity(
        source: MMapBuffer,
        output: MMapBuffer,
        scaleFactor: Int
    ) -> ImageIdentity {
        ImageIdentity(
            sourcePath: source.fileURL.path,
            outputPath: output.fileURL.path,
            outputWidth: output.width,
            outputHeight: output.height,
            scaleFactor: max(1, scaleFactor)
        )
    }

    private static func insetsEqual(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) < 0.5
            && abs(lhs.left - rhs.left) < 0.5
            && abs(lhs.bottom - rhs.bottom) < 0.5
            && abs(lhs.right - rhs.right) < 0.5
    }
}
#endif
