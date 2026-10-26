import XCTest
@testable import TetherCore

final class FileImportPlanTests: XCTestCase {
    func testPairsBothSidecarSpellingsAndSkipsJunk() throws {
        let dir = URL(fileURLWithPath: "/shoot")
        let files = ["IMG_0002.CR3", "IMG_0002.xmp", "IMG_0001.JPG", "IMG_0001.CR3", "IMG_0001.CR3.xmp",
                     ".DS_Store", "AW26-manifest.json", "notes.txt", "orphan.xmp", "clip.MOV"].map { dir.appendingPathComponent($0) }
        let plan = FileImportPlan(files: files)
        XCTAssertEqual(plan.entries.map(\.file.lastPathComponent), ["clip.MOV", "IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.CR3"])
        let byName = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.file.lastPathComponent, $0.sidecar?.lastPathComponent) })
        XCTAssertEqual(byName["IMG_0001.CR3"], "IMG_0001.CR3.xmp", "darktable-style sidecar")
        XCTAssertEqual(byName["IMG_0002.CR3"], "IMG_0002.xmp", "Lightroom / Capture One style sidecar")
        XCTAssertEqual(byName["IMG_0001.JPG"], .some(nil))
        XCTAssertEqual(Set(plan.skipped.map(\.lastPathComponent)), ["AW26-manifest.json", "notes.txt", "orphan.xmp"])
    }

    func testFolderWalkFindsNestedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Capture/Day 1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("A.NEF"))
        try Data([1]).write(to: root.appendingPathComponent("B.JPG"))
        try Data([1]).write(to: root.appendingPathComponent(".hidden.JPG"))
        let names = FileImportPlan.files(under: root).map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["A.NEF", "B.JPG"])
    }
}
