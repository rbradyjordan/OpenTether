import SwiftUI
import TetherCore

/// Grouped settings: everyday sections first, developer details under Advanced.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var cloudURL = ""
    @State private var ftpUser = ""
    @State private var ftpPassword = ""
    @State private var ftpPort = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    SettingsLabel("Cloud", systemImage: "icloud")
                    Spacer()
                    cloudStatus.font(TetherFont.callout)
                }
                .accessibilityElement(children: .combine)
                NavigationLink(value: AppRoute.credits) { SettingsLabel("Credits", systemImage: "creditcard") }
            } header: { Text("Account") } footer: {
                Text("Credits pay for cloud looks, colour match and batch exports. Everything else works offline.")
            }

            Section {
                LabeledContent("Username") {
                    TextField("Username", text: $ftpUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing).foregroundStyle(TetherColor.ink1)
                }
                LabeledContent("Password") {
                    TextField("Password", text: $ftpPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing).foregroundStyle(TetherColor.ink1).monospaced()
                }
                LabeledContent("Port") {
                    TextField("Port", text: $ftpPort).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing).foregroundStyle(TetherColor.ink1).monospacedDigit()
                }
                Button("Save FTP login") {
                    app.settings.ftpUsername = ftpUser
                    app.settings.ftpPassword = ftpPassword
                    if let p = UInt16(ftpPort), p > 0 { app.settings.ftpPort = p }
                    app.ftpReceiver.restartIfRunning()
                }
                .disabled(ftpUser.isEmpty || ftpPassword.isEmpty)
            } header: { Text("FTP receiver") } footer: {
                Text("Enter the same username, password and port in your camera's FTP settings.")
            }

            Section("Exports") {
                NavigationLink(value: AppRoute.ftpDestinations) { SettingsLabel("FTP destinations", systemImage: "server.rack") }
                NavigationLink(value: AppRoute.metadata) { SettingsLabel("Creator & copyright", systemImage: "person.text.rectangle") }
            }

            Section("Help") {
                NavigationLink(value: AppRoute.brandGuides) { SettingsLabel("Camera setup guides", systemImage: "book.pages") }
                NavigationLink(value: AppRoute.testedCameras) { SettingsLabel("Tested cameras", systemImage: "camera") }
                NavigationLink(value: AppRoute.diagnostics(wired: true)) { SettingsLabel("Check a USB cable", systemImage: "cable.connector") }
                NavigationLink(value: AppRoute.diagnostics(wired: false)) { SettingsLabel("Check a Wi-Fi link", systemImage: "wifi") }
                Button { app.settings.hasOnboarded = false } label: { SettingsLabel("Replay the intro", systemImage: "sparkles") }
            }

            Section("About") {
                NavigationLink(value: AppRoute.privacy) { SettingsLabel("Privacy & legal", systemImage: "hand.raised") }
                NavigationLink(value: AppRoute.about) { SettingsLabel("About Open Tether", systemImage: "info.circle") }
            }

            Section {
                TextField("Base URL", text: $cloudURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { app.applyCloudBaseURL(cloudURL) }
                    .accessibilityLabel("Cloud base URL")
                LabeledContent("Account", value: app.settings.accountID ?? "Not registered")
                LabeledContent("Device", value: String(app.settings.deviceID.prefix(8)))
                NavigationLink("PTP transaction log", value: AppRoute.ptpLog)
                Button("Apply URL and reconnect") { app.applyCloudBaseURL(cloudURL) }
            } header: { Text("Advanced") } footer: {
                Text("Default cloud URL is \(AppSettings.defaultCloudBaseURL). Exports already queued keep the URL from launch.")
            }
        }
        .listRowBackground(TetherColor.surface2)
        .tint(TetherColor.accent)
        .tetherList()
        .navigationTitle("Settings")
        .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
        .onAppear {
            cloudURL = app.settings.cloudBaseURL
            ftpUser = app.settings.ftpUsername
            ftpPassword = app.settings.ftpPassword
            ftpPort = String(app.settings.ftpPort)
        }
    }

    /// Text plus glyph, so the state reads without colour.
    @ViewBuilder private var cloudStatus: some View {
        switch app.cloudReachable {
        case true?: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(TetherColor.ok)
        case false?: Label("Offline", systemImage: "icloud.slash").foregroundStyle(TetherColor.warn)
        case nil: Text("Checking…").foregroundStyle(TetherColor.ink1)
        }
    }
}

/// Settings row label: a small icon tile and the title.
struct SettingsLabel: View {
    var title: String
    var systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(TetherColor.ink0)
        } icon: {
            IconTile(systemImage: systemImage, size: 30)
        }
    }
}
