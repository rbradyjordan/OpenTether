import Foundation
import Observation
import TetherCore

/// Main-thread state for the Library: which source is open, how it is viewed,
/// what is selected, and the loaded page of captures. Edits never flow through
/// here; `ReviewEditor` writes the store and this model patches changed ids in
/// place when the editor (or the live session) announces them.
@Observable @MainActor
final class LibraryModel {
    /// What the grid shows. Sessions and cameras are "All photos" narrowed by id.
    enum Source: Hashable {
        case collection(String)
        case session(String)
        case camera(String)

        /// Key for `WorkspaceMemory.viewState`; collections use their id directly.
        var memoryKey: String {
            switch self {
            case .collection(let id): return id
            case .session(let id): return "session:" + id
            case .camera(let id): return "camera:" + id
            }
        }

        static func from(memoryKey key: String) -> Source {
            if key.hasPrefix("session:") { return .session(String(key.dropFirst(8))) }
            if key.hasPrefix("camera:") { return .camera(String(key.dropFirst(7))) }
            return .collection(key)
        }
    }

    static let pageSize = 600

    private let store: SessionStore
    let memory: WorkspaceMemory
    private let editor: ReviewEditor

    // Sources for the sidebar.
    private(set) var collections: [Collection] = []
    private(set) var counts: [String: Int] = [:]
    private(set) var sessions: [ShootSession] = []
    private(set) var cameras: [CameraIdentity] = []

    // Current view.
    private(set) var source: Source = .collection("builtin.all")
    private(set) var collection: Collection = Collection.builtIns[0]
    var filter = CaptureFilter() { didSet { if filter != oldValue { viewChanged(reload: true) } } }
    var sort: CaptureSort = .captureTimeDescending { didSet { if sort != oldValue { viewChanged(reload: true) } } }
    /// Callers clamp through `GridMath`; the pinch and zoom menu already stay in 2…6.
    var columns = 3 { didSet { if columns != oldValue { viewChanged(reload: false) } } }
    var stackPairs = true { didSet { if stackPairs != oldValue { viewChanged(reload: false) } } }
    var inspectorOpen = false { didSet { if inspectorOpen != oldValue { viewChanged(reload: false) } } }
    var scrollToCaptureID: String?
    var searchText = "" { didSet { if searchText != oldValue { debounceSearch() } } }

    // Items and selection.
    private(set) var items: [CaptureItem] = []
    private(set) var totalCount = 0
    private(set) var isLoading = false
    var selection = Selection()
    var selectionMode = false { didSet { if !selectionMode { selection.clear() } } }
    var expandedStacks: Set<String> = []
    /// The frame the inspector describes when nothing is selected.
    var focusedID: String?
    var loupeID: String?
    var undoTitle: String?
    var redoTitle: String?
    var error: String?

    private var searchTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var editorTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var restoring = false

    init(store: SessionStore, memory: WorkspaceMemory, editor: ReviewEditor) {
        self.store = store
        self.memory = memory
        self.editor = editor
    }

    // MARK: Derived

    var stacks: [CaptureStack] {
        stackPairs ? CaptureStack.stack(items) : items.map { CaptureStack(key: $0.id, items: [$0]) }
    }

    /// The ids the grid shows, in order, for range selection and select-all.
    var visibleIDs: [String] {
        stacks.flatMap { stack in expandedStacks.contains(stack.id) || !stackPairs ? stack.items.map(\.id) : [stack.top.id] }
    }

    var hasMore: Bool { items.count < totalCount }
    var title: String {
        switch source {
        case .collection: return collection.name
        case .session(let id): return sessions.first { $0.id == id }?.name ?? "Session"
        case .camera(let id): return cameras.first { $0.id == id }?.displayName ?? "Camera"
        }
    }
    var inspectedItem: CaptureItem? {
        let id = selection.ids.last ?? focusedID
        return items.first { $0.id == id }
    }
    var selectedItems: [CaptureItem] { let s = selection.set; return items.filter { s.contains($0.id) } }
    var pinned: [Collection] { collections.filter { $0.isPinned && !$0.isBuiltIn } }
    var builtIns: [Collection] { collections.filter(\.isBuiltIn) }
    var manual: [Collection] { collections.filter { !$0.isBuiltIn && $0.kind == .manual }.sorted { $0.sortOrder < $1.sortOrder } }
    var smart: [Collection] { collections.filter { !$0.isBuiltIn && $0.kind == .smart } }

