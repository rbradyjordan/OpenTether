import XCTest
@testable import TetherCore

#if canImport(CCurl)
/// libcurl uploader against our own FTP server (Linux only, where CCurl links).
final class CurlFTPClientTests: XCTestCase {
    func testUploadThroughLibcurlLandsOnTheServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-curl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cfg = FTPServerConfiguration(port: 0, username: "cam", password: "secret", allowAnonymous: false,
                                         rootDirectory: root, passivePortRange: 42100 ... 42110, idleTimeout: 60)
        let server = FTPServer(configuration: cfg)
        try server.start()
        defer { server.stop() }
        let dest = FTPDestination(host: "127.0.0.1", port: server.boundPort!, username: "cam", password: "secret",
                                  security: .plain, passive: true, remoteDirectory: "/shoot/day1")
        let client = CurlFTPClient(destination: dest, timeout: 10)
        let banner = try await client.test()
        XCTAssertFalse(banner.isEmpty)
        let payload = Data((0 ..< 200_000).map { UInt8($0 & 0xFF) })
        let progress = Progress()
        try await client.upload(payload, to: "IMG_0001.JPG") { done, total in progress.add(done, total) }
        let stored = try Data(contentsOf: root.appendingPathComponent("shoot/day1/IMG_0001.JPG"))
        XCTAssertEqual(stored, payload)
        XCTAssertEqual(progress.values.last?.0, payload.count)

        let bad = CurlFTPClient(destination: FTPDestination(host: "127.0.0.1", port: server.boundPort!, username: "cam", password: "wrong"), timeout: 5)
        do { _ = try await bad.test(); XCTFail("expected login failure") } catch { }
    }
}
#endif
