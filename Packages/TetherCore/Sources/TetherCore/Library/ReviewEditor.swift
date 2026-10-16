import Foundation

/// A selection of captures in a grid or filmstrip. Keeps an anchor so
/// shift-style range selection and "select to end" work on iPad keyboards.
public struct Selection: Equatable, Sendable {
    public private(set) var ids: [String] = []      // ordered, no duplicates
    public private(set) var anchor: String?

    public init(_ ids: [String] = []) { self.ids = ids; anchor = ids.last }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public var set: Set<String> { Set(ids) }
    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        anchor = id
    }

    public mutating func replace(with id: String) { ids = [id]; anchor = id }

    /// Range from the anchor to `id` within `ordered` (the view's order).
    public mutating func extend(to id: String, in ordered: [String]) {
        guard let a = anchor, let ai = ordered.firstIndex(of: a), let bi = ordered.firstIndex(of: id) else { replace(with: id); return }
        let range = ordered[min(ai, bi) ... max(ai, bi)]
        for r in range where !ids.contains(r) { ids.append(r) }
    }

    public mutating func selectAll(_ ordered: [String]) { ids = ordered; anchor = ordered.last }
    public mutating func invert(in ordered: [String]) { let s = set; ids = ordered.filter { !s.contains($0) }; anchor = ids.last }
    public mutating func clear() { ids = []; anchor = nil }
    public mutating func keep(only existing: Set<String>) { ids.removeAll { !existing.contains($0) }; if let a = anchor, !existing.contains(a) { anchor = ids.last } }
}

/// One reversible change to review state. Batch operations record one entry
/// with all affected captures, so Undo reverts the whole batch.
public struct ReviewEdit: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case rating(before: [String: Int], after: Int)
        case flag(before: [String: CaptureFlag], after: CaptureFlag)
        case label(before: [String: ColorLabel], after: ColorLabel)
        /// Only the (capture, tag) pairs that did not exist before, so undo
        /// never strips a tag the user had already applied.
        case tagsAdded(added: [String: [String]])
        case tagsRemoved(ids: [String], tags: [String])
        case addedToCollection(ids: [String], collectionID: String, alreadyPresent: Set<String>)
        case removedFromCollection(ids: [String], collectionID: String)
    }
    public var change: Change
    public var at: Date
    public var title: String
    public var count: Int
}

