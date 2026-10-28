#if canImport(UIKit)
// Ported from the current read-only TruongCam implementation; root/order fences retained.
import SwiftUI
import UIKit

struct GalleryCellFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Attaches to the existing native scroll view. A horizontal start selects;
/// a vertical start fails immediately so normal scrolling remains unchanged.
struct GallerySelectionGesture: UIViewRepresentable {
    let frames: [String: CGRect]
    let orderedIDs: [String]
    @Binding var selectedIDs: Set<String>
    let context: String
    let isEnabled: Bool

    func makeUIView(context: Context) -> GallerySelectionGestureView {
        let view = GallerySelectionGestureView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: GallerySelectionGestureView, context: Context) {
        view.update(frames: frames, orderedIDs: orderedIDs, selectedIDs: selectedIDs,
                    context: self.context, isEnabled: isEnabled, onChange: { selectedIDs = $0 })
    }
    static func dismantleUIView(_ view: GallerySelectionGestureView, coordinator: ()) { view.detach() }
}

final class GallerySelectionGestureView: UIView, UIGestureRecognizerDelegate {
    private(set) weak var scrollView: UIScrollView?
    private(set) var sweep: GalleryRangeSelection?
    private var frames: [String: CGRect] = [:]
    private var orderedIDs: [String] = []
    private var selectedIDs: Set<String> = []
    private var selectionContext = ""
    private var onChange: ((Set<String>) -> Void)?
    private var lastID: String?
    private var fingerInWindow = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    lazy var selectionPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.cancelsTouchesInView = true
        return pan
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() }
        else { installIfNeeded() }
    }

    func update(frames: [String: CGRect], orderedIDs: [String], selectedIDs: Set<String>,
                context: String, isEnabled: Bool, onChange: @escaping (Set<String>) -> Void) {
        if context != selectionContext || orderedIDs != self.orderedIDs || !isEnabled {
            // Never restore an old root's baseline into a replacement library.
            finish(cancelled: false)
            selectionPan.isEnabled = false
        }
        self.frames = frames
        self.orderedIDs = orderedIDs
        self.selectedIDs = selectedIDs
        self.selectionContext = context
        self.onChange = onChange
        selectionPan.isEnabled = isEnabled
        installIfNeeded()
        if sweep != nil { updateSelection(at: fingerInWindow) }
    }

    func installIfNeeded() {
        guard window != nil else { return }
        var ancestor = superview
        while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
        guard let scroll = ancestor as? UIScrollView, scroll !== scrollView else { return }
        detach()
        scrollView = scroll
        scroll.addGestureRecognizer(selectionPan)
        scroll.panGestureRecognizer.require(toFail: selectionPan)
    }

    func detach() {
        finish(cancelled: false)
        scrollView?.removeGestureRecognizer(selectionPan)
        scrollView = nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let scroll = scrollView,
              !scroll.isDecelerating else { return false }
        let movement = pan.translation(in: scroll)
        let start = pan.location(in: self).applying(CGAffineTransform(translationX: -movement.x, y: -movement.y))
        return abs(movement.x) > abs(movement.y) && hit(at: start) != nil
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: self)
        switch pan.state {
        case .began:
            let delta = pan.translation(in: self)
            begin(at: CGPoint(x: point.x - delta.x, y: point.y - delta.y))
            fallthrough
        case .changed:
            fingerInWindow = pan.location(in: window)
            updateSelection(at: fingerInWindow)
            if sweep != nil && displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        case .cancelled, .failed: finish(cancelled: true)
        case .ended: finish(cancelled: false)
        default: break
        }
    }

    /// Seams shared by native tests and the actual recognizer callbacks.
    func begin(at point: CGPoint) {
        guard let id = hit(at: point) else { return }
        sweep = GalleryRangeSelection(orderedIDs: orderedIDs, anchorID: id, baseline: selectedIDs)
        lastID = nil
        apply(through: id)
    }

    func updateSelection(at windowPoint: CGPoint) {
        guard sweep != nil, let scroll = scrollView else { return }
        let visible = convert(scroll.bounds, from: scroll)
        let local = convert(windowPoint, from: window)
        // During edge scrolling keep the endpoint in the visible content. Gaps
        // choose their nearest visible cell instead of jumping to an old frame.
        let point = CGPoint(x: min(max(local.x, visible.minX + 1), visible.maxX - 1),
                            y: min(max(local.y, visible.minY + 1), visible.maxY - 1))
        if let id = hit(at: point, visible: visible) { apply(through: id) }
    }

    private func hit(at point: CGPoint, visible: CGRect? = nil) -> String? {
        let candidates = frames.filter { visible == nil || $0.value.intersects(visible!) }
        if let exact = candidates.first(where: { $0.value.contains(point) }) { return exact.key }
        // Only small inter-tile gaps count as hits; the folder/header never
        // starts selection. Once sweeping, a partial edge row remains usable.
        return candidates.filter { $0.value.insetBy(dx: -3, dy: -3).contains(point) }
            .min(by: { distance($0.value, point) < distance($1.value, point) })?.key
    }
    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        abs(rect.midX - point.x) + abs(rect.midY - point.y)
    }
    private func apply(through id: String) {
        guard lastID != id, let result = sweep?.selection(through: id) else { return }
        lastID = id
        if result != selectedIDs { selectedIDs = result; onChange?(result) }
    }
    func finish(cancelled: Bool) {
        if cancelled, let baseline = sweep?.baseline, baseline != selectedIDs {
            selectedIDs = baseline; onChange?(baseline)
        }
        sweep = nil; lastID = nil
        displayLink?.invalidate(); displayLink = nil; lastTick = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = lastTick == 0 ? 1.0 / 30 : min(0.05, link.timestamp - lastTick)
        lastTick = link.timestamp
        advanceAutoScroll(at: fingerInWindow, elapsed: elapsed)
    }

    func advanceAutoScroll(at windowPoint: CGPoint, elapsed: CFTimeInterval) {
        guard sweep != nil, let scroll = scrollView, let window else { finish(cancelled: false); return }
        let visible = scroll.convert(scroll.bounds, to: window)
        let margin: CGFloat = min(64, visible.height / 5)
        let y = windowPoint.y
        let direction: CGFloat
        if y < visible.minY + margin { direction = -min(1, (visible.minY + margin - y) / margin) }
        else if y > visible.maxY - margin { direction = min(1, (y - visible.maxY + margin) / margin) }
        else { direction = 0 }
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let next = min(maximum, max(minimum, scroll.contentOffset.y + direction * 600 * elapsed))
        if next != scroll.contentOffset.y { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false) }
        updateSelection(at: windowPoint)
    }
}

#endif
#if !canImport(UIKit)
import SwiftUI
struct GalleryCellFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, n in n }) }
}
struct GallerySelectionGesture: View {
    let frames: [String: CGRect]; let orderedIDs: [String]; @Binding var selectedIDs: Set<String>; let context: String; let isEnabled: Bool
    var body: some View { Color.clear.allowsHitTesting(false) }
}
#endif
