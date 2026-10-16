import XCTest
@testable import TetherCore

final class InteropTests: XCTestCase {
    func capture(_ name: String, rating: Int = 4, flag: CaptureFlag = .pick, label: ColorLabel = .blue, kind: MediaKind = .jpeg) -> CaptureItem {
        var c = CaptureItem(sessionID: "s", sequence: 7, handle: 7, filename: name, kind: kind, bytes: 10,
                            capturedAt: Date(timeIntervalSince1970: 1_792_000_000), source: .usb)
        c.rating = rating; c.flag = flag; c.colorLabel = label; c.state = .ready
        return c
    }

    // MARK: XMP

    func testXMPRoundTripUsesTheConventionsOtherToolsRead() throws {
        let profile = MetadataProfile(creator: "Brady Jordan", copyright: "© {year} Brady Jordan", captionTemplate: "{session} · {date}", hierarchicalRoot: "Tether")
        let p = XMPPacket(capture: capture("IMG_0007.JPG"), tags: ["hero", "cover"], profile: profile, sessionName: "Lookbook AW26")
        let xml = p.serialized()
        XCTAssertTrue(xml.contains("<xmp:Rating>4</xmp:Rating>"))
        XCTAssertTrue(xml.contains("<xmp:Label>Blue</xmp:Label>"))
        XCTAssertTrue(xml.contains("<photomechanic:ColorClass>4</photomechanic:ColorClass>"))
        XCTAssertTrue(xml.contains("<photomechanic:Tagged>True</photomechanic:Tagged>"))
        XCTAssertTrue(xml.contains("<rdf:li>Tether|hero</rdf:li>"))
        XCTAssertTrue(xml.contains("<rdf:li>Lookbook AW26</rdf:li>"), "session as keyword")
        XCTAssertTrue(xml.contains("Lookbook AW26 · 2026-10-14") || xml.contains("Lookbook AW26 · 2026-10-15"), "caption template rendered")
        XCTAssertTrue(xml.contains("<?xpacket begin="))

        let back = try XMPPacket(parsing: p.data)
        XCTAssertEqual(back.rating, 4); XCTAssertEqual(back.label, .blue); XCTAssertTrue(back.pick)
        XCTAssertEqual(Set(back.keywords), ["hero", "cover", "Lookbook AW26"])
        XCTAssertEqual(back.hierarchicalKeywords, ["Tether|hero", "Tether|cover"])
        XCTAssertEqual(back.creator, "Brady Jordan"); XCTAssertEqual(back.copyright, profile.copyrightLine(), "{year} is resolved, not written literally")
        XCTAssertFalse(xml.contains("{year}"))
        XCTAssertEqual(back.headline, "Lookbook AW26")
        XCTAssertEqual(back.createDate?.timeIntervalSince1970, 1_792_000_000)
    }

    func testRejectBecomesMinusOneAndParsesBackAsReject() throws {
        let p = XMPPacket(capture: capture("A.JPG", rating: 3, flag: .reject, label: .none), tags: [], profile: MetadataProfile(), sessionName: nil)
        XCTAssertEqual(p.rating, -1)
        var c = capture("A.JPG", rating: 0, flag: .none, label: .none)
        _ = try XMPPacket(parsing: p.data).applied(to: &c)
        XCTAssertEqual(c.flag, .reject); XCTAssertEqual(c.rating, 0)
    }

    func testParsesLightroomAndCaptureOneStyleSidecars() throws {
        let lightroom = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/" xmp:Rating="5" xmp:Label="Red" xmp:CreatorTool="Adobe Photoshop Lightroom Classic 13.0">
           <dc:subject><rdf:Bag><rdf:li>studio</rdf:li><rdf:li>headshot</rdf:li></rdf:Bag></dc:subject>
           <lr:hierarchicalSubject><rdf:Bag><rdf:li>Clients|Acme</rdf:li></rdf:Bag></lr:hierarchicalSubject>
           <dc:creator><rdf:Seq><rdf:li>Someone Else</rdf:li></rdf:Seq></dc:creator>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let p = try XMPPacket(parsing: Data(lightroom.utf8))
        XCTAssertEqual(p.rating, 5); XCTAssertEqual(p.label, .red); XCTAssertFalse(p.pick)
        XCTAssertEqual(p.keywords, ["studio", "headshot"]); XCTAssertEqual(p.creator, "Someone Else")
        var c = capture("x.jpg", rating: 0, flag: .none, label: .none)
        XCTAssertEqual(p.applied(to: &c), ["studio", "headshot"])
        XCTAssertEqual(c.rating, 5); XCTAssertEqual(c.colorLabel, .red)
        // Photo Mechanic colour class without a Lightroom label.
        let pm = lightroom.replacingOccurrences(of: " xmp:Label=\"Red\"", with: "").replacingOccurrences(of: "<dc:creator>", with: "<photomechanic:ColorClass xmlns:photomechanic=\"http://ns.camerabits.com/photomechanic/1.0/\">3</photomechanic:ColorClass><dc:creator>")
        XCTAssertEqual(try XMPPacket(parsing: Data(pm.utf8)).label, .green)
        XCTAssertThrowsError(try XMPPacket(parsing: Data("<not xml".utf8)))
    }

