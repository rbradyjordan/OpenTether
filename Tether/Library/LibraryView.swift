import SwiftUI
import TetherCore

/// Compact-width Library tab: the source list as the root, the grid pushed
/// on top. On first appearance it lands on the last source viewed.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [LibraryModel.Source] = []
    @State private var restored = false

    var body: some View {
        NavigationStack(path: $path) {
            LibrarySidebar(mode: .compact)
                .navigationTitle("Library")
                .navigationDestination(for: LibraryModel.Source.self) { source in
                    LibraryContent(model: app.library)
                        .onAppear { if app.library.source != source { app.library.select(source) } }
                }
        }
        .onAppear {
            guard !restored else { return }
            restored = true
            path = [app.library.source]
        }
        .onChange(of: app.library.source) { _, source in
            // "Continue where you left off" and other outside selections push the grid.
            if path.last != source { path = [source] }
        }
    }
}
