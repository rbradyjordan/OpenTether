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
                ScreenIntro(text: "Pick how your camera talks to the phone. USB-C is the fastest and most reliable.")
                if let interrupted = app.interrupted.first {
                    ResumeBanner(session: interrupted)
                }
                cardStack
                recentCameras.staggeredAppear(3)
                NavigationLink(value: AppRoute.brandGuides) {
                    ActionCard(title: "Camera setup guides", subtitle: "The menu to change on Canon, Nikon, Sony, Fujifilm and more.",
                               systemImage: "book.pages")
                }
                .staggeredAppear(4)
            }
            .padding(TetherSpace.l)
        }
        .buttonStyle(.plain)
        .tetherScreen()
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
                           badge: hub.usbDeviceVisible ? "Camera found" : nil,
                           isLive: hub.usbDeviceVisible)
            }
            .staggeredAppear(0)
            NavigationLink(value: AppRoute.wifi) {
                ActionCard(title: "Wi-Fi", subtitle: "Join the camera's network, then pick it here.",
                           systemImage: "wifi", badge: hub.wifiCameraVisible ? "Camera found" : nil,
                           isLive: hub.wifiCameraVisible)
            }
            .staggeredAppear(1)
            NavigationLink(value: AppRoute.ftpReceiver) {
                ActionCard(title: "FTP", subtitle: "The camera sends each photo to the phone as you shoot.",
                           systemImage: "arrow.down.doc", badge: hub.ftpClientConnected ? "Receiving" : nil,
                           isLive: hub.ftpClientConnected)
            }
            .staggeredAppear(2)
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
        case .metadata: MetadataSettingsView()
        }
    }
}

/// "Resume <session>?" with frame count and transport; one primary action.
struct ResumeBanner: View {
    @Environment(AppModel.self) private var app
    var session: ShootSession

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.m) {
            HStack(alignment: .top, spacing: TetherSpace.m) {
                IconTile(systemImage: "arrow.counterclockwise", active: true, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick up where you left off").tetherCaption().foregroundStyle(TetherColor.accent)
                    Text(session.name).font(TetherFont.headline).foregroundStyle(TetherColor.ink0).lineLimit(2)
                    Text("\(session.captureCount) frames · \(session.transport?.displayName ?? "no camera")")
                        .font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                }
                Spacer(minLength: TetherSpace.xs)
                Button { app.dismissInterrupted(session) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TetherColor.ink1)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .frame(width: TetherHit.min, height: TetherHit.min)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("End \(session.name) without resuming")
            }
            Button { app.resume(session) } label: {
                Label("Resume session", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.tetherPrimary)
        }
        .padding(TetherSpace.l)
        .tetherGlassCard(tint: TetherColor.accent.opacity(0.18))
    }
}
