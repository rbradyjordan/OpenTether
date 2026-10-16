import SwiftUI
import TetherCore

/// New session: pick a template (most recent first), "Last settings" or
/// "Blank", then adjust. The name is prefilled from the template's pattern.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onCreate: ((ShootSession) -> Void)? = nil

    enum Start: Hashable { case template(String), last, blank }

    @State private var start: Start = .last
    @State private var name = ""
    @State private var destination: CaptureDestination = .both
    @State private var jpegTarget: RoutingRules.Target = .photos
    @State private var rawTarget: RoutingRules.Target = .files
    @State private var lookID: String?
    @State private var autoExportPicks = false
    @State private var workflowTag = ""
    @State private var editingTemplate: WorkspaceMemory.SessionTemplate?

    private var templates: [WorkspaceMemory.SessionTemplate] { app.memory.templates() }
    private var index: Int { TemplateNaming.nextIndex(sessionCount: app.sessions.count) }
    private var camera: CameraIdentity? { app.shoot?.identity }

    var body: some View {
        NavigationStack {
            Form {
                Section("Start from") { TemplateRow(templates: templates, start: $start, onEdit: { editingTemplate = $0 }).listRowInsets(EdgeInsets()) }
                Section("Name") {
                    TextField("Client · Location", text: $name)
                    TextField("Workflow tag (optional)", text: $workflowTag).textInputAutocapitalization(.never)
                }
                Section {
                    Picker("Capture destination", selection: $destination) { ForEach(CaptureDestination.allCases) { d in Text(d.displayName).tag(d) } }
                } header: { Text("Where the camera writes") } footer: { Text(destinationHelp) }
                Section("Routing on export") {
                    Picker("JPEG / HEIF", selection: $jpegTarget) { targets([.photos, .files, .none]) }
                    Picker("RAW", selection: $rawTarget) { targets([.files, .cloud, .none]) }
                    Toggle("Export picks automatically", isOn: $autoExportPicks)
                }
                Section("Look") {
                    Picker("Look", selection: $lookID) {
                        Text("None").tag(String?.none)
                        ForEach(app.looks) { look in Text(look.name).tag(String?.some(look.id)) }
                    }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create() } }
            }
            .sheet(item: $editingTemplate) { t in TemplateEditor(template: t, isNew: false) }
            .onAppear { applyStart(initial: true) }
            .onChange(of: start) { _, _ in applyStart(initial: false) }
        }
    }

    private func targets(_ list: [RoutingRules.Target]) -> some View { ForEach(list) { t in Text(t.displayName).tag(t) } }

    private var destinationHelp: String {
        switch destination {
        case .card: return "Frames stay on the card. Open Tether still lists them when the camera announces them but downloads nothing; good for speed on slow links."
        case .host: return "Frames go straight to the phone and are not written to the card. Fast, but a crash before download loses the frame."
        case .both: return "The camera writes the card and sends a copy. Safest choice."
        }
    }

    /// Fills the form from the chosen start without recording a template use
    /// (that happens on Create, through `memory.configure`).
    private func applyStart(initial: Bool) {
        if initial, let suggested = app.memory.suggestedTemplate(for: camera) { start = .template(suggested.id); return }
        switch start {
        case .template(let id):
            guard let t = templates.first(where: { $0.id == id }) else { return }
            destination = t.destination; jpegTarget = t.routing.jpeg; rawTarget = t.routing.raw
            lookID = t.look.lookID; autoExportPicks = t.autoExportPicks
            name = TemplateNaming.expand(t, camera: camera, index: index)
        case .last:
            let d = app.memory.get(WorkspaceMemory.sessionDefaults)
            destination = d.destination; jpegTarget = d.routing.jpeg; rawTarget = d.routing.raw
            lookID = d.look.lookID; autoExportPicks = d.autoExportPicks
            name = TemplateNaming.preview(pattern: d.namePattern, templateName: "Shoot", cameraName: camera?.displayName, index: index)
        case .blank:
            destination = .both; jpegTarget = .photos; rawTarget = .files; lookID = nil; autoExportPicks = false
            name = "Shoot \(Date().formatted(date: .abbreviated, time: .omitted))"
        }
    }

    private func create() {
        var session = ShootSession(name: "", destination: destination, routing: RoutingRules(jpeg: jpegTarget, raw: rawTarget, autoExportPicks: autoExportPicks),
                                   lookID: lookID, workflowTag: workflowTag.isEmpty ? nil : workflowTag)
        if case .template(let id) = start, let t = templates.first(where: { $0.id == id }) {
            app.memory.configure(&session, with: t, camera: camera, index: index)
        } else if start == .last {
            app.memory.configure(&session, with: nil, camera: camera, index: index)
        }
        // The form's edits win over whatever the template or memory set.
        session.destination = destination
        session.routing = RoutingRules(jpeg: jpegTarget, raw: rawTarget, autoExportPicks: autoExportPicks)
        session.lookID = lookID
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        session.name = trimmed.isEmpty ? "Untitled shoot" : trimmed
        app.createSession(session)
        onCreate?(session)
        dismiss()
    }
}

/// Horizontal cards: templates (most recent first), Last settings, Blank.
private struct TemplateRow: View {
    var templates: [WorkspaceMemory.SessionTemplate]
    @Binding var start: NewSessionSheet.Start
    var onEdit: (WorkspaceMemory.SessionTemplate) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TetherSpace.s) {
                ForEach(templates) { t in
                    Button { start = .template(t.id) } label: {
                        TemplateCard(title: t.name, symbol: t.symbol, detail: detail(t), selected: start == .template(t.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button { onEdit(t) } label: { Label("Edit template", systemImage: "pencil") } }
                }
                Button { start = .last } label: { TemplateCard(title: "Last settings", symbol: "clock.arrow.circlepath", detail: "How the previous session was set up", selected: start == .last) }.buttonStyle(.plain)
                Button { start = .blank } label: { TemplateCard(title: "Blank", symbol: "square.dashed", detail: "Defaults, nothing remembered", selected: start == .blank) }.buttonStyle(.plain)
            }
            .padding(TetherSpace.m)
        }
    }

    private func detail(_ t: WorkspaceMemory.SessionTemplate) -> String {
        var parts = [t.destination.displayName]
        if t.autoExportPicks { parts.append("auto-export picks") }
        if !t.tags.isEmpty { parts.append(t.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}
