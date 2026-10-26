import SwiftUI

// MARK: - Liquid Glass

/// The one surface material: Liquid Glass on iOS 26 and later, a flat
/// ultra-thin material with a faint hairline before that. Flat by design: no
/// gradients, no drop shadows; depth comes from the glass itself.
struct TetherGlass<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                }
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        }
    }
}

extension View {
    /// Liquid Glass in `shape`, optionally tinted; `interactive` makes it
    /// respond to touch (buttons).
    func tetherGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(TetherGlass(shape: shape, tint: tint, interactive: interactive))
    }

    /// Glass card: the default container for grouped content.
    func tetherGlassCard(radius: CGFloat = TetherRadius.card, tint: Color? = nil) -> some View {
        tetherGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }
}

// MARK: - Buttons

/// Primary action: accent-tinted Liquid Glass capsule, white label. Sizes
/// follow `controlSize`; presses dip to 0.97 with the `snap` spring.
struct TetherPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let metrics = ButtonMetrics(controlSize)
        configuration.label
            .font(metrics.font.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : TetherColor.ink2)
            .padding(.horizontal, metrics.horizontal)
            .frame(minHeight: metrics.height)
            .contentShape(Capsule())
            .tetherGlass(in: Capsule(), tint: isEnabled ? TetherColor.accent : nil, interactive: true)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: configuration.isPressed)
    }
}

/// Secondary action: clear Liquid Glass capsule with an accent label.
struct TetherSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let metrics = ButtonMetrics(controlSize)
        configuration.label
            .font(metrics.font.weight(.semibold))
            .foregroundStyle(isEnabled ? TetherColor.accent : TetherColor.ink2)
            .padding(.horizontal, metrics.horizontal)
            .frame(minHeight: metrics.height)
            .contentShape(Capsule())
            .tetherGlass(in: Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: configuration.isPressed)
    }
}

private struct ButtonMetrics {
    var height: CGFloat
    var horizontal: CGFloat
    var font: Font

    init(_ size: ControlSize) {
        switch size {
        case .mini, .small: self.init(height: 34, horizontal: 14, font: .subheadline)
        case .large, .extraLarge: self.init(height: 54, horizontal: 28, font: .body)
        default: self.init(height: 44, horizontal: 20, font: .body)
        }
    }

    private init(height: CGFloat, horizontal: CGFloat, font: Font) {
        self.height = height
        self.horizontal = horizontal
        self.font = font
    }
}

extension ButtonStyle where Self == TetherPrimaryButtonStyle {
    static var tetherPrimary: TetherPrimaryButtonStyle { TetherPrimaryButtonStyle() }
}

extension ButtonStyle where Self == TetherSecondaryButtonStyle {
    static var tetherSecondary: TetherSecondaryButtonStyle { TetherSecondaryButtonStyle() }
}

// MARK: - Backgrounds

/// Every non-canvas screen sits on this: graphite with a faint lens-blue glow
/// from the top, like light catching glass. Purely decorative.
struct ScreenBackground: View {
    var body: some View {
        ZStack {
            TetherColor.surface1
            RadialGradient(colors: [TetherColor.accent.opacity(0.20), .clear],
                           center: UnitPoint(x: 0.5, y: -0.05), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color(hex: 0x6F7BFF).opacity(0.10), .clear],
                           center: UnitPoint(x: 1.1, y: 0.45), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(hex: 0x37C6C0).opacity(0.06), .clear],
                           center: UnitPoint(x: -0.1, y: 0.85), startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Ambient screen background.
    func tetherScreen() -> some View { background(ScreenBackground()) }

    /// Lists and forms: hide the system grouped background so the ambient
    /// screen shows through; rows sit on graphite cards.
    func tetherList() -> some View {
        scrollContentBackground(.hidden)
            .background(ScreenBackground())
    }
}

// MARK: - Icon tile

/// A symbol in a small flat rounded tile; accent-filled when `active`. Used
/// by hub cards, settings rows and section headers (it sits on glass, so it
/// is not glass itself).
struct IconTile: View {
    var systemImage: String
    var active = false
    var size: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(active ? Color.white : TetherColor.ink0)
            .frame(width: size, height: size)
            .background(active ? AnyShapeStyle(TetherColor.accent) : AnyShapeStyle(Color.white.opacity(0.08)), in: shape)
            .accessibilityHidden(true)
    }
}

// MARK: - Entrance

/// Rises and fades in once, `index` steps after its siblings, so a stack of
/// cards arrives as a sequence rather than all at once. Plain fade under
/// Reduce Motion.
struct StaggeredAppear: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                let animation = reduceMotion ? TetherMotion.reduced : TetherMotion.arrive.delay(0.05 * Double(index))
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}

/// Screen intro under the large title: one line saying what to do here.
struct ScreenIntro: View {
    var text: String

    var body: some View {
        Text(text)
            .font(TetherFont.callout)
            .foregroundStyle(TetherColor.ink1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TetherSpace.xs)
            .padding(.bottom, TetherSpace.xs)
    }
}

// MARK: - Text fields

/// Flat translucent field, accent edge while focused; replaces `.roundedBorder` everywhere.
struct TetherFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .focused($focused)
            .padding(.horizontal, TetherSpace.m)
            .frame(minHeight: TetherHit.min)
            .background(Color.white.opacity(focused ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: TetherRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TetherRadius.control, style: .continuous)
                    .strokeBorder(TetherColor.accent.opacity(focused ? 1 : 0), lineWidth: 1)
            )
            .animation(TetherMotion.snap, value: focused)
    }
}

extension TextFieldStyle where Self == TetherFieldStyle {
    static var tether: TetherFieldStyle { TetherFieldStyle() }
}

/// A caption label above a field, so a filled-in value still says what it is.
struct LabeledField<Field: View>: View {
    var label: String
    @ViewBuilder var field: () -> Field

    init(_ label: String, @ViewBuilder field: @escaping () -> Field) {
        self.label = label
        self.field = field
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.xs) {
            Text(label).tetherCaption().foregroundStyle(TetherColor.ink2)
            field()
        }
    }
}

/// Plain button that dips to 0.94 while pressed (icon buttons, tools).
struct PressScaleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
