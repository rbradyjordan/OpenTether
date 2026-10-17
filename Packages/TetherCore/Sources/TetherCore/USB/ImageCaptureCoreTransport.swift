import Foundation

#if canImport(ImageCaptureCore)
import ImageCaptureCore
import os

/// Console trail for the USB path (filter Xcode's console on "[USB]").
let usbLog = Logger(subsystem: "com.bradyjordan.tether", category: "usb")

/// The one sanctioned USB door on iOS: ImageCaptureCore. Discovers cameras
/// with `ICDeviceBrowser`, requests BOTH control and contents authorization
/// (version-gated), opens the session and reconnects when the cable comes
/// back. Capture is never done with `requestTakePicture`; everything goes
/// through `requestSendPTPCommand`.
@available(iOS 13.0, macOS 10.15, *)
public final class USBCameraBrowser: NSObject, ICDeviceBrowserDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        case devices([USBCameraCandidate])
        case authorization(USBAuthorizationState)
        case error(String)
    }

    private let browser = ICDeviceBrowser()
    private var devices: [String: ICCameraDevice] = [:]
    private let lock = NSLock()
    /// Every screen that listens (Connect hub, USB-C, the shoot screen's
    /// reconnect, diagnostics) gets every event, and on subscribing the
    /// current camera list and access state, so a screen opened after the
    /// camera was plugged in still sees it.
    private let deviceEvents = ValueBroadcaster<[USBCameraCandidate]>(initial: [])
    private let otherEvents = ValueBroadcaster<Event>()
    public private(set) var authorization = USBAuthorizationState()
    public var vendorFilter: Set<CameraVendor>? = nil

    public override init() {
        super.init()
        browser.delegate = self
        // Type AND location: a mask with only the camera bit matches no
        // location, so iOS reported nothing on the cable.
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
    }

    /// Reads the saved permissions, asks only for what is still undecided,
    /// then browses. On iOS the browser reports cameras only once access is
    /// granted, so it is (re)started after the answers come back.
    public func start() {
        Task { @MainActor in
            let before = self.currentAuthorization()
            usbLog.notice("[USB] start; access before: contents=\(before.contents.rawValue, privacy: .public) control=\(before.control.rawValue, privacy: .public)")
            let after = await self.requestAuthorizations()
            usbLog.notice("[USB] access after: contents=\(after.contents.rawValue, privacy: .public) control=\(after.control.rawValue, privacy: .public)")
            if after.canSendPTP, !before.canSendPTP, self.browser.isBrowsing { self.browser.stop() }
            if !self.browser.isBrowsing {
                self.browser.start()
                usbLog.notice("[USB] browser started (mask 0x\(String(self.browser.browsedDeviceTypeMask.rawValue, radix: 16), privacy: .public)), browsing=\(self.browser.isBrowsing, privacy: .public)")
            }
        }
    }

    public func stop() { browser.stop() }

    /// A new stream for one listener: the current list first, then changes.
    public var events: AsyncStream<Event> {
        let devices = deviceEvents.stream(replayLatest: true)
        let others = otherEvents.stream(replayLatest: true)
        return AsyncStream { cont in
            let a = Task { for await list in devices { cont.yield(.devices(list)) } }
            let b = Task { for await event in others { cont.yield(event) } }
            cont.onTermination = { _ in a.cancel(); b.cancel() }
        }
    }

    /// One line for the USB screen: is the browser running, what does iOS say
    /// about access, and what has it seen on the cable (cameras or not).
    @MainActor
    public var statusLine: String {
        let auth = currentAuthorization()
        let all = browser.devices ?? []
        let cams = all.filter { $0 is ICCameraDevice }.count
        return "Browser \(browser.isBrowsing ? "on" : "off") · contents \(auth.contents.rawValue) · control \(auth.control.rawValue) · \(all.count) device\(all.count == 1 ? "" : "s") (\(cams) camera\(cams == 1 ? "" : "s"))"
    }

    /// What iOS has on record, without prompting.
    @MainActor
    public func currentAuthorization() -> USBAuthorizationState {
        #if os(iOS)
        var state = USBAuthorizationState(control: .notRequired, contents: .notRequired)
        // Availability alone is not enough: the simulator does not implement these.
        if browser.responds(to: Selector(("contentsAuthorizationStatus"))) { state.contents = Self.grant(browser.contentsAuthorizationStatus) }
        if browser.responds(to: Selector(("controlAuthorizationStatus"))) { state.control = Self.grant(browser.controlAuthorizationStatus) }
        return state
        #else
        return USBAuthorizationState(control: .notRequired, contents: .notRequired)
        #endif
    }

    /// Ask for contents and control access where iOS has no answer yet, on the
    /// main thread (ImageCaptureCore expects it). Already-decided permissions
    /// are reported as they are; a denied one can only be changed in Settings.
    @MainActor @discardableResult
    public func requestAuthorizations() async -> USBAuthorizationState {
        var state = currentAuthorization()
        #if os(iOS)
        if state.contents == .notDetermined, browser.responds(to: Selector(("requestContentsAuthorizationWithCompletion:"))) {
            state.contents = await Self.ask { done in self.browser.requestContentsAuthorization { done($0) } }
                ?? currentAuthorization().contents
        }
        if state.control == .notDetermined, browser.responds(to: Selector(("requestControlAuthorizationWithCompletion:"))) {
            state.control = await Self.ask { done in self.browser.requestControlAuthorization { done($0) } }
                ?? currentAuthorization().control
        }
        #endif
        lock.lock(); authorization = state; lock.unlock()
        otherEvents.send(.authorization(state))
        return state
    }

    #if os(iOS)
    /// One permission prompt; nil if iOS never calls back (then the caller
    /// re-reads the status instead of waiting forever).
    @MainActor
    private static func ask(_ request: @escaping (@escaping @Sendable (ICAuthorizationStatus) -> Void) -> Void) async -> USBAuthorizationState.Grant? {
        await withCheckedContinuation { (cont: CheckedContinuation<USBAuthorizationState.Grant?, Never>) in
            let once = ResumeOnce(cont)
            request { status in once.resume(grant(status)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { once.resume(nil) }
        }
    }
    #endif

    #if os(iOS)
    static func grant(_ status: ICAuthorizationStatus) -> USBAuthorizationState.Grant {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }
    #endif

    public func device(id: String) -> ICCameraDevice? {
        lock.lock(); defer { lock.unlock() }
        return devices[id]
    }

    /// ICC exposes the serial number on macOS only; iOS reconnects match on the other fields.
    private static func serialNumber(of device: ICCameraDevice) -> String? {
        #if os(macOS)
        return device.serialNumberString
        #else
        return nil
        #endif
    }

    private func publish() {
        lock.lock()
        let list = devices.values.map { d in
            USBCameraCandidate(id: d.uuidString ?? d.name ?? UUID().uuidString, name: d.name ?? "Camera",
                               usbVendorID: Int(d.usbVendorID), usbProductID: Int(d.usbProductID),
                               serialNumber: Self.serialNumber(of: d), hasOpenSession: d.hasOpenSession)
        }.filter { vendorFilter == nil || vendorFilter!.contains($0.vendorGuess) || $0.vendorGuess == .generic }
        let total = devices.count
        lock.unlock()
        usbLog.notice("[USB] cameras: \(total, privacy: .public) seen, \(list.count, privacy: .public) listed")
        deviceEvents.send(list.sorted { $0.name < $1.name })
    }

    // MARK: ICDeviceBrowserDelegate

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        usbLog.notice("[USB] didAdd \(device.name ?? "?", privacy: .public) type=\(String(describing: type(of: device)), privacy: .public) transport=\(device.transportType ?? "?", privacy: .public) usb=\(String(format: "%04X:%04X", device.usbVendorID, device.usbProductID), privacy: .public) moreComing=\(moreComing, privacy: .public)")
        guard let cam = device as? ICCameraDevice else { return }
        lock.lock(); devices[cam.uuidString ?? cam.name ?? UUID().uuidString] = cam; lock.unlock()
        if !moreComing { publish() }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        usbLog.notice("[USB] didRemove \(device.name ?? "?", privacy: .public)")
        lock.lock(); devices = devices.filter { $0.value !== device }; lock.unlock()
        if !moreGoing { publish() }
    }

    #if os(macOS)
    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) { publish() }
    #endif
}

