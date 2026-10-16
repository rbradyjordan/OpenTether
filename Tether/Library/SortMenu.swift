import SwiftUI
import TetherCore

struct SortMenu: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                ForEach(CaptureSort.allCases) { s in Text(s.displayName).tag(s) }
            }
        } label: {
            Label("Sort: \(model.sort.displayName)", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort, currently \(model.sort.displayName)")
    }
}

/// 2–6 tiles per row; the same levels the pinch snaps to.
struct ZoomMenu: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Menu {
            Picker("Zoom", selection: $model.columns) {
                ForEach(Array(GridMath.columnRange), id: \.self) { n in Text(GridMath.zoomTitle(n)).tag(n) }
            }
        } label: {
            Label("Zoom: \(GridMath.zoomTitle(model.columns))", systemImage: "square.grid.3x3")
        }
        .accessibilityLabel("Zoom, currently \(GridMath.zoomTitle(model.columns))")
    }
}