    func item(_ id: String) -> CaptureItem? { items.first { $0.id == id } }
    func collection(_ id: String) -> Collection? { collections.first { $0.id == id } }

    // MARK: Lifecycle

    /// Restores the last source and starts listening to the editor.
    func start() {
        reloadSources()
        observeEditor()
        select(Source.from(memoryKey: memory.get(WorkspaceMemory.lastCollectionID)))
    }

    func reloadSources() {
        collections = (try? store.collections()) ?? Collection.builtIns
        sessions = (try? store.sessions()) ?? []
        cameras = ((try? store.knownCameras()) ?? []).map(\.0)
        refreshCounts()
    }

    func refreshCounts() {
        var c: [String: Int] = [:]
        for col in collections { c[col.id] = (try? store.count(in: col)) ?? 0 }
        for s in sessions { c["session:" + s.id] = (try? store.count(matching: CaptureFilter(sessionIDs: [s.id]))) ?? 0 }
        for cam in cameras { c["camera:" + cam.id] = (try? store.count(matching: CaptureFilter(cameraIDs: [cam.id]))) ?? 0 }
        counts = c
    }

    func count(for source: Source) -> Int { counts[source.memoryKey] ?? 0 }

    /// Switches source, restoring how it was last viewed.
    func select(_ newSource: Source) {
        let state = memory.viewState(for: newSource.memoryKey)
        restoring = true
        source = newSource
        if case .collection(let id) = newSource, let c = collection(id) ?? (try? store.collection(id)) {
            collection = c
        } else {
            collection = collection("builtin.all") ?? Collection.builtIns[0]
        }
        filter = state.filter
        sort = state.sort
        columns = GridMath.clampColumns(state.columns)
        stackPairs = state.stackPairs
        inspectorOpen = state.inspectorOpen
        scrollToCaptureID = state.scrollToCaptureID
        searchText = state.filter.text ?? ""
        selection.clear()
        selectionMode = false
        expandedStacks = []
        restoring = false
        memory.setViewState(state, for: newSource.memoryKey)
        reload()
    }

    // MARK: Loading

    /// The filter actually sent to the store: the user's chips plus the
    /// session/camera narrowing for those sources.
    var effectiveFilter: CaptureFilter {
        var f = filter
        switch source {
        case .session(let id): f.sessionIDs = [id]
        case .camera(let id): f.cameraIDs = [id]
        case .collection: break
        }
        return f
    }

    func reload() {
        reloadTask?.cancel()
        isLoading = true
        let page = fetch(offset: 0)
        items = page.items
        totalCount = page.total
        selection.keep(only: Set(items.map(\.id)))
        if let f = focusedID, item(f) == nil { focusedID = nil }
        isLoading = false
    }

    func loadMoreIfNeeded(current id: String) {
        guard hasMore, !isLoading, let i = items.firstIndex(where: { $0.id == id }), i >= items.count - 60 else { return }
        isLoading = true
        let page = fetch(offset: items.count)
        let known = Set(items.map(\.id))
        items += page.items.filter { !known.contains($0.id) }
        totalCount = page.total
        isLoading = false
    }

    /// Smart collections page in SQL; manual ones have no limit in the core
    /// API, so they are sliced in memory (hand order is kept).
    private func fetch(offset: Int) -> (items: [CaptureItem], total: Int) {
        let extra = effectiveFilter
        do {
            switch collection.kind {
            case .smart:
                let rule = (collection.rule ?? CaptureFilter()).merged(with: extra)
                return (try store.captures(matching: rule, sort: sort, limit: Self.pageSize, offset: offset), try store.count(matching: rule))
            case .manual:
                let narrowed = extra.isEmpty && extra.readyOnly ? nil : extra
                let all = try store.captures(in: collection, narrowedBy: narrowed, sort: sort == .captureTimeDescending ? nil : sort)
                let end = min(all.count, offset + Self.pageSize)
                return (offset < end ? Array(all[offset ..< end]) : [], all.count)
            }
        } catch {
            self.error = "\(error)"
            return ([], 0)
        }
    }

    private func viewChanged(reload: Bool) {
        guard !restoring else { return }
        persistViewState()
        if reload { self.reload() }
    }

