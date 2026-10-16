import TetherCore
import XCTest
@testable import Tether

final class CreditsQuoteTextTests: XCTestCase {
    private func items(_ n: Int) -> [ExportJob.Item] {
        (0 ..< n).map { ExportJob.Item(id: "\($0)", filename: "\($0).jpg", kind: .jpeg, bytes: 1) }
    }

    func testFreeTierSplitsCreditsAndWatermarks() {
        let state = CreditsState(tier: .free, balance: 2)
        let quote = state.quote(for: items(5), forceWatermark: false)
        XCTAssertEqual(CreditsFormatting.quoteText(quote, tier: .free), "2 credits · 3 watermarked")
    }

    func testSingularCredit() {
        let state = CreditsState(tier: .free, balance: 10)
        XCTAssertEqual(CreditsFormatting.quoteText(state.quote(for: items(1), forceWatermark: false), tier: .free), "1 credit")
    }

    func testProIsIncluded() {
        let state = CreditsState(tier: .pro, balance: 0)
        XCTAssertEqual(CreditsFormatting.quoteText(state.quote(for: items(3), forceWatermark: false), tier: .pro), "Included in Pro")
    }
}