    func testJPEGEmbedReplacesAndKeepsExifFirst() throws {
        var jpeg = Data([0xFF, 0xD8])
        jpeg.append(EXIFWriter.minimalJPEGExif(make: "Canon", model: "EOS R5", dateTimeOriginal: Date(timeIntervalSince1970: 1_792_000_000), exposureTime: 1 / 250, fNumber: 2.8, iso: 400))
        jpeg.append(Data([0xFF, 0xDB, 0x00, 0x04, 0x00, 0x00]))      // DQT stub
        jpeg.append(Data([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9])) // SOS + "scan" + EOI
        let p1 = XMPPacket(rating: 2, keywords: ["one"])
        let once = try JPEGXMP.embed(p1, in: jpeg)
        XCTAssertEqual(try JPEGXMP.extract(from: once).rating, 2)
        XCTAssertEqual([UInt8](once.prefix(4)), [0xFF, 0xD8, 0xFF, 0xE1], "Exif APP1 still first")
        let exif = try EXIFReader.read(once)
        XCTAssertEqual(exif.model, "EOS R5"); XCTAssertEqual(exif.iso, 400)
        let twice = try JPEGXMP.embed(XMPPacket(rating: 5), in: once)
        XCTAssertEqual(try JPEGXMP.extract(from: twice).rating, 5)
        XCTAssertEqual(twice.count - once.count, XMPPacket(rating: 5).data.count - p1.data.count, "old packet replaced, not duplicated")
        XCTAssertTrue(twice.suffix(2) == Data([0xFF, 0xD9]), "image data intact")
        XCTAssertThrowsError(try JPEGXMP.extract(from: jpeg))
        XCTAssertThrowsError(try JPEGXMP.embed(p1, in: Data([1, 2, 3])))
    }

    func testEXIFReader() throws {
        var jpeg = Data([0xFF, 0xD8])
        jpeg.append(EXIFWriter.minimalJPEGExif(make: "SONY", model: "ILCE-7M4", dateTimeOriginal: EXIFReader.parseDate("2026:10:16 09:41:00")!, exposureTime: 1 / 8000, fNumber: 1.8, iso: 100))
        jpeg.append(Data([0xFF, 0xD9]))
        let e = try EXIFReader.read(jpeg)
        XCTAssertEqual(e.cameraLine, "SONY ILCE-7M4")
        XCTAssertEqual(e.exposureLine, "1/8000  ƒ/1.8  ISO 100")
        XCTAssertEqual(e.dateTimeOriginal, EXIFReader.parseDate("2026:10:16 09:41:00"))
        XCTAssertThrowsError(try EXIFReader.read(Data([0xFF, 0xD8, 0xFF, 0xD9])))
    }

    // MARK: Naming, layouts, manifest

    func testNamingTemplatesAndSafety() {
        let c = capture("IMG_0007.CR3", kind: .raw)
        XCTAssertEqual(NamingTemplate("{session}_{seq:4}").render(capture: c, sessionName: "Lookbook AW26", index: 7), "Lookbook AW26_0007")
        XCTAssertEqual(NamingTemplate("{client}/{orig}").render(capture: c, sessionName: nil, index: 1, client: "Acme: Fall"), "Acme_ Fall/IMG_0007")
        XCTAssertEqual(NamingTemplate("{rating}{label}{pick}{kind}").render(capture: c, sessionName: nil, index: 1), "4bluepickraw")
        XCTAssertEqual(NamingTemplate("{seq}").render(capture: c, sessionName: nil, index: 12), "0012")
        XCTAssertEqual(NamingTemplate("").render(capture: c, sessionName: nil, index: 1), "IMG_0007", "empty pattern falls back to the original")
        XCTAssertEqual(NamingTemplate.safe("a/b\\c:d*e?f\"g<h>i|j"), "a_b_c_d_e_f_g_h_i_j")
        XCTAssertEqual(FolderLayout.captureOne.directory(for: c, sessionName: "AW26"), "AW26/Selects")
        XCTAssertEqual(FolderLayout.captureOne.directory(for: capture("x", flag: .reject), sessionName: "AW26"), "AW26/Trash")
        XCTAssertEqual(FolderLayout.captureOne.directory(for: capture("x", flag: .none), sessionName: "AW26"), "AW26/Capture")
        XCTAssertEqual(FolderLayout.captureOne.scaffold(sessionName: "AW26").count, 4)
        XCTAssertEqual(FolderLayout.byRating.directory(for: capture("x", rating: 1), sessionName: nil), "1 star")
        XCTAssertTrue(FolderLayout.dated.directory(for: c, sessionName: nil).hasPrefix("2026/2026-10-1"))
    }

