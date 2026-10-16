import SwiftUI
import TetherCore

/// The main tethering screen.
struct ShootView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ShootViewModel
    @State private var showEndConfirm = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    header
                    ZStack(alignment: .bottom) {
                        if model.liveViewActive, model.canLiveView {
                            LiveViewView(image: model.liveViewImage)
                        } else {
                            EditCanvasView(model: model)
                        }
                        canvasOverlay
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { if model.displayedItem != nil, !model.liveViewActive { model.showLoupe = true } }
                    .accessibilityLabel(model.displayedItem.map { "Canvas showing \($0.filename), double tap to open loupe" } ?? "Canvas, no capture yet")
                    ExposureBarView(model: model)
                    FilmstripView(model: model)
                        .frame(height: 84)
                    ShootBottomBar(model: model)
                }
                .frame(width: geo.size.width)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .toast($model.toast) { model.showNewest() }
            .sheet(item: $model.sheet) { sheet in sheetView(sheet) }
            .fullScreenCover(isPresented: $model.showClientReview) { ClientReviewView(model: model) }
            .fullScreenCover(isPresented: $model.showLoupe) { LoupeView(model: model) }
            .confirmationDialog("End this session?", isPresented: $showEndConfirm, titleVisibility: .visible) {
                Button("End session", role: .destructive) { Task { await app.endShoot() } }
                Button("Keep shooting", role: .cancel) {}
            } message: {
                Text("The camera link is closed. Captures stay in the session and can be exported later.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusPill(title: model.cameraName, subtitle: model.transportName, tint: statusColor,
                       systemImage: model.isDisconnected ? "bolt.slash" : nil)
            if let battery = model.batteryText {
                StatusPill(title: battery, systemImage: "battery.75percent")
            }
            if model.downloadsInFlight > 0 {
                StatusPill(title: "\(model.downloadsInFlight)", systemImage: "arrow.down.circle")
                    .accessibilityLabel("\(model.downloadsInFlight) downloads in flight")
            }
            Spacer(minLength: 4)
            StatusPill(title: model.statusText, tint: statusColor)
            Menu {
                Button { model.sheet = .exportProgress } label: { Label("Export progress", systemImage: "arrow.up.doc") }
                if model.isDisconnected { Button { model.sheet = .reconnect } label: { Label("Reconnect", systemImage: "arrow.clockwise") } }
                Button(role: .destructive) { showEndConfirm = true } label: { Label("End session", systemImage: "stop.circle") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Session menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch model.status {
        case .ready: return Theme.success
        case .capturing: return Theme.accent
        case .disconnected: return Theme.danger
        case .ended: return Theme.textSecondary
        default: return Theme.warning
        }
    }

    @ViewBuilder private var canvasOverlay: some View {
        HStack {
            Picker("Selection", selection: Binding(get: { model.shootSession.showNewestCapture }, set: { model.setShowNewestCapture($0) })) {
                Text("Show Newest").tag(true)
                Text("Keep Selection").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .accessibilityLabel("Which capture to show")
            Spacer()
            if model.canLiveView {
                Button { model.toggleLiveView() } label: {
                    Image(systemName: model.liveViewActive ? "video.fill" : "video")
                        .font(.title3).frame(width: 40, height: 40)
                        .background(Theme.surfaceRaised.opacity(0.8), in: Circle())
                }
                .accessibilityLabel(model.liveViewActive ? "Stop live view" : "Start live view")
            }
        }
        .padding(10)
    }

    @ViewBuilder private func sheetView(_ sheet: ShootSheet) -> some View {
        switch sheet {
        case .looks: LooksSheet(model: model)
        case .colorMatch: ColorMatchView(model: model)
        case .export: ExportSheet(sessionID: model.shootSession.id, items: model.readyItems, selectedID: model.selectedItemID, look: model.lookStack)
        case .exportProgress: NavigationStack { ExportProgressView(sessionID: model.shootSession.id) }
        case .compare: CompareView(model: model)
        case .property(let p): PropertyPickerSheet(model: model, property: p)
        case .reconnect: ReconnectView(model: model)
        case .newSession: NewSessionSheet()
        }
    }
}
