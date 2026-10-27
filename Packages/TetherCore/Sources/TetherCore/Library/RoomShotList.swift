import Foundation

/// A listing's shot list: the rooms to cover, in walking order, with how
/// many frames each has. Real estate shooters work room by room; picking
/// the room before shooting tags every frame that lands (`room:<slug>`), so
/// files export as `123-Main-St_Kitchen_03.jpg` and nothing is forgotten.
public struct RoomShotList: Codable, Hashable, Sendable {
    public struct Room: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// How many frames the shooter wants here (0 = no target, just a count).
        public var target: Int

        public init(id: String = UUID().uuidString, name: String, target: Int = 0) {
            self.id = id
            self.name = name
            self.target = target
        }

        public var slug: String { RoomShotList.slug(name) }
        public var tag: String { RoomShotList.tagPrefix + slug }
    }

    public var rooms: [Room]

    public init(rooms: [Room]) { self.rooms = rooms }

    public static let tagPrefix = "room:"

    /// The usual walk-through of a house. Shooters edit it per listing.
    public static let listing = RoomShotList(rooms: [
        "Exterior front", "Entry", "Living room", "Dining room", "Kitchen", "Primary bedroom", "Primary bathroom",
        "Bedroom 2", "Bedroom 3", "Bathroom 2", "Office", "Laundry", "Garage", "Backyard", "Exterior twilight",
    ].map { Room(name: $0) })

    public static let condo = RoomShotList(rooms: [
        "Building exterior", "Lobby", "Entry", "Living room", "Kitchen", "Dining area", "Primary bedroom", "Primary bathroom",
        "Bedroom 2", "Bathroom 2", "Balcony", "Amenities", "View",
    ].map { Room(name: $0) })

    public static let presets: [(name: String, list: RoomShotList)] = [("House", listing), ("Condo / apartment", condo)]

    /// Lower-case, hyphenated, filename-safe.
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        var pendingDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// "primary-bedroom" → "Primary Bedroom", for filenames and captions.
    public static func displayName(fromSlug slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The room a capture was tagged with, if any.
    public static func roomSlug(in tags: [String]) -> String? {
        tags.first { $0.hasPrefix(tagPrefix) }.map { String($0.dropFirst(tagPrefix.count)) }
    }

    public func room(withSlug slug: String) -> Room? { rooms.first { $0.slug == slug } }

    /// Index of the room after `slug` (wrapping), for a "next room" button.
    public func next(after slug: String?) -> Room? {
        guard !rooms.isEmpty else { return nil }
        guard let slug, let i = rooms.firstIndex(where: { $0.slug == slug }) else { return rooms.first }
        return rooms[(i + 1) % rooms.count]
    }

    /// Frames per room from the tags of every capture in the session.
    public static func counts(from tagsByCapture: [String: [String]]) -> [String: Int] {
        var out: [String: Int] = [:]
        for tags in tagsByCapture.values {
            if let slug = roomSlug(in: tags) { out[slug, default: 0] += 1 }
        }
        return out
    }

    /// "9 of 15 rooms" style progress: rooms with at least one frame.
    public func coverage(counts: [String: Int]) -> (covered: Int, total: Int) {
        (rooms.filter { (counts[$0.slug] ?? 0) > 0 }.count, rooms.count)
    }
}

/// Per-session shot list and current room, kept in the settings table.
public extension SessionStore {
    func roomList(for sessionID: String) -> RoomShotList? {
        guard let json = setting("rooms.list.\(sessionID)"), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RoomShotList.self, from: data)
    }

    func setRoomList(_ list: RoomShotList?, for sessionID: String) {
        let json = list.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        setSetting("rooms.list.\(sessionID)", json)
        if list == nil { setSetting("rooms.current.\(sessionID)", nil) }
    }

    func currentRoom(for sessionID: String) -> String? { setting("rooms.current.\(sessionID)") }
}
