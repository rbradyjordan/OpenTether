import SwiftUI
import TetherCore

struct LoupeView: View {
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var showInfo = true

    private var items: [CaptureItem] { model.readyItems }
    private var current: CaptureItem? { model.displayedItem }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let current {
                RenderedCaptureImage(model: model, itemID: current.id, scale: $scale, offset: $offset)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showInfo.toggle() } }
                    .gesture(swipe)
                if showInfo {
                    VStack {
                        HStack {
                            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3).padding(10).background(.black.opacity(0.5), in: Circle()) }
                                .accessibilityLabel("Close loupe")
                            Spacer()
                            Text("\(index(of: current) + 1) / \(items.count)").font(.footnote.monospacedDigit()).padding(8).background(.black.opacity(0.5), in: Capsule())
                        }
                        .padding()
                        Spacer()
                        metadata(current)
                    }
                }
            } else {
                EmptyState(systemImage: "photo", title: "Nothing to show", message: "Captures appear here once they download.")
            }
        }
        .statusBarHidden(true)
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

    private func metadata(_ item: CaptureItem) -> some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).font(.subheadline.weight(.semibold))
                    Text("\(item.width)×\(item.height) · \(item.capturedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.textSecondary)
                    if let line = item.exposure?.line, !line.isEmpty { Text(line).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
                FlagButtons(flag: item.flag) { model.flag(item.id, $0) }
            }
            RatingStars(rating: item.rating, size: 24) { model.rate(item.id, stars: $0) }
        }
        .padding(16)
        .background(.black.opacity(0.6))
    }
}
