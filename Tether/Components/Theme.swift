import SwiftUI
import UIKit

// MARK: - Colour tokens (docs/DESIGN.md "Tokens › Colour")

/// Every colour token from the design system. Each resolves per trait
/// collection, so a screen under `ForceDark` gets the dark column while Home,
/// Sessions, Settings and Credits follow the system scheme.
enum TetherColor {
    static let ink0 = dynamic(light: 0x0B0B0C, dark: 0xF5F4F0)
    static let ink1 = dynamic(light: 0x4A4A4F, dark: 0xB8B7B2)
    static let ink2 = dynamic(light: 0x8A8A90, dark: 0x7A7975)
    static let surface0 = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let surface1 = dynamic(light: 0xF6F5F2, dark: 0x121214)
    static let surface2 = dynamic(light: 0xECEAE5, dark: 0x1C1C20)
    static let surface3 = dynamic(light: 0xE0DED8, dark: 0x26262B)
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
    static let accent = dynamic(light: 0xFF5A1F, dark: 0xFF6A2C)
    static let accentSoft = dynamic(light: 0xFF5A1F, dark: 0xFF6A2C, lightAlpha: 0.14, darkAlpha: 0.18)
    static let ok = dynamic(light: 0x2BB673, dark: 0x3DD68C)
    static let warn = dynamic(light: 0xE8A317, dark: 0xF2B63D)
    static let danger = dynamic(light: 0xE23D3D, dark: 0xFF5C5C)
    static let pick = dynamic(light: 0xFFC53D, dark: 0xFFD166)

    /// Colour labels are the same in both schemes.
    static let labelRed = Color(uiColor: UIColor(hex: 0xFF5C5C))
    static let labelYellow = Color(uiColor: UIColor(hex: 0xFFD166))
    static let labelGreen = Color(uiColor: UIColor(hex: 0x3DD68C))
    static let labelBlue = Color(uiColor: UIColor(hex: 0x4C8DFF))
    static let labelPurple = Color(uiColor: UIColor(hex: 0xB07CFF))

    /// Light-scheme card shadow; dark mode uses hairlines instead.
    static let shadow = Color.black.opacity(0.35)

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Type roles

/// The eight type roles. Dynamic Type comes from the text styles; the
/// numeral roles add monospaced digits so values never jitter.
enum TetherFont {
    /// 34 pt rounded semibold: onboarding titles, empty states.
    static let display = Font.system(.largeTitle, design: .rounded, weight: .semibold)
    /// 22 pt semibold: screen titles.
    static let title = Font.system(.title2, design: .default, weight: .semibold)
    /// 17 pt semibold: card titles, camera name.
    static let headline = Font.system(.body, design: .default, weight: .semibold)
    /// 17 pt regular: prose.
    static let body = Font.system(.body, design: .default, weight: .regular)
    /// 15 pt regular: descriptions.
    static let callout = Font.system(.subheadline, design: .default, weight: .regular)
    /// 12 pt medium; pair with `.tetherCaption()` for tracking and uppercase.
    static let caption = Font.system(.caption, design: .default, weight: .medium)
    /// 20 pt rounded semibold, mono digits: exposure chips.
    static let exposure = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
    /// 13 pt medium, mono digits: status pill, filmstrip badges.
    static let hud = Font.system(.footnote, design: .default, weight: .medium).monospacedDigit()
    /// Big numerals (credits balance): display role with mono digits.
    static let displayNumeral = Font.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit()
}

/// Caption role: 12 pt medium, tracking +0.4, uppercase.
struct TetherCaptionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TetherFont.caption)
            .tracking(0.4)
            .textCase(.uppercase)
    }
}

extension View {
    func tetherCaption() -> some View { modifier(TetherCaptionModifier()) }
}

// MARK: - Spacing and shape

enum TetherSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum TetherRadius {
    static let card: CGFloat = 20
    static let control: CGFloat = 14
    static let chip: CGFloat = 10
    static let pill: CGFloat = 999
}

/// Minimum hit target everywhere.
enum TetherHit {
    static let min: CGFloat = 44
}

// MARK: - Motion

enum TetherMotion {
    /// Selection, chips, toggles.
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// New frame into filmstrip, cards.
    static let arrive = Animation.spring(response: 0.42, dampingFraction: 0.80)
    /// Sheets, canvas crossfade.
    static let settle = Animation.spring(response: 0.55, dampingFraction: 0.90)
    /// Capture ring: 0.9 s ease-out, scale 1 → 1.6, opacity 0.6 → 0.
    static let pulse = Animation.easeOut(duration: 0.9)
    static let pulseDuration: Double = 0.9
    static let pulseScale: CGFloat = 1.6
    static let pulseOpacity: Double = 0.6
    /// What every spring becomes under Reduce Motion.
    static let reduced = Animation.easeOut(duration: 0.16)
}

/// Picks the spring or its Reduce Motion replacement. Pure so it is testable.
enum Motion {
    static func spring(_ animation: Animation, reduce: Bool) -> Animation {
        reduce ? TetherMotion.reduced : animation
    }

    /// Under Reduce Motion the capture pulse becomes an opacity blink.
    static func pulseScale(reduce: Bool) -> CGFloat {
        reduce ? 1 : TetherMotion.pulseScale
    }
}

