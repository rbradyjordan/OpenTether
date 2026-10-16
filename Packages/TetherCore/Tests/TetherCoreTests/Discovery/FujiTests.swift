import XCTest
@testable import TetherCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class FujiTests: XCTestCase {
    func testDatagramFormat() throws {
        let d = FujiDiscoveryMessage.datagram(broadcast: "192.168.0.255")
        let text = try XCTUnwrap(String(data: d, encoding: .utf8))
        XCTAssertEqual(text, "DISCOVERY * HTTP/1.1\r\nHOST: 192.168.0.255:51562\r\nMX: 5\r\nSERVICE: PCSS/1.0\r\nDSCNAME: Tether\r\n\r\n")
        XCTAssertEqual(FujiConstants.discoveryPort, 51562)
        XCTAssertEqual(FujiConstants.dialBackPort, 51560)
    }

    func testDialBackParsing() throws {
        let full = try XCTUnwrap(FujiDiscoveryMessage.parseDialBack("NOTIFY * HTTP/1.1\r\nDSCNAME: X-T5\r\nIMPORT: ptpip\r\nSERVICE: PCSS/1.0\r\n\r\nignored: trailing"))
        XCTAssertTrue(full.isNotify)
        XCTAssertEqual(full.cameraName, "X-T5")
        XCTAssertEqual(full["Import"], "ptpip")
        XCTAssertNil(full["ignored"])

        let noStart = try XCTUnwrap(FujiDiscoveryMessage.parseDialBack("dscname:GFX100 II\nmodel:GFX100 II\n"))
        XCTAssertEqual(noStart.startLine, "")
        XCTAssertEqual(noStart.cameraName, "GFX100 II")

        let onlyModel = try XCTUnwrap(FujiDiscoveryMessage.parseDialBack("HTTP/1.1 200 OK\r\nMODEL: X-H2S\r\n"))
        XCTAssertEqual(onlyModel.cameraName, "X-H2S")
        XCTAssertNil(FujiDiscoveryMessage.parseDialBack("   \r\n\r\n"))
    }

    func testIngestRecordsPeerAsHost() {
        let d = FujiDiscoverer(listenPort: 0)
        d.ingest("NOTIFY * HTTP/1.1\r\nDSCNAME: X-T5\r\n\r\n", from: "192.168.0.10")
        let cam = d.current.first
        XCTAssertEqual(cam?.id, "192.168.0.10")
        XCTAssertEqual(cam?.host, "192.168.0.10")
        XCTAssertEqual(cam?.port, 15740)
        XCTAssertEqual(cam?.vendor, .fujifilm)
        XCTAssertEqual(cam?.method, .fujiUDP)
        XCTAssertEqual(cam?.transport, .ptpip)
        XCTAssertEqual(cam?.name, "X-T5")
    }

    func testLoopbackDialBackEmitsCamera() async throws {
        let d = FujiDiscoverer(listenPort: 0)
        d.broadcastEnabled = false
        try await d.start()
        defer { Task { await d.stop() } }
        let port = try XCTUnwrap(d.listeningPort)
        XCTAssertNotEqual(port, 0)

        var it = d.cameras.makeAsyncIterator()
        _ = await it.next() // initial empty list

        // A fake camera dials back.
        let fd = try SocketConnector.blockingConnect(host: "127.0.0.1", port: port, timeout: 3)
        let ch = SocketChannel(fd: fd)
        try await ch.send(Data("NOTIFY * HTTP/1.1\r\nDSCNAME: X-T5\r\nSERVICE: PCSS/1.0\r\n\r\n".utf8))

        let list = await withTimeout(seconds: 5) { await it.next() ?? [] }
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?.name, "X-T5")
        XCTAssertEqual(list?.first?.host, "127.0.0.1")
        XCTAssertEqual(list?.first?.vendor, .fujifilm)
        // The listener acknowledges the registration.
        let ack = try await ch.receive()
        XCTAssertTrue(String(decoding: ack, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
        ch.close()
    }
}

/// Runs `body` with a deadline; nil when it did not finish in time.
func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
