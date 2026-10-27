import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Pure parsing

/// One SSDP datagram: an M-SEARCH response (`HTTP/1.1 200 OK`) or a
/// `NOTIFY * HTTP/1.1`. Header names are lower-cased.
public struct SSDPMessage: Equatable, Sendable {
    public var startLine: String
    public var headers: [String: String]

    public static let multicastGroup = "239.255.255.250"
    public static let port: UInt16 = 1900
    public static let sonyDigitalImaging = "urn:schemas-sony-com:service:DigitalImaging:1"
    public static let sonyScalarWebAPI = "urn:schemas-sony-com:service:ScalarWebAPI:1"
    /// Canon EOS in "Remote control (EOS Utility)" Wi-Fi mode announces this
    /// (NOTIFY alive) and serves its description at :49152/upnp/CameraDevDesc.xml.
    public static let canonEOS = "urn:schemas-canon-com:service:ICPO-WFTEOSSystemService:1"
    public static let searchTargets = [sonyDigitalImaging, sonyScalarWebAPI, canonEOS, "ssdp:all"]

    public var isResponse: Bool { startLine.uppercased().hasPrefix("HTTP/") && startLine.contains("200") }
    public var isNotify: Bool { startLine.uppercased().hasPrefix("NOTIFY") }
    public var isByeBye: Bool { (headers["nts"] ?? "").lowercased().contains("byebye") }

    public subscript(_ name: String) -> String? { headers[name.lowercased()] }
    public var usn: String? { self["usn"] }
    public var location: String? { self["location"] }
    public var searchTarget: String? { self["st"] ?? self["nt"] }
    public var server: String? { self["server"] }

    /// `uuid:xxxx` out of the USN, or the whole USN when it has no uuid part.
    public var uuid: String? {
        guard let usn else { return nil }
        if let r = usn.range(of: "uuid:", options: .caseInsensitive) {
            let rest = usn[r.upperBound...]
            let end = rest.firstIndex(of: ":") ?? rest.endIndex
            let id = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        return usn
    }

    /// Host part of the LOCATION URL.
    public var locationHost: String? {
        guard let location, let url = URL(string: location.trimmingCharacters(in: .whitespaces)) else { return nil }
        return url.host
    }

    /// Mentions a Sony imaging service in ST/NT/USN.
    public var mentionsSony: Bool {
        let hay = ((searchTarget ?? "") + " " + (usn ?? "") + " " + (server ?? "")).lowercased()
        return hay.contains("sony-com") || hay.contains("sony")
    }

    public var mentionsCanon: Bool {
        let hay = ((searchTarget ?? "") + " " + (usn ?? "") + " " + (server ?? "")).lowercased()
        return hay.contains("schemas-canon-com") || hay.contains("canon")
    }

    public static func parse(_ text: String) -> SSDPMessage? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else { return nil }
        let up = first.uppercased()
        guard up.hasPrefix("HTTP/") || up.hasPrefix("NOTIFY") || up.hasPrefix("M-SEARCH") else { return nil }
        var headers: [String: String] = [:]
        for raw in lines.dropFirst() {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            headers[key] = value
        }
        return SSDPMessage(startLine: first, headers: headers)
    }

    public static func mSearch(st: String, mx: Int = 3) -> String {
        "M-SEARCH * HTTP/1.1\r\n" +
        "HOST: \(multicastGroup):\(port)\r\n" +
        "MAN: \"ssdp:discover\"\r\n" +
        "MX: \(mx)\r\n" +
        "ST: \(st)\r\n" +
        "USER-AGENT: Tether/1.0 UPnP/1.1\r\n" +
        "\r\n"
    }
}

/// The UPnP device-description document a camera serves at LOCATION.
public struct SSDPDeviceDescription: Equatable, Sendable {
    public var friendlyName: String
    public var manufacturer: String
    public var modelName: String
    public var serviceTypes: [String]
    public var udn: String
    /// Sony puts the camera's own API base URLs in `av:X_ScalarWebAPI_ServiceList`.
    public var scalarWebAPIURLs: [String]

