import SwiftUI
import TetherCore

/// Horizontal chip row over a `CaptureFilter`. Used live on the grid (bound to
/// the model) and inside the collection editor on a draft rule.
struct FilterBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel

    var body: some View {
        FilterChips(filter: $model.filter, sessions: model.sessions, cameras: model.cameras, suggestions: model.tagSuggestions(prefix:)) {
            app.commands.request = .saveSmart(model.effectiveFilter)
        }
    }
}

/// The chips themselves, over any filter binding.
struct FilterChips: View {
    @Binding var filter: CaptureFilter
    var sessions: [ShootSession] = []
    var cameras: [CameraIdentity] = []
    var suggestions: (String) -> [String] = { _ in [] }
    var onSaveSmart: (() -> Void)? = nil

    @State private var tagText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TetherSpace.s) {
                if !filter.isEmpty { clearChip }
                ratingChip
                flagChip
                colorChip
                kindChip
                tagChip
                dateChip
                if !sessions.isEmpty { sessionChip }
                if !cameras.isEmpty { cameraChip }
                exportedChip
                if !filter.isEmpty, let onSaveSmart {
                    Button(action: onSaveSmart) { Label("Save as smart collection", systemImage: "sparkles") }.buttonStyle(ChipStyle(selected: false))
                }
            }
            .padding(.horizontal, TetherSpace.m)
            .padding(.vertical, TetherSpace.s)
            .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: filter)
        }
        .background(TetherColor.surface1)
        .accessibilityLabel("Filters: \(filter.summary)")
    }

    private var clearChip: some View {
        Button { filter = CaptureFilter() } label: { Label(filter.summary, systemImage: "xmark.circle.fill").lineLimit(1) }
            .buttonStyle(ChipStyle(selected: true))
            .accessibilityLabel("Clear all filters, currently \(filter.summary)")
    }

    private var ratingChip: some View {
        Menu {
            ForEach(1 ... 5, id: \.self) { n in Button("\(n)★ and up") { filter.minRating = n; filter.maxRating = nil } }
            Button("Unrated") { filter.maxRating = 0; filter.minRating = nil }
            Button("Any rating") { filter.minRating = nil; filter.maxRating = nil }
        } label: { chipLabel(filter.minRating.map { "\($0)★+" } ?? (filter.maxRating == 0 ? "Unrated" : "Rating"), "star") }
            .buttonStyle(ChipStyle(selected: filter.minRating != nil || filter.maxRating != nil))
    }

    private var flagChip: some View {
        Menu {
            Button("Picks") { filter.flags = [.pick] }
            Button("Rejects") { filter.flags = [.reject] }
            Button("Unflagged") { filter.flags = [.none] }
            Button("Not rejected") { filter.flags = [.none, .pick] }
            Button("Any flag") { filter.flags = nil }
        } label: { chipLabel(flagTitle, "flag") }
            .buttonStyle(ChipStyle(selected: filter.flags != nil))
    }

    private var flagTitle: String {
        guard let f = filter.flags else { return "Flag" }
        if f == [.pick] { return "Picks" }
        if f == [.reject] { return "Rejects" }
        if f == [.none] { return "Unflagged" }
        return "Not rejected"
    }

    private var colorChip: some View {
        Menu {
            ForEach(TetherCoreColorLabel.allCases.filter { $0 != .none }) { c in
                Button { toggle(&filter.colors, c) } label: { Label(c.rawValue.capitalized, systemImage: filter.colors?.contains(c) == true ? "checkmark.circle.fill" : "circle.fill") }
            }
            Button("Any colour") { filter.colors = nil }
        } label: { chipLabel(filter.colors.map { $0.map(\.rawValue).sorted().joined(separator: ", ") } ?? "Colour", "circle.lefthalf.filled") }
            .buttonStyle(ChipStyle(selected: filter.colors != nil))
    }

    private var kindChip: some View {
        Menu {
            Button("JPEG / HEIF") { filter.kinds = [.jpeg, .heif, .jpegXL] }
            Button("RAW") { filter.kinds = [.raw] }
            Button("Video") { filter.kinds = [.video] }
            Button("Any kind") { filter.kinds = nil }
        } label: { chipLabel(filter.kinds.map { $0.contains(.raw) ? "RAW" : ($0.contains(.video) ? "Video" : "JPEG") } ?? "Kind", "doc") }
            .buttonStyle(ChipStyle(selected: filter.kinds != nil))
    }

    private var tagChip: some View {
        Menu {
            TextField("Tag", text: $tagText).textInputAutocapitalization(.never).onSubmit { addTag(tagText) }
            ForEach(suggestions(tagText).prefix(8), id: \.self) { t in Button("#\(t)") { addTag(t) } }
            if let all = filter.tagsAll, !all.isEmpty {
                Divider()
                ForEach(all.sorted(), id: \.self) { t in Button { filter.tagsAll?.remove(t); if filter.tagsAll?.isEmpty == true { filter.tagsAll = nil } } label: { Label("Remove #\(t)", systemImage: "minus.circle") } }
            }
        } label: { chipLabel(filter.tagsAll.map { $0.sorted().map { "#\($0)" }.joined(separator: " ") } ?? "Tags", "number") }
            .buttonStyle(ChipStyle(selected: filter.tagsAll != nil))
    }

    private var dateChip: some View {
        Menu {
            Button("Today") { filter.dateRange = .today }
            Button("Last 7 days") { filter.dateRange = .last7Days }
            Button("Last 30 days") { filter.dateRange = .last30Days }
            Button("Any date") { filter.dateRange = nil }
        } label: { chipLabel(dateTitle, "calendar") }
            .buttonStyle(ChipStyle(selected: filter.dateRange != nil))
    }

    private var dateTitle: String {
        switch filter.dateRange {
        case .today?: return "Today"
        case .last7Days?: return "7 days"
        case .last30Days?: return "30 days"
        case .between?: return "Date range"
        case nil: return "Date"
        }
    }

    private var sessionChip: some View {
        Menu {
            ForEach(sessions.prefix(20)) { s in Button { toggle(&filter.sessionIDs, s.id) } label: { Label(s.name, systemImage: filter.sessionIDs?.contains(s.id) == true ? "checkmark" : "rectangle.stack") } }
            Button("Any session") { filter.sessionIDs = nil }
        } label: { chipLabel(sessionTitle, "rectangle.stack") }
            .buttonStyle(ChipStyle(selected: filter.sessionIDs != nil))
    }

    private var sessionTitle: String {
        guard let ids = filter.sessionIDs else { return "Session" }
        if ids.count == 1, let only = ids.first { return sessions.first { $0.id == only }?.name ?? "1 session" }
        return "\(ids.count) sessions"
    }

    private var cameraChip: some View {
        Menu {
            ForEach(cameras) { c in Button { toggle(&filter.cameraIDs, c.id) } label: { Label(c.displayName, systemImage: filter.cameraIDs?.contains(c.id) == true ? "checkmark" : "camera") } }
            Button("Any camera") { filter.cameraIDs = nil }
        } label: { chipLabel(cameraTitle, "camera") }
            .buttonStyle(ChipStyle(selected: filter.cameraIDs != nil))
    }

    private var cameraTitle: String {
        guard let ids = filter.cameraIDs else { return "Camera" }
        if ids.count == 1, let only = ids.first { return cameras.first { $0.id == only }?.displayName ?? "1 camera" }
        return "\(ids.count) cameras"
    }

    private var exportedChip: some View {
        Menu {
            Button("Exported") { filter.exportedTo = .any }
            Button("Not exported") { filter.exportedTo = .never }
            Button("To Photos") { filter.exportedTo = .photos }
            Button("To Files") { filter.exportedTo = .files }
            Button("To FTP") { filter.exportedTo = .ftp }
            Button("Either") { filter.exportedTo = nil }
        } label: { chipLabel(exportedTitle, "square.and.arrow.up") }
            .buttonStyle(ChipStyle(selected: filter.exportedTo != nil))
    }

    private var exportedTitle: String {
        switch filter.exportedTo {
        case nil: return "Exported?"
        case .never?: return "Not exported"
        case .any?: return "Exported"
        case .some(let d): return "To \(d.rawValue)"
        }
    }

    private func chipLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).lineLimit(1)
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>?, _ v: T) {
        var s = set ?? []
        if s.contains(v) { s.remove(v) } else { s.insert(v) }
        set = s.isEmpty ? nil : s
    }

    private func addTag(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "#", with: "")
        guard !t.isEmpty else { return }
        var all = filter.tagsAll ?? []
        all.insert(t)
        filter.tagsAll = all
        tagText = ""
    }
}

/// Chip button: `surface2` resting, `accentSoft` + accent hairline when selected. 44 pt tall.
struct ChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TetherFont.hud)
            .foregroundStyle(selected ? TetherColor.accent : TetherColor.ink0)
            .padding(.horizontal, TetherSpace.m)
            .frame(minHeight: 32)
            .tetherChip(selected: selected)
            .frame(minHeight: TetherHit.min)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
