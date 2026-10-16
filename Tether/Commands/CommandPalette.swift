import SwiftUI
import TetherCore

/// ⌘K / long-press-the-title: search every available command, grouped, with
/// symbol and shortcut hint. Return runs the first (or highlighted) result.
struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var focused: Bool

    private var ids: [String] { app.library.selection.ids }
    private var results: [Command] { Commands.search(query, in: app.commands.context(selection: ids, collection: app.library.collection)) }
    private var sections: [PaletteSection] { PaletteGrouping.sections(results) }

    var body: some View {
        NavigationStack {
            List(selection: $highlighted) {
                if results.isEmpty {
                    Text("No command matches “\(query)”").font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.commands) { cmd in row(cmd).tag(cmd.id) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(TetherColor.surface1)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Type a command")
            .onSubmit(of: .search) { runHighlightedOrFirst() }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: query) { _, _ in highlighted = results.first?.id }
            .onAppear { highlighted = results.first?.id }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ cmd: Command) -> some View {
        Button { run(cmd) } label: {
            HStack(spacing: TetherSpace.m) {
                Image(systemName: cmd.symbol).foregroundStyle(cmd.isDestructive ? TetherColor.danger : TetherColor.accent).frame(width: 24)
                Text(cmd.title).font(TetherFont.body).foregroundStyle(cmd.isDestructive ? TetherColor.danger : TetherColor.ink0)
                Spacer()
                if let hint = cmd.shortcut {
                    Text(hint).font(TetherFont.hud).foregroundStyle(TetherColor.ink2)
                        .padding(.horizontal, TetherSpace.s).padding(.vertical, 2)
                        .background(TetherColor.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(minHeight: TetherHit.min)
        }
        .accessibilityLabel(cmd.title + (cmd.shortcut.map { ", shortcut \($0)" } ?? ""))
    }

    private func runHighlightedOrFirst() {
        guard let cmd = results.first(where: { $0.id == highlighted }) ?? results.first else { return }
        run(cmd)
    }

    private func run(_ cmd: Command) {
        dismiss()
        app.commands.run(cmd, on: ids, in: app.library.collection)
    }
}
