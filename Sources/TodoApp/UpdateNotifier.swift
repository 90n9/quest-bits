import Foundation
import Combine

/// Bridge between Sparkle's delegate callbacks (in AppDelegate) and SwiftUI.
/// AppDelegate writes; the in-window update banner observes and renders with an
/// "Update Now" button that re-presents the native install dialog. Menu items
/// ("Check for Updates…") route through `requestCheck` so every UI entry point
/// drives the same SPUStandardUpdaterController.
final class UpdateNotifier: ObservableObject {
    static let shared = UpdateNotifier()

    @Published var availableVersion: String?
    /// The banner was closed for this version. The sidebar footer keeps offering the update.
    @Published var bannerDismissed = false

    /// Re-presents Sparkle's install dialog for an already-found update.
    var onInstallTapped: (() -> Void)?
    /// Triggers an explicit user-initiated update check.
    var requestCheck: (() -> Void)?

    private init() {}

    func setAvailable(version: String?) {
        let apply = {
            // A different version shows the banner again.
            if version != self.availableVersion { self.bannerDismissed = false }
            self.availableVersion = version
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Close the banner until another version is found.
    func dismiss() {
        bannerDismissed = true
    }
}
