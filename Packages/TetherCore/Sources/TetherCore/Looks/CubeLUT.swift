import Foundation

/// A look: built in, imported as a `.cube`, or made by colour match.
public struct LookDescriptor: Identifiable, Codable, Hashable, Sendable {
    public struct Hint: Codable, Hashable, Sendable {
        public var warmth: Double
        public var contrast: Double
        public var saturation: Double
        public init(warmth: Double = 0, contrast: Double = 0, saturation: Double = 0) {
            self.warmth = warmth
            self.contrast = contrast
            self.saturation = saturation
        }
    }

    public var id: String
    public var name: String
    public var family: String
    public var version: Int
    public var size: Int
    public var sha256: String
    public var cubeURL: String
    public var hint: Hint?

    public init(id: String, name: String, family: String, version: Int = 1, size: Int = 33, sha256: String, cubeURL: String, hint: Hint? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.version = version
        self.size = size
        self.sha256 = sha256
        self.cubeURL = cubeURL
        self.hint = hint
    }

    enum CodingKeys: String, CodingKey { case id, name, family, version, size, sha256, cubeURL = "cube_url", hint }

    public static let neutralID = "neutral"
}

/// Adobe `.cube` 3D LUT: parse, serialise, sample (trilinear). Pure Swift so
/// the look math is unit-tested here and shared by the Core Image / Metal
/// renderer in the app.
public struct CubeLUT: Equatable, Sendable {
    public let size: Int
    public let title: String
    /// RGB triples, red fastest: index = r + g*size + b*size*size.
    public let table: [Float]
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>

    public enum ParseError: Error, Equatable { case missingSize, badLine(Int), wrongCount(expected: Int, got: Int), badSize(Int) }

    public init(size: Int, title: String = "", table: [Float], domainMin: SIMD3<Float> = .zero, domainMax: SIMD3<Float> = .one) throws {
        guard size >= 2, size <= 65 else { throw ParseError.badSize(size) }
        guard table.count == size * size * size * 3 else { throw ParseError.wrongCount(expected: size * size * size * 3, got: table.count) }
        self.size = size
        self.title = title
        self.table = table
        self.domainMin = domainMin
        self.domainMax = domainMax
    }

    public static func identity(size: Int = 33) -> CubeLUT {
        var t = [Float]()
        t.reserveCapacity(size * size * size * 3)
        let n = Float(size - 1)
        for b in 0 ..< size { for g in 0 ..< size { for r in 0 ..< size {
            t.append(Float(r) / n); t.append(Float(g) / n); t.append(Float(b) / n)
        } } }
        return try! CubeLUT(size: size, title: "Identity", table: t)
    }

    public init(parsing text: String) throws {
        var size: Int?
        var title = ""
        var mn = SIMD3<Float>(repeating: 0), mx = SIMD3<Float>(repeating: 1)
        var values = [Float]()
        for (i, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.uppercased().hasPrefix("TITLE") {
                title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
                continue
            }
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                guard let n = Int(line.split(separator: " ").last ?? "") else { throw ParseError.badLine(i + 1) }
                size = n
                continue
            }
            if line.uppercased().hasPrefix("LUT_1D_SIZE") { throw ParseError.badLine(i + 1) }
            if line.uppercased().hasPrefix("DOMAIN_MIN") || line.uppercased().hasPrefix("DOMAIN_MAX") {
                let parts = line.split(separator: " ").dropFirst().compactMap { Float($0) }
                guard parts.count == 3 else { throw ParseError.badLine(i + 1) }
                if line.uppercased().hasPrefix("DOMAIN_MIN") { mn = SIMD3(parts[0], parts[1], parts[2]) } else { mx = SIMD3(parts[0], parts[1], parts[2]) }
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
            guard parts.count == 3 else { throw ParseError.badLine(i + 1) }
            values.append(contentsOf: parts)
        }
        guard let n = size else { throw ParseError.missingSize }
        try self.init(size: n, title: title, table: values, domainMin: mn, domainMax: mx)
    }

    public func serialized() -> String {
        var s = "TITLE \"\(title)\"\nLUT_3D_SIZE \(size)\nDOMAIN_MIN \(fmt(domainMin.x)) \(fmt(domainMin.y)) \(fmt(domainMin.z))\nDOMAIN_MAX \(fmt(domainMax.x)) \(fmt(domainMax.y)) \(fmt(domainMax.z))\n"
        s.reserveCapacity(table.count * 9)
        var i = 0
        while i < table.count {
            s += "\(fmt(table[i])) \(fmt(table[i + 1])) \(fmt(table[i + 2]))\n"
            i += 3
        }
        return s
    }

    private func fmt(_ f: Float) -> String { String(format: "%.6f", f) }

    @inline(__always)
    private func node(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
        let i = (r + g * size + b * size * size) * 3
        return SIMD3(table[i], table[i + 1], table[i + 2])
    }

