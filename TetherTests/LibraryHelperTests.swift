import TetherCore
import XCTest
@testable import Tether

final class GridMathTests: XCTestCase {
    func testColumnsClampToTwoThroughSix() {
        XCTAssertEqual(GridMath.clampColumns(1), 2)
        XCTAssertEqual(GridMath.clampColumns(4), 4)
        XCTAssertEqual(GridMath.clampColumns(9), 6)
    }

    func testPinchOutShowsFewerColumns() {
        XCTAssertEqual(GridMath.columns(afterPinch: 2, from: 4), 2)
        XCTAssertEqual(GridMath.columns(afterPinch: 0.5, from: 3), 6)
        XCTAssertEqual(GridMath.columns(afterPinch: 1, from: 3), 3)
        XCTAssertEqual(GridMath.columns(afterPinch: 0, from: 3), 3)
    }

    func testTileSideAccountsForGutters() {
        // 302 pt wide, 3 columns, 2-pt gutters: (302 - 4) / 3 = 99.333…
        XCTAssertEqual(GridMath.tileSide(width: 302, columns: 3), 298.0 / 3, accuracy: 0.001)
    }

    func testIndexAtPointMapsRowsAndColumns() {
        // 100-pt tiles + 2-pt gutter → pitch 102, 3 columns, 7 items.
        let w: CGFloat = 304
        XCTAssertEqual(GridMath.index(at: CGPoint(x: 10, y: 10), width: w, columns: 3, count: 7), 0)
        XCTAssertEqual(GridMath.index(at: CGPoint(x: 250, y: 10), width: w, columns: 3, count: 7), 2)
        XCTAssertEqual(GridMath.index(at: CGPoint(x: 110, y: 110), width: w, columns: 3, count: 7), 4)
        XCTAssertEqual(GridMath.index(at: CGPoint(x: 10, y: 210), width: w, columns: 3, count: 7), 6)
        XCTAssertNil(GridMath.index(at: CGPoint(x: 110, y: 210), width: w, columns: 3, count: 7), "past the last tile")
        XCTAssertNil(GridMath.index(at: CGPoint(x: -1, y: 10), width: w, columns: 3, count: 7))
    }

    func testRangeIsDirectionless() {
        XCTAssertEqual(GridMath.range(from: 5, to: 2), 2 ... 5)
        XCTAssertEqual(GridMath.range(from: 2, to: 5), 2 ... 5)
        XCTAssertEqual(GridMath.range(from: 3, to: 3), 3 ... 3)
    }

    func testDragRangeSelectsThroughSelection() {
        let ids = (0 ..< 6).map { "c\($0)" }
        var selection = Selection(["c0"])
        for id in GridMath.range(from: 1, to: 3).map({ ids[$0] }) where !selection.contains(id) { selection.toggle(id) }
        XCTAssertEqual(selection.ids, ["c0", "c1", "c2", "c3"])
    }
}

final class TemplateNamingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC

    func testPreviewExpandsEveryToken() {
        let out = TemplateNaming.preview(pattern: "{date} {name} {camera} {n}", templateName: "Headshots", cameraName: "X-T5", index: 7, now: date)
        XCTAssertTrue(out.hasSuffix("Headshots X-T5 007"), out)
        XCTAssertTrue(out.hasPrefix("2023-11-1"), out)
    }

    func testUnknownCameraFallsBackToCamera() {
        XCTAssertEqual(TemplateNaming.preview(pattern: "{camera}", templateName: "T", cameraName: nil, index: 1, now: date), "Camera")
        XCTAssertEqual(TemplateNaming.preview(pattern: "{camera}", templateName: "T", cameraName: "", index: 1, now: date), "Camera")
    }

    func testExpandMatchesCore() {
        let t = WorkspaceMemory.SessionTemplate(name: "Lookbook", namePattern: "{name}-{n}")
        XCTAssertEqual(TemplateNaming.expand(t, camera: nil, index: 12, now: date), t.sessionName(camera: nil, index: 12, now: date))
        XCTAssertEqual(TemplateNaming.expand(t, camera: nil, index: 12, now: date), "Lookbook-012")
    }

    func testNextIndexIsOneBased() {
        XCTAssertEqual(TemplateNaming.nextIndex(sessionCount: 0), 1)
        XCTAssertEqual(TemplateNaming.nextIndex(sessionCount: 4), 5)
    }
}