    public var isCanonEOS: Bool {
        manufacturer.lowercased().contains("canon")
            || serviceTypes.contains { $0.lowercased().contains("schemas-canon-com") }
    }

    public var isSonyImaging: Bool {
        serviceTypes.contains { s in
            let l = s.lowercased()
            return l.contains("sony-com") && (l.contains("digitalimaging") || l.contains("scalarwebapi"))
        }
    }

    public static func parse(xml: Data) -> SSDPDeviceDescription? {
        let delegate = DescriptionParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || delegate.sawDevice else { return nil }
        guard delegate.sawDevice else { return nil }
        return SSDPDeviceDescription(friendlyName: delegate.friendlyName, manufacturer: delegate.manufacturer,
                                     modelName: delegate.modelName, serviceTypes: delegate.serviceTypes,
                                     udn: delegate.udn, scalarWebAPIURLs: delegate.scalarURLs)
    }

    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var friendlyName = "", manufacturer = "", modelName = "", udn = ""
        var serviceTypes: [String] = []
        var scalarURLs: [String] = []
        var sawDevice = false
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            path.append(localName(elementName))
            text = ""
            if path.last == "device" { sawDevice = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = localName(elementName)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only the root device's identity, not embedded devices'.
            let depth = path.filter { $0 == "device" }.count
            switch name {
            case "friendlyName" where depth == 1 && friendlyName.isEmpty: friendlyName = value
            case "manufacturer" where depth == 1 && manufacturer.isEmpty: manufacturer = value
            case "modelName" where depth == 1 && modelName.isEmpty: modelName = value
            case "UDN" where depth == 1 && udn.isEmpty: udn = value
            case "serviceType" where !value.isEmpty: serviceTypes.append(value)
            case "X_ScalarWebAPI_ActionList_URL", "X_ScalarWebAPI_LiveView_URL": if !value.isEmpty { scalarURLs.append(value) }
            default: break
            }
            text = ""
            _ = path.popLast()
        }

        private func localName(_ qualified: String) -> String {
            if let colon = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: colon)...]) }
            return qualified
        }
    }
}

// MARK: - Discoverer

/// SSDP (UPnP) discovery for Sony and Canon cameras: active M-SEARCH on the
/// multicast group plus passive NOTIFY listening. A hit is only accepted
/// after its device description proves a Sony imaging service or a Canon.
/// On iOS this needs the multicast entitlement; `PTPIPScanner` covers the
/// same cameras without it.
public final class SSDPDiscoverer: CameraDiscovering, @unchecked Sendable {
    public var searchInterval: TimeInterval = 10
    public var descriptionTimeout: TimeInterval = 3

    private let state = DiscoveryState()
    private let prober: HTTPProbing
    private let lock = NSLock()
    private var socket: UDPSocket?
    private var listenSocket: UDPSocket?
    private var running = false
    private var tasks: [Task<Void, Never>] = []
    private var threads: [Thread] = []
    private var pendingLocations = Set<String>()

    public init(prober: HTTPProbing = URLSessionProber()) { self.prober = prober }

    public var cameras: AsyncStream<[DiscoveredCamera]> { state.stream }
    public var lastError: String? { state.lastError }
    public var current: [DiscoveredCamera] { state.snapshot }

