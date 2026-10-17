import XCTest
@testable import TetherCore

/// Power-user "what if" scenarios. Each test is a story a working
/// photographer would recognise; the assertions are what must stay true.
final class LibraryScenarioTests: XCTestCase {
    var store: SessionStore!
    var memory: WorkspaceMemory!
    var editor: ReviewEditor!
    var sessionA: ShootSession!
    var sessionB: ShootSession!
    let canon = CameraIdentity(id: "canon-R5-1", vendor: .canon, manufacturer: "Canon", model: "EOS R5", serialNumber: "1", firmware: "1", transport: .usb, capabilities: [.remoteCapture])
    let sony = CameraIdentity(id: "sony-A7IV-1", vendor: .sony, manufacturer: "Sony", model: "ILCE-7M4", serialNumber: "2", firmware: "1", transport: .ptpip, capabilities: [.remoteCapture])

    override func setUpWithError() throws {
        store = try SessionStore.inMemory()
        memory = WorkspaceMemory(store: store)
        editor = ReviewEditor(store: store, memory: memory)
        sessionA = ShootSession(name: "Lookbook AW26")
        sessionA.camera = canon
        sessionB = ShootSession(name: "Headshots Studio B")
        sessionB.camera = sony
        try store.save(sessionA); try store.save(sessionB)
        // 60 RAW+JPEG pairs in A (ready), 40 JPEGs in B, 3 still downloading in B.
        for i in 1 ... 60 {
            for (ext, kind) in [("CR3", MediaKind.raw), ("JPG", .jpeg)] {
                var c = CaptureItem(sessionID: sessionA.id, sequence: i * 2 + (kind == .raw ? 0 : 1), handle: UInt32(i), filename: String(format: "IMG_%04d.%@", i, ext),
                                    kind: kind, bytes: 10, receivedAt: Date(timeIntervalSinceNow: -Double(3600 * 24 * 3) + Double(i)), source: .usb, cameraID: canon.id)
                c.state = .ready
                try store.save(c)
            }
        }
        for i in 1 ... 43 {
            var c = CaptureItem(sessionID: sessionB.id, sequence: i, handle: UInt32(1000 + i), filename: String(format: "DSC%05d.JPG", i), kind: .jpeg, bytes: 10,
                                receivedAt: Self.earlierToday(minutesAgo: i), source: .ptpip, cameraID: sony.id)
            c.state = i > 40 ? .downloading(received: 1, total: 10) : .ready
            try store.save(c)
        }
    }

    /// "i minutes ago", but never before midnight (the Today shelf test ran
    /// red in the first 43 minutes of each day).
    static func earlierToday(minutesAgo i: Int) -> Date {
        let now = Date()
        return max(now.addingTimeInterval(-60 * Double(i)), Calendar.current.startOfDay(for: now).addingTimeInterval(Double(i)))
    }

    func ids(_ filter: CaptureFilter) throws -> [String] { try store.captureIDs(matching: filter) }
    func jpegsA(_ n: Int) throws -> [String] { Array(try store.captures(matching: CaptureFilter(kinds: [.jpeg], sessionIDs: [sessionA.id]), sort: .captureTimeAscending).prefix(n).map(\.id)) }

    // MARK: Built-ins and filters

    func testBuiltInShelvesAreSeededAndCountCorrectly() throws {
        let all = try store.collections()
        XCTAssertEqual(all.filter(\.isBuiltIn).count, Collection.builtIns.count)
        let allPhotos = try store.collection("builtin.all")!
        XCTAssertEqual(try store.count(in: allPhotos), 120 + 40, "downloading frames are not library items yet")
        XCTAssertEqual(try store.count(in: try store.collection("builtin.unrated")!), 160)
        XCTAssertEqual(try store.count(in: try store.collection("builtin.today")!), 40, "session B shot today, A three days ago")
        XCTAssertThrowsError(try store.deleteCollection("builtin.picks"))
    }

