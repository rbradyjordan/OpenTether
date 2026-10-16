import Foundation
import TetherCore

/// One section of the command palette: a group heading and its commands in
/// the order `Commands.available` produced them.
struct PaletteSection: Identifiable, Equatable {
    var group: Command.Group
    var commands: [Command]
    var id: String { group.rawValue }
    var title: String { PaletteGrouping.title(for: group) }
}

/// Groups palette results by `Command.Group`, keeping first-appearance order
/// so the most relevant group (usually review) stays on top.
enum PaletteGrouping {
    static func sections(_ commands: [Command]) -> [PaletteSection] {
        var order: [Command.Group] = []
        var buckets: [Command.Group: [Command]] = [:]
        for c in commands {
            if buckets[c.group] == nil { order.append(c.group) }
            buckets[c.group, default: []].append(c)
        }
        return order.map { PaletteSection(group: $0, commands: buckets[$0] ?? []) }
    }

    static func title(for group: Command.Group) -> String {
        switch group {
        case .review: return "Review"
        case .organize: return "Organize"
        case .export: return "Export"
        case .session: return "Session"
        case .view: return "View"
        case .camera: return "Camera"
        }
    }
}

/// A keyboard shortcut hint ("⇧⌘E", "P", "Space") as key + modifiers, so the
/// view can build a `KeyEquivalent` and the parser stays testable.
struct ParsedShortcut: Equatable {
    var key: Character
    var command = false
    var shift = false
    var option = false

    static let deleteKey: Character = "\u{7F}"
}

enum ShortcutParser {
    static func parse(_ hint: String) -> ParsedShortcut? {
        var rest = hint.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var out = ParsedShortcut(key: " ")
        while let first = rest.first, "⌘⇧⌥".contains(first) {
            switch first {
            case "⌘": out.command = true
            case "⇧": out.shift = true
            default: out.option = true
            }
            rest.removeFirst()
        }
        switch rest.lowercased() {
        case "space": out.key = " "
        case "⌫", "delete": out.key = ParsedShortcut.deleteKey
        default:
            guard rest.count == 1, let c = rest.first else { return nil }
            out.key = Character(c.lowercased())
        }
        return out
    }
}
