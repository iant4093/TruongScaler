#if canImport(UIKit)
import SwiftUI
import UIKit

/// Mount directly behind the companion button, so iPad's Open In menu points at that button.
struct NativeCompanionHandoffPresenter: UIViewControllerRepresentable {
    let session: CompanionHandoffSession?
    let onFinish: (UUID, Bool) -> Void
    func makeUIViewController(context: Context) -> CompanionHandoffAnchor { CompanionHandoffAnchor() }
    func updateUIViewController(_ anchor: CompanionHandoffAnchor, context: Context) {
        anchor.update(session: session, onFinish: onFinish)
    }
    static func dismantleUIViewController(_ anchor: CompanionHandoffAnchor, coordinator: ()) { anchor.tearDown() }
}

@MainActor
final class CompanionHandoffAnchor: UIViewController {
    private var pending: CompanionHandoffSession?
    private var completion: ((UUID, Bool) -> Void)?
    private var transfer: CompanionDocumentTransfer?
    private var presentationWait: Task<Void, Never>?
    private var tornDown = false
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentIfPossible() }

    func update(session: CompanionHandoffSession?, onFinish: @escaping (UUID, Bool) -> Void) {
        guard !tornDown else {
            if let session { Task { @MainActor in onFinish(session.id, false) } }
            return
        }
        if let old = pending, old.id != session?.id, old.id != transfer?.sessionID {
            let handler = completion
            Task { @MainActor in handler?(old.id, false) }
        }
        if pending?.id != session?.id { cancelPresentationWait() }
        pending = session; completion = onFinish
        if session?.id != transfer?.sessionID { transfer?.cancelMenu() }
        Task { @MainActor [weak self] in self?.presentIfPossible() }
    }

    private func presentIfPossible() {
        guard !tornDown, transfer == nil, let pending, let completion, viewIfLoaded?.window != nil else { return }
        guard companionPresentationSurfaceIsReady(self) else {
            waitForPresentationSurface(sessionID: pending.id)
            return
        }
        cancelPresentationWait()
        let transfer = CompanionDocumentTransfer(session: pending) { [weak self] id, unavailable in
            if self?.transfer?.sessionID == id { self?.transfer = nil }
            if self?.pending?.id == id { self?.pending = nil }
            completion(id, unavailable)
        }
        self.transfer = transfer
        transfer.present(from: view)
    }

    private func cancelPresentationWait() {
        presentationWait?.cancel(); presentationWait = nil
    }

    private func waitForPresentationSurface(sessionID: UUID) {
        guard presentationWait == nil else { return }
        presentationWait = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(3)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard let self, !self.tornDown, self.pending?.id == sessionID, self.transfer == nil else { return }
                if companionPresentationSurfaceIsReady(self) {
                    self.presentationWait = nil
                    self.presentIfPossible()
                    return
                }
                if .now >= deadline {
                    // A confirmation's dismissal normally drains in a fraction of a second. If a
                    // different modal keeps this surface, cancel the unpresented request instead
                    // of holding its private document and disabling the next Send indefinitely.
                    self.presentationWait = nil
                    self.pending = nil
                    self.completion?(sessionID, false)
                    return
                }
            }
        }
    }

    func tearDown() {
        tornDown = true
        cancelPresentationWait()
        if let pending, pending.id != transfer?.sessionID, let completion {
            Task { @MainActor in completion(pending.id, false) }
        }
        pending = nil
        transfer?.cancelMenu()
        transfer = nil
    }
}

/// The same readiness check gates the library's incoming viewer request. Read actual UIKit
/// presentation state; a SwiftUI binding becoming false does not finish its dismissal animation.
@MainActor
private func companionPresentationSurfaceIsReady(_ anchor: UIViewController) -> Bool {
    guard anchor.viewIfLoaded?.window != nil, !anchor.isBeingDismissed else { return false }
    var owner = anchor
    while let parent = owner.parent { owner = parent }
    return owner.presentedViewController == nil && !owner.isBeingDismissed && !owner.isBeingPresented
        && owner.transitionCoordinator == nil
}

