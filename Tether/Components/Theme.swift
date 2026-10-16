import SwiftUI

/// Dark-first palette: the shoot screen is near-black with one accent.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.64, blue: 0.22)
    static let background = Color.black
    static let surface = Color(white: 0.09)
    static let surfaceRaised = Color(white: 0.15)
    static let stroke = Color(white: 0.22)
    static let textSecondary = Color(white: 0.66)
    static let success = Color(red: 0.36, green: 0.80, blue: 0.47)
    static let warning = Color(red: 0.98, green: 0.78, blue: 0.28)
    static let danger = Color(red: 0.95, green: 0.36, blue: 0.36)

    static let cornerRadius: CGFloat = 14
}

extension View {
    func cardBackground() -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension ColorLabelStyle {
    static func color(for label: TetherCoreColorLabel) -> Color {
        switch label {
        case .none: return .clear
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

enum ColorLabelStyle {}
