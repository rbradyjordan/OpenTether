import SwiftUI

@main
struct TetherApp: App {
    @State private var model = AppModel.boot()
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let model {
                    // Home, Sessions, Settings and Credits follow the system scheme;
                    // image-first screens force dark themselves (`forceDark()`).
                    RootView()
                        .environment(model)
                        .tint(TetherColor.accent)
                        .task { await launch(model) }
                        .onChange(of: scenePhase) { _, phase in
                            switch phase {
                            case .background: model.didEnterBackground()
                            case .active: model.didBecomeActive()
                            default: break
                            }
                        }
                } else {
                    BootFailureView()
                        .task { await dismissSplash(after: SplashView.introDuration) }
                }
                if showSplash {
                    SplashView()
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 1.04)))
                        .zIndex(1)
                }
            }
        }
    }

    /// The splash stays up for its intro and until launch work finishes, but
    /// never longer than `splashCap` (export resume can be slow).
    private func launch(_ model: AppModel) async {
        let started = ContinuousClock.now
        let work = Task { await model.launch() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work.value }
            group.addTask { try? await Task.sleep(for: Self.splashCap) }
            await group.next()
            group.cancelAll()
        }
        let elapsed = ContinuousClock.now - started
        await dismissSplash(after: SplashView.introDuration + .milliseconds(350) - elapsed)
        await work.value
    }

    private func dismissSplash(after delay: Duration) async {
        if delay > .zero { try? await Task.sleep(for: delay) }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.45)) { showSplash = false }
    }

    private static let splashCap: Duration = .seconds(3)
}

private struct BootFailureView: View {
    var body: some View {
        EmptyState(systemImage: "exclamationmark.triangle",
                   title: "Open Tether could not start",
                   message: "The local database could not be opened. Free up storage or reinstall the app.")
            .forceDark()
    }
}