    public func start() async throws {
        let already = lock.withLock { () -> Bool in
            if running { return true }
            running = true
            return false
        }
        if already { return }

        // Unicast replies come back to the ephemeral socket; NOTIFYs to :1900.
        let s = try UDPSocket(bindPort: 0)
        var l: UDPSocket?
        do {
            let ls = try UDPSocket(bindPort: SSDPMessage.port)
            try ls.joinMulticast(group: SSDPMessage.multicastGroup)
            l = ls
        } catch {
            state.fail("SSDP passive listen unavailable: \(error)")
        }
        lock.withLock { socket = s; listenSocket = l }

        for sock in [s, l].compactMap({ $0 }) {
            let t = Thread { [weak self] in self?.receiveLoop(sock) }
            t.name = "tether.ssdp.recv"
            t.start()
            lock.withLock { threads.append(t) }
        }
        let search = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.sendSearches()
                try? await Task.sleep(nanoseconds: UInt64(self.searchInterval * 1_000_000_000))
            }
        }
        lock.withLock { tasks.append(search) }
    }

    public func stop() async {
        let (ts, s, l) = lock.withLock { () -> ([Task<Void, Never>], UDPSocket?, UDPSocket?) in
            running = false
            defer { tasks = []; socket = nil; listenSocket = nil; threads = [] }
            return (tasks, socket, listenSocket)
        }
        ts.forEach { $0.cancel() }
        s?.close(); l?.close()
    }

    /// Sends one M-SEARCH per search target.
    public func sendSearches() {
        lock.lock(); let s = socket; lock.unlock()
        guard let s else { return }
        for st in SSDPMessage.searchTargets {
            let text = SSDPMessage.mSearch(st: st, mx: 3)
            do { try s.send(Data(text.utf8), to: SSDPMessage.multicastGroup, port: SSDPMessage.port) }
            catch { state.fail("SSDP send failed: \(error)") }
        }
    }

    private func receiveLoop(_ sock: UDPSocket) {
        while true {
            do {
                guard let (data, host, _) = try sock.receive(timeout: 1) else { continue }
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
                let t = Task { [weak self] in await self?.ingest(text, from: host) }
                _ = t
            } catch {
                return
            }
        }
    }

    /// Handles one datagram's text. Exposed so tests can drive the pipeline
    /// without a socket: parse → byebye removal → description fetch → emit.
    public func ingest(_ text: String, from sourceHost: String) async {
        guard let msg = SSDPMessage.parse(text) else { return }
        guard msg.isResponse || msg.isNotify else { return }
        guard let usn = msg.usn, let id = msg.uuid else { return }
        if msg.isByeBye {
            state.remove { $0.id == id || $0.details["usn"] == usn }
            return
        }
        guard let location = msg.location, let url = URL(string: location), let host = url.host else { return }
        guard IPAddressFilter.isUsable(host) else { return }
        // Skip obviously non-camera UPnP noise unless asked for all.
        let st = (msg.searchTarget ?? "").lowercased()
        if !msg.mentionsSony && !msg.mentionsCanon && !(st.isEmpty || st.contains("upnp:rootdevice") || st.contains("mediaserver") || st.contains("basic")) { return }

        let dup = lock.withLock { () -> Bool in
            if pendingLocations.contains(location) { return true }
            pendingLocations.insert(location)
            return false
        }
        if dup { return }
        defer { lock.withLock { _ = pendingLocations.remove(location) } }

        do {
            let (body, status) = try await prober.get(url, timeout: descriptionTimeout)
            guard (200 ..< 300).contains(status), let desc = SSDPDeviceDescription.parse(xml: body) else { return }
            let canon = desc.isCanonEOS || msg.mentionsCanon
            guard desc.isSonyImaging || canon else { return }
            var details: [String: String] = [
                "location": location, "usn": usn, "model": desc.modelName, "manufacturer": desc.manufacturer,
                "udn": desc.udn, "serviceTypes": desc.serviceTypes.joined(separator: ","),
            ]
            if let server = msg.server { details["server"] = server }
            if !desc.scalarWebAPIURLs.isEmpty { details["scalarWebAPI"] = desc.scalarWebAPIURLs.joined(separator: ",") }
            if sourceHost != host { details["sourceHost"] = sourceHost }
            let fallback = canon ? "Canon camera" : "Sony camera"
            let name = canon ? ([desc.modelName, desc.friendlyName].first { !$0.isEmpty } ?? fallback)
                             : (desc.friendlyName.isEmpty ? (desc.modelName.isEmpty ? fallback : desc.modelName) : desc.friendlyName)
            state.upsert(DiscoveredCamera(id: id, name: name, vendor: canon ? .canon : .sony, host: host, port: PTPIPPacket.standardPort,
                                          method: .ssdp, transport: .ptpip, lastSeen: Date(), details: details))
        } catch {
            state.fail("SSDP description fetch failed for \(location): \(error)")
        }
    }
}
