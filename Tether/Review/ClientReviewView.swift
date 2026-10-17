import SwiftUI
import TetherCore
import UIKit

/// True black, image only, gestures only. A hint fades after two seconds;
/// the only way out is holding the top-left corner, then confirming.
struct ClientReviewView: View {
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFilename = false
    @State private var showHint = true
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    private var items: [CaptureItem] { model.readyItems }
    private var current: CaptureItem? { model.displayedItem }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let current {
                RenderedCaptureImage(model: model, itemID: current.id, scale: $scale, offset: $offset)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(Motion.spring(TetherMotion.snap, reduce: reduceMotion)) { showFilename.toggle() } }
                    .gesture(swipe)
                VStack {
                    Spacer()
                    if showFilename {
                        Text(current.filename)
                            .font(TetherFont.hud)
                            .foregroundStyle(TetherColor.ink0)
                            .padding(.horizontal, TetherSpace.m).padding(.vertical, TetherSpace.s)
                            .background(Color.black.opacity(0.6), in: Capsule())
                            .transition(.opacity)
                            .padding(.bottom, TetherSpace.xl)
                    }
                }
            }
            hotCorner
            if showHint { hint.transition(.opacity) }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .forceDark()
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: reduceMotion ? 0.16 : 0.5)) { showHint = false }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var hint: some View {
        VStack {
            Spacer()
            Text("swipe · tap for name · hold Exit to leave")
                .font(TetherFont.hud)
                .foregroundStyle(TetherColor.ink1)
                .padding(.horizontal, TetherSpace.l).padding(.vertical, TetherSpace.s)
                .background(Color.black.opacity(0.7), in: Capsule())
                .padding(.bottom, TetherSpace.xxl + TetherSpace.l)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A faint "Hold to exit" button inside the safe area: always findable,
    /// but a client tapping around never leaves by accident.
    private var hotCorner: some View {
        VStack {
            HStack {
                HoldToExitButton { dismiss() }
                Spacer()
            }
            Spacer()
        }
        .padding(TetherSpace.m)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            guard scale <= 1, let current, let i = items.firstIndex(where: { $0.id == current.id }) else { return }
            if value.translation.width < -40, i + 1 < items.count { model.select(items[i + 1].id) }
            if value.translation.width > 40, i > 0 { model.select(items[i - 1].id) }
        }
    }
}

/// Press and hold for 0.8 s; a ring fills while held and the review closes
/// when it completes. Letting go early cancels.
private struct HoldToExitButton: View {
    var action: () -> Void
    @State private var holding = false

    private static let hold: Double = 0.8

    var body: some View {
        HStack(spacing: TetherSpace.xs) {
            ZStack {
                Circle().stroke(TetherColor.ink0.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: holding ? 1 : 0)
                    .stroke(TetherColor.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(holding ? .linear(duration: Self.hold) : .easeOut(duration: 0.15), value: holding)
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .frame(width: 22, height: 22)
            Text(holding ? "Keep holding" : "Hold to exit").font(TetherFont.hud)
        }
        .foregroundStyle(TetherColor.ink0)
        .padding(.horizontal, TetherSpace.m)
        .frame(minHeight: TetherHit.min)
        .background(Color.black.opacity(0.55), in: Capsule())
        .opacity(holding ? 1 : 0.55)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: Self.hold, pressing: { holding = $0 }) {
            holding = false
            action()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exit client review")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
