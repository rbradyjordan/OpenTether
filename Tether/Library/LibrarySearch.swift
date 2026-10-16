import SwiftUI
import TetherCore

extension View {
    /// `.searchable` over the library with recent searches and tag suggestions.
    /// Typing is debounced in the model; submit records the search.
    func librarySearch(model: LibraryModel) -> some View { modifier(LibrarySearchModifier(model: model)) }
}

private struct LibrarySearchModifier: ViewModifier {
    @Bindable var model: LibraryModel

    func body(content: Content) -> some View {
        content
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filename, session or #tag") {
                LibrarySearchSuggestions(model: model)
            }
            .onSubmit(of: .search) { model.submitSearch() }
    }
}

private struct LibrarySearchSuggestions: View {
    @Bindable var model: LibraryModel

    private var recents: [String] { model.memory.get(WorkspaceMemory.recents).searches }
    private var tags: [String] {
        let prefix = model.searchText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        return model.tagSuggestions(prefix: prefix).filter { $0 != prefix }
    }

    var body: some View {
        if model.searchText.isEmpty, !recents.isEmpty {
            Section("Recent") {
                ForEach(recents, id: \.self) { s in
                    Label(s, systemImage: "clock").searchCompletion(s)
                }
            }
        }
        if !tags.isEmpty {
            Section("Tags") {
                ForEach(tags.prefix(8), id: \.self) { t in
                    Label("#\(t)", systemImage: "number").searchCompletion(t)
                }
            }
        }
    }
}
