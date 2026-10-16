import SwiftUI
import TetherCore

struct FTPDestinationsView: View {
    @Environment(AppModel.self) private var app
    @State private var destinations: [StoredFTPDestination] = []
    @State private var editing: StoredFTPDestination?
    @State private var creating = false

    var body: some View {
        List {
            if destinations.isEmpty {
                EmptyState(systemImage: "server.rack", title: "No FTP destinations",
                           message: "Add a studio or client server to push exports straight to it.", actionTitle: "Add destination") { creating = true }
                    .listRowBackground(Color.clear)
            }
            ForEach(destinations) { d in
                Button { editing = d } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.headline).foregroundStyle(.primary)
                        Text("\(d.username)@\(d.host):\(d.port) · \(d.security) · \(d.remoteDirectory)").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets {
                    let d = destinations[i]
                    try? app.store.deleteFTPDestination(d.id)
                    app.services.keychain.write(d.passwordKeychainKey, nil)
                }
                reload()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("FTP destinations")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Label("Add", systemImage: "plus") } } }
        .sheet(isPresented: $creating) { FTPDestinationEditor(destination: nil) { reload() } }
        .sheet(item: $editing) { d in FTPDestinationEditor(destination: d) { reload() } }
        .onAppear(perform: reload)
    }

    private func reload() { destinations = (try? app.store.ftpDestinations()) ?? [] }
}

struct FTPDestinationEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var destination: StoredFTPDestination?
    var onSave: () -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "21"
    @State private var username = ""
    @State private var password = ""
    @State private var security: FTPSecurity = .explicitTLS
    @State private var passive = true
    @State private var directory = "/"
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    Picker("Security", selection: $security) {
                        Text("Plain FTP").tag(FTPSecurity.plain)
                        Text("Explicit TLS (FTPES)").tag(FTPSecurity.explicitTLS)
                        Text("Implicit TLS (990)").tag(FTPSecurity.implicitTLS)
                    }
                    Toggle("Passive mode", isOn: $passive)
                }
                Section("Login") {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    TextField("Remote directory", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.disabled(testing || host.isEmpty)
                    if let testResult { Text(testResult).font(.footnote) }
                }
            }
            .navigationTitle(destination == nil ? "New destination" : "Edit destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.isEmpty || host.isEmpty || username.isEmpty) }
            }
            .onAppear {
                guard let d = destination else { return }
                name = d.name; host = d.host; port = String(d.port); username = d.username
                security = FTPSecurity(rawValue: d.security) ?? .explicitTLS; passive = d.passive; directory = d.remoteDirectory
                password = app.services.keychain.read(d.passwordKeychainKey) ?? ""
            }
            .onChange(of: security) { _, s in if s == .implicitTLS, port == "21" { port = "990" } else if s != .implicitTLS, port == "990" { port = "21" } }
        }
    }

    private var draft: FTPDestination {
        FTPDestination(host: host, port: UInt16(port) ?? 21, username: username, password: password, security: security, passive: passive, remoteDirectory: directory)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do { testResult = try await FTPClientFactory.make(draft).test() } catch { testResult = "Failed: \(error)" }
    }

    private func save() {
        var stored = destination ?? StoredFTPDestination(name: name, host: host, username: username)
        stored.name = name; stored.host = host; stored.port = UInt16(port) ?? 21; stored.username = username
        stored.security = security.rawValue; stored.passive = passive; stored.remoteDirectory = directory
        try? app.store.save(stored)
        app.services.keychain.write(stored.passwordKeychainKey, password)
        onSave()
        dismiss()
    }
}
