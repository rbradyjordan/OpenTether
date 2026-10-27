import XCTest
@testable import TetherCore

final class RealEstateTests: XCTestCase {
    // MARK: Rooms

    func testSlugsAreFilenameSafeAndRoundTripToDisplayNames() {
        XCTAssertEqual(RoomShotList.slug("Primary Bedroom"), "primary-bedroom")
        XCTAssertEqual(RoomShotList.slug("  Kitchen / Dining  "), "kitchen-dining")
        XCTAssertEqual(RoomShotList.slug("Café"), "cafe")
        XCTAssertEqual(RoomShotList.displayName(fromSlug: "primary-bedroom"), "Primary Bedroom")
        XCTAssertEqual(RoomShotList.Room(name: "Bedroom 2").tag, "room:bedroom-2")
    }

    func testRoomFromTagsCountsAndCoverage() {
        let list = RoomShotList.listing
        let tags: [String: [String]] = [
            "a": ["room:kitchen"], "b": ["room:kitchen", "bracket:12"], "c": ["room:entry"], "d": ["favourite"],
        ]
        XCTAssertEqual(RoomShotList.roomSlug(in: tags["b"]!), "kitchen")
        XCTAssertNil(RoomShotList.roomSlug(in: tags["d"]!))
        let counts = RoomShotList.counts(from: tags)
        XCTAssertEqual(counts, ["kitchen": 2, "entry": 1])
        let cov = list.coverage(counts: counts)
        XCTAssertEqual(cov.covered, 2)
        XCTAssertEqual(cov.total, list.rooms.count)
    }

    func testNextRoomWalksTheListAndWraps() {
        let list = RoomShotList(rooms: ["A", "B", "C"].map { RoomShotList.Room(name: $0) })
        XCTAssertEqual(list.next(after: nil)?.name, "A")
        XCTAssertEqual(list.next(after: "a")?.name, "B")
        XCTAssertEqual(list.next(after: "c")?.name, "A")
        XCTAssertEqual(list.next(after: "missing")?.name, "A")
        XCTAssertNil(RoomShotList(rooms: []).next(after: nil))
    }

    func testRoomListPersistsPerSessionInTheStore() throws {
        let store = try SessionStore(path: ":memory:")
        XCTAssertNil(store.roomList(for: "s1"))
        store.setRoomList(.condo, for: "s1")
        XCTAssertEqual(store.roomList(for: "s1"), .condo)
        XCTAssertNil(store.roomList(for: "s2"))
        store.setRoomList(nil, for: "s1")
        XCTAssertNil(store.roomList(for: "s1"))
    }

    // MARK: Brackets

    private func frame(_ seq: Int, at t: TimeInterval, shutter: String, aperture: String = "f/8", comp: String = "0", kind: MediaKind = .jpeg,
                       name: String? = nil) -> CaptureItem {
        CaptureItem(sessionID: "s", sequence: seq, handle: UInt32(seq), filename: name ?? String(format: "IMG_%04d.%@", seq, kind == .raw ? "CR3" : "JPG"),
                    kind: kind, bytes: 1, capturedAt: Date(timeIntervalSince1970: 1_000 + t), state: .ready, source: .usb,
                    exposure: ExposureSummary(aperture: aperture, shutter: shutter, iso: "100", compensation: comp))
    }

    func testAEBRunsBecomeBracketsAndSinglesDoNot() {
        let items = [
            frame(1, at: 0, shutter: "1/60"),                       // lone frame
            frame(2, at: 10, shutter: "1/60", comp: "-2"),           // 3-frame AEB
            frame(3, at: 10.3, shutter: "1/15", comp: "0"),
            frame(4, at: 10.6, shutter: "1/4", comp: "+2"),
            frame(5, at: 30, shutter: "1/125"),                      // two frames, same exposure: not a bracket
            frame(6, at: 30.2, shutter: "1/125"),
            frame(7, at: 60, shutter: "1/250"),                      // 5-frame set by shutter alone
            frame(8, at: 60.2, shutter: "1/125"),
            frame(9, at: 60.4, shutter: "1/60"),
            frame(10, at: 60.6, shutter: "1/30"),
            frame(11, at: 60.8, shutter: "1/15"),
        ]
        let groups = BracketDetector.groups(in: items.shuffled())
        XCTAssertEqual(groups.map(\.size), [3, 5])
        XCTAssertEqual(groups[0].tag, "bracket:2")
        XCTAssertEqual(groups[0].middle.sequence, 3, "the middle frame is the normal exposure")
        XCTAssertEqual(groups[1].items.map(\.sequence), [7, 8, 9, 10, 11])
    }

    func testAGapOrApertureChangeSplitsASet() {
        let items = [
            frame(1, at: 0, shutter: "1/60", comp: "-2"),
            frame(2, at: 0.3, shutter: "1/15", comp: "0"),
            frame(3, at: 9, shutter: "1/4", comp: "+2"),            // too late: the shooter moved on
            frame(4, at: 20, shutter: "1/60", aperture: "f/8"),
            frame(5, at: 20.3, shutter: "1/15", aperture: "f/11"),  // different aperture
            frame(6, at: 20.6, shutter: "1/4", aperture: "f/8"),
        ]
        XCTAssertTrue(BracketDetector.groups(in: items).isEmpty)
    }

    func testRawJpegPairsCountOnceAndTheTagNamesTheBracket() {
        var items: [CaptureItem] = []
        for (i, (s, c)) in [("1/60", "-2"), ("1/15", "0"), ("1/4", "+2")].enumerated() {
            items.append(frame(i * 2 + 1, at: Double(i) * 0.3, shutter: s, comp: c, name: String(format: "IMG_%04d.JPG", i + 1)))
            items.append(frame(i * 2 + 2, at: Double(i) * 0.3, shutter: s, comp: c, kind: .raw, name: String(format: "IMG_%04d.CR3", i + 1)))
        }
        let plain = BracketDetector.groups(in: items)
        XCTAssertTrue(plain.isEmpty, "a RAW twin repeats its JPEG's exposure and breaks the run: hence the pair-collapsing variant")
        let collapsed = BracketDetector.groupsCollapsingPairs(in: items)
        XCTAssertEqual(collapsed.map(\.size), [3])
        XCTAssertEqual(BracketDetector.bracketID(in: ["room:kitchen", collapsed[0].tag]), "1")
    }

    func testNamingTokensForRoomAndBracket() {
        let item = frame(12, at: 0, shutter: "1/60", name: "IMG_0012.JPG")
        let t = NamingTemplate("{session}_{room}_{bracket}_{seq:2}")
        let name = t.render(capture: item, sessionName: "123 Main St", index: 7, tags: ["bracket:12", "room:primary-bedroom", "hero"])
        // Spaces are kept, as every other token does; repeated separators collapse.
        XCTAssertEqual(name, "123 Main St_Primary Bedroom_b0012_07")
        XCTAssertEqual(NamingTemplate("{tag}").render(capture: item, sessionName: nil, index: 1, tags: ["room:kitchen", "hero"]), "hero",
                       "room and bracket markers are not the first tag")
        XCTAssertEqual(NamingTemplate.listing.render(capture: item, sessionName: "Listing 3", index: 2, tags: []), "Listing 3_02",
                       "no room yet: the empty token leaves no double underscore")
    }
}
