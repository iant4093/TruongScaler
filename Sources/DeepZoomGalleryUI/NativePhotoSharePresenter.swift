#if canImport(UIKit)
import SwiftUI
import UIKit

/// A native presentation anchor in the actual foreground surface. Unlike another SwiftUI sheet
/// modifier, it cannot be queued on the library behind its fullscreen photo viewer.
struct NativePhotoSharePresenter: UIViewControllerRepresentable {
    let session: PhotoShareSession?
    let onDismiss: (UUID) -> Void
    func makeUIViewController(context: Context) -> PhotoShareAnchor { PhotoShareAnchor() }
    func updateUIViewController(_ anchor: PhotoShareAnchor, context: Context) {
        anchor.update(session: session, onDismiss: onDismiss)
    }
    static func dismantleUIViewController(_ anchor: PhotoShareAnchor, coordinator: ()) { anchor.tearDown() }
}

@MainActor
final class PhotoShareAnchor: UIViewController, UIAdaptivePresentationControllerDelegate {
    private struct Request {
        let session: PhotoShareSession
        let onDismiss: (UUID) -> Void
    }
    private var pending: Request?
    private var active: Request?
    private var activity: UIActivityViewController?
    private var finishing = false
    private var tornDown = false
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentIfPossible() }
    func update(session: PhotoShareSession?, onDismiss: @escaping (UUID) -> Void) {
        let next = session.map { Request(session: $0, onDismiss: onDismiss) }
        if tornDown {
            if let next { notifyRetired(next) }
            return
        }
        if let previous = pending, previous.session.id != next?.session.id,
           previous.session.id != active?.session.id { notifyRetired(previous) }
        pending = next
        Task { @MainActor [weak self] in self?.presentIfPossible() }
    }
    private func notifyRetired(_ request: Request) {
        // This can originate in SwiftUI dismantling. Publish its identity after that update drains,
        // retaining its snapshots until the matching owner receives the retirement callback.
        Task { @MainActor in request.onDismiss(request.session.id) }
    }
    private func presentIfPossible() {
        guard !tornDown, let request = pending, active == nil, viewIfLoaded?.window != nil else { return }
        var owner: UIViewController = self
        while let parent = owner.parent { owner = parent }
        guard owner.presentedViewController == nil, !owner.isBeingDismissed else {
            // A newer inspector/folder sheet owns the surface. Retire this unpresentable request
            // rather than retaining a shareSession that permanently disables the next Export tap.
            pending = nil
            notifyRetired(request)
            return
        }
        active = request // retain snapshots through the complete UIKit dismissal
        let controller = UIActivityViewController(activityItems: request.session.fileURLs.map { PhotoShareItem(url: $0) },
            applicationActivities: [SaveOriginalToPhotosActivity()])
        activity = controller
        if let popover = controller.popoverPresentationController {
            popover.sourceView = owner.view
            popover.sourceRect = CGRect(x: owner.view.bounds.midX, y: owner.view.bounds.maxY - 44, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        let id = request.session.id
        controller.completionWithItemsHandler = { [weak self, weak controller] _, _, _, _ in
            Task { @MainActor in
                guard let self, let controller, self.activity === controller else { return }
                self.finishAfterDismissal(id: id)
            }
        }
        owner.present(controller, animated: true)
        controller.presentationController?.delegate = self
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === activity, let id = active?.session.id else { return }
        finish(id: id)
    }
    private func finishAfterDismissal(id: UUID) {
        guard active?.session.id == id, !finishing else { return }
        finishing = true
        guard let activity else { finish(id: id); return }
        // Completion can precede the share extension's closing animation. Keep snapshots until the
        // native controller is detached; another session is refused throughout this interval.
        if activity.isBeingDismissed, let transition = activity.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.finish(id: id) }
        } else if activity.presentingViewController != nil {
            activity.dismiss(animated: true) { [weak self] in self?.finish(id: id) }
        } else { finish(id: id) }
    }
    private func finish(id: UUID) {
        guard let request = active, request.session.id == id else { return }
        activity?.completionWithItemsHandler = nil
        activity = nil; active = nil; finishing = false
        if pending?.session.id == id { pending = nil }
        notifyRetired(request)
        Task { @MainActor [weak self] in self?.presentIfPossible() }
    }
    func tearDown() {
        tornDown = true
        if let pending, pending.session.id != active?.session.id { notifyRetired(pending) }
        pending = nil
        guard let id = active?.session.id else { return }
        if let activity, activity.presentingViewController != nil {
            activity.dismiss(animated: false) { [self] in finish(id: id) }
        } else { finish(id: id) }
    }
}
#endif
