import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(NetworkExtension)
import NetworkExtension
#endif

public enum SSIDAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized, unavailable
}

/// Reads the current Wi-Fi name. iOS only reveals it with location
/// permission; we never join a camera AP ourselves, we only tell the user
/// which network they are on.
public protocol SSIDProviding: Sendable {
    func currentSSID() async -> String?
    var authorizationState: SSIDAuthorization { get async }
    func requestAuthorization() async
}

/// Camera access-point naming conventions → brand. Used for the "you're on a
/// camera network" banner, not for routing.
public enum CameraWiFiHints {
    public static func looksLikeCameraNetwork(_ ssid: String) -> CameraVendor? {
        let s = ssid.trimmingCharacters(in: .whitespaces)
        let u = s.uppercased()
        if u.hasPrefix("EOS") || u.hasPrefix("CANON") || u.contains("_CANON") { return .canon }
        if u.hasPrefix("NIKON") || u.hasPrefix("Z 5") || u.hasPrefix("Z5_") || u.hasPrefix("Z6_") || u.hasPrefix("Z7_") || u.hasPrefix("D850") { return .nikon }
        if u.hasPrefix("DIRECT-") { return .sony }
        if u.hasPrefix("FUJIFILM") || u.hasPrefix("X-T") || u.hasPrefix("X-H") || u.hasPrefix("GFX") || u.hasPrefix("X-PRO") || u.hasPrefix("X100") { return .fujifilm }
        if u.hasPrefix("GR_") || u.hasPrefix("GR-") || u.hasPrefix("RICOH") || u.hasPrefix("THETA") || u.hasPrefix("PENTAX") { return .ricoh }
        if u.hasPrefix("LEICA") { return .leica }
        if u.hasPrefix("OM-") || u.hasPrefix("OLYMPUS") || u.hasPrefix("E-M") || u.hasPrefix("OMSYSTEM") { return .olympus }
        if u.hasPrefix("LUMIX") || u.hasPrefix("PANASONIC") || u.hasPrefix("DC-") { return .panasonic }
        if u.hasPrefix("HASSELBLAD") { return .hasselblad }
        return nil
    }
}

#if canImport(CoreLocation) && canImport(NetworkExtension) && !os(macOS) && !targetEnvironment(macCatalyst)
/// iOS: when-in-use location permission unlocks `NEHotspotNetwork.fetchCurrent`.
public final class CoreLocationSSIDMonitor: NSObject, SSIDProviding, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public override init() {
        super.init()
        manager.delegate = self
    }

    public var authorizationState: SSIDAuthorization {
        get async {
            switch manager.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            case .authorizedAlways, .authorizedWhenInUse: return .authorized
            @unknown default: return .unavailable
            }
        }
    }

    public func requestAuthorization() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock(); waiters.append(c); lock.unlock()
            manager.requestWhenInUseAuthorization()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        lock.lock(); let ws = waiters; waiters = []; lock.unlock()
        ws.forEach { $0.resume() }
    }

    public func currentSSID() async -> String? {
        guard await authorizationState == .authorized else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            NEHotspotNetwork.fetchCurrent { network in c.resume(returning: network?.ssid) }
        }
    }
}
#else
/// Linux / macOS / Mac Catalyst stub: no SSID access (macOS gives apps the
/// Wi-Fi name only through CoreWLAN plus location, neither of which Catalyst has).
public final class CoreLocationSSIDMonitor: SSIDProviding, @unchecked Sendable {
    public init() {}
    public var authorizationState: SSIDAuthorization { get async { .unavailable } }
    public func requestAuthorization() async {}
    public func currentSSID() async -> String? { nil }
}
#endif

/// Fixed-answer provider for previews and tests.
public struct StaticSSIDProvider: SSIDProviding {
    public var ssid: String?
    public var state: SSIDAuthorization
    public init(ssid: String?, state: SSIDAuthorization = .authorized) { self.ssid = ssid; self.state = state }
    public func currentSSID() async -> String? { state == .authorized ? ssid : nil }
    public var authorizationState: SSIDAuthorization { get async { state } }
    public func requestAuthorization() async {}
}
