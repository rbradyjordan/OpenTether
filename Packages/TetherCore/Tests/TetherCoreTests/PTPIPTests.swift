import XCTest
@testable import TetherCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class PTPIPPacketTests: XCTestCase {
    func testInitCommandRoundTrip() throws {
        let guid = PTPIPIdentity.guid(from: UUID())
        let p = PTPIPPacket.initCommandRequest(guid: guid, name: "Tether", protocolVersion: PTPIPPacket.protocolVersion)
        let enc = p.encode()
        // length(4) + type(4) + guid(16) + "Tether\0" utf16 (14) + version(4)
        XCTAssertEqual(enc.count, 8 + 16 + 14 + 4)
        XCTAssertEqual(PTPIPPacket.frameLength(in: enc), enc.count)
        let (dec, used) = try PTPIPPacket.decode(enc)
        XCTAssertEqual(dec, p)
        XCTAssertEqual(used, enc.count)
    }

    func testCommandAndDataPackets() throws {
        let packets: [PTPIPPacket] = [
            .cmdRequest(dataPhase: 1, code: .getObjectInfo, transactionID: 7, parameters: [0x1234]),
            .cmdResponse(code: .ok, transactionID: 7, parameters: []),
            .startData(transactionID: 7, totalLength: 1000),
            .data(transactionID: 7, payload: Data([1, 2, 3])),
            .endData(transactionID: 7, payload: Data([4, 5])),
            .event(code: .objectAdded, transactionID: 0, parameters: [0x42, 0, 0]),
            .initEventRequest(connectionNumber: 3),
            .initEventAck, .probeRequest, .probeResponse,
            .initFail(reason: 2),
            .cancelTransaction(transactionID: 9),
            .initCommandAck(connectionNumber: 1, guid: [UInt8](repeating: 7, count: 16), name: "ILCE-7M4", protocolVersion: 0x10000),
        ]
        for p in packets {
            let (d, _) = try PTPIPPacket.decode(p.encode())
            XCTAssertEqual(d, p, "\(p.type)")
        }
    }

    func testFramerSplitsAndJoins() throws {
        let a = PTPIPPacket.cmdResponse(code: .ok, transactionID: 1, parameters: [5]).encode()
        let b = PTPIPPacket.event(code: .captureComplete, transactionID: 0, parameters: []).encode()
        var all = a; all.append(b)
        var f = PTPIPFramer()
        f.append(all.prefix(5))
        XCTAssertEqual(try f.drain().count, 0)
        f.append(all.suffix(from: 5))
        let out = try f.drain()
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1], .event(code: .captureComplete, transactionID: 0, parameters: []))
        XCTAssertEqual(f.bufferedBytes, 0)
    }

    func testBadLengthIsRejected() {
        var f = PTPIPFramer()
        f.append(Data([2, 0, 0, 0, 6, 0, 0, 0]))
        XCTAssertThrowsError(try f.drain())
    }
}