    func persistViewState() {
        var s = memory.viewState(for: source.memoryKey)
        s.filter = filter
        s.sort = sort
        s.columns = columns
        s.stackPairs = stackPairs
        s.inspectorOpen = inspectorOpen
        s.scrollToCaptureID = scrollToCaptureID
        memory.setViewState(s, for: source.memoryKey)
    }

    func rememberScroll(_ id: String?) {
        scrollToCaptureID = id
        persistViewState()
    }

    private func debounceSearch() {
        searchTask?.cancel()
        let text = searchText
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if (filter.text ?? "") != trimmed { filter.text = trimmed.isEmpty ? nil : trimmed }
        }
    }

    func submitSearch() {
        let t = searchText.trimmingCharacters(in: .whitespaces)
        memory.noteSearch(t)
    }

    // MARK: Live updates

    private func observeEditor() {
        editorTask?.cancel()
        let stream = editor.events
        editorTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .changed(let ids): apply(changed: ids)
                case .undoAvailable(let t): undoTitle = t
                case .redoAvailable(let t): redoTitle = t
                }
            }
        }
    }

    /// Follows the open shoot so new frames appear without a manual refresh.
    func attachLive(_ session: TetherSession?) {
        liveTask?.cancel()
        guard let session else { return }
        let stream = session.events
        liveTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case .capture(let item) = event, item.state.isReady { apply(changed: [item.id]) }
            }
        }
    }

    /// Patches the changed captures into the loaded page; anything new or no
    /// longer matching is reconciled by a short, coalesced reload.
    func apply(changed ids: [String]) {
        guard let fresh = try? store.captures(ids: ids) else { return }
        var missing = false
        for f in fresh {
            if let i = items.firstIndex(where: { $0.id == f.id }) { items[i] = f } else { missing = true }
        }
        let ruleSensitive = !(collection.rule ?? CaptureFilter()).isEmpty || !filter.isEmpty || collection.kind == .manual
        scheduleReconcile(force: missing || ruleSensitive)
    }

    private func scheduleReconcile(force: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            refreshCounts()
            if force { reload() }
        }
    }

    // MARK: Selection

    func toggle(_ id: String) {
        selection.toggle(id)
        focusedID = id
    }

    func selectRange(to id: String) { selection.extend(to: id, in: visibleIDs) }
    func selectAll() { selection.selectAll(visibleIDs); selectionMode = true }
    func invertSelection() { selection.invert(in: visibleIDs) }
    func selectPicks() {
        let picks = items.filter { $0.flag == .pick }.map(\.id)
        selection = Selection(picks)
        selectionMode = !picks.isEmpty
    }
    func clearSelection() { selection.clear(); selectionMode = false }

    func toggleStack(_ key: String) {
        if expandedStacks.contains(key) { expandedStacks.remove(key) } else { expandedStacks.insert(key) }
    }

    // MARK: Collections

    func save(_ c: Collection) {
        do { try store.saveCollection(c); reloadSources(); if case .collection(c.id) = source { collection = c; reload() } }
        catch { self.error = "\(error)" }
    }

    func delete(_ c: Collection) {
        do {
            try store.deleteCollection(c.id)
            if case .collection(c.id) = source { select(.collection("builtin.all")) }
            reloadSources()
        } catch { self.error = "\(error)" }
    }

    func togglePin(_ c: Collection) { var c = c; c.isPinned.toggle(); save(c) }

    func moveManual(from offsets: IndexSet, to destination: Int) {
        var list = manual
        list.move(fromOffsets: offsets, toOffset: destination)
        for (i, var c) in list.enumerated() where c.sortOrder != i { c.sortOrder = i; try? store.saveCollection(c) }
        reloadSources()
    }

    func tagSuggestions(prefix: String) -> [String] { (try? store.tagSuggestions(prefix: prefix)) ?? [] }
    func tags(for id: String) -> [String] { (try? store.tags(for: id)) ?? [] }
    func collectionIDs(containing id: String) -> [String] { (try? store.collectionIDs(containing: id)) ?? [] }
    func exportHistory(for id: String) -> [(destination: String, at: Date, remoteID: String?)] { (try? store.exportHistory(captureID: id)) ?? [] }
    func previewCount(for rule: CaptureFilter) -> Int { (try? store.count(matching: rule)) ?? 0 }
}
