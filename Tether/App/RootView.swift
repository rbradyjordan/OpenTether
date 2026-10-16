import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.settings.hasOnboarded {
                TabView(selection: $app.selectedTab) {
                    shootTab
                        .tabItem { Label(app.shoot == nil ? "Connect" : "Shoot", systemImage: app.shoot == nil ? "cable.connector" : "camera.aperture") }
                        .tag(AppTab.shoot)
                    NavigationStack { HomeView() }
                        .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
                        .tag(AppTab.sessions)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
            } else {
                OnboardingView()
            }
        }
        .background(Theme.background)
        .toast($app.toast)
    }

    @ViewBuilder private var shootTab: some View {
        if let shoot = app.shoot {
            ShootView(model: shoot)
        } else {
            NavigationStack { ConnectHubView() }
        }
    }
}
