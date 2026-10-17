import SwiftUI
import TetherCore

/// The main tethering screen. Always dark: the photograph is the interface.
struct ShootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: ShootViewModel
    /// iPad: hides the shoot without ending it (the Live pill brings it back).
    var onMinimize: (() -> Void)? = nil
    @State private var showEndConfirm = false
    @State private var showImporter = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if geo.size.width >= TetherLayout.shootSideBySideMinWidth, geo.size.width > geo.size.height {
                    // iPad landscape: the photo gets the width, controls sit beside it.
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            header
                            if model.restoreOffer != nil { RestoreOfferBanner(model: model) }
                            HStack(spacing: 0) {
                                FilmstripView(model: model, vertical: true)
                                    .frame(width: 92)
                                Rectangle().fill(TetherColor.hairline).frame(width: 0.5)
                                canvas
                            }
                        }
                        Rectangle().fill(TetherColor.hairline).frame(width: 0.5)
                        ShootSidePanel(model: model)
                            .frame(width: TetherLayout.shootPanelWidth)
                    }
                } else {
                    VStack(spacing: 0) {
                        header
                        if model.restoreOffer != nil { RestoreOfferBanner(model: model) }
                        canvas
                        ExposureBarView(model: model)
                        FilmstripView(model: model)
                            .frame(height: 88)
                        ShootBottomBar(model: model)
                    }
                    .frame(width: geo.size.width)
                }
            }
            .background(TetherColor.surface0)
            .toolbar(.hidden, for: .navigationBar)
            .toast($model.toast) { model.showNewest() }
            .sheet(item: $model.sheet) { sheet in sheetView(sheet) }
            .fullScreenCover(isPresented: $model.showClientReview) { ClientReviewView(model: model) }
            .fullScreenCover(isPresented: $model.showLoupe) { LoupeView(model: model) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .rawImage, .movie, .folder, .data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.importFiles(urls) }
            }
            .alert("Rename session", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { app.renameSession(model.shootSession, to: newName) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("End this session?", isPresented: $showEndConfirm, titleVisibility: .visible) {
                Button("End session", role: .destructive) { Task { await app.endShoot() } }
                Button("Keep shooting", role: .cancel) {}
            } message: {
                Text("The camera link is closed. Captures stay in the session and can be exported later.")
            }
        }
        .forceDark()
    }

    private var header: some View {
        ShootHeader(model: model, showEndConfirm: $showEndConfirm, showImporter: $showImporter, onMinimize: onMinimize) {
            newName = model.shootSession.name; renaming = true
        }
    }

    /// Canvas dims to 60 % while the link is down; the reconnect sheet does the talking.
    private var canvas: some View {
        ZStack(alignment: .bottom) {
            if (model.liveViewActive || model.liveViewStarting), model.canLiveView {
                LiveViewView(image: model.liveViewImage, focusPoint: model.focusPoint, focusPointID: model.focusPointID,
                             isFocusing: model.isFocusing, isStarting: model.liveViewStarting,
                             onFocus: model.canTouchFocus ? { model.focus(at: $0) } : nil)
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
        case .addToCollection: CollectionPickerSheet(ids: model.displayedItem.map { [$0.id] } ?? [])
        }
    }
}

