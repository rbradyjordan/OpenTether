import SwiftUI

/// Display-type title, one line of guidance, at most one action.
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: TetherSpace.m) {
            EmptyStateMedallion(systemImage: systemImage)
                .padding(.bottom, TetherSpace.s)
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(TetherColor.ink0)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(TetherFont.callout)
                    .foregroundStyle(TetherColor.ink1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.tetherPrimary)
                    .controlSize(.large)
                    .padding(.top, TetherSpace.s)
            }
        }
        .padding(TetherSpace.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The empty-state glyph: a glass disc with a faint blue glow
/// behind it that breathes slowly (still under Reduce Motion).
struct EmptyStateMedallion: View {
    var systemImage: String
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [TetherColor.accent.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 80))
                .frame(width: 160, height: 160)
                .scaleEffect(breathe ? 1.06 : 0.94)
                .opacity(breathe ? 1 : 0.7)
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(TetherColor.ink0)
                .frame(width: 92, height: 92)
                .tetherGlass(in: Circle())
        }
        .frame(height: 140)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
