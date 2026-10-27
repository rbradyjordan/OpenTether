import Foundation

/// PTP/IP (ISO 15740 transport binding) packet family. Every packet starts
/// with a UInt32 total length (header included) and a UInt32 packet type.
///
/// Standard TCP port is 15740. Both the command and the event connection
/// carry this header; data phases ride on the command connection as
/// StartData / Data / EndData keyed by transaction ID.
public enum PTPIPPacketType: UInt32, Sendable {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case cmdRequest = 6
    case cmdResponse = 7
    case event = 8
    case startData = 9
    case data = 10
    case cancelTransaction = 11
    case endData = 12
    case probeRequest = 13
    case probeResponse = 14
}

public enum PTPIPPacket: Equatable, Sendable {
    case initCommandRequest(guid: [UInt8], name: String, protocolVersion: UInt32)
    case initCommandAck(connectionNumber: UInt32, guid: [UInt8], name: String, protocolVersion: UInt32)
    case initEventRequest(connectionNumber: UInt32)
    case initEventAck
    case initFail(reason: UInt32)
    case cmdRequest(dataPhase: UInt32, code: PTPOperationCode, transactionID: UInt32, parameters: [UInt32])
    case cmdResponse(code: PTPResponseCode, transactionID: UInt32, parameters: [UInt32])
    case event(code: PTPEventCode, transactionID: UInt32, parameters: [UInt32])
    case startData(transactionID: UInt32, totalLength: UInt64)
    case data(transactionID: UInt32, payload: Data)
    case cancelTransaction(transactionID: UInt32)
    case endData(transactionID: UInt32, payload: Data)
    case probeRequest
    case probeResponse

    public static let headerLength = 8
    public static let standardPort: UInt16 = 15740
    public static let protocolVersion: UInt32 = 0x0001_0000

    /// Data-phase direction flags carried in CmdRequest.
    public enum DataPhase {
        public static let noDataOrDataIn: UInt32 = 1
        public static let dataOut: UInt32 = 2
    }

    public var type: PTPIPPacketType {
        switch self {
        case .initCommandRequest: return .initCommandRequest
        case .initCommandAck: return .initCommandAck
        case .initEventRequest: return .initEventRequest
        case .initEventAck: return .initEventAck
        case .initFail: return .initFail
        case .cmdRequest: return .cmdRequest
        case .cmdResponse: return .cmdResponse
        case .event: return .event
        case .startData: return .startData
        case .data: return .data
        case .cancelTransaction: return .cancelTransaction
        case .endData: return .endData
        case .probeRequest: return .probeRequest
        case .probeResponse: return .probeResponse
        }
    }

    // MARK: Encoding

    public func encode() -> Data {
        var body = ByteBuffer()
        switch self {
        case .initCommandRequest(let guid, let name, let version):
            body.write(Self.pad16(guid)); body.writeUTF16LEZ(name); body.write(version)
        case .initCommandAck(let conn, let guid, let name, let version):
            body.write(conn); body.write(Self.pad16(guid)); body.writeUTF16LEZ(name); body.write(version)
        case .initEventRequest(let conn):
            body.write(conn)
        case .initEventAck, .probeRequest, .probeResponse:
            break
        case .initFail(let reason):
            body.write(reason)
        case .cmdRequest(let phase, let code, let tid, let params):
            body.write(phase); body.write(code.rawValue); body.write(tid); params.forEach { body.write($0) }
        case .cmdResponse(let code, let tid, let params):
            body.write(code.rawValue); body.write(tid); params.forEach { body.write($0) }
        case .event(let code, let tid, let params):
            body.write(code.rawValue); body.write(tid); params.forEach { body.write($0) }
        case .startData(let tid, let total):
            body.write(tid); body.write(total)
        case .data(let tid, let payload), .endData(let tid, let payload):
            body.write(tid); body.write(payload)
        case .cancelTransaction(let tid):
            body.write(tid)
        }
        var out = ByteBuffer()
        out.write(UInt32(Self.headerLength + body.count))
        out.write(type.rawValue)
        out.write(body.bytes)
        return out.data
    }

    private static func pad16(_ g: [UInt8]) -> [UInt8] {
        if g.count == 16 { return g }
        var out = Array(g.prefix(16))
        while out.count < 16 { out.append(0) }
        return out
    }

    // MARK: Decoding

    public enum DecodeError: Error, Equatable {
        case needMoreBytes(Int)
        case badLength(UInt32)
        case unknownType(UInt32)
        case truncated
    }

    /// Length of the next packet in `data`, or nil when the header isn't there yet.
    public static func frameLength(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var b = ByteBuffer(data.prefix(4))
        guard let len = try? b.readUInt32() else { return nil }
        return Int(len)
    }

