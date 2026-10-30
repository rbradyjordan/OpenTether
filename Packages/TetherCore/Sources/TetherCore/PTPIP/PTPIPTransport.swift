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
        /// Pairing: a Canon that is saving the new phone drops the first TCP
        /// connection, refuses with reason 1 for a moment, or restarts its
        /// PTP/IP service after OK is pressed. Each of those is retried this
        /// many times, `retryDelay` apart, before the error is reported.
        public var handshakeRetries = 0
        public var retryDelay: TimeInterval = 1.5
        /// After this long without the InitCommandAck the camera is taken to be
        /// showing its "connect to this device?" prompt (`awaitingConfirmation`).
        public var confirmationHint: TimeInterval = 2.5

        public init(host: String, port: UInt16 = PTPIPPacket.standardPort, clientName: String = PTPIPIdentity.clientName,
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
        case tcpConnected, awaitingConfirmation, initCommandAcked, eventConnected, eventAcked
        /// The attempt failed in a way pairing retries (reason for the UI), then `retrying`.
        case retrying
    }

    public let kind: TransportKind = .ptpip
    public let configuration: Configuration
    private let connector: PTPIPConnector

    private var command: PTPIPChannel?
    private var event: PTPIPChannel?
    /// The command connection is read by one long-lived task into this
    /// stream, so a transaction that gives up waiting (timeout) leaves the
    /// read in place for the next one instead of a socket read nothing can
    /// cancel.
    private var commandPackets: PacketMailbox?
    private var commandReader: Task<Void, Never>?
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
        var attempt = 0
        while true {
            do {
                try await openOnce()
                return
            } catch let error where attempt < configuration.handshakeRetries && Self.isRetryableDuringPairing(error) {
                attempt += 1
                health.lastError = "\(error)"
                configuration.onProgress?(.retrying)
                try await Task.sleep(nanoseconds: UInt64(configuration.retryDelay * 1_000_000_000))
            }
        }
    }

    /// What a Canon does mid-pairing: closes the socket, refuses the port
    /// while its service restarts, or answers reason 1 before it has saved us.
    static func isRetryableDuringPairing(_ error: Error) -> Bool {
        if error is ChannelError { return true }
        guard let e = error as? PTPError else { return false }
        switch e {
        case .transportClosed, .notConnected: return true
        case .vendorGate(let m): return m.contains("rejected the connection")
        case .malformed: return true
        default: return false
        }
    }

    private func openOnce() async throws {
        let cmd = try await connector.connect(host: configuration.host, port: configuration.port, timeout: configuration.connectTimeout)
        command = cmd
        startCommandReader(cmd)
        configuration.onProgress?(.tcpConnected)
        do {
            try await cmd.send(PTPIPPacket.initCommandRequest(guid: configuration.guid, name: configuration.clientName,
                                                              protocolVersion: PTPIPPacket.protocolVersion).encode())
            let hint = Task { [configuration] in
                try await Task.sleep(nanoseconds: UInt64(configuration.confirmationHint * 1_000_000_000))
                configuration.onProgress?(.awaitingConfirmation)
            }
            defer { hint.cancel() }
            let ack = try await withTimeout(configuration.handshakeTimeout, op: .openSession) { try await self.nextCommandPacket() }
            hint.cancel()
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
        case 1: return "The camera rejected the connection. Put it in its remote-control Wi-Fi mode (Canon: Wi-Fi function → Remote control (EOS Utility)) and try again."
        case 2: return "The camera is busy with another connection (EOS Utility, Camera Connect or another phone). Close that, then try again."
        case 3: return "The camera doesn't know this phone yet. Start pairing on the camera (Canon: Remote control (EOS Utility) → add a device), connect again here, and press OK on the camera."
        default: return "The camera refused the connection (reason \(reason))."
        }
    }

    public func close() async {
        stateLock.lock(); _isOpen = false; stateLock.unlock()
        eventTask?.cancel()
        eventTask = nil
        commandReader?.cancel()
        commandReader = nil
        commandPackets = nil
        command?.close()
        event?.close()
        command = nil
        event = nil
    }

    // MARK: Transactions

    public func execute(_ request: PTPRequest) async throws -> PTPResponse {
        try await serial.run { try await self.executeLocked(request) }
    }

    private func executeLocked(_ request: PTPRequest) async throws -> PTPResponse {
        guard isOpen, let cmd = command else { throw PTPError.notConnected }
        // First transaction is 0, as EOS Utility and libgphoto2 send it; Canon
        // bodies check the sequence.
        let tid = transactionID
        transactionID &+= 1
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
            switch e {
            case .timeout:
                // Over Wi-Fi a slow answer is not a dead link: cancel this
                // transaction and keep the session. Anything the camera still
                // sends for it is dropped by transaction ID above.
                health.lastError = "\(e)"
                try? await cmd.send(PTPIPPacket.cancelTransaction(transactionID: tid).encode())
            case .transportClosed:
                health.lastError = "\(e)"
                await close()
            default: break
            }
            throw e
        }
    }

    private func startCommandReader(_ cmd: PTPIPChannel) {
        let mailbox = PacketMailbox()
        commandPackets = mailbox
        commandReader = Task.detached { [weak self] in
            var framer = PTPIPFramer()
            defer { mailbox.finish() }
            while !Task.isCancelled {
                do {
                    framer.append(try await cmd.receive())
                    for p in try framer.drain() { mailbox.deliver(p) }
                } catch {
                    if let self, self.isOpen { self.health.lastError = "command channel: \(error)" }
                    return
                }
            }
        }
    }

    /// Next packet from the command connection. Throws `transportClosed`
    /// when the connection has ended, `cancelled` when the caller stopped waiting.
    private func nextCommandPacket() async throws -> PTPIPPacket {
        guard let mailbox = commandPackets else { throw PTPError.notConnected }
        if let p = await mailbox.next() { return p }
        if Task.isCancelled { throw PTPError.cancelled }
        throw PTPError.transportClosed
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

/// Packets from one connection, handed out one at a time. A waiter whose
/// task is cancelled (a transaction timing out) is simply released; the
/// packets keep flowing for the next transaction, unlike an AsyncStream,
/// which ends for good when its consumer is cancelled.
final class PacketMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [PTPIPPacket] = []
    private var waiter: CheckedContinuation<PTPIPPacket?, Never>?
    private var finished = false

    func deliver(_ packet: PTPIPPacket) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: packet)
        } else {
            queue.append(packet)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
    }

    /// nil when the connection has ended or the waiting task was cancelled.
    func next() async -> PTPIPPacket? {
        lock.lock()
        if !queue.isEmpty {
            let p = queue.removeFirst()
            lock.unlock()
            return p
        }
        if finished { lock.unlock(); return nil }
        lock.unlock()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PTPIPPacket?, Never>) in
                lock.lock()
                if !queue.isEmpty {
                    let p = queue.removeFirst()
                    lock.unlock()
                    cont.resume(returning: p)
                } else if finished || Task.isCancelled {
                    lock.unlock()
                    cont.resume(returning: nil)
                } else {
                    // One transaction at a time: a second waiter would be a bug.
                    waiter?.resume(returning: nil)
                    waiter = cont
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: nil)
        }
    }
}
