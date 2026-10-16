import Foundation
@testable import TetherCore

/// A fake camera for unit tests: answers each operation code from a script
/// (closure or canned response) and lets tests push events.
final class ScriptedTransport: PTPTransport, @unchecked Sendable {
    typealias Script = @Sendable (PTPRequest) -> PTPResponse

    let kind: TransportKind
    private(set) var isOpen = false
    private let lock = NSLock()
    private var handlers: [PTPOperationCode: Script] = [:]
    private var fallback: Script
    private(set) var requests: [PTPRequest] = []
    let events: AsyncStream<PTPEvent>
    private let eventContinuation: AsyncStream<PTPEvent>.Continuation
    var openError: Error?

    init(kind: TransportKind = .usb, deviceInfo: PTPDeviceInfo = ScriptedTransport.genericInfo) {
        self.kind = kind
        var c: AsyncStream<PTPEvent>.Continuation!
        events = AsyncStream { c = $0 }
        eventContinuation = c
        fallback = { _ in PTPResponse(code: .operationNotSupported) }
        on(.getDeviceInfo) { _ in PTPResponse(code: .ok, dataIn: deviceInfo.encoded) }
        on(.openSession) { _ in PTPResponse(code: .ok) }
        on(.closeSession) { _ in PTPResponse(code: .ok) }
    }

    static let genericInfo = PTPDeviceInfo(
        vendorExtensionID: 6,
        operationsSupported: [.getDeviceInfo, .openSession, .closeSession, .getStorageIDs, .getStorageInfo,
                              .getObjectHandles, .getObjectInfo, .getObject, .getPartialObject, .getThumb,
                              .getDevicePropDesc, .getDevicePropValue, .setDevicePropValue, .initiateCapture],
        eventsSupported: [.objectAdded, .devicePropChanged, .captureComplete],
        devicePropertiesSupported: [.fNumber, .exposureTime, .exposureIndex, .whiteBalance, .batteryLevel],
        captureFormats: [.exifJPEG], imageFormats: [.exifJPEG],
        manufacturer: "Generic Camera Co.", model: "PTP-1", deviceVersion: "1.0", serialNumber: "SN0001")

    func on(_ code: PTPOperationCode, _ script: @escaping Script) {
        lock.lock(); handlers[code] = script; lock.unlock()
    }

    func onAny(_ script: @escaping Script) {
        lock.lock(); fallback = script; lock.unlock()
    }

    func push(_ event: PTPEvent) { eventContinuation.yield(event) }

    func open() async throws {
        if let e = openError { throw e }
        isOpen = true
    }

    func close() async { isOpen = false }

    func execute(_ request: PTPRequest) async throws -> PTPResponse {
        guard isOpen else { throw PTPError.notConnected }
        lock.lock()
        requests.append(request)
        let h = handlers[request.code] ?? fallback
        lock.unlock()
        var r = h(request)
        r.transactionID = UInt32(requests.count)
        return r
    }

    func requests(for code: PTPOperationCode) -> [PTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.code == code }
    }
}

/// Small helpers for building canned payloads.
extension PTPResponse {
    static func ok(_ data: Data = Data(), params: [UInt32] = []) -> PTPResponse { PTPResponse(code: .ok, parameters: params, dataIn: data) }
    static func fail(_ code: PTPResponseCode) -> PTPResponse { PTPResponse(code: code) }
}

extension Data {
    static func fakeJPEG(size: Int = 64) -> Data {
        var d = Data([0xFF, 0xD8, 0xFF, 0xE0])
        d.append(Data(repeating: 0x11, count: Swift.max(0, size - 6)))
        d.append(Data([0xFF, 0xD9]))
        return d
    }
}
