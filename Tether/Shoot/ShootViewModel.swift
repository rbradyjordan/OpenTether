import Foundation
import Observation
import TetherCore
import UIKit

/// Main-thread mirror of a `TetherSession`: consumes its event stream into
/// observable state and exposes every action the shoot screen needs.
@Observable @MainActor
final class ShootViewModel {
    private(set) var session: TetherSession
    private(set) var shootSession: ShootSession
    private(set) var identity: CameraIdentity?
    private(set) var context: ReconnectContext
    private(set) var status: TetherSession.Status = .idle
    private(set) var items: [CaptureItem] = []
    private(set) var properties: [PropertyDescriptor] = []
    private(set) var selectedItemID: String?
    private(set) var downloadsInFlight = 0
    private(set) var liveViewImage: UIImage?
    private(set) var liveViewActive = false
    private(set) var isCapturing = false
    private(set) var isReconnecting = false
    var lookStack: LookStack
    var toast: ToastMessage?
    var sheet: ShootSheet?
    var showClientReview = false
    var showLoupe = false
    var compareOtherID: String?
    var reconnectError: String?
    /// "Use last time's look X?" banner, from the camera's workspace memory.
    var restoreOffer: WorkspaceMemory.CameraMemory?

    let renderCache: LookRenderCache
    private unowned let app: AppModel
    private var eventsTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Set while the link is known to be down so a stale snapshot cannot flip
    /// the status back to idle/ready.
    private var pendingReconnect = false
    /// Frames that arrived while "Keep current selection" was on.
    private(set) var unseenCount = 0

    init(connection: LiveConnection, app: AppModel) {
        self.app = app
        self.session = connection.session
        self.shootSession = connection.shoot
        self.identity = connection.identity
        self.context = connection.context
        self.lookStack = LookStack(lookID: connection.shoot.lookID, strength: connection.shoot.lookStrength)
        self.renderCache = LookRenderCache(renderer: app.services.renderer, resolver: app.services.lookResolver, cache: app.cache)
        bind()
        offerCameraMemory()
        if connection.needsReconnect {
            pendingReconnect = true
            status = .disconnected("Resumed after the app was closed")
            sheet = .reconnect
        }
    }

    // MARK: Derived

    var capabilities: CameraCapabilities { identity?.capabilities ?? [] }
    var canCapture: Bool { capabilities.contains(.remoteCapture) }
    var canLiveView: Bool { capabilities.contains(.liveView) }
    var canTouchFocus: Bool { capabilities.contains(.touchAutofocus) }
    var canControlProperties: Bool { capabilities.contains(.propertyControl) }
    var isImportOnly: Bool { identity != nil && !canCapture }
    var isLive: Bool { status.isLive }
    var isDisconnected: Bool { if case .disconnected = status { return true }; return false }
    var readyItems: [CaptureItem] { items.filter { $0.state.isReady } }
    var displayedItem: CaptureItem? { items.first { $0.id == selectedItemID } ?? items.last { $0.state.isReady } }
    var cameraName: String { identity?.displayName ?? (shootSession.transport == .ftpPush ? "FTP receiver" : "No camera") }
    var transportName: String { (identity?.transport ?? shootSession.transport)?.displayName ?? "" }
    var batteryText: String? { properties.first { $0.property == .batteryLevel }?.display }
    var exposureDescriptors: [PropertyDescriptor] {
        TetherProperty.exposureBar.compactMap { p in properties.first { $0.property == p } }
    }
    var statusText: String {
        switch status {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .capturing: return "Capturing"
        case .reconnecting: return "Reconnecting"
        case .disconnected(let r): return r
        case .ended: return "Ended"
        }
    }

    /// Items sharing a pair key, newest first (RAW+JPEG indicator).
    func pairCount(for item: CaptureItem) -> Int { items.filter { $0.pairKey == item.pairKey }.count }

    // MARK: Event binding

