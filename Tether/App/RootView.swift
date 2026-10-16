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
    }
}

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
