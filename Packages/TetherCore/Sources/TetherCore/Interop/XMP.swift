import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The metadata other pro tools read. Written as an XMP sidecar next to RAW
/// files and embedded as an APP1 packet in exported JPEGs, so Lightroom,
/// Capture One, Bridge and Photo Mechanic see the same rating, label,
/// keywords and copyright Tether shows.
///
/// Mapping used (the de-facto conventions these apps share):
/// - rating        → `xmp:Rating` 0–5; reject → `xmp:Rating = -1` (Lightroom/Bridge)
/// - colour label  → `xmp:Label` with Lightroom's names (Red, Yellow, Green, Blue, Purple)
///                   and `photomechanic:ColorClass` 1–8 for Photo Mechanic
/// - pick          → `photomechanic:Tagged = True` plus keyword `tether:pick`
///                   (Lightroom does not store its flag in XMP)
/// - tags          → `dc:subject` bag and `lr:hierarchicalSubject`
/// - creator/copyright/caption/headline → `dc:creator`, `dc:rights`,
///   `dc:description`, `photoshop:Headline`, `xmpRights:Marked`
public struct XMPPacket: Equatable, Sendable {
    public var rating: Int?               // -1 reject, 0 none, 1–5
    public var label: ColorLabel?
    public var pick: Bool
    public var keywords: [String]
    public var hierarchicalKeywords: [String]   // "Clients|Acme|AW26"
    public var title: String?
    public var caption: String?
    public var headline: String?
    public var creator: String?
    public var copyright: String?
    public var creatorTool: String
    public var createDate: Date?
    public var documentID: String?
    /// Anything we read but don't model, preserved verbatim on rewrite.
    public var extraDescriptions: [String]

    public init(rating: Int? = nil, label: ColorLabel? = nil, pick: Bool = false, keywords: [String] = [],
                hierarchicalKeywords: [String] = [], title: String? = nil, caption: String? = nil, headline: String? = nil,
                creator: String? = nil, copyright: String? = nil, creatorTool: String = "Open Tether for iOS",
                createDate: Date? = nil, documentID: String? = nil, extraDescriptions: [String] = []) {
        self.rating = rating
        self.label = label
        self.pick = pick
        self.keywords = keywords
        self.hierarchicalKeywords = hierarchicalKeywords
        self.title = title
        self.caption = caption
        self.headline = headline
        self.creator = creator
        self.copyright = copyright
        self.creatorTool = creatorTool
        self.createDate = createDate
        self.documentID = documentID
        self.extraDescriptions = extraDescriptions
    }

    /// Build from a capture's review state plus the user's metadata profile.
    public init(capture: CaptureItem, tags: [String], profile: MetadataProfile, sessionName: String?) {
        var kw = tags
        if capture.flag == .pick { kw.append("tether:pick") }
        if let s = sessionName, profile.sessionAsKeyword { kw.append(s) }
        self.init(rating: capture.flag == .reject ? -1 : capture.rating,
                  label: capture.colorLabel == .none ? nil : capture.colorLabel,
                  pick: capture.flag == .pick,
                  keywords: Array(Set(kw)).sorted(),
                  hierarchicalKeywords: profile.hierarchicalRoot.map { root in tags.map { "\(root)|\($0)" } } ?? [],
                  caption: profile.captionTemplate.flatMap { NamingTemplate($0).render(capture: capture, sessionName: sessionName, index: capture.sequence) },
                  headline: sessionName,
                  creator: profile.creator, copyright: profile.copyrightLine(),
                  createDate: capture.capturedAt, documentID: "xmp.did:tether-\(capture.id)")
    }

    // MARK: Serialise

    public static let lightroomLabels: [ColorLabel: String] = [.red: "Red", .yellow: "Yellow", .green: "Green", .blue: "Blue", .purple: "Purple"]
    /// Photo Mechanic colour classes: 1 Winner(red) 2 Winner alt(yellow) 3 Superior(green) 4 Superior alt(blue) 5 Typical(purple)…
    public static let photoMechanicClasses: [ColorLabel: Int] = [.red: 1, .yellow: 2, .green: 3, .blue: 4, .purple: 5]

