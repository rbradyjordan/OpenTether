import Photos
import SwiftUI
import TetherCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var localNetworkAsked = false
    @State private var photosStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @State private var ssidState: SSIDAuthorization = .notDetermined

    var body: some View {
        VStack {
            TabView(selection: $page) {
                ForEach(OnboardingContent.pages) { p in
                    pageView(p).tag(p.id)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            Button(page == OnboardingContent.pages.count - 1 ? "Start" : "Next") {
                if page < OnboardingContent.pages.count - 1 { withAnimation { page += 1 } } else { finish() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .task { ssidState = await app.services.ssid.authorizationState }
    }

    private func pageView(_ p: OnboardingPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: p.symbol).font(.system(size: 48)).foregroundStyle(Theme.accent).padding(.top, 40)
                Text(p.title).font(.largeTitle.weight(.bold))
                ForEach(p.lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle.fill").font(.system(size: 6)).padding(.top, 7).foregroundStyle(Theme.accent)
                        Text(line).font(.body)
                    }
                }
                if p.id == 2 { permissionButtons }
            }
            .padding(24)
        }
    }

    private var permissionButtons: some View {
        VStack(spacing: 10) {
            permissionRow("Local network", done: localNetworkAsked) {
                // Starting discovery triggers the system prompt; stop again right away.
                Task {
                    try? await app.discovery.start()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await app.discovery.stop()
                    localNetworkAsked = true
                }
            }
            permissionRow("Photos (add only)", done: photosStatus == .authorized || photosStatus == .limited) {
                Task { photosStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            }
            permissionRow("Location for the Wi-Fi name", done: ssidState == .authorized) {
                Task {
                    await app.services.ssid.requestAuthorization()
                    ssidState = await app.services.ssid.authorizationState
                }
            }
            Text("You can skip any of these; Tether asks again when a feature needs it.").font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 10)
    }

    private func permissionRow(_ title: String, done: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.success : Theme.textSecondary)
            Text(title)
            Spacer()
            Button(done ? "Granted" : "Allow", action: action).buttonStyle(.bordered).controlSize(.small).disabled(done)
        }
        .padding(12)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }

    private func finish() {
        app.settings.hasOnboarded = true
        Task { await app.refreshCloud() } // registers the device; failure is tolerated
    }
}
