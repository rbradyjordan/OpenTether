import Foundation

/// Little-endian byte reader/writer for PTP, PTP/IP and vendor payloads.
///
/// PTP wire format is little-endian throughout. Strings are a UInt8 count of
/// UTF-16 code units *including* the terminating NUL, followed by UTF-16LE
/// code units; an empty string is the single byte 0x00. Arrays are a UInt32
/// element count followed by the elements.
public struct ByteBuffer: Equatable, Sendable {
    public private(set) var bytes: [UInt8]
    public var position: Int = 0

    public init(_ bytes: [UInt8] = []) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public var count: Int { bytes.count }
    public var remaining: Int { max(0, bytes.count - position) }
    public var isAtEnd: Bool { position >= bytes.count }
    public var data: Data { Data(bytes) }

    public mutating func rewind() { position = 0 }

    // MARK: Reading

    public enum ReadError: Error, Equatable {
        case outOfBounds(needed: Int, remaining: Int)
        case invalidString
    }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, position + n <= bytes.count else {
            throw ReadError.outOfBounds(needed: n, remaining: remaining)
        }
        defer { position += n }
        return bytes[position ..< position + n]
    }

    public mutating func readUInt8() throws -> UInt8 { try take(1).first! }
    public mutating func readInt8() throws -> Int8 { Int8(bitPattern: try readUInt8()) }

    public mutating func readUInt16() throws -> UInt16 {
        let s = try take(2)
        return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }
    public mutating func readInt16() throws -> Int16 { Int16(bitPattern: try readUInt16()) }

    public mutating func readUInt32() throws -> UInt32 {
        let s = try take(4)
        var v: UInt32 = 0
        for i in 0 ..< 4 { v |= UInt32(s[s.startIndex + i]) << (8 * UInt32(i)) }
        return v
    }
    public mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }

    public mutating func readUInt64() throws -> UInt64 {
        let s = try take(8)
        var v: UInt64 = 0
        for i in 0 ..< 8 { v |= UInt64(s[s.startIndex + i]) << (8 * UInt64(i)) }
        return v
    }
    public mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readUInt64()) }

    /// 128-bit values are carried as (low, high) 64-bit halves.
    public mutating func readUInt128() throws -> (low: UInt64, high: UInt64) {
        let low = try readUInt64()
        let high = try readUInt64()
        return (low, high)
    }

    public mutating func readBytes(_ n: Int) throws -> [UInt8] { Array(try take(n)) }
    public mutating func readData(_ n: Int) throws -> Data { Data(try take(n)) }
    public mutating func readRemaining() -> [UInt8] {
        defer { position = bytes.count }
        return Array(bytes[position...])
    }

    public mutating func skip(_ n: Int) throws { _ = try take(n) }

    /// PTP string: UInt8 count of UTF-16 units including NUL, then UTF-16LE.
    public mutating func readPTPString() throws -> String {
        let units = Int(try readUInt8())
        if units == 0 { return "" }
        var code = [UInt16]()
        code.reserveCapacity(units)
        for _ in 0 ..< units { code.append(try readUInt16()) }
        if code.last == 0 { code.removeLast() }
        // Some firmware omits the terminator or pads; tolerate both.
        if let nul = code.firstIndex(of: 0) { code = Array(code[..<nul]) }
        return String(decoding: code, as: UTF16.self)
    }

    /// A NUL-terminated UTF-16LE string with no length prefix (PTP/IP init packets).
    public mutating func readUTF16LEZ() throws -> String {
        var code = [UInt16]()
        while true {
            let u = try readUInt16()
            if u == 0 { break }
            code.append(u)
        }
        return String(decoding: code, as: UTF16.self)
    }

    public mutating func readArray<T>(_ element: (inout ByteBuffer) throws -> T) throws -> [T] {
        let n = Int(try readUInt32())
        var out = [T]()
        out.reserveCapacity(min(n, 1 << 16))
        for _ in 0 ..< n { out.append(try element(&self)) }
        return out
    }
    public mutating func readUInt16Array() throws -> [UInt16] { try readArray { try $0.readUInt16() } }
    public mutating func readUInt32Array() throws -> [UInt32] { try readArray { try $0.readUInt32() } }

    // MARK: Writing

    public mutating func write(_ v: UInt8) { bytes.append(v) }
    public mutating func write(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    public mutating func write(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    public mutating func write(_ v: Int16) { write(UInt16(bitPattern: v)) }
    public mutating func write(_ v: UInt32) { for i in 0 ..< 4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    public mutating func write(_ v: Int32) { write(UInt32(bitPattern: v)) }
    public mutating func write(_ v: UInt64) { for i in 0 ..< 8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    public mutating func write(_ v: Int64) { write(UInt64(bitPattern: v)) }
    public mutating func write(_ v: [UInt8]) { bytes.append(contentsOf: v) }
    public mutating func write(_ v: Data) { bytes.append(contentsOf: v) }
    public mutating func write(_ v: ArraySlice<UInt8>) { bytes.append(contentsOf: v) }

    public mutating func writePTPString(_ s: String) {
        if s.isEmpty { write(UInt8(0)); return }
        let units = Array(s.utf16.prefix(254))
        write(UInt8(units.count + 1))
        for u in units { write(u) }
        write(UInt16(0))
    }

    public mutating func writeUTF16LEZ(_ s: String) {
        for u in s.utf16 { write(u) }
        write(UInt16(0))
    }

    public mutating func writeArray<T>(_ items: [T], _ element: (inout ByteBuffer, T) -> Void) {
        write(UInt32(items.count))
        for i in items { element(&self, i) }
    }
    public mutating func write(uint16Array a: [UInt16]) { writeArray(a) { $0.write($1) } }
    public mutating func write(uint32Array a: [UInt32]) { writeArray(a) { $0.write($1) } }

    /// Overwrite a UInt32 at an absolute offset (used to back-patch lengths).
    public mutating func patch(uint32 v: UInt32, at offset: Int) {
        precondition(offset + 4 <= bytes.count)
        for i in 0 ..< 4 { bytes[offset + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }
}

public extension ByteBuffer {
    /// Hex dump for logs: `01 02 0a ff`.
    var hexString: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

public extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
