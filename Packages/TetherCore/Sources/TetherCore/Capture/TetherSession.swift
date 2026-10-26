import Foundation

/// Makes JPEG proxies and thumbnails from an original. The app supplies an
/// ImageIO/Core Image implementation (RAW embedded preview → proxy); tests
/// use `NoPreviewGenerator`.
public struct PreviewOutput: Sendable {
    public var proxyJPEG: Data?
    public var thumbnailJPEG: Data?
    public var width: Int
    public var height: Int
    public init(proxyJPEG: Data? = nil, thumbnailJPEG: Data? = nil, width: Int = 0, height: Int = 0) {
        self.proxyJPEG = proxyJPEG
        self.thumbnailJPEG = thumbnailJPEG
        self.width = width
        self.height = height
    }
}

public protocol PreviewGenerating: Sendable {
    func makePreviews(original: Data, kind: MediaKind, filename: String) async -> PreviewOutput
}

public struct NoPreviewGenerator: PreviewGenerating {
    public init() {}
    public func makePreviews(original: Data, kind: MediaKind, filename: String) async -> PreviewOutput { PreviewOutput() }
}

/// Live state of one tethered shoot: drives the vendor handler, receives
/// captures, writes them through the cache proxy and the store, and exposes
/// a snapshot plus an event stream for the UI.
public actor TetherSession {
    public enum Status: Equatable, Sendable {
        case idle, connecting, preparing, ready, capturing, reconnecting, disconnected(String), ended
        public var isLive: Bool { self == .ready || self == .capturing }
    }

    public enum Event: Sendable {
        case status(Status)
        case capture(CaptureItem)
        case properties([PropertyDescriptor])
        case liveView(LiveViewFrame)
        case warning(String)
        case selection(String?)
    }

    public struct Snapshot: Sendable {
        public var session: ShootSession
        public var identity: CameraIdentity?
        public var status: Status
        public var items: [CaptureItem]
        public var properties: [PropertyDescriptor]
        public var selectedItemID: String?
        public var liveViewActive: Bool
        public var downloadsInFlight: Int
        public var transportHealth: TransportHealth?

        public var displayedItem: CaptureItem? { items.first { $0.id == selectedItemID } ?? items.last { $0.state.isReady } }
        public var readyItems: [CaptureItem] { items.filter { $0.state.isReady } }
    }

    public private(set) var session: ShootSession
    public let identity: CameraIdentity?
    private var handler: VendorHandler?
    private var engine: PTPEngine?
    private let store: SessionStore
    private let cache: CaptureCacheProxy
    private let previews: PreviewGenerating
    private var items: [CaptureItem] = []
    private var properties: [PropertyDescriptor] = []
    private var status: Status = .idle
    private var selectedItemID: String?
    private var knownHandles: Set<UInt32> = []
    private var downloadQueue: [NewObject] = []
    private var downloading = false
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    private var propertyRefreshTask: Task<Void, Never>?
    private var transportHealth: TransportHealth?
    /// Sidecars that arrived on their own (FTP push), by pair key, so the
    /// photo or its RAW/JPEG twin picks them up whichever lands first.
    private var pendingSidecars: [String: XMPPacket] = [:]
    /// Fans every event out to each subscriber: the shoot screen and the
    /// library both listen, and a plain `AsyncStream` would split events
    /// between them.
    private let broadcaster = ValueBroadcaster<Event>()
    /// A new stream of every event from now on; each caller gets its own.
    public nonisolated var events: AsyncStream<Event> { broadcaster.stream(replayLatest: false) }

    /// Properties shown on the shoot screen; vendors fill what they have.
    public static let trackedProperties: [TetherProperty] = [.shutterSpeed, .aperture, .iso, .exposureCompensation, .whiteBalance, .batteryLevel, .captureDestination, .storageFreeImages, .exposureProgram, .driveMode, .focusMode]

    public init(session: ShootSession, identity: CameraIdentity?, handler: VendorHandler?, engine: PTPEngine?,
                store: SessionStore, cache: CaptureCacheProxy, previews: PreviewGenerating = NoPreviewGenerator()) {
        self.session = session
        self.identity = identity
        self.handler = handler
        self.engine = engine
        self.store = store
        self.cache = cache
        self.previews = previews
        items = (try? store.captures(in: session.id)) ?? []
        knownHandles = Set(items.map(\.handle))
        selectedItemID = items.last { $0.state.isReady }?.id
    }

    public var snapshot: Snapshot {
        Snapshot(session: session, identity: identity, status: status, items: items, properties: properties,
                 selectedItemID: selectedItemID, liveViewActive: liveViewTask != nil,
                 downloadsInFlight: downloadQueue.count + (downloading ? 1 : 0), transportHealth: transportHealth)
    }

    // MARK: Lifecycle

    /// Prepare the camera (vendor gate), apply the destination, read the
    /// settings bar, then start the event + poll loops. Safe to call again
    /// after a reconnect.
    public func start() async throws {
        guard let handler else {
            // FTP-push sessions have no camera link; they only ingest files.
            setStatus(.ready)
            return
        }
        setStatus(.preparing)
        do {
            try await handler.prepare()
            do { try await handler.setCaptureDestination(session.destination) } catch let e as PTPError {
                if case .unsupported(let m) = e { warn(m) } else { throw e }
            }
            await refreshProperties()
            startLoops()
            if session.status != .active { session.status = .active; persistSession() }
            setStatus(.ready)
            await recoverPendingDownloads()
        } catch {
            setStatus(.disconnected("\(error)"))
            throw error
        }
    }

    public func stop(ended: Bool) async {
        eventTask?.cancel(); pollTask?.cancel(); propertyRefreshTask?.cancel()
        eventTask = nil; pollTask = nil; propertyRefreshTask = nil
        await stopLiveView()
        await handler?.teardown()
        await engine?.disconnect()
        session.status = ended ? .ended : .interrupted
        if ended { session.endedAt = Date() }
        persistSession()
        setStatus(ended ? .ended : .disconnected("Stopped"))
    }

    /// Reconnect over a fresh transport while keeping the session, its items
    /// and selection: swap the camera link and run `start()` again.
    public func reattach(handler: VendorHandler?, engine: PTPEngine?) async throws {
        eventTask?.cancel(); pollTask?.cancel(); liveViewTask?.cancel()
        eventTask = nil; pollTask = nil; liveViewTask = nil
        await self.engine?.disconnect()
        self.handler = handler
        self.engine = engine
        setStatus(.reconnecting)
        try await start()
    }

    /// The transport dropped (cable pulled, Wi-Fi lost). The UI offers reconnect.
    public func markDisconnected(_ reason: String) {
        eventTask?.cancel(); pollTask?.cancel(); liveViewTask?.cancel()
        eventTask = nil; pollTask = nil; liveViewTask = nil
        session.status = .interrupted
        persistSession()
        setStatus(.disconnected(reason))
    }

    private func startLoops() {
        eventTask?.cancel(); pollTask?.cancel()
        if let engine, let handler {
            eventTask = Task { [weak self] in
                let stream = await engine.events
                for await ev in stream {
                    guard let self else { return }
                    if let translated = await handler.translate(ev) { await self.handle(translated) }
                }
                await self?.markDisconnected("The camera connection closed.")
            }
        }
        if let handler {
            let interval = handler.eventPollInterval
            pollTask = Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard let self else { return }
                    do {
                        for ev in try await handler.pollEvents() { await self.handle(ev) }
                        failures = 0
                    } catch {
                        failures += 1
                        if failures >= 5 { await self.markDisconnected("Lost contact with the camera: \(error)"); return }
                    }
                }
            }
        }
    }

    // MARK: Camera control

    public func capture(autofocus: Bool = true) async throws {
        guard let handler, status.isLive else { throw PTPError.notConnected }
        setStatus(.capturing)
        defer { if status == .capturing { setStatus(.ready) } }
        try await handler.capture(autofocus: autofocus)
    }

    public func setProperty(_ property: TetherProperty, raw: PTPValue) async throws {
        guard let handler else { throw PTPError.notConnected }
        try await handler.writeProperty(property, raw: raw)
        if let i = properties.firstIndex(where: { $0.property == property }) {
            properties[i].raw = raw
            properties[i].display = properties[i].choices.first { $0.raw == raw }?.display ?? properties[i].display
            broadcaster.send(.properties(properties))
        }
        scheduleRefresh(after: 0.4)
    }

    public func refreshProperties() async {
        guard let handler else { return }
        if let p = try? await handler.readProperties(Self.trackedProperties) {
            properties = p
            broadcaster.send(.properties(p))
        }
    }

    private func scheduleRefresh(after seconds: TimeInterval) {
        propertyRefreshTask?.cancel()
        propertyRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshProperties()
        }
    }

    public func setDestination(_ d: CaptureDestination) async throws {
        try await handler?.setCaptureDestination(d)
        session.destination = d
        persistSession()
    }

    // MARK: Live view

    public func startLiveView(quality: LiveViewQuality = .medium) async throws {
        guard let handler, liveViewTask == nil else { return }
        try await handler.startLiveView(quality: quality)
        liveViewTask = Task { [weak self] in
            var sequence: UInt64 = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    if var frame = try await handler.nextLiveViewFrame() {
                        sequence += 1
                        frame.sequence = sequence
                        self.broadcaster.send(.liveView(frame))
                    } else {
                        try await Task.sleep(nanoseconds: 33_000_000)
                    }
                } catch {
                    await self.warn("Live view stopped: \(error)")
                    await self.stopLiveView()
                    return
                }
            }
        }
    }

    /// Touch AF: focus at a point of the live-view frame, 0…1 from the top left.
    public func focus(atNormalizedX x: Double, y: Double) async throws -> FocusResult {
        guard let handler, status.isLive else { throw PTPError.notConnected }
        return try await handler.focus(atNormalizedX: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Press-and-hold focus: AF runs until `stopTrackingFocus`.
    public func startTrackingFocus(atNormalizedX x: Double, y: Double) async throws {
        guard let handler, status.isLive else { throw PTPError.notConnected }
        try await handler.startTrackingFocus(atNormalizedX: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public func stopTrackingFocus() async {
        await handler?.stopTrackingFocus()
    }

    public func stopLiveView() async {
        guard liveViewTask != nil else { return }
        liveViewTask?.cancel()
        liveViewTask = nil
        await handler?.stopLiveView()
    }

    // MARK: Events → captures

    public func handle(_ event: CameraEvent) async {
        switch event {
        case .objectAdded(let obj):
            guard !knownHandles.contains(obj.handle) || obj.inSDRAM else { return }
            knownHandles.insert(obj.handle)
            guard session.destination.wantsTransfer || obj.inSDRAM || session.transport == .ptpip else {
                // Card-only: still register the capture so the filmstrip counts it.
                return
            }
            downloadQueue.append(obj)
            pumpDownloads()
        case .objectRemoved(let h):
            knownHandles.remove(h)
        case .propertyChanged:
            scheduleRefresh(after: 0.2)
        case .captureComplete:
            if status == .capturing { setStatus(.ready) }
        case .storageChanged:
            scheduleRefresh(after: 0.5)
        case .cameraBusy(let busy):
            if busy, status == .ready { setStatus(.capturing) } else if !busy, status == .capturing { setStatus(.ready) }
        case .shutterPressed:
            setStatus(.capturing)
        case .warning(let w):
            warn(w)
        case .disconnected:
            markDisconnected("The camera disconnected.")
        case .raw:
            break
        }
    }

    private func pumpDownloads() {
        guard !downloading, let next = downloadQueue.first else { return }
        downloadQueue.removeFirst()
        downloading = true
        Task { [weak self] in
            await self?.download(next)
            await self?.finishedDownload()
        }
    }

    private func finishedDownload() {
        downloading = false
        pumpDownloads()
    }

    private func download(_ obj: NewObject) async {
        guard let handler else { return }
        let seq = (try? store.nextSequence(in: session.id)) ?? (items.count + 1)
        var item = CaptureItem(sessionID: session.id, sequence: seq, handle: obj.handle,
                               filename: obj.info?.filename ?? "capture-\(seq)", kind: obj.info?.mediaKind ?? .other,
                               bytes: Int(obj.info?.objectCompressedSize ?? 0), source: identity?.transport ?? .usb,
                               lookID: session.lookID, exposure: ExposureSummary(from: properties), cameraID: identity?.id)
        if let info = obj.info { apply(info, to: &item) }
        item.state = .downloading(received: 0, total: item.bytes > 0 ? item.bytes : nil)
        upsert(item)

        let id = item.id
        do {
            let (info, data) = try await handler.fetchObject(obj) { [weak self] received, total in
                Task { await self?.progress(id: id, received: received, total: total) }
            }
            guard var current = items.first(where: { $0.id == id }) else { return }
            apply(info, to: &current)
            current.bytes = data.count
            let path = try cache.store(data, at: cache.originalPath(session: session, filename: current.filename))
            current.relativePath = path
            let out = await previews.makePreviews(original: data, kind: current.kind, filename: current.filename)
            if out.width > 0 { current.width = out.width; current.height = out.height }
            if let p = out.proxyJPEG { current.proxyRelativePath = try? cache.store(p, at: cache.proxyPath(session: session, filename: current.filename)) }
            if let t = out.thumbnailJPEG { current.thumbnailRelativePath = try? cache.store(t, at: cache.thumbnailPath(session: session, filename: current.filename)) }
            current.state = .ready
            current.receivedAt = Date()
            upsert(current)
            session.captureCount += 1
            persistSession()
            if session.showNewestCapture || selectedItemID == nil {
                select(current.id)
            }
            if obj.inSDRAM, let engine, identity?.vendor == .generic, session.destination == .host {
                _ = try? await engine.deleteObject(obj.handle)
            }
        } catch {
            if var failed = items.first(where: { $0.id == id }) {
                failed.state = .failed("\(error)")
                upsert(failed)
            }
            warn("Download of \(item.filename) failed: \(error)")
            if case PTPError.transportClosed = error { markDisconnected("The camera connection closed during a download.") }
        }
    }

    private func apply(_ info: PTPObjectInfo, to item: inout CaptureItem) {
        if !info.filename.isEmpty { item.filename = info.filename; item.pairKey = CaptureItem.pairKey(for: info.filename) }
        item.kind = info.mediaKind
        if info.objectCompressedSize > 0 { item.bytes = Int(info.objectCompressedSize) }
        if info.imagePixWidth > 0 { item.width = Int(info.imagePixWidth); item.height = Int(info.imagePixHeight) }
        if let d = info.captureDateValue { item.capturedAt = d }
    }

    private func progress(id: String, received: Int, total: Int?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .downloading(received: received, total: total ?? (items[i].bytes > 0 ? items[i].bytes : nil))
        broadcaster.send(.capture(items[i]))
    }

    /// Captures left half-downloaded by a crash: card objects can be fetched
    /// again by handle; SDRAM ones are gone and marked failed.
    private func recoverPendingDownloads() async {
        for item in items where !item.state.isReady && !item.state.isFailed {
            if item.handle == 0 || item.handle >= 0xFFFF_0000 || item.handle == 0x8000_0001 {
                var f = item; f.state = .failed("Lost when the app stopped (camera buffer only)"); upsert(f)
            } else {
                knownHandles.remove(item.handle)
                try? store.deleteCapture(item.id)
                items.removeAll { $0.id == item.id }
                await handle(.objectAdded(NewObject(handle: item.handle)))
            }
        }
    }

    // MARK: FTP push ingest

    /// A file the camera pushed to our FTP server, or one imported from Files:
    /// adopt it as a capture. `sidecar` is its XMP when the caller already
    /// matched one (Files import); otherwise `<name>.xmp` beside it is used.
    /// `consumeSource` deletes the file and sidecar afterwards: only for
    /// private copies (FTP inbox, temporary import copies), never a user folder.
    public func ingestFile(at url: URL, from: String, sidecar: URL? = nil, consumeSource: Bool = true) async {
        // A sidecar on its own is metadata, not a frame. Cameras and Photo
        // Mechanic send it before or after the photo: apply it to the frame
        // (and its twin) already here, and remember it for any half of the
        // pair still to come.
        if url.pathExtension.lowercased() == "xmp" {
            let key = CaptureItem.pairKey(for: url.deletingPathExtension().lastPathComponent)
            if let data = try? Data(contentsOf: url), let packet = try? XMPPacket(parsing: data) {
                pendingSidecars[key] = packet
                for var target in items where target.pairKey == key {
                    let tags = packet.applied(to: &target)
                    upsert(target)
                    if !tags.isEmpty { try? store.addTags(tags, to: [target.id]) }
                }
            }
            if consumeSource { try? FileManager.default.removeItem(at: url) }
            return
        }
        let seq = (try? store.nextSequence(in: session.id)) ?? (items.count + 1)
        let name = url.lastPathComponent
        let kind = PTPObjectInfo(objectFormat: .undefined, filename: name).mediaKind
        var item = CaptureItem(sessionID: session.id, sequence: seq, handle: UInt32(truncatingIfNeeded: seq), filename: name,
                               kind: kind, bytes: 0, source: .ftpPush, lookID: session.lookID, cameraID: identity?.id)
        do {
            let data = try Data(contentsOf: url)
            item.bytes = data.count
            item.relativePath = try cache.store(data, at: cache.originalPath(session: session, filename: name))
            let out = await previews.makePreviews(original: data, kind: kind, filename: name)
            item.width = out.width; item.height = out.height
            if let p = out.proxyJPEG { item.proxyRelativePath = try? cache.store(p, at: cache.proxyPath(session: session, filename: name)) }
            if let t = out.thumbnailJPEG { item.thumbnailRelativePath = try? cache.store(t, at: cache.thumbnailPath(session: session, filename: name)) }
            item.state = .ready
            // Interop: metadata that came with the file (Photo Mechanic / Capture
            // One sidecar, or an embedded packet) seeds rating, flag, label, tags.
            var incomingTags: [String] = []
            let candidates = [sidecar, url.deletingPathExtension().appendingPathExtension("xmp"), url.appendingPathExtension("xmp")].compactMap { $0 }
            let sidecarURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
            if let sc = try? Data(contentsOf: sidecarURL), let packet = try? XMPPacket(parsing: sc) {
                incomingTags = packet.applied(to: &item)
                pendingSidecars[item.pairKey] = packet   // for the twin, if it comes later
                if consumeSource { try? FileManager.default.removeItem(at: sidecarURL) }
            } else if let packet = pendingSidecars[item.pairKey] {
                incomingTags = packet.applied(to: &item)
            } else if kind == .jpeg, let packet = try? JPEGXMP.extract(from: data) {
                incomingTags = packet.applied(to: &item)
            }
            if consumeSource { try? FileManager.default.removeItem(at: url) }
            upsert(item)
            if !incomingTags.isEmpty { try? store.addTags(incomingTags, to: [item.id]) }
        } catch {
            item.state = .failed("\(error)")
        }
        upsert(item)
        session.captureCount += 1
        persistSession()
        if session.showNewestCapture || selectedItemID == nil { select(item.id) }
    }

    // MARK: Review

    public func select(_ id: String?) {
        selectedItemID = id
        broadcaster.send(.selection(id))
    }

    public func setRouting(_ routing: RoutingRules) {
        session.routing = routing
        persistSession()
    }

    public func setShowNewestCapture(_ on: Bool) {
        session.showNewestCapture = on
        persistSession()
        if on, let latest = items.last(where: { $0.state.isReady }) { select(latest.id) }
    }

    public func setLook(_ stack: LookStack) {
        session.lookID = stack.lookID
        session.lookStrength = stack.strength
        persistSession()
    }

    public func rate(_ id: String, stars: Int) async {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.rating = max(0, min(5, stars))
        upsert(item)
        if let handler, handler.capabilities.contains(.rating) { try? await handler.setRating(handle: item.handle, stars: item.rating) }
        // keep the pair in sync
        for var twin in items where twin.pairKey == item.pairKey && twin.id != item.id { twin.rating = item.rating; upsert(twin) }
    }

    public func flag(_ id: String, _ flag: CaptureFlag) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.flag = item.flag == flag ? .none : flag
        upsert(item)
        for var twin in items where twin.pairKey == item.pairKey && twin.id != item.id { twin.flag = item.flag; upsert(twin) }
    }

    public func label(_ id: String, _ color: ColorLabel) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.colorLabel = item.colorLabel == color ? .none : color
        upsert(item)
        for var twin in items where twin.pairKey == item.pairKey && twin.id != item.id { twin.colorLabel = item.colorLabel; upsert(twin) }
    }

    public func delete(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        [item.relativePath, item.proxyRelativePath, item.thumbnailRelativePath].compactMap { $0 }.forEach(cache.remove)
        items.removeAll { $0.id == id }
        try? store.deleteCapture(id)
        if selectedItemID == id { select(items.last { $0.state.isReady }?.id) }
    }

    public func rename(_ name: String) {
        session.name = name
        persistSession()
    }

    /// The library edited one of our captures (rating, flag, label): take the
    /// stored version so the filmstrip agrees without a second write.
    public func replaceFromStore(_ item: CaptureItem) async {
        guard item.sessionID == session.id, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let previousRating = items[i].rating
        items[i] = item
        broadcaster.send(.capture(item))
        // Library edits reach the camera too when it keeps ratings.
        if item.rating != previousRating, let handler, handler.capabilities.contains(.rating) {
            try? await handler.setRating(handle: item.handle, stars: item.rating)
        }
    }

    // MARK: Internals

    private func upsert(_ item: CaptureItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        try? store.save(item)
        broadcaster.send(.capture(item))
    }

    private func persistSession() { try? store.save(session) }

    private func setStatus(_ s: Status) {
        status = s
        broadcaster.send(.status(s))
    }

    private func warn(_ s: String) { broadcaster.send(.warning(s)) }

    public func updateTransportHealth(_ h: TransportHealth) { transportHealth = h }
}
