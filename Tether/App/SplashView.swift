import SwiftUI

/// First screen after the launch screen: the mark draws itself (ring, cable,
/// disc), the wordmark rises in, and `TetherApp` fades the whole thing out
/// once launch work is done. Starts on the same black as the launch screen so
/// the hand-off is invisible. Under Reduce Motion everything simply fades in.
struct SplashView: View {
    @State private var ring: CGFloat = 0
    @State private var cable: CGFloat = 0
    @State private var disc: CGFloat = 0
    @State private var wordmark = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Roughly how long the intro takes to finish drawing.
    static let introDuration: Duration = .milliseconds(1400)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: TetherSpace.xl) {
                OpenTetherMark(ring: ring, cable: cable, disc: disc,
                               ringColor: TetherColor.accent, cableColor: TetherColor.accent, discColor: .white)
                    .frame(width: 132, height: 132)
                VStack(spacing: TetherSpace.xs) {
                    Text("Open Tether")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(TetherColor.ink0)
                    Text("Tethered capture, wherever you shoot")
                        .tetherCaption()
                        .foregroundStyle(TetherColor.ink2)
                }
                .opacity(wordmark ? 1 : 0)
                .offset(y: wordmark || reduceMotion ? 0 : 10)
            }
        }
        .forceDark()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open Tether")
        .accessibilityAddTraits(.isHeader)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            ring = 1; cable = 1; disc = 1
            withAnimation(.easeOut(duration: 0.3)) { wordmark = true }
            return
        }
        withAnimation(.easeInOut(duration: 0.6)) { ring = 1 }
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.easeOut(duration: 0.45)) { cable = 1 }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { disc = 1 }
        try? await Task.sleep(for: .milliseconds(180))
        withAnimation(TetherMotion.arrive) { wordmark = true }
    }
}

#Preview {
    SplashView()
}
