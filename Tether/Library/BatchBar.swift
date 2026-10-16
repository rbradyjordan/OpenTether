import SwiftUI
import TetherCore

/// Appears when the selection is non-empty: count, the quick review commands
/// as buttons, and everything else from `Commands.available` in a menu.
struct BatchBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: LibraryModel

    private static let quickIDs = ["rate.1", "rate.2", "rate.3", "rate.4", "rate.5", "flag.pick", "flag.reject", "tag.add", "collection.add", "export"]

    private var ids: [String] { model.selection.ids }
    private var commands: [Command] { app.commands.available(selection: ids, collection: model.collection) }

    var body: some View {
        if !model.selection.isEmpty {
            VStack(spacing: TetherSpace.s) {
                HStack {
                    Text("\(model.selection.count) selected").font(TetherFont.hud).foregroundStyle(TetherColor.ink0).contentTransition(.numericText())
                    Spacer()
                    Button("Clear") { model.clearSelection() }.font(TetherFont.hud)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TetherSpace.xs) {
                        ForEach(commands.filter { Self.quickIDs.contains($0.id) }) { cmd in quick(cmd) }
                        more
                    }
                }
            }
            .padding(.horizontal, TetherSpace.l)
            .padding(.vertical, TetherSpace.m)
            .background(.bar)
            .overlay(alignment: .top) { Rectangle().fill(TetherColor.hairline).frame(height: 0.5) }
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .animation(Motion.spring(TetherMotion.arrive, reduce: reduceMotion), value: model.selection.count)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Batch actions for \(model.selection.count) photos")
        }
    }

    private func quick(_ cmd: Command) -> some View {
        Button { app.commands.run(cmd, on: ids, in: model.collection) } label: {
            VStack(spacing: 2) {
                if cmd.id.hasPrefix("rate.") {
                    Text(String(cmd.id.dropFirst(5))).font(TetherFont.exposure)
                } else {
                    Image(systemName: cmd.symbol).font(.system(size: 18, weight: .medium))
                }
                Text(shortTitle(cmd)).tetherCaption().lineLimit(1)
            }
            .foregroundStyle(cmd.id == "flag.reject" ? TetherColor.danger : TetherColor.ink0)
            .frame(minWidth: 52, minHeight: TetherHit.min + 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cmd.title)
    }

    private func shortTitle(_ cmd: Command) -> String {
        if cmd.id.hasPrefix("rate.") { return "★" }
        if cmd.id == "tag.add" { return "Tag" }
        if cmd.id == "collection.add" { return "Collect" }
        return cmd.title.replacingOccurrences(of: "…", with: "")
    }

    private var more: some View {
        Menu {
            CommandMenuContent(commands: commands.filter { !Self.quickIDs.contains($0.id) }) { cmd in app.commands.run(cmd, on: ids, in: model.collection) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "ellipsis.circle").font(.system(size: 18, weight: .medium))
                Text("More").tetherCaption()
            }
            .foregroundStyle(TetherColor.ink0)
            .frame(minWidth: 52, minHeight: TetherHit.min + 6)
        }
        .accessibilityLabel("More actions")
    }
}
