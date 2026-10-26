import Foundation

/// PTP-over-USB "generic container" (PIMA 15740 USB class spec §5): the
/// framing `ICCameraDevice.requestSendPTPCommand` expects for the command and
/// returns for the response, and the framing of `didReceivePTPEvent` data.
///
///     UInt32 length (header included) · UInt16 type · UInt16 code · UInt32 transactionID · payload/params
public struct PTPUSBContainer: Equatable, Sendable {
    public enum ContainerType: UInt16, Sendable { case undefined = 0, command = 1, data = 2, response = 3, event = 4 }

    public var type: ContainerType
    public var code: UInt16
    public var transactionID: UInt32
    public var payload: Data

    public static let headerLength = 12

    public init(type: ContainerType, code: UInt16, transactionID: UInt32, payload: Data = Data()) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    public static func command(_ code: PTPOperationCode, transactionID: UInt32, parameters: [UInt32]) -> PTPUSBContainer {
        var b = ByteBuffer()
        parameters.forEach { b.write($0) }
        return PTPUSBContainer(type: .command, code: code.rawValue, transactionID: transactionID, payload: b.data)
    }

    public func encode() -> Data {
        var b = ByteBuffer()
        b.write(UInt32(Self.headerLength + payload.count))
        b.write(type.rawValue)
        b.write(code)
        b.write(transactionID)
        b.write(payload)
        return b.data
    }

    public init(parsing data: Data) throws {
        guard data.count >= Self.headerLength else { throw PTPError.malformed("USB container shorter than header (\(data.count) bytes)") }
        var b = ByteBuffer(data)
        let length = Int(try b.readUInt32())
        let rawType = try b.readUInt16()
        guard let t = ContainerType(rawValue: rawType) else { throw PTPError.malformed("unknown container type \(rawType)") }
        type = t
        code = try b.readUInt16()
        transactionID = try b.readUInt32()
        let end = min(data.count, max(Self.headerLength, length))
        payload = Data(data[data.startIndex + Self.headerLength ..< data.startIndex + end])
    }

    /// Up to five UInt32 parameters from a response/event payload.
    public var parameters: [UInt32] {
        var b = ByteBuffer(payload)
        var out = [UInt32]()
        while b.remaining >= 4, out.count < 5, let v = try? b.readUInt32() { out.append(v) }
        return out
    }

    public var asResponse: PTPResponse? {
        guard type == .response else { return nil }
        return PTPResponse(code: PTPResponseCode(code), parameters: parameters, transactionID: transactionID)
    }

    public var asEvent: PTPEvent? {
        guard type == .event else { return nil }
        return PTPEvent(code: PTPEventCode(code), parameters: parameters, transactionID: transactionID)
    }
}

/// Which authorizations ImageCaptureCore granted. Both are required to send
/// raw PTP on iOS 18.3+; earlier systems only have the contents one.
public struct USBAuthorizationState: Equatable, Sendable {
    public enum Grant: String, Sendable { case notDetermined, granted, denied, notRequired }
    public var control: Grant
    public var contents: Grant

    public init(control: Grant = .notDetermined, contents: Grant = .notDetermined) {
        self.control = control
        self.contents = contents
    }

    /// Refused before: only Settings can change it now.
    public var isDenied: Bool { control == .denied || contents == .denied }

    public var canSendPTP: Bool { (control == .granted || control == .notRequired) && (contents == .granted || contents == .notRequired) }
    public var summary: String {
        if canSendPTP { return "Camera control and contents access granted" }
        var missing = [String]()
        if control == .denied || control == .notDetermined { missing.append("camera control") }
        if contents == .denied || contents == .notDetermined { missing.append("camera access") }
        if isDenied { return "Turned off: allow \(missing.joined(separator: " and ")) in Settings" }
        return "Needs \(missing.joined(separator: " and "))"
    }
}

/// A camera seen on the USB bus before we open it.
public struct USBCameraCandidate: Identifiable, Hashable, Sendable {
    public var id: String          // ICDevice UUID string
    public var name: String
    public var usbVendorID: Int
    public var usbProductID: Int
    public var serialNumber: String?
    public var vendorGuess: CameraVendor
    public var hasOpenSession: Bool

    public init(id: String, name: String, usbVendorID: Int, usbProductID: Int, serialNumber: String?, hasOpenSession: Bool = false) {
        self.id = id
        self.name = name
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
        self.serialNumber = serialNumber
        self.hasOpenSession = hasOpenSession
        self.vendorGuess = CameraVendor.allCases.first { $0.usbVendorID.map { Int($0) } == usbVendorID } ?? .generic
    }
}
