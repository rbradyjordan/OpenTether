import SwiftUI
import UIKit
import TetherCore

/// Renders a command list as menu buttons with dividers between groups.
/// Used by every `Menu` and `.contextMenu` so action lists live in one place.
struct CommandMenuContent: View {
    var commands: [Command]
    var exclude: [String] = []
    var run: (Command) -> Void

    private var filtered: [Command] { commands.filter { c in !exclude.contains { c.id.hasPrefix($0) } } }

    var body: some View {
        ForEach(PaletteGrouping.sections(filtered)) { section in
            ForEach(section.commands) { cmd in
                if cmd.isDestructive {
                    Button(role: .destructive) { run(cmd) } label: { Label(cmd.title, systemImage: cmd.symbol) }
                } else {
                    Button { run(cmd) } label: { label(cmd) }
                }
            }
            Divider()
        }
    }

    @ViewBuilder private func label(_ cmd: Command) -> some View {
        if cmd.id.hasPrefix("label."), let color = TetherCoreColorLabel(rawValue: String(cmd.id.dropFirst(6))), color != .none {
            // Menus re-tint icons with the accent; an always-original image keeps the label's own colour.
            Label { Text(cmd.title) } icon: {
                Image(uiImage: UIImage(systemName: "circle.fill")?
                    .withTintColor(UIColor(ColorLabelStyle.color(for: color)), renderingMode: .alwaysOriginal) ?? UIImage())
            }
        } else {
            Label(cmd.title, systemImage: cmd.symbol)
        }
    }
}

/// Invisible buttons carrying `.keyboardShortcut` for every available command,
/// plus ⌘K for the palette. Lives in the regular-width root so iPad keyboards
/// drive the library; the shortcut hints come from the commands themselves.
struct CommandShortcuts: View {
    @Environment(AppModel.self) private var app

    private var ids: [String] { app.library.selection.ids }

    var body: some View {
        let commands = app.commands.available(selection: ids, collection: app.library.collection)
        return ZStack {
            ForEach(commands) { cmd in
                if let parsed = cmd.shortcut.flatMap(ShortcutParser.parse), cmd.id != "collection.add" {
                    Button(cmd.title) { app.commands.run(cmd, on: ids, in: app.library.collection) }
                        .keyboardShortcut(Self.key(parsed), modifiers: Self.modifiers(parsed))
                }
            }
            Button("Command palette") { app.commands.request = .palette }
                .keyboardShortcut("k", modifiers: .command)
            Button("Clear selection") { app.library.clearSelection() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    static func key(_ p: ParsedShortcut) -> KeyEquivalent {
        if p.key == ParsedShortcut.deleteKey { return .delete }
        if p.key == " " { return .space }
        return KeyEquivalent(p.key)
    }

    static func modifiers(_ p: ParsedShortcut) -> EventModifiers {
        var m: EventModifiers = []
        if p.command { m.insert(.command) }
        if p.shift { m.insert(.shift) }
        if p.option { m.insert(.option) }
        return m
    }
}

/// The shoot screen's keys (iPad keyboards and the Mac): Space fires, 0–5 /
/// P / X / U rate and flag the frame on screen, ← → step through frames.
/// Only commands that act in place; anything that opens a sheet stays on
/// the menus.
struct ShootShortcuts: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel

    private static let prefixes = ["rate.", "flag.", "label.", "camera.", "undo", "redo"]

    var body: some View {
        let ids = model.displayedItem.map { [$0.id] } ?? []
        let commands = app.commands.available(selection: ids, inShoot: true)
            .filter { cmd in Self.prefixes.contains { cmd.id.hasPrefix($0) } }
        return ZStack {
            ForEach(commands) { cmd in
                if let parsed = cmd.shortcut.flatMap(ShortcutParser.parse) {
                    Button(cmd.title) {
                        app.commands.preferShootSurface = true
                        app.commands.run(cmd, on: ids)
                        app.commands.preferShootSurface = false
                    }
                    .keyboardShortcut(CommandShortcuts.key(parsed), modifiers: CommandShortcuts.modifiers(parsed))
                }
            }
            Button("Previous frame") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next frame") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int) {
        let ready = model.items.filter { $0.state.isReady }
        guard let current = model.displayedItem, let i = ready.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + delta
        guard ready.indices.contains(j) else { return }
        model.select(ready[j].id)
    }
}