    private func bind() {
        eventsTask?.cancel()
        let session = session
        let stream = session.events
        eventsTask = Task { [weak self] in
            let snap = await session.snapshot
            self?.apply(snapshot: snap)
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    private func apply(snapshot: TetherSession.Snapshot) {
        shootSession = snapshot.session
        identity = snapshot.identity ?? identity
        if !pendingReconnect { status = snapshot.status }
        items = snapshot.items
        properties = snapshot.properties
        selectedItemID = snapshot.selectedItemID
        downloadsInFlight = snapshot.downloadsInFlight
        liveViewActive = snapshot.liveViewActive
    }

    private func apply(_ event: TetherSession.Event) {
        switch event {
        case .status(let s):
            status = s
            isCapturing = s == .capturing
            if case .disconnected(let reason) = s, !isReconnecting, context != .ftp {
                TetherHaptic.disconnected()
                toast = ToastMessage(text: reason, systemImage: "bolt.slash")
                if !reconnectSnoozed { sheet = .reconnect }
            }
        case .capture(let item):
            let previous = items.first { $0.id == item.id }
            let becameReady = item.state.isReady && !(previous?.state.isReady ?? false)
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
            if previous == nil || becameReady {
                Task { await refreshCounters() }
            }
            // Culling on the phone flows to the hot folder's sidecar (one per
            // RAW+JPEG pair: the RAW's, else the JPEG's).
            if let previous, previous.state.isReady, !becameReady,
               previous.rating != item.rating || previous.flag != item.flag || previous.colorLabel != item.colorLabel,
               item.kind == .raw || !items.contains(where: { $0.pairKey == item.pairKey && $0.kind == .raw }) {
                app.refreshHotFolderSidecar(item, session: shootSession)
            }
            if becameReady {
                TetherHaptic.frameArrived()
                app.sendToHotFolder(item, session: shootSession)
                if !shootSession.showNewestCapture {
                    unseenCount += 1
                    toast = ToastMessage(text: "New frame \(item.filename)", systemImage: "photo.badge.plus", action: "Show")
                }
            }
        case .properties(let p):
            properties = p
            if let id = identity?.id { app.memory.rememberExposure(cameraID: id, exposureDescriptors) }
        case .liveView(let frame):
            let payload = frame.jpeg.jpegPayload() ?? frame.jpeg
            if let img = UIImage(data: payload) { liveViewImage = img }
        case .warning(let w):
            toast = ToastMessage(text: w, systemImage: "exclamationmark.triangle")
        case .selection(let id):
            selectedItemID = id
            if shootSession.showNewestCapture { unseenCount = 0 }
        }
    }

    private func refreshCounters() async {
        let snap = await session.snapshot
        downloadsInFlight = snap.downloadsInFlight
        shootSession = snap.session
    }

    // MARK: Actions

    func capture(autofocus: Bool) {
        guard canCapture, isLive else { return }
        // The capture ring plays the rigid haptic itself: one haptic per event.
        Task {
            do { try await session.capture(autofocus: autofocus) } catch {
                toast = ToastMessage(text: "\(error)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    func setProperty(_ property: TetherProperty, raw: PTPValue) {
        Task {
            do { try await session.setProperty(property, raw: raw) } catch {
                toast = ToastMessage(text: "\(property.displayName): \(error)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    func toggleLiveView() {
        guard canLiveView else { return }
        Task {
            if liveViewActive {
                await session.stopLiveView()
                liveViewActive = false
                liveViewImage = nil
            } else {
                do {
                    try await session.startLiveView(quality: .medium)
                    liveViewActive = true
                } catch {
                    toast = ToastMessage(text: "\(error)", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    /// Where the user last tapped on live view (0…1), shown as the AF box.
    private(set) var focusPoint: CGPoint?
    private(set) var focusPointID = 0

    func focus(at point: CGPoint) {
        guard canTouchFocus, liveViewActive, isLive else { return }
        focusPoint = point
        focusPointID += 1
        TetherHaptic.rate()
        Task {
            do { try await session.focus(atNormalizedX: point.x, y: point.y) } catch {
                toast = ToastMessage(text: "Focus: \(error)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    func select(_ id: String?) {
        TetherHaptic.rate()
        Task { await session.select(id) }
    }

    func showNewest() {
        unseenCount = 0
        if let latest = items.last(where: { $0.state.isReady }) { select(latest.id) }
    }

    func updateRouting(_ routing: RoutingRules) {
        shootSession.routing = routing
        Task { await session.setRouting(routing) }
    }

    func setShowNewestCapture(_ on: Bool) {
        shootSession.showNewestCapture = on
        if on { unseenCount = 0 }
        Task { await session.setShowNewestCapture(on) }
    }

    // Review edits go through the editor so they are undoable and the library
    // sees them; the editor writes the store and pushes the result back here.
    func rate(_ id: String, stars: Int) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].rating = stars }
        app.commands.rate([id], stars)
        if let handler = identity, handler.capabilities.contains(.rating) { Task { await session.rate(id, stars: stars) } }
    }

    /// Flag buttons send the flag to set; tapping the active one clears it.
    func flag(_ id: String, _ flag: CaptureFlag) {
        app.commands.flag([id], flag)
    }

    func label(_ id: String, _ color: TetherCoreColorLabel) {
        let current = items.first { $0.id == id }?.colorLabel
        app.commands.label([id], current == color ? .none : color)
    }

    func addDisplayedToCollection() { if displayedItem != nil { sheet = .addToCollection } }

    // MARK: Camera memory

    private func offerCameraMemory() {
        guard let id = identity?.id, let remembered = app.memory.camera(id), !remembered.look.isNeutral,
              remembered.look != lookStack else { return }
        restoreOffer = remembered
    }

    func acceptRestoreOffer() {
        guard let offer = restoreOffer else { return }
        setLook(offer.look)
        if offer.destination != shootSession.destination { Task { try? await session.setDestination(offer.destination) } }
        restoreOffer = nil
    }

    func declineRestoreOffer() { restoreOffer = nil }

    func delete(_ id: String) {
        Task {
            await session.delete(id)
            items.removeAll { $0.id == id }
            selectedItemID = await session.snapshot.selectedItemID
        }
    }

    func setLook(_ stack: LookStack) {
        lookStack = stack
        Task { await session.setLook(stack) }
    }

    func rename(_ name: String) {
        shootSession.name = name
        Task { await session.rename(name) }
    }

    /// Files / share-sheet import into this session (files or folders,
    /// sidecars matched); see `AppModel.importFromFiles`.
    func importFiles(_ urls: [URL]) {
        Task { await app.importFromFiles(urls, into: shootSession) }
    }

    func ingestFTPFile(_ url: URL, from: String) async {
        guard context == .ftp || shootSession.transport == .ftpPush else { return }
        await session.ingestFile(at: url, from: from)
    }

    func end() async {
        eventsTask?.cancel()
        reconnectTask?.cancel()
        await session.stop(ended: true)
    }

    // MARK: Reconnect

    var reconnectStrategy: ReconnectStrategy { ReconnectStrategy.choose(for: context) }

    /// After foregrounding: a suspended socket shows up as a disconnected
    /// status once the loops notice; poke the snapshot so the sheet appears.
    func checkTransportAfterForeground() {
        Task {
            let snap = await session.snapshot
            status = snap.status
            if case .disconnected = snap.status, context != .ftp, sheet == nil, !reconnectSnoozed { sheet = .reconnect }
        }
    }

    /// Set when the user puts the reconnect sheet away; it then stays away
    /// (reconnecting carries on) until they ask for it or the link is back.
    private(set) var reconnectSnoozed = false

    func snoozeReconnect() {
        guard isDisconnected || status == .reconnecting else { return }
        reconnectSnoozed = true
    }

    func showReconnect() {
        reconnectSnoozed = false
        sheet = .reconnect
    }

    func reconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectError = nil
        let strategy = reconnectStrategy
        switch strategy {
        case .nothingToDo, .startFresh:
            isReconnecting = false
            sheet = nil
            return
        default:
            break
        }
        status = .reconnecting
        pendingReconnect = true
        let services = app.services
        let shoot = shootSession
        let old = session
        reconnectTask = Task {
            defer { isReconnecting = false }
            // The old TetherSession cannot swap transports: close it first so the
            // new one (built over the same stored ShootSession) owns the camera.
            eventsTask?.cancel()
            await old.stop(ended: false)
            do {
                let connection: LiveConnection
                switch strategy {
                case .waitForUSBDevice(let serial):
                    let candidate = try await waitForUSBCandidate(serial: serial, browser: services.usbBrowser)
                    connection = try await ConnectionBuilder.connectUSB(candidate: candidate, shoot: shoot, services: services) { _ in }
                case .retryHost(let host, let port, let vendor):
                    connection = try await ConnectionBuilder.connectPTPIP(host: host, port: port, vendorHint: vendor, shoot: shoot, services: services) { _ in }
                case .retryRicoh(let host):
                    connection = try await ConnectionBuilder.connectRicoh(host: host, shoot: shoot, services: services) { _ in }
                case .retryHTTP(let host, let vendor):
                    connection = try await ConnectionBuilder.connectHTTP(vendor: vendor, host: host, shoot: shoot, services: services) { _ in }
                case .nothingToDo, .startFresh:
                    return
                }
                adopt(connection)
                reconnectSnoozed = false
                sheet = nil
                TetherHaptic.connected()
                toast = ToastMessage(text: "Reconnected to \(cameraName)", systemImage: "checkmark.circle")
            } catch is CancellationError {
                status = .disconnected("Reconnect cancelled")
            } catch {
                reconnectError = "\(error)"
                status = .disconnected("\(error)")
            }
        }
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        isReconnecting = false
    }

    private func adopt(_ connection: LiveConnection) {
        pendingReconnect = false
        session = connection.session
        shootSession = connection.shoot
        identity = connection.identity
        context = connection.context
        liveViewImage = nil
        liveViewActive = false
        bind()
    }

    private func waitForUSBCandidate(serial: String?, browser: USBCameraBrowser) async throws -> USBCameraCandidate {
        browser.start()
        for await event in browser.events {
            try Task.checkCancellation()
            if case .devices(let list) = event, !list.isEmpty {
                if let serial, let match = list.first(where: { $0.serialNumber == serial }) { return match }
                if let first = list.first { return first }
            }
        }
        throw ConnectError.deviceGone
    }
}
