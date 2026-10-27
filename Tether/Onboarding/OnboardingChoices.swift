import Photos
import SwiftUI
import TetherCore

// MARK: - Connection

struct ConnectionStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingPageScaffold(eyebrow: "Connection", title: "How will it connect?",
                               subtitle: subtitle) {
            VStack(spacing: TetherSpace.s) {
                ForEach(Array(model.availableConnections.enumerated()), id: \.element) { i, c in
                    VStack(alignment: .leading, spacing: 0) {
                        ChoiceCard(title: c.title, detail: c.pitch, symbol: c.symbol,
                                   selected: model.connection == c, badge: i == 0 ? "Recommended" : nil) {
                            model.connection = c
                        }
                        if model.connection == c {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(c.tradeoffs, id: \.self) { t in
                                    Label(t, systemImage: "info.circle")
                                        .font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
                                }
                            }
                            .padding(.horizontal, TetherSpace.l)
                            .padding(.top, TetherSpace.s)
                            .transition(.opacity)
                        }
                    }
                }
            }
            .animation(TetherMotion.snap, value: model.connection)
            if model.body?.vendor == .canon {
                Label("Wi-Fi on Canon pairs once, like EOS Utility on a computer. The next step shows exactly what the camera will say.",
                      systemImage: "checkmark.seal")
                    .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                    .padding(TetherSpace.m)
                    .background(TetherColor.accentSoft, in: RoundedRectangle(cornerRadius: TetherRadius.control, style: .continuous))
            }
        }
    }

    private var subtitle: String {
        guard let b = model.body else { return "Pick the path you'll use most. You can use the others any time." }
        return "Ways \(b.name) can talk to this phone, best first. You can switch any time from Connect."
    }
}

// MARK: - Permissions

struct PermissionsStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingPageScaffold(eyebrow: "Permissions", title: "Only what your setup needs",
                               subtitle: "Open Tether never joins a network, uploads a photo or reads your library on its own. Here's what each permission is for.") {
            VStack(spacing: TetherSpace.s) {
                LivePermissionRow(
                    title: "Local Network",
                    symbol: "network",
                    reason: "Find Wi-Fi cameras and receive FTP uploads on this network. Nothing leaves your network.",
                    need: model.localNetworkNeed,
                    state: model.askingLocalNetwork ? .working : (model.localNetworkAsked ? .asked : .notAsked),
                    action: { model.askLocalNetwork(app: app) })
                LivePermissionRow(
                    title: "Camera over USB",
                    symbol: "cable.connector",
                    reason: "Lets iOS hand a cable-connected camera to Open Tether for control and transfers.",
                    need: model.usbNeed,
                    state: usbState,
                    action: { model.askUSB(app: app) })
                LivePermissionRow(
                    title: "Save to Photos",
                    symbol: "photo.on.rectangle",
                    reason: "Only when you export to Photos. Add-only: Open Tether can't see your library.",
                    need: model.photosNeed,
                    state: photosState,
                    action: { model.askPhotos() })
                if model.ssid != .unavailable {
                    LivePermissionRow(
                        title: "Wi-Fi name",
                        symbol: "wifi",
                        reason: "iOS shows the network name only with location access. Used to confirm you're on the camera's network; your location is never stored.",
                        need: model.ssidNeed,
                        state: ssidState,
                        action: { model.askSSID(app: app) })
                }
            }
            Label("Changed your mind? Settings → Privacy & Security, or Settings → Open Tether.", systemImage: "gearshape")
                .font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
        }
    }

    private var usbState: LivePermissionRow.State {
        if model.usb.canSendPTP { return .granted }
        if model.usb.isDenied { return .denied }
        return .notAsked
    }

    private var photosState: LivePermissionRow.State {
        switch model.photos {
        case .authorized, .limited: return .granted
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }

    private var ssidState: LivePermissionRow.State {
        switch model.ssid {
        case .authorized: return .granted
        case .denied: return .denied
        default: return .notAsked
        }
    }
}

