import XCTest
@testable import TetherCore

final class BuiltInLooksTests: XCTestCase {
    func testNeutralRecipeIsIdentityAndMonoIsGrey() {
        let neutral = LookRecipe()
        for v in [SIMD3<Float>(0.2, 0.5, 0.8), SIMD3(0, 0, 0), SIMD3(1, 1, 1)] {
            XCTAssertEqual(neutral.apply(v).x, v.x, accuracy: 1e-5)
            XCTAssertEqual(neutral.apply(v).z, v.z, accuracy: 1e-5)
        }
        let mono = LookRecipe(saturation: -1).apply(SIMD3(0.9, 0.2, 0.1))
        XCTAssertEqual(mono.x, mono.y, accuracy: 1e-5); XCTAssertEqual(mono.y, mono.z, accuracy: 1e-5)
        let warm = LookRecipe(warmth: 1).apply(SIMD3(0.5, 0.5, 0.5))
        XCTAssertGreaterThan(warm.x, warm.z)
    }

    func testBuiltInsInstallAndResolveWithoutNetwork() async throws {
        let store = try SessionStore.inMemory()
        BuiltInLooks.install(into: store)
        let looks = try store.looks()
        XCTAssertEqual(looks.count, BuiltInLooks.all.count)
        let resolver = LookResolver(store: store)   // no fetcher: everything is local
        let lut = try await resolver.lut(for: LookStack(lookID: "ot.mono", strength: 1))
        XCTAssertEqual(lut?.size, 25)
        BuiltInLooks.install(into: store)
        XCTAssertEqual(try store.looks().count, BuiltInLooks.all.count, "re-install is idempotent")
    }

    func testColorMatchMovesTargetTowardReference() {
        let reference = (0 ..< 200).map { i in SIMD3<Float>(0.8, 0.5, 0.3) + SIMD3(repeating: Float(i % 10) * 0.01) }
        let target = (0 ..< 200).map { i in SIMD3<Float>(0.3, 0.5, 0.8) + SIMD3(repeating: Float(i % 10) * 0.01) }
        let lut = ColorMatch.lut(reference: reference, target: target)
        // Sample the LUT at the target's average colour: it should come out warm.
        let n = lut.size, idx = { (r: Int, g: Int, b: Int) in ((b * n + g) * n + r) * 3 }
        let i = idx(Int(0.34 * Float(n - 1)), Int(0.54 * Float(n - 1)), Int(0.84 * Float(n - 1)))
        XCTAssertGreaterThan(lut.table[i], lut.table[i + 2], "blue cast moved to the reference's warm cast")
    }
}
