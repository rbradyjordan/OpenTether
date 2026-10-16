import Foundation

/// Between-session memory. Everything a power user would otherwise re-set
/// every shoot: how the last session was configured, what this camera was
/// last used with, which collection they were looking at and how, recent
/// tags, saved session templates. Backed by the store's `settings` table as
/// typed JSON blobs with defaults, so a missing key is never an error.
public final class WorkspaceMemory: @unchecked Sendable {
    private let store: SessionStore
    private let lock = NSLock()

    public init(store: SessionStore) { self.store = store }

    // MARK: Generic typed access

    public func get<T: Codable>(_ key: Key<T>) -> T {
        guard let raw = store.setting(key.name), let d = raw.data(using: .utf8),
              let v = try? JSONDecoder().decode(T.self, from: d) else { return key.default }
        return v
    }

    public func set<T: Codable>(_ key: Key<T>, _ value: T) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        store.setSetting(key.name, String(decoding: d, as: UTF8.self))
    }

    public func clear<T>(_ key: Key<T>) { store.setSetting(key.name, nil) }

    public struct Key<T: Codable>: Sendable {
        public let name: String
        public let `default`: T
        public init(_ name: String, default: T) { self.name = "memory." + name; self.default = `default` }
    }

    // MARK: Well-known keys

    /// How the last session was set up; the New Session sheet starts here.
    public struct SessionDefaults: Codable, Hashable, Sendable {
        public var destination: CaptureDestination = .both
        public var routing: RoutingRules = RoutingRules()
        public var look: LookStack = .none
        public var showNewestCapture = true
        public var autoExportPicks = false
        public var namePattern = "{date} {camera}"
        public var tags: [String] = []
        public var templateID: String?
        public init() {}
    }
    public static let sessionDefaults = Key("session.defaults", default: SessionDefaults())

    /// Per-camera memory: the last look, destination and exposure the body was
    /// left at, so reconnecting a known camera restores its working state.
    public struct CameraMemory: Codable, Hashable, Sendable {
        public var cameraID: String
        public var lastSeen: Date
        public var look: LookStack
        public var destination: CaptureDestination
        public var lastExposure: [TetherProperty: String]
        public var templateID: String?
        public var connectionHost: String?
        public init(cameraID: String, lastSeen: Date = Date(), look: LookStack = .none, destination: CaptureDestination = .both,
                    lastExposure: [TetherProperty: String] = [:], templateID: String? = nil, connectionHost: String? = nil) {
            self.cameraID = cameraID
            self.lastSeen = lastSeen
            self.look = look
            self.destination = destination
            self.lastExposure = lastExposure
            self.templateID = templateID
            self.connectionHost = connectionHost
        }
    }
    private static let cameras = Key("cameras", default: [String: CameraMemory]())

    public func camera(_ id: String) -> CameraMemory? { get(Self.cameras)[id] }

    public func remember(camera: CameraMemory) {
        lock.lock(); defer { lock.unlock() }
        var all = get(Self.cameras)
        all[camera.cameraID] = camera
        set(Self.cameras, all)
    }

    public func rememberExposure(cameraID: String, _ props: [PropertyDescriptor]) {
        lock.lock(); defer { lock.unlock() }
        var all = get(Self.cameras)
        var m = all[cameraID] ?? CameraMemory(cameraID: cameraID)
        for p in props { m.lastExposure[p.property] = p.display }
        m.lastSeen = Date()
        all[cameraID] = m
        set(Self.cameras, all)
    }

    /// How the library was last viewed, per collection, so coming back lands
    /// on the same frame with the same filter, sort and zoom.
    public struct ViewState: Codable, Hashable, Sendable {
        public var filter: CaptureFilter = CaptureFilter()
        public var sort: CaptureSort = .captureTimeDescending
        public var columns: Int = 3
        public var stackPairs = true
        public var scrollToCaptureID: String?
        public var inspectorOpen = false
        public init() {}
    }
    private static let views = Key("library.views", default: [String: ViewState]())
    public static let lastCollectionID = Key("library.lastCollection", default: "builtin.all")

    public func viewState(for collectionID: String) -> ViewState { get(Self.views)[collectionID] ?? ViewState() }

    public func setViewState(_ state: ViewState, for collectionID: String) {
        lock.lock(); defer { lock.unlock() }
        var all = get(Self.views)
        all[collectionID] = state
        set(Self.views, all)
        set(Self.lastCollectionID, collectionID)
    }

    /// Last export configuration per destination kind, so "export again"
    /// is one tap.
    public struct ExportMemory: Codable, Hashable, Sendable {
        public var destination: ExportDestination = .photos
        public var options: ExportOptions = ExportOptions()
        public var scope: String = "picks"
        public init() {}
    }
    public static let lastExport = Key("export.last", default: ExportMemory())

    /// Recents: the small lists that make the app feel like it knows you.
    public struct Recents: Codable, Hashable, Sendable {
        public var tags: [String] = []
        public var collectionIDs: [String] = []
        public var ftpDestinationIDs: [String] = []
        public var searches: [String] = []
        public init() {}
        mutating func push(_ v: String, to path: WritableKeyPath<Recents, [String]>, max: Int = 10) {
            var list = self[keyPath: path]
            list.removeAll { $0 == v }
            list.insert(v, at: 0)
            self[keyPath: path] = Array(list.prefix(max))
        }
    }
    public static let recents = Key("recents", default: Recents())

    public func noteTag(_ t: String) { mutateRecents { $0.push(t, to: \.tags) } }
    public func noteCollection(_ id: String) { mutateRecents { $0.push(id, to: \.collectionIDs) } }
    public func noteSearch(_ s: String) { guard !s.isEmpty else { return }; mutateRecents { $0.push(s, to: \.searches) } }
    public func noteFTP(_ id: String) { mutateRecents { $0.push(id, to: \.ftpDestinationIDs) } }

    private func mutateRecents(_ f: (inout Recents) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var r = get(Self.recents)
        f(&r)
        set(Self.recents, r)
    }

    // MARK: Session templates

    /// A saved way of shooting: "Headshots", "Lookbook", "Client review day".
    public struct SessionTemplate: Identifiable, Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var symbol: String
        public var destination: CaptureDestination
        public var routing: RoutingRules
        public var look: LookStack
        public var showNewestCapture: Bool
        public var autoExportPicks: Bool
        public var tags: [String]
        public var namePattern: String
        public var addToCollectionID: String?
        public var useCount: Int
        public var lastUsed: Date?

        public init(id: String = UUID().uuidString, name: String, symbol: String = "camera.aperture", destination: CaptureDestination = .both,
                    routing: RoutingRules = RoutingRules(), look: LookStack = .none, showNewestCapture: Bool = true,
                    autoExportPicks: Bool = false, tags: [String] = [], namePattern: String = "{date} {name}",
                    addToCollectionID: String? = nil, useCount: Int = 0, lastUsed: Date? = nil) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.destination = destination
            self.routing = routing
            self.look = look
            self.showNewestCapture = showNewestCapture
            self.autoExportPicks = autoExportPicks
            self.tags = tags
            self.namePattern = namePattern
            self.addToCollectionID = addToCollectionID
            self.useCount = useCount
            self.lastUsed = lastUsed
        }

        /// Expand `{date}`, `{name}`, `{camera}`, `{n}` for a new session name.
        public func sessionName(camera: CameraIdentity?, index: Int, now: Date = Date()) -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return namePattern
                .replacingOccurrences(of: "{date}", with: f.string(from: now))
                .replacingOccurrences(of: "{name}", with: name)
                .replacingOccurrences(of: "{camera}", with: camera?.displayName ?? "Camera")
                .replacingOccurrences(of: "{n}", with: String(format: "%03d", index))
                .trimmingCharacters(in: .whitespaces)
        }
    }
    private static let templates = Key("session.templates", default: [SessionTemplate]())

    public func templates() -> [SessionTemplate] {
        get(Self.templates).sorted { ($0.lastUsed ?? .distantPast, $0.useCount) > ($1.lastUsed ?? .distantPast, $1.useCount) }
    }

    public func save(template: SessionTemplate) {
        lock.lock(); defer { lock.unlock() }
        var all = get(Self.templates)
        if let i = all.firstIndex(where: { $0.id == template.id }) { all[i] = template } else { all.append(template) }
        set(Self.templates, all)
    }

    public func deleteTemplate(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        set(Self.templates, get(Self.templates).filter { $0.id != id })
    }

    /// Build a template from a session as it was shot ("Save as template").
    public func template(from session: ShootSession, name: String) -> SessionTemplate {
        SessionTemplate(name: name, destination: session.destination, routing: session.routing,
                        look: LookStack(lookID: session.lookID, strength: session.lookStrength),
                        showNewestCapture: session.showNewestCapture, autoExportPicks: session.routing.autoExportPicks)
    }

    /// The suggestion for a new session: the template this camera used last,
    /// else the most recent template, else the last session's settings.
    public func suggestedTemplate(for camera: CameraIdentity?) -> SessionTemplate? {
        let all = get(Self.templates)
        if let cam = camera, let id = self.camera(cam.id)?.templateID, let t = all.first(where: { $0.id == id }) { return t }
        return templates().first
    }

    /// Apply a template (or the remembered defaults) to a new session and
    /// record the use.
    public func configure(_ session: inout ShootSession, with template: SessionTemplate?, camera: CameraIdentity?, index: Int) {
        if var t = template {
            session.destination = t.destination
            session.routing = t.routing
            session.lookID = t.look.lookID
            session.lookStrength = t.look.strength
            session.showNewestCapture = t.showNewestCapture
            session.routing.autoExportPicks = t.autoExportPicks
            if session.name.isEmpty { session.name = t.sessionName(camera: camera, index: index) }
            t.useCount += 1
            t.lastUsed = Date()
            save(template: t)
            var d = get(Self.sessionDefaults)
            d.templateID = t.id
            set(Self.sessionDefaults, d)
        } else {
            let d = get(Self.sessionDefaults)
            session.destination = d.destination
            session.routing = d.routing
            session.lookID = d.look.lookID
            session.lookStrength = d.look.strength
            session.showNewestCapture = d.showNewestCapture
        }
        if let cam = camera {
            var m = self.camera(cam.id) ?? CameraMemory(cameraID: cam.id)
            m.templateID = template?.id ?? m.templateID
            m.destination = session.destination
            m.look = LookStack(lookID: session.lookID, strength: session.lookStrength)
            m.lastSeen = Date()
            remember(camera: m)
        }
    }

    /// Call when a session ends so the next one starts where this left off.
    public func learn(from session: ShootSession) {
        var d = get(Self.sessionDefaults)
        d.destination = session.destination
        d.routing = session.routing
        d.look = LookStack(lookID: session.lookID, strength: session.lookStrength)
        d.showNewestCapture = session.showNewestCapture
        d.autoExportPicks = session.routing.autoExportPicks
        set(Self.sessionDefaults, d)
        if let cam = session.camera {
            var m = camera(cam.id) ?? CameraMemory(cameraID: cam.id)
            m.look = d.look
            m.destination = d.destination
            m.connectionHost = session.lastHost ?? m.connectionHost
            m.lastSeen = Date()
            remember(camera: m)
        }
    }
}
