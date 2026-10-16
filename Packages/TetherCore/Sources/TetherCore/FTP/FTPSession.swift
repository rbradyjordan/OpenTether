import Foundation

/// One FTP control connection. Sequential command loop; data connections are
/// opened per transfer (PASV/EPSV listener or PORT/EPRT dial-out).
final class FTPSession: @unchecked Sendable {
    let peer: String
    private let fd: Int32
    private let control: FTPSocket
    private unowned let server: FTPServer
    private var config: FTPServerConfiguration { server.configuration }

    private let lock = NSLock()
    private var _lastActivity = Date()
    private var _transferring = false
    private var closed = false

    private var pendingUser: String?
    private var authenticated = false
    private var failedLogins = 0
    private var cwd = "/"
    private var restOffset = 0
    private var renameFrom: String?
    private var inbox = Data()

    private enum DataMode { case none, passive(TCPListener), active(host: String, port: UInt16) }
    private var dataMode: DataMode = .none

    init(fd: Int32, peer: String, server: FTPServer) {
        self.fd = fd
        self.peer = peer
        self.server = server
        self.control = FTPSocket(fd: fd, reading: true)
    }

    var lastActivity: Date { lock.lock(); defer { lock.unlock() }; return _lastActivity }
    var isTransferring: Bool { lock.lock(); defer { lock.unlock() }; return _transferring }
    private func touch() { lock.withLock { _lastActivity = Date() } }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let mode = dataMode
        dataMode = .none
        lock.unlock()
        if case .passive(let l) = mode { l.close() }
        control.close()
    }

    // MARK: Loop

    func run() async {
        do {
            try await reply("220 Tether FTP ready")
            while let line = try await readLine() {
                touch()
                let keepGoing = await handle(line)
                if !keepGoing { break }
            }
        } catch {
            // Peer went away or we closed it.
        }
        close()
    }

    private func readLine() async throws -> String? {
        while true {
            if let range = inbox.firstRange(of: Data([0x0A])) {
                var lineData = inbox.subdata(in: inbox.startIndex ..< range.lowerBound)
                inbox.removeSubrange(inbox.startIndex ... range.lowerBound)
                if lineData.last == 0x0D { lineData.removeLast() }
                return String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .isoLatin1) ?? ""
            }
            if inbox.count > 64 * 1024 { throw ChannelError.closed }
            do { inbox.append(try await control.receive()) }
            catch { return nil }
        }
    }

    private func reply(_ text: String) async throws {
        try await control.send(Data((text + "\r\n").utf8))
    }

    private func replyLines(_ lines: [String]) async throws {
        try await control.send(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
    }

    /// Returns false when the session should end.
    private func handle(_ line: String) async -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        let split = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = split[0].uppercased()
        let arg = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespaces) : ""
        do {
            switch verb {
            case "USER": try await user(arg)
            case "PASS": try await pass(arg)
            case "QUIT":
                try await reply("221 Goodbye")
                return false
            case "SYST": try await reply("215 UNIX Type: L8")
            case "FEAT":
                try await replyLines(["211-Features:", " UTF8", " SIZE", " MDTM", " REST STREAM", " EPSV", " EPRT", " PASV", "211 End"])
            case "OPTS":
                if arg.uppercased().hasPrefix("UTF8") { try await reply("200 UTF8 mode enabled") }
                else { try await reply("501 Option not understood") }
            case "NOOP": try await reply("200 OK")
            default:
                guard authenticated else { try await reply("530 Please log in"); return true }
                try await handleAuthenticated(verb, arg)
            }
        } catch {
            return false
        }
        return true
    }

    private func user(_ name: String) async throws {
        pendingUser = name
        if config.allowAnonymous, ["anonymous", "ftp"].contains(name.lowercased()) {
            authenticated = true
            try await reply("230 Anonymous login ok")
        } else {
            try await reply("331 Password required for \(name)")
        }
    }

    private func pass(_ password: String) async throws {
        guard let name = pendingUser else { try await reply("503 Login with USER first"); return }
        if config.allowAnonymous, ["anonymous", "ftp"].contains(name.lowercased()) {
            authenticated = true
            try await reply("230 Anonymous login ok")
            return
        }
        if name == config.username, password == config.password {
            authenticated = true
            try await reply("230 User \(name) logged in")
        } else {
            failedLogins += 1
            server.emit(.loginFailed(peer))
            try await reply("530 Login incorrect")
            if failedLogins >= 3 { throw ChannelError.closed }
        }
    }

    private func handleAuthenticated(_ verb: String, _ arg: String) async throws {
        switch verb {
        case "PWD", "XPWD": try await reply("257 \"\(cwd.replacingOccurrences(of: "\"", with: "\"\""))\" is the current directory")
        case "CWD", "XCWD":
            guard let v = resolve(arg.isEmpty ? "/" : arg), isDirectory(v) else { try await reply("550 Failed to change directory"); return }
            cwd = v
            try await reply("250 Directory changed to \(v)")
        case "CDUP", "XCUP":
            cwd = FTPPath.parent(of: cwd)
            try await reply("250 Directory changed to \(cwd)")
        case "TYPE": try await reply("200 Type set to \(arg.uppercased().isEmpty ? "I" : arg.uppercased())")
        case "MODE": try await reply(arg.uppercased() == "S" ? "200 Mode S ok" : "504 Only stream mode is supported")
        case "STRU": try await reply(arg.uppercased() == "F" ? "200 Structure F ok" : "504 Only file structure is supported")
        case "PASV": try await pasv(extended: false)
        case "EPSV": try await pasv(extended: true)
        case "PORT": try await port(arg)
        case "EPRT": try await eprt(arg)
        case "STOR": try await store(arg, append: false)
        case "APPE": try await store(arg, append: true)
        case "REST":
            guard let n = Int(arg), n >= 0 else { try await reply("501 Bad restart point"); return }
            restOffset = n
            try await reply("350 Restarting at \(n). Send STORE or RETRIEVE")
        case "LIST": try await list(arg, namesOnly: false)
        case "NLST": try await list(arg, namesOnly: true)
        case "MLSD": try await reply("502 MLSD not implemented")
        case "MKD", "XMKD":
            guard let v = resolve(arg), !v.isEmpty, v != "/" else { try await reply("550 Create directory failed"); return }
            do {
                try FileManager.default.createDirectory(at: url(v), withIntermediateDirectories: true)
                try await reply("257 \"\(v)\" created")
            } catch { try await reply("550 Create directory failed") }
        case "RMD", "XRMD":
            guard let v = resolve(arg), isDirectory(v), v != "/" else { try await reply("550 Remove directory failed"); return }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url(v).path)) ?? []
            guard contents.isEmpty, (try? FileManager.default.removeItem(at: url(v))) != nil else { try await reply("550 Remove directory failed"); return }
            try await reply("250 Directory removed")
        case "DELE":
            guard let v = resolve(arg), isFile(v), (try? FileManager.default.removeItem(at: url(v))) != nil else { try await reply("550 Delete failed"); return }
            try await reply("250 File deleted")
        case "RNFR":
            guard let v = resolve(arg), FileManager.default.fileExists(atPath: url(v).path) else { try await reply("550 File not found"); return }
            renameFrom = v
            try await reply("350 Ready for RNTO")
        case "RNTO":
            guard let from = renameFrom else { try await reply("503 RNFR required first"); return }
            renameFrom = nil
            guard let to = resolve(arg) else { try await reply("550 Rename failed"); return }
            do {
                if FileManager.default.fileExists(atPath: url(to).path) { try FileManager.default.removeItem(at: url(to)) }
                try FileManager.default.moveItem(at: url(from), to: url(to))
                try await reply("250 Rename successful")
            } catch { try await reply("550 Rename failed") }
        case "SIZE":
            guard let v = resolve(arg), isFile(v), let size = attributes(v)?[.size] as? NSNumber else { try await reply("550 Could not get file size"); return }
            try await reply("213 \(size.intValue)")
        case "MDTM":
            guard let v = resolve(arg), let date = attributes(v)?[.modificationDate] as? Date else { try await reply("550 Could not get file modification time"); return }
            try await reply("213 \(FTPListing.mdtmString(date))")
        case "ABOR":
            closeDataMode()
            try await reply("226 No transfer to abort")
        case "ALLO": try await reply("202 No storage allocation necessary")
        case "RETR": try await retrieve(arg)
        case "HELP": try await reply("214 Tether FTP: USER PASS QUIT SYST FEAT OPTS PWD CWD CDUP TYPE PASV EPSV PORT EPRT STOR APPE REST LIST NLST MKD RMD DELE RNFR RNTO SIZE MDTM ABOR NOOP RETR")
        default: try await reply("500 Unknown command")
        }
    }

    // MARK: Paths

    private func resolve(_ arg: String) -> String? { FTPPath.resolve(arg, cwd: cwd) }
    private func url(_ virtual: String) -> URL { FTPPath.fileURL(root: config.rootDirectory, virtual: virtual) }
    private func attributes(_ virtual: String) -> [FileAttributeKey: Any]? { try? FileManager.default.attributesOfItem(atPath: url(virtual).path) }
    private func isDirectory(_ virtual: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(virtual).path, isDirectory: &isDir) && isDir.boolValue
    }
    private func isFile(_ virtual: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(virtual).path, isDirectory: &isDir) && !isDir.boolValue
    }

    // MARK: Data connections

    private func closeDataMode() {
        lock.lock()
        let mode = dataMode
        dataMode = .none
        lock.unlock()
        if case .passive(let l) = mode { l.close() }
    }

    private func pasv(extended: Bool) async throws {
        closeDataMode()
        let l: TCPListener
        do { l = try server.makePassiveListener() } catch { try await reply("425 Can't open passive port"); return }
        lock.withLock { dataMode = .passive(l) }
        if extended {
            try await reply("229 Entering Extended Passive Mode (|||\(l.port)|)")
        } else {
            let host = POSIXNet.localAddress(of: fd)?.host ?? "127.0.0.1"
            guard IPAddressFilter.isIPv4(host) else {
                try await reply("425 Use EPSV for this connection")
                return
            }
            let h = host.replacingOccurrences(of: ".", with: ",")
            try await reply("227 Entering Passive Mode (\(h),\(l.port >> 8),\(l.port & 0xFF))")
        }
    }

    private func port(_ arg: String) async throws {
        let parts = arg.split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6, parts.prefix(4).allSatisfy({ $0 < 256 }), parts[4] < 256, parts[5] < 256 else {
            try await reply("501 Bad PORT argument"); return
        }
        closeDataMode()
        let host = parts.prefix(4).map(String.init).joined(separator: ".")
        lock.withLock { dataMode = .active(host: host, port: parts[4] << 8 | parts[5]) }
        try await reply("200 PORT command successful")
    }

    private func eprt(_ arg: String) async throws {
        // |1|h.h.h.h|port| or |2|ipv6|port|
        guard let delim = arg.first else { try await reply("501 Bad EPRT argument"); return }
        let parts = arg.split(separator: delim, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, let port = UInt16(parts[3]), !parts[2].isEmpty else { try await reply("501 Bad EPRT argument"); return }
        closeDataMode()
        lock.withLock { dataMode = .active(host: parts[2], port: port) }
        try await reply("200 EPRT command successful")
    }

    private func openDataConnection(reading: Bool) async throws -> FTPSocket {
        let mode = lock.withLock { () -> DataMode in defer { dataMode = .none }; return dataMode }
        switch mode {
        case .none:
            throw ChannelError.closed
        case .passive(let l):
            defer { l.close() }
            let accepted = try await Task.detached(priority: .userInitiated) { try l.accept(timeout: 20) }.value
            guard let (dfd, _) = accepted else { throw ChannelError.timeout }
            return FTPSocket(fd: dfd, reading: reading)
        case .active(let host, let port):
            let dfd = try await Task.detached(priority: .userInitiated) {
                try SocketConnector.blockingConnect(host: host, port: port, timeout: 10)
            }.value
            return FTPSocket(fd: dfd, reading: reading)
        }
    }

    // MARK: Transfers

    private func store(_ arg: String, append: Bool) async throws {
        let offset = restOffset
        restOffset = 0
        guard !arg.isEmpty, let v = resolve(arg), !isDirectory(v) else { try await reply("553 Invalid file name"); return }
        let final = url(v)
        guard isDirectory(FTPPath.parent(of: v)) else { try await reply("550 Directory does not exist"); return }
        guard hasDataMode else { try await reply("425 Use PASV or PORT first"); return }

        let fm = FileManager.default
        let part = final.appendingPathExtension("part")
        // Resume/append targets: the final file when it exists, else the leftover .part.
        let resumeTarget = fm.fileExists(atPath: final.path) ? final : part
        let writeURL = (append || offset > 0) ? resumeTarget : part
        let handle: FileHandle
        do {
            if !fm.fileExists(atPath: writeURL.path) { _ = fm.createFile(atPath: writeURL.path, contents: nil) }
            handle = try FileHandle(forWritingTo: writeURL)
            if append {
                try handle.seekToEnd()
            } else {
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
            }
        } catch {
            try await reply("553 Could not open file for writing")
            return
        }

        try await reply("150 Opening BINARY mode data connection for \(FTPPath.name(of: v))")
        let data: FTPSocket
        do { data = try await openDataConnection(reading: true) } catch {
            try? handle.close()
            try await reply("425 Can't open data connection")
            return
        }
        lock.withLock { _transferring = true }
        defer { lock.withLock { _transferring = false } }
        server.emit(.transferStarted(path: v, from: peer))
        let started = Date()
        var received = 0
        var sinceProgress = 0
        var failure: Error?
        do {
            while true {
                let chunk = try await data.receive()
                try handle.write(contentsOf: chunk)
                received += chunk.count
                sinceProgress += chunk.count
                touch()
                if sinceProgress >= 1 << 20 {
                    sinceProgress = 0
                    server.emit(.transferProgress(path: v, bytes: received))
                }
            }
        } catch let e as PTPError where e == .transportClosed {
            // EOF: the client finished.
        } catch {
            failure = error
        }
        data.close()
        try? handle.synchronize()
        try? handle.close()
        if let failure {
            server.emit(.error("Transfer of \(v) failed: \(failure)"))
            try await reply("426 Connection closed; transfer aborted")
            return
        }
        if writeURL != final {
            do {
                if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                try fm.moveItem(at: writeURL, to: final)
            } catch {
                server.emit(.error("Could not finalize \(v): \(error)"))
                try await reply("451 Could not finalize file")
                return
            }
        }
        try await reply("226 Transfer complete")
        server.emit(.fileReceived(url: final, bytes: received, from: peer, duration: Date().timeIntervalSince(started)))
    }

    private var hasDataMode: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .none = dataMode { return false }
        return true
    }

    private func retrieve(_ arg: String) async throws {
        let offset = restOffset
        restOffset = 0
        guard let v = resolve(arg), isFile(v), let handle = try? FileHandle(forReadingFrom: url(v)) else { try await reply("550 File not found"); return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        try await reply("150 Opening BINARY mode data connection")
        let data: FTPSocket
        do { data = try await openDataConnection(reading: false) } catch { try await reply("425 Can't open data connection"); return }
        lock.withLock { _transferring = true }
        defer { lock.withLock { _transferring = false } }
        do {
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try await data.send(chunk)
                touch()
            }
            data.close()
            try await reply("226 Transfer complete")
        } catch {
            data.close()
            try await reply("426 Connection closed; transfer aborted")
        }
    }

    private func list(_ arg: String, namesOnly: Bool) async throws {
        // Ignore ls flags like "-la".
        let target = arg.split(separator: " ").first(where: { !$0.hasPrefix("-") }).map(String.init) ?? ""
        guard let v = resolve(target.isEmpty ? "." : target) else { try await reply("550 No such directory"); return }
        var lines: [String] = []
        if isDirectory(v) {
            let entries = FTPListing.entries(in: url(v)).filter { !$0.name.hasSuffix(".part") }
            lines = namesOnly ? entries.map(\.name) : entries.map { FTPListing.line(for: $0) }
        } else if isFile(v) {
            let e = FTPListing.entries(in: url(FTPPath.parent(of: v))).first { $0.name == FTPPath.name(of: v) }
            if let e { lines = namesOnly ? [e.name] : [FTPListing.line(for: e)] }
        } else {
            try await reply("550 No such file or directory"); return
        }
        try await reply("150 Here comes the directory listing")
        let data: FTPSocket
        do { data = try await openDataConnection(reading: false) } catch { try await reply("425 Can't open data connection"); return }
        do {
            if !lines.isEmpty { try await data.send(Data((lines.joined(separator: "\r\n") + "\r\n").utf8)) }
            data.close()
            try await reply("226 Directory send OK")
        } catch {
            data.close()
            try await reply("426 Connection closed; transfer aborted")
        }
    }
}
