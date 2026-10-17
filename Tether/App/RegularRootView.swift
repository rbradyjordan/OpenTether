import SwiftUI
import TetherCore

/// iPad / wide iPhone: sidebar (sources) and content (grid or Connect), with
/// the inspector as a side panel when it's open. The shoot screen is a full-screen cover reached from the
/// persistent "Live" pill whenever a session is open.
struct RegularRootView: View {
    @Environment(AppModel.self) private var app
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var sidebarItem: SidebarItem? = .library
    @State private var showSettings = false

    enum SidebarItem: Hashable { case connect, library }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columns) {
            LibrarySidebar(mode: .regular, selected: $sidebarItem)
                .navigationTitle("Open Tether")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                }
        } detail: {
            content
                .inspector(isPresented: Binding(get: { app.library.inspectorOpen }, set: { app.library.inspectorOpen = $0 })) {
                    InspectorView(model: app.library)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .bottom) { livePill }
        .fullScreenCover(isPresented: $app.showShootCover) { shootCover }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .background(CommandShortcuts())
        .onChange(of: app.shoot == nil) { _, none in if none { app.showShootCover = false } }
    }

    @ViewBuilder private var content: some View {
        switch sidebarItem {
        case .connect?:
            NavigationStack { ConnectHubView() }
        default:
            NavigationStack { LibraryContent(model: app.library) }
        }
    }

    /// The Live pill brings the shoot back from anywhere in the library.
    @ViewBuilder private var livePill: some View {
        if let shoot = app.shoot, !app.showShootCover {
            Button { app.showShoot() } label: {
                HStack(spacing: TetherSpace.s) {
                    LiveDot(isLive: shoot.isLive)
                    Text(shoot.isLive ? "Live · \(shoot.cameraName)" : "Session · \(shoot.cameraName)")
                        .font(TetherFont.hud).foregroundStyle(.white).lineLimit(1)
                    Image(systemName: "chevron.up").font(TetherFont.hud).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, TetherSpace.l)
                .frame(minHeight: TetherHit.min)
                .background(TetherColor.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, TetherSpace.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityLabel("Return to the live shoot with \(shoot.cameraName)")
        }
    }

    @ViewBuilder private var shootCover: some View {
        if let shoot = app.shoot {
            ShootView(model: shoot) { app.showShootCover = false }
        } else {
            NavigationStack { ConnectHubView() }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { app.showShootCover = false } } }
        }
    }
}

struct InspectorPlaceholder: View {
    var body: some View {
        EmptyState(systemImage: "sidebar.right", title: "Inspector",
                   message: "Select a photo and open the inspector to see its details.")
            .tetherScreen()
    }
}
