import SwiftUI

/// The 72 pt signature control. Tap: inner disc scales 0.92 → 1 with a rigid
/// haptic and a translucent ring expands outward (`pulse`). Long-press: the
/// ring turns hollow and reads "No AF"; release fires without autofocus.
struct CaptureRing: View {
    var enabled: Bool
    var busy: Bool
    var onCapture: (_ autofocus: Bool) -> Void

    @State private var pressed = false
    @State private var holding = false
    @State private var pulseScale: CGFloat = 1
    @State private var pulseOpacity: Double = 0
    @State private var fireCount = 0
    @GestureState private var isTouching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let diameter: CGFloat = 72

    var body: some View {
        ZStack {
            // Expanding pulse ring.
            Circle()
                .stroke(TetherColor.accent, lineWidth: 3)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
            // Accent stroke.
            Circle()
                .stroke(enabled ? TetherColor.accent : TetherColor.ink2, lineWidth: 3)
            // Inner disc; hollow while holding for "No AF".
            Circle()
                .fill(holding ? Color.clear : (enabled ? Color.white : TetherColor.ink2.opacity(0.5)))
                .overlay(Circle().strokeBorder(.white, lineWidth: holding ? 3 : 0))
                .padding(7)
                .scaleEffect(pressed ? 0.92 : 1)
            if holding {
                Text("No AF")
                    .font(TetherFont.hud)
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
            if busy {
                ProgressView().tint(holding ? .white : .black)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .gesture(pressGesture)
        .simultaneousGesture(longPress)
        .tetherHaptic(.capture, trigger: fireCount)
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: pressed)
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: holding)
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel("Shutter")
        .accessibilityValue(enabled ? (busy ? "capturing" : "ready") : "not available")
        .accessibilityHint("Double tap to capture with autofocus.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Capture without autofocus") { fire(autofocus: false) }
    }

    /// Tap = press feedback + capture with AF. Kept as a drag so the press
    /// scale shows for the whole touch, not only on release.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { _ in if enabled, !pressed, !holding { pressed = true } }
            .onEnded { value in
                let wasHolding = holding
                pressed = false
                holding = false
                guard enabled else { return }
                let inside = abs(value.translation.width) < 24 && abs(value.translation.height) < 24
                guard inside else { return }
                fire(autofocus: !wasHolding)
            }
    }

    private var longPress: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in if enabled { holding = true } }
    }

    private func fire(autofocus: Bool) {
        fireCount += 1
        onCapture(autofocus)
        pulse()
    }

    private func pulse() {
        if reduceMotion {
            // Opacity blink instead of expansion.
            pulseScale = 1
            pulseOpacity = TetherMotion.pulseOpacity
            withAnimation(.easeOut(duration: 0.3)) { pulseOpacity = 0 }
            return
        }
        pulseScale = 1
        pulseOpacity = TetherMotion.pulseOpacity
        withAnimation(TetherMotion.pulse) {
            pulseScale = TetherMotion.pulseScale
            pulseOpacity = 0
        }
    }
}
