import UIKit

/// The few places the Mac (Catalyst) build behaves differently from iOS.
enum MacSupport {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// Wi-Fi settings: System Settings → Wi-Fi on the Mac, the app's page in
    /// Settings on iOS (iOS has no public link straight to Wi-Fi).
    @MainActor static func openWiFiSettings() {
        let link = isMac ? "x-apple.systempreferences:com.apple.wifi-settings-extension" : UIApplication.openSettingsURLString
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    /// Default and minimum window size on the Mac, in points (the Mac idiom
    /// draws at 100 %). The default is wide enough for the side-by-side shoot
    /// layout (`TetherLayout.shootSideBySideMinWidth`).
    static let defaultWindowSize = CGSize(width: 1280, height: 820)
    static let minimumWindowSize = CGSize(width: 800, height: 600)
}

import SwiftUI

extension View {
    /// The Mac idiom draws un-styled buttons with a bezel and menus as
    /// pull-down buttons with a chevron. The app's controls draw their own
    /// glass, so ask for the plain iOS look instead. Style environment does
    /// not cross UIKit presentations, so sheets and covers apply it again.
    /// No-op on iOS.
    @ViewBuilder func macControlStyle() -> some View {
        #if targetEnvironment(macCatalyst)
        buttonStyle(.plain)
            .menuStyle(.button)
            .menuIndicator(.hidden)
        #else
        self
        #endif
    }

    /// The Mac toolbar fills an image button with its tint, so the app's
    /// accent turns toolbar icons into solid blue discs. Use the default
    /// (neutral) tint there. No-op on iOS.
    @ViewBuilder func macToolbarTint() -> some View {
        #if targetEnvironment(macCatalyst)
        tint(nil)
        #else
        self
        #endif
    }
}
