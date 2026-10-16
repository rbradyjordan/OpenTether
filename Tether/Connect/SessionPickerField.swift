import SwiftUI
import TetherCore

/// "Which session does this connection feed?" Shared by the three connect screens.
struct SessionPickerField: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: ShootSession?
    @State private var showNew = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session").font(.caption).foregroundStyle(Theme.textSecondary)
                Text(selection?.name ?? "New session").font(.subheadline.weight(.medium))
            }
            Spacer()
            Menu {
                Button("New session…") { showNew = true }
                if !app.sessions.isEmpty {
                    Divider()
                    ForEach(app.sessions.filter { $0.status != .ended }.prefix(8)) { s in
                        Button(s.name) { selection = s }
                    }
                }
            } label: {
                Label("Choose", systemImage: "chevron.up.chevron.down").labelStyle(.iconOnly)
            }
            .accessibilityLabel("Choose session")
        }
        .padding(12)
        .cardBackground()
        .sheet(isPresented: $showNew) {
            NewSessionSheet { created in selection = created }
        }
        .onAppear {
            if selection == nil { selection = app.sessions.first { $0.status != .ended } }
        }
    }

    /// The session to use, creating a default one when none is picked.
    static func resolve(_ selection: ShootSession?, app: AppModel) -> ShootSession {
        if let selection { return selection }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let s = ShootSession(name: "Shoot \(formatter.string(from: Date()))")
        app.createSession(s)
        return s
    }
}
