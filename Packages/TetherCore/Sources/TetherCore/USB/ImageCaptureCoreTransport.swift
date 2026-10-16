import Foundation

#if canImport(ImageCaptureCore)
import ImageCaptureCore

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
    private let continuation: AsyncStream<Event>.Continuation
    public let events: AsyncStream<Event>
    public private(set) var authorization = USBAuthorizationState()
    public var vendorFilter: Set<CameraVendor>? = nil

    public override init() {
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { c = $0 }
        continuation = c
        super.init()
        browser.delegate = self
        #if os(macOS)
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        #else
        browser.browsedDeviceTypeMask = .camera
        #endif
    }

    public func start() {
        Task { await requestAuthorizations() }
        browser.start()
    }

    public func stop() { browser.stop() }

    /// Request control + contents authorization. On iOS < 18.3 only the
    /// contents authorization exists, so control is `notRequired`.
    @discardableResult
    public func requestAuthorizations() async -> USBAuthorizationState {
        var state = USBAuthorizationState()
        #if os(iOS)
        if #available(iOS 18.3, *) {
            state.control = await withCheckedContinuation { cont in
                browser.requestControlAuthorization { status in cont.resume(returning: Self.grant(status)) }
            }
        } else {
            state.control = .notRequired
        }
        if #available(iOS 14.0, *) {
            state.contents = await withCheckedContinuation { cont in
                browser.requestContentsAuthorization { status in cont.resume(returning: Self.grant(status)) }
            }
        } else {
            state.contents = .notRequired
        }
        #else
        state = USBAuthorizationState(control: .notRequired, contents: .notRequired)
        #endif
        lock.lock(); authorization = state; lock.unlock()
        continuation.yield(.authorization(state))
        return state
    }

    #if os(iOS)
    private static func grant(_ status: ICAuthorizationStatus) -> USBAuthorizationState.Grant {
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
        lock.unlock()
        continuation.yield(.devices(list.sorted { $0.name < $1.name }))
    }

    // MARK: ICDeviceBrowserDelegate

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        lock.lock(); devices[cam.uuidString ?? cam.name ?? UUID().uuidString] = cam; lock.unlock()
        if !moreComing { publish() }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
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
        if let error { health.lastError = error.localizedDescription }
    }
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
}
#endif

/// Hex strings for the USB IDs the setup guides show.
public enum USBIDs {
    public static func hex(_ v: Int) -> String { String(format: "0x%04X", v) }
}
