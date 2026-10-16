import Observation
import SwiftUI
import TetherCore

/// Watches the three connection paths so each hub card can show a live dot
/// the moment a camera is actually visible on it. Discovery is never started
/// from here (that is the Wi-Fi screen's job and needs the local-network
/// prompt); the USB browser is cheap and prompt-free.
@Observable @MainActor
final class ConnectHubModel {
    private(set) var usbDeviceVisible = false
    private(set) var wifiCameraVisible = false
    private(set) var ftpClientConnected = false

    private var usbTask: Task<Void, Never>?
    private var wifiTask: Task<Void, Never>?

    func start(app: AppModel) {
        guard usbTask == nil else { return }
        let browser = app.services.usbBrowser
        browser.start()
        let usbStream = browser.events
        usbTask = Task { [weak self] in
            for await event in usbStream {
                guard let self else { return }
                if case .devices(let list) = event { usbDeviceVisible = !list.isEmpty }
            }
        }
        wifiCameraVisible = !app.discovery.current.isEmpty
        let wifiStream = app.discovery.cameras
        wifiTask = Task { [weak self] in
            for await list in wifiStream {
                guard let self else { return }
                wifiCameraVisible = !list.isEmpty
            }
        }
        ftpClientConnected = app.ftpReceiver.isRunning && app.ftpReceiver.clients > 0
    }

    func refreshFTP(app: AppModel) {
        ftpClientConnected = app.ftpReceiver.isRunning && app.ftpReceiver.clients > 0
    }

    func stop() {
        usbTask?.cancel(); usbTask = nil
        wifiTask?.cancel(); wifiTask = nil
    }
}

struct ConnectHubView: View {
    @Environment(AppModel.self) private var app
    @State private var showNewSession = false
    @State private var hub = ConnectHubModel()
    @State private var knownCameras: [(CameraIdentity, host: String?, lastSeen: Date)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: TetherSpace.m) {
                if let interrupted = app.interrupted.first {
                    ResumeBanner(session: interrupted)
                }
                cardStack
                recentCameras
                NavigationLink(value: AppRoute.brandGuides) {
                    ActionCard(title: "Camera setup guides", subtitle: "Which menu to flip for Canon, Nikon, Sony, Fujifilm, Ricoh and more.",
                               systemImage: "book")
                }
            }
            .padding(TetherSpace.l)
        }
        .buttonStyle(.plain)
        .background(TetherColor.surface1)
        .navigationTitle("Connect")
        .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewSession = true } label: { Label("New session", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showNewSession) { NewSessionSheet() }
        .onAppear {
            knownCameras = (try? app.store.knownCameras()) ?? []
            hub.start(app: app)
            hub.refreshFTP(app: app)
        }
        .onDisappear { hub.stop() }
    }

    /// Three cards; copy per DESIGN.md. The USB-C badge appears only when a
    /// device is really on the bus.
    private var cardStack: some View {
        VStack(spacing: TetherSpace.m) {
            NavigationLink(value: AppRoute.usb) {
                ActionCard(title: "USB-C", subtitle: "Plug the camera straight into the phone.",
                           systemImage: "cable.connector",
                           badge: hub.usbDeviceVisible ? "Recommended · most stable" : nil,
                           isLive: hub.usbDeviceVisible)
            }
            NavigationLink(value: AppRoute.wifi) {
                ActionCard(title: "Wi-Fi", subtitle: "Join the camera's network in Settings, then pick it from the list.",
                           systemImage: "wifi", isLive: hub.wifiCameraVisible)
            }
            NavigationLink(value: AppRoute.ftpReceiver) {
                ActionCard(title: "FTP", subtitle: "Turn the phone into an FTP server the camera sends files to.",
                           systemImage: "arrow.down.doc", isLive: hub.ftpClientConnected)
            }
        }
    }

    @ViewBuilder private var recentCameras: some View {
        if !knownCameras.isEmpty {
            SectionCard(title: "Recent cameras", systemImage: "clock") {
                ForEach(knownCameras.prefix(4), id: \.0.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.0.displayName).font(TetherFont.callout.weight(.medium)).foregroundStyle(TetherColor.ink0)
                            Text([entry.0.transport.displayName, entry.host].compactMap { $0 }.joined(separator: " · "))
                                .font(TetherFont.hud).foregroundStyle(TetherColor.ink2)
                        }
                        Spacer()
                        Text(entry.lastSeen, style: .relative).font(TetherFont.hud).foregroundStyle(TetherColor.ink2)
                    }
                    .frame(minHeight: TetherHit.min)
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

/// "Resume <session>?" with frame count and transport; one primary action.
struct ResumeBanner: View {
    @Environment(AppModel.self) private var app
    var session: ShootSession

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(TetherColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resume \(session.name)?").font(TetherFont.headline).foregroundStyle(TetherColor.ink0).lineLimit(1)
                Text("\(session.captureCount) frames · \(session.transport?.displayName ?? "no camera")")
                    .font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
            }
            Spacer(minLength: TetherSpace.xs)
            Button("Resume") { app.resume(session) }
                .buttonStyle(.borderedProminent).tint(TetherColor.accent).controlSize(.regular)
            Button { app.dismissInterrupted(session) } label: {
                Image(systemName: "xmark").frame(width: TetherHit.min - 8, height: TetherHit.min - 8)
            }
            .buttonStyle(.bordered).tint(TetherColor.ink1)
            .accessibilityLabel("End \(session.name) without resuming")
        }
        .padding(TetherSpace.l)
        .background(TetherColor.accentSoft, in: RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous).strokeBorder(TetherColor.accent.opacity(0.35), lineWidth: 0.5))
    }
}