final class PaletteGroupingTests: XCTestCase {
    func testGroupsKeepFirstAppearanceOrder() {
        let cmds = [Commands.pick, Commands.tag, Commands.rate[0], Commands.export, Commands.addToCollection]
        let sections = PaletteGrouping.sections(cmds)
        XCTAssertEqual(sections.map(\.group), [.review, .organize, .export])
        XCTAssertEqual(sections[0].commands.map(\.id), ["flag.pick", "rate.1"])
        XCTAssertEqual(sections[1].commands.map(\.id), ["tag.add", "collection.add"])
        XCTAssertEqual(sections[0].title, "Review")
    }

    func testEmptyInputGivesNoSections() {
        XCTAssertTrue(PaletteGrouping.sections([]).isEmpty)
    }

    func testAvailableCommandsGroupWithoutLosingAny() {
        let ctx = CommandContext(selectionCount: 3, canUndo: true)
        let all = Commands.available(in: ctx)
        XCTAssertEqual(PaletteGrouping.sections(all).flatMap(\.commands).count, all.count)
    }
}

final class ShortcutParserTests: XCTestCase {
    func testPlainKeys() {
        XCTAssertEqual(ShortcutParser.parse("P"), ParsedShortcut(key: "p"))
        XCTAssertEqual(ShortcutParser.parse("5"), ParsedShortcut(key: "5"))
    }

    func testModifiers() {
        XCTAssertEqual(ShortcutParser.parse("⇧⌘E"), ParsedShortcut(key: "e", command: true, shift: true))
        XCTAssertEqual(ShortcutParser.parse("⌘A"), ParsedShortcut(key: "a", command: true))
    }

    func testSpecialKeysAndRejects() {
        XCTAssertEqual(ShortcutParser.parse("Space"), ParsedShortcut(key: " "))
        XCTAssertEqual(ShortcutParser.parse("⌫"), ParsedShortcut(key: ParsedShortcut.deleteKey))
        XCTAssertNil(ShortcutParser.parse(""))
        XCTAssertNil(ShortcutParser.parse("F13"))
    }
}

final class ExportScopePresetsTests: XCTestCase {
    func testLibraryPresetsIncludeSelectionAndCollection() {
        XCTAssertEqual(ExportScope.presets(selectionCount: 4, inCollection: true).map(\.id), ["all", "picks", "rated3", "selection", "collection"])
        XCTAssertEqual(ExportScope.presets(selectionCount: 0, inCollection: false).map(\.id), ["all", "picks", "rated3", "selected"])
        XCTAssertEqual(ExportScope.selection(4).title, "Selection (4)")
    }

    func testMemoryRestoreRespectsContext() {
        XCTAssertEqual(ExportScope.from(memory: "rated4", selectionCount: 0, inCollection: false), .rated(min: 4))
        XCTAssertNil(ExportScope.from(memory: "selection", selectionCount: 0, inCollection: false))
        XCTAssertEqual(ExportScope.from(memory: "selection", selectionCount: 2, inCollection: false), .selection(2))
        XCTAssertNil(ExportScope.from(memory: "bogus", selectionCount: 0, inCollection: false))
    }

    func testSelectionScopeFiltersByIDs() {
        let a = CaptureItem(sessionID: "s", sequence: 1, handle: 1, filename: "A.JPG", kind: .jpeg, bytes: 1, state: .ready, source: .usb)
        let b = CaptureItem(sessionID: "s", sequence: 2, handle: 2, filename: "B.JPG", kind: .jpeg, bytes: 1, state: .ready, source: .usb)
        XCTAssertEqual(ExportScope.selection(1).filter([a, b], selectedID: nil, selectionIDs: [b.id]).map(\.filename), ["B.JPG"])
    }
}
