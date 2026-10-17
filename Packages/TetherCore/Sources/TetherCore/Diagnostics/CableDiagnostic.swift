import Foundation

/// The cable/power diagnostic screen: an ordered list of checks, each with a
/// result and a plain-language tip. Checks are injected so the app can wire
/// the real USB/Wi-Fi probes and tests can script outcomes.
public struct DiagnosticCheck: Identifiable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case pending, running, pass(String), warn(String), fail(String), skipped(String)
        public var isFailure: Bool { if case .fail = self { return true }; return false }
        public var isPass: Bool { if case .pass = self { return true }; return false }
        public var detail: String {
            switch self {
            case .pending: return "Waiting"
            case .running: return "Checking…"
            case .pass(let s), .warn(let s), .fail(let s), .skipped(let s): return s
            }
        }
    }

    public var id: String
    public var title: String
    public var tip: String
    public var run: @Sendable () async -> Outcome
    public var outcome: Outcome = .pending

    public init(id: String, title: String, tip: String, run: @escaping @Sendable () async -> Outcome) {
        self.id = id
        self.title = title
        self.tip = tip
        self.run = run
    }
}

public struct DiagnosticReport: Sendable {
    public var checks: [DiagnosticCheck]
    public var startedAt: Date
    public var finishedAt: Date?

    public var verdict: String {
        if checks.contains(where: { $0.outcome.isFailure }) { return "Something is blocking the tether" }
        if checks.contains(where: { if case .warn = $0.outcome { return true }; return false }) { return "Working, with warnings" }
        if finishedAt == nil { return "Checking…" }
        return "Everything looks good"
    }

    public var firstFailure: DiagnosticCheck? { checks.first { $0.outcome.isFailure } }

    /// Text the user can paste into a support message.
    public var shareText: String {
        var s = "Tether diagnostic \(ISO8601DateFormatter().string(from: startedAt))\n"
        for c in checks {
            let mark: String
            switch c.outcome {
            case .pass: mark = "✓"
            case .warn: mark = "!"
            case .fail: mark = "✗"
            case .skipped: mark = "–"
            default: mark = "…"
            }
            s += "\(mark) \(c.title): \(c.outcome.detail)\n"
        }
        return s
    }
}

/// Runs checks in order, stopping early when a prerequisite fails (there is
/// no point probing PTP when no device is on the bus).
public final class DiagnosticRunner: @unchecked Sendable {
    public enum Event: Sendable { case updated(DiagnosticReport), finished(DiagnosticReport) }

    private var report: DiagnosticReport
    private let stopOnFailure: Bool
    private let continuation: AsyncStream<Event>.Continuation
    public let events: AsyncStream<Event>

    public init(checks: [DiagnosticCheck], stopOnFailure: Bool = true) {
        report = DiagnosticReport(checks: checks, startedAt: Date())
        self.stopOnFailure = stopOnFailure
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { c = $0 }
        continuation = c
    }

    public func run() async -> DiagnosticReport {
        var halted = false
        for i in report.checks.indices {
            if halted {
                report.checks[i].outcome = .skipped("Skipped because an earlier check failed")
                continuation.yield(.updated(report))
                continue
            }
            report.checks[i].outcome = .running
            continuation.yield(.updated(report))
            let outcome = await report.checks[i].run()
            report.checks[i].outcome = outcome
            continuation.yield(.updated(report))
            if outcome.isFailure, stopOnFailure { halted = true }
        }
        report.finishedAt = Date()
        continuation.yield(.finished(report))
        return report
    }
}

/// The standard wired checklist. The app passes closures that use its USB
/// browser/transport; everything here is transport-agnostic text.
public enum WiredDiagnostics {
    public struct Probes: Sendable {
        public var deviceOnBus: @Sendable () async -> USBCameraCandidate?
        public var authorization: @Sendable () async -> USBAuthorizationState
        public var openSession: @Sendable () async -> Result<Void, Error>
        public var deviceInfo: @Sendable () async -> Result<PTPDeviceInfo, Error>
        public var battery: @Sendable () async -> Int?
        public var powerSource: @Sendable () async -> String?   // "USB-C PD 15 W" when the OS tells us

        public init(deviceOnBus: @escaping @Sendable () async -> USBCameraCandidate?,
                    authorization: @escaping @Sendable () async -> USBAuthorizationState,
                    openSession: @escaping @Sendable () async -> Result<Void, Error>,
                    deviceInfo: @escaping @Sendable () async -> Result<PTPDeviceInfo, Error>,
                    battery: @escaping @Sendable () async -> Int?,
                    powerSource: @escaping @Sendable () async -> String?) {
            self.deviceOnBus = deviceOnBus
            self.authorization = authorization
            self.openSession = openSession
            self.deviceInfo = deviceInfo
            self.battery = battery
            self.powerSource = powerSource
        }
    }

