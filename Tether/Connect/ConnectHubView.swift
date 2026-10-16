import SwiftUI
import TetherCore

struct ConnectHubView: View {
    @Environment(AppModel.self) private var app
    @State private var showNewSession = false
    @State private var knownCameras: [(CameraIdentity, host: String?, lastSeen: Date)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let interrupted = app.interrupted.first {
                    ResumeBanner(session: interrupted)
                }
                NavigationLink(value: AppRoute.usb) {
                    ActionCard(title: "USB-C", subtitle: "Most stable and fastest. Plug the camera straight into the phone.",
                               systemImage: "cable.connector", badge: "Recommended")
                }
                NavigationLink(value: AppRoute.wifi) {
                    ActionCard(title: "Wi-Fi", subtitle: "Join the camera's network in Settings, then pick it from the list.",
                               systemImage: "wifi")
                }
                NavigationLink(value: AppRoute.ftpReceiver) {
                    ActionCard(title: "FTP push", subtitle: "Turn the phone into an FTP server the camera sends files to.",
                               systemImage: "arrow.down.doc")
                }
                recentCameras
                NavigationLink(value: AppRoute.brandGuides) {
                    ActionCard(title: "Camera setup guides", subtitle: "Which menu to flip for Canon, Nikon, Sony, Fujifilm, Ricoh and more.",
                               systemImage: "book")
                }
            }
            .padding(16)
        }
        .buttonStyle(.plain)
        .background(Theme.background)
        .navigationTitle("Connect")
        .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewSession = true } label: { Label("New session", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showNewSession) { NewSessionSheet() }
        .onAppear { knownCameras = (try? app.store.knownCameras()) ?? [] }
    }

    @ViewBuilder private var recentCameras: some View {
        if !knownCameras.isEmpty {
            SectionCard(title: "Recent cameras", systemImage: "clock") {
                ForEach(knownCameras.prefix(4), id: \.0.id) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.0.displayName).font(.subheadline.weight(.medium))
                            Text([entry.0.transport.displayName, entry.host].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(entry.lastSeen, style: .relative).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Routes shared by the Connect, Sessions and Settings stacks.
struct ConnectRouteView: View {
    var route: AppRoute

    var body: some View {
        switch route {
        case .usb: USBConnectView()
        case .wifi: WiFiConnectView()
        case .ftpReceiver: FTPReceiverView()
        case .brandGuides: BrandGuidesView()
        case .brandGuide(let vendor): BrandGuideDetailView(vendor: vendor)
        case .diagnostics(let wired): DiagnosticsView(wired: wired)
        case .sessionDetail(let id): SessionDetailView(sessionID: id)
        case .credits: CreditsView()
        case .ftpDestinations: FTPDestinationsView()
        case .exportProgress(let sessionID): ExportProgressView(sessionID: sessionID)
        case .ptpLog: DiagnosticsLogView()
        case .testedCameras: TestedCamerasView()
        case .privacy: PrivacyView()
        case .about: AboutView()
        }
    }
}

struct ResumeBanner: View {
    @Environment(AppModel.self) private var app
    var session: ShootSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.counterclockwise.circle.fill").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resume \(session.name)?").font(.subheadline.weight(.semibold))
                Text("\(session.captureCount) frames · \(session.transport?.displayName ?? "no camera")")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Resume") { app.resume(session) }.buttonStyle(.borderedProminent).controlSize(.small)
            Button { app.dismissInterrupted(session) } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("End \(session.name) without resuming")
        }
        .padding(14)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
