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
    @State private var confirmExit = false
    @State private var showHint = true
    @State private var cornerHeld = false
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
        .confirmationDialog("Leave client review?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Leave review") { dismiss() }
            Button("Stay", role: .cancel) {}
        }
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
            Text("swipe · tap for name · hold corner to leave")
                .font(TetherFont.hud)
                .foregroundStyle(TetherColor.ink1)
                .padding(.horizontal, TetherSpace.l).padding(.vertical, TetherSpace.s)
                .background(Color.black.opacity(0.7), in: Capsule())
                .padding(.bottom, TetherSpace.xxl + TetherSpace.l)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Top-left 72 pt corner. A client tapping around never leaves by accident.
    private var hotCorner: some View {
        VStack {
            HStack {
                Circle()
                    .fill(TetherColor.ink0.opacity(cornerHeld ? 0.25 : 0))
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.2, pressing: { cornerHeld = $0 }) {
                        cornerHeld = false
                        confirmExit = true
                    }
                    .animation(.easeOut(duration: 0.2), value: cornerHeld)
                    .accessibilityLabel("Exit client review")
                    .accessibilityHint("Hold for one second, then confirm")
                    .accessibilityAddTraits(.isButton)
                Spacer()
            }
            Spacer()
        }
        .ignoresSafeArea()
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            guard scale <= 1, let current, let i = items.firstIndex(where: { $0.id == current.id }) else { return }
            if value.translation.width < -40, i + 1 < items.count { model.select(items[i + 1].id) }
            if value.translation.width > 40, i > 0 { model.select(items[i - 1].id) }
        }
    }
}
