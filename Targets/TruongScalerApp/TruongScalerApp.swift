import SwiftUI
import UIKit
import TruongScalerCore
import DeepZoomGalleryUI
import BackgroundJobManager

@main
struct TruongScalerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: StudioViewModel

    init() {
        Diagnostics.shared.recordLaunch(
            configuration: {
                #if DEBUG
                return "Debug"
                #else
                return "Release"
                #endif
            }(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        LiveActivityController.endOrphanedActivitiesAfterColdLaunch()
        let model = StudioViewModel()
        _viewModel = State(initialValue: model)
        // Continued-processing launch handlers are registered per concrete job identifier by the
        // coordinator immediately before submission (the wildcard in
        // BGTaskSchedulerPermittedIdentifiers is only the Info.plist family declaration; the system
        // rejects registering the literal wildcard). Restore the saved library selection exactly
        // once here so a relaunch shows the library without re-picking the folder.
        model.restoreLibraryBookmarkIfAvailable()
        model.restoreOutputBookmarkIfAvailable()
    }

    var body: some Scene {
        WindowGroup {
            LibraryScreen(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await viewModel.releaseIdleImageCache() }
                }
                .onOpenURL { incomingURL in
                    viewModel.handleIncomingHandoffURL(incomingURL)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task {
                        await viewModel.handleScenePhaseChange(newPhase)
                    }
                }
        }
    }
}
