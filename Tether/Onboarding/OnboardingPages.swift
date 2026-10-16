import Foundation
import SwiftUI

/// One full-bleed page: a title, one line, and a generated gradient placeholder.
struct OnboardingPage: Identifiable {
    var id: Int
    var title: String
    var symbol: String
    var line: String
    /// Hue pair for the placeholder imagery (no asset catalog on this pass).
    var gradient: [Color]
    var asksPermissions = false
}

enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(id: 0, title: "Shoot tethered, review live", symbol: "camera.aperture",
                       line: "Every frame lands on the phone as it is taken.",
                       gradient: [Color(red: 0.13, green: 0.11, blue: 0.10), Color(red: 0.55, green: 0.22, blue: 0.08)]),
        OnboardingPage(id: 1, title: "Nothing happens behind your back", symbol: "hand.raised",
                       line: "Tether never joins a network, uploads a photo or reads your library without asking.",
                       gradient: [Color(red: 0.08, green: 0.10, blue: 0.14), Color(red: 0.12, green: 0.30, blue: 0.42)]),
        OnboardingPage(id: 2, title: "Three permissions, each optional", symbol: "lock.shield",
                       line: "Local network to find cameras, Photos to save exports, Location only for the Wi-Fi name.",
                       gradient: [Color(red: 0.10, green: 0.12, blue: 0.10), Color(red: 0.16, green: 0.42, blue: 0.30)],
                       asksPermissions: true),
    ]

    /// Index maths for the paged progress indicator.
    static func isLast(_ page: Int) -> Bool { page >= pages.count - 1 }
}
