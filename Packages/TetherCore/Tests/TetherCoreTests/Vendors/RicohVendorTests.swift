import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TetherCore

/// Canned HTTP for the Ricoh handler. Keyed by "METHOD path" (query kept).
final class FakeRicohHTTP: RicohHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Data, Int)] = [:]
    private(set) var requests: [URLRequest] = []
    var socketMessages: [String]?
    private(set) var streamChunk: (@Sendable (Data) -> Void)?
    private(set) var streamCancelled = false

    func respond(_ method: String, _ pathAndQuery: String, status: Int = 200, json: Any) {
        respond(method, pathAndQuery, status: status, body: try! JSONSerialization.data(withJSONObject: json))
    }

    func respond(_ method: String, _ pathAndQuery: String, status: Int = 200, body: Data) {
        lock.lock(); responses["\(method) \(pathAndQuery)"] = (body, status); lock.unlock()
    }

    static func key(_ r: URLRequest) -> String {
        let url = r.url!
        var p = url.path
        if let q = url.query { p += "?" + q }
        return "\(r.httpMethod ?? "GET") \(p)"
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); requests.append(request); let r = responses[Self.key(request)]; lock.unlock()
        return r ?? (Data(), 404)
    }

    func stream(_ request: URLRequest, onChunk: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) -> RicohStreamHandle {
        lock.lock(); requests.append(request); streamChunk = onChunk; lock.unlock()
        return Handle { [weak self] in self?.streamCancelled = true }
    }

    func webSocket(_ url: URL) -> RicohWebSocket? {
        guard let msgs = socketMessages else { return nil }
        lock.lock(); requests.append(URLRequest(url: url)); lock.unlock()
        return Socket(messages: msgs)
    }

    var bodies: [String: Data] {
        lock.lock(); defer { lock.unlock() }
        var out = [String: Data]()
        for r in requests { if let b = r.httpBody { out[Self.key(r)] = b } }
        return out
    }

    var keys: [String] { lock.lock(); defer { lock.unlock() }; return requests.map(Self.key) }

    final class Handle: RicohStreamHandle, @unchecked Sendable {
        let f: @Sendable () -> Void
        init(_ f: @escaping @Sendable () -> Void) { self.f = f }
        func cancel() { f() }
    }

    final class Socket: RicohWebSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String]
        init(messages: [String]) { self.messages = messages }
        func receiveText() async throws -> String {
            lock.lock(); defer { lock.unlock() }
            if messages.isEmpty { throw PTPError.transportClosed }
            return messages.removeFirst()
        }
        func cancel() {}
    }
}

final class RicohVendorTests: XCTestCase {
    static let props: [String: Any] = [
        "errCode": 200, "errMsg": "OK", "model": "RICOH GR III", "firmwareVersion": "1.41", "serialNo": "GR3-0001",
        "battery": ["level": 72], "av": "2.8", "tv": "1/250", "sv": "200", "xv": "-0.3", "WBMode": "auto",
        "avList": ["2.8", "4.0", "5.6"], "tvList": ["1/125", "1/250", "1/500"], "svList": ["auto", "100", "200"],
        "xvList": ["-0.3", "0.0", "0.3"], "WBModeList": ["auto", "daylight", "shade"],
    ]

    func makeHandler(socket: [String]? = nil) -> (RicohHandler, FakeRicohHTTP) {
        let http = FakeRicohHTTP()
        http.socketMessages = socket
        http.respond("GET", "/v1/props", json: Self.props)
        http.respond("GET", "/v1/photos", json: ["dirs": [["name": "100RICOH", "files": ["R0000001.JPG", "R0000001.DNG"]]]])
        http.respond("POST", "/v1/camera/shoot", json: ["errCode": 200, "errMsg": "OK"])
        http.respond("PUT", "/v1/params/camera", json: ["errCode": 200, "errMsg": "OK"])
        return (RicohHandler(baseURL: URL(string: "http://192.168.0.1")!, http: http), http)
    }

