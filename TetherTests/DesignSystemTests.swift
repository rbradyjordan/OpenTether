import SwiftUI
import TetherCore
import XCTest
@testable import Tether

final class RatingMathTests: XCTestCase {
    func testDragIndexMapsAcrossStars() {
        // 28 pt stars, 6 pt gaps: pitch 34.
        XCTAssertEqual(RatingMath.star(atX: -5, starSize: 28, spacing: 6), 0)
        XCTAssertEqual(RatingMath.star(atX: 0, starSize: 28, spacing: 6), 1)
        XCTAssertEqual(RatingMath.star(atX: 33, starSize: 28, spacing: 6), 1)
        XCTAssertEqual(RatingMath.star(atX: 34, starSize: 28, spacing: 6), 2)
        XCTAssertEqual(RatingMath.star(atX: 150, starSize: 28, spacing: 6), 5)
        XCTAssertEqual(RatingMath.star(atX: 10_000, starSize: 28, spacing: 6), 5)
    }

    func testTapOnCurrentClears() {
        XCTAssertEqual(RatingMath.tapped(3, current: 3), 0)
        XCTAssertEqual(RatingMath.tapped(4, current: 3), 4)
        XCTAssertEqual(RatingMath.tapped(1, current: 0), 1)
    }
}

final class MotionTests: XCTestCase {
    func testReduceMotionPicksEaseOut() {
        XCTAssertEqual(Motion.spring(TetherMotion.snap, reduce: true), TetherMotion.reduced)
        XCTAssertEqual(Motion.spring(TetherMotion.arrive, reduce: false), TetherMotion.arrive)
        XCTAssertNotEqual(Motion.spring(TetherMotion.settle, reduce: false), TetherMotion.reduced)
    }

    func testPulseBecomesBlinkUnderReduceMotion() {
        XCTAssertEqual(Motion.pulseScale(reduce: true), 1)
        XCTAssertEqual(Motion.pulseScale(reduce: false), 1.6)
    }
}

final class ExposureFormattingTests: XCTestCase {
    func testApertureUsesScriptF() {
        XCTAssertEqual(ExposureFormatting.value(for: .aperture, display: "f/2.8"), "ƒ/2.8")
        XCTAssertEqual(ExposureFormatting.value(for: .aperture, display: "F2.8"), "ƒ/2.8")
        XCTAssertEqual(ExposureFormatting.value(for: .aperture, display: "2.8"), "ƒ/2.8")
        XCTAssertEqual(ExposureFormatting.value(for: .aperture, display: "ƒ/4"), "ƒ/4")
    }

    func testISOGetsItsPrefixOnce() {
        XCTAssertEqual(ExposureFormatting.value(for: .iso, display: "400"), "ISO 400")
        XCTAssertEqual(ExposureFormatting.value(for: .iso, display: "ISO400"), "ISO 400")
        XCTAssertEqual(ExposureFormatting.value(for: .iso, display: "ISO 800"), "ISO 800")
        XCTAssertEqual(ExposureFormatting.value(for: .iso, display: "Auto"), "Auto")
    }

    func testCompensationIsSigned() {
        XCTAssertEqual(ExposureFormatting.value(for: .exposureCompensation, display: "0.3"), "+0.3")
        XCTAssertEqual(ExposureFormatting.value(for: .exposureCompensation, display: "-0.7"), "-0.7")
        XCTAssertEqual(ExposureFormatting.value(for: .exposureCompensation, display: "0"), "0")
        XCTAssertEqual(ExposureFormatting.value(for: .exposureCompensation, display: "+1"), "+1")
    }

    func testShutterPassesThroughAndMissingIsDash() {
        XCTAssertEqual(ExposureFormatting.value(for: .shutterSpeed, display: "1/250"), "1/250")
        XCTAssertEqual(ExposureFormatting.value(for: .shutterSpeed, display: nil), "—")
        XCTAssertEqual(ExposureFormatting.value(for: .shutterSpeed, display: "  "), "—")
    }
}

final class ExportQuoteLineTests: XCTestCase {
    private func items(_ n: Int) -> [ExportJob.Item] {
        (0 ..< n).map { ExportJob.Item(id: "\($0)", filename: "\($0).jpg", kind: .jpeg, bytes: 1) }
    }

    func testFreeTierLine() {
        let state = CreditsState(tier: .free, balance: 3)
        let quote = state.quote(for: items(24), forceWatermark: false)
        let line = CreditsFormatting.quoteLine(photos: 24, quote: quote, tier: .free)
        XCTAssertEqual(line.text, "24 photos · 3 credits · 21 watermarked")
        XCTAssertEqual(line.watermark, "21 watermarked")
    }

    func testNoWatermarkSegmentWhenCovered() {
        let state = CreditsState(tier: .free, balance: 10)
        let line = CreditsFormatting.quoteLine(photos: 1, quote: state.quote(for: items(1), forceWatermark: false), tier: .free)
        XCTAssertEqual(line.text, "1 photo · 1 credit")
        XCTAssertNil(line.watermark)
    }

    func testProAndEmpty() {
        let pro = CreditsState(tier: .pro, balance: 0)
        XCTAssertEqual(CreditsFormatting.quoteLine(photos: 5, quote: pro.quote(for: items(5), forceWatermark: false), tier: .pro).text,
                       "5 photos · included in Pro")
        let free = CreditsState(tier: .free, balance: 0)
        XCTAssertEqual(CreditsFormatting.quoteLine(photos: 0, quote: free.quote(for: [], forceWatermark: false), tier: .free).text,
                       "Nothing to export")
    }
}

final class LookStrengthDetentTests: XCTestCase {
    func testSnapsNearStops() {
        XCTAssertEqual(LookStrengthDetent.snap(0.02).value, 0)
        XCTAssertEqual(LookStrengthDetent.snap(0.02).stop, 0)
        XCTAssertEqual(LookStrengthDetent.snap(0.49).value, 0.5)
        XCTAssertEqual(LookStrengthDetent.snap(0.98).value, 1)
    }

    func testLeavesOtherValuesAlone() {
        let r = LookStrengthDetent.snap(0.3)
        XCTAssertEqual(r.value, 0.3)
        XCTAssertNil(r.stop)
    }
}

final class WheelMathTests: XCTestCase {
    func testOffsetRoundsAndClamps() {
        XCTAssertEqual(WheelMath.index(forOffset: 0, rowHeight: 44, count: 10), 0)
        XCTAssertEqual(WheelMath.index(forOffset: 21, rowHeight: 44, count: 10), 0)
        XCTAssertEqual(WheelMath.index(forOffset: 23, rowHeight: 44, count: 10), 1)
        XCTAssertEqual(WheelMath.index(forOffset: 5000, rowHeight: 44, count: 10), 9)
        XCTAssertEqual(WheelMath.index(forOffset: -50, rowHeight: 44, count: 10), 0)
        XCTAssertEqual(WheelMath.index(forOffset: 50, rowHeight: 44, count: 0), 0)
    }

    func testSteps() {
        XCTAssertEqual(WheelMath.steps(from: 2, to: 5), 3)
        XCTAssertEqual(WheelMath.steps(from: 5, to: 2), 3)
    }
}

final class ConnectFailureCopyTests: XCTestCase {
    func testFirstSentenceOnly() {
        XCTAssertEqual(ConnectFailureCopy.sentence("Camera refused the session. Try PC Remote mode."), "Camera refused the session.")
        XCTAssertEqual(ConnectFailureCopy.sentence("Timed out"), "Timed out.")
        XCTAssertEqual(ConnectFailureCopy.sentence("   "), "The camera did not answer.")
    }
}
