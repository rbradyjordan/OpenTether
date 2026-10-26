import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TetherCore

/// HTTP fake that answers from a closure, so one endpoint can reply by body.
final class ScriptedHTTP: RicohHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var log: [String] = []
    var handler: (URLRequest) -> (Data, Int)

    init(_ handler: @escaping (URLRequest) -> (Data, Int)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        lock.withLock { log.append("\(request.httpMethod ?? "GET") \(request.url!.absoluteString) \(body)") }
        return handler(request)
    }
    func stream(_ request: URLRequest, onChunk: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) -> RicohStreamHandle {
        FakeRicohHTTP.Handle {}
    }
    func webSocket(_ url: URL) -> RicohWebSocket? { nil }

    static func json(_ obj: Any) -> (Data, Int) { (try! JSONSerialization.data(withJSONObject: obj), 200) }
}

final class HTTPCameraTests: XCTestCase {
    func testGoProListsStillsCapturesAndDownloads() async throws {
        var files = ["GOPR0001.JPG", "GX010002.MP4"]
        let http = ScriptedHTTP { req in
            let path = req.url!.path
            switch path {
            case "/gopro/camera/info":
                return ScriptedHTTP.json(["info": ["model_name": "HERO12 Black", "serial_number": "C350", "firmware_version": "H23.01"]])
            case "/gopro/media/list":
                return ScriptedHTTP.json(["media": [["d": "100GOPRO", "fs": files.map { ["n": $0] }]]])
            case "/videos/DCIM/100GOPRO/GOPR0003.GPR": return (Data([1, 2, 3]), 200)
            default: return (Data("{}".utf8), 200)
            }
        }
        let gopro = GoProHandler(http: http)
        let id = try await gopro.probeIdentity()
        XCTAssertEqual(id.model, "HERO12 Black"); XCTAssertEqual(id.vendor, .gopro); XCTAssertEqual(id.transport, .http)
        try await gopro.prepare()
        XCTAssertTrue(http.log.contains { $0.contains("presets/set_group?id=1001") }, "switched to photo mode")
        try await gopro.capture(autofocus: true)
        XCTAssertTrue(http.log.contains { $0.contains("/gopro/camera/shutter/start") })
        let first = try await gopro.pollEvents()
        XCTAssertTrue(first.filter { if case .objectAdded = $0 { return true }; return false }.isEmpty,
                      "card contents at connect are not imported")
        files.append("GOPR0003.GPR")
        let events = try await gopro.pollEvents()
        guard case .objectAdded(let obj)? = events.first(where: { if case .objectAdded = $0 { return true }; return false }) else {
            return XCTFail("new still announced")
        }
        XCTAssertEqual(obj.info?.filename, "GOPR0003.GPR")
        let (info, data) = try await gopro.fetchObject(obj, progress: nil)
        XCTAssertEqual(data, Data([1, 2, 3])); XCTAssertEqual(info.mediaKind, .raw, "GoPro RAW is RAW")
    }

    func testGoProMediaListSkipsVideo() {
        let body = try! JSONSerialization.data(withJSONObject: ["media": [["d": "100GOPRO", "fs": [["n": "A.JPG"], ["n": "B.MP4"], ["n": "C.GPR"]]]]])
        XCTAssertEqual(GoProHandler.stills(fromMediaList: body).map(\.name), ["A.JPG", "C.GPR"])
    }

    func testOSCCameraTakesAndImportsByFileURL() async throws {
        var entries: [[String: Any]] = [["name": "R0010001.JPG", "fileUrl": "http://192.168.1.1/files/100RICOH/R0010001.JPG"]]
        let http = ScriptedHTTP { req in
            let path = req.url!.path
            if path == "/osc/info" { return ScriptedHTTP.json(["manufacturer": "RICOH", "model": "RICOH THETA Z1", "serialNumber": "10010", "firmwareVersion": "3.0"]) }
            if path == "/files/100RICOH/R0010002.JPG" { return (Data([9]), 200) }
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            switch body["name"] as? String {
            case "camera.listFiles": return ScriptedHTTP.json(["name": "camera.listFiles", "state": "done", "results": ["entries": entries, "totalEntries": entries.count]])
            case "camera.takePicture": return ScriptedHTTP.json(["name": "camera.takePicture", "state": "inProgress", "id": "1"])
            default: return ScriptedHTTP.json(["state": "done"])
            }
        }
        let theta = OSCHandler(http: http)
        let id = try await theta.probeIdentity()
        XCTAssertEqual(id.model, "RICOH THETA Z1"); XCTAssertEqual(id.manufacturer, "RICOH")
        try await theta.prepare()
        XCTAssertTrue(http.log.contains { $0.contains("\"clientVersion\":2") }, "switched to API level 2")
        try await theta.capture(autofocus: false)
        XCTAssertTrue(http.log.contains { $0.contains("camera.takePicture") })
        entries.append(["name": "R0010002.JPG", "fileUrl": "http://192.168.1.1/files/100RICOH/R0010002.JPG"])
        let events = try await theta.pollEvents()
        guard case .objectAdded(let obj)? = events.first else { return XCTFail("new photo announced") }
        XCTAssertEqual(obj.info?.filename, "R0010002.JPG")
        let (_, data) = try await theta.fetchObject(obj, progress: nil)
        XCTAssertEqual(data, Data([9]))
    }

    func testOSCErrorsSurface() async {
        let http = ScriptedHTTP { _ in ScriptedHTTP.json(["error": ["code": "disabledCommand", "message": "Busy"]]) }
        do { try await OSCHandler(http: http).capture(autofocus: false); XCTFail() } catch { XCTAssertTrue("\(error)".contains("Busy")) }
    }

    func testProbeRecognisesBothKinds() async {
        struct Prober: HTTPProbing {
            func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
                if url.absoluteString.contains("10.5.5.9") {
                    return (try JSONSerialization.data(withJSONObject: ["info": ["model_name": "HERO11 Black"]]), 200)
                }
                if url.absoluteString.contains("192.168.1.1/osc/info") {
                    return (try JSONSerialization.data(withJSONObject: ["model": "RICOH THETA X"]), 200)
                }
                throw URLError(.timedOut)
            }
        }
        let probe = HTTPCameraProbe(prober: Prober())
        await probe.probeOnce()
        let names = Set(probe.current.map(\.name))
        XCTAssertEqual(names, ["HERO11 Black", "RICOH THETA X"])
        XCTAssertTrue(probe.current.allSatisfy { $0.transport == .http && $0.isControllable })
    }
}
