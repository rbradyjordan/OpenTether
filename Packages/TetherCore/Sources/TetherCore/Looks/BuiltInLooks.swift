import Foundation

/// Looks that ship with the app and are generated on the device: no
/// downloads, no account. Each is a small recipe turned into a 3D LUT, so
/// it renders through the same path as an imported `.cube`.
public struct LookRecipe: Hashable, Sendable {
    /// -1…1: cooler ↔ warmer.
    public var warmth: Float = 0
    /// -1…1: magenta ↔ green.
    public var tint: Float = 0
    /// -1…1: flatter ↔ punchier (S-curve).
    public var contrast: Float = 0
    /// -1…1: -1 is monochrome.
    public var saturation: Float = 0
    /// 0…1: lifted, matte blacks.
    public var fade: Float = 0
    /// Colour pushed into shadows / highlights (split toning), with strength.
    public var shadowTone: SIMD3<Float> = .zero
    public var highlightTone: SIMD3<Float> = .zero

    public init(warmth: Float = 0, tint: Float = 0, contrast: Float = 0, saturation: Float = 0, fade: Float = 0,
                shadowTone: SIMD3<Float> = .zero, highlightTone: SIMD3<Float> = .zero) {
        self.warmth = warmth
        self.tint = tint
        self.contrast = contrast
        self.saturation = saturation
        self.fade = fade
        self.shadowTone = shadowTone
        self.highlightTone = highlightTone
    }

    /// Bake the recipe into a LUT (`.cube` order: red fastest).
    public func lut(size: Int = 25, title: String) -> CubeLUT {
        var table = [Float]()
        table.reserveCapacity(size * size * size * 3)
        let step = 1 / Float(size - 1)
        for b in 0 ..< size {
            for g in 0 ..< size {
                for r in 0 ..< size {
                    let out = apply(SIMD3(Float(r) * step, Float(g) * step, Float(b) * step))
                    table += [out.x, out.y, out.z]
                }
            }
        }
        return (try? CubeLUT(size: size, title: title, table: table)) ?? .identity(size: size)
    }

    func apply(_ input: SIMD3<Float>) -> SIMD3<Float> {
        var c = input
        // White balance.
        c.x *= 1 + 0.10 * warmth
        c.z *= 1 - 0.10 * warmth
        c.y *= 1 - 0.06 * tint
        // Contrast: a smooth S-curve that keeps black and white anchored.
        if contrast != 0 {
            let k = contrast
            c = SIMD3(curve(c.x, k), curve(c.y, k), curve(c.z, k))
        }
        // Saturation around Rec. 709 luma.
        let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        c = SIMD3(repeating: luma) + (c - SIMD3(repeating: luma)) * max(0, 1 + saturation)
        // Split toning, weighted by brightness.
        let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        c += shadowTone * (1 - l) * (1 - l)
        c += highlightTone * l * l
        // Fade: lift blacks, soften whites a touch.
        if fade > 0 { c = SIMD3(repeating: 0.10 * fade) + c * (1 - 0.14 * fade) }
        return c.clamped(lowerBound: .zero, upperBound: .one)
    }

    private func curve(_ x: Float, _ k: Float) -> Float {
        let s = x * x * (3 - 2 * x)          // smoothstep: an S-curve
        return k > 0 ? x + (s - x) * k * 1.6 : x + (0.5 - x) * (-k) * 0.45
    }
}

public enum BuiltInLooks {
    public struct Entry: Sendable {
        public var id: String
        public var name: String
        public var recipe: LookRecipe
    }

    public static let family = "Open Tether"

    public static let all: [Entry] = [
        Entry(id: "ot.natural", name: "Natural", recipe: LookRecipe(contrast: 0.15, saturation: 0.05)),
        Entry(id: "ot.portrait", name: "Warm Portrait", recipe: LookRecipe(warmth: 0.35, contrast: 0.1, saturation: -0.08, fade: 0.15)),
        Entry(id: "ot.studio", name: "Cool Studio", recipe: LookRecipe(warmth: -0.3, contrast: 0.25, saturation: -0.05)),
        Entry(id: "ot.chrome", name: "Chrome", recipe: LookRecipe(contrast: 0.35, saturation: -0.3,
                                                                  shadowTone: SIMD3(-0.01, 0.0, 0.02))),
        Entry(id: "ot.film", name: "Faded Film", recipe: LookRecipe(warmth: 0.15, contrast: -0.2, saturation: -0.15, fade: 0.6,
                                                                   shadowTone: SIMD3(0.0, 0.02, 0.04))),
        Entry(id: "ot.golden", name: "Golden Hour", recipe: LookRecipe(warmth: 0.6, tint: -0.1, contrast: 0.15, saturation: 0.1,
                                                                    highlightTone: SIMD3(0.05, 0.02, -0.03))),
        Entry(id: "ot.tealorange", name: "Teal & Orange", recipe: LookRecipe(contrast: 0.25, saturation: 0.05,
                                                                           shadowTone: SIMD3(-0.05, 0.02, 0.06),
                                                                           highlightTone: SIMD3(0.06, 0.02, -0.04))),
        Entry(id: "ot.matte", name: "Matte", recipe: LookRecipe(contrast: -0.15, saturation: -0.1, fade: 0.8)),
        Entry(id: "ot.mono", name: "Mono", recipe: LookRecipe(contrast: 0.15, saturation: -1)),
        Entry(id: "ot.mono.contrast", name: "Mono Contrast", recipe: LookRecipe(contrast: 0.55, saturation: -1)),
    ]