    /// Trilinear lookup of one RGB value in 0...1.
    public func sample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let n = Float(size - 1)
        let p = simd_clamp((rgb - domainMin) / (domainMax - domainMin), SIMD3(repeating: 0), SIMD3(repeating: 1)) * n
        let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let i1 = SIMD3<Int>(min(i0.x + 1, size - 1), min(i0.y + 1, size - 1), min(i0.z + 1, size - 1))
        let f = p - SIMD3(Float(i0.x), Float(i0.y), Float(i0.z))
        let c000 = node(i0.x, i0.y, i0.z), c100 = node(i1.x, i0.y, i0.z)
        let c010 = node(i0.x, i1.y, i0.z), c110 = node(i1.x, i1.y, i0.z)
        let c001 = node(i0.x, i0.y, i1.z), c101 = node(i1.x, i0.y, i1.z)
        let c011 = node(i0.x, i1.y, i1.z), c111 = node(i1.x, i1.y, i1.z)
        let c00 = c000 + (c100 - c000) * f.x, c10 = c010 + (c110 - c010) * f.x
        let c01 = c001 + (c101 - c001) * f.x, c11 = c011 + (c111 - c011) * f.x
        let c0 = c00 + (c10 - c00) * f.y, c1 = c01 + (c11 - c01) * f.y
        return c0 + (c1 - c0) * f.z
    }

    /// Blend toward identity: strength 0 = no effect, 1 = full look.
    public func blended(strength: Float) -> CubeLUT {
        let s = max(0, min(1, strength))
        if s >= 1 { return self }
        let id = CubeLUT.identity(size: size)
        var t = table
        for i in 0 ..< t.count { t[i] = id.table[i] + (t[i] - id.table[i]) * s }
        return try! CubeLUT(size: size, title: title, table: t, domainMin: domainMin, domainMax: domainMax)
    }

    /// Apply to 8-bit RGBA pixels in place (CPU path for thumbnails/tests).
    public func apply(toRGBA8 pixels: inout [UInt8]) {
        var i = 0
        while i + 3 < pixels.count {
            let v = sample(SIMD3(Float(pixels[i]) / 255, Float(pixels[i + 1]) / 255, Float(pixels[i + 2]) / 255))
            pixels[i] = UInt8(max(0, min(255, (v.x * 255).rounded())))
            pixels[i + 1] = UInt8(max(0, min(255, (v.y * 255).rounded())))
            pixels[i + 2] = UInt8(max(0, min(255, (v.z * 255).rounded())))
            i += 4
        }
    }

    /// Core Image's CIColorCube wants RGBA float32, red fastest. Same order as .cube.
    public var colorCubeData: Data {
        var out = [Float]()
        out.reserveCapacity(size * size * size * 4)
        var i = 0
        while i < table.count {
            out.append(table[i]); out.append(table[i + 1]); out.append(table[i + 2]); out.append(1)
            i += 3
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

@inline(__always)
private func simd_clamp(_ v: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(max(lo.x, min(hi.x, v.x)), max(lo.y, min(hi.y, v.y)), max(lo.z, min(hi.z, v.z)))
}

/// A look applied to the canvas: which LUT, how strong. Carried forward to
/// each new capture (`syncCameraEffectFromLastFile`).
public struct LookStack: Codable, Hashable, Sendable {
    public var lookID: String?
    public var strength: Double

    public init(lookID: String? = nil, strength: Double = 1) {
        self.lookID = lookID
        self.strength = max(0, min(1, strength))
    }

    public static let none = LookStack()
    public var isNeutral: Bool { lookID == nil || lookID == LookDescriptor.neutralID || strength == 0 }
}

/// Renders a capture with a look. The Core Image implementation lives in the
/// app (`EffectEngine`); this protocol keeps the pipeline testable here.
public protocol LookRendering: Sendable {
    func render(image: Data, look: CubeLUT?, strength: Double, maxPixelSize: Int?) async throws -> Data
}

/// Resolves LookStack → CubeLUT from the store (optionally fetching a missing cube).
public final class LookResolver: @unchecked Sendable {
    private let store: SessionStore
    private let fetch: (@Sendable (LookDescriptor) async throws -> Data)?
    private let lock = NSLock()
    private var memo: [String: CubeLUT] = [:]

    public init(store: SessionStore, fetch: (@Sendable (LookDescriptor) async throws -> Data)? = nil) {
        self.store = store
        self.fetch = fetch
    }

    public func lut(for stack: LookStack) async throws -> CubeLUT? {
        guard let id = stack.lookID, !stack.isNeutral else { return nil }
        lock.lock()
        if let m = memo[id] { lock.unlock(); return m.blended(strength: Float(stack.strength)) }
        lock.unlock()
        var data = try store.cube(for: id)
        if data == nil, let fetch, let desc = try store.looks().first(where: { $0.id == id }) {
            data = try await fetch(desc)
            try store.saveLook(desc, cube: data)
        }
        guard let d = data, let text = String(data: d, encoding: .utf8) else { return nil }
        let lut = try CubeLUT(parsing: text)
        lock.lock(); memo[id] = lut; lock.unlock()
        return lut.blended(strength: Float(stack.strength))
    }
}