    public func serialized() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func alt(_ tag: String, _ v: String) -> String { "   <\(tag)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(esc(v))</rdf:li></rdf:Alt></\(tag)>\n" }
        func bag(_ tag: String, _ v: [String]) -> String {
            v.isEmpty ? "" : "   <\(tag)><rdf:Bag>\n" + v.map { "    <rdf:li>\(esc($0))</rdf:li>\n" }.joined() + "   </rdf:Bag></\(tag)>\n"
        }
        func seq(_ tag: String, _ v: [String]) -> String {
            v.isEmpty ? "" : "   <\(tag)><rdf:Seq>\n" + v.map { "    <rdf:li>\(esc($0))</rdf:li>\n" }.joined() + "   </rdf:Seq></\(tag)>\n"
        }
        var body = ""
        if let r = rating { body += "   <xmp:Rating>\(r)</xmp:Rating>\n" }
        if let l = label, let name = Self.lightroomLabels[l] { body += "   <xmp:Label>\(name)</xmp:Label>\n" }
        body += "   <xmp:CreatorTool>\(esc(creatorTool))</xmp:CreatorTool>\n"
        if let d = createDate { body += "   <xmp:CreateDate>\(Self.iso.string(from: d))</xmp:CreateDate>\n" }
        body += "   <xmp:MetadataDate>\(Self.iso.string(from: Date()))</xmp:MetadataDate>\n"
        if let id = documentID { body += "   <xmpMM:DocumentID>\(esc(id))</xmpMM:DocumentID>\n" }
        if let l = label, let c = Self.photoMechanicClasses[l] { body += "   <photomechanic:ColorClass>\(c)</photomechanic:ColorClass>\n" }
        body += "   <photomechanic:Tagged>\(pick ? "True" : "False")</photomechanic:Tagged>\n"
        body += bag("dc:subject", keywords)
        body += bag("lr:hierarchicalSubject", hierarchicalKeywords)
        if let t = title { body += alt("dc:title", t) }
        if let c = caption { body += alt("dc:description", c) }
        if let c = creator { body += seq("dc:creator", [c]) }
        if let r = copyright { body += alt("dc:rights", r); body += "   <xmpRights:Marked>True</xmpRights:Marked>\n" }
        if let h = headline { body += "   <photoshop:Headline>\(esc(h))</photoshop:Headline>\n" }
        let extras = extraDescriptions.joined()
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Tether">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
            xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:photomechanic="http://ns.camerabits.com/photomechanic/1.0/">
        \(body)  </rdf:Description>
        \(extras) </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    public var data: Data { Data(serialized().utf8) }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Parse

    /// Lenient parse of an XMP packet (sidecar or embedded) from any of the
    /// tools above. Unknown content is kept so a rewrite doesn't lose it.
    public init(parsing data: Data) throws {
        let parser = XMPParser()
        let x = XMLParser(data: data)
        x.delegate = parser
        guard x.parse(), parser.sawDescription else { throw XMPError.malformed(x.parserError?.localizedDescription ?? "no rdf:Description") }
        var p = XMPPacket()
        if let r = parser.values["xmp:Rating"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) { p.rating = r }
        if let l = parser.values["xmp:Label"] { p.label = Self.lightroomLabels.first { $0.value.caseInsensitiveCompare(l) == .orderedSame }?.key }
        if p.label == nil, let c = parser.values["photomechanic:ColorClass"].flatMap({ Int($0) }) { p.label = Self.photoMechanicClasses.first { $0.value == c }?.key }
        p.pick = (parser.values["photomechanic:Tagged"] ?? "").lowercased() == "true" || parser.bags["dc:subject", default: []].contains("tether:pick")
        p.keywords = parser.bags["dc:subject", default: []].filter { $0 != "tether:pick" }
        p.hierarchicalKeywords = parser.bags["lr:hierarchicalSubject", default: []]
        p.title = parser.alts["dc:title"]
        p.caption = parser.alts["dc:description"]
        p.creator = parser.bags["dc:creator"]?.first
        p.copyright = parser.alts["dc:rights"]
        p.headline = parser.values["photoshop:Headline"]
        p.creatorTool = parser.values["xmp:CreatorTool"] ?? "unknown"
        p.createDate = parser.values["xmp:CreateDate"].flatMap { Self.iso.date(from: $0) ?? PTPDateTime.parse($0) }
        p.documentID = parser.values["xmpMM:DocumentID"]
        self = p
    }

    /// What the library should adopt from a file that arrives with metadata
    /// (FTP push, Files import): rating/flag/label/tags.
    public func applied(to capture: inout CaptureItem) -> [String] {
        if let r = rating {
            if r < 0 { capture.flag = .reject; capture.rating = 0 } else { capture.rating = min(5, r) }
        }
        if pick { capture.flag = .pick }
        if let l = label { capture.colorLabel = l }
        return keywords
    }
}

public enum XMPError: Error, Equatable { case malformed(String), notJPEG, noPacket }

/// Minimal XMP/RDF reader: simple elements, rdf:Bag/Seq lists, rdf:Alt text.
final class XMPParser: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var bags: [String: [String]] = [:]
    var alts: [String: String] = [:]
    var sawDescription = false
    private var stack: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name)
        text = ""
        // Attribute-style XMP (Capture One writes some values as attributes).
        if name == "rdf:Description" {
            sawDescription = true
            for (k, v) in attributes where k.contains(":") && !k.hasPrefix("xmlns") && k != "rdf:about" { values[k] = v }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { stack.removeLast(); text = "" }
        if name == "rdf:li", stack.count >= 3 {
            let container = stack[stack.count - 2]
            let owner = stack[stack.count - 3]
            if container == "rdf:Alt" { alts[owner] = t } else { bags[owner, default: []].append(t) }
            return
        }
        if name.contains(":"), !name.hasPrefix("rdf:"), !name.hasPrefix("x:"), !t.isEmpty, stack.count >= 2, stack[stack.count - 2] == "rdf:Description" {
            values[name] = t
        }
    }
}

