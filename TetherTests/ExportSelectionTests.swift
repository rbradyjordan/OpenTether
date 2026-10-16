import TetherCore
import XCTest
@testable import Tether

final class ExportSelectionTests: XCTestCase {
    private func item(_ name: String, rating: Int = 0, flag: CaptureFlag = .none, ready: Bool = true, kind: MediaKind = .jpeg) -> CaptureItem {
        CaptureItem(sessionID: "s", sequence: 1, handle: 1, filename: name, kind: kind, bytes: 10,
                    rating: rating, flag: flag, state: ready ? .ready : .announced, source: .usb)
    }

    func testAllExcludesRejectsAndUnready() {
        let items = [item("A.JPG"), item("B.JPG", flag: .reject), item("C.JPG", ready: false)]
        XCTAssertEqual(ExportScope.all.filter(items, selectedID: nil).map(\.filename), ["A.JPG"])
    }

    func testPicksAndRated() {
        let items = [item("A.JPG", rating: 4, flag: .pick), item("B.JPG", rating: 3), item("C.JPG", rating: 5, flag: .reject)]
        XCTAssertEqual(ExportScope.picks.filter(items, selectedID: nil).map(\.filename), ["A.JPG"])
        XCTAssertEqual(ExportScope.rated(min: 3).filter(items, selectedID: nil).map(\.filename), ["A.JPG", "B.JPG"])
    }

    func testSelectedIncludesRawJpegPair() {
        let jpeg = item("IMG_0001.JPG")
        let raw = item("IMG_0001.CR3", kind: .raw)
        let other = item("IMG_0002.JPG")
        let out = ExportScope.selected.filter([jpeg, raw, other], selectedID: jpeg.id)
        XCTAssertEqual(Set(out.map(\.filename)), ["IMG_0001.JPG", "IMG_0001.CR3"])
        XCTAssertTrue(ExportScope.selected.filter([jpeg], selectedID: nil).isEmpty)
    }
}
