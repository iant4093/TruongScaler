#if canImport(UIKit)
// Ported from the current read-only TruongCam native, identity-fenced popover anchor.
import SwiftUI
import UIKit

/// The native action sheet is anchored to the actual 44-point Trash target.
/// Keeping popover adaptation disabled preserves that relationship on iPhone;
/// UIKit can reposition the popover when compact landscape has less room.
enum GalleryPhotoConfirmationKind: Equatable {
    case move, recover, permanentlyDelete
    func title(count: Int) -> String {
        let photos = "\(count) \(count == 1 ? "photo" : "photos")"
        switch self {
        case .move: return "Move \(photos) to Trash?"
        case .recover: return "Recover \(photos)?"
        case .permanentlyDelete: return "Permanently delete \(photos)?"
        }
    }
    var message: String {
        switch self {
        case .move: return "Recover these photos in Output → Recently Deleted. Input photos are kept."
        case .recover: return "These photos will return to your library."
        case .permanentlyDelete: return "These photos will be permanently deleted. This cannot be undone."
        }
    }
    func action(count: Int) -> String {
        switch self {
        case .move: return "Move \(count) \(count == 1 ? "photo" : "photos") to Trash"
        case .recover: return "Recover \(count) \(count == 1 ? "Photo" : "Photos")"
        case .permanentlyDelete: return "Delete \(count) \(count == 1 ? "Photo" : "Photos")"
        }
    }
}

struct GalleryTrashConfirmation: UIViewRepresentable {
    let requestID: UUID?
    let count: Int
    let onConfirm: (UUID) -> Void
    let onDismiss: (UUID) -> Void
    var kind: GalleryPhotoConfirmationKind = .move

    func makeUIView(context: Context) -> GalleryTrashAnchorView { GalleryTrashAnchorView() }
    func updateUIView(_ view: GalleryTrashAnchorView, context: Context) {
        view.update(requestID: requestID, count: count, onConfirm: onConfirm, onDismiss: onDismiss, kind: kind)
    }
    static func dismantleUIView(_ view: GalleryTrashAnchorView, coordinator: ()) { view.close() }
}

