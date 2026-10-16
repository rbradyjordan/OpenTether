import Foundation

/// The EXIF fields the inspector shows and the manifest records, read
/// straight from a JPEG's APP1 Exif segment (also works on the TIFF header
/// of most RAW files, since CR2/NEF/ARW/RW2/ORF/DNG start with a TIFF IFD).
/// Pure Swift so it runs in tests and on Linux.
public struct EXIFSummary: Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var lens: String?
    public var dateTimeOriginal: Date?
    public var exposureTime: Double?      // seconds
    public var fNumber: Double?
    public var iso: Int?
    public var focalLength: Double?       // mm
    public var exposureBias: Double?      // EV
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var serialNumber: String?
    public var artist: String?
    public var copyright: String?

    public init() {}

    public var exposureLine: String {
        var parts = [String]()
        if let t = exposureTime { parts.append(PropertyFormat.shutter(seconds: t)) }
        if let f = fNumber { parts.append(PropertyFormat.aperture(hundredths: Int64((f * 100).rounded()))) }
        if let i = iso { parts.append("ISO \(i)") }
        if let b = exposureBias, b != 0 { parts.append(String(format: "%+.1f EV", b)) }
        if let fl = focalLength { parts.append(String(format: "%.0f mm", fl)) }
        return parts.joined(separator: "  ")
    }

    public var cameraLine: String { [make, model].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
}

public enum EXIFReader {
    public enum Error: Swift.Error, Equatable { case noEXIF, malformed(String) }

