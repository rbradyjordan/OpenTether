import SwiftUI

@main
struct TetherApp: App {
    @State private var model = AppModel.boot()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let model {
                // Home, Sessions, Settings and Credits follow the system scheme;
                // image-first screens force dark themselves (`forceDark()`).
                RootView()
                    .environment(model)
                    .tint(TetherColor.accent)
                    .task { await model.launch() }
                    .onChange(of: scenePhase) { _, phase in
                        switch phase {
                        case .background: model.didEnterBackground()
                        case .active: model.didBecomeActive()
                        default: break
                        }
                    }
            } else {
                BootFailureView()
            }
        }
    }
}

private struct BootFailureView: View {
    var body: some View {
        EmptyState(systemImage: "exclamationmark.triangle",
                   title: "Tether could not start",
                   message: "The local database could not be opened. Free up storage or reinstall the app.")
            .forceDark()
    }
}
