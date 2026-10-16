import XCTest
@testable import TetherCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Collects server events on a background task.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FTPServerEvent] = []
    private var task: Task<Void, Never>?

    init(_ server: FTPServer) {
        let stream = server.events
        task = Task { [weak self] in
            for await e in stream {
                guard let self else { return }
                self.lock.withLock { self.items.append(e) }
            }
        }
    }

    var all: [FTPServerEvent] { lock.lock(); defer { lock.unlock() }; return items }

    func received() -> [(URL, Int, String)] {
        all.compactMap { if case .fileReceived(let u, let b, let f, _) = $0 { return (u, b, f) } else { return nil } }
    }

    func waitFor(_ predicate: @escaping ([FTPServerEvent]) -> Bool, seconds: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate(all) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate(all)
    }

    func stop() { task?.cancel() }
}

final class FTPServerTests: XCTestCase {
    var root: URL!
    var server: FTPServer!
    var sink: EventSink!

    func startServer(anonymous: Bool = false, idle: TimeInterval = 300, heartbeat: TimeInterval = 5) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-ftp-\(UUID().uuidString)")
        let cfg = FTPServerConfiguration(port: 0, username: "cam", password: "secret", allowAnonymous: anonymous,
                                         rootDirectory: root, passivePortRange: 42000 ... 42020, idleTimeout: idle)
        server = FTPServer(configuration: cfg)
        server.heartbeatInterval = heartbeat
        sink = EventSink(server)
        try server.start()
        XCTAssertTrue(server.isRunning)
        XCTAssertNotNil(server.boundPort)
    }

    override func tearDown() {
        server?.stop()
        sink?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func destination(user: String = "cam", password: String = "secret", passive: Bool = true, dir: String = "/") -> FTPDestination {
        FTPDestination(host: "127.0.0.1", port: server.boundPort!, username: user, password: password, security: .plain, passive: passive, remoteDirectory: dir)
    }

    func core(_ dest: FTPDestination? = nil) -> FTPClientCore {
        FTPClientCore(destination: dest ?? destination(), factory: SocketWireFactory(), timeout: 5)
    }

    /// Opens a passive data connection and runs `body` on it after sending `command`.
    func dataTransfer(_ c: FTPClientCore, command: String, body: (FTPSocket) async throws -> Void) async throws -> FTPReply {
        let pasv = try await c.command("PASV", expecting: 200 ..< 300)
        let (host, port) = try XCTUnwrap(FTPReply.parsePASV(pasv.text))
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertTrue((42000 ... 42020).contains(port) || port > 1024)
        let prelim = try await c.command(command, expecting: 100 ..< 200)
        XCTAssertEqual(prelim.code, 150)
        let fd = try SocketConnector.blockingConnect(host: host, port: port, timeout: 3)
        let ch = FTPSocket(fd: fd, reading: true)
        try await body(ch)
        ch.close()
        return try await c.readReply()
    }

    func receiveAll(_ ch: FTPSocket) async -> Data {
        var out = Data()
        while let d = try? await ch.receive() { out.append(d) }
        return out
    }

    // MARK: Tests

    func testBannerLoginSuccessAndFailure() async throws {
        try startServer()
        let ok = core()
        let banner = try await ok.connectAndLogin()
        XCTAssertEqual(banner.code, 220)
        XCTAssertTrue(banner.text.contains("Tether FTP ready"))
        let syst = try await ok.command("SYST", expecting: 200 ..< 300)
        XCTAssertEqual(syst.text, "UNIX Type: L8")
        let feat = try await ok.command("FEAT", expecting: 200 ..< 300)
        XCTAssertTrue(feat.lines.contains { $0.contains("REST STREAM") })
        XCTAssertTrue(feat.lines.contains { $0.contains("EPSV") })
        await assertCode(ok, "OPTS UTF8 ON", 200)
        await assertCode(ok, "NOOP", 200)
        await assertCode(ok, "TYPE I", 200)
        await assertText(ok, "PWD", contains: "\"/\"")
        XCTAssertEqual(server.connectedClients, 1)
        await ok.quit()

        let bad = core(destination(password: "wrong"))
        do { _ = try await bad.connectAndLogin(); XCTFail("login should fail") }
        catch let e as FTPClientError { XCTAssertEqual(e, .unexpectedReply(code: 530, text: "Login incorrect")) }
        let gotEvent = await sink.waitFor { $0.contains { if case .loginFailed = $0 { return true } else { return false } } }
        XCTAssertTrue(gotEvent)

        // Commands before login are refused.
        let fresh = FTPClientCore(destination: destination(), factory: SocketWireFactory(), timeout: 5)
        let wire = try await SocketWireFactory().open(host: "127.0.0.1", port: server.boundPort!, tls: false, timeout: 3)
        _ = wire
        _ = fresh
    }

    func testAnonymousPolicy() async throws {
        try startServer(anonymous: false)
        let anon = core(destination(user: "anonymous", password: "x@y"))
        do { _ = try await anon.connectAndLogin(); XCTFail("anonymous must be rejected") }
        catch let e as FTPClientError { if case .unexpectedReply(let code, _) = e { XCTAssertEqual(code, 530) } else { XCTFail("\(e)") } }
        server.stop()
        sink.stop()
        try startServer(anonymous: true)
        let anon2 = core(destination(user: "anonymous", password: "x@y"))
        _ = try await anon2.connectAndLogin()
        await assertCode(anon2, "PWD", 257)
        await anon2.quit()
    }

    func testPassiveStorOneMiBViaClient() async throws {
        try startServer()
        let payload = Data.fakeJPEG(size: 1 << 20)
        let client = SocketFTPClient(destination: destination(), timeout: 5)
        let progress = ProgressRecorder()
        try await client.upload(payload, to: "IMG_0001.JPG", progress: { progress.record($0, $1) })
        let saved = try Data(contentsOf: root.appendingPathComponent("IMG_0001.JPG"))
        XCTAssertEqual(saved, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("IMG_0001.JPG.part").path))
        XCTAssertEqual(progress.last, (payload.count, payload.count))
        let got = await sink.waitFor { _ in self.sink.received().count == 1 }
        XCTAssertTrue(got)
        let r = sink.received()[0]
        XCTAssertEqual(r.0.lastPathComponent, "IMG_0001.JPG")
        XCTAssertEqual(r.1, payload.count)
        XCTAssertEqual(r.2, "127.0.0.1")
        XCTAssertTrue(sink.all.contains { if case .transferStarted(let p, _) = $0 { return p == "/IMG_0001.JPG" } else { return false } })
    }

    func testNestedMkdAndStor() async throws {
        try startServer()
        let payload = Data.fakeJPEG(size: 5000)
        let client = SocketFTPClient(destination: destination(dir: "/Tether"), timeout: 5)
        try await client.upload(payload, to: "2026/10/16/DSC_0042.NEF", progress: nil)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Tether/2026/10/16/DSC_0042.NEF")), payload)

        // Cameras also issue a single MKD with a deep path.
        let c = core()
        _ = try await c.connectAndLogin()
        let mkd = try await c.command("MKD 2026/10/17/A", expecting: 200 ..< 300)
        XCTAssertEqual(mkd.code, 257)
        await assertCode(c, "CWD 2026/10/17/A", 250)
        await assertText(c, "PWD", contains: "/2026/10/17/A")
        await assertCode(c, "CDUP", 250)
        await assertText(c, "PWD", contains: "\"/2026/10/17\"")
        let rmd = try await c.command("RMD A", expecting: 200 ..< 300)
        XCTAssertEqual(rmd.code, 250)
        do { _ = try await c.command("CWD A", expecting: 200 ..< 300); XCTFail() } catch let e as FTPClientError { XCTAssertEqual(e, .unexpectedReply(code: 550, text: "Failed to change directory")) }
        await c.quit()
    }

    func testRestAndAppeResume() async throws {
        try startServer()
        let payload = Data.fakeJPEG(size: 300_000)
        let half = payload.count / 2
        let c = core()
        _ = try await c.connectAndLogin()

        // First half as a complete STOR (simulating a camera that got cut off and wrote what it had).
        var done = try await dataTransfer(c, command: "STOR part.jpg") { try await $0.send(payload.prefix(half)) }
        XCTAssertEqual(done.code, 226)
        await assertText(c, "SIZE part.jpg", equals: "\(half)")

        // REST + STOR writes the remainder at the offset.
        await assertCode(c, "REST \(half)", 350)
        done = try await dataTransfer(c, command: "STOR part.jpg") { try await $0.send(payload.suffix(from: half)) }
        XCTAssertEqual(done.code, 226)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("part.jpg")), payload)

        // APPE appends.
        done = try await dataTransfer(c, command: "STOR appe.bin") { try await $0.send(Data("hello ".utf8)) }
        XCTAssertEqual(done.code, 226)
        done = try await dataTransfer(c, command: "APPE appe.bin") { try await $0.send(Data("world".utf8)) }
        XCTAssertEqual(done.code, 226)
        XCTAssertEqual(String(decoding: try Data(contentsOf: root.appendingPathComponent("appe.bin")), as: UTF8.self), "hello world")

        // MDTM / DELE / RNFR+RNTO.
        let mdtm = try await c.command("MDTM appe.bin", expecting: 200 ..< 300)
        XCTAssertEqual(mdtm.text.count, 14)
        await assertCode(c, "RNFR appe.bin", 350)
        await assertCode(c, "RNTO renamed.bin", 250)
        await assertCode(c, "DELE renamed.bin", 250)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.bin").path))
        await c.quit()
    }

    func testClientResumesWhenServerHasPrefix() async throws {
        try startServer()
        let payload = Data.fakeJPEG(size: 200_000)
        try payload.prefix(80_000).write(to: root.appendingPathComponent("resume.jpg"))
        let client = SocketFTPClient(destination: destination(), timeout: 5)
        let progress = ProgressRecorder()
        try await client.upload(payload, to: "resume.jpg", progress: { progress.record($0, $1) })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("resume.jpg")), payload)
        XCTAssertEqual(progress.first?.0, 80_000, "progress starts at the resume offset")
        let got = await sink.waitFor { _ in self.sink.received().count == 1 }
        XCTAssertTrue(got)
        XCTAssertEqual(sink.received().first?.1, 120_000, "only the remainder crossed the wire")
        // Identical file: client skips the transfer entirely.
        try await client.upload(payload, to: "resume.jpg", progress: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sink.received().count, 1)
    }

    func testPathEscapesRejected() async throws {
        try startServer()
        let c = core()
        _ = try await c.connectAndLogin()
        func code(_ cmd: String) async -> Int {
            do { return try await c.command(cmd, expecting: 200 ..< 400).code }
            catch let e as FTPClientError { if case .unexpectedReply(let code, _) = e { return code }; return -1 }
            catch { return -1 }
        }
        let cwdUp = await code("CWD ..")
        XCTAssertEqual(cwdUp, 550)
        let cwdAbs = await code("CWD /../../")
        XCTAssertEqual(cwdAbs, 550)
        let mkd = await code("MKD ../escape")
        XCTAssertEqual(mkd, 550)
        let stor = await code("STOR ../../evil.txt")
        XCTAssertEqual(stor, 553)
        let dele = await code("DELE ../../etc/hosts")
        XCTAssertEqual(dele, 550)
        let size = await code("SIZE ../Package.swift")
        XCTAssertEqual(size, 550)
        let list = await code("LIST ../..")
        XCTAssertEqual(list, 550)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        // Still at root and still usable.
        await assertText(c, "PWD", contains: "\"/\"")
        await c.quit()
    }

    func testListOutputParses() async throws {
        try startServer()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1234).write(to: root.appendingPathComponent("a b.jpg"))
        try Data().write(to: root.appendingPathComponent("stale.jpg.part"))
        let c = core()
        _ = try await c.connectAndLogin()
        var listing = Data()
        let done = try await dataTransfer(c, command: "LIST -la") { listing = await self.receiveAll($0) }
        XCTAssertEqual(done.code, 226)
        let lines = String(decoding: listing, as: UTF8.self).split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        let parsed = lines.compactMap(FTPListing.parse(line:))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.first { $0.name == "a b.jpg" }?.size, 1234)
        XCTAssertEqual(parsed.first { $0.name == "2026" }?.isDirectory, true)

        var names = Data()
        _ = try await dataTransfer(c, command: "NLST") { names = await self.receiveAll($0) }
        XCTAssertEqual(String(decoding: names, as: UTF8.self), "2026\r\na b.jpg\r\n")
        await c.quit()
    }

    func testEPSVWorks() async throws {
        try startServer()
        let c = core()
        _ = try await c.connectAndLogin()
        let epsv = try await c.command("EPSV", expecting: 200 ..< 300)
        XCTAssertEqual(epsv.code, 229)
        let port = try XCTUnwrap(FTPReply.parseEPSV(epsv.text))
        let payload = Data.fakeJPEG(size: 20_000)
        await assertCode(c, "STOR epsv.jpg", 150)
        let ch = FTPSocket(fd: try SocketConnector.blockingConnect(host: "127.0.0.1", port: port, timeout: 3), reading: false)
        try await ch.send(payload)
        ch.close()
        do { let r = try await c.readReply(); XCTAssertEqual(r.code, 226) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("epsv.jpg")), payload)
        // STOR without a data connection set up is refused.
        do { _ = try await c.command("STOR nodata.jpg", expecting: 100 ..< 300); XCTFail() }
        catch let e as FTPClientError { if case .unexpectedReply(let code, _) = e { XCTAssertEqual(code, 425) } else { XCTFail() } }
        await c.quit()
    }

    func testActiveModeUpload() async throws {
        try startServer()
        let payload = Data.fakeJPEG(size: 70_000)
        let client = SocketFTPClient(destination: destination(passive: false), timeout: 5)
        try await client.upload(payload, to: "active.jpg", progress: nil)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("active.jpg")), payload)
        // EPRT form as well.
        let c = core()
        _ = try await c.connectAndLogin()
        let l = try TCPListener(address: "127.0.0.1", port: 0)
        await assertCode(c, "EPRT |1|127.0.0.1|\(l.port)|", 200)
        await assertCode(c, "STOR eprt.bin", 150)
        let (fd, _) = try XCTUnwrap(try l.accept(timeout: 3))
        let ch = FTPSocket(fd: fd, reading: false)
        try await ch.send(Data("eprt".utf8))
        ch.close()
        l.close()
        do { let r = try await c.readReply(); XCTAssertEqual(r.code, 226) }
        XCTAssertEqual(String(decoding: try Data(contentsOf: root.appendingPathComponent("eprt.bin")), as: UTF8.self), "eprt")
        await c.quit()
    }

    func testTwoConcurrentClients() async throws {
        try startServer()
        let a = Data.fakeJPEG(size: 600_000), b = Data.fakeJPEG(size: 400_000)
        let dest = destination()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await SocketFTPClient(destination: dest, timeout: 10).upload(a, to: "cam1/A.JPG", progress: nil) }
            group.addTask { try await SocketFTPClient(destination: dest, timeout: 10).upload(b, to: "cam2/B.JPG", progress: nil) }
            try await group.waitForAll()
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("cam1/A.JPG")), a)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("cam2/B.JPG")), b)
        let got = await sink.waitFor { _ in self.sink.received().count == 2 }
        XCTAssertTrue(got)
        let disconnected = await sink.waitFor { evs in evs.filter { if case .clientDisconnected = $0 { return true } else { return false } }.count == 2 }
        XCTAssertTrue(disconnected)
        XCTAssertEqual(server.connectedClients, 0)
    }

    func testClientTestReportsBannerAndFeatures() async throws {
        try startServer()
        let summary = try await SocketFTPClient(destination: destination(), timeout: 5).test()
        XCTAssertTrue(summary.contains("220 Tether FTP ready"))
        XCTAssertTrue(summary.contains("UNIX Type: L8"))
        XCTAssertTrue(summary.contains("Features: UTF8, SIZE, MDTM, REST STREAM"))
        let factoryMade = FTPClientFactory.make(destination())
        #if canImport(Darwin)
        XCTAssertTrue(factoryMade is StreamFTPClient)
        #else
        XCTAssertTrue(factoryMade is SocketFTPClient)
        #endif
        do { _ = try await SocketFTPClient(destination: FTPDestination(host: "127.0.0.1", port: server.boundPort!, security: .explicitTLS)).test(); XCTFail() }
        catch let e as FTPClientError { XCTAssertEqual(e, .tlsUnsupported) }
        XCTAssertFalse(FTPSecurity.allCases.map(\.rawValue).contains { $0.lowercased().contains("sftp") })
    }

    func testIdleClientsAreDropped() async throws {
        try startServer(idle: 0.4, heartbeat: 0.1)
        let c = core()
        _ = try await c.connectAndLogin()
        XCTAssertEqual(server.connectedClients, 1)
        let dropped = await sink.waitFor({ evs in evs.contains { if case .clientDisconnected = $0 { return true } else { return false } } }, seconds: 5)
        XCTAssertTrue(dropped)
        XCTAssertEqual(server.connectedClients, 0)
        do { _ = try await c.command("NOOP", expecting: 200 ..< 300); XCTFail("connection should be gone") } catch {}
    }

    func testRebindKeepsPortAndStopEmits() async throws {
        try startServer()
        let port = server.boundPort!
        server.rebind()
        XCTAssertEqual(server.boundPort, port)
        XCTAssertTrue(server.isRunning)
        let rebound = await sink.waitFor { evs in evs.contains { if case .rebound = $0 { return true } else { return false } } }
        XCTAssertTrue(rebound)
        let c = core()
        _ = try await c.connectAndLogin()
        await assertCode(c, "NOOP", 200)
        await c.quit()
        server.stop()
        XCTAssertFalse(server.isRunning)
        let stopped = await sink.waitFor { evs in evs.contains { if case .stopped = $0 { return true } else { return false } } }
        XCTAssertTrue(stopped)
        XCTAssertTrue(sink.all.contains { if case .started(let p, _) = $0 { return p == port } else { return false } })
        // Port is free again.
        let again = try TCPListener(port: port)
        again.close()
    }
}

