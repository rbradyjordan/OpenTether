import Foundation
import Observation
import TetherCore

@Observable @MainActor
final class USBConnectViewModel {
    private(set) var devices: [USBCameraCandidate] = []
    private(set) var authorization = USBAuthorizationState()
    private(set) var browserError: String?
    var progress: ConnectProgress?
    var isConnecting = false

    private let browser: USBCameraBrowser
    private var task: Task<Void, Never>?

    init(browser: USBCameraBrowser) { self.browser = browser }

    func start() {
        guard task == nil else { return }
        authorization = browser.currentAuthorization()   // what iOS already has, no prompt
        browser.start()
        let stream = browser.events
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .devices(let list): devices = list
                case .authorization(let state): authorization = state
                case .error(let message): browserError = message
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // The browser keeps running while a session is live (reconnect needs it).
    }

    func requestAuthorizations() {
        Task {
            authorization = await browser.requestAuthorizations()
            if authorization.canSendPTP { browser.start() }   // begin seeing cameras now
        }
    }

    func connect(_ candidate: USBCameraCandidate, shoot: ShootSession, app: AppModel) {
        guard !isConnecting else { return }
        isConnecting = true
        var p = ConnectProgress(transport: .usb)
        p.advance(to: .link)
        progress = p
        Task {
            defer { isConnecting = false }
            do {
                let connection = try await ConnectionBuilder.connectUSB(candidate: candidate, shoot: shoot, services: app.services) { [weak self] step in
                    self?.progress?.advance(to: step)
                }
                progress = nil
                app.activate(connection)
            } catch {
                progress?.fail("\(error)")
                HapticFeedback.error()
            }
        }
    }
}