    func testFilterCombinationsTranslateToSQL() throws {
        try store.addTags(["hero", "cover"], to: try jpegsA(5))
        try store.addTags(["hero"], to: try jpegsA(8))
        XCTAssertEqual(try store.count(matching: CaptureFilter(tagsAll: ["hero"])), 8)
        XCTAssertEqual(try store.count(matching: CaptureFilter(tagsAll: ["hero", "cover"])), 5)
        XCTAssertEqual(try store.count(matching: CaptureFilter(tagsAny: ["cover", "nope"])), 5)
        XCTAssertEqual(try store.count(matching: CaptureFilter(kinds: [.raw])), 60)
        XCTAssertEqual(try store.count(matching: CaptureFilter(cameraIDs: [sony.id])), 40)
        XCTAssertEqual(try store.count(matching: CaptureFilter(text: "headshots")), 40, "text searches the session name too")
        XCTAssertEqual(try store.count(matching: CaptureFilter(text: "IMG_0007")), 2)
        XCTAssertEqual(try store.count(matching: CaptureFilter(text: "%")), 0, "LIKE wildcards are escaped")
        XCTAssertEqual(try store.count(matching: CaptureFilter(dateRange: .last7Days)), 160)
        XCTAssertEqual(try store.count(matching: CaptureFilter(exportedTo: .never)), 160)
        let f = CaptureFilter(minRating: 4, flags: [.pick], colors: [.red, .blue], tagsAll: ["hero"], dateRange: .today, text: "x")
        XCTAssertEqual(f.summary, "4★+ · Pick · blue, red · #hero · today · “x”")
        XCTAssertTrue(CaptureFilter().isEmpty)
        // Paging
        XCTAssertEqual(try store.captures(matching: CaptureFilter(), sort: .filename, limit: 25, offset: 150).count, 10)
    }

    func testStacksPairRawAndJPEG() throws {
        let items = try store.captures(matching: CaptureFilter(sessionIDs: [sessionA.id]), sort: .captureTimeAscending)
        let stacks = CaptureStack.stack(items)
        XCTAssertEqual(stacks.count, 60)
        XCTAssertTrue(stacks.allSatisfy { $0.isPair && $0.top.kind == .jpeg })
        let mixed = CaptureStack.stack(try store.captures(matching: CaptureFilter(), sort: .sessionThenTime))
        XCTAssertEqual(mixed.count, 100)
    }

    // MARK: Scenario: culling 60 frames fast, then changing my mind

    func testBulkRatingSyncsPairsAndUndoRevertsTheWholeBatch() async throws {
        let twelve = try jpegsA(12)
        try await editor.rate(twelve, stars: 4)
        XCTAssertEqual(try store.count(matching: CaptureFilter(minRating: 4)), 24, "RAW twins follow their JPEG")
        try await editor.flag(Array(twelve.prefix(3)), .pick)
        XCTAssertEqual(try store.count(in: try store.collection("builtin.picks")!), 6)
        try await editor.label(Array(twelve.prefix(2)), .red)
        XCTAssertEqual(try store.count(matching: CaptureFilter(colors: [.red])), 2, "labels stay per file")

        let title = await editor.undoTitle
        XCTAssertEqual(title, "Label red")
        try await editor.undo()
        XCTAssertEqual(try store.count(matching: CaptureFilter(colors: [.red])), 0)
        try await editor.undo()
        XCTAssertEqual(try store.count(in: try store.collection("builtin.picks")!), 0, "one undo clears the whole pick batch")
        try await editor.undo()
        XCTAssertEqual(try store.count(matching: CaptureFilter(minRating: 4)), 0)
        let canUndo = await editor.canUndo
        XCTAssertFalse(canUndo)
        try await editor.redo(); try await editor.redo()
        XCTAssertEqual(try store.count(matching: CaptureFilter(minRating: 4)), 24)
        XCTAssertEqual(try store.count(in: try store.collection("builtin.picks")!), 6)
        // A new edit after undo discards the redo branch.
        try await editor.rate([twelve[0]], stars: 5)
        let canRedo = await editor.canRedo
        XCTAssertFalse(canRedo)
    }

    // MARK: Scenario: a client collection, a smart collection, and a deleted frame