    /// Find and parse the Exif block in a JPEG, or parse `data` as a bare
    /// TIFF (RAW files) when it starts with a TIFF header.
    public static func read(_ data: Data) throws -> EXIFSummary {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else { throw Error.malformed("too short") }
        if (bytes[0] == 0x49 && bytes[1] == 0x49) || (bytes[0] == 0x4D && bytes[1] == 0x4D) {
            return try parseTIFF(bytes, base: 0)
        }
        guard bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw Error.noEXIF }
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let len = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xE1, i + 10 <= bytes.count, bytes[i + 4] == 0x45, bytes[i + 5] == 0x78, bytes[i + 6] == 0x69, bytes[i + 7] == 0x66 { // "Exif\0\0"
                return try parseTIFF(bytes, base: i + 10)
            }
            i += 2 + len
        }
        throw Error.noEXIF
    }

    private struct Reader {
        let b: [UInt8]; let base: Int; let little: Bool
        func u16(_ o: Int) -> UInt16? {
            guard base + o + 2 <= b.count else { return nil }
            let x = b[base + o], y = b[base + o + 1]
            return little ? UInt16(x) | UInt16(y) << 8 : UInt16(y) | UInt16(x) << 8
        }
        func u32(_ o: Int) -> UInt32? {
            guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
            return little ? UInt32(lo) | UInt32(hi) << 16 : UInt32(hi) | UInt32(lo) << 16
        }
        func string(_ o: Int, _ n: Int) -> String? {
            guard base + o + n <= b.count else { return nil }
            var s = b[(base + o) ..< (base + o + n)]
            while s.last == 0 { s = s.dropLast() }
            return String(decoding: s, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        func rational(_ o: Int, signed: Bool) -> Double? {
            guard let n = u32(o), let d = u32(o + 4), d != 0 else { return nil }
            return signed ? Double(Int32(bitPattern: n)) / Double(Int32(bitPattern: d)) : Double(n) / Double(d)
        }
    }

    private static func parseTIFF(_ bytes: [UInt8], base: Int) throws -> EXIFSummary {
        guard base + 8 <= bytes.count else { throw Error.malformed("tiff header") }
        let little: Bool
        switch (bytes[base], bytes[base + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: throw Error.malformed("byte order")
        }
        let r = Reader(b: bytes, base: base, little: little)
        guard let ifd0 = r.u32(4) else { throw Error.malformed("ifd0") }
        var out = EXIFSummary()
        var exifIFD: Int?
        try walk(r, Int(ifd0), &out, &exifIFD, depth: 0)
        if let e = exifIFD { var none: Int?; try walk(r, e, &out, &none, depth: 1) }
        return out
    }

    private static let typeSizes: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8]

    private static func walk(_ r: Reader, _ ifd: Int, _ out: inout EXIFSummary, _ exifIFD: inout Int?, depth: Int) throws {
        guard let count = r.u16(ifd), count < 1000 else { throw Error.malformed("ifd count") }
        for i in 0 ..< Int(count) {
            let e = ifd + 2 + i * 12
            guard let tag = r.u16(e), let type = r.u16(e + 2), let n = r.u32(e + 4) else { break }
            let size = (typeSizes[type] ?? 1) * Int(n)
            let valueOffset = size <= 4 ? e + 8 : Int(r.u32(e + 8) ?? 0)
            func str() -> String? { r.string(valueOffset, Int(n)) }
            func short() -> Int? { type == 3 ? r.u16(valueOffset).map(Int.init) : r.u32(valueOffset).map(Int.init) }
            func rat(_ signed: Bool = false) -> Double? { r.rational(valueOffset, signed: signed) }
            switch tag {
            case 0x010F: out.make = str()
            case 0x0110: out.model = str()
            case 0x0112: out.orientation = short()
            case 0x013B: out.artist = str()
            case 0x8298: out.copyright = str()
            case 0x8769: if depth == 0 { exifIFD = Int(r.u32(e + 8) ?? 0) }
            case 0x829A: out.exposureTime = rat()
            case 0x829D: out.fNumber = rat()
            case 0x8827: out.iso = short()
            case 0x9003: out.dateTimeOriginal = str().flatMap(Self.parseDate)
            case 0x9204: out.exposureBias = rat(true)
            case 0x920A: out.focalLength = rat()
            case 0xA002: out.width = short()
            case 0xA003: out.height = short()
            case 0xA434: out.lens = str()
            case 0xA431: out.serialNumber = str()
            default: break
            }
        }
    }

    /// EXIF dates are "yyyy:MM:dd HH:mm:ss" in local time.
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}

/// Builds a minimal Exif APP1 segment for tests and for files that arrive
/// without one (FTP push of camera JPEGs always has one; our rendered
/// exports copy the original's).
public enum EXIFWriter {
    public static func minimalJPEGExif(make: String, model: String, dateTimeOriginal: Date, exposureTime: Double, fNumber: Double, iso: Int) -> Data {
        var tiff = ByteBuffer()
        tiff.write(UInt8(0x49)); tiff.write(UInt8(0x49)); tiff.write(UInt16(42)); tiff.write(UInt32(8))
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let date = f.string(from: dateTimeOriginal) + "\0"
        let makeZ = make + "\0", modelZ = model + "\0"
        // IFD0: Make, Model, ExifIFD pointer. Values stored after both IFDs.
        let ifd0Count = 3, exifCount = 4
        let ifd0 = 8, exifIFD = ifd0 + 2 + ifd0Count * 12 + 4
        var dataOff = exifIFD + 2 + exifCount * 12 + 4
        var blobs = ByteBuffer()
        func put(_ s: String) -> UInt32 { let o = UInt32(dataOff); blobs.write(Array(s.utf8)); dataOff += s.utf8.count; return o }
        func putRat(_ n: UInt32, _ d: UInt32) -> UInt32 { let o = UInt32(dataOff); blobs.write(n); blobs.write(d); dataOff += 8; return o }
        tiff.write(UInt16(ifd0Count))
        let makeO = put(makeZ), modelO = put(modelZ)
        tiff.write(UInt16(0x010F)); tiff.write(UInt16(2)); tiff.write(UInt32(makeZ.utf8.count)); tiff.write(makeO)
        tiff.write(UInt16(0x0110)); tiff.write(UInt16(2)); tiff.write(UInt32(modelZ.utf8.count)); tiff.write(modelO)
        tiff.write(UInt16(0x8769)); tiff.write(UInt16(4)); tiff.write(UInt32(1)); tiff.write(UInt32(exifIFD))
        tiff.write(UInt32(0))
        tiff.write(UInt16(exifCount))
        let expO = putRat(UInt32((exposureTime * 1_000_000).rounded()), 1_000_000)
        let fO = putRat(UInt32((fNumber * 100).rounded()), 100)
        let dateO = put(date)
        tiff.write(UInt16(0x829A)); tiff.write(UInt16(5)); tiff.write(UInt32(1)); tiff.write(expO)
        tiff.write(UInt16(0x829D)); tiff.write(UInt16(5)); tiff.write(UInt32(1)); tiff.write(fO)
        tiff.write(UInt16(0x8827)); tiff.write(UInt16(3)); tiff.write(UInt32(1)); tiff.write(UInt16(iso)); tiff.write(UInt16(0))
        tiff.write(UInt16(0x9003)); tiff.write(UInt16(2)); tiff.write(UInt32(date.utf8.count)); tiff.write(dateO)
        tiff.write(UInt32(0))
        tiff.write(blobs.bytes)
        var seg = Data([0xFF, 0xE1])
        let payload = Data("Exif\0\0".utf8) + tiff.data
        let len = UInt16(payload.count + 2)
        seg.append(UInt8(len >> 8)); seg.append(UInt8(len & 0xFF)); seg.append(payload)
        return seg
    }
}
