import Foundation

/// Mid-shoot recovery: what to do when the link drops or the app comes back
/// from the background. Pure logic so the UI and tests share one answer.
public struct ReconnectPolicy: Equatable, Sendable {
    public enum Strategy: Equatable, Sendable {
        /// Wait for the same USB device to reappear, then reopen the session.
        case waitForUSBDevice(candidateID: String?, serial: String?)
        /// Dial the camera's last address again (PTP/IP or Ricoh HTTP).
        case redial(host: String, port: UInt16)
        /// Nothing to reconnect: the camera pushes to us.
        case ftpPassive
        /// We cannot reconnect without the user (no host remembered).
        case askUser(String)
    }

    public var strategy: Strategy
    public var attempts: Int
    public var maxAttempts: Int

    public init(session: ShootSession, identity: CameraIdentity?, usbCandidateID: String? = nil, maxAttempts: Int = 8) {
        self.attempts = 0
        self.maxAttempts = maxAttempts
        switch session.transport ?? identity?.transport {
        case .usb?:
            strategy = .waitForUSBDevice(candidateID: usbCandidateID, serial: identity?.serialNumber)
        case .ptpip?:
            if let h = session.lastHost { strategy = .redial(host: h, port: PTPIPPacket.standardPort) }
            else { strategy = .askUser("The camera's address is unknown. Find it on the network again.") }
        case .ricohHTTP?:
            strategy = .redial(host: session.lastHost ?? "192.168.0.1", port: 80)
        case .http?:
            if let h = session.lastHost { strategy = .redial(host: h, port: 80) }
            else { strategy = .askUser("Join the camera's Wi-Fi again, then pick it from the list.") }
        case .ftpPush?:
            strategy = .ftpPassive
        case nil:
            strategy = .askUser("This session has no camera link.")
        }
    }

    /// Exponential backoff capped at 15 s; nil when we should stop trying.
    public mutating func nextDelay() -> TimeInterval? {
        guard attempts < maxAttempts else { return nil }
        attempts += 1
        return min(15, 0.5 * pow(2, Double(attempts - 1)))
    }

    public var userMessage: String {
        switch strategy {
        case .waitForUSBDevice: return "Plug the camera back in. Open Tether reconnects as soon as it sees it."
        case .redial(let h, _): return "Reconnecting to the camera at \(h)…"
        case .ftpPassive: return "The camera sends files when it is ready. Check it is still on the same Wi-Fi."
        case .askUser(let s): return s
        }
    }

    /// True when a USB candidate is the camera we lost.
    public func matches(_ candidate: USBCameraCandidate) -> Bool {
        guard case .waitForUSBDevice(let id, let serial) = strategy else { return false }
        if let id, id == candidate.id { return true }
        if let serial, !serial.isEmpty, candidate.serialNumber == serial { return true }
        return id == nil && serial == nil
    }
}
