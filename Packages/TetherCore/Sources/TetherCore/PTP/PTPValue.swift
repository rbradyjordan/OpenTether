import Foundation

/// A typed PTP value as carried in DevicePropDesc / DevicePropValue payloads.
public enum PTPValue: Equatable, Hashable, Sendable, CustomStringConvertible {
    case int8(Int8), uint8(UInt8)
    case int16(Int16), uint16(UInt16)
    case int32(Int32), uint32(UInt32)
    case int64(Int64), uint64(UInt64)
    case int128(low: UInt64, high: UInt64), uint128(low: UInt64, high: UInt64)
    case array([PTPValue])
    case string(String)
    case undefined

    public var dataType: PTPDataType {
        switch self {
        case .int8: return .int8
        case .uint8: return .uint8
        case .int16: return .int16
        case .uint16: return .uint16
        case .int32: return .int32
        case .uint32: return .uint32
        case .int64: return .int64
        case .uint64: return .uint64
        case .int128: return .int128
        case .uint128: return .uint128
        case .string: return .string
        case .undefined: return .undef
        case .array(let a):
            guard let first = a.first else { return .auint8 }
            return PTPDataType(first.dataType.rawValue | 0x4000)
        }
    }

    /// Integer view for numeric scalars (sign preserved); nil for strings/arrays.
    public var intValue: Int64? {
        switch self {
        case .int8(let v): return Int64(v)
        case .uint8(let v): return Int64(v)
        case .int16(let v): return Int64(v)
        case .uint16(let v): return Int64(v)
        case .int32(let v): return Int64(v)
        case .uint32(let v): return Int64(v)
        case .int64(let v): return v
        case .uint64(let v): return v > UInt64(Int64.max) ? nil : Int64(v)
        default: return nil
        }
    }

    public var uintValue: UInt64? {
        switch self {
        case .int8(let v): return v < 0 ? nil : UInt64(v)
        case .uint8(let v): return UInt64(v)
        case .int16(let v): return v < 0 ? nil : UInt64(v)
        case .uint16(let v): return UInt64(v)
        case .int32(let v): return v < 0 ? nil : UInt64(v)
        case .uint32(let v): return UInt64(v)
        case .int64(let v): return v < 0 ? nil : UInt64(v)
        case .uint64(let v): return v
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var description: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[\(a.map(\.description).joined(separator: ", "))]"
        case .int128(let l, let h), .uint128(let l, let h): return String(format: "0x%016llx%016llx", h, l)
        case .undefined: return "undef"
        default: return intValue.map(String.init) ?? uintValue.map(String.init) ?? "?"
        }
    }

    // MARK: Wire coding

    public static func read(_ type: PTPDataType, from buf: inout ByteBuffer) throws -> PTPValue {
        if type.isArray {
            let n = Int(try buf.readUInt32())
            var items = [PTPValue]()
            items.reserveCapacity(min(n, 1 << 16))
            for _ in 0 ..< n { items.append(try read(type.scalar, from: &buf)) }
            return .array(items)
        }
        switch type {
        case .int8: return .int8(try buf.readInt8())
        case .uint8: return .uint8(try buf.readUInt8())
        case .int16: return .int16(try buf.readInt16())
        case .uint16: return .uint16(try buf.readUInt16())
        case .int32: return .int32(try buf.readInt32())
        case .uint32: return .uint32(try buf.readUInt32())
        case .int64: return .int64(try buf.readInt64())
        case .uint64: return .uint64(try buf.readUInt64())
        case .int128: let v = try buf.readUInt128(); return .int128(low: v.low, high: v.high)
        case .uint128: let v = try buf.readUInt128(); return .uint128(low: v.low, high: v.high)
        case .string: return .string(try buf.readPTPString())
        default: throw PTPError.unsupportedDataType(type)
        }
    }

    public func write(to buf: inout ByteBuffer) {
        switch self {
        case .int8(let v): buf.write(v)
        case .uint8(let v): buf.write(v)
        case .int16(let v): buf.write(v)
        case .uint16(let v): buf.write(v)
        case .int32(let v): buf.write(v)
        case .uint32(let v): buf.write(v)
        case .int64(let v): buf.write(v)
        case .uint64(let v): buf.write(v)
        case .int128(let l, let h), .uint128(let l, let h): buf.write(l); buf.write(h)
        case .string(let s): buf.writePTPString(s)
        case .array(let a): buf.write(UInt32(a.count)); a.forEach { $0.write(to: &buf) }
        case .undefined: break
        }
    }

    public var encoded: Data {
        var b = ByteBuffer()
        write(to: &b)
        return b.data
    }

    /// Build a value of `type` from an integer (used when setting properties).
    public static func make(_ type: PTPDataType, _ v: Int64) -> PTPValue {
        switch type {
        case .int8: return .int8(Int8(truncatingIfNeeded: v))
        case .uint8: return .uint8(UInt8(truncatingIfNeeded: v))
        case .int16: return .int16(Int16(truncatingIfNeeded: v))
        case .uint16: return .uint16(UInt16(truncatingIfNeeded: v))
        case .int32: return .int32(Int32(truncatingIfNeeded: v))
        case .uint32: return .uint32(UInt32(truncatingIfNeeded: v))
        case .int64: return .int64(v)
        case .uint64: return .uint64(UInt64(bitPattern: v))
        default: return .uint32(UInt32(truncatingIfNeeded: v))
        }
    }
}
