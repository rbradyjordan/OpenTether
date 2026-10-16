import SwiftUI
import TetherCore
import UIKit

/// Fullscreen black, nothing but the picture. Exit = long-press a corner, then confirm.
struct ClientReviewView: View {
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFilename = false
    @State private var confirmExit = false
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
                    .onTapGesture { withAnimation { showFilename.toggle() } }
                    .gesture(swipe)
                VStack {
                    Spacer()
                    if showFilename {
                        Text(current.filename).font(.footnote).padding(8).background(.black.opacity(0.6), in: Capsule())
                            .transition(.opacity)
                    }
                    HStack(spacing: 18) {
                        RatingStars(rating: current.rating, size: 20) { model.rate(current.id, stars: $0) }
                        FlagButtons(flag: current.flag) { model.flag(current.id, $0) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 12)
                }
            }
            // Exit hot-corner (top-left) so a client tapping around never leaves the review.
            VStack {
                HStack {
                    Color.clear.frame(width: 72, height: 72).contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 1.2) { confirmExit = true }
                        .accessibilityLabel("Exit client review")
                        .accessibilityHint("Hold for one second, then confirm")
                    Spacer()
                }
                Spacer()
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .confirmationDialog("Leave client review?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Leave review") { dismiss() }
            Button("Stay", role: .cancel) {}
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            guard scale <= 1, let current, let i = items.firstIndex(where: { $0.id == current.id }) else { return }
            if value.translation.width < -40, i + 1 < items.count { model.select(items[i + 1].id) }
            if value.translation.width > 40, i > 0 { model.select(items[i - 1].id) }
        }
    }
}