/// A minimal PTP/IP camera on loopback: accepts the two connections, runs the
/// handshake and answers GetDeviceInfo / OpenSession / GetObject, pushing one
/// ObjectAdded event after the session opens.
final class FakePTPIPCamera: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private var threads: [Thread] = []
    private let lock = NSLock()
    private var eventChannel: SocketChannel?
    private(set) var connectionNumber: UInt32 = 0x1001
    var refuse = false
    let objectPayload = Data.fakeJPEG(size: 300_000)

    init() throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        listenFD = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 4) == 0 else { throw ChannelError.connectFailed("bind", errno) }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
    }

    func start() {
        let t = Thread { [self] in acceptLoop() }
        t.start()
        lock.lock(); threads.append(t); lock.unlock()
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            let ch = SocketChannel(fd: fd)
            let t = Thread { [self] in
                let sem = DispatchSemaphore(value: 0)
                Task { await self.serve(ch); sem.signal() }
                sem.wait()
            }
            t.start()
            lock.lock(); threads.append(t); lock.unlock()
        }
    }

    private func serve(_ ch: SocketChannel) async {
        var framer = PTPIPFramer()
        var sessionOpen = false
        do {
            while true {
                framer.append(try await ch.receive())
                for p in try framer.drain() {
                    switch p {
                    case .initCommandRequest:
                        if refuse { try await ch.send(PTPIPPacket.initFail(reason: 2).encode()); ch.close(); return }
                        try await ch.send(PTPIPPacket.initCommandAck(connectionNumber: connectionNumber, guid: [UInt8](repeating: 9, count: 16), name: "FakeCam", protocolVersion: PTPIPPacket.protocolVersion).encode())
                    case .initEventRequest(let n):
                        guard n == connectionNumber else { try await ch.send(PTPIPPacket.initFail(reason: 1).encode()); return }
                        lock.lock(); eventChannel = ch; lock.unlock()
                        try await ch.send(PTPIPPacket.initEventAck.encode())
                    case .cmdRequest(_, let code, let tid, let params):
                        switch code {
                        case .getDeviceInfo:
                            try await reply(ch, tid, data: ScriptedTransport.genericInfo.encoded)
                        case .openSession:
                            sessionOpen = true
                            try await ch.send(PTPIPPacket.cmdResponse(code: .ok, transactionID: tid, parameters: []).encode())
                            if let evt = eventChannel {
                                try await evt.send(PTPIPPacket.event(code: .objectAdded, transactionID: 0, parameters: [0x77]).encode())
                            }
                        case .getObjectInfo:
                            let info = PTPObjectInfo(objectFormat: .exifJPEG, objectCompressedSize: UInt32(objectPayload.count), filename: "FAKE0001.JPG")
                            try await reply(ch, tid, data: info.encoded)
                        case .getObject:
                            try await reply(ch, tid, data: objectPayload, chunk: 65536)
                        case .getPartialObject:
                            let off = Int(params[1]), want = Int(params[2])
                            try await reply(ch, tid, data: objectPayload[off ..< min(objectPayload.count, off + want)])
                        case .setDevicePropValue:
                            // consume data phase then OK
                            try await ch.send(PTPIPPacket.cmdResponse(code: .ok, transactionID: tid, parameters: []).encode())
                        case .closeSession:
                            sessionOpen = false
                            try await ch.send(PTPIPPacket.cmdResponse(code: .ok, transactionID: tid, parameters: []).encode())
                        default:
                            try await ch.send(PTPIPPacket.cmdResponse(code: sessionOpen ? .operationNotSupported : .sessionNotOpen, transactionID: tid, parameters: []).encode())
                        }
                    case .probeRequest:
                        try await ch.send(PTPIPPacket.probeResponse.encode())
                    default: break
                    }
                }
            }
        } catch {
            ch.close()
        }
    }

    private func reply(_ ch: SocketChannel, _ tid: UInt32, data: Data, chunk: Int = 1 << 20) async throws {
        try await ch.send(PTPIPPacket.startData(transactionID: tid, totalLength: UInt64(data.count)).encode())
        var off = 0
        while off < data.count {
            let end = min(data.count, off + chunk)
            let slice = data[data.startIndex + off ..< data.startIndex + end]
            if end == data.count { try await ch.send(PTPIPPacket.endData(transactionID: tid, payload: Data(slice)).encode()) }
            else { try await ch.send(PTPIPPacket.data(transactionID: tid, payload: Data(slice)).encode()) }
            off = end
        }
        try await ch.send(PTPIPPacket.cmdResponse(code: .ok, transactionID: tid, parameters: []).encode())
    }

    func stop() { close(listenFD) }
}

final class PTPIPTransportTests: XCTestCase {
    func testHandshakeTransactionsAndEvents() async throws {
        let cam = try FakePTPIPCamera()
        cam.start()
        defer { cam.stop() }
        let cfg = PTPIPTransport.Configuration(host: "127.0.0.1", port: cam.port, guid: PTPIPIdentity.guid(from: UUID()))
        let transport = PTPIPTransport(configuration: cfg, connector: SocketConnector())
        let engine = PTPEngine(transport: transport)
        let info = try await engine.connect()
        XCTAssertEqual(info.model, "PTP-1")
        XCTAssertEqual(transport.cameraName, "FakeCam")
        XCTAssertEqual(transport.connectionNumber, 0x1001)

        // Event pushed on the event channel after OpenSession.
        var it = transport.events.makeAsyncIterator()
        let ev = await it.next()
        XCTAssertEqual(ev?.code, .objectAdded)
        XCTAssertEqual(ev?.parameters.first, 0x77)

        // Multi-packet data phase reassembles.
        let obj = try await engine.getObjectInfo(0x77)
        XCTAssertEqual(obj.filename, "FAKE0001.JPG")
        let data = try await engine.getObject(0x77)
        XCTAssertEqual(data, cam.objectPayload)
        let partial = try await engine.download(0x77, size: obj.objectCompressedSize)
        XCTAssertEqual(partial, cam.objectPayload)

        // Data-out phase.
        try await engine.setDevicePropValue(.fNumber, .uint16(280))

        // Unsupported op maps to a PTPError with the code.
        do { _ = try await engine.run(.formatStore, [1]); XCTFail() } catch let e as PTPError { XCTAssertEqual(e.responseCode, .operationNotSupported) }

        await engine.disconnect()
        XCTAssertFalse(transport.isOpen)
    }

    func testInitFailSurfacesAsGate() async throws {
        let cam = try FakePTPIPCamera()
        cam.refuse = true
        cam.start()
        defer { cam.stop() }
        let cfg = PTPIPTransport.Configuration(host: "127.0.0.1", port: cam.port, guid: [UInt8](repeating: 1, count: 16))
        let transport = PTPIPTransport(configuration: cfg, connector: SocketConnector())
        do {
            try await transport.open()
            XCTFail("expected refusal")
        } catch let e as PTPError {
            guard case .vendorGate(let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("busy"))
        }
        XCTAssertFalse(transport.isOpen)
    }

    func testConnectionRefusedIsReported() async {
        let cfg = PTPIPTransport.Configuration(host: "127.0.0.1", port: 1, guid: [UInt8](repeating: 1, count: 16), connectTimeout: 2)
        let transport = PTPIPTransport(configuration: cfg, connector: SocketConnector())
        do { try await transport.open(); XCTFail() } catch { XCTAssertTrue(error is ChannelError) }
    }
}
