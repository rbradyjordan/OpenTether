import Foundation
import TetherCore

/// The connect progress list. The PTP/IP handshake (TCP → InitCommand →
/// InitEvent) happens inside `PTPIPTransport.open()` as one call, so those
/// three are advanced together once `open()` returns.
enum ConnectStep: Int, CaseIterable, Comparable, Sendable {
    case link, initCommand, initEvent, session, deviceInfo, vendorGate, ready

    static func < (a: ConnectStep, b: ConnectStep) -> Bool { a.rawValue < b.rawValue }

    static func steps(for transport: TransportKind) -> [ConnectStep] {
        switch transport {
        case .ptpip: return allCases
        case .usb: return [.link, .session, .deviceInfo, .vendorGate, .ready]
        case .ricohHTTP, .http: return [.link, .deviceInfo, .vendorGate, .ready]
        case .ftpPush: return [.link, .ready]
        }
    }

    func title(for transport: TransportKind) -> String {
        switch (self, transport) {
        case (.link, .ptpip): return "TCP connection"
        case (.link, .usb): return "USB session"
        case (.link, .ricohHTTP), (.link, .http): return "Camera reachable over Wi-Fi"
        case (.link, .ftpPush): return "FTP server listening"
        case (.initCommand, _): return "InitCommand handshake"
        case (.initEvent, _): return "Event channel"
        case (.session, _): return "Open PTP session"
        case (.deviceInfo, _): return "Read DeviceInfo"
        case (.vendorGate, _): return "Vendor remote mode"
        case (.ready, _): return "Ready"
        }
    }
}

struct ConnectProgress: Equatable, Sendable {
    var transport: TransportKind
    var current: ConnectStep?
    var completed: Set<ConnectStep> = []
    var failure: String?

    init(transport: TransportKind) { self.transport = transport }

    var steps: [ConnectStep] { ConnectStep.steps(for: transport) }

    /// Marks every earlier step complete and `step` as in progress.
    mutating func advance(to step: ConnectStep) {
        for s in steps where s < step { completed.insert(s) }
        current = step
        if step == .ready { completed.insert(.ready); current = nil }
    }

    mutating func fail(_ message: String) { failure = message }

    func state(of step: ConnectStep) -> StepState {
        if completed.contains(step) { return .done }
        if current == step { return failure == nil ? .running : .failed }
        return .pending
    }

    enum StepState { case pending, running, done, failed }
}
