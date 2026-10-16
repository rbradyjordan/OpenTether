import SwiftUI
import TetherCore

/// Two-up with synced spring zoom; tap "Change" on a side to pick its frame.
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
                    ComparePane(model: model, itemID: leftID, side: .left, scale: $scale, offset: $offset) { picking = .left }
                    ComparePane(model: model, itemID: rightID, side: .right, scale: $scale, offset: $offset) { picking = .right }
                }
            }
            .background(TetherColor.surface0)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { let l = leftID; leftID = rightID; rightID = l } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                }
            }
            .sheet(item: $picking) { side in ComparePicker(model: model, side: side) { id in
                if side == .left { leftID = id } else { rightID = id }
                picking = nil
            } }
            .onAppear {
                let ready = model.readyItems
                leftID = model.displayedItem?.id ?? ready.last?.id
                rightID = ready.last { $0.id != leftID }?.id
            }
        }
        .forceDark()
        .overlayTypeCap()
    }
}

private struct ComparePane: View {
    var model: ShootViewModel
    var itemID: String?
    var side: CompareView.Side
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    var onChange: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            RenderedCaptureImage(model: model, itemID: itemID, scale: $scale, offset: $offset)
            if let item = model.items.first(where: { $0.id == itemID }) {
                HStack(spacing: TetherSpace.s) {
                    MetadataStrip(item: item, position: nil)
                    Button("Change", action: onChange)
                        .font(TetherFont.hud)
                        .buttonStyle(.bordered)
                        .tint(TetherColor.ink1)
                        .frame(minHeight: TetherHit.min)
                        .padding(.trailing, TetherSpace.s)
                }
                .background(Color.black.opacity(0.55))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(side == .left ? "Left" : "Right") image")
    }
}

private struct ComparePicker: View {
    var model: ShootViewModel
    var side: CompareView.Side
    var onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: TetherSpace.s)], spacing: TetherSpace.s) {
                    ForEach(model.readyItems) { item in
                        Button { onPick(item.id) } label: {
                            AsyncImageView(cache: model.renderCache.proxyCache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath,
                                           contentMode: .fill, maxPixelSize: 320)
                                .frame(height: 100).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous))
                                .hairlineBorder(radius: TetherRadius.chip)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.filename)
                    }
                }
                .padding(TetherSpace.m)
            }
            .background(TetherColor.surface1)
            .navigationTitle(side == .left ? "Left image" : "Right image")
            .navigationBarTitleDisplayMode(.inline)
        }
        .forceDark()
        .presentationDetents([.medium, .large])
    }
}

extension CompareView.Side: Identifiable {
    var id: Int { self == .left ? 0 : 1 }
}
