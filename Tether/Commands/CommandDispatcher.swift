import Foundation
import Observation
import TetherCore

/// Maps `Command.id` to an action. Every menu, shortcut and palette entry
/// calls `run`; the commands themselves come from `Commands.available(in:)`,
/// so nothing is listed twice. Commands that need more input (tags, a
/// collection, a confirmation) surface as a `request` the host view presents.
@Observable @MainActor
final class CommandDispatcher {
    enum Request: Identifiable {
        case tags(ids: [String])
        case addToCollection(ids: [String])
        case newCollection(ids: [String])
        case saveSmart(CaptureFilter)
        case export(ids: [String], title: String)
        case compare(ids: [String])
        case clientReview(ids: [String])
        case delete(ids: [String])
        case saveTemplate(ShootSession)
        case palette

        var id: String {
            switch self {
            case .tags: return "tags"
            case .addToCollection: return "addToCollection"
            case .newCollection: return "newCollection"
            case .saveSmart: return "saveSmart"
            case .export: return "export"
            case .compare: return "compare"
            case .clientReview: return "clientReview"
            case .delete: return "delete"
            case .saveTemplate: return "saveTemplate"
            case .palette: return "palette"
            }
        }
    }

    private unowned let app: AppModel
    var request: Request?
    /// Set by the shoot screen's menu so "Compare" / "Client review" open there.
    var preferShootSurface = false

    init(app: AppModel) { self.app = app }

    private var editor: ReviewEditor { app.editor }
    private var library: LibraryModel { app.library }

    // MARK: Context

    /// What applies right now for a given selection. `collection` is the
    /// library's open collection when the caller is the grid.
    func context(selection: [String], collection: Collection? = nil, inShoot: Bool = false) -> CommandContext {
        CommandContext(selectionCount: selection.count,
                       inLiveSession: app.shoot != nil && (inShoot || app.shoot?.isLive == true),
                       cameraCapabilities: app.shoot?.capabilities ?? [],
                       inCollection: collection,
                       canUndo: library.undoTitle != nil,
                       canRedo: library.redoTitle != nil)
    }

    func available(selection: [String], collection: Collection? = nil, inShoot: Bool = false) -> [Command] {
        Commands.available(in: context(selection: selection, collection: collection, inShoot: inShoot))
    }

    // MARK: Run

