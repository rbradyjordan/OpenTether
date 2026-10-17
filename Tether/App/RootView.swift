import SwiftUI
import TetherCore

/// The one place the layout forks: compact width gets tabs, regular width
/// gets the split view. Both reuse the same child screens.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var app = app
        Group {
            if !app.settings.hasOnboarded {
                OnboardingView()
            } else if sizeClass == .regular {
                RegularRootView()
            } else {
                CompactRootView()
            }
        }
        .background(ScreenBackground())
        .toast($app.toast)
        .sheet(item: Binding(get: { app.pendingCatalog.map(IdentifiedURL.init) }, set: { app.pendingCatalog = $0?.url })) { item in
            CatalogSyncSheet(catalogURL: item.url)
        }
        // "Open in Open Tether" from Files or another app: catalogs sync,
        // photos (and folders) import.
        .onOpenURL { url in
            if CatalogKind.detect(url) != nil {
                app.pendingCatalog = url
            } else if url.isFileURL {
                app.selectedTab = .library
                Task { await app.importFromFiles([url]) }
            }
        }
        .commandRequests()
        #if DEBUG
        .task { await DemoShoot.startIfRequested(app) }
        #endif
    }
}

#if DEBUG
/// Simulator screenshots without a camera: `simctl launch … -OTDemoShoot`
/// opens an FTP-receive session and drops a few generated frames into it.
enum DemoShoot {
    @MainActor static func startIfRequested(_ app: AppModel) async {
        if ProcessInfo.processInfo.arguments.contains("-OTLandscape"),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        guard ProcessInfo.processInfo.arguments.contains("-OTDemoShoot"), app.shoot == nil else { return }
        let shoot = ShootSession(name: "Demo shoot")
        guard let connection = try? await ConnectionBuilder.startFTPSession(shoot: shoot, services: app.services) else { return }
        app.activate(connection)
        guard let vm = app.shoot else { return }
        let hues: [CGFloat] = [0.58, 0.08, 0.33, 0.75]
        for (i, hue) in hues.enumerated() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(format: "DEMO_%04d.JPG", i + 1))
            try? frame(hue: hue).write(to: url)
            await vm.ingestFTPFile(url, from: "demo")
        }
    }

    private static func frame(hue: CGFloat) -> Data {
        let size = CGSize(width: 1800, height: 1200)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.25, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 700, y: 350, width: 400, height: 400))
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}
#endif

/// iPhone: Shoot (or Connect), Library, Sessions, Settings.
private struct CompactRootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            shootTab
                .tabItem { Label(app.shoot == nil ? "Connect" : "Shoot", systemImage: app.shoot == nil ? "cable.connector" : "camera.aperture") }
                .tag(AppTab.shoot)
            LibraryView()
                .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }
                .tag(AppTab.library)
            NavigationStack { HomeView() }
                .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
                .tag(AppTab.sessions)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .background(ShakeDetector { app.commands.undo() })
    }

    @ViewBuilder private var shootTab: some View {
        if let shoot = app.shoot {
            ShootView(model: shoot)
        } else {
            NavigationStack { ConnectHubView() }
        }
    }
}
