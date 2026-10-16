import XCTest
@testable import TetherCore

final class CatalogTests: XCTestCase {
    private func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString)-\(name)").path
    }

    /// The subset of the Lightroom Classic schema the reader uses.
    private func makeLightroomCatalog() throws -> String {
        let path = tempPath("Shoots.lrcat")
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT, name TEXT)")
        try db.execute("CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, pathFromRoot TEXT, rootFolder INTEGER)")
        try db.execute("CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, baseName TEXT, extension TEXT, folder INTEGER)")
        try db.execute("CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, rating REAL, pick REAL, colorLabels TEXT)")
        try db.execute("CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER, tag INTEGER)")
        try db.execute("INSERT INTO AgLibraryRootFolder VALUES (1, '/Volumes/SSD/Shoots/', 'Shoots')")
        try db.execute("INSERT INTO AgLibraryFolder VALUES (1, 'AW26/', 1)")
        try db.execute("INSERT INTO AgLibraryFile VALUES (1, 'IMG_0001', 'CR3', 1), (2, 'AW26_002', 'JPG', 1), (3, 'NOT_OURS', 'NEF', 1)")
        try db.execute("INSERT INTO Adobe_images VALUES (10, 1, 4, 1, 'Blue'), (11, 2, NULL, -1, ''), (12, 3, 5, 0, 'Red')")
        try db.execute("INSERT INTO AgLibraryKeyword VALUES (1, 'hero'), (2, 'cover')")
        try db.execute("INSERT INTO AgLibraryKeywordImage VALUES (1, 10, 1), (2, 10, 2)")
        return path
    }

    func testReadsLightroomCatalog() throws {
        let path = try makeLightroomCatalog()
        let entries = try CatalogReader.entries(at: URL(fileURLWithPath: path))
        let first = try XCTUnwrap(entries.first { $0.filename == "IMG_0001.CR3" })
        XCTAssertEqual(first.rating, 4)
        XCTAssertEqual(first.flag, .pick)
        XCTAssertEqual(first.label, .blue)
        XCTAssertEqual(Set(first.keywords), ["hero", "cover"])
        XCTAssertEqual(first.folder, "/Volumes/SSD/Shoots/AW26/")
        let second = try XCTUnwrap(entries.first { $0.filename == "AW26_002.JPG" })
        XCTAssertEqual(second.rating, 0); XCTAssertEqual(second.flag, .reject); XCTAssertEqual(second.label, ColorLabel.none)
    }

    func testCatalogIsNeverTouchedAndUncheckpointedChangesAreRead() throws {
        let path = try makeLightroomCatalog()
        // Lightroom still has it open: its latest edit is only in the WAL.
        let writer = try SQLiteDatabase(path: path)
        try writer.execute("UPDATE Adobe_images SET rating = 3 WHERE id_local = 12")
        let files = [path, path + "-wal", path + "-shm"].filter { FileManager.default.fileExists(atPath: $0) }
        let before = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

        let entries = try CatalogReader.entries(at: URL(fileURLWithPath: path))
        XCTAssertEqual(entries.first { $0.filename == "NOT_OURS.NEF" }?.rating, 3, "reads what is still in the WAL")
        XCTAssertEqual(try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, before, "catalog files unchanged")

        let snapshot = try SQLiteDatabase.snapshot(of: path)
        XCTAssertThrowsError(try snapshot.execute("INSERT INTO AgLibraryKeyword VALUES (9, 'x')"), "query-only")
        _ = writer
    }

    func testMatchesByCameraNameAndExportedName() throws {
        let entries = try CatalogReader.entries(at: URL(fileURLWithPath: try makeLightroomCatalog()))
        var raw = CaptureItem(sessionID: "s", sequence: 1, handle: 1, filename: "IMG_0001.CR3", kind: .raw, bytes: 0, source: .usb)
        raw.rating = 2
        let jpeg = CaptureItem(sessionID: "s", sequence: 2, handle: 2, filename: "IMG_0002.JPG", kind: .jpeg, bytes: 0, source: .usb)
        let result = CatalogMatcher.changes(entries: entries, captures: [raw, jpeg],
                                            exportedNames: ["aw26_002.jpg": jpeg.id], tags: { $0 == raw.id ? ["hero"] : [] })
        XCTAssertEqual(result.unmatched, ["NOT_OURS.NEF"])
        let r = try XCTUnwrap(result.changes.first { $0.captureID == raw.id })
        XCTAssertEqual(r.rating, 4); XCTAssertEqual(r.flag, .pick); XCTAssertEqual(r.label, .blue)
        XCTAssertEqual(r.newKeywords, ["cover"], "only keywords not already on the frame")
        let j = try XCTUnwrap(result.changes.first { $0.captureID == jpeg.id }, "matched through the exported name")
        XCTAssertEqual(j.flag, .reject)
        XCTAssertNil(j.rating, "no change when equal")
    }

    func testReadsCaptureOneStyleSchemaWithVariantTable() throws {
        let path = tempPath("Session.cosessiondb")
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY, ZIMAGEFILENAME TEXT)")
        try db.execute("CREATE TABLE ZVARIANT (Z_PK INTEGER PRIMARY KEY, ZIMAGE INTEGER, ZRATING INTEGER, ZCOLORTAG INTEGER)")
        try db.execute("INSERT INTO ZIMAGE VALUES (1, 'IMG_0001.CR3'), (2, 'IMG_0002.CR3')")
        try db.execute("INSERT INTO ZVARIANT VALUES (1, 1, 5, 4), (2, 1, 1, 0), (3, 2, 0, 2)")
        let entries = try CatalogReader.entries(at: URL(fileURLWithPath: path))
        XCTAssertEqual(entries.count, 2, "one entry per image (first variant)")
        let a = try XCTUnwrap(entries.first { $0.filename == "IMG_0001.CR3" })
        XCTAssertEqual(a.rating, 5); XCTAssertEqual(a.label, .green)
        let b = try XCTUnwrap(entries.first { $0.filename == "IMG_0002.CR3" })
        XCTAssertNil(b.label, "orange has no equivalent; left alone")
    }

    func testDetectsKindsAndRejectsOthers() {
        XCTAssertEqual(CatalogKind.detect(URL(fileURLWithPath: "/a/Shoots.lrcat")), .lightroom)
        XCTAssertEqual(CatalogKind.detect(URL(fileURLWithPath: "/a/Job.cocatalog")), .captureOne)
        XCTAssertEqual(CatalogKind.detect(URL(fileURLWithPath: "/a/Job.cosessiondb")), .captureOne)
        XCTAssertNil(CatalogKind.detect(URL(fileURLWithPath: "/a/photo.jpg")))
        XCTAssertEqual(StoredFolderDestination.detectKind(entries: ["Capture", "Selects", "Job.cosessiondb"]), .captureOneSession)
        XCTAssertEqual(StoredFolderDestination.detectKind(entries: ["Capture"]), .plain)
    }

    func testCaptureOneSessionRootLayout() {
        var c = CaptureItem(sessionID: "s", sequence: 1, handle: 1, filename: "A.CR3", kind: .raw, bytes: 0, source: .usb)
        XCTAssertEqual(FolderLayout.captureOneSessionRoot.directory(for: c, sessionName: "AW26"), "Capture")
        c.flag = .pick
        XCTAssertEqual(FolderLayout.captureOneSessionRoot.directory(for: c, sessionName: "AW26"), "Selects")
        XCTAssertEqual(FolderLayout.captureOneSessionRoot.manifestDirectory(sessionName: "AW26"), "Output")
        XCTAssertEqual(FolderLayout.captureOne.manifestDirectory(sessionName: "AW26"), "AW26/Output")
        XCTAssertEqual(FolderLayout.captureOneSessionRoot.scaffold(sessionName: "AW26"), ["Capture", "Selects", "Output", "Trash"])
    }
}