final class GalleryTrashAnchorView: UIView, UIPopoverPresentationControllerDelegate {
    private(set) weak var confirmation: UIAlertController?
    private var presentationSource: UIView?
    private var retiringConfirmation: UIAlertController?
    private var retiringSource: UIView?
    private var actionAwaitingDismissal: (requestID: UUID, confirms: Bool)?
    private var dismissalObservation: Task<Void, Never>?
    // IDs contain no photo/root payload. Keep terminal requests fenced for this
    // representable's lifetime: a delayed SwiftUI snapshot is not a new intent.
    private var terminalRequestIDs: Set<UUID> = []
    private var requestID: UUID?
    private var pendingKind: GalleryPhotoConfirmationKind = .move
    private var pendingCount = 0
    private var onConfirm: ((UUID) -> Void)?
    private var onDismiss: ((UUID) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var frame: CGRect { didSet { updatePresentationSourceGeometry() } }
    override var bounds: CGRect { didSet { updatePresentationSourceGeometry() } }
    override var center: CGPoint { didSet { updatePresentationSourceGeometry() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePresentationSourceGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { close() }
        else { updatePresentationSourceGeometry() }
    }

    func update(requestID: UUID?, count: Int, onConfirm: @escaping (UUID) -> Void, onDismiss: @escaping (UUID) -> Void, kind: GalleryPhotoConfirmationKind = .move) {
        if let requestID, terminalRequestIDs.contains(requestID) { return }
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        updatePresentationSourceGeometry()
        guard requestID != self.requestID else { return }
        if let previous = self.requestID { terminalRequestIDs.insert(previous) }
        self.requestID = requestID
        actionAwaitingDismissal = nil
        pendingKind = kind
        pendingCount = count
        if let alert = confirmation {
            confirmation = nil
            let source = presentationSource; presentationSource = nil
            retire(alert, source: source, animated: false)
        } else if retiringConfirmation == nil {
            presentPendingRequest()
        }
    }

    private func presentPendingRequest() {
        guard retiringConfirmation == nil else { return }
        guard let requestID, !terminalRequestIDs.contains(requestID) else { return }
        let count = pendingCount
        guard count > 0, window != nil, bounds.width > 0, bounds.height > 0 else {
            // A source detached during rotation must not retain a request that
            // can never be presented. The caller only clears this exact ID.
            cancelUnpresentableRequest(requestID)
            return
        }
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil,
              let sourceHost = window, presenter.view.window === sourceHost else {
            cancelUnpresentableRequest(requestID)
            return
        }
        // The SwiftUI button can be replaced by progress during dismissal. A
        // transparent sibling in the UIWindow survives that replacement without
        // inserting unsupported UIKit children into UIHostingController.view.
        let source = UIView(frame: convert(bounds, to: sourceHost))
        source.isUserInteractionEnabled = false
        source.accessibilityElementsHidden = true
        sourceHost.addSubview(source)
        presentationSource = source
        let alert = UIAlertController(title: pendingKind.title(count: count),
            message: pendingKind.message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: pendingKind.action(count: count), style: pendingKind == .recover ? .default : .destructive) { [weak self, weak alert] _ in
            guard let alert else { return }
            self?.performNativeAction(for: requestID, alert: alert, confirms: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
            guard let alert else { return }
            self?.performNativeAction(for: requestID, alert: alert, confirms: false)
        })
        alert.modalPresentationStyle = .popover
        if let popover = alert.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
            popover.permittedArrowDirections = [.down]
            popover.delegate = self
        }
        confirmation = alert
        presenter.present(alert, animated: true)
    }

    private func updatePresentationSourceGeometry(invalidatePopover: Bool = true) {
        guard let alert = confirmation, retiringConfirmation == nil,
              let source = presentationSource, let host = source.superview,
              let window, bounds.width > 0, bounds.height > 0 else { return }
        let hostWindow = (host as? UIWindow) ?? host.window
        guard window === hostWindow else { return }
        let frame = convert(bounds, to: host)
        guard source.frame != frame else { return }
        source.frame = frame
        if invalidatePopover, let popover = alert.popoverPresentationController {
            // UIKit normalizes a null sourceRect during presentation. Moving
            // the proxy alone can therefore leave an already-presented card
            // at its old position until another layout happens. Refresh the
            // exact rectangle and request the native container's next layout.
            popover.sourceRect = source.bounds
            popover.containerView?.setNeedsLayout()
        }
    }

    private func cancelUnpresentableRequest(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        terminalRequestIDs.insert(requestID)
        self.requestID = nil
        let callback = onDismiss
        Task { @MainActor in callback?(requestID) }
    }

    /// Replacement B waits only for our own A's real UIKit transition. Another
    /// modal does not gain authority to hold or later resurrect this request.
    private func retire(_ alert: UIAlertController, source: UIView?, animated: Bool) {
        retiringConfirmation = alert
        retiringSource = source
        let wasDismissing = alert.isBeingDismissed
        if (alert.isBeingPresented || wasDismissing), let transition = alert.transitionCoordinator {
            let registered = transition.animate(alongsideTransition: nil) { [self, weak alert] context in
                guard let alert, retiringConfirmation === alert else { return }
                if wasDismissing && !context.isCancelled { self.finishedRetiring(alert) }
                else { self.dismissRetiring(alert, animated: animated) }
            }
            if registered { return }
        }
        dismissRetiring(alert, animated: animated)
    }

    private func dismissRetiring(_ alert: UIAlertController, animated: Bool) {
        guard retiringConfirmation === alert else { return }
        guard alert.presentingViewController != nil || alert.viewIfLoaded?.window != nil else {
            finishedRetiring(alert); return
        }
        alert.dismiss(animated: animated) { [self, weak alert] in
            guard let alert else { return }
            finishedRetiring(alert)
        }
    }

    private func finishedRetiring(_ alert: UIAlertController) {
        guard retiringConfirmation === alert else { return }
        guard alert.presentingViewController == nil, alert.viewIfLoaded?.window == nil else {
            observeNativeDismissal(alert)
            return
        }
        dismissalObservation?.cancel(); dismissalObservation = nil
        retiringConfirmation = nil
        retiringSource?.removeFromSuperview(); retiringSource = nil
        alert.popoverPresentationController?.delegate = nil
        let action = actionAwaitingDismissal
        actionAwaitingDismissal = nil
        if let action, requestID == action.requestID {
            pendingCount = 0
            // Starting a batch may remove the source button immediately. UIKit
            // is completely off-screen before the owner can make that change.
            if action.confirms { onConfirm?(action.requestID) }
            else { onDismiss?(action.requestID) }
        }
        presentPendingRequest()
    }

    /// UIAlertAction owns its native automatic dismissal. Calling dismiss again
    /// from its handler can race that same transition and strand the presenter.
    /// Observe the real terminal relation instead, with one guarded recovery if
    /// UIKit unexpectedly leaves the controller presented after the action.
    private func observeNativeDismissal(_ alert: UIAlertController) {
        guard dismissalObservation == nil else { return }
        dismissalObservation = Task { @MainActor [self, weak alert] in
            for _ in 0..<125 {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let alert, retiringConfirmation === alert else { return }
                if alert.presentingViewController == nil, alert.viewIfLoaded?.window == nil {
                    finishedRetiring(alert)
                    return
                }
            }
            guard let alert, retiringConfirmation === alert else { return }
            dismissalObservation = nil
            // retire waits for an existing native transition before issuing its
            // own dismissal; it never competes with the automatic action.
            retire(alert, source: retiringSource, animated: false)
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController,
        traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func popoverPresentationController(_ popoverPresentationController: UIPopoverPresentationController,
        willRepositionPopoverTo rect: UnsafeMutablePointer<CGRect>, in view: AutoreleasingUnsafeMutablePointer<UIView>) {
        guard popoverPresentationController.presentedViewController === confirmation else { return }
        updatePresentationSourceGeometry(invalidatePopover: false)
        if let source = presentationSource {
            rect.pointee = source.bounds
            view.pointee = source
        }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishInteractiveDismissal(presentationController)
    }
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        finishInteractiveDismissal(popoverPresentationController)
    }
    private func finishInteractiveDismissal(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === confirmation, let requestID else { return }
        terminalRequestIDs.insert(requestID)
        confirmation = nil
        presentationSource?.removeFromSuperview(); presentationSource = nil
        self.requestID = nil
        pendingCount = 0
        onDismiss?(requestID)
    }
    /// Both the native action and the SwiftUI owner verify the frozen ID. A
    /// late action from dismissed A cannot confirm or dismiss replacement B.
    func performAction(for requestID: UUID, alert: UIAlertController, confirms: Bool) {
        consumeAction(for: requestID, alert: alert, confirms: confirms, nativeDismissal: false)
    }
    /// The exact UIAlertAction callback entry point. Native tests can signal the
    /// handler and separately drive UIKit's real dismissal without private APIs;
    /// this path itself must never compete with the automatic native dismissal.
    func performNativeAction(for requestID: UUID, alert: UIAlertController, confirms: Bool) {
        consumeAction(for: requestID, alert: alert, confirms: confirms, nativeDismissal: true)
    }
    private func consumeAction(for requestID: UUID, alert: UIAlertController, confirms: Bool, nativeDismissal: Bool) {
        guard self.requestID == requestID, confirmation === alert else { return }
        terminalRequestIDs.insert(requestID)
        actionAwaitingDismissal = (requestID, confirms)
        confirmation = nil
        let source = presentationSource; presentationSource = nil
        if nativeDismissal {
            retiringConfirmation = alert
            retiringSource = source
            observeNativeDismissal(alert)
        } else { retire(alert, source: source, animated: true) }
    }
    func close() {
        if let requestID { terminalRequestIDs.insert(requestID) }
        requestID = nil
        pendingCount = 0
        actionAwaitingDismissal = nil
        if let alert = confirmation {
            confirmation = nil
            let source = presentationSource; presentationSource = nil
            retire(alert, source: source, animated: false)
        }
    }
}

#endif
#if !canImport(UIKit)
import SwiftUI
enum GalleryPhotoConfirmationKind { case move, recover, permanentlyDelete }
struct GalleryTrashConfirmation: View {
    let requestID: UUID?; let count: Int; let onConfirm: (UUID) -> Void; let onDismiss: (UUID) -> Void
    var kind: GalleryPhotoConfirmationKind = .move
    var body: some View { Color.clear.confirmationDialog("Confirm photo operation", isPresented: Binding(get: { requestID != nil }, set: { if !$0, let id = requestID { onDismiss(id) } })) {
        if let id = requestID { Button(kind == .recover ? "Restore" : "Delete", role: kind == .recover ? nil : .destructive) { onConfirm(id) } }
    } }
}
#endif