    /// Store the built-ins (descriptor + cube) so the look picker, resolver
    /// and exports treat them like any other look. Safe to call every launch.
    public static func install(into store: SessionStore) {
        for entry in all {
            let cube = Data(entry.recipe.lut(title: entry.name).serialized().utf8)
            let descriptor = LookDescriptor(id: entry.id, name: entry.name, family: family, version: 1, size: 25,
                                            sha256: "", cubeURL: "builtin:\(entry.id)")
            try? store.saveLook(descriptor, cube: cube)
        }
    }
}

/// On-device colour match: moves the target's colour statistics (mean and
/// spread per channel, in a decorrelated colour space) onto the reference's
/// — Reinhard's transfer — and bakes that into a LUT.
public enum ColorMatch {
    /// `reference` / `target`: RGB samples in 0…1 (a downsampled frame each).
    public static func lut(reference: [SIMD3<Float>], target: [SIMD3<Float>], strength: Float = 1,
                           size: Int = 25, title: String = "Match") -> CubeLUT {
        guard !reference.isEmpty, !target.isEmpty else { return .identity(size: size) }
        let ref = stats(reference.map(toLab))
        let tgt = stats(target.map(toLab))
        let k = max(0, min(1, strength))
        var table = [Float]()
        table.reserveCapacity(size * size * size * 3)
        let step = 1 / Float(size - 1)
        for b in 0 ..< size {
            for g in 0 ..< size {
                for r in 0 ..< size {
                    let input = SIMD3(Float(r) * step, Float(g) * step, Float(b) * step)
                    let lab = toLab(input)
                    let moved = (lab - tgt.mean) / pointwiseMax(tgt.sd, SIMD3(repeating: 1e-4)) * ref.sd + ref.mean
                    let out = fromLab(moved).clamped(lowerBound: .zero, upperBound: .one)
                    let mixed = input + (out - input) * k
                    table += [mixed.x, mixed.y, mixed.z]
                }
            }
        }
        return (try? CubeLUT(size: size, title: title, table: table)) ?? .identity(size: size)
    }

    private static func stats(_ v: [SIMD3<Float>]) -> (mean: SIMD3<Float>, sd: SIMD3<Float>) {
        let n = Float(v.count)
        let mean = v.reduce(SIMD3<Float>.zero, +) / n
        let variance = v.reduce(SIMD3<Float>.zero) { $0 + ($1 - mean) * ($1 - mean) } / n
        return (mean, SIMD3(variance.x.squareRoot(), variance.y.squareRoot(), variance.z.squareRoot()))
    }

    // lαβ via LMS (Ruderman et al.), as in Reinhard 2001.
    private static func toLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.3811 * c.x + 0.5783 * c.y + 0.0402 * c.z
        let m = 0.1967 * c.x + 0.7244 * c.y + 0.0782 * c.z
        let s = 0.0241 * c.x + 0.1288 * c.y + 0.8444 * c.z
        let L = Float(log10(Double(max(l, 1e-4)))), M = Float(log10(Double(max(m, 1e-4)))), S = Float(log10(Double(max(s, 1e-4))))
        return SIMD3((L + M + S) / Float(3).squareRoot(), (L + M - 2 * S) / Float(6).squareRoot(), (L - M) / Float(2).squareRoot())
    }

    private static func fromLab(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let a = v.x / Float(3).squareRoot(), b = v.y / Float(6).squareRoot(), c = v.z / Float(2).squareRoot()
        let L = Float(pow(10, Double(a + b + c))), M = Float(pow(10, Double(a + b - c))), S = Float(pow(10, Double(a - 2 * b)))
        return SIMD3(4.4679 * L - 3.5873 * M + 0.1193 * S,
                     -1.2186 * L + 2.3809 * M - 0.1624 * S,
                     0.0497 * L - 0.2439 * M + 1.2045 * S)
    }
}
