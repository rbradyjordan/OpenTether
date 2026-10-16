import SwiftUI
import TetherCore

/// LazyVGrid of stacks. Pinch changes the column count (2–6); in selection
/// mode a drag across tiles range-selects; tap opens the loupe or toggles.
struct LibraryGrid: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: LibraryModel

    @State private var pinchBase: Int?
    @State private var dragAnchor: Int?
    @State private var dragBase: Selection?
    @State private var gridWidth: CGFloat = 0
    /// Where the grid's top edge sits in the scroll view's frame (negative once scrolled).
    @State private var gridTop: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if model.items.isEmpty, !model.isLoading {
                        emptyState
                    } else {
                        grid(width: geo.size.width - TetherSpace.s * 2)
                            .padding(.horizontal, TetherSpace.s)
                            .padding(.vertical, TetherSpace.s)
                    }
                }
                .coordinateSpace(name: "library.grid")
                .simultaneousGesture(pinch)
                .simultaneousGesture(rangeDrag, including: model.selectionMode ? .all : .subviews)
                .onAppear { if let id = model.scrollToCaptureID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.loupeID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .tetherHaptic(.rate, trigger: model.columns)
        .accessibilityLabel("\(model.title), \(model.totalCount) photos")
    }

    private func grid(width: CGFloat) -> some View {
        let side = GridMath.tileSide(width: width, columns: model.columns)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: GridMath.spacing), count: model.columns), spacing: GridMath.spacing) {
            ForEach(model.stacks) { stack in
                ForEach(tiles(for: stack)) { item in
                    LibraryTile(item: item, stack: stack, model: model, side: side)
                        .id(item.id)
                        .onAppear { model.loadMoreIfNeeded(current: item.id) }
                }
            }
        }
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: model.columns)
        .background(GeometryReader { g in
            Color.clear.preference(key: GridTopKey.self, value: g.frame(in: .named("library.grid")).minY)
        })
        .onPreferenceChange(GridTopKey.self) { gridTop = $0 }
        .onAppear { gridWidth = width }
        .onChange(of: width) { _, w in gridWidth = w }
    }

    private func tiles(for stack: CaptureStack) -> [CaptureItem] {
        model.stackPairs && !model.expandedStacks.contains(stack.id) ? [stack.top] : stack.items
    }

    private var emptyState: some View {
        EmptyState(systemImage: model.filter.isEmpty ? "photo.on.rectangle" : "line.3.horizontal.decrease.circle",
                   title: model.filter.isEmpty ? "No photos here yet" : "Nothing matches",
                   message: model.filter.isEmpty ? "Frames from your sessions appear here as they download." : "Clear a chip or two to widen the view.",
                   actionTitle: model.filter.isEmpty ? nil : "Clear filters") { model.filter = CaptureFilter(); model.searchText = "" }
            .padding(.top, TetherSpace.xxl)
    }

    // MARK: Gestures

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil { pinchBase = model.columns }
                let next = GridMath.columns(afterPinch: value.magnification, from: pinchBase ?? model.columns)
                if next != model.columns { model.columns = next }
            }
            .onEnded { _ in pinchBase = nil }
    }

    /// Drag across tiles extends the selection from the tile under the first touch.
    private var rangeDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                let ids = model.visibleIDs
                guard let i = GridMath.index(at: adjusted(value.location), width: gridWidth, columns: model.columns, count: ids.count) else { return }
                if dragAnchor == nil {
                    dragAnchor = GridMath.index(at: adjusted(value.startLocation), width: gridWidth, columns: model.columns, count: ids.count) ?? i
                    dragBase = model.selection
                }
                guard let anchor = dragAnchor, var next = dragBase else { return }
                for id in GridMath.range(from: anchor, to: i).map({ ids[$0] }) where !next.contains(id) { next.toggle(id) }
                if next != model.selection { model.selection = next; TetherHaptic.rate() }
            }
            .onEnded { _ in dragAnchor = nil; dragBase = nil }
    }

    /// Grid coordinates: the scroll offset and side padding are removed from the touch point.
    private func adjusted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - TetherSpace.s, y: p.y - gridTop) }
}

private struct GridTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