/// A permission with why it's asked, how much this setup needs it and its
/// live state; denied rows link to Settings since iOS never asks twice.
struct LivePermissionRow: View {
    enum State { case notAsked, working, asked, granted, denied }

    var title: String
    var symbol: String
    var reason: String
    var need: OnboardingModel.Need
    var state: State
    var action: () -> Void

    var body: some View {
        if need != .notNeeded {
            HStack(alignment: .top, spacing: TetherSpace.m) {
                IconTile(systemImage: symbol, active: state == .granted, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: TetherSpace.s) {
                        Text(title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                        needChip
                    }
                    Text(reason).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                        .fixedSize(horizontal: false, vertical: true)
                    control.padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(TetherSpace.l)
            .tetherCard()
            .animation(TetherMotion.snap, value: stateKey)
            .accessibilityElement(children: .combine)
            .accessibilityValue(stateLabel)
        }
    }

    @ViewBuilder private var needChip: some View {
        let (text, color): (String, Color) = {
            switch need {
            case .required: return ("Needed", TetherColor.warn)
            case .recommended: return ("Recommended", TetherColor.accent)
            default: return ("Optional", TetherColor.ink2)
            }
        }()
        Text(text).font(TetherFont.caption).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule()).foregroundStyle(color)
    }

    @ViewBuilder private var control: some View {
        switch state {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(TetherFont.callout.weight(.semibold)).foregroundStyle(TetherColor.ok)
                .transition(.scale.combined(with: .opacity))
        case .asked:
            Label("Asked. iOS keeps your answer in Settings → Privacy & Security → Local Network.", systemImage: "checkmark.circle")
                .font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
        case .working:
            HStack(spacing: TetherSpace.s) { ProgressView().controlSize(.small); Text("Waiting for iOS…").font(TetherFont.caption) }
                .foregroundStyle(TetherColor.ink1)
        case .denied:
            HStack(spacing: TetherSpace.s) {
                Label("Off", systemImage: "xmark.circle.fill").font(TetherFont.callout.weight(.semibold)).foregroundStyle(TetherColor.danger)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.tetherSecondary).controlSize(.small)
            }
        case .notAsked:
            Button("Allow", action: action).buttonStyle(.tetherSecondary).controlSize(.small)
        }
    }

    private var stateKey: Int {
        switch state { case .notAsked: return 0; case .working: return 1; case .asked: return 2; case .granted: return 3; case .denied: return 4 }
    }

    private var stateLabel: String {
        switch state {
        case .notAsked: return "not yet asked"
        case .working: return "asking"
        case .asked: return "asked"
        case .granted: return "allowed"
        case .denied: return "off, change in Settings"
        }
    }
}

// MARK: - Workflow

