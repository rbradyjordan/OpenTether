import Foundation

/// PTP/IP transport: two TCP connections to the camera (command + event),
/// the five-packet handshake, and demultiplexing of command responses,
/// data phases and events into separate queues.
///
///     cmd:  InitCommandRequest → InitCommandAck(connectionNumber)
///     evt:  InitEventRequest(connectionNumber) → InitEventAck
///
/// After that every transaction is CmdRequest → [StartData, Data*, EndData]
/// → CmdResponse on the command connection; the event connection carries
/// Event packets and the camera's keep-alive probes.
public final class PTPIPTransport: PTPTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var clientName: String
        public var guid: [UInt8]
        public var connectTimeout: TimeInterval
        public var handshakeTimeout: TimeInterval
        /// Some bodies (older Nikon) answer the event InitEventRequest slowly or
        /// not at all until the first command; allow running without it.
        public var requireEventChannel: Bool
        /// Fujifilm cameras dial back to us; the app is then the TCP server and
        /// `host` is ignored by the Fuji connector.
        public var vendorHint: CameraVendor?
        /// Handshake progress for the connecting screen.
        public var onProgress: (@Sendable (HandshakeStage) -> Void)?

        public init(host: String, port: UInt16 = PTPIPPacket.standardPort, clientName: String = "Tether",
                    guid: [UInt8], connectTimeout: TimeInterval = 8, handshakeTimeout: TimeInterval = 15,
                    requireEventChannel: Bool = true, vendorHint: CameraVendor? = nil) {
            self.host = host
            self.port = port
            self.clientName = clientName
            self.guid = guid
            self.connectTimeout = connectTimeout
            self.handshakeTimeout = handshakeTimeout
            self.requireEventChannel = requireEventChannel
            self.vendorHint = vendorHint
        }
    }

    public enum HandshakeStage: String, Sendable, CaseIterable {
        case tcpConnected, initCommandAcked, eventConnected, eventAcked
    }

    public let kind: TransportKind = .ptpip
    public let configuration: Configuration
    private let connector: PTPIPConnector

    private var command: PTPIPChannel?
    private var event: PTPIPChannel?
    private var commandFramer = PTPIPFramer()
    private var queuedCommandPackets: [PTPIPPacket] = []
    private var eventTask: Task<Void, Never>?
    private var transactionID: UInt32 = 0
    private let serial = AsyncSerialQueue()
    private let stateLock = NSLock()
    private var _isOpen = false
    public private(set) var connectionNumber: UInt32 = 0
    public private(set) var cameraName: String = ""
    public private(set) var cameraGUID: [UInt8] = []
    public private(set) var health = TransportHealth()

    private let eventContinuation: AsyncStream<PTPEvent>.Continuation
    public let events: AsyncStream<PTPEvent>

    public init(configuration: Configuration, connector: PTPIPConnector = DefaultPTPIPConnector()) {
        self.configuration = configuration
        self.connector = connector
        var cont: AsyncStream<PTPEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        eventContinuation = cont
    }

    public var isOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isOpen
    }

    // MARK: Handshake

    public func open() async throws {
        if isOpen { return }
        let cmd = try await connector.connect(host: configuration.host, port: configuration.port, timeout: configuration.connectTimeout)
        command = cmd
        configuration.onProgress?(.tcpConnected)
        do {
            try await cmd.send(PTPIPPacket.initCommandRequest(guid: configuration.guid, name: configuration.clientName,
                                                              protocolVersion: PTPIPPacket.protocolVersion).encode())
            let ack = try await withTimeout(configuration.handshakeTimeout, op: .openSession) { try await self.nextCommandPacket() }
            switch ack {
            case .initCommandAck(let conn, let guid, let name, _):
                connectionNumber = conn
                cameraGUID = guid
                cameraName = name
                configuration.onProgress?(.initCommandAcked)
            case .initFail(let reason):
                throw PTPError.vendorGate(Self.describeInitFail(reason))
            default:
                throw PTPError.malformed("Expected InitCommandAck, got \(ack.type)")
            }

            let evt = try await connector.connect(host: configuration.host, port: configuration.port, timeout: configuration.connectTimeout)
            event = evt
            configuration.onProgress?(.eventConnected)
            try await evt.send(PTPIPPacket.initEventRequest(connectionNumber: connectionNumber).encode())
            var framer = PTPIPFramer()
            var acked = false
            do {
                try await withTimeout(configuration.requireEventChannel ? configuration.handshakeTimeout : 2, op: .openSession) {
                    while !acked {
                        framer.append(try await evt.receive())
                        for p in try framer.drain() {
                            if case .initEventAck = p { acked = true }
                            else if case .initFail(let r) = p { throw PTPError.vendorGate(Self.describeInitFail(r)) }
                        }
                    }
                }
            } catch PTPError.timeout where !configuration.requireEventChannel {
                // proceed without a confirmed event channel
            }
            startEventLoop(evt, framer: framer)
            if acked { configuration.onProgress?(.eventAcked) }
            stateLock.lock(); _isOpen = true; stateLock.unlock()
        } catch {
            health.lastError = "\(error)"
            await close()
            throw error
        }
    }

    private static func describeInitFail(_ reason: UInt32) -> String {
        switch reason {
        case 1: return "The camera rejected the connection (fail reason 1). Check it is in remote/tether mode."
        case 2: return "The camera is busy with another connection. Only one client can control it at a time."
        case 3: return "The camera refused this device. Accept the pairing on the camera and try again."
        default: return "The camera refused the connection (reason \(reason))."
        }
    }

    public func close() async {
        stateLock.lock(); _isOpen = false; stateLock.unlock()
        eventTask?.cancel()
        eventTask = nil
        command?.close()
        event?.close()
        command = nil
        event = nil
        queuedCommandPackets.removeAll()
        commandFramer = PTPIPFramer()
    }

    // MARK: Transactions

    public func execute(_ request: PTPRequest) async throws -> PTPResponse {
        try await serial.run { try await self.executeLocked(request) }
    }

    private func executeLocked(_ request: PTPRequest) async throws -> PTPResponse {
        guard isOpen, let cmd = command else { throw PTPError.notConnected }
        transactionID &+= 1
        if transactionID == 0 { transactionID = 1 }
        let tid = transactionID
        let started = Date()

        let phase = request.dataOut == nil ? PTPIPPacket.DataPhase.noDataOrDataIn : PTPIPPacket.DataPhase.dataOut
        try await cmd.send(PTPIPPacket.cmdRequest(dataPhase: phase, code: request.code, transactionID: tid, parameters: request.parameters).encode())
        health.bytesOut += 8 + 10 + request.parameters.count * 4

        if let out = request.dataOut {
            try await cmd.send(PTPIPPacket.startData(transactionID: tid, totalLength: UInt64(out.count)).encode())
            // Send everything in one EndData; cameras accept any split.
            try await cmd.send(PTPIPPacket.endData(transactionID: tid, payload: out).encode())
            health.bytesOut += out.count + 20
        }

        var dataIn = Data()
        var expected: UInt64?
        do {
            return try await withTimeout(request.timeout, op: request.code) {
                while true {
                    let p = try await self.nextCommandPacket()
                    switch p {
                    case .startData(let t, let total) where t == tid:
                        expected = total
                        if total < 1 << 31 { dataIn.reserveCapacity(Int(total)) }
                    case .data(let t, let payload) where t == tid:
                        dataIn.append(payload)
                    case .endData(let t, let payload) where t == tid:
                        dataIn.append(payload)
                    case .cmdResponse(let code, let t, let params) where t == tid:
                        self.health.bytesIn += dataIn.count
                        self.health.roundTripMillis = Date().timeIntervalSince(started) * 1000
                        if let e = expected, UInt64(dataIn.count) != e, code == .ok {
                            // Some bodies under-report; only fail when we got less.
                            if UInt64(dataIn.count) < e { throw PTPError.malformed("data phase short: \(dataIn.count) of \(e)") }
                        }
                        return PTPResponse(code: code, parameters: params, dataIn: dataIn, transactionID: tid)
                    case .event(let code, let t, let params):
                        // Some cameras push events on the command connection.
                        self.eventContinuation.yield(PTPEvent(code: code, parameters: params, transactionID: t))
                    case .probeRequest:
                        try await cmd.send(PTPIPPacket.probeResponse.encode())
                    case .cancelTransaction(let t) where t == tid:
                        throw PTPError.cancelled
                    default:
                        // Stale packet from an earlier, timed-out transaction: drop it.
                        continue
                    }
                }
            }
        } catch let e as PTPError {
            if case .timeout = e {
                health.lastError = "\(e)"
                await close()
            }
            throw e
        }
    }

    private func nextCommandPacket() async throws -> PTPIPPacket {
        guard let cmd = command else { throw PTPError.notConnected }
        while true {
            if !queuedCommandPackets.isEmpty { return queuedCommandPackets.removeFirst() }
            let chunk = try await cmd.receive()
            commandFramer.append(chunk)
            queuedCommandPackets.append(contentsOf: try commandFramer.drain())
        }
    }

    private func startEventLoop(_ evt: PTPIPChannel, framer initial: PTPIPFramer) {
        eventTask = Task.detached { [weak self] in
            var framer = initial
            while !Task.isCancelled {
                do {
                    framer.append(try await evt.receive())
                    for p in try framer.drain() {
                        switch p {
                        case .event(let code, let tid, let params):
                            self?.eventContinuation.yield(PTPEvent(code: code, parameters: params, transactionID: tid))
                        case .probeRequest:
                            try? await evt.send(PTPIPPacket.probeResponse.encode())
                        default: break
                        }
                    }
                } catch {
                    guard let self, self.isOpen else { return }
                    self.health.lastError = "event channel: \(error)"
                    self.eventContinuation.yield(PTPEvent(code: .deviceReset))
                    await self.close()
                    return
                }
            }
        }
    }

    // MARK: Keep-alive

    /// Send a ProbeRequest on the event connection; camera answers ProbeResponse.
    public func probe() async throws {
        guard let evt = event else { throw PTPError.notConnected }
        try await evt.send(PTPIPPacket.probeRequest.encode())
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, op: PTPOperationCode, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                throw PTPError.timeout(op: op)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Runs async closures one at a time, in order. PTP allows one outstanding
/// transaction per session.
public actor AsyncSerialQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            _ = await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
