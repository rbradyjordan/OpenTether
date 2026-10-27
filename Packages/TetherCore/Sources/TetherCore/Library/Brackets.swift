import Foundation

/// Exposure brackets (AEB sets for HDR and flambient work) found by looking
/// at how frames arrived: a run of 3 or more shot within a few seconds of
/// each other at one aperture, where the shutter speed or exposure
/// compensation changes from frame to frame, is one bracket. Members get a
/// `bracket:<n>` tag (n = the sequence number of the first frame), so they
/// export together and `{bracket}` names them.
public enum BracketDetector {
    public static let tagPrefix = "bracket:"
    /// Longest gap between two frames of one bracket. AEB bursts are well
    /// under a second; a shooter re-framing between sets takes longer.
    public static var maxGap: TimeInterval = 4
    public static let minimumSize = 3
    public static let maximumSize = 9

    public struct Group: Equatable, Sendable {
        public var items: [CaptureItem]
        public var tag: String { tagPrefix + String(items[0].sequence) }
        public var size: Int { items.count }
        /// The frame nearest the middle of the set: the "normal" exposure.
        public var middle: CaptureItem { items[items.count / 2] }
    }

    /// Groups in capture order. `items` may be in any order.
    public static func groups(in items: [CaptureItem]) -> [Group] {
        let stills = items.filter { $0.kind.isStill && $0.exposure != nil }
            .sorted { ($0.capturedAt, $0.sequence) < ($1.capturedAt, $1.sequence) }
        var out: [Group] = []
        var run: [CaptureItem] = []
        func flush() {
            if run.count >= minimumSize { out.append(Group(items: run)) }
            run = []
        }
        for item in stills {
            if let last = run.last, belongsTogether(last, item), run.count < maximumSize {
                run.append(item)
            } else {
                flush()
                run = [item]
            }
        }
        flush()
        return out
    }

    /// Same aperture, close in time, and a different shutter or compensation.
    static func belongsTogether(_ a: CaptureItem, _ b: CaptureItem) -> Bool {
        guard let ea = a.exposure, let eb = b.exposure else { return false }
        guard b.capturedAt.timeIntervalSince(a.capturedAt) <= maxGap, b.capturedAt >= a.capturedAt else { return false }
        guard ea.aperture == eb.aperture, ea.iso == eb.iso else { return false }
        return ea.shutter != eb.shutter || ea.compensation != eb.compensation
    }

    /// The bracket a capture belongs to, from its tags.
    public static func bracketID(in tags: [String]) -> String? {
        tags.first { $0.hasPrefix(tagPrefix) }.map { String($0.dropFirst(tagPrefix.count)) }
    }

    /// RAW+JPEG pairs count once: the groups are built on one member per pair.
    public static func groupsCollapsingPairs(in items: [CaptureItem]) -> [Group] {
        var seen = Set<String>()
        let one = items.sorted { $0.kind == .jpeg && $1.kind != .jpeg }.filter { seen.insert($0.pairKey).inserted }
        return groups(in: one)
    }
}