    func run(_ command: Command, on ids: [String], in collection: Collection? = nil) {
        let parts = command.id.split(separator: ".").map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? parts[1] : "") {
        case ("rate", let n): rate(ids, Int(n) ?? 0)
        case ("flag", let f): flag(ids, CaptureFlag(rawValue: f) ?? .none)
        case ("label", let c): label(ids, TetherCoreColorLabel(rawValue: c) ?? .none)
        case ("tag", _): request = .tags(ids: ids)
        case ("collection", "add"): request = .addToCollection(ids: ids)
        case ("collection", "new"): request = .newCollection(ids: ids)
        case ("collection", "remove"): if let c = collection { perform("Remove") { try await self.editor.remove(ids, from: c.id) } }
        case ("collection", "smart"): request = .saveSmart(library.effectiveFilter)
        case ("export", "again"): exportAgain(ids)
        case ("export", _): request = .export(ids: ids, title: ids.count == 1 ? "Export 1 photo" : "Export \(ids.count) photos")
        case ("look", _): colorMatch(ids)
        case ("view", "compare"): compare(ids)
        case ("view", "client"): clientReview(ids)
        case ("select", "all"): library.selectAll()
        case ("select", "picks"): library.selectPicks()
        case ("select", "invert"): library.invertSelection()
        case ("undo", _): undo()
        case ("redo", _): redo()
        case ("camera", "capture"): app.shoot?.capture(autofocus: true)
        case ("camera", "liveview"): app.shoot?.toggleLiveView()
        case ("delete", _): request = .delete(ids: ids)
        case ("session", "template"): if let s = app.shoot?.shootSession { request = .saveTemplate(s) }
        case ("session", "end"): Task { await app.endShoot() }
        default: app.toast = ToastMessage(text: "\(command.title) is not available here", systemImage: "questionmark.circle")
        }
    }

    // MARK: Review edits (all undoable)

    func rate(_ ids: [String], _ stars: Int) { TetherHaptic.rate(); perform("Rate") { try await self.editor.rate(ids, stars: stars) } }

    func flag(_ ids: [String], _ flag: CaptureFlag) {
        if flag == .pick { TetherHaptic.pick() } else if flag == .reject { TetherHaptic.reject() }
        perform("Flag") { try await self.editor.flag(ids, flag) }
    }

    func label(_ ids: [String], _ color: TetherCoreColorLabel) { perform("Label") { try await self.editor.label(ids, color) } }
    func addTags(_ tags: [String], to ids: [String]) { perform("Tag") { try await self.editor.addTags(tags, to: ids) } }
    func removeTags(_ tags: [String], from ids: [String]) { perform("Remove tag") { try await self.editor.removeTags(tags, from: ids) } }

    func add(_ ids: [String], to collectionID: String) {
        perform("Add to collection") {
            try await self.editor.add(ids, to: collectionID)
            self.library.reloadSources()
        }
    }

    func remove(_ ids: [String], from collectionID: String) {
        perform("Remove from collection") {
            try await self.editor.remove(ids, from: collectionID)
            self.library.reloadSources()
        }
    }

    func createCollection(named name: String, with ids: [String], symbol: String, tint: TetherCoreColorLabel) {
        perform("New collection") {
            let c = try await self.editor.createCollection(named: name, with: ids, symbol: symbol, tint: tint)
            self.library.reloadSources()
            self.app.toast = ToastMessage(text: "Created \(c.name)", systemImage: c.symbol)
        }
    }

    func saveSmartCollection(_ draft: Collection) {
        perform("Smart collection") {
            try await self.editor.saveSmartCollection(named: draft.name, rule: draft.rule ?? CaptureFilter(), symbol: draft.symbol)
            self.library.reloadSources()
        }
    }

    func undo() {
        let title = library.undoTitle
        perform("Undo") {
            try await self.editor.undo()
            if let title { self.app.toast = ToastMessage(text: "Undid \(title)", systemImage: "arrow.uturn.backward") }
        }
    }

    func redo() {
        let title = library.redoTitle
        perform("Redo") {
            try await self.editor.redo()
            if let title { self.app.toast = ToastMessage(text: "Redid \(title)", systemImage: "arrow.uturn.forward") }
        }
    }

    /// Removes the files and rows; the live session does it itself when the
    /// frame is part of the open shoot so the filmstrip stays in step.
    func confirmDelete(_ ids: [String]) {
        for id in ids {
            if let shoot = app.shoot, shoot.items.contains(where: { $0.id == id }) {
                shoot.delete(id)
            } else if let item = library.item(id) ?? (try? app.store.capture(id)) {
                [item.relativePath, item.proxyRelativePath, item.thumbnailRelativePath].compactMap { $0 }.forEach(app.cache.remove)
                try? app.store.deleteCapture(id)
            }
        }
        library.clearSelection()
        library.reload()
        library.reloadSources()
        app.reloadSessions()
    }

    // MARK: Export and view

    /// One job per session, with the remembered destination and options.
    func exportAgain(_ ids: [String]) {
        let last = app.memory.get(WorkspaceMemory.lastExport)
        let items = (try? app.store.captures(ids: ids)) ?? []
        guard !items.isEmpty else { app.toast = ToastMessage(text: "Nothing to export", systemImage: "square.and.arrow.up"); return }
        Task {
            var queued = 0
            for (sessionID, group) in Dictionary(grouping: items, by: \.sessionID) {
                guard let session = try? app.store.session(sessionID) else { continue }
                let job = await app.exportQueue.makeJob(session: session, captures: group, destination: last.destination, options: last.options,
                                                        look: LookStack(lookID: session.lookID, strength: session.lookStrength))
                guard !job.items.isEmpty else { continue }
                do { try await app.exportQueue.enqueue(job); queued += job.items.count } catch { app.toast = ToastMessage(text: "\(error)", systemImage: "exclamationmark.triangle") }
            }
            if queued > 0 { app.toast = ToastMessage(text: "Exporting \(queued) to \(last.destination.displayName)", systemImage: "arrow.up.doc") }
        }
    }

    private func colorMatch(_ ids: [String]) {
        if let shoot = app.shoot, let id = ids.first, shoot.items.contains(where: { $0.id == id }) {
            shoot.select(id)
            shoot.sheet = .colorMatch
        } else {
            app.toast = ToastMessage(text: "Colour match works on the live session's frames", systemImage: "wand.and.stars")
        }
    }

    private func compare(_ ids: [String]) {
        if preferShootSurface, let shoot = app.shoot, ids.count == 2 {
            shoot.compareOtherID = ids[1]
            shoot.select(ids[0])
            shoot.sheet = .compare
        } else {
            request = .compare(ids: ids)
        }
    }

    private func clientReview(_ ids: [String]) {
        if preferShootSurface, let shoot = app.shoot { shoot.showClientReview = true } else { request = .clientReview(ids: ids) }
    }

    private func perform(_ what: String, _ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() } catch { app.toast = ToastMessage(text: "\(what) failed: \(error)", systemImage: "exclamationmark.triangle") }
        }
    }
}
