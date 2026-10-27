import XCTest
@testable import TetherCore

final class SSDPTests: XCTestCase {
    static let sonyResponse = """
    HTTP/1.1 200 OK\r
    CACHE-CONTROL: max-age=1800\r
    EXT:\r
    LOCATION: http://192.168.122.1:64321/dd.xml\r
    SERVER: UPnP/1.0 SonyImagingDevice/1.0\r
    ST: urn:schemas-sony-com:service:ScalarWebAPI:1\r
    USN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::urn:schemas-sony-com:service:ScalarWebAPI:1\r
    X-AV-Physical-Unit-Info: pa="ILCE-7M4";\r
    \r

    """

    static let sonyNotify = """
    NOTIFY * HTTP/1.1\r
    HOST: 239.255.255.250:1900\r
    NT: upnp:rootdevice\r
    NTS: ssdp:alive\r
    LOCATION: http://192.168.122.1:64321/dd.xml\r
    USN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::upnp:rootdevice\r
    \r

    """

    static let sonyXML = Data("""
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:av="urn:schemas-sony-com:av">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
        <friendlyName>ILCE-7M4</friendlyName>
        <manufacturer>Sony Corporation</manufacturer>
        <modelName>SonyImagingDevice</modelName>
        <UDN>uuid:00000000-0005-0010-8000-1c994c1b4f3a</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-sony-com:service:ScalarWebAPI:1</serviceType>
            <serviceId>urn:schemas-sony-com:serviceId:ScalarWebAPI</serviceId>
            <SCPDURL>/ScalarWebAPI.xml</SCPDURL>
          </service>
          <service>
            <serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType>
            <serviceId>urn:schemas-sony-com:serviceId:DigitalImaging</serviceId>
          </service>
        </serviceList>
        <av:X_ScalarWebAPI_DeviceInfo>
          <av:X_ScalarWebAPI_ServiceList>
            <av:X_ScalarWebAPI_Service>
              <av:X_ScalarWebAPI_ServiceType>camera</av:X_ScalarWebAPI_ServiceType>
              <av:X_ScalarWebAPI_ActionList_URL>http://192.168.122.1:8080/sony</av:X_ScalarWebAPI_ActionList_URL>
            </av:X_ScalarWebAPI_Service>
          </av:X_ScalarWebAPI_ServiceList>
        </av:X_ScalarWebAPI_DeviceInfo>
      </device>
    </root>
    """.utf8)

    static let routerXML = Data("""
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
      <friendlyName>Router</friendlyName><manufacturer>Acme</manufacturer><modelName>R1</modelName>
      <UDN>uuid:router</UDN>
      <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType></service></serviceList>
    </device></root>
    """.utf8)

    func testParsesResponseHeadersCaseInsensitively() throws {
        let m = try XCTUnwrap(SSDPMessage.parse(Self.sonyResponse))
        XCTAssertTrue(m.isResponse)
        XCTAssertFalse(m.isNotify)
        XCTAssertEqual(m.location, "http://192.168.122.1:64321/dd.xml")
        XCTAssertEqual(m["Location"], m.location)
        XCTAssertEqual(m.locationHost, "192.168.122.1")
        XCTAssertEqual(m.uuid, "00000000-0005-0010-8000-1c994c1b4f3a")
        XCTAssertEqual(m.searchTarget, "urn:schemas-sony-com:service:ScalarWebAPI:1")
        XCTAssertTrue(m.mentionsSony)
    }

    func testParsesNotifyAndRejectsGarbage() throws {
        let m = try XCTUnwrap(SSDPMessage.parse(Self.sonyNotify))
        XCTAssertTrue(m.isNotify)
        XCTAssertFalse(m.isByeBye)
        XCTAssertEqual(m.searchTarget, "upnp:rootdevice")
        XCTAssertNil(SSDPMessage.parse("hello world"))
        XCTAssertNil(SSDPMessage.parse(""))
        let bye = try XCTUnwrap(SSDPMessage.parse("NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nUSN: uuid:abc::x\r\n\r\n"))
        XCTAssertTrue(bye.isByeBye)
        XCTAssertEqual(bye.uuid, "abc")
    }