    func testManualAndSmartCollectionsStayConsistentAcrossEdits() async throws {
        let picks = try jpegsA(10)
        let client = try await editor.createCollection(named: "Client selects", with: picks, tint: .blue)
        XCTAssertEqual(try store.count(in: client), 10)
        XCTAssertEqual(try store.collectionIDs(containing: picks[0]), [client.id])
        try await editor.add([picks[0]], to: client.id) // duplicate add is a no-op
        XCTAssertEqual(try store.count(in: client), 10)
        // Smart: 4★+ JPEGs from this session, updates live.
        let smart = try await editor.saveSmartCollection(named: "Best of lookbook", rule: CaptureFilter(minRating: 4, kinds: [.jpeg], sessionIDs: [sessionA.id]))
        XCTAssertEqual(try store.count(in: smart), 0)
        try await editor.rate(Array(picks.prefix(4)), stars: 5)
        XCTAssertEqual(try store.count(in: smart), 4)
        XCTAssertEqual(try store.captures(in: smart, narrowedBy: CaptureFilter(colors: [.red])).count, 0)
        // Hand order survives narrowing/sorting choices.
        try store.reorder(Array(picks.reversed()), in: client.id)
        XCTAssertEqual(try store.captures(in: client).map(\.id), picks.reversed())
        XCTAssertEqual(try store.captures(in: client, sort: .captureTimeAscending).map(\.id), picks)
        // Adding to a smart collection is refused clearly.
        do { try await editor.add(picks, to: smart.id); XCTFail() } catch { XCTAssertEqual(error as? LibraryError, .notManual) }
        // Deleting a capture removes it everywhere.
        try store.deleteCapture(picks[0])
        XCTAssertEqual(try store.count(in: client), 9)
        XCTAssertEqual(try store.count(in: smart), 3)
        XCTAssertTrue(try store.tags(for: picks[0]).isEmpty)
        // Undo of the add never removes frames that were already there.
        let extra = try jpegsA(12).suffix(2).map { $0 }
        try await editor.add(extra + [picks[1]], to: client.id)
        try await editor.undo()
        XCTAssertEqual(try store.count(in: client), 9, "picks[1] was present before the add and stays")
        // Deleting the collection leaves the photos alone.
        try store.deleteCollection(client.id)
        XCTAssertEqual(try store.count(matching: CaptureFilter(sessionIDs: [sessionA.id])), 119, "only the deleted frame is gone")
    }

    // MARK: Scenario: tagging with autocomplete and recents

    func testTagsNormaliseSuggestAndUndo() async throws {
        let some = try jpegsA(6)
        try await editor.addTags(["#Hero Shot", "cover"], to: some)
        XCTAssertEqual(try store.tags(for: some[0]), ["cover", "hero-shot"])
        try await editor.addTags(["cover"], to: try jpegsA(20))
        XCTAssertEqual(try store.tagSuggestions(prefix: "c"), ["cover"])
        XCTAssertEqual(try store.tagSuggestions().first, "cover", "most used first")
        XCTAssertEqual(memory.get(WorkspaceMemory.recents).tags.first, "cover")
        try await editor.undo()
        XCTAssertEqual(try store.count(matching: CaptureFilter(tagsAll: ["cover"])), 6)
        try await editor.removeTags(["hero-shot"], from: [some[0]])
        XCTAssertEqual(try store.tags(for: some[0]), ["cover"])
        try await editor.undo()
        XCTAssertEqual(try store.tags(for: some[0]), ["cover", "hero-shot"])
    }

    // MARK: Scenario: library edits reach the live shoot screen

    func testEditsPropagateToTheOpenSession() async throws {
        let cache = CaptureCacheProxy(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("tether-lib-\(UUID().uuidString)"))
        let live = TetherSession(session: sessionA, identity: canon, handler: nil, engine: nil, store: store, cache: cache)
        try await live.start()
        await editor.attach(session: live)
        let target = try jpegsA(1)[0]
        try await editor.rate([target], stars: 3)
        let snap = await live.snapshot
        XCTAssertEqual(snap.items.first { $0.id == target }?.rating, 3)
        XCTAssertEqual(snap.items.first { $0.pairKey == snap.items.first { $0.id == target }!.pairKey && $0.kind == .raw }?.rating, 3)
    }