/// `PTPTransport` over an open `ICCameraDevice`. Serialises transactions,
/// frames them as USB containers and forwards `didReceivePTPEvent`.
@available(iOS 13.0, macOS 10.15, *)
public final class ImageCaptureCoreTransport: NSObject, PTPTransport, ICCameraDeviceDelegate, @unchecked Sendable {
    public let kind: TransportKind = .usb
    public let device: ICCameraDevice
    private let serial = AsyncSerialQueue()
    private var transactionID: UInt32 = 0
    private var sessionOpen = false
    private var openContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    public private(set) var health = TransportHealth()
    private let eventContinuation: AsyncStream<PTPEvent>.Continuation
    public let events: AsyncStream<PTPEvent>
    /// Called when ICC reports the device went away (cable pulled).
    public var onDisconnect: (@Sendable (String) -> Void)?

    public init(device: ICCameraDevice) {
        self.device = device
        var c: AsyncStream<PTPEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c = $0 }
        eventContinuation = c
        super.init()
        device.delegate = self
    }

    public var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return sessionOpen }

    public func open() async throws {
        if isOpen { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock(); openContinuation = cont; lock.unlock()
            device.requestOpenSession()
        }
    }

    public func close() async {
        lock.lock(); sessionOpen = false; lock.unlock()
        try? await device.requestCloseSession()
    }

    public func execute(_ request: PTPRequest) async throws -> PTPResponse {
        try await serial.run { try await self.executeLocked(request) }
    }

    private func executeLocked(_ request: PTPRequest) async throws -> PTPResponse {
        guard isOpen else { throw PTPError.notConnected }
        transactionID &+= 1
        if transactionID == 0 { transactionID = 1 }
        let tid = transactionID
        let command = PTPUSBContainer.command(request.code, transactionID: tid, parameters: request.parameters).encode()
        let started = Date()
        return try await withThrowingTaskGroup(of: PTPResponse.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PTPResponse, Error>) in
                    device.requestSendPTPCommand(command, outData: request.dataOut) { dataIn, responseData, error in
                        if let error { cont.resume(throwing: PTPError.malformed("ICC: \(error.localizedDescription)")); return }
                        do {
                            let container = try PTPUSBContainer(parsing: responseData)
                            guard var response = container.asResponse else { throw PTPError.malformed("ICC returned a non-response container") }
                            response.dataIn = dataIn
                            response.transactionID = tid
                            self.health.bytesIn += response.dataIn.count
                            self.health.bytesOut += command.count + (request.dataOut?.count ?? 0)
                            self.health.roundTripMillis = Date().timeIntervalSince(started) * 1000
                            cont.resume(returning: response)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(request.timeout * 1_000_000_000))
                throw PTPError.timeout(op: request.code)
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }

    // MARK: ICCameraDeviceDelegate

    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        usbLog.notice("[USB] session open on \(device.name ?? "?", privacy: .public): \(error.map { "\($0)" } ?? "ok", privacy: .public)")
        lock.lock()
        let cont = openContinuation
        openContinuation = nil
        sessionOpen = error == nil
        lock.unlock()
        if let error {
            health.lastError = error.localizedDescription
            cont?.resume(throwing: PTPError.vendorGate(Self.describe(error)))
        } else {
            cont?.resume()
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        // ICReturnConnectionSessionAlreadyOpen, ICLegacyReturnCodeDeviceAlreadyOpenErr
        case -21347, -9914: return "Another app has this camera open. Close it and try again."
        default: return "Could not open the camera over USB: \(ns.localizedDescription)"
        }
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        lock.lock(); sessionOpen = false; lock.unlock()
    }

    public func didRemove(_ device: ICDevice) {
        lock.lock(); sessionOpen = false; lock.unlock()
        health.lastError = "Camera unplugged"
        eventContinuation.yield(PTPEvent(code: .deviceReset))
        onDisconnect?("The camera was unplugged.")
    }

    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        if let container = try? PTPUSBContainer(parsing: eventData), let ev = container.asEvent {
            eventContinuation.yield(ev)
        }
    }

    // Required by the protocol; items are handled through raw PTP instead.
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    public func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {}
    public func device(_ device: ICDevice, didEncounterError error: Error?) {
        usbLog.error("[USB] device error on \(device.name ?? "?", privacy: .public): \(error.map { "\($0)" } ?? "nil", privacy: .public)")
        if let error { health.lastError = error.localizedDescription }
    }
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
}
#endif

/// Resumes a continuation at most once (callback vs. timeout).
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(_ value: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

/// Hex strings for the USB IDs the setup guides show.
public enum USBIDs {
    public static func hex(_ v: Int) -> String { String(format: "0x%04X", v) }
}
