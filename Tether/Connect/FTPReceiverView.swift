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

    private var loginChanged: Bool {
        username != app.settings.ftpUsername || password != app.settings.ftpPassword || port != String(app.settings.ftpPort)
    }

    var body: some View {
        let receiver = app.ftpReceiver
        ScrollView {
            VStack(spacing: TetherSpace.m) {
                ScreenIntro(text: "Your camera uploads each photo to the phone over Wi-Fi as you shoot.")
                SessionPickerField(selection: $session)
                SectionCard(title: "1 · Login the camera uses", systemImage: "person.badge.key") {
                    LabeledField("Username") {
                        TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.tether).accessibilityLabel("FTP username")
                    }
                    HStack(spacing: TetherSpace.m) {
                        LabeledField("Password") {
                            TextField("Password", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .monospaced().textFieldStyle(.tether).accessibilityLabel("FTP password")
                        }
                        LabeledField("Port") {
                            TextField("Port", text: $port).keyboardType(.numberPad).monospacedDigit()
                                .textFieldStyle(.tether).accessibilityLabel("FTP port")
                        }
                        .frame(width: 96)
                    }
                    if loginChanged {
                        Button("Save login") {
                            app.settings.ftpUsername = username
                            app.settings.ftpPassword = password
                            if let p = UInt16(port), p > 0 { app.settings.ftpPort = p }
                            receiver.restartIfRunning()
                        }
                        .buttonStyle(.tetherSecondary)
                        .controlSize(.small)
                        .disabled(username.isEmpty || password.isEmpty)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(TetherMotion.snap, value: loginChanged)
                SectionCard(title: "2 · Set up the camera", systemImage: "camera.badge.ellipsis") {
                    Picker("Brand", selection: $guideVendor) {
                        ForEach(BrandGuide.ftpCapable) { v in Text(v.displayName).tag(v) }
                    }
                    .pickerStyle(.menu)
                    Text(BrandGuide.ftpInstructions(for: guideVendor, host: receiver.primaryAddress ?? "<phone IP>", port: receiver.boundPort ?? receiver.port,
                                                    username: receiver.username))
                        .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                startButton(receiver)
                SectionCard(title: "FTP server on this phone", systemImage: "antenna.radiowaves.left.and.right") {
                    Toggle(isOn: Binding(get: { receiver.isRunning }, set: { on in on ? receiver.start() : receiver.stop() })) {
                        Label(receiver.isRunning ? "Listening" : "Stopped", systemImage: receiver.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                            .font(TetherFont.callout.weight(.medium))
                            .foregroundStyle(receiver.isRunning ? TetherColor.ok : TetherColor.ink1)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .tint(TetherColor.accent)
                    .accessibilityLabel("FTP server")
                    if receiver.isRunning {
                        LabeledContent("Address") {
                            Text("\(receiver.primaryAddress ?? "–"):\(receiver.boundPort ?? receiver.port)")
                                .font(.body.monospaced()).textSelection(.enabled)
                        }
                        LabeledContent("Cameras connected") { Text("\(receiver.clients)").monospacedDigit() }
                    }
                    if let error = receiver.lastError { Text(error).font(.footnote).foregroundStyle(TetherColor.danger) }
                }
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
            .padding(TetherSpace.l)
        }
        .tetherScreen()
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
            Label("3 · Start shooting", systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.tetherPrimary)
        .controlSize(.large)
        .disabled(starting)
    }
}
