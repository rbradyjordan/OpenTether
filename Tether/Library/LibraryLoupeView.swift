import SwiftUI
import TetherCore

/// Full-screen frame from the library grid: swipe between the grid's items,
/// rate / flag in the thumb zone through the dispatcher, context menu from the
/// commands. With `compareIDs` it shows two frames side by side.
struct LibraryLoupeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: LibraryModel
    var compareIDs: [String] = []
    @State private var showInfo = true

    private var items: [CaptureItem] { compareIDs.isEmpty ? model.items.filter { $0.state.isReady } : model.items.filter { compareIDs.contains($0.id) } }
    private var current: CaptureItem? { items.first { $0.id == model.loupeID } ?? items.first }

    var body: some View {
        ZStack {
            TetherColor.surface0.ignoresSafeArea()
            if compareIDs.count == 2 {
                compare
            } else if let current {
                single(current)
            } else {
                EmptyState(systemImage: "photo", title: "Nothing to show", message: "")
            }
            if showInfo, let current { chrome(current).transition(.opacity) }
        }
        .statusBarHidden(true)
        .forceDark()
        .overlayTypeCap()
        .onAppear { if model.loupeID == nil { model.loupeID = items.first?.id } }
    }

    private func single(_ item: CaptureItem) -> some View {
        CachedZoomableImage(cache: app.cache, relativePath: item.previewRelativePath ?? item.thumbnailRelativePath)
            .ignoresSafeArea()
            .onTapGesture { withAnimation(Motion.spring(TetherMotion.snap, reduce: reduceMotion)) { showInfo.toggle() } }
            .gesture(swipe(item))
            .contextMenu {
                CommandMenuContent(commands: app.commands.available(selection: [item.id], collection: model.collection), exclude: ["select."]) {
                    app.commands.run($0, on: [item.id], in: model.collection)
                }
            }
            .accessibilityLabel(item.filename)
    }

    private var compare: some View {
        HStack(spacing: 2) {
            ForEach(items.prefix(2)) { item in
                VStack(spacing: TetherSpace.xs) {
                    AsyncImageView(cache: app.cache, relativePath: item.previewRelativePath ?? item.thumbnailRelativePath, maxPixelSize: 2048)
                    Text(item.filename).font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                }
                .accessibilityLabel(item.filename)
            }
        }
        .padding(.top, 60)
    }

    private func chrome(_ item: CaptureItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.rememberScroll(item.id); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(TetherColor.ink0)
                        .frame(width: TetherHit.min, height: TetherHit.min).background(TetherColor.surface2.opacity(0.8), in: Circle())
                }
                .accessibilityLabel("Close loupe")
                Spacer()
                if compareIDs.isEmpty { TonePill(text: "\((items.firstIndex { $0.id == item.id } ?? 0) + 1) / \(items.count)") }
                Button { model.focusedID = item.id; model.inspectorOpen = true; dismiss() } label: {
                    Image(systemName: "info.circle").font(.system(size: 18, weight: .semibold)).foregroundStyle(TetherColor.ink0)
                        .frame(width: TetherHit.min, height: TetherHit.min).background(TetherColor.surface2.opacity(0.8), in: Circle())
                }
                .accessibilityLabel("Inspector")
            }
            .padding(TetherSpace.l)
            Spacer()
            VStack(spacing: TetherSpace.s) {
                MetadataStrip(item: item, position: nil)
                HStack(spacing: TetherSpace.m) {
                    FlagButton(kind: .reject, flag: item.flag) { app.commands.flag([item.id], $0) }
                    Spacer(minLength: 0)
                    RatingStars(rating: item.rating, size: 28) { app.commands.rate([item.id], $0) }
                    Spacer(minLength: 0)
                    FlagButton(kind: .pick, flag: item.flag) { app.commands.flag([item.id], $0) }
                }
                .padding(.horizontal, TetherSpace.l)
                .padding(.bottom, TetherSpace.m)
            }
            .background(Color.black.opacity(0.6))
        }
    }

    private func swipe(_ item: CaptureItem) -> some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
            if value.translation.width < -40, i + 1 < items.count { model.loupeID = items[i + 1].id; model.focusedID = model.loupeID; model.loadMoreIfNeeded(current: items[i + 1].id) }
            if value.translation.width > 40, i > 0 { model.loupeID = items[i - 1].id; model.focusedID = model.loupeID }
            if value.translation.height > 80 { model.rememberScroll(item.id); dismiss() }
        }
    }
}