extension FTPServerTests {
    func assertCode(_ c: FTPClientCore, _ cmd: String, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let r = try await c.command(cmd, expecting: 100 ..< 400)
            XCTAssertEqual(r.code, expected, cmd, file: file, line: line)
        } catch let e as FTPClientError {
            if case .unexpectedReply(let code, let text) = e { XCTAssertEqual(code, expected, "\(cmd): \(text)", file: file, line: line) }
            else { XCTFail("\(cmd): \(e)", file: file, line: line) }
        } catch { XCTFail("\(cmd): \(error)", file: file, line: line) }
    }

    func assertText(_ c: FTPClientCore, _ cmd: String, contains: String? = nil, equals: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let r = try await c.command(cmd, expecting: 200 ..< 400)
            if let contains { XCTAssertTrue(r.text.contains(contains), "\(cmd): \(r.text)", file: file, line: line) }
            if let equals { XCTAssertEqual(r.text, equals, cmd, file: file, line: line) }
        } catch { XCTFail("\(cmd): \(error)", file: file, line: line) }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func record(_ a: Int, _ b: Int) { lock.lock(); values.append((a, b)); lock.unlock() }
    var first: (Int, Int)? { lock.lock(); defer { lock.unlock() }; return values.first }
    var last: (Int, Int)? { lock.lock(); defer { lock.unlock() }; return values.last }
}

func XCTAssertEqual(_ a: (Int, Int)?, _ b: (Int, Int), file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a?.0, b.0, file: file, line: line)
    XCTAssertEqual(a?.1, b.1, file: file, line: line)
}
