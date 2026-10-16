import SwiftUI
import TetherCore

/// The main tethering screen. Always dark: the photograph is the interface.
struct ShootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: ShootViewModel
    @State private var showEndConfirm = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ShootHeader(model: model, showEndConfirm: $showEndConfirm)
                    canvas
                    ExposureBarView(model: model)
                    FilmstripView(model: model)
                        .frame(height: 88)
                    ShootBottomBar(model: model)
                }
                .frame(width: geo.size.width)
            }
            .background(TetherColor.surface0)
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
        .forceDark()
    }

    /// Canvas dims to 60 % while the link is down; the reconnect sheet does the talking.
    private var canvas: some View {
        ZStack(alignment: .bottom) {
            if model.liveViewActive, model.canLiveView {
                LiveViewView(image: model.liveViewImage)
            } else {
                EditCanvasView(model: model)
            }
            CanvasOverlay(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(model.isDisconnected ? 0.6 : 1)
        .animation(Motion.spring(TetherMotion.settle, reduce: reduceMotion), value: model.isDisconnected)
        .contentShape(Rectangle())
        .onTapGesture { if model.displayedItem != nil, !model.liveViewActive { model.showLoupe = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.displayedItem.map { "Canvas showing \($0.filename)" } ?? "Canvas, no capture yet")
        .accessibilityHint(model.displayedItem == nil ? "" : "Double tap to open the loupe")
        .accessibilityAction(named: "Capture") { model.capture(autofocus: true) }
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
        case .diagnostics: ShootDiagnosticsSheet(model: model)
        }
    }
}

/// Status pill (tap → diagnostics) and the session menu.
private struct ShootHeader: View {
    @Bindable var model: ShootViewModel
    @Binding var showEndConfirm: Bool

    var body: some View {
        HStack(spacing: TetherSpace.s) {
            StatusPill(tone: tone, title: model.cameraName, transportSymbol: transportSymbol,
                       battery: model.batteryText, downloads: model.downloadsInFlight, detail: detail) {
                model.sheet = .diagnostics
            }
            Spacer(minLength: TetherSpace.xs)
            Menu {
                Button { model.sheet = .exportProgress } label: { Label("Export progress", systemImage: "arrow.up.doc") }
                if model.isDisconnected {
                    Button { model.sheet = .reconnect } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                }
                Button(role: .destructive) { showEndConfirm = true } label: { Label("End session", systemImage: "stop.circle") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(TetherColor.ink1)
                    .frame(width: TetherHit.min, height: TetherHit.min)
            }
            .accessibilityLabel("Session menu")
        }
        .padding(.horizontal, TetherSpace.m)
        .padding(.vertical, TetherSpace.xs)
        .overlayTypeCap()
    }

    private var tone: StatusPill.Tone {
        switch model.status {
        case .ready, .capturing: return .ok
        case .disconnected: return .danger
        case .ended: return .neutral
        default: return .warn
        }
    }

    /// Only shown when the pill needs to say more than "ready".
    private var detail: String? {
        switch model.status {
        case .ready: return nil
        case .capturing: return nil
        default: return model.statusText
        }
    }

    private var transportSymbol: String? {
        switch model.identity?.transport ?? model.shootSession.transport {
        case .usb?: return "cable.connector"
        case .ptpip?, .ricohHTTP?: return "wifi"
        case .ftpPush?: return "arrow.down.doc"
        case nil: return nil
        }
    }
}

/// "Show newest / Keep selection" plus the live-view toggle, over the canvas.
private struct CanvasOverlay: View {
    @Bindable var model: ShootViewModel

    var body: some View {
        HStack(alignment: .bottom) {
            Picker("Which capture to show", selection: Binding(get: { model.shootSession.showNewestCapture }, set: { model.setShowNewestCapture($0) })) {
                Text("Show newest").tag(true)
                Text("Keep selection").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .accessibilityLabel("Which capture to show")
            Spacer()
            if model.canLiveView {
                Button { model.toggleLiveView() } label: {
                    Image(systemName: model.liveViewActive ? "video.fill" : "video")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(model.liveViewActive ? TetherColor.accent : TetherColor.ink0)
                        .frame(width: TetherHit.min, height: TetherHit.min)
                        .background(TetherColor.surface2.opacity(0.85), in: Circle())
                        .overlay(Circle().strokeBorder(TetherColor.hairline, lineWidth: 0.5))
                }
                .accessibilityLabel(model.liveViewActive ? "Stop live view" : "Start live view")
            }
        }
        .padding(TetherSpace.m)
        .overlayTypeCap()
    }
}

/// The status pill expands into the diagnostics checklist.
private struct ShootDiagnosticsSheet: View {
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss

    private var wired: Bool {
        if case .usb = model.context { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            DiagnosticsView(wired: wired)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .forceDark()
        .presentationDetents([.large])
    }
}
