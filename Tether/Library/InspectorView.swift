import SwiftUI
import TetherCore

/// Right pane on iPad, sheet on iPhone. Describes the selected (or focused)
/// frame; every control routes through the dispatcher so it is undoable.
struct InspectorView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LibraryModel
    @State private var tags: [String] = []
    @State private var memberships: [String] = []
    @State private var history: [(destination: String, at: Date, remoteID: String?)] = []
    @State private var exif: EXIFSummary?

    private var item: CaptureItem? { model.inspectedItem }
    private var ids: [String] { model.selection.isEmpty ? (item.map { [$0.id] } ?? []) : model.selection.ids }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: TetherSpace.m) {
                    preview(item)
                    if model.selection.count > 1 {
                        Text("\(model.selection.count) selected · showing \(item.filename)").font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                    }
                    InspectorFacts(item: item, session: model.sessions.first { $0.id == item.sessionID }, camera: model.cameras.first { $0.id == item.cameraID }, look: app.looks.first { $0.id == item.lookID }, exif: exif)
                    reviewCard(item)
                    SectionCard(title: "Tags", systemImage: "number") { TagEditor(tags: tags, suggestions: model.tagSuggestions(prefix:), onAdd: addTag, onRemove: removeTag) }
                    collectionsCard
                    exportsCard
                    revealButton(item)
                }
                .padding(TetherSpace.l)
            } else {
                EmptyState(systemImage: "photo", title: "Nothing selected", message: "Tap a photo to inspect it.")
            }
        }
        .background(TetherColor.surface1)
        .task(id: "\(item?.id ?? "")|\(item?.rating ?? 0)|\(item?.flag.rawValue ?? "")") { refresh() }
    }

    private func preview(_ item: CaptureItem) -> some View {
        AsyncImageView(cache: app.cache, relativePath: item.previewRelativePath ?? item.thumbnailRelativePath, contentMode: .fit, maxPixelSize: 1600)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 160, maxHeight: 320)
            .background(TetherColor.surface0, in: RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous))
            .onTapGesture { model.loupeID = item.id }
            .accessibilityLabel("Preview of \(item.filename), double tap to open the loupe")
            .accessibilityAddTraits(.isButton)
    }

    private func reviewCard(_ item: CaptureItem) -> some View {
        SectionCard(title: "Review", systemImage: "star") {
            HStack(spacing: TetherSpace.m) {
                FlagButton(kind: .reject, flag: item.flag) { app.commands.flag(ids, $0) }
                Spacer(minLength: 0)
                RatingStars(rating: item.rating, size: 24) { app.commands.rate(ids, $0) }
                Spacer(minLength: 0)
                FlagButton(kind: .pick, flag: item.flag) { app.commands.flag(ids, $0) }
            }
            ColorLabelPicker(current: item.colorLabel) { app.commands.label(ids, $0) }
        }
    }

    private var collectionsCard: some View {
        SectionCard(title: "Collections", systemImage: "rectangle.stack") {
            ForEach(memberships, id: \.self) { cid in
                if let c = model.collection(cid) {
                    HStack {
                        Label(c.name, systemImage: c.symbol).font(TetherFont.body).foregroundStyle(TetherColor.ink0)
                        Spacer()
                        Button { app.commands.remove(ids, from: cid) } label: { Image(systemName: "minus.circle").frame(width: TetherHit.min, height: TetherHit.min) }
                            .accessibilityLabel("Remove from \(c.name)")
                    }
                }
            }
            Button { app.commands.request = .addToCollection(ids: ids) } label: { Label("Add to collection…", systemImage: "plus") }
                .frame(minHeight: TetherHit.min)
        }
    }

    private var exportsCard: some View {
        SectionCard(title: "Export history", systemImage: "square.and.arrow.up") {
            if history.isEmpty {
                Text("Not exported yet").font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
            }
            ForEach(Array(history.enumerated()), id: \.offset) { _, h in
                HStack {
                    Text(h.destination.capitalized).font(TetherFont.body).foregroundStyle(TetherColor.ink0)
                    Spacer()
                    Text(h.at.formatted(date: .abbreviated, time: .shortened)).font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                }
                .frame(minHeight: 32)
            }
        }
    }

    private func revealButton(_ item: CaptureItem) -> some View {
        Button {
            model.select(.session(item.sessionID))
            model.focusedID = item.id
            model.scrollToCaptureID = item.id
        } label: { Label("Reveal in session", systemImage: "rectangle.stack.badge.person.crop") }
            .buttonStyle(.bordered)
            .frame(minHeight: TetherHit.min)
    }

    private func refresh() {
        guard let id = item?.id else { tags = []; memberships = []; history = []; exif = nil; return }
        tags = model.tags(for: id)
        memberships = model.collectionIDs(containing: id)
        history = model.exportHistory(for: id)
        exif = nil
        // EXIF comes from the file itself; JPEG/HEIF originals or the RAW's proxy.
        if let path = item?.previewRelativePath, let data = try? app.cache.load(path) { exif = try? EXIFReader.read(data) }
    }

    private func addTag(_ t: String) { app.commands.addTags([t], to: ids); tags = Array(Set(tags + [t])).sorted() }
    private func removeTag(_ t: String) { app.commands.removeTags([t], from: ids); tags.removeAll { $0 == t } }
}

/// Filename, session, camera, exposure line, dimensions, bytes, look.
struct InspectorFacts: View {
    var item: CaptureItem
    var session: ShootSession?
    var camera: CameraIdentity?
    var look: LookDescriptor?
    var exif: EXIFSummary?

    var body: some View {
        SectionCard(title: nil) {
            Text(item.filename).font(TetherFont.headline).foregroundStyle(TetherColor.ink0).lineLimit(1)
            fact("Session", session?.name ?? "—")
            fact("Camera", camera?.displayName ?? (exif?.cameraLine.isEmpty == false ? exif!.cameraLine : "—"))
            if let lens = exif?.lens, !lens.isEmpty { fact("Lens", lens) }
            if let line = item.exposure?.line, !line.isEmpty { fact("Exposure", line) }
            else if let line = exif?.exposureLine, !line.isEmpty { fact("Exposure", line) }
            if let shot = exif?.dateTimeOriginal { fact("EXIF time", shot.formatted(date: .abbreviated, time: .standard)) }
            fact("Size", "\(item.width) × \(item.height) · \(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))")
            fact("Captured", item.capturedAt.formatted(date: .abbreviated, time: .standard))
            fact("Look", look?.name ?? (item.lookID == nil ? "None" : "Applied"))
            if item.isRAW { fact("Kind", "RAW") }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).tetherCaption().foregroundStyle(TetherColor.ink2).frame(width: 72, alignment: .leading)
            Text(value).font(TetherFont.callout).foregroundStyle(TetherColor.ink0).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