    public static func checks(_ p: Probes) -> [DiagnosticCheck] {
        [
            DiagnosticCheck(id: "bus", title: "Camera on the cable",
                            tip: "If your camera doesn't appear, try disconnecting and reconnecting the USB-C cable. Use a data-capable cable (not charge-only). Some cameras need their USB mode set to PC Remote / PTP before they appear. Try the camera's other port if it has two, and skip hubs.") {
                if let d = await p.deviceOnBus() { return .pass("\(d.name) (\(d.vendorGuess.displayName), USB \(USBIDs.hex(d.usbVendorID)):\(USBIDs.hex(d.usbProductID)))") }
                return .fail("No camera is visible on USB. Try disconnecting and reconnecting the USB-C cable, then check the cable, the camera's USB connection mode, and that the camera is on.")
            },
            DiagnosticCheck(id: "auth", title: "Permissions",
                            tip: "Tether needs both Camera Control and Contents access to send PTP commands (Settings → Privacy & Security).") {
                let a = await p.authorization()
                return a.canSendPTP ? .pass(a.summary) : .fail(a.summary)
            },
            DiagnosticCheck(id: "session", title: "Open a session",
                            tip: "If another app (Photos, Files, the camera maker's app) has the camera open, close it. Sony bodies allow only one PC Remote session at a time.") {
                switch await p.openSession() {
                case .success: return .pass("Session open")
                case .failure(let e): return .fail("\(e)")
                }
            },
            DiagnosticCheck(id: "ptp", title: "Talk PTP",
                            tip: "GetDeviceInfo is the first PTP command. If it fails the camera is in MTP/mass-storage mode or needs its remote/tether mode enabled.") {
                switch await p.deviceInfo() {
                case .success(let info):
                    let v = CameraVendor.detect(info)
                    let note = v.supportsWiredControl ? "" : " (import only)"
                    return .pass("\(info.manufacturer) \(info.model), firmware \(info.deviceVersion), \(info.operationsSupported.count) operations\(note)")
                case .failure(let e): return .fail("\(e)")
                }
            },
            DiagnosticCheck(id: "power", title: "Power",
                            tip: "Long sessions drain both batteries. A USB-C PD hub that powers the iPhone and the camera at once avoids mid-shoot shutdowns.") {
                let b = await p.battery()
                let src = await p.powerSource()
                switch (b, src) {
                case (let b?, let s?): return b < 20 ? .warn("Camera battery \(b)%, \(s)") : .pass("Camera battery \(b)%, \(s)")
                case (let b?, nil): return b < 20 ? .warn("Camera battery low (\(b)%)") : .pass("Camera battery \(b)%")
                case (nil, let s?): return .pass(s)
                default: return .warn("Battery level not reported by this camera")
                }
            },
        ]
    }
}

/// The wireless checklist.
public enum WirelessDiagnostics {
    public struct Probes: Sendable {
        public var ssid: @Sendable () async -> String?
        public var localAddresses: @Sendable () async -> [String]
        public var reachable: @Sendable (String, UInt16) async -> Bool
        public var host: String
        public var port: UInt16

        public init(ssid: @escaping @Sendable () async -> String?, localAddresses: @escaping @Sendable () async -> [String],
                    reachable: @escaping @Sendable (String, UInt16) async -> Bool, host: String, port: UInt16) {
            self.ssid = ssid
            self.localAddresses = localAddresses
            self.reachable = reachable
            self.host = host
            self.port = port
        }
    }

    public static func checks(_ p: Probes) -> [DiagnosticCheck] {
        [
            DiagnosticCheck(id: "wifi", title: "On the camera's Wi-Fi",
                            tip: "Join the camera's own network in Settings → Wi-Fi first. Tether never joins it for you.") {
                guard let s = await p.ssid() else { return .warn("Network name unavailable (Location permission needed to read it)") }
                if let v = CameraWiFiHintsBridge.vendor(s) { return .pass("\(s) looks like a \(v.displayName) camera network") }
                return .warn("Connected to \(s). If that is not the camera, join the camera's network.")
            },
            DiagnosticCheck(id: "ip", title: "Address on that network", tip: "The phone needs an address from the camera (usually 192.168.x.x).") {
                let a = await p.localAddresses().filter { !$0.hasPrefix("169.254.") && !$0.hasPrefix("127.") }
                return a.isEmpty ? .fail("No usable IPv4 address yet; wait a moment or rejoin the network.") : .pass(a.joined(separator: ", "))
            },
            DiagnosticCheck(id: "tcp", title: "Camera answers", tip: "PTP/IP listens on TCP 15740; Ricoh on HTTP port 80. The camera must be in its remote/PC-connection mode.") {
                await p.reachable(p.host, p.port) ? .pass("\(p.host):\(p.port) is open") : .fail("\(p.host):\(p.port) did not answer")
            },
        ]
    }
}

/// Indirection so Diagnostics does not depend on the Discovery module's
/// concrete type until it exists; Discovery registers the real mapper.
public enum CameraWiFiHintsBridge {
    nonisolated(unsafe) public static var vendor: @Sendable (String) -> CameraVendor? = { ssid in
        let s = ssid.lowercased()
        if s.hasPrefix("eos") || s.contains("canon") { return .canon }
        if s.contains("nikon") { return .nikon }
        if s.hasPrefix("direct-") || s.contains("ilce") || s.contains("dsc-") { return .sony }
        if s.contains("fujifilm") { return .fujifilm }
        if s.hasPrefix("gr_") || s.contains("ricoh") || s.contains("theta") { return .ricoh }
        return nil
    }
}
