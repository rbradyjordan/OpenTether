import SwiftUI
import TetherCore

/// Export for a session, a library selection or a collection. Starts from the
/// remembered settings (`WorkspaceMemory.lastExport`) and writes them back on
/// enqueue so "Export like last time" is one tap.
struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// nil when the frames may span sessions (library); one job per session is made.
    var sessionID: String?
    var items: [CaptureItem]
    var selectedID: String?
    var look: LookStack
    var selectionIDs: [String] = []
    var collectionName: String? = nil

    @State private var scope: ExportScope = .all
    @State private var minRating = 3
    @State private var destination: ExportDestinationChoice = .photos
    @State private var options = ExportOptions()
    @State private var resize = false
    @State private var longEdge = 2048
    @State private var ftpDestinations: [StoredFTPDestination] = []
    @State private var folderDestinations: [StoredFolderDestination] = []
    @State private var pickingFolder = false
    @State private var previewPaths: [String] = []
    @State private var error: String?
    @State private var loaded = false

    private var fromLibrary: Bool { sessionID == nil }
    private var effectiveScope: ExportScope { if case .rated = scope { return .rated(min: minRating) }; return scope }
    private var chosen: [CaptureItem] { effectiveScope.filter(items, selectedID: selectedID, selectionIDs: Set(selectionIDs)) }
    private var effectiveOptions: ExportOptions { var o = options; o.maxLongEdge = resize ? longEdge : nil; return o }
    private var previewItems: [ExportJob.Item] {
        chosen.filter { $0.kind != .raw || options.includeRAW }.filter { $0.kind.isStill }
            .map { ExportJob.Item(id: $0.id, filename: $0.filename, kind: $0.kind, bytes: $0.bytes) }
    }
    private var summaryLine: String {
        let raw = previewItems.filter { $0.kind == .raw }.count
        let photos = previewItems.count - raw
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if raw > 0 {
            let how = options.rawOutput == .original ? "RAW" : "RAW → \(options.rawOutput.displayName)"
            parts.append("\(raw) \(how)")
        }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " · ")
    }
    private var presets: [ExportScope] { fromLibrary ? ExportScope.presets(selectionCount: selectionIDs.count, inCollection: collectionName != nil) : ExportScope.presets }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                whereSection
                ExportOptionsSection(options: $options, resize: $resize, longEdge: $longEdge, lookIsNeutral: look.isNeutral)
                ExportNamingSection(options: $options, previewPaths: previewPaths)
                if let error { Section { Text(error).foregroundStyle(TetherColor.danger) } }
            }
            .tint(TetherColor.accent)
            .safeAreaInset(edge: .bottom) { quoteBar }
            .tetherList()
            .navigationTitle(collectionName.map { fromLibrary ? "Export · \($0)" : "Export" } ?? "Export")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear(perform: load)
            .task(id: previewKey) { await refreshPreview() }
        }
    }

    private var scopeSection: some View {
        Section("What") {
            if presets.count > 4 {
                scopePicker.pickerStyle(.menu)
            } else {
                scopePicker.pickerStyle(.segmented)
            }
            if case .rated = scope { Stepper("Minimum rating: \(minRating)", value: $minRating, in: 1 ... 5) }
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) { ForEach(presets) { s in Text(s.title).tag(s) } }
    }

    private var whereSection: some View {
        Section("Where") {
            Picker("Destination", selection: $destination) {
                Text("Photos").tag(ExportDestinationChoice.photos)
                Text("On My iPhone › Exports").tag(ExportDestinationChoice.files)
                ForEach(folderDestinations) { d in
                    Label(d.name, systemImage: FolderDestinationsView.symbol(for: d.kind)).tag(ExportDestinationChoice.folder(d.id))
                }
                Text("Share").tag(ExportDestinationChoice.share)
                ForEach(ftpDestinations) { d in Text("FTP · \(d.name)").tag(ExportDestinationChoice.ftp(d.id)) }
            }
            if let folder = chosenFolder {
                LabeledContent("Location") {
                    Text(folder.displayPath ?? folder.name).font(TetherFont.hud).foregroundStyle(TetherColor.ink1).lineLimit(2)
                }
                if folder.kind != .plain {
                    Label(folder.kind == .captureOneSession ? "Capture One session: photos go into Capture, Selects and Trash."
                                                           : "Lightroom Auto Import: one flat folder, sidecars written first.",
                          systemImage: "checkmark.seal")
                        .font(TetherFont.hud).foregroundStyle(TetherColor.ok)
                }
            }
            Button { pickingFolder = true } label: { Label("Add a folder from Files…", systemImage: "folder.badge.plus") }
            NavigationLink("FTP destinations", value: AppRoute.ftpDestinations)
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                let saved = try FolderAccess.destination(for: url)
                try app.store.save(saved)
                folderDestinations = (try? app.store.folderDestinations()) ?? []
                destination = .folder(saved.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onChange(of: destination) { _, _ in
            // Tool-shaped folders bring their own layout.
            if let layout = chosenFolder?.suggestedLayout { options.layout = layout }
        }
    }

    private var chosenFolder: StoredFolderDestination? {
        guard case .folder(let id) = destination else { return nil }
        return folderDestinations.first { $0.id == id }
    }

    /// What will go out, plus the one action; sits in the thumb zone.
    private var quoteBar: some View {
        VStack(spacing: TetherSpace.m) {
            Text(summaryLine)
                .font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())
                .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: summaryLine)
            Button { Task { await enqueue() } } label: {
                Text(previewItems.isEmpty ? "Nothing to export" : "Export \(previewItems.count)")
                    .font(TetherFont.headline).frame(maxWidth: .infinity, minHeight: TetherHit.min + 6).contentTransition(.numericText())
            }
            .buttonStyle(.tetherPrimary).disabled(previewItems.isEmpty)
        }
        .padding(TetherSpace.l)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(TetherColor.hairline).frame(height: 0.5) }
    }

    // MARK: Memory

    private func load() {
        ftpDestinations = (try? app.store.ftpDestinations()) ?? []
        folderDestinations = (try? app.store.folderDestinations()) ?? []
        guard !loaded else { return }
        loaded = true
        let last = app.memory.get(WorkspaceMemory.lastExport)
        destination = ExportDestinationChoice(last.destination)
        options = last.options
        resize = last.options.maxLongEdge != nil
        longEdge = last.options.maxLongEdge ?? 2048
        if look.isNeutral { options.applyLook = false }
        if let s = ExportScope.from(memory: last.scope, selectionCount: selectionIDs.count, inCollection: collectionName != nil), presets.contains(where: { $0.id == s.id }) || s.id.hasPrefix("rated") {
            scope = s
            if case .rated(let n) = s { minRating = n; scope = .rated(min: 3) }
        } else if !selectionIDs.isEmpty, fromLibrary {
            scope = .selection(selectionIDs.count)
        }
    }

    private func remember() {
        var m = app.memory.get(WorkspaceMemory.lastExport)
        m.destination = destination.destination
        m.options = effectiveOptions
        m.scope = effectiveScope.id
        app.memory.set(WorkspaceMemory.lastExport, m)
    }

    // MARK: Jobs

    private var previewKey: String { "\(effectiveScope.id)|\(options.naming.pattern)|\(options.layout.rawValue)|\(options.includeRAW)|\(options.rawOutput.rawValue)|\(options.writeSidecars)|\(options.writeManifest)|\(chosen.count)" }

    /// First three delivered paths of the jobs this sheet would enqueue.
    private func refreshPreview() async {
        var paths: [String] = []
        for job in await makeJobs() where paths.count < 3 {
            paths += job.items.filter { !$0.isCompanion }.prefix(3 - paths.count).map(\.deliveredRelativePath)
        }
        previewPaths = paths
    }

    private func makeJobs() async -> [ExportJob] {
        var jobs: [ExportJob] = []
        let groups = Dictionary(grouping: chosen, by: \.sessionID)
        for (sid, group) in groups.sorted(by: { $0.key < $1.key }) {
            guard let session = try? app.store.session(sid) else { continue }
            let jobLook = fromLibrary ? LookStack(lookID: session.lookID, strength: session.lookStrength) : look
            let job = await app.exportQueue.makeJob(session: session, captures: group, destination: destination.destination,
                                                    options: effectiveOptions, look: jobLook)
            if !job.items.isEmpty { jobs.append(job) }
        }
        return jobs
    }

    private func enqueue() async {
        let jobs = await makeJobs()
        guard !jobs.isEmpty else { error = fromLibrary ? "Nothing to export" : "Session not found"; return }
        do {
            for job in jobs { try await app.exportQueue.enqueue(job) }
            remember()
            let n = jobs.reduce(0) { $0 + $1.items.filter { !$0.isCompanion }.count }
            app.toast = ToastMessage(text: "Exporting \(n) frames to \(destination.destination.displayName)", systemImage: "arrow.up.doc")
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Look, RAW, resize, quality.
private struct ExportOptionsSection: View {
    @Binding var options: ExportOptions
    @Binding var resize: Bool
    @Binding var longEdge: Int
    var lookIsNeutral: Bool

    var body: some View {
        Section("Options") {
            Button {
                // What listing services and agents want: sRGB JPEGs around
                // 2048 px, no RAW, named by address and room.
                resize = true; longEdge = 2048
                options.jpegQuality = 0.86
                options.includeRAW = false
                options.naming = .listing
                options.layout = .flat
                options.writeSidecars = false
                options.writeManifest = false
            } label: {
                Label("Set up for MLS / listing delivery", systemImage: "house")
            }
            Toggle("Apply look", isOn: $options.applyLook).disabled(lookIsNeutral)
            Toggle("Include RAW files", isOn: $options.includeRAW)
            if options.includeRAW {
                Picker("RAW as", selection: $options.rawOutput) {
                    ForEach(RAWOutput.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Toggle("Resize", isOn: $resize)
            if resize {
                Picker("Long edge", selection: $longEdge) {
                    Text("1024 px").tag(1024); Text("2048 px").tag(2048); Text("3000 px").tag(3000); Text("4096 px").tag(4096)
                }
            }
            VStack(alignment: .leading) {
                Text("JPEG quality \(Int(options.jpegQuality * 100))").contentTransition(.numericText())
                Slider(value: $options.jpegQuality, in: 0.5 ... 1, step: 0.02) { Text("JPEG quality") }
            }
        }
    }
}

/// Filename template, folder layout, metadata companions, and the path preview.
private struct ExportNamingSection: View {
    @Binding var options: ExportOptions
    var previewPaths: [String]

    private var presetIDs: [String] { NamingTemplate.presets.map(\.pattern) }

    var body: some View {
        Section {
            Picker("Naming", selection: $options.naming.pattern) {
                ForEach(NamingTemplate.presets, id: \.pattern) { t in Text(t.pattern).tag(t.pattern) }
                if !presetIDs.contains(options.naming.pattern) { Text("Custom").tag(options.naming.pattern) }
            }
            TextField("Pattern", text: $options.naming.pattern).textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.body, design: .monospaced))
            Picker("Folders", selection: $options.layout) { ForEach(FolderLayout.allCases) { Text($0.displayName).tag($0) } }
            Toggle("Embed XMP in JPEGs", isOn: $options.embedMetadata)
            Toggle("Write .xmp sidecars", isOn: $options.writeSidecars)
            Toggle("Write manifest (JSON + CSV)", isOn: $options.writeManifest)
        } header: { Text("Files") } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tokens: {orig} {session} {date} {seq:4} {camera} {client} {room} {bracket} {rating} {label} {pick}")
                ForEach(previewPaths, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).foregroundStyle(TetherColor.ink0) }
            }
        }
    }
}
