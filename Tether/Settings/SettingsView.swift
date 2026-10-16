import SwiftUI
import TetherCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var cloudURL = ""
    @State private var ftpUser = ""
    @State private var ftpPassword = ""
    @State private var ftpPort = ""

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $cloudURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { app.applyCloudBaseURL(cloudURL) }
                    .accessibilityLabel("Cloud base URL")
                HStack {
                    Text("Status")
                    Spacer()
                    switch app.cloudReachable {
                    case true?: Label("Reachable", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    case false?: Label("Unreachable", systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger)
                    case nil: Text("Checking…").foregroundStyle(Theme.textSecondary)
                    }
                }
                LabeledContent("Account", value: app.settings.accountID ?? "Not registered")
                LabeledContent("Device", value: String(app.settings.deviceID.prefix(8)))
                NavigationLink("Credits", value: AppRoute.credits)
                Button("Apply URL and reconnect") { app.applyCloudBaseURL(cloudURL) }
            } header: { Text("Tether cloud") } footer: {
                Text("Default for development is \(AppSettings.defaultCloudBaseURL). Exports already queued keep using the URL from launch.")
            }

            Section("FTP receiver defaults") {
                TextField("Username", text: $ftpUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Password", text: $ftpPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $ftpPort).keyboardType(.numberPad)
                Button("Save") {
                    app.settings.ftpUsername = ftpUser
                    app.settings.ftpPassword = ftpPassword
                    if let p = UInt16(ftpPort), p > 0 { app.settings.ftpPort = p }
                    app.ftpReceiver.restartIfRunning()
                }
                .disabled(ftpUser.isEmpty || ftpPassword.isEmpty)
                NavigationLink("FTP destinations (exports)", value: AppRoute.ftpDestinations)
            }

            Section("Diagnostics") {
                NavigationLink("PTP transaction log", value: AppRoute.ptpLog)
                NavigationLink("Tested cameras", value: AppRoute.testedCameras)
                NavigationLink("Cable diagnostic", value: AppRoute.diagnostics(wired: true))
                NavigationLink("Wireless diagnostic", value: AppRoute.diagnostics(wired: false))
            }

            Section("About") {
                NavigationLink("Privacy & legal", value: AppRoute.privacy)
                NavigationLink("About Tether", value: AppRoute.about)
                Button("Replay onboarding") { app.settings.hasOnboarded = false }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
        .onAppear {
            cloudURL = app.settings.cloudBaseURL
            ftpUser = app.settings.ftpUsername
            ftpPassword = app.settings.ftpPassword
            ftpPort = String(app.settings.ftpPort)
        }
    }
}
