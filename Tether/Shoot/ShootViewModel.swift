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

    let renderCache: LookRenderCache
    private unowned let app: AppModel
    private var eventsTask: Task<Void, Never>?
    private var usbWaitTask: Task<Void, Never>?
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
        if connection.needsReconnect {
            status = .disconnected("Resumed after the app was closed")
            sheet = .reconnect
        }
    }

    // MARK: Derived

    var capabilities: CameraCapabilities { identity?.capabilities ?? [] }
    var canCapture: Bool { capabilities.contains(.remoteCapture) }
    var canLiveView: Bool { capabilities.contains(.liveView) }
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
        status = snapshot.status
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
                HapticFeedback.warning()
                toast = ToastMessage(text: reason, systemImage: "bolt.slash")
                sheet = .reconnect
            }
        case .capture(let item):
            let isNew = !items.contains { $0.id == item.id }
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
            if isNew || item.state.isReady {
                Task { await refreshCounters() }
            }
            if item.state.isReady, !shootSession.showNewestCapture, isNew || selectedItemID != item.id {
                unseenCount += 1
                toast = ToastMessage(text: "New frame \(item.filename)", systemImage: "photo.badge.plus", action: "Show")
            }
            if item.state.isReady, isNew { HapticFeedback.light() }
        case .properties(let p):
            properties = p
        case .liveView(let frame):
            if let payload = frame.jpeg.jpegPayload() ?? Optional(frame.jpeg), let img = UIImage(data: payload) {
                liveViewImage = img
            }
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
        HapticFeedback.shutter()
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

    func select(_ id: String?) {
        HapticFeedback.selection()
        Task { await session.select(id) }
    }

    func showNewest() {
        unseenCount = 0
        if let latest = items.last(where: { $0.state.isReady }) { select(latest.id) }
    }

    func setShowNewestCapture(_ on: Bool) {
        shootSession.showNewestCapture = on
        if on { unseenCount = 0 }
        Task { await session.setShowNewestCapture(on) }
    }

    func rate(_ id: String, stars: Int) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].rating = stars }
        Task { await session.rate(id, stars: stars) }
    }

    func flag(_ id: String, _ flag: CaptureFlag) { Task { await session.flag(id, flag) } }
    func label(_ id: String, _ color: TetherCoreColorLabel) { Task { await session.label(id, color) } }

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

    func ingestFTPFile(_ url: URL, from: String) async {
        guard context == .ftp || shootSession.transport == .ftpPush else { return }
        await session.ingestFile(at: url, from: from)
    }

    func end() async {
        eventsTask?.cancel()
        usbWaitTask?.cancel()
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
            if case .disconnected = snap.status, context != .ftp, sheet == nil { sheet = .reconnect }
        }
    }

    func reconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectError = nil
        status = .reconnecting
        let strategy = reconnectStrategy
        let services = app.services
        let shoot = shootSession
        Task {
            defer { isReconnecting = false }
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
                case .nothingToDo:
                    sheet = nil
                    return
                case .startFresh:
                    sheet = nil
                    return
                }
                adopt(connection)
                sheet = nil
                HapticFeedback.success()
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
        usbWaitTask?.cancel()
        isReconnecting = false
    }

    /// The old `TetherSession` cannot swap transports, so a reconnect builds a
    /// fresh one over the same stored `ShootSession` (the store holds every capture).
    private func adopt(_ connection: LiveConnection) {
        let old = session
        Task { await old.stop(ended: false) }
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
