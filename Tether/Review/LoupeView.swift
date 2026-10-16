import SwiftUI
import TetherCore

/// Full-screen single frame: spring zoom, swipe between frames, metadata in
/// `hud` type, rating and flags in the thumb zone.
struct LoupeView: View {
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var showInfo = true

    private var items: [CaptureItem] { model.readyItems }
    private var current: CaptureItem? { model.displayedItem }

    var body: some View {
        ZStack {
            TetherColor.surface0.ignoresSafeArea()
            if let current {
                RenderedCaptureImage(model: model, itemID: current.id, scale: $scale, offset: $offset)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(Motion.spring(TetherMotion.snap, reduce: reduceMotion)) { showInfo.toggle() } }
                    .gesture(swipe)
                if showInfo {
                    chrome(current).transition(.opacity)
                }
            } else {
                EmptyState(systemImage: "photo", title: "Nothing to show", message: "Captures appear here once they download.")
            }
        }
        .statusBarHidden(true)
        .forceDark()
        .overlayTypeCap()
    }

    private func chrome(_ current: CaptureItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TetherColor.ink0)
                        .frame(width: TetherHit.min, height: TetherHit.min)
                        .background(TetherColor.surface2.opacity(0.8), in: Circle())
                }
                .accessibilityLabel("Close loupe")
                Spacer()
                TonePill(text: "\(index(of: current) + 1) / \(items.count)")
            }
            .padding(TetherSpace.l)
            Spacer()
            VStack(spacing: TetherSpace.s) {
                MetadataStrip(item: current, position: nil)
                HStack(spacing: TetherSpace.m) {
                    FlagButton(kind: .reject, flag: current.flag) { model.flag(current.id, $0) }
                    Spacer(minLength: 0)
                    RatingStars(rating: current.rating, size: 28) { model.rate(current.id, stars: $0) }
                    Spacer(minLength: 0)
                    FlagButton(kind: .pick, flag: current.flag) { model.flag(current.id, $0) }
                }
                .padding(.horizontal, TetherSpace.l)
                .padding(.bottom, TetherSpace.m)
            }
            .background(Color.black.opacity(0.6))
        }
    }

    private func index(of item: CaptureItem) -> Int { items.firstIndex { $0.id == item.id } ?? 0 }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            guard scale <= 1, let current else { return }
            let i = index(of: current)
            if value.translation.width < -40, i + 1 < items.count { model.select(items[i + 1].id) }
            if value.translation.width > 40, i > 0 { model.select(items[i - 1].id) }
            if value.translation.height > 80 { dismiss() }
        }
    }
}
