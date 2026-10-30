import Foundation
import TetherCore

enum ConnectError: Error, CustomStringConvertible {
    case deviceGone
    case badHost(String)
    case cancelled
    var description: String {
        switch self {
        case .deviceGone: return "The camera is no longer on the USB bus."
        case .badHost(let h): return "\"\(h)\" is not a usable address."
        case .cancelled: return "Connection cancelled."
        }
    }
}

/// The one place a transport becomes a running `TetherSession`.
enum ConnectionBuilder {
    typealias Progress = @MainActor (ConnectStep) -> Void

    static func connectUSB(candidate: USBCameraCandidate, shoot: ShootSession, services: AppServices,
                           progress: @escaping Progress) async throws -> LiveConnection {
        guard let device = services.usbBrowser.device(id: candidate.id) else { throw ConnectError.deviceGone }
        let transport = ImageCaptureCoreTransport(device: device)
        let engine = PTPEngine(transport: transport, log: services.ptpLog)
        await progress(.link)
        try await transport.open()
        await progress(.session)
        let info = try await engine.connect()
        await progress(.deviceInfo)
        let handler = VendorRegistry.makeHandler(engine: engine, info: info, transport: .usb)
        let identity = CameraIdentity(info: info, transport: .usb, capabilities: handler.capabilities, fallbackID: candidate.id)
        let session = try makeSession(shoot: shoot, identity: identity, transport: .usb, host: nil,
                                      handler: handler, engine: engine, services: services)
        transport.onDisconnect = { reason in Task { await session.markDisconnected(reason) } }
        await progress(.vendorGate)
        try await session.start()
        await progress(.ready)
        return LiveConnection(session: session, shoot: await session.session, identity: identity,
                              context: .usb(deviceID: candidate.id, serial: candidate.serialNumber ?? info.serialNumber))
    }

    static func connectPTPIP(host: String, port: UInt16, vendorHint: CameraVendor?, shoot: ShootSession,
                             services: AppServices, progress: @escaping Progress, pairing: Bool = false,
                             handshake: (@Sendable (PTPIPTransport.HandshakeStage) -> Void)? = nil) async throws -> LiveConnection {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConnectError.badHost(host) }
        let guid = PTPIPIdentity.guid(from: services.stableGUID)
        // The camera remembers this name and GUID as the pairing, and on a
        // first connection waits for the user to confirm on its screen.
        var config = PTPIPTransport.Configuration(host: trimmed, port: port, clientName: PTPIPIdentity.clientName, guid: guid,
                                                  handshakeTimeout: PTPIPIdentity.pairingTimeout, vendorHint: vendorHint)
        if pairing {
            // A body saving a new phone drops and refuses a few times first.
            config.handshakeRetries = 8
            config.retryDelay = 1.5
        }
        config.onProgress = { stage in
            handshake?(stage)
            let step: ConnectStep
            switch stage {
            case .tcpConnected, .awaitingConfirmation, .retrying: step = .initCommand
            case .initCommandAcked, .eventConnected: step = .initEvent
            case .eventAcked: step = .session
            }
            Task { await progress(step) }
        }
        let transport = PTPIPTransport(configuration: config)
        let engine = PTPEngine(transport: transport, log: services.ptpLog)
        await progress(.link)
        try await transport.open()
        await progress(.session)
        let info = try await engine.connect()
        await progress(.deviceInfo)
        let handler = VendorRegistry.makeHandler(engine: engine, info: info, transport: .ptpip)
        let identity = CameraIdentity(info: info, transport: .ptpip, capabilities: handler.capabilities, fallbackID: "ptpip-\(trimmed)")
        let session = try makeSession(shoot: shoot, identity: identity, transport: .ptpip, host: trimmed,
                                      handler: handler, engine: engine, services: services)
        await progress(.vendorGate)
        try await session.start()
        await progress(.ready)
        return LiveConnection(session: session, shoot: await session.session, identity: identity,
                              context: .ptpip(host: trimmed, port: port, vendor: identity.vendor))
    }

    static func connectRicoh(host: String, shoot: ShootSession, services: AppServices,
                             progress: @escaping Progress) async throws -> LiveConnection {
        try await connectHTTP(vendor: .ricoh, host: host, shoot: shoot, services: services, progress: progress)
    }

    /// Cameras controlled over HTTP on their own Wi-Fi: Ricoh GR, GoPro,
    /// and 360° cameras speaking the Open Spherical Camera API.
    static func connectHTTP(vendor: CameraVendor, host: String, shoot: ShootSession, services: AppServices,
                            progress: @escaping Progress) async throws -> LiveConnection {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: "http://\(trimmed)"), !trimmed.isEmpty else { throw ConnectError.badHost(host) }
        let handler: any HTTPCameraHandler
        switch vendor {
        case .gopro: handler = GoProHandler(baseURL: base)
        case .osc: handler = OSCHandler(baseURL: base)
        default: handler = RicohHandler(baseURL: base)
        }
        await progress(.link)
        let identity = try await handler.probeIdentity()
        await progress(.deviceInfo)
        let transport: TransportKind = vendor == .ricoh ? .ricohHTTP : .http
        let session = try makeSession(shoot: shoot, identity: identity, transport: transport, host: trimmed,
                                      handler: handler, engine: nil, services: services)
        await progress(.vendorGate)
        try await session.start()
        await progress(.ready)
        let context: ReconnectContext = vendor == .ricoh ? .ricoh(host: trimmed) : .http(host: trimmed, vendor: vendor)
        return LiveConnection(session: session, shoot: await session.session, identity: identity, context: context)
    }

    /// FTP push: no camera link, the session only ingests files the receiver hands it.
    static func startFTPSession(shoot: ShootSession, services: AppServices) async throws -> LiveConnection {
        let session = try makeSession(shoot: shoot, identity: nil, transport: .ftpPush, host: nil,
                                      handler: nil, engine: nil, services: services)
        try await session.start()
        return LiveConnection(session: session, shoot: await session.session, identity: nil, context: .ftp)
    }

    private static func makeSession(shoot: ShootSession, identity: CameraIdentity?, transport: TransportKind, host: String?,
                                    handler: VendorHandler?, engine: PTPEngine?, services: AppServices) throws -> TetherSession {
        var s = shoot
        s.camera = identity ?? s.camera
        s.transport = transport
        s.lastHost = host ?? s.lastHost
        s.status = .active
        try services.store.save(s)
        if let identity { try? services.store.rememberCamera(identity, host: host) }
        return TetherSession(session: s, identity: identity, handler: handler, engine: engine,
                             store: services.store, cache: services.cache, previews: services.previews)
    }
}

extension AppServices {
    /// PTP/IP wants a stable client GUID so cameras that pair by GUID recognise us.
    var stableGUID: UUID {
        if let s = store.setting("ptpip.guid"), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        store.setSetting("ptpip.guid", u.uuidString)
        return u
    }
}