extension View {
    /// `withAnimation` for views: reads Reduce Motion from the environment.
    func tetherAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducedMotionAnimation(animation: animation, value: value))
    }
}

private struct ReducedMotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animation: Animation
    var value: V

    func body(content: Content) -> some View {
        content.animation(Motion.spring(animation, reduce: reduceMotion), value: value)
    }
}

// MARK: - Haptics

/// One haptic per named event; never more than one per event.
enum TetherHaptic {
    enum Kind {
        case capture, frameArrived, rate, pick, reject, connected, disconnected

        /// The `.sensoryFeedback` equivalent, for trigger-driven views.
        var sensory: SensoryFeedback {
            switch self {
            case .capture: return .impact(flexibility: .rigid)
            case .frameArrived: return .impact(flexibility: .soft)
            case .rate: return .selection
            case .pick, .reject: return .impact(weight: .light)
            case .connected: return .success
            case .disconnected: return .warning
            }
        }

        /// UIKit fallback for code paths without a view trigger (view models, gestures).
        @MainActor func play() {
            switch self {
            case .capture: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            case .frameArrived: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case .rate: UISelectionFeedbackGenerator().selectionChanged()
            case .pick, .reject: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .connected: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .disconnected: UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    @MainActor static func capture() { Kind.capture.play() }
    @MainActor static func frameArrived() { Kind.frameArrived.play() }
    @MainActor static func rate() { Kind.rate.play() }
    @MainActor static func pick() { Kind.pick.play() }
    @MainActor static func reject() { Kind.reject.play() }
    @MainActor static func connected() { Kind.connected.play() }
    @MainActor static func disconnected() { Kind.disconnected.play() }
}

extension View {
    /// Plays `haptic` whenever `trigger` changes.
    func tetherHaptic<T: Equatable>(_ haptic: TetherHaptic.Kind, trigger: T) -> some View {
        sensoryFeedback(haptic.sensory, trigger: trigger)
    }
}

// MARK: - Surface modifiers

/// Card: `surface2`, radius 20, hairline in dark, one soft shadow in light.
struct TetherCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var surface: Color = TetherColor.surface2

    func body(content: Content) -> some View {
        content
            .background(surface, in: RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous)
                    .strokeBorder(TetherColor.hairline, lineWidth: scheme == .dark ? 0.5 : 0)
            )
            .shadow(color: scheme == .dark ? Color.clear : TetherColor.shadow, radius: 24, y: 8)
    }
}

/// Chip: `surface2` resting, `accentSoft` fill plus accent hairline when selected.
struct TetherChipModifier: ViewModifier {
    var selected: Bool

    func body(content: Content) -> some View {
        content
            .background(selected ? TetherColor.accentSoft : TetherColor.surface2,
                        in: RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous)
                    .strokeBorder(selected ? TetherColor.accent : TetherColor.hairline, lineWidth: selected ? 1 : 0.5)
            )
    }
}

/// 0.5 pt hairline on any rounded shape.
struct HairlineBorderModifier: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(TetherColor.hairline, lineWidth: 0.5)
        )
    }
}

/// Image-first screens (Connect progress, Shoot, Review, Looks, Client review)
/// are always dark regardless of the system setting.
struct ForceDark: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func tetherCard(surface: Color = TetherColor.surface2) -> some View { modifier(TetherCardModifier(surface: surface)) }
    func tetherChip(selected: Bool) -> some View { modifier(TetherChipModifier(selected: selected)) }
    func hairlineBorder(radius: CGFloat = TetherRadius.control) -> some View { modifier(HairlineBorderModifier(radius: radius)) }
    func forceDark() -> some View { modifier(ForceDark()) }
    /// Dark tokens for one card inside a system-scheme screen (the connect progress card).
    func darkSurface() -> some View { environment(\.colorScheme, .dark) }
    /// Canvas overlays cap Dynamic Type at XXL; every other screen scales to accessibility sizes.
    func overlayTypeCap() -> some View { dynamicTypeSize(...DynamicTypeSize.xxLarge) }
    /// Legacy name kept for the few screens not yet on `tetherCard`.
    func cardBackground() -> some View { tetherCard() }
}

// MARK: - Legacy aliases

/// Pre-design-system names, mapped onto the tokens so older screens keep compiling.
enum Theme {
    static let accent = TetherColor.accent
    static let background = TetherColor.surface1
    static let surface = TetherColor.surface2
    static let surfaceRaised = TetherColor.surface3
    static let stroke = TetherColor.hairline
    static let textSecondary = TetherColor.ink1
    static let success = TetherColor.ok
    static let warning = TetherColor.warn
    static let danger = TetherColor.danger

    static let cornerRadius: CGFloat = TetherRadius.control
}

enum ColorLabelStyle {
    static func color(for label: TetherCoreColorLabel) -> Color {
        switch label {
        case .none: return .clear
        case .red: return TetherColor.labelRed
        case .yellow: return TetherColor.labelYellow
        case .green: return TetherColor.labelGreen
        case .blue: return TetherColor.labelBlue
        case .purple: return TetherColor.labelPurple
        }
    }
}
