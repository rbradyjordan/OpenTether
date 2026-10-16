import SwiftUI
import TetherCore

struct FTPReceiverView: View {
    @Environment(AppModel.self) private var app
    @State private var session: ShootSession?
    @State private var username = ""
    @State private var password = ""
    @State private var port = ""
    @State private var guideVendor: CameraVendor = .canon
    @State private var starting = false

    var body: some View {
        let receiver = app.ftpReceiver
        ScrollView {
            VStack(spacing: 12) {
                SessionPickerField(selection: $session)
                SectionCard(title: "FTP server on this phone", systemImage: "antenna.radiowaves.left.and.right") {
                    Toggle(isOn: Binding(get: { receiver.isRunning }, set: { on in on ? receiver.start() : receiver.stop() })) {
                        Text(receiver.isRunning ? "Listening" : "Stopped").font(.subheadline.weight(.medium))
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("FTP server")
                    if receiver.isRunning {
                        LabeledContent("Address") {
                            Text("\(receiver.primaryAddress ?? "–"):\(receiver.boundPort ?? receiver.port)")
                                .font(.body.monospaced()).textSelection(.enabled)
                        }
                        LabeledContent("Clients") { Text("\(receiver.clients)") }
                    }
                    if let error = receiver.lastError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                }
                SectionCard(title: "Login the camera uses", systemImage: "person.badge.key") {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).accessibilityLabel("FTP username")
                    TextField("Password", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).accessibilityLabel("FTP password")
                    TextField("Port", text: $port).keyboardType(.numberPad).textFieldStyle(.roundedBorder).accessibilityLabel("FTP port")
                    Button("Save") {
                        app.settings.ftpUsername = username
                        app.settings.ftpPassword = password
                        if let p = UInt16(port), p > 0 { app.settings.ftpPort = p }
                        receiver.restartIfRunning()
                    }
                    .buttonStyle(.bordered)
                    .disabled(username.isEmpty || password.isEmpty)
                }
                SectionCard(title: "Set up the camera", systemImage: "camera.badge.ellipsis") {
                    Picker("Brand", selection: $guideVendor) {
                        ForEach(BrandGuide.ftpCapable) { v in Text(v.displayName).tag(v) }
                    }
                    .pickerStyle(.menu)
                    Text(BrandGuide.ftpInstructions(for: guideVendor, host: receiver.primaryAddress ?? "<phone IP>", port: receiver.boundPort ?? receiver.port,
                                                    username: receiver.username))
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                startButton(receiver)
                SectionCard(title: "Received files", systemImage: "tray.and.arrow.down") {
                    if receiver.received.isEmpty {
                        Text("Nothing received yet. Take a picture once the camera shows the FTP connection as OK.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(receiver.received.prefix(30)) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(file.name).font(.subheadline)
                                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)) from \(file.from) in \(String(format: "%.1f", file.duration)) s")
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Text(file.at, style: .time).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("FTP push")
        .onAppear {
            username = app.settings.ftpUsername
            password = app.settings.ftpPassword
            port = String(app.settings.ftpPort)
        }
    }

    private func startButton(_ receiver: FTPReceiverModel) -> some View {
        Button {
            starting = true
            Task {
                defer { starting = false }
                if !receiver.isRunning { receiver.start() }
                let shoot = SessionPickerField.resolve(session, app: app)
                if let connection = try? await ConnectionBuilder.startFTPSession(shoot: shoot, services: app.services) {
                    app.activate(connection)
                }
            }
        } label: {
            Label("Start session from FTP", systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(starting)
    }
}
