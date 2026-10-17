import SwiftUI

/// First screen after the launch screen: the app icon rises out of the dark
/// with a lens-blue bloom behind it, a highlight sweeps across the glass, and
/// the wordmark settles in. `TetherApp` fades it out once launch work is done.
/// Starts on the same black as the launch screen so the hand-off is invisible.
/// Under Reduce Motion everything simply fades in.
struct SplashView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPhone: a wall of photographs. iPad and Mac: a centred splash card
    /// in the style of Lightroom and Resolve. (`IconSplash` stays for previews
    /// and as the fallback look.)
    static var introDuration: Duration {
        UIDevice.current.userInterfaceIdiom == .phone ? PhotoWallSplash.introDuration : CardSplash.introDuration
    }

    var body: some View {
        if sizeClass == .regular { CardSplash() } else { PhotoWallSplash() }
    }
}

struct IconSplash: View {
    @State private var iconIn = false
    @State private var bloom = false
    @State private var sweep: CGFloat = -1
    @State private var wordmark = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Roughly how long the intro takes to finish.
    static let introDuration: Duration = .milliseconds(1400)
    private static let iconSize: CGFloat = 148

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [TetherColor.accent.opacity(0.32), TetherColor.accentDeep.opacity(0.08), .clear],
                           center: .center, startRadius: 0, endRadius: 260)
                .frame(width: 520, height: 520)
                .offset(y: -40)
                .opacity(bloom ? 1 : 0)
                .scaleEffect(bloom ? 1 : 0.6)
            VStack(spacing: TetherSpace.xl) {
                icon
                VStack(spacing: TetherSpace.s) {
                    Text("Open Tether")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.white, TetherColor.steel], startPoint: .top, endPoint: .bottom))
                    Text("Tethered capture, wherever you shoot")
                        .tetherCaption()
                        .foregroundStyle(TetherColor.ink2)
                }
                .opacity(wordmark ? 1 : 0)
                .offset(y: wordmark || reduceMotion ? 0 : 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open Tether")
        .accessibilityAddTraits(.isHeader)
        .task { await play() }
    }

    private var icon: some View {
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: Self.iconSize, height: Self.iconSize)
            // A soft highlight passes across the icon once, like light over the lens.
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.45)
                        .rotationEffect(.degrees(20))
                        .offset(x: sweep * geo.size.width * 1.2)
                        .blendMode(.plusLighter)
                }
                .mask(Image("BrandIcon").resizable().scaledToFit())
                .allowsHitTesting(false)
            }
            .opacity(iconIn ? 1 : 0)
            .scaleEffect(iconIn || reduceMotion ? 1 : 0.82)
            .offset(y: iconIn || reduceMotion ? 0 : 14)
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { iconIn = true; bloom = true; wordmark = true }
            return
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { iconIn = true }
        withAnimation(.easeOut(duration: 0.9)) { bloom = true }
        try? await Task.sleep(for: .milliseconds(420))
        withAnimation(.easeInOut(duration: 0.7)) { sweep = 1.2 }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(TetherMotion.arrive) { wordmark = true }
    }
}

#Preview("Icon") { IconSplash() }