/// Every review mutation goes through here: it writes the store, keeps RAW+JPEG
/// pairs in sync, records undo, and tells the live session (if one is open)
/// so the shoot screen and the library never disagree.
public actor ReviewEditor {
    public enum Event: Sendable { case changed(ids: [String]), undoAvailable(String?), redoAvailable(String?) }

    private let store: SessionStore
    private let memory: WorkspaceMemory?
    private var undoStack: [ReviewEdit] = []
    private var redoStack: [ReviewEdit] = []
    private let maxUndo = 100
    /// Live session hook: when the edited captures belong to the open shoot.
    public var liveSession: TetherSession?
    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    public init(store: SessionStore, memory: WorkspaceMemory? = nil) {
        self.store = store
        self.memory = memory
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        continuation = c
    }

    public func attach(session: TetherSession?) { liveSession = session }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoTitle: String? { undoStack.last?.title }
    public var redoTitle: String? { redoStack.last?.title }

    // MARK: Batch operations (each is one undo step)

    /// Expands a selection to include each item's RAW/JPEG twin.
    private func withPairs(_ ids: [String]) throws -> [CaptureItem] {
        let items = try store.captures(ids: ids)
        var all = items
        var seen = Set(ids)
        for i in items {
            for twin in try store.captures(in: i.sessionID) where twin.pairKey == i.pairKey && !seen.contains(twin.id) {
                all.append(twin); seen.insert(twin.id)
            }
        }
        return all
    }

    public func rate(_ ids: [String], stars: Int) async throws {
        guard !ids.isEmpty else { throw LibraryError.nothingSelected }
        let items = try withPairs(ids)
        let before = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.rating) })
        try apply(items) { $0.rating = max(0, min(5, stars)) }
        push(ReviewEdit(change: .rating(before: before, after: stars), at: Date(), title: stars == 0 ? "Clear rating" : "Rate \(stars)★", count: ids.count))
        await notify(items.map(\.id))
    }

    public func flag(_ ids: [String], _ flag: CaptureFlag) async throws {
        guard !ids.isEmpty else { throw LibraryError.nothingSelected }
        let items = try withPairs(ids)
        let before = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.flag) })
        try apply(items) { $0.flag = flag }
        let title = flag == .none ? "Unflag" : (flag == .pick ? "Pick" : "Reject")
        push(ReviewEdit(change: .flag(before: before, after: flag), at: Date(), title: title, count: ids.count))
        await notify(items.map(\.id))
    }

    public func label(_ ids: [String], _ color: ColorLabel) async throws {
        guard !ids.isEmpty else { throw LibraryError.nothingSelected }
        let items = try store.captures(ids: ids)
        let before = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.colorLabel) })
        try apply(items) { $0.colorLabel = color }
        push(ReviewEdit(change: .label(before: before, after: color), at: Date(), title: color == .none ? "Clear label" : "Label \(color.rawValue)", count: ids.count))
        await notify(ids)
    }

    public func addTags(_ tags: [String], to ids: [String]) async throws {
        guard !ids.isEmpty else { throw LibraryError.nothingSelected }
        let clean = tags.map(SessionStore.normalizeTag).filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        var added: [String: [String]] = [:]
        for id in ids {
            let existing = Set(try store.tags(for: id))
            let new = clean.filter { !existing.contains($0) }
            if !new.isEmpty { added[id] = new }
        }
        try store.addTags(clean, to: ids)
        clean.forEach { memory?.noteTag($0) }
        push(ReviewEdit(change: .tagsAdded(added: added), at: Date(), title: "Tag \(clean.map { "#\($0)" }.joined(separator: " "))", count: ids.count))
        await notify(ids)
    }

    public func removeTags(_ tags: [String], from ids: [String]) async throws {
        let clean = tags.map(SessionStore.normalizeTag)
        try store.removeTags(clean, from: ids)
        push(ReviewEdit(change: .tagsRemoved(ids: ids, tags: clean), at: Date(), title: "Remove tag", count: ids.count))
        await notify(ids)
    }

    public func add(_ ids: [String], to collectionID: String) async throws {
        guard !ids.isEmpty else { throw LibraryError.nothingSelected }
        let present = Set(try store.captures(in: try store.collection(collectionID) ?? Collection(name: "", kind: .manual)).map(\.id))
        try store.add(ids, to: collectionID)
        memory?.noteCollection(collectionID)
        let name = try store.collection(collectionID)?.name ?? "collection"
        push(ReviewEdit(change: .addedToCollection(ids: ids, collectionID: collectionID, alreadyPresent: present), at: Date(), title: "Add to \(name)", count: ids.count))
        await notify(ids)
    }

    public func remove(_ ids: [String], from collectionID: String) async throws {
        try store.remove(ids, from: collectionID)
        let name = try store.collection(collectionID)?.name ?? "collection"
        push(ReviewEdit(change: .removedFromCollection(ids: ids, collectionID: collectionID), at: Date(), title: "Remove from \(name)", count: ids.count))
        await notify(ids)
    }

    /// Create a manual collection from a selection in one step.
    @discardableResult
    public func createCollection(named name: String, with ids: [String], symbol: String = "rectangle.stack", tint: ColorLabel = .none) async throws -> Collection {
        let c = Collection(name: name, kind: .manual, symbol: symbol, tint: tint)
        try store.saveCollection(c)
        if !ids.isEmpty { try await add(ids, to: c.id) }
        return c
    }

    /// Save the current filter as a smart collection.
    @discardableResult
    public func saveSmartCollection(named name: String, rule: CaptureFilter, symbol: String = "sparkles.rectangle.stack") throws -> Collection {
        let c = Collection.smart(name, rule, symbol: symbol)
        try store.saveCollection(c)
        memory?.noteCollection(c.id)
        return c
    }

    // MARK: Undo / redo

    /// Returns the edit that was undone (title + count for the toast).
    @discardableResult
    public func undo() async throws -> ReviewEdit? {
        guard let edit = undoStack.popLast() else { return nil }
        try await revert(edit)
        redoStack.append(edit)
        announce()
        return edit
    }

    @discardableResult
    public func redo() async throws -> ReviewEdit? {
        guard let edit = redoStack.popLast() else { return nil }
        try await reapply(edit)
        undoStack.append(edit)
        announce()
        return edit
    }

    private func push(_ e: ReviewEdit) {
        undoStack.append(e)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        announce()
    }

    private func announce() {
        continuation.yield(.undoAvailable(undoStack.last?.title))
        continuation.yield(.redoAvailable(redoStack.last?.title))
    }

    private func revert(_ e: ReviewEdit) async throws {
        switch e.change {
        case .rating(let before, _):
            try apply(try store.captures(ids: Array(before.keys))) { $0.rating = before[$0.id] ?? $0.rating }
            await notify(Array(before.keys))
        case .flag(let before, _):
            try apply(try store.captures(ids: Array(before.keys))) { $0.flag = before[$0.id] ?? $0.flag }
            await notify(Array(before.keys))
        case .label(let before, _):
            try apply(try store.captures(ids: Array(before.keys))) { $0.colorLabel = before[$0.id] ?? $0.colorLabel }
            await notify(Array(before.keys))
        case .tagsAdded(let added):
            for (id, tags) in added { try store.removeTags(tags, from: [id]) }
            await notify(Array(added.keys))
        case .tagsRemoved(let ids, let tags):
            try store.addTags(tags, to: ids); await notify(ids)
        case .addedToCollection(let ids, let cid, let present):
            try store.remove(ids.filter { !present.contains($0) }, from: cid); await notify(ids)
        case .removedFromCollection(let ids, let cid):
            try store.add(ids, to: cid); await notify(ids)
        }
    }

    private func reapply(_ e: ReviewEdit) async throws {
        switch e.change {
        case .rating(let before, let after):
            try apply(try store.captures(ids: Array(before.keys))) { $0.rating = after }; await notify(Array(before.keys))
        case .flag(let before, let after):
            try apply(try store.captures(ids: Array(before.keys))) { $0.flag = after }; await notify(Array(before.keys))
        case .label(let before, let after):
            try apply(try store.captures(ids: Array(before.keys))) { $0.colorLabel = after }; await notify(Array(before.keys))
        case .tagsAdded(let added):
            for (id, tags) in added { try store.addTags(tags, to: [id]) }
            await notify(Array(added.keys))
        case .tagsRemoved(let ids, let tags):
            try store.removeTags(tags, from: ids); await notify(ids)
        case .addedToCollection(let ids, let cid, _):
            try store.add(ids, to: cid); await notify(ids)
        case .removedFromCollection(let ids, let cid):
            try store.remove(ids, from: cid); await notify(ids)
        }
    }

    private func apply(_ items: [CaptureItem], _ mutate: (inout CaptureItem) -> Void) throws {
        try store.db.transaction {
            for var i in items {
                mutate(&i)
                try store.save(i)
            }
        }
    }

    private func notify(_ ids: [String]) async {
        continuation.yield(.changed(ids: ids))
        if let live = liveSession {
            let items = try? store.captures(ids: ids)
            for i in items ?? [] { await live.replaceFromStore(i) }
        }
    }
}

/// The one place every menu, context menu, keyboard shortcut and command
/// palette entry comes from. Views ask `available(in:)` and render; they
/// never hardcode action lists, so adding a workflow is adding a command.
public struct Command: Identifiable, Hashable, Sendable {
    public enum Group: String, Sendable, CaseIterable { case review, organize, export, session, view, camera }

    public var id: String
    public var title: String
    public var symbol: String
    public var group: Group
    public var shortcut: String?        // display hint, e.g. "1"…"5", "P", "X", "⌘E"
    public var isDestructive: Bool

    public init(id: String, title: String, symbol: String, group: Group, shortcut: String? = nil, isDestructive: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.group = group
        self.shortcut = shortcut
        self.isDestructive = isDestructive
    }
}

/// What the UI knows when it asks which commands apply.
public struct CommandContext: Sendable {
    public var selectionCount: Int
    public var inLiveSession: Bool
    public var cameraCapabilities: CameraCapabilities
    public var inCollection: Collection?
    public var canUndo: Bool
    public var canRedo: Bool
    public var hasCredits: Bool

    public init(selectionCount: Int = 0, inLiveSession: Bool = false, cameraCapabilities: CameraCapabilities = [],
                inCollection: Collection? = nil, canUndo: Bool = false, canRedo: Bool = false, hasCredits: Bool = true) {
        self.selectionCount = selectionCount
        self.inLiveSession = inLiveSession
        self.cameraCapabilities = cameraCapabilities
        self.inCollection = inCollection
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.hasCredits = hasCredits
    }
}

public enum Commands {
    public static let rate0 = Command(id: "rate.0", title: "Clear rating", symbol: "star.slash", group: .review, shortcut: "0")
    public static let rate = (1 ... 5).map { Command(id: "rate.\($0)", title: "Rate \($0) star\($0 == 1 ? "" : "s")", symbol: "star.fill", group: .review, shortcut: "\($0)") }
    public static let pick = Command(id: "flag.pick", title: "Pick", symbol: "flag.fill", group: .review, shortcut: "P")
    public static let reject = Command(id: "flag.reject", title: "Reject", symbol: "xmark", group: .review, shortcut: "X")
    public static let unflag = Command(id: "flag.none", title: "Unflag", symbol: "flag.slash", group: .review, shortcut: "U")
    public static let labels = ColorLabel.allCases.filter { $0 != .none }.map { Command(id: "label.\($0.rawValue)", title: "Label \($0.rawValue)", symbol: "circle.fill", group: .review) }
    public static let clearLabel = Command(id: "label.none", title: "Clear label", symbol: "circle", group: .review)
    public static let tag = Command(id: "tag.add", title: "Add tags…", symbol: "number", group: .organize, shortcut: "T")
    public static let addToCollection = Command(id: "collection.add", title: "Add to collection…", symbol: "rectangle.stack.badge.plus", group: .organize, shortcut: "⇧⌘K")
    public static let newCollection = Command(id: "collection.new", title: "New collection from selection", symbol: "plus.rectangle.on.rectangle", group: .organize)
    public static let removeFromCollection = Command(id: "collection.remove", title: "Remove from this collection", symbol: "rectangle.stack.badge.minus", group: .organize, shortcut: "⌫")
    public static let saveSmart = Command(id: "collection.smart", title: "Save filter as smart collection", symbol: "sparkles.rectangle.stack", group: .organize)
    public static let export = Command(id: "export", title: "Export…", symbol: "square.and.arrow.up", group: .export, shortcut: "⌘E")
    public static let exportAgain = Command(id: "export.again", title: "Export like last time", symbol: "arrow.uturn.up", group: .export, shortcut: "⇧⌘E")
    public static let colorMatch = Command(id: "look.match", title: "Match colour to this frame…", symbol: "wand.and.stars", group: .export)
    public static let compare = Command(id: "view.compare", title: "Compare", symbol: "rectangle.split.2x1", group: .view, shortcut: "C")
    public static let clientReview = Command(id: "view.client", title: "Client review", symbol: "rectangle.inset.filled", group: .view, shortcut: "⇧R")
    public static let selectAll = Command(id: "select.all", title: "Select all", symbol: "checkmark.circle", group: .view, shortcut: "⌘A")
    public static let selectPicks = Command(id: "select.picks", title: "Select picks", symbol: "flag", group: .view)
    public static let invert = Command(id: "select.invert", title: "Invert selection", symbol: "arrow.triangle.2.circlepath", group: .view)
    public static let undo = Command(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", group: .review, shortcut: "⌘Z")
    public static let redo = Command(id: "redo", title: "Redo", symbol: "arrow.uturn.forward", group: .review, shortcut: "⇧⌘Z")
    public static let capture = Command(id: "camera.capture", title: "Capture", symbol: "circle.inset.filled", group: .camera, shortcut: "Space")
    public static let liveView = Command(id: "camera.liveview", title: "Live view", symbol: "eye", group: .camera, shortcut: "L")
    public static let delete = Command(id: "delete", title: "Delete from iPhone", symbol: "trash", group: .organize, isDestructive: true)
    public static let saveTemplate = Command(id: "session.template", title: "Save session as template", symbol: "doc.badge.plus", group: .session)
    public static let endSession = Command(id: "session.end", title: "End session", symbol: "stop.circle", group: .session)

    /// Commands that make sense right now, grouped and ordered for a menu.
    public static func available(in ctx: CommandContext) -> [Command] {
        var out = [Command]()
        let sel = ctx.selectionCount > 0
        if ctx.inLiveSession {
            if ctx.cameraCapabilities.contains(.remoteCapture) { out.append(capture) }
            if ctx.cameraCapabilities.contains(.liveView) { out.append(liveView) }
        }
        if sel {
            out += rate + [rate0, pick, reject, unflag] + labels + [clearLabel, tag, addToCollection, newCollection]
            if let c = ctx.inCollection, c.kind == .manual { out.append(removeFromCollection) }
            out += [export, exportAgain]
            if ctx.selectionCount == 1 && ctx.hasCredits { out.append(colorMatch) }
            if ctx.selectionCount == 2 { out.append(compare) }
            out.append(clientReview)
        }
        out += [selectAll, selectPicks]
        if sel { out.append(invert) }
        if ctx.inCollection?.kind == .smart, ctx.inCollection?.isBuiltIn == false { out.append(saveSmart) }
        if ctx.canUndo { out.append(undo) }
        if ctx.canRedo { out.append(redo) }
        if ctx.inLiveSession { out += [saveTemplate, endSession] }
        if sel { out.append(delete) }
        return out
    }

    /// Full-text match for the command palette: title, group, shortcut.
    public static func search(_ query: String, in ctx: CommandContext) -> [Command] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let all = available(in: ctx)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.group.rawValue.contains(q) || ($0.shortcut?.lowercased() == q) }
            .sorted { a, b in a.title.lowercased().hasPrefix(q) && !b.title.lowercased().hasPrefix(q) }
    }
}
