import SwiftUI

struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.m) {
            if let title {
                HStack(spacing: TetherSpace.s) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(TetherColor.accent) }
                    Text(title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                }
                .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(TetherSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tetherCard()
    }
}

/// `ok` dot that pulses one ring outward when `isLive` becomes true.
struct LiveDot: View {
    var isLive: Bool
    @State private var pulseID = 0
    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(TetherColor.ok, lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
            Circle()
                .fill(isLive ? TetherColor.ok : TetherColor.ink2)
                .frame(width: 10, height: 10)
        }
        .frame(width: 24, height: 24)
        .onChange(of: isLive) { _, live in if live { pulseOnce() } }
        .onAppear { if isLive { pulseOnce() } }
        .accessibilityHidden(true)
    }

    private func pulseOnce() {
        if reduceMotion {
            ringOpacity = 0.6
            withAnimation(.easeOut(duration: 0.4)) { ringOpacity = 0 }
            return
        }
        ringScale = 1
        ringOpacity = TetherMotion.pulseOpacity
        withAnimation(TetherMotion.pulse) {
            ringScale = 2.2
            ringOpacity = 0
        }
    }
}

/// A tappable hub card with an optional live indicator.
struct ActionCard: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var badge: String?
    var isLive = false

    var body: some View {
        HStack(spacing: TetherSpace.l) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isLive ? TetherColor.accent : TetherColor.ink1)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: TetherSpace.xs) {
                HStack(spacing: TetherSpace.s) {
                    Text(title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                    if let badge {
                        Text(badge).font(TetherFont.hud)
                            .padding(.horizontal, TetherSpace.s).padding(.vertical, 2)
                            .background(TetherColor.accentSoft, in: Capsule())
                            .foregroundStyle(TetherColor.accent)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                Text(subtitle).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
            }
            Spacer(minLength: TetherSpace.s)
            LiveDot(isLive: isLive)
            Image(systemName: "chevron.right").font(TetherFont.hud).foregroundStyle(TetherColor.ink2)
        }
        .padding(TetherSpace.l)
        .frame(minHeight: 72)
        .tetherCard()
        .contentShape(Rectangle())
        .tetherAnimation(TetherMotion.snap, value: badge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [title]
        if let badge { parts.append(badge) }
        if isLive { parts.append("camera visible") }
        parts.append(subtitle)
        return parts.joined(separator: ". ")
    }
}
