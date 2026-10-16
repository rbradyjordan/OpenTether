import SwiftUI
import TetherCore

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onCreate: ((ShootSession) -> Void)? = nil

    @State private var name = ""
    @State private var destination: CaptureDestination = .both
    @State private var jpegTarget: RoutingRules.Target = .photos
    @State private var rawTarget: RoutingRules.Target = .files
    @State private var lookID: String?
    @State private var workflowTag = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Client · Location", text: $name)
                    TextField("Workflow tag (optional)", text: $workflowTag).textInputAutocapitalization(.never)
                }
                Section {
                    Picker("Capture destination", selection: $destination) {
                        ForEach(CaptureDestination.allCases) { d in Text(d.displayName).tag(d) }
                    }
                } header: { Text("Where the camera writes") } footer: {
                    Text(destinationHelp)
                }
                Section("Routing on export") {
                    Picker("JPEG / HEIF", selection: $jpegTarget) { targets([.photos, .files, .none]) }
                    Picker("RAW", selection: $rawTarget) { targets([.files, .cloud, .none]) }
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
            .onAppear {
                if name.isEmpty { name = "Shoot \(Date().formatted(date: .abbreviated, time: .omitted))" }
            }
        }
    }

    private func targets(_ list: [RoutingRules.Target]) -> some View {
        ForEach(list) { t in Text(t.displayName).tag(t) }
    }

    private var destinationHelp: String {
        switch destination {
        case .card: return "Frames stay on the card. Tether still lists them when the camera announces them but downloads nothing; good for speed on slow links."
        case .host: return "Frames go straight to the phone and are not written to the card. Fast, but a crash before download loses the frame."
        case .both: return "The camera writes the card and sends a copy. Safest choice."
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let session = ShootSession(name: trimmed.isEmpty ? "Untitled shoot" : trimmed, destination: destination,
                                   routing: RoutingRules(jpeg: jpegTarget, raw: rawTarget), lookID: lookID,
                                   workflowTag: workflowTag.isEmpty ? nil : workflowTag)
        app.createSession(session)
        onCreate?(session)
        dismiss()
    }
}
