import SwiftUI

@main
struct TetherApp: App {
    @State private var model = AppModel.boot()
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() { Self.styleNavigationBars() }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let model {
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
            // Open Tether is always dark (graphite and steel, like the icon).
            .preferredColorScheme(.dark)
            #if targetEnvironment(macCatalyst)
            .frame(minWidth: MacSupport.minimumWindowSize.width, minHeight: MacSupport.minimumWindowSize.height)
            #endif
        }
        #if targetEnvironment(macCatalyst)
        // Wide enough for the side-by-side shoot layout on first launch;
        // macOS remembers the user's own size after that.
        .defaultSize(width: MacSupport.defaultWindowSize.width, height: MacSupport.defaultWindowSize.height)
        .windowResizability(.contentMinSize)
        #endif
    }

    /// Rounded semibold titles, matching the display type role.
    private static func styleNavigationBars() {
        let appearance = UINavigationBar.appearance()
        func rounded(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style)
            let font = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
            guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
            return UIFont(descriptor: descriptor, size: base.pointSize)
        }
        appearance.largeTitleTextAttributes = [.font: rounded(.largeTitle, .bold), .foregroundColor: UIColor(TetherColor.ink0)]
        appearance.titleTextAttributes = [.font: rounded(.headline, .semibold), .foregroundColor: UIColor(TetherColor.ink0)]
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
