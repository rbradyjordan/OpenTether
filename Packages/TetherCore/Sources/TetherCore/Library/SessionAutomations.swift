import Foundation

/// The hands-free parts of a power user's workflow, driven by the session's
/// template and routing:
///
/// - every frame that lands gets the template's tags and joins its collection;
/// - when `autoExportPicks` is on, a frame flagged Pick is exported with the
///   remembered export settings, debounced so a burst of picks becomes one
///   job;
/// - when the session ends, memory learns from it.
///
/// It only observes streams, so it is testable without a camera.
public actor SessionAutomations {
    public struct Rules: Codable, Hashable, Sendable {
        public var tags: [String]
        public var addToCollectionID: String?
        public var autoExportPicks: Bool
        public var autoExportDestination: ExportDestination
        public var autoExportOptions: ExportOptions
        public var debounce: TimeInterval

        public init(tags: [String] = [], addToCollectionID: String? = nil, autoExportPicks: Bool = false,
                    autoExportDestination: ExportDestination = .photos, autoExportOptions: ExportOptions = ExportOptions(),
                    debounce: TimeInterval = 2.0) {
            self.tags = tags
            self.addToCollectionID = addToCollectionID
            self.autoExportPicks = autoExportPicks
            self.autoExportDestination = autoExportDestination
            self.autoExportOptions = autoExportOptions
            self.debounce = debounce
        }

        public static func from(template: WorkspaceMemory.SessionTemplate?, session: ShootSession, memory: WorkspaceMemory) -> Rules {
            let last = memory.get(WorkspaceMemory.lastExport)
            return Rules(tags: template?.tags ?? memory.get(WorkspaceMemory.sessionDefaults).tags,
                         addToCollectionID: template?.addToCollectionID,
                         autoExportPicks: session.routing.autoExportPicks,
                         autoExportDestination: last.destination, autoExportOptions: last.options)
        }
    }

    public enum Event: Sendable { case tagged(captureID: String), addedToCollection(captureID: String), exportQueued(ExportJob), error(String) }

    private let store: SessionStore
    private let editor: ReviewEditor
    private let queue: ExportQueue?
    private let memory: WorkspaceMemory
    public private(set) var rules: Rules
    private var session: ShootSession
    private var tasks: [Task<Void, Never>] = []
    private var pendingPicks: Set<String> = []
    private var exportedPicks: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    public init(session: ShootSession, rules: Rules, store: SessionStore, editor: ReviewEditor, queue: ExportQueue?, memory: WorkspaceMemory) {
        self.session = session
        self.rules = rules
        self.store = store
        self.editor = editor
        self.queue = queue
        self.memory = memory
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { c = $0 }
        continuation = c
    }

    public func update(rules: Rules) { self.rules = rules }

    /// Start observing the live session and the editor.
    public func attach(to live: TetherSession) {
        stop()
        tasks.append(Task { [weak self] in
            for await ev in live.events {
                guard let self else { return }
                switch ev {
                case .capture(let item) where item.state.isReady:
                    await self.onReady(item)
                case .status(.ended):
                    await self.onEnded(live)
                default: break
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await ev in editor.events {
                guard let self else { return }
                if case .changed(let ids) = ev { await self.onEdited(ids) }
            }
        })
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        debounceTask?.cancel()
    }

    // MARK: Reactions

    private var seen: Set<String> = []

    private func onReady(_ item: CaptureItem) async {
        guard item.sessionID == session.id, !seen.contains(item.id) else { return }
        seen.insert(item.id)
        if !rules.tags.isEmpty {
            do { try store.addTags(rules.tags, to: [item.id]); continuation.yield(.tagged(captureID: item.id)) } catch { continuation.yield(.error("\(error)")) }
        }
        if let cid = rules.addToCollectionID {
            do { try store.add([item.id], to: cid); continuation.yield(.addedToCollection(captureID: item.id)) } catch { continuation.yield(.error("\(error)")) }
        }
        if rules.autoExportPicks, item.flag == .pick { schedulePick(item.id) }
    }

    private func onEdited(_ ids: [String]) async {
        guard rules.autoExportPicks else { return }
        for item in (try? store.captures(ids: ids)) ?? [] where item.sessionID == session.id {
            if item.flag == .pick, item.state.isReady, item.kind != .raw { schedulePick(item.id) }
        }
    }

    private func schedulePick(_ id: String) {
        guard !exportedPicks.contains(id) else { return }
        pendingPicks.insert(id)
        debounceTask?.cancel()
        let delay = rules.debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushPicks()
        }
    }

    /// Enqueue one export job for everything picked since the last flush.
    public func flushPicks() async {
        guard let queue, !pendingPicks.isEmpty else { return }
        let ids = Array(pendingPicks)
        pendingPicks.removeAll()
        exportedPicks.formUnion(ids)
        do {
            let caps = try store.captures(ids: ids)
            let job = await queue.makeJob(session: session, captures: caps, destination: rules.autoExportDestination,
                                          options: rules.autoExportOptions, look: LookStack(lookID: session.lookID, strength: session.lookStrength))
            guard !job.items.isEmpty else { return }
            try await queue.enqueue(job)
            continuation.yield(.exportQueued(job))
        } catch {
            exportedPicks.subtract(ids)
            continuation.yield(.error("Auto-export failed: \(error)"))
        }
    }

    private func onEnded(_ live: TetherSession) async {
        let final = await live.snapshot.session
        session = final
        memory.learn(from: final)
        await flushPicks()
    }

    public var pendingPickCount: Int { pendingPicks.count }
}
