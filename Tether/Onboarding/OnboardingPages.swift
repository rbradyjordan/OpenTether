import Foundation
import SwiftUI

/// One full-bleed page: a hero (the app icon or a symbol medallion), a title
/// and one line, over graphite with a coloured glow.
struct OnboardingPage: Identifiable {
    var id: Int
    var title: String
    var symbol: String
    var line: String
    /// Glow colour behind the hero.
    var glow: Color
    /// Asset to show instead of the symbol (the first page shows the app icon).
    var heroImage: String?
    var asksPermissions = false
}

enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(id: 0, title: "Shoot tethered,\nreview live", symbol: "camera.aperture",
                       line: "Every frame lands on your phone the moment you take it.",
                       glow: Color(hex: 0x4A9DFF), heroImage: "BrandIcon"),
        OnboardingPage(id: 1, title: "Nothing happens behind your back", symbol: "hand.raised.fill",
                       line: "Open Tether never joins a network, uploads a photo or reads your library without asking.",
                       glow: Color(hex: 0x7B6CFF)),
        OnboardingPage(id: 2, title: "Three quick permissions", symbol: "lock.shield.fill",
                       line: "Each is optional. You can allow them now or when a feature needs them.",
                       glow: Color(hex: 0x37C6C0),
                       asksPermissions: true),
    ]

    /// Index maths for the paged progress indicator.
    static func isLast(_ page: Int) -> Bool { page >= pages.count - 1 }
}
