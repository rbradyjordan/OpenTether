import Foundation
import Observation
import TetherCore

/// Owns the on-device FTP server so it outlives the Connect screen. Received
/// files are forwarded to the active FTP-push shoot through `onFileReceived`.
@Observable @MainActor
final class FTPReceiverModel {
    struct ReceivedFile: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var bytes: Int
        var from: String
        var at: Date
        var duration: TimeInterval
    }

    private(set) var isRunning = false
    private(set) var boundPort: UInt16?
    private(set) var addresses: [String] = []
    private(set) var clients: Int = 0
    private(set) var received: [ReceivedFile] = []
    private(set) var lastError: String?
    var onFileReceived: ((URL, String) async -> Void)?

    private let inbox: URL
    private let settings: AppSettings
    private var server: FTPServer?
    private var eventsTask: Task<Void, Never>?

    init(inbox: URL, settings: AppSettings) {
        self.inbox = inbox
        self.settings = settings
    }

    var username: String { settings.ftpUsername }
    var password: String { settings.ftpPassword }
    var port: UInt16 { settings.ftpPort }
    var primaryAddress: String? { addresses.first ?? CameraDiscoverer.localIPv4Addresses().first }

    func start() {
        guard !isRunning else { return }
        let config = FTPServerConfiguration(port: settings.ftpPort, username: settings.ftpUsername,
                                            password: settings.ftpPassword, allowAnonymous: false, rootDirectory: inbox)
        let server = FTPServer(configuration: config)
        self.server = server
        let stream = server.events
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        do {
            try server.start()
            isRunning = true
            boundPort = server.boundPort
            addresses = server.advertisedAddresses
            lastError = nil
        } catch {
            lastError = "Could not start the FTP server on port \(settings.ftpPort): \(error)"
            self.server = nil
        }
    }

    func stop() {
        server?.stop()
        server = nil
        eventsTask?.cancel()
        isRunning = false
        boundPort = nil
        clients = 0
    }

    /// Credentials changed: restart so the new ones apply.
    func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    private func handle(_ event: FTPServerEvent) async {
        switch event {
        case .started(let port, let addrs):
            boundPort = port
            addresses = addrs
        case .clientConnected:
            clients += 1
        case .clientDisconnected:
            clients = max(0, clients - 1)
        case .loginFailed(let who):
            lastError = "Login failed from \(who). Check the username and password on the camera."
        case .fileReceived(let url, let bytes, let from, let duration):
            received.insert(ReceivedFile(name: url.lastPathComponent, bytes: bytes, from: from, at: Date(), duration: duration), at: 0)
            if received.count > 200 { received.removeLast(received.count - 200) }
            await onFileReceived?(url, from)
        case .rebound(let addrs):
            addresses = addrs
        case .error(let message):
            lastError = message
        case .stopped:
            isRunning = false
        case .transferStarted, .transferProgress:
            break
        }
    }
}
