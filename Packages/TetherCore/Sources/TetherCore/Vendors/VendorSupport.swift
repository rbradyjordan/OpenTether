import Foundation

/// Finds new objects by diffing `GetObjectHandles` against the previous
/// poll. The fallback event source for every vendor whose own event stream
/// is unknown or unreliable (Fujifilm, Olympus, Panasonic, Leica), and a
/// safety net for the others.
///
/// The first call seeds the known set and reports nothing, so objects that
/// were already on the card when we connected are not announced.
public final class ObjectHandleDiffer: @unchecked Sendable {
    private let lock = NSLock()
    private var known: Set<UInt32>?
    public let storage: UInt32

    public init(storage: UInt32 = 0xFFFF_FFFF) { self.storage = storage }

    /// Handles present in `current` that were not seen before (ordered as given).
    public func diff(_ current: [UInt32]) -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        guard let seen = known else {
            known = Set(current)
            return []
        }
        let fresh = current.filter { !seen.contains($0) }
        known = Set(current)
        return fresh
    }

    public func reset() {
        lock.lock(); known = nil; lock.unlock()
    }

    public var isSeeded: Bool {
        lock.lock(); defer { lock.unlock() }
        return known != nil
    }

    /// Seed from the camera without reporting anything.
    public func seed(engine: PTPEngine) async {
        if let handles = try? await engine.getObjectHandles(storage: storage) { _ = diff(handles) }
    }

    /// One poll: list handles, diff, emit `objectAdded` for the new ones.
    public func poll(engine: PTPEngine) async throws -> [CameraEvent] {
        let handles = try await engine.getObjectHandles(storage: storage)
        return diff(handles).map { .objectAdded(NewObject(handle: $0)) }
    }
}

/// Shared helpers for handlers that use the standard PTP property codes with
/// a vendor-specific override for codes or display strings.
enum VendorProps {
    /// Reads DevicePropDesc for each property that `code` maps and the body
    /// advertises; formats with `format`.
    static func readStandard(engine: PTPEngine, info: PTPDeviceInfo, _ properties: [TetherProperty],
                             code: (TetherProperty) -> PTPDevicePropCode?,
                             format: @escaping (TetherProperty, PTPValue) -> String) async throws -> [PropertyDescriptor] {
        var out = [PropertyDescriptor]()
        for p in properties {
            guard let c = code(p), info.supports(c) else { continue }
            let desc = try await engine.getDevicePropDesc(c)
            out.append(GenericPTPHandler.descriptor(p, desc, format: format))
        }
        return out
    }

    /// Descriptor for a capture destination the handler tracks itself (the
    /// body has no property for it). Raw values: 0 card, 1 host, 2 both.
    static func destinationDescriptor(current: CaptureDestination, allowed: [CaptureDestination], writable: Bool) -> PropertyDescriptor {
        let choices = allowed.map { PropertyChoice(raw: destinationRaw($0), display: $0.displayName) }
        return PropertyDescriptor(property: .captureDestination, raw: destinationRaw(current), display: current.displayName,
                                  isWritable: writable, form: .choices(choices))
    }

    static func destinationRaw(_ d: CaptureDestination) -> PTPValue {
        switch d {
        case .card: return .uint8(0)
        case .host: return .uint8(1)
        case .both: return .uint8(2)
        }
    }

    static func destination(fromRaw v: PTPValue) -> CaptureDestination? {
        switch v.intValue {
        case 0: return .card
        case 1: return .host
        case 2: return .both
        default: return nil
        }
    }

    /// Choices for a plain lookup table (code → label), sorted by code.
    static func choices<K: BinaryInteger>(_ table: [K: String], make: (K) -> PTPValue) -> [PropertyChoice] {
        table.keys.sorted().map { PropertyChoice(raw: make($0), display: table[$0]!) }
    }
}

extension PTPDeviceInfo {
    func supportsOp(_ raw: UInt16) -> Bool { operationsSupported.contains(PTPOperationCode(raw)) }
    func supportsProp(_ raw: UInt16) -> Bool { devicePropertiesSupported.contains(PTPDevicePropCode(raw)) }
}

extension PTPEngine {
    /// Vendor GetDevicePropValue for a code the standard table does not know.
    func getRawPropValue(_ code: UInt16) async throws -> Data {
        try await run(.getDevicePropValue, [UInt32(code)]).dataIn
    }
}