    // MARK: Scenario: between-session memory

    func testTemplatesAndCameraMemoryShapeTheNextSession() throws {
        var first = ShootSession(name: "", destination: .host)
        first.lookID = "film-warm"; first.lookStrength = 0.8; first.showNewestCapture = false
        first.routing = RoutingRules(jpeg: .photos, raw: .ftp, autoExportPicks: true)
        first.camera = canon
        memory.learn(from: first)
        let d = memory.get(WorkspaceMemory.sessionDefaults)
        XCTAssertEqual(d.destination, .host)
        XCTAssertEqual(d.look.lookID, "film-warm")
        XCTAssertEqual(memory.camera(canon.id)?.look.strength, 0.8)

        var t = memory.template(from: first, name: "Lookbook")
        t.tags = ["lookbook"]
        t.namePattern = "{date} {name} {camera}"
        memory.save(template: t)
        var next = ShootSession(name: "")
        memory.configure(&next, with: memory.suggestedTemplate(for: canon), camera: canon, index: 2)
        XCTAssertEqual(next.destination, .host)
        XCTAssertTrue(next.name.hasSuffix("Lookbook EOS R5"))
        XCTAssertEqual(next.routing.raw, .ftp)
        XCTAssertEqual(memory.templates().first?.useCount, 1)
        XCTAssertEqual(memory.camera(canon.id)?.templateID, t.id)
        XCTAssertEqual(memory.suggestedTemplate(for: canon)?.id, t.id)
        // A different camera with no history still gets the most recent template.
        XCTAssertEqual(memory.suggestedTemplate(for: sony)?.id, t.id)
        // No template: the remembered defaults apply.
        var blank = ShootSession(name: "Blank")
        memory.configure(&blank, with: nil, camera: nil, index: 1)
        XCTAssertEqual(blank.lookID, "film-warm")
        memory.deleteTemplate(t.id)
        XCTAssertTrue(memory.templates().isEmpty)
    }

    func testViewStateExposureAndExportMemoryPersistAcrossRelaunch() throws {
        var v = WorkspaceMemory.ViewState()
        v.filter = CaptureFilter(minRating: 3); v.columns = 5; v.scrollToCaptureID = "abc"; v.sort = .ratingDescending
        memory.setViewState(v, for: "builtin.picks")
        memory.rememberExposure(cameraID: sony.id, [PropertyDescriptor(property: .iso, raw: .uint32(400), display: "400", isWritable: true, form: .other)])
        var e = WorkspaceMemory.ExportMemory(); e.destination = .ftp(destinationID: "nas"); e.options.includeRAW = true; e.scope = "selection"
        memory.set(WorkspaceMemory.lastExport, e)
        memory.noteSearch("hero"); memory.noteSearch("cover"); memory.noteSearch("hero")

        // "Relaunch": a fresh memory over the same store.
        let again = WorkspaceMemory(store: store)
        XCTAssertEqual(again.get(WorkspaceMemory.lastCollectionID), "builtin.picks")
        XCTAssertEqual(again.viewState(for: "builtin.picks").columns, 5)
        XCTAssertEqual(again.viewState(for: "builtin.picks").filter.minRating, 3)
        XCTAssertEqual(again.viewState(for: "builtin.all").columns, 3, "unknown views get defaults")
        XCTAssertEqual(again.camera(sony.id)?.lastExposure[.iso], "400")
        XCTAssertEqual(again.get(WorkspaceMemory.lastExport).destination, .ftp(destinationID: "nas"))
        XCTAssertEqual(again.get(WorkspaceMemory.recents).searches, ["hero", "cover"])
    }

    // MARK: Scenario: export history feeds the "not exported yet" shelf