/// Status pill (tap → diagnostics) and the session menu.
private struct ShootHeader: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ShootViewModel
    @Binding var showEndConfirm: Bool
    @Binding var showImporter: Bool
    var onMinimize: (() -> Void)?
    var onRename: () -> Void

    var body: some View {
        HStack(spacing: TetherSpace.s) {
            StatusPill(tone: tone, title: model.cameraName, transportSymbol: transportSymbol,
                       battery: model.batteryText, downloads: model.downloadsInFlight, detail: detail) {
                if model.isDisconnected || model.status == .reconnecting { model.showReconnect() } else { model.sheet = .diagnostics }
            }
            Spacer(minLength: TetherSpace.xs)
            if let onMinimize {
                Button(action: onMinimize) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(TetherColor.ink0)
                        .frame(width: TetherHit.min, height: TetherHit.min)
                        .tetherGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Back to library, keep shooting")
            }
            Button { showEndConfirm = true } label: {
                Text("End")
                    .font(TetherFont.callout.weight(.semibold))
                    .foregroundStyle(TetherColor.ink0)
                    .padding(.horizontal, TetherSpace.m)
                    .frame(minHeight: TetherHit.min)
                    .tetherGlass(in: Capsule(), interactive: true)
            }
            .accessibilityLabel("End session")
            Menu {
                Button { model.sheet = .exportProgress } label: { Label("Export progress", systemImage: "arrow.up.doc") }
                Button(action: onRename) { Label("Rename session…", systemImage: "pencil") }
                Button { showImporter = true } label: { Label("Import files…", systemImage: "square.and.arrow.down") }
                if model.isDisconnected {
                    Button { model.showReconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                }
                Divider()
                Button(role: .destructive) { showEndConfirm = true } label: { Label("End session", systemImage: "stop.circle") }
                // Session commands (save as template, end) come from the shared command list.
                CommandMenuContent(commands: app.commands.available(selection: [], inShoot: true).filter { $0.group == .session && $0.id != "session.end" }) { cmd in
                    app.commands.run(cmd, on: [])
                }
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
        case .ptpip?, .ricohHTTP?, .http?: return "wifi"
        case .ftpPush?: return "arrow.down.doc"
        case nil: return nil
        }
    }
}

/// One line under the header: "Use last time's look Film Warm? Yes / No".
private struct RestoreOfferBanner: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ShootViewModel

    private var lookName: String {
        guard let id = model.restoreOffer?.look.lookID else { return "look" }
        return app.looks.first { $0.id == id }?.name ?? "look"
    }

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            Image(systemName: "camera.filters").foregroundStyle(TetherColor.accent)
            Text("Use last time's look \(lookName)?").font(TetherFont.callout).foregroundStyle(TetherColor.ink0).lineLimit(1)
            Spacer(minLength: 0)
            Button("Yes") { model.acceptRestoreOffer() }.font(TetherFont.callout.weight(.semibold)).frame(minHeight: TetherHit.min)
            Button("No") { model.declineRestoreOffer() }.font(TetherFont.callout).foregroundStyle(TetherColor.ink1).frame(minHeight: TetherHit.min)
        }
        .padding(.horizontal, TetherSpace.l)
        .background(TetherColor.surface2)
        .overlay(alignment: .bottom) { Rectangle().fill(TetherColor.hairline).frame(height: 0.5) }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .overlayTypeCap()
    }
}

/// "Show newest / Keep selection" plus the live-view toggle, over the canvas.
private struct CanvasOverlay: View {
    @Bindable var model: ShootViewModel

    var body: some View {
        HStack(alignment: .bottom) {
            FollowNewestToggle(isOn: model.shootSession.showNewestCapture) { model.setShowNewestCapture($0) }
            Spacer()
            if model.canLiveView {
                Button { model.toggleLiveView() } label: {
                    ZStack {
                        if model.liveViewStarting || model.liveViewStopping {
                            ProgressView().tint(TetherColor.accent)
                        } else {
                            Image(systemName: model.liveViewActive ? "video.fill" : "video")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(model.liveViewActive ? TetherColor.accent : TetherColor.ink0)
                        }
                    }
                    .frame(width: TetherHit.min, height: TetherHit.min)
                    .tetherGlass(in: Circle(), interactive: true)
                }
                .disabled(model.liveViewStarting || model.liveViewStopping)
                .accessibilityLabel(model.liveViewStarting ? "Starting live view" : model.liveViewActive ? "Stop live view" : "Start live view")
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

/// One glass capsule over the canvas: "Following newest" jumps to each new
/// frame as it lands; tap to hold the frame you are looking at instead.
private struct FollowNewestToggle: View {
    var isOn: Bool
    var set: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { set(!isOn) } label: {
            Label {
                Text(isOn ? "Following newest" : "Holding this frame").foregroundStyle(.white)
            } icon: {
                Image(systemName: isOn ? "arrow.right.to.line" : "pin.fill")
                    .foregroundStyle(isOn ? TetherColor.accent : .white)
                    .contentTransition(.symbolEffect(.replace))
            }
                .font(TetherFont.hud.weight(.semibold))
                .padding(.horizontal, TetherSpace.m)
                .frame(minHeight: 36)
                .tetherGlass(in: Capsule(), tint: Color.black.opacity(0.35), interactive: true)
                .frame(minHeight: TetherHit.min)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: isOn)
        .accessibilityLabel("Show newest frame")
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityHint("When on, each new frame is shown as it arrives")
    }
}

/// iPad landscape: exposure as a grid, then rating, shutter and tools at the
/// bottom where the thumb rests.
private struct ShootSidePanel: View {
    @Bindable var model: ShootViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: TetherSpace.s) {
                    if model.identity != nil {
                        Text("Exposure").font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
                            .padding(.horizontal, TetherSpace.m).padding(.top, TetherSpace.m)
                        ExposureBarView(model: model, grid: true)
                    }
                    if let item = model.displayedItem {
                        Text("Frame").font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
                            .padding(.horizontal, TetherSpace.m).padding(.top, TetherSpace.s)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename).font(TetherFont.callout.weight(.semibold)).foregroundStyle(TetherColor.ink0).lineLimit(1)
                            Text("#\(item.sequence) · \(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))")
                                .font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
                        }
                        .padding(.horizontal, TetherSpace.m)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ShootBottomBar(model: model)
        }
        .background(TetherColor.surface0)
    }
}
