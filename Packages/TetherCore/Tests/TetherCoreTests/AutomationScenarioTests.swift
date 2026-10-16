import XCTest
@testable import TetherCore

/// "I set it up once and it just happens": template tags and collections on
/// arrival, auto-export of picks as one debounced job, memory learning on end.
final class AutomationScenarioTests: XCTestCase {
    final class CountingSink: ExportSink, @unchecked Sendable {
        let lock = NSLock(); var delivered: [String] = []
        func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String? {
            lock.lock(); delivered.append(item.id); lock.unlock(); return "ph-\(item.id)"
        }
    }

    func makeWorld() throws -> (SessionStore, WorkspaceMemory, ReviewEditor, ExportQueue, CountingSink, CaptureCacheProxy, TetherSession, ShootSession, ScriptedTransport) {
        let store = try SessionStore.inMemory()
        let memory = WorkspaceMemory(store: store)
        let editor = ReviewEditor(store: store, memory: memory)
        let cache = CaptureCacheProxy(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("tether-auto-\(UUID().uuidString)"))
        let sink = CountingSink()
        let queue = ExportQueue(store: store, cache: cache, sink: sink, looks: LookResolver(store: store))
        let t = ScriptedTransport()
        let payload = Data.fakeJPEG(size: 400)
        t.on(.getObjectInfo) { req in .ok(PTPObjectInfo(objectFormat: .exifJPEG, objectCompressedSize: UInt32(payload.count), filename: String(format: "IMG_%04d.JPG", req.parameters[0])).encoded) }
        t.on(.getPartialObject) { req in let o = Int(req.parameters[1]), w = Int(req.parameters[2]); return .ok(payload[o ..< min(payload.count, o + w)]) }
        var shoot = ShootSession(name: "Headshots")
        shoot.routing.autoExportPicks = true
        try store.save(shoot)
        let live = TetherSession(session: shoot, identity: nil, handler: nil, engine: nil, store: store, cache: cache)
        return (store, memory, editor, queue, sink, cache, live, shoot, t)
    }

    /// Pushes a fake frame straight into the session as a ready capture.
    func land(_ live: TetherSession, _ store: SessionStore, _ cache: CaptureCacheProxy, _ shoot: ShootSession, n: Int) async throws -> CaptureItem {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_\(n).JPG")
        try Data.fakeJPEG(size: 300).write(to: tmp)
        await live.ingestFile(at: tmp, from: "test")
        return try store.captures(in: shoot.id).last!
    }

    func testTemplateTagsCollectionAndAutoExportPicks() async throws {
        let (store, memory, editor, queue, sink, cache, live, shoot, _) = try makeWorld()
        let clientSet = try await editor.createCollection(named: "Headshots delivery", with: [])
        var rules = SessionAutomations.Rules(tags: ["headshots", "Studio B"], addToCollectionID: clientSet.id, autoExportPicks: true, debounce: 0.15)
        rules.autoExportDestination = .photos
        let auto = SessionAutomations(session: shoot, rules: rules, store: store, editor: editor, queue: queue, memory: memory)
        await editor.attach(session: live)
        await auto.attach(to: live)
        try await live.start()

        let a = try await land(live, store, cache, shoot, n: 1)
        let b = try await land(live, store, cache, shoot, n: 2)
        _ = try await land(live, store, cache, shoot, n: 3)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try store.tags(for: a.id), ["headshots", "studio-b"], "template tags applied, normalised")
        XCTAssertEqual(try store.count(in: clientSet), 3, "every frame joined the template's collection")

        // Two picks in quick succession → one export job with two items.
        try await editor.flag([a.id], .pick)
        try await editor.flag([b.id], .pick)
        var queued: ExportJob?
        for await ev in auto.events { if case .exportQueued(let j) = ev { queued = j; break } }
        XCTAssertEqual(queued?.items.count, 2)
        XCTAssertEqual(queued?.destination, .photos)
        for await ev in queue.events { if case .finished = ev { break } }
        XCTAssertEqual(Set(sink.delivered), [a.id, b.id])
        XCTAssertEqual(try store.count(matching: CaptureFilter(exportedTo: .photos)), 2)

        // Un-pick and re-pick does not export twice.
        try await editor.flag([a.id], .none)
        try await editor.flag([a.id], .pick)
        try await Task.sleep(nanoseconds: 300_000_000)
        let pending = await auto.pendingPickCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(sink.delivered.count, 2)

        // Ending the session teaches memory and flushes nothing extra.
        await live.stop(ended: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(memory.get(WorkspaceMemory.sessionDefaults).autoExportPicks)
        await auto.stop()
    }

    func testRulesComeFromTemplateAndLastExport() throws {
        let store = try SessionStore.inMemory()
        let memory = WorkspaceMemory(store: store)
        var e = WorkspaceMemory.ExportMemory(); e.destination = .files; e.options.includeRAW = true
        memory.set(WorkspaceMemory.lastExport, e)
        var t = WorkspaceMemory.SessionTemplate(name: "Lookbook", tags: ["lookbook"]); t.addToCollectionID = "c1"
        var s = ShootSession(name: "x"); s.routing.autoExportPicks = true
        let r = SessionAutomations.Rules.from(template: t, session: s, memory: memory)
        XCTAssertEqual(r.tags, ["lookbook"]); XCTAssertEqual(r.addToCollectionID, "c1")
        XCTAssertTrue(r.autoExportPicks); XCTAssertEqual(r.autoExportDestination, .files); XCTAssertTrue(r.autoExportOptions.includeRAW)
        var d = memory.get(WorkspaceMemory.sessionDefaults); d.tags = ["default"]; memory.set(WorkspaceMemory.sessionDefaults, d)
        XCTAssertEqual(SessionAutomations.Rules.from(template: nil, session: s, memory: memory).tags, ["default"])
    }
}
