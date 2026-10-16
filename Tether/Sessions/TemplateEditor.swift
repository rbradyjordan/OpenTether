import SwiftUI
import TetherCore

/// Create or edit a `SessionTemplate`: name, symbol, destination, routing,
/// look, name pattern (with live preview), tags, auto-export of picks.
struct TemplateEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var template: WorkspaceMemory.SessionTemplate
    var isNew: Bool

    @State private var tagText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    TextField("Name (Headshots, Lookbook…)", text: $template.name)
                    SymbolPicker(selected: $template.symbol)
                }
                Section {
                    TextField("Pattern", text: $template.namePattern).textInputAutocapitalization(.never)
                    LabeledContent("Example", value: TemplateNaming.preview(pattern: template.namePattern, templateName: template.name, cameraName: app.shoot?.cameraName, index: TemplateNaming.nextIndex(sessionCount: app.sessions.count)))
                } header: { Text("Session name") } footer: { Text("Tokens: " + TemplateNaming.placeholders.joined(separator: " ")) }
                Section("Capture") {
                    Picker("Camera writes to", selection: $template.destination) { ForEach(CaptureDestination.allCases) { Text($0.displayName).tag($0) } }
                    Toggle("Show newest capture", isOn: $template.showNewestCapture)
                    Picker("Look", selection: $template.look.lookID) {
                        Text("None").tag(String?.none)
                        ForEach(app.looks) { look in Text(look.name).tag(String?.some(look.id)) }
                    }
                }
                Section("Routing on export") {
                    Picker("JPEG / HEIF", selection: $template.routing.jpeg) { ForEach([RoutingRules.Target.photos, .files, .none]) { Text($0.displayName).tag($0) } }
                    Picker("RAW", selection: $template.routing.raw) { ForEach([RoutingRules.Target.files, .ftp, .none]) { Text($0.displayName).tag($0) } }
                    Toggle("Export picks automatically", isOn: $template.autoExportPicks)
                }
                Section("Every frame gets") {
                    TagEditor(tags: template.tags, suggestions: app.library.tagSuggestions(prefix:),
                              onAdd: { if !template.tags.contains($0) { template.tags.append($0) } },
                              onRemove: { t in template.tags.removeAll { $0 == t } })
                    Picker("Added to collection", selection: $template.addToCollectionID) {
                        Text("None").tag(String?.none)
                        ForEach(app.library.manual) { c in Text(c.name).tag(String?.some(c.id)) }
                    }
                }
                if !isNew {
                    Section { Button("Delete template", role: .destructive) { app.memory.deleteTemplate(template.id); dismiss() } }
                }
            }
            .tetherList()
            .navigationTitle(isNew ? "Save as template" : "Edit template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { app.memory.save(template: template); app.toast = ToastMessage(text: "Saved template \(template.name)", systemImage: template.symbol); dismiss() }
                        .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// One card in the New Session sheet's template row.
struct TemplateCard: View {
    var title: String
    var symbol: String
    var detail: String
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.xs) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(selected ? TetherColor.accent : TetherColor.ink1)
            Spacer(minLength: 0)
            Text(title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0).lineLimit(1)
            Text(detail).font(TetherFont.hud).foregroundStyle(TetherColor.ink1).lineLimit(2)
        }
        .padding(TetherSpace.m)
        .frame(width: 140, height: 104, alignment: .leading)
        .tetherChip(selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