struct NativeIncomingHandoffViewerPresenter: UIViewControllerRepresentable {
    let requestID: UUID?
    let onReady: (UUID) -> Void
    func makeUIViewController(context: Context) -> IncomingHandoffViewerAnchor { IncomingHandoffViewerAnchor() }
    func updateUIViewController(_ anchor: IncomingHandoffViewerAnchor, context: Context) {
        anchor.update(requestID: requestID, onReady: onReady)
    }
    static func dismantleUIViewController(_ anchor: IncomingHandoffViewerAnchor, coordinator: ()) { anchor.tearDown() }
}

@MainActor
final class IncomingHandoffViewerAnchor: UIViewController {
    private var requestID: UUID?
    private var deliveredID: UUID?
    private var onReady: ((UUID) -> Void)?
    private var readinessWait: Task<Void, Never>?
    private var tornDown = false
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); beginWaitIfNeeded() }

    func update(requestID: UUID?, onReady: @escaping (UUID) -> Void) {
        guard !tornDown else { return }
        if self.requestID != requestID {
            readinessWait?.cancel(); readinessWait = nil; deliveredID = nil
        }
        self.requestID = requestID; self.onReady = onReady
        beginWaitIfNeeded()
    }

    private func beginWaitIfNeeded() {
        guard readinessWait == nil, let id = requestID, deliveredID != id, !tornDown else { return }
        readinessWait = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(3)
            var interval = Duration.milliseconds(40)
            while !Task.isCancelled {
                // Let dismissal bindings from this SwiftUI update reach UIKit before probing.
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !self.tornDown, self.requestID == id else { return }
                if companionPresentationSurfaceIsReady(self) {
                    self.readinessWait = nil; self.deliveredID = id
                    self.onReady?(id)
                    return
                }
                if .now >= deadline {
                    // Alerts need not send the covered child another viewDidAppear on dismissal.
                    // Keep this durable request pending at a low polling rate until it is visible,
                    // superseded or torn down, rather than silently losing a late dismissal.
                    interval = .milliseconds(250)
                }
            }
        }
    }

    func tearDown() {
        tornDown = true; readinessWait?.cancel(); readinessWait = nil
        requestID = nil; onReady = nil
    }
}

/// Retained independently of SwiftUI teardown while UIKit copies the document to another app.
/// `didEndSendingToApplication` means the OS completed the send; a menu cancellation owns no send.
/// UIKit invokes these document-interaction UI callbacks on its main thread. This SDK's Objective-C
/// delegate protocol lacks that isolation annotation; the narrowly scoped `@preconcurrency`
/// conformance keeps the class/state MainActor-isolated and enables dynamic isolation checking.
/// https://developer.apple.com/documentation/uikit
@MainActor
final class CompanionDocumentTransfer: NSObject, @preconcurrency UIDocumentInteractionControllerDelegate {
    private static var active: [UUID: CompanionDocumentTransfer] = [:]
    static var activeTransferCount: Int { active.count }
    let sessionID: UUID
    private let session: CompanionHandoffSession
    private let controller: UIDocumentInteractionController
    private var onFinish: ((UUID, Bool) -> Void)?
    private var sending = false
    private var finished = false

    init(session: CompanionHandoffSession, onFinish: @escaping (UUID, Bool) -> Void) {
        self.session = session; sessionID = session.id; self.onFinish = onFinish
        controller = UIDocumentInteractionController(url: session.fileURL)
        super.init()
        controller.uti = session.targetApp.handoffDocumentTypeIdentifier
        controller.name = "Open in \(session.targetApp.rawValue)"
        controller.delegate = self
    }

    func present(from view: UIView) {
        Self.active[sessionID] = self
        guard controller.presentOpenInMenu(from: view.bounds, in: view, animated: true) else {
            finish(unavailable: true)
            return
        }
    }

    func cancelMenu() {
        controller.dismissMenu(animated: false)
        if !sending { finish(unavailable: false) }
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController, willBeginSendingToApplication application: String?) {
        sending = true
    }
    func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
        sending = false
        finish(unavailable: false)
    }
    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        if !sending { finish(unavailable: false) }
    }

    private func finish(unavailable: Bool) {
        guard !finished else { return }
        finished = true
        let handler = onFinish
        onFinish = nil
        Self.active.removeValue(forKey: sessionID)
        Task { @MainActor in handler?(sessionID, unavailable) }
    }
}
#endif