    func testPropsMapToIdentity() async throws {
        let (h, _) = makeHandler()
        let id = try await h.probeIdentity()
        XCTAssertEqual(id.vendor, .ricoh)
        XCTAssertEqual(id.transport, .ricohHTTP)
        XCTAssertEqual(id.model, "RICOH GR III")
        XCTAssertEqual(id.firmware, "1.41")
        XCTAssertEqual(id.serialNumber, "GR3-0001")
        XCTAssertEqual(id.id, "ricoh-GR3-0001")
        XCTAssertTrue(id.capabilities.contains(.remoteCapture))
        XCTAssertTrue(id.capabilities.contains(.liveView))
        XCTAssertFalse(id.capabilities.contains(.sdramCapture))
        let flat = try RicohProps(json: try JSONSerialization.data(withJSONObject: ["model": "RICOH GR II", "battery": 55]))
        XCTAssertEqual(flat.batteryPercent, 55)
    }

    func testShootPostsAFFlag() async throws {
        let (h, http) = makeHandler()
        try await h.capture(autofocus: true)
        try await h.capture(autofocus: false)
        let shoots = http.requests.filter { FakeRicohHTTP.key($0) == "POST /v1/camera/shoot" }
        XCTAssertEqual(shoots.count, 2)
        XCTAssertEqual(String(decoding: shoots[0].httpBody!, as: UTF8.self), "{\"af\":true}")
        XCTAssertEqual(String(decoding: shoots[1].httpBody!, as: UTF8.self), "{\"af\":false}")
        XCTAssertEqual(shoots[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        http.respond("POST", "/v1/camera/shoot", json: ["errCode": 500, "errMsg": "busy"])
        await XCTAssertThrowsPTP(try await h.capture(autofocus: true)) { e in XCTAssertTrue("\(e)".contains("busy")) }
    }

    func testMJPEGSplitterWithContentLengthAcrossChunks() {
        let j1 = Data.fakeJPEG(size: 300), j2 = Data.fakeJPEG(size: 120)
        var body = Data()
        for j in [j1, j2] {
            body.append(Data("--boundarydonotcross\r\nContent-Type: image/jpeg\r\nContent-Length: \(j.count)\r\n\r\n".utf8))
            body.append(j)
            body.append(Data("\r\n".utf8))
        }
        var s = MJPEGFrameSplitter()
        var frames = [Data]()
        var i = 0
        while i < body.count {
            let n = min(37, body.count - i)
            frames += s.feed(body.subdata(in: i ..< i + n))
            i += n
        }
        XCTAssertEqual(frames, [j1, j2])
        XCTAssertEqual(s.framesEmitted, 2)
    }

    func testMJPEGSplitterWithoutContentLengthUsesNextBoundary() {
        let j1 = Data.fakeJPEG(size: 64), j2 = Data.fakeJPEG(size: 80)
        var body = Data("--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(j1)
        body.append(Data("\r\n--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(j2)
        var s = MJPEGFrameSplitter()
        let first = s.feed(body)
        XCTAssertEqual(first, [j1]) // j2 waits for its closing boundary
        let rest = s.feed(Data("\r\n--frame\r\n".utf8))
        XCTAssertEqual(rest, [j2])
    }

    func testLiveViewFramesFlowThroughHandler() async throws {
        let (h, http) = makeHandler()
        try await h.startLiveView(quality: .medium)
        XCTAssertEqual(http.keys.last, "GET /v1/liveview")
        let j = Data.fakeJPEG(size: 90)
        var body = Data("--b\r\nContent-Length: \(j.count)\r\n\r\n".utf8)
        body.append(j); body.append(Data("\r\n".utf8))
        http.streamChunk?(body)
        let frame = try await h.nextLiveViewFrame()
        XCTAssertEqual(frame?.jpeg, j)
        XCTAssertEqual(frame?.sequence, 1)
        let none = try await h.nextLiveViewFrame()
        XCTAssertNil(none)
        await h.stopLiveView()
        XCTAssertTrue(http.streamCancelled)
    }

    func testChangeMessagesBecomeObjectAddedWithStableHandles() async throws {
        let (h, _) = makeHandler()
        try await h.prepare() // seeds R0000001.JPG / .DNG as known; no socket → polling task
        await h.teardown()
        let initial = try await h.pollEvents()
        XCTAssertEqual(initial, [])
        h.handleChange(#"{"changed":["storage"],"storage":{"latestPhoto":"100RICOH/R0000002.JPG","available":true}}"#)
        h.handleChange(#"{"changed":["camera"],"camera":{"av":"4.0"}}"#)
        h.handleChange(#"{"changed":["storage"],"storage":{"photos":["/100RICOH/R0000002.JPG","100RICOH/R0000002.DNG"]}}"#) // first one repeats
        let events = try await h.pollEvents()
        XCTAssertEqual(events.count, 3)
        guard case .objectAdded(let a) = events[0] else { return XCTFail("\(events[0])") }
        XCTAssertEqual(a.info?.filename, "R0000002.JPG")
        XCTAssertEqual(a.handle, h.handles.handle(for: "100RICOH/R0000002.JPG"))
        XCTAssertEqual(a.handle, RicohHandleMap.hash("100RICOH/R0000002.JPG"))
        XCTAssertEqual(events[1], .propertyChanged(nil))
        guard case .objectAdded(let b) = events[2] else { return XCTFail("\(events[2])") }
        XCTAssertEqual(b.info?.filename, "R0000002.DNG")
        XCTAssertEqual(b.info?.objectFormat, .dng)
        XCTAssertNotEqual(a.handle, b.handle)
        XCTAssertEqual(h.handles.path(for: b.handle), "100RICOH/R0000002.DNG")
        let drained = try await h.pollEvents()
        XCTAssertEqual(drained, [])
    }

    func testWebSocketMessagesAreConsumed() async throws {
        let (h, http) = makeHandler(socket: [#"{"changed":["storage"],"storage":{"latestPhoto":"100RICOH/R0000009.JPG"}}"#])
        try await h.prepare()
        XCTAssertTrue(http.keys.contains { $0.hasSuffix("/v1/changes") })
        var events = [CameraEvent]()
        for _ in 0 ..< 50 where events.isEmpty {
            events = try await h.pollEvents()
            if events.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        await h.teardown()
        XCTAssertEqual(events.count, 1)
        guard case .objectAdded(let o) = events[0] else { return XCTFail("\(events)") }
        XCTAssertEqual(o.info?.filename, "R0000009.JPG")
    }

    func testPhotoPollingFallbackDiffsListing() async throws {
        let (h, http) = makeHandler()
        try await h.prepare()
        await h.teardown()
        http.respond("GET", "/v1/photos", json: ["dirs": [["name": "100RICOH", "files": ["R0000001.JPG", "R0000001.DNG", "R0000003.JPG"]]]])
        await h.pollPhotosOnce()
        let events = try await h.pollEvents()
        XCTAssertEqual(events.count, 1)
        guard case .objectAdded(let o) = events[0] else { return XCTFail("\(events)") }
        XCTAssertEqual(o.info?.filename, "R0000003.JPG")
    }

    func testFetchObjectUsesViewProxyForDNGAndFullForJPEG() async throws {
        let (h, http) = makeHandler()
        let jpeg = Data.fakeJPEG(size: 200), proxy = Data.fakeJPEG(size: 100), dng = Data(repeating: 0x49, count: 400)
        http.respond("GET", "/v1/photos/100RICOH/R0000005.JPG", body: jpeg)
        http.respond("GET", "/v1/photos/100RICOH/R0000005.DNG?size=view", body: proxy)
        http.respond("GET", "/v1/photos/100RICOH/R0000005.DNG", body: dng)
        let jh = h.handles.handle(for: "100RICOH/R0000005.JPG")
        let (ji, jd) = try await h.fetchObject(NewObject(handle: jh), progress: nil)
        XCTAssertEqual(jd, jpeg)
        XCTAssertEqual(ji.filename, "R0000005.JPG")
        XCTAssertEqual(ji.objectCompressedSize, 200)
        let dh = h.handles.handle(for: "100RICOH/R0000005.DNG")
        let (di, dd) = try await h.fetchObject(NewObject(handle: dh), progress: nil)
        XCTAssertEqual(dd, proxy)
        XCTAssertEqual(di.filename, "R0000005.JPG")
        XCTAssertEqual(di.objectFormat, .exifJPEG)
        h.preferViewProxyForRAW = false
        let (oi, od) = try await h.fetchObject(NewObject(handle: dh), progress: nil)
        XCTAssertEqual(od, dng)
        XCTAssertEqual(oi.filename, "R0000005.DNG")
        XCTAssertEqual(oi.mediaKind, .raw)
        await XCTAssertThrowsPTP(try await h.fetchObject(NewObject(handle: 0xDEAD), progress: nil)) { _ in }
    }

    func testPropertiesReadDisplayAndWrite() async throws {
        let (h, http) = makeHandler()
        let props = try await h.readProperties([.aperture, .shutterSpeed, .iso, .exposureCompensation, .whiteBalance, .batteryLevel, .captureDestination])
        let by = Dictionary(uniqueKeysWithValues: props.map { ($0.property, $0) })
        XCTAssertEqual(by[.aperture]?.display, "ƒ/2.8")
        XCTAssertEqual(by[.aperture]?.choices.map(\.display), ["ƒ/2.8", "ƒ/4", "ƒ/5.6"])
        XCTAssertEqual(by[.shutterSpeed]?.display, "1/250")
        XCTAssertEqual(by[.iso]?.display, "200")
        XCTAssertEqual(by[.iso]?.choices.first?.display, "Auto")
        XCTAssertEqual(by[.exposureCompensation]?.display, "-0.3")
        XCTAssertEqual(by[.whiteBalance]?.display, "Auto")
        XCTAssertEqual(by[.batteryLevel]?.display, "72%")
        XCTAssertEqual(by[.captureDestination]?.isWritable, false)
        try await h.writeProperty(.aperture, raw: by[.aperture]!.choices[1].raw)
        XCTAssertEqual(String(decoding: http.bodies["PUT /v1/params/camera"]!, as: UTF8.self), "{\"av\":\"4.0\"}")
        await XCTAssertThrowsPTP(try await h.writeProperty(.batteryLevel, raw: .uint8(1))) { _ in }
    }

    func testProbeRequiresModelInJSON() async {
        let http = FakeRicohHTTP()
        http.respond("GET", "/v1/props", json: ["model": "RICOH GR III"])
        let yes = await RicohHandler.probe(host: "192.168.0.1", timeout: 1, http: http)
        XCTAssertTrue(yes)
        XCTAssertEqual(http.keys, ["GET /v1/props"])
        XCTAssertEqual(http.requests.first?.url?.absoluteString, "http://192.168.0.1/v1/props")
        let other = FakeRicohHTTP()
        other.respond("GET", "/v1/props", json: ["hello": "world"])
        let no = await RicohHandler.probe(host: "http://10.0.0.5", timeout: 1, http: other)
        XCTAssertFalse(no)
        let missing = await RicohHandler.probe(host: "10.0.0.6", timeout: 1, http: FakeRicohHTTP())
        XCTAssertFalse(missing)
    }

    func testHandleMapIsStableAndResolvesCollisions() {
        let m = RicohHandleMap()
        let a = m.handle(for: "100RICOH/R0000001.JPG")
        XCTAssertEqual(a, m.handle(for: "100RICOH/R0000001.JPG"))
        XCTAssertNotEqual(a, 0)
        XCTAssertEqual(m.path(for: a), "100RICOH/R0000001.JPG")
        XCTAssertNil(m.path(for: a &+ 7))
        XCTAssertEqual(RicohChangeMessage.parse("not json"), nil)
        XCTAssertEqual(RicohChangeMessage.parse(#"{"changed":["storage"]}"#)?.storageChanged, true)
        XCTAssertEqual(RicohChangeMessage.parse(#"{"changed":["storage"]}"#)?.photoPaths, [])
    }
}