    func testMSearchFormat() {
        let s = SSDPMessage.mSearch(st: SSDPMessage.sonyDigitalImaging, mx: 3)
        XCTAssertTrue(s.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        XCTAssertTrue(s.contains("HOST: 239.255.255.250:1900\r\n"))
        XCTAssertTrue(s.contains("MAN: \"ssdp:discover\"\r\n"))
        XCTAssertTrue(s.contains("MX: 3\r\n"))
        XCTAssertTrue(s.contains("ST: urn:schemas-sony-com:service:DigitalImaging:1\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n"))
        XCTAssertEqual(SSDPMessage.searchTargets.count, 4)
        XCTAssertTrue(SSDPMessage.searchTargets.contains("ssdp:all"))
        // Our own M-SEARCH parses but is neither a response nor a notify.
        let parsed = SSDPMessage.parse(s)
        XCTAssertNotNil(parsed)
        XCTAssertFalse(parsed!.isResponse || parsed!.isNotify)
    }

    func testDeviceDescriptionParsing() throws {
        let d = try XCTUnwrap(SSDPDeviceDescription.parse(xml: Self.sonyXML))
        XCTAssertEqual(d.friendlyName, "ILCE-7M4")
        XCTAssertEqual(d.manufacturer, "Sony Corporation")
        XCTAssertEqual(d.modelName, "SonyImagingDevice")
        XCTAssertEqual(d.udn, "uuid:00000000-0005-0010-8000-1c994c1b4f3a")
        XCTAssertEqual(d.serviceTypes, ["urn:schemas-sony-com:service:ScalarWebAPI:1", "urn:schemas-sony-com:service:DigitalImaging:1"])
        XCTAssertEqual(d.scalarWebAPIURLs, ["http://192.168.122.1:8080/sony"])
        XCTAssertTrue(d.isSonyImaging)

        let r = try XCTUnwrap(SSDPDeviceDescription.parse(xml: Self.routerXML))
        XCTAssertFalse(r.isSonyImaging)
        XCTAssertEqual(r.friendlyName, "Router")
        XCTAssertNil(SSDPDeviceDescription.parse(xml: Data("<nope/>".utf8)))
        XCTAssertNil(SSDPDeviceDescription.parse(xml: Data("not xml at all".utf8)))
    }

    func testDiscovererAcceptsSonyAfterDescriptionCheck() async throws {
        let prober = FakeProber(responses: ["http://192.168.122.1:64321/dd.xml": (Self.sonyXML, 200)])
        let d = SSDPDiscoverer(prober: prober)
        await d.ingest(Self.sonyResponse, from: "192.168.122.1")
        let cams = d.current
        XCTAssertEqual(cams.count, 1)
        let cam = try XCTUnwrap(cams.first)
        XCTAssertEqual(cam.id, "00000000-0005-0010-8000-1c994c1b4f3a")
        XCTAssertEqual(cam.vendor, .sony)
        XCTAssertEqual(cam.transport, .ptpip)
        XCTAssertEqual(cam.port, 15740)
        XCTAssertEqual(cam.host, "192.168.122.1")
        XCTAssertEqual(cam.method, .ssdp)
        XCTAssertEqual(cam.name, "ILCE-7M4")
        XCTAssertEqual(cam.details["location"], "http://192.168.122.1:64321/dd.xml")
        XCTAssertEqual(cam.details["model"], "SonyImagingDevice")

        // Same device via NOTIFY dedupes by UUID; byebye removes it.
        await d.ingest(Self.sonyNotify, from: "192.168.122.1")
        XCTAssertEqual(d.current.count, 1)
        await d.ingest("NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nUSN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::upnp:rootdevice\r\n\r\n", from: "192.168.122.1")
        XCTAssertEqual(d.current.count, 0)
        XCTAssertEqual(prober.callCount, 2)
    }

    func testDiscovererRejectsNonSonyAndAPIPA() async throws {
        let prober = FakeProber(responses: ["http://192.168.1.1/desc.xml": (Self.routerXML, 200)])
        let d = SSDPDiscoverer(prober: prober)
        await d.ingest("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1/desc.xml\r\nST: upnp:rootdevice\r\nUSN: uuid:router::upnp:rootdevice\r\n\r\n", from: "192.168.1.1")
        XCTAssertEqual(d.current.count, 0)
        XCTAssertEqual(prober.callCount, 1)
        await d.ingest("HTTP/1.1 200 OK\r\nLOCATION: http://169.254.3.4/dd.xml\r\nST: urn:schemas-sony-com:service:ScalarWebAPI:1\r\nUSN: uuid:x::y\r\n\r\n", from: "169.254.3.4")
        XCTAssertEqual(prober.callCount, 1, "link-local LOCATION must not be fetched")
        XCTAssertEqual(d.current.count, 0)
    }

    func testDiscovererStartStopOnLoopback() async throws {
        let d = SSDPDiscoverer(prober: FakeProber(responses: [:]))
        do { try await d.start() } catch {
            throw XCTSkip("UDP unavailable in this sandbox: \(error)")
        }
        d.sendSearches()
        await d.stop()
        XCTAssertEqual(d.current.count, 0)
    }
}

/// Canned HTTP responder keyed by absolute URL.
final class FakeProber: HTTPProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Data, Int)]
    private(set) var callCount = 0
    var error: Error?

    init(responses: [String: (Data, Int)], error: Error? = nil) { self.responses = responses; self.error = error }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
        lock.lock(); callCount += 1; let r = responses[url.absoluteString]; let e = error; lock.unlock()
        if let e { throw e }
        guard let r else { return (Data(), 404) }
        return r
    }

    func set(_ url: String, _ body: Data, _ status: Int) { lock.lock(); responses[url] = (body, status); lock.unlock() }
}
