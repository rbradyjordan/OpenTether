import Foundation

/// A PTP operation request: up to five UInt32 parameters plus an optional
/// host-to-camera data phase.
public struct PTPRequest: Equatable, Sendable {
    public var code: PTPOperationCode
    public var parameters: [UInt32]
    public var dataOut: Data?
    public var expectsLargeData: Bool
    public var timeout: TimeInterval

    public init(_ code: PTPOperationCode, parameters: [UInt32] = [], dataOut: Data? = nil,
                expectsLargeData: Bool = false, timeout: TimeInterval = 10) {
        precondition(parameters.count <= 5)
        self.code = code
        self.parameters = parameters
        self.dataOut = dataOut
        self.expectsLargeData = expectsLargeData
        self.timeout = timeout
    }
}

public struct PTPResponse: Equatable, Sendable {
    public var code: PTPResponseCode
    public var parameters: [UInt32]
    public var dataIn: Data
    public var transactionID: UInt32

    public init(code: PTPResponseCode, parameters: [UInt32] = [], dataIn: Data = Data(), transactionID: UInt32 = 0) {
        self.code = code
        self.parameters = parameters
        self.dataIn = dataIn
        self.transactionID = transactionID
    }

    public var isOK: Bool { code.isOK }

    @discardableResult
    public func checked(_ op: PTPOperationCode) throws -> PTPResponse {
        guard isOK else { throw PTPError.response(op: op, code: code, parameters: parameters) }
        return self
    }
}

public struct PTPEvent: Equatable, Sendable, CustomStringConvertible {
    public var code: PTPEventCode
    public var parameters: [UInt32]
    public var transactionID: UInt32
    public var receivedAt: Date

    public init(code: PTPEventCode, parameters: [UInt32] = [], transactionID: UInt32 = 0, receivedAt: Date = Date()) {
        self.code = code
        self.parameters = parameters
        self.transactionID = transactionID
        self.receivedAt = receivedAt
    }

    public var description: String {
        "\(code)(\(parameters.map { String(format: "0x%08x", $0) }.joined(separator: ", ")))"
    }
}

public enum PTPError: Error, Equatable, CustomStringConvertible {
    case response(op: PTPOperationCode, code: PTPResponseCode, parameters: [UInt32])
    case transportClosed
    case timeout(op: PTPOperationCode)
    case malformed(String)
    case unsupportedDataType(PTPDataType)
    case sessionNotOpen
    case notConnected
    case vendorGate(String)
    case unsupported(String)
    case cancelled

    public var description: String {
        switch self {
        case .response(let op, let code, let params):
            return "\(op) failed: \(code)" + (params.isEmpty ? "" : " \(params)")
        case .transportClosed: return "The camera connection closed."
        case .timeout(let op): return "\(op) timed out."
        case .malformed(let s): return "Malformed PTP data: \(s)"
        case .unsupportedDataType(let t): return "Unsupported PTP data type \(t)"
        case .sessionNotOpen: return "No PTP session is open."
        case .notConnected: return "Not connected to a camera."
        case .vendorGate(let s): return s
        case .unsupported(let s): return s
        case .cancelled: return "Cancelled."
        }
    }

    public var responseCode: PTPResponseCode? {
        if case .response(_, let code, _) = self { return code }
        return nil
    }
}