struct WorkflowStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingPageScaffold(eyebrow: "Your workflow", title: "How do you like to work?",
                               subtitle: "These become the defaults for new sessions. Every session can still be set up its own way.") {
            section("What do you shoot most?") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: TetherSpace.s)], spacing: TetherSpace.s) {
                    ForEach(ShootKind.allCases) { k in
                        Button { withAnimation(TetherMotion.snap) { model.shootKind = k } } label: {
                            HStack(spacing: TetherSpace.s) {
                                Image(systemName: k.symbol).frame(width: 22)
                                Text(k.title).font(TetherFont.callout.weight(.medium)).lineLimit(2).minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(model.shootKind == k ? TetherColor.ink0 : TetherColor.ink1)
                            .padding(TetherSpace.m)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .tetherChip(selected: model.shootKind == k)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.shootKind == k ? [.isButton, .isSelected] : .isButton)
                    }
                }
                if model.shootKind == .realEstate {
                    Label("New sessions start from the Real estate listing template: a room shot list, bracket detection and an MLS export preset.",
                          systemImage: "house").font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
                }
            }

            section("Where should the camera save each frame?") {
                VStack(spacing: TetherSpace.xs) {
                    ForEach([CaptureDestination.both, .host, .card], id: \.self) { d in
                        DestinationRow(destination: d, selected: model.destination == d) { model.destination = d }
                    }
                }
            }

            section("When you export") {
                VStack(spacing: 0) {
                    pickerRow("JPEG and HEIF go to", selection: $model.jpegTarget, options: [.photos, .files, .none])
                    Divider().overlay(TetherColor.hairline)
                    pickerRow("RAW goes to", selection: $model.rawTarget, options: [.files, .ftp, .none])
                    Divider().overlay(TetherColor.hairline)
                    Toggle(isOn: $model.autoExportPicks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export picks automatically").font(TetherFont.callout).foregroundStyle(TetherColor.ink0)
                            Text("Flag a frame as a pick and it goes out on its own.").font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
                        }
                    }
                    .tint(TetherColor.accent)
                    .padding(.vertical, TetherSpace.s)
                }
                .padding(.horizontal, TetherSpace.l)
                .tetherCard()
            }

            if !app.looks.isEmpty {
                section("A look on every frame?") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TetherSpace.s) {
                            lookChip(nil, name: "None")
                            ForEach(app.looks) { look in lookChip(look.id, name: look.name) }
                        }
                    }
                    Text("Looks are previews: originals stay untouched until you export with the look.")
                        .font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
                }
            }

            section("Session names") {
                HStack {
                    Image(systemName: "textformat").foregroundStyle(TetherColor.ink2)
                    TextField("{date} {camera}", text: $model.namePattern)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .foregroundStyle(TetherColor.ink0)
                }
                .padding(TetherSpace.m)
                .hairlineBorder()
                Text("Example: \(preview). Tokens: {date} {camera} {n}")
                    .font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
            }
        }
    }

    private var preview: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return model.namePattern
            .replacingOccurrences(of: "{date}", with: f.string(from: Date()))
            .replacingOccurrences(of: "{camera}", with: model.body?.name ?? "Camera")
            .replacingOccurrences(of: "{n}", with: "001")
            .replacingOccurrences(of: "{name}", with: "Shoot")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: TetherSpace.s) {
            Text(title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
            content()
        }
        .padding(.top, TetherSpace.s)
    }

    private func pickerRow(_ title: String, selection: Binding<RoutingRules.Target>, options: [RoutingRules.Target]) -> some View {
        HStack {
            Text(title).font(TetherFont.callout).foregroundStyle(TetherColor.ink0)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options) { t in Text(t == .none ? "Don't export" : t.displayName).tag(t) }
            }
            .labelsHidden()
            .tint(TetherColor.accent)
        }
        .frame(minHeight: TetherHit.min)
    }

    private func lookChip(_ id: String?, name: String) -> some View {
        let selected = model.lookID == id
        return Button { model.lookID = id } label: {
            Text(name).font(TetherFont.callout.weight(.medium))
                .foregroundStyle(selected ? TetherColor.ink0 : TetherColor.ink1)
                .padding(.horizontal, TetherSpace.m)
                .frame(minHeight: 36)
                .tetherChip(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct DestinationRow: View {
    var destination: CaptureDestination
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: TetherSpace.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? TetherColor.accent : TetherColor.ink2)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TetherFont.callout.weight(.semibold)).foregroundStyle(TetherColor.ink0)
                    Text(detail).font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(TetherSpace.m)
            .background(selected ? TetherColor.accentSoft : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: TetherRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String {
        switch destination {
        case .both: return "Card and phone (safest)"
        case .host: return "Phone only (fastest)"
        case .card: return "Card only (lightest)"
        }
    }

    private var detail: String {
        switch destination {
        case .both: return "The camera writes the card and sends a copy. Nothing is lost if the link drops."
        case .host: return "Frames skip the card and come straight here. A dropped link mid-transfer loses that frame."
        case .card: return "Frames stay on the card; Open Tether lists them and downloads only what you open. Best for long days on Wi-Fi."
        }
    }
}

// MARK: - Ready

struct ReadyStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: OnboardingModel
    @State private var connectSheet: RouteSheet?
    @State private var celebrate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: TetherSpace.xl) {
                ZStack {
                    Circle().fill(TetherColor.accent.opacity(0.18)).frame(width: 150, height: 150)
                        .scaleEffect(celebrate ? 1 : 0.6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 104, height: 104)
                        .tetherGlass(in: Circle(), tint: TetherColor.accent.opacity(0.5))
                        .symbolEffect(.bounce, value: celebrate)
                }
                .accessibilityHidden(true)
                VStack(spacing: TetherSpace.s) {
                    Text("You're set up")
                        .font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(TetherColor.ink0)
                    Text(summary).font(TetherFont.body).foregroundStyle(TetherColor.ink1).multilineTextAlignment(.center)
                }
                VStack(spacing: TetherSpace.s) {
                    if let route {
                        Button { connectSheet = RouteSheet(route: route) } label: {
                            Label(connectTitle, systemImage: model.connection?.symbol ?? "cable.connector").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.tetherPrimary).controlSize(.large)
                    }
                    Button {
                        model.finish(app: app)
                        Task { await DemoSession.start(app) }
                    } label: {
                        Label("Try the demo session", systemImage: "play.rectangle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(route == nil ? AnyButtonStyle(.tetherPrimary) : AnyButtonStyle(.tetherSecondary))
                    .controlSize(.large)
                    Button("Just look around") { model.finish(app: app) }
                        .font(TetherFont.callout.weight(.medium))
                        .foregroundStyle(TetherColor.ink1)
                        .frame(minHeight: TetherHit.min)
                }
                Text("Replay this setup any time: Settings → Replay the intro.")
                    .font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
            }
            .frame(maxWidth: TetherLayout.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TetherSpace.xl)
            .padding(.top, TetherSpace.xxl)
            .padding(.bottom, TetherSpace.xxl)
        }
        .onAppear {
            withAnimation(reduceMotion ? .none : TetherMotion.arrive.delay(0.1)) { celebrate = true }
            TetherHaptic.connected()
        }
        // The real connect screen, inside onboarding; once a session is live
        // the intro is done and the shoot screen takes over.
        .sheet(item: $connectSheet) { sheet in
            NavigationStack {
                ConnectRouteView(route: sheet.route)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { connectSheet = nil } } }
                    .navigationDestination(for: AppRoute.self) { r in ConnectRouteView(route: r) }
            }
            .forceDark()
        }
        .onChange(of: app.shoot != nil) { _, live in
            if live { connectSheet = nil; model.finish(app: app) }
        }
    }

    private var route: AppRoute? {
        switch model.connection {
        case .usb?: return .usb
        case .cameraNetwork?, .sameNetwork?: return .wifi
        case .ftp?: return .ftpReceiver
        case nil: return nil
        }
    }

    private var connectTitle: String {
        guard let name = model.body?.name else { return "Connect my camera" }
        return "Connect my \(name)"
    }

    private var summary: String {
        guard let b = model.body, let c = model.connection else {
            return "Try the demo session to see frames arrive, or connect a camera later from Connect."
        }
        let saves: String
        switch model.destination {
        case .both: saves = "the card and this phone"
        case .host: saves = "this phone only"
        case .card: saves = "the card only"
        }
        return "\(b.name) over \(c.shortTitle). New sessions save to \(saves)."
    }
}

/// `AppRoute` isn't Identifiable; the connect sheet needs an item.
private struct RouteSheet: Identifiable {
    var route: AppRoute
    var id: String { String(describing: route) }
}

/// Type-erased button style so a button can switch between two styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
