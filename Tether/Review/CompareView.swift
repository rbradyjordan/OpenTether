import SwiftUI
import TetherCore

/// Two-up with synced zoom; tap a side to pick which item it shows.
struct CompareView: View {
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var leftID: String?
    @State private var rightID: String?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var picking: Side?

    enum Side { case left, right }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let vertical = geo.size.width < geo.size.height
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
                layout {
                    pane(leftID, .left)
                    pane(rightID, .right)
                }
            }
            .background(Color.black)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { let l = leftID; leftID = rightID; rightID = l } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                }
            }
            .sheet(item: $picking) { side in picker(side) }
            .onAppear {
                let ready = model.readyItems
                leftID = model.displayedItem?.id ?? ready.last?.id
                rightID = ready.last { $0.id != leftID }?.id
            }
        }
    }

    private func pane(_ id: String?, _ side: Side) -> some View {
        ZStack(alignment: .bottomLeading) {
            RenderedCaptureImage(model: model, itemID: id, scale: $scale, offset: $offset)
            if let item = model.items.first(where: { $0.id == id }) {
                HStack(spacing: 6) {
                    Text(item.filename).font(.caption)
                    RatingDots(rating: item.rating)
                    Spacer()
                    Button("Change") { picking = side }.font(.caption).buttonStyle(.bordered).controlSize(.mini)
                }
                .padding(8)
                .background(.black.opacity(0.5))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(side == .left ? "Left" : "Right") image")
    }

    private func picker(_ side: Side) -> some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                    ForEach(model.readyItems) { item in
                        AsyncImageView(cache: model.renderCache.proxyCache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath, contentMode: .fill, maxPixelSize: 320)
                            .frame(height: 90).clipped().cornerRadius(6)
                            .onTapGesture {
                                if side == .left { leftID = item.id } else { rightID = item.id }
                                picking = nil
                            }
                            .accessibilityLabel(item.filename)
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(12)
            }
            .navigationTitle(side == .left ? "Left image" : "Right image")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

extension CompareView.Side: Identifiable {
    var id: Int { self == .left ? 0 : 1 }
}