    /// Decode one complete packet from the front of `data`; returns the
    /// packet and the number of bytes consumed.
    public static func decode(_ data: Data) throws -> (PTPIPPacket, Int) {
        guard data.count >= headerLength else { throw DecodeError.needMoreBytes(headerLength - data.count) }
        var b = ByteBuffer(data)
        let length = try b.readUInt32()
        guard length >= UInt32(headerLength), length < 1 << 30 else { throw DecodeError.badLength(length) }
        guard data.count >= Int(length) else { throw DecodeError.needMoreBytes(Int(length) - data.count) }
        let rawType = try b.readUInt32()
        guard let type = PTPIPPacketType(rawValue: rawType) else { throw DecodeError.unknownType(rawType) }
        let base = data.startIndex
        var body = ByteBuffer(Array(data[(base + headerLength) ..< (base + Int(length))]))
        let packet: PTPIPPacket
        do {
            switch type {
            case .initCommandRequest:
                let guid = try body.readBytes(16)
                let name = try body.readUTF16LEZ()
                let ver = body.remaining >= 4 ? try body.readUInt32() : protocolVersion
                packet = .initCommandRequest(guid: guid, name: name, protocolVersion: ver)
            case .initCommandAck:
                let conn = try body.readUInt32()
                let guid = try body.readBytes(16)
                let name = (try? body.readUTF16LEZ()) ?? ""
                let ver = body.remaining >= 4 ? try body.readUInt32() : protocolVersion
                packet = .initCommandAck(connectionNumber: conn, guid: guid, name: name, protocolVersion: ver)
            case .initEventRequest:
                packet = .initEventRequest(connectionNumber: try body.readUInt32())
            case .initEventAck:
                packet = .initEventAck
            case .initFail:
                packet = .initFail(reason: body.remaining >= 4 ? try body.readUInt32() : 0)
            case .cmdRequest:
                let phase = try body.readUInt32()
                let code = PTPOperationCode(try body.readUInt16())
                let tid = try body.readUInt32()
                packet = .cmdRequest(dataPhase: phase, code: code, transactionID: tid, parameters: try readParams(&body))
            case .cmdResponse:
                let code = PTPResponseCode(try body.readUInt16())
                let tid = try body.readUInt32()
                packet = .cmdResponse(code: code, transactionID: tid, parameters: try readParams(&body))
            case .event:
                let code = PTPEventCode(try body.readUInt16())
                let tid = try body.readUInt32()
                packet = .event(code: code, transactionID: tid, parameters: try readParams(&body))
            case .startData:
                let tid = try body.readUInt32()
                packet = .startData(transactionID: tid, totalLength: try body.readUInt64())
            case .data:
                let tid = try body.readUInt32()
                packet = .data(transactionID: tid, payload: Data(body.readRemaining()))
            case .endData:
                let tid = try body.readUInt32()
                packet = .endData(transactionID: tid, payload: Data(body.readRemaining()))
            case .cancelTransaction:
                packet = .cancelTransaction(transactionID: try body.readUInt32())
            case .probeRequest:
                packet = .probeRequest
            case .probeResponse:
                packet = .probeResponse
            }
        } catch is ByteBuffer.ReadError {
            throw DecodeError.truncated
        }
        return (packet, Int(length))
    }

    private static func readParams(_ b: inout ByteBuffer) throws -> [UInt32] {
        var params = [UInt32]()
        while b.remaining >= 4, params.count < 5 { params.append(try b.readUInt32()) }
        return params
    }
}

/// Accumulates bytes from a stream and yields complete packets.
public struct PTPIPFramer: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Pops every complete packet currently buffered.
    public mutating func drain() throws -> [PTPIPPacket] {
        var out = [PTPIPPacket]()
        while let len = PTPIPPacket.frameLength(in: buffer), buffer.count >= len, len >= PTPIPPacket.headerLength {
            let (p, consumed) = try PTPIPPacket.decode(buffer)
            buffer = Data(buffer.dropFirst(consumed))
            out.append(p)
        }
        if let len = PTPIPPacket.frameLength(in: buffer), len < PTPIPPacket.headerLength {
            throw PTPIPPacket.DecodeError.badLength(UInt32(len))
        }
        return out
    }

    public var bufferedBytes: Int { buffer.count }
}

/// Stable per-install GUID sent in InitCommandRequest. Cameras pair on it,
/// so it must not change between launches.
public enum PTPIPIdentity {
    /// The name cameras show and save for this phone. Changing it breaks
    /// existing pairings, so it stays fixed.
    public static let clientName = "Open Tether"
    /// The first connection waits for the user to confirm on the camera.
    public static let pairingTimeout: TimeInterval = 60

    public static func guid(from uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }
}