    func testManifestJSONAndCSV() throws {
        var s = ShootSession(name: "Headshots, \"Studio B\"")
        s.workflowTag = "booking-42"
        let caps = [capture("A.JPG"), capture("B.CR3", rating: 0, flag: .none, label: .none, kind: .raw)]
        let m = SessionManifest(session: s, captures: caps, tags: [caps[0].id: ["hero", "a;b"]], collections: [caps[0].id: ["Client selects"]], exportedNames: [caps[0].id: "AW26_0007.JPG"])
        let csv = m.csv()
        let lines = csv.split(separator: "\r\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("\"A.JPG\",\"AW26_0007.JPG\",jpeg,4,pick,blue,\"hero;a;b\",\"Client selects\","))
        let json = try m.json()
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(obj?["workflowTag"] as? String, "booking-42")
        XCTAssertEqual((obj?["rows"] as? [[String: Any]])?.count, 2)
    }

    // MARK: End to end through the export queue

    final class FolderSink: ExportSink, @unchecked Sendable {
        let root: URL
        init(root: URL) { self.root = root }
        func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String? {
            let dest = root.appendingPathComponent(item.deliveredRelativePath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: fileURL, to: dest)
            return dest.path
        }
    }

    func testExportWritesCaptureOneTreeSidecarsEmbeddedXMPAndManifest() async throws {
        let store = try SessionStore.inMemory()
        let memory = WorkspaceMemory(store: store)
        memory.set(WorkspaceMemory.metadataProfile, MetadataProfile(creator: "Brady Jordan", writeSidecarsForJPEG: true))
        let cache = CaptureCacheProxy(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("tether-io-\(UUID().uuidString)"))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tether-io-out-\(UUID().uuidString)")
        let shoot = ShootSession(name: "AW26")
        try store.save(shoot)
        var jpeg = CaptureItem(sessionID: shoot.id, sequence: 1, handle: 1, filename: "IMG_0001.JPG", kind: .jpeg, bytes: 0, source: .usb)
        var jpegData = Data([0xFF, 0xD8]); jpegData.append(Data([0xFF, 0xDA, 0x00, 0x02, 0x00, 0xFF, 0xD9]))
        jpeg.relativePath = try cache.store(jpegData, at: cache.originalPath(session: shoot, filename: jpeg.filename))
        jpeg.state = .ready; jpeg.flag = .pick; jpeg.rating = 5
        try store.save(jpeg)
        var raw = CaptureItem(sessionID: shoot.id, sequence: 2, handle: 2, filename: "IMG_0001.CR3", kind: .raw, bytes: 0, source: .usb)
        raw.relativePath = try cache.store(Data([1, 2, 3]), at: cache.originalPath(session: shoot, filename: raw.filename))
        raw.state = .ready; raw.flag = .pick; raw.rating = 5
        try store.save(raw)
        try store.addTags(["hero"], to: [jpeg.id, raw.id])

        let queue = ExportQueue(store: store, cache: cache, sink: FolderSink(root: out), looks: LookResolver(store: store), memory: memory)
        let options = ExportOptions(includeRAW: true, naming: NamingTemplate("{session}_{seq:3}"), layout: .captureOne, writeManifest: true)
        let job = await queue.makeJob(session: shoot, captures: [jpeg, raw], destination: .files, options: options, look: .none)
        XCTAssertEqual(job.items.map { $0.deliveredRelativePath }, ["AW26/Selects/AW26_001.JPG", "AW26/Selects/AW26_001.CR3"],
                       "RAW+JPEG twins keep one base name so Lightroom / Capture One re-pair them")
        try await queue.enqueue(job)
        for await ev in queue.events { if case .finished(let j) = ev { XCTAssertEqual(j.status.key, "completed"); break } }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("AW26/Selects/AW26_001.JPG").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("AW26/Selects/AW26_001.CR3").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("AW26/Selects/AW26_001.xmp").path), "one sidecar for the pair")
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent("AW26/Selects/AW26_001-1.xmp").path), "no duplicate sidecar")
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("AW26/Output/AW26-manifest.json").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("AW26/Output/AW26-manifest.csv").path))
        let stamped = try Data(contentsOf: out.appendingPathComponent("AW26/Selects/AW26_001.JPG"))
        let packet = try JPEGXMP.extract(from: stamped)
        XCTAssertEqual(packet.rating, 5); XCTAssertTrue(packet.pick); XCTAssertEqual(packet.creator, "Brady Jordan")
        XCTAssertTrue(packet.keywords.contains("hero"))
        let side = try XMPPacket(parsing: Data(contentsOf: out.appendingPathComponent("AW26/Selects/AW26_001.xmp")))
        XCTAssertEqual(side.rating, 5)
        XCTAssertEqual(try store.count(matching: CaptureFilter(exportedTo: .files)), 2, "companions are not recorded as exports")
    }

    func testIngestAdoptsSidecarMetadata() async throws {
        let store = try SessionStore.inMemory()
        let cache = CaptureCacheProxy(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("tether-ing-\(UUID().uuidString)"))
        var shoot = ShootSession(name: "FTP"); shoot.transport = .ftpPush
        try store.save(shoot)
        let live = TetherSession(session: shoot, identity: nil, handler: nil, engine: nil, store: store, cache: cache)
        try await live.start()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("DSC00042.ARW")
        try Data([1, 2, 3]).write(to: file)
        try XMPPacket(rating: 3, label: .yellow, pick: true, keywords: ["press"]).data.write(to: dir.appendingPathComponent("DSC00042.xmp"))
        await live.ingestFile(at: file, from: "cam")
        let item = try store.captures(in: shoot.id)[0]
        XCTAssertEqual(item.rating, 3); XCTAssertEqual(item.colorLabel, .yellow); XCTAssertEqual(item.flag, .pick)
        XCTAssertEqual(try store.tags(for: item.id), ["press"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("DSC00042.xmp").path), "sidecar consumed")
        // Embedded packet in a pushed JPEG.
        var jpg = Data([0xFF, 0xD8]); jpg.append(Data([0xFF, 0xDA, 0x00, 0x02, 0x00, 0xFF, 0xD9]))
        let stamped = try JPEGXMP.embed(XMPPacket(rating: 1, keywords: ["b-roll"]), in: jpg)
        let f2 = dir.appendingPathComponent("DSC00043.JPG")
        try stamped.write(to: f2)
        await live.ingestFile(at: f2, from: "cam")
        let item2 = try store.captures(in: shoot.id)[1]
        XCTAssertEqual(item2.rating, 1); XCTAssertEqual(try store.tags(for: item2.id), ["b-roll"])

        // Sidecar pushed before its RAW+JPEG pair: not a frame, applied to both halves.
        try XMPPacket(rating: 4, label: .green).data.write(to: dir.appendingPathComponent("DSC00050.xmp"))
        await live.ingestFile(at: dir.appendingPathComponent("DSC00050.xmp"), from: "cam")
        XCTAssertEqual(try store.captures(in: shoot.id).count, 2, "a lone sidecar is not a capture")
        try Data([4, 5]).write(to: dir.appendingPathComponent("DSC00050.ARW"))
        await live.ingestFile(at: dir.appendingPathComponent("DSC00050.ARW"), from: "cam")
        try stamped.write(to: dir.appendingPathComponent("DSC00050.JPG"))
        await live.ingestFile(at: dir.appendingPathComponent("DSC00050.JPG"), from: "cam")
        let pair = try store.captures(in: shoot.id).filter { $0.pairKey == "DSC00050" }
        XCTAssertEqual(pair.count, 2)
        XCTAssertTrue(pair.allSatisfy { $0.rating == 4 && $0.colorLabel == .green }, "both halves took the early sidecar")

        // Sidecar pushed after the photo updates it.
        try XMPPacket(rating: 2).data.write(to: dir.appendingPathComponent("DSC00043.xmp"))
        await live.ingestFile(at: dir.appendingPathComponent("DSC00043.xmp"), from: "cam")
        XCTAssertEqual(try store.captures(in: shoot.id).first { $0.filename == "DSC00043.JPG" }?.rating, 2)
    }
}