/// Embeds / extracts an XMP packet in a JPEG's APP1 segment (the standard
/// `http://ns.adobe.com/xap/1.0/` marker), replacing any existing one.
public enum JPEGXMP {
    static let header = Data("http://ns.adobe.com/xap/1.0/\0".utf8)

    public static func embed(_ packet: XMPPacket, in jpeg: Data) throws -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw XMPError.notJPEG }
        var payload = header
        payload.append(packet.data)
        guard payload.count + 2 <= 0xFFFF else { throw XMPError.malformed("XMP packet too large for one APP1 segment") }
        var out = Data([0xFF, 0xD8])
        var i = 2
        var inserted = false
        // Walk the segments before the image data; drop an old XMP APP1, and
        // insert ours after APP0/EXIF (Exif must stay first for many readers).
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }   // SOS / EOI: image data begins
            let len = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let segEnd = min(bytes.count, i + 2 + len)
            let seg = bytes[i ..< segEnd]
            let isXMP = marker == 0xE1 && seg.count > 4 + header.count && Data(seg[(i + 4) ..< (i + 4 + header.count)]) == header
            let isAPP0orEXIF = marker == 0xE0 || (marker == 0xE1 && !isXMP)
            if !inserted && !isAPP0orEXIF {
                out.append(appendable(payload)); inserted = true
            }
            if !isXMP { out.append(contentsOf: seg) }
            i = segEnd
        }
        if !inserted { out.append(appendable(payload)) }
        out.append(contentsOf: bytes[i...])
        return out
    }

    private static func appendable(_ payload: Data) -> Data {
        var seg = Data([0xFF, 0xE1])
        let len = UInt16(payload.count + 2)
        seg.append(UInt8(len >> 8)); seg.append(UInt8(len & 0xFF))
        seg.append(payload)
        return seg
    }

    public static func extract(from jpeg: Data) throws -> XMPPacket {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw XMPError.notJPEG }
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let len = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let segEnd = min(bytes.count, i + 2 + len)
            if marker == 0xE1, segEnd - (i + 4) > header.count, Data(bytes[(i + 4) ..< (i + 4 + header.count)]) == header {
                return try XMPPacket(parsing: Data(bytes[(i + 4 + header.count) ..< segEnd]))
            }
            i = segEnd
        }
        throw XMPError.noPacket
    }
}

/// Who shot it. Lives in WorkspaceMemory; applied to every export.
public struct MetadataProfile: Codable, Hashable, Sendable {
    public var creator: String?
    public var copyright: String?
    public var captionTemplate: String?         // NamingTemplate tokens, e.g. "{session} – {date}"
    public var hierarchicalRoot: String?        // "Tether" → lr:hierarchicalSubject "Tether|hero"
    public var sessionAsKeyword: Bool
    public var embedInJPEG: Bool
    public var writeSidecarsForRAW: Bool
    public var writeSidecarsForJPEG: Bool       // Photo Mechanic / Capture One style
    public var readIncomingXMP: Bool

    public init(creator: String? = nil, copyright: String? = nil, captionTemplate: String? = nil, hierarchicalRoot: String? = "Tether",
                sessionAsKeyword: Bool = true, embedInJPEG: Bool = true, writeSidecarsForRAW: Bool = true,
                writeSidecarsForJPEG: Bool = false, readIncomingXMP: Bool = true) {
        self.creator = creator
        self.copyright = copyright
        self.captionTemplate = captionTemplate
        self.hierarchicalRoot = hierarchicalRoot
        self.sessionAsKeyword = sessionAsKeyword
        self.embedInJPEG = embedInJPEG
        self.writeSidecarsForRAW = writeSidecarsForRAW
        self.writeSidecarsForJPEG = writeSidecarsForJPEG
        self.readIncomingXMP = readIncomingXMP
    }

    /// Copyright line with the year filled in: "© 2026 Brady Jordan".
    public func copyrightLine(year: Int = Calendar.current.component(.year, from: Date())) -> String? {
        guard let c = creator, !c.isEmpty else { return copyright }
        if let cp = copyright, !cp.isEmpty { return cp.replacingOccurrences(of: "{year}", with: String(year)) }
        return "© \(year) \(c)"
    }
}

public extension WorkspaceMemory {
    static let metadataProfile = Key("interop.metadata", default: MetadataProfile())
}