    func testExportHistoryIsQueryable() throws {
        let three = try jpegsA(3)
        for id in three { try store.recordExport(captureID: id, destination: .photos, jobID: "job1", remoteID: "ph-\(id)") }
        try store.recordExport(captureID: three[0], destination: .ftp, jobID: "job2", remoteID: "/nas/a.jpg")
        XCTAssertEqual(try store.count(matching: CaptureFilter(exportedTo: .any)), 3)
        XCTAssertEqual(try store.count(matching: CaptureFilter(exportedTo: .ftp)), 1)
        XCTAssertEqual(try store.count(matching: CaptureFilter(exportedTo: .never)), 157)
        XCTAssertEqual(try store.exportHistory(captureID: three[0]).count, 2)
        let s = try store.libraryStats()
        XCTAssertEqual(s.captures, 160); XCTAssertEqual(s.sessions, 2); XCTAssertEqual(s.cameras, 2)
    }

    // MARK: Selection and commands

    func testSelectionMathAndCommandAvailability() {
        let order = (0 ..< 10).map { "f\($0)" }
        var s = Selection()
        s.replace(with: "f2"); s.extend(to: "f5", in: order)
        XCTAssertEqual(s.ids, ["f2", "f3", "f4", "f5"])
        s.toggle("f3"); XCTAssertEqual(s.count, 3)
        s.invert(in: order); XCTAssertEqual(s.count, 7); XCTAssertTrue(s.contains("f3"))
        s.keep(only: ["f3", "zzz"]); XCTAssertEqual(s.ids, ["f3"])
        s.selectAll(order); XCTAssertEqual(s.count, 10); s.clear(); XCTAssertTrue(s.isEmpty)

        let none = Commands.available(in: CommandContext())
        XCTAssertFalse(none.contains(Commands.pick)); XCTAssertTrue(none.contains(Commands.selectAll))
        let two = Commands.available(in: CommandContext(selectionCount: 2, canUndo: true))
        XCTAssertTrue(two.contains(Commands.compare)); XCTAssertTrue(two.contains(Commands.undo)); XCTAssertFalse(two.contains(Commands.colorMatch))
        let one = Commands.available(in: CommandContext(selectionCount: 1, inCollection: Collection(name: "x", kind: .manual)))
        XCTAssertTrue(one.contains(Commands.colorMatch)); XCTAssertTrue(one.contains(Commands.removeFromCollection))
        let live = Commands.available(in: CommandContext(inLiveSession: true, cameraCapabilities: [.remoteCapture]))
        XCTAssertEqual(live.first, Commands.capture); XCTAssertFalse(live.contains(Commands.liveView))
        XCTAssertEqual(Commands.search("5", in: CommandContext(selectionCount: 1)).first?.id, "rate.5")
        XCTAssertEqual(Commands.search("coll", in: CommandContext(selectionCount: 1)).map(\.id), ["collection.add", "collection.new"])
        XCTAssertTrue(Commands.available(in: CommandContext(selectionCount: 1, inLiveSession: true, cameraCapabilities: [])).contains(Commands.endSession))
    }

    // MARK: Scenario: a 20k-frame library stays fast

    func testLargeLibraryQueriesStayFast() throws {
        let big = try SessionStore.inMemory()
        let s = ShootSession(name: "Wedding")
        try big.save(s)
        try big.db.transaction {
            for i in 0 ..< 20_000 {
                var c = CaptureItem(sessionID: s.id, sequence: i, handle: UInt32(i), filename: "W\(i).JPG", kind: .jpeg, bytes: 1, source: .usb)
                c.state = .ready; c.rating = i % 6; c.flag = i % 7 == 0 ? .pick : .none
                try big.save(c)
            }
        }
        let t0 = Date()
        XCTAssertEqual(try big.count(matching: CaptureFilter(minRating: 4, flags: [.pick])), (0 ..< 20_000).filter { $0 % 6 >= 4 && $0 % 7 == 0 }.count)
        let page = try big.captures(matching: CaptureFilter(minRating: 3), sort: .ratingDescending, limit: 60, offset: 300)
        XCTAssertEqual(page.count, 60)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
    }
}
