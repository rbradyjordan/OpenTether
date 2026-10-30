import SwiftUI
import TetherCore

/// Pairing a Canon over Wi-Fi, one screen, four stages that advance on their
/// own as the phone sees each thing happen: the camera menu, joining the
/// camera's network, finding it, and the handshake, where the phone shows
/// exactly what the camera is about to show and waits for the OK press.
/// Everything the camera does mid-pairing (drops the link, refuses for a
/// moment, restarts its service) is retried behind the stage rows.
struct CanonPairingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: CanonPairingModel?
    @State private var showManual = false

    var body: some View {
        ScrollView {
            VStack(spacing: TetherSpace.m) {
                if let model { content(model) }
            }
            .padding(TetherSpace.l)
        }
        .tetherScreen()
        .navigationTitle("Pair a Canon")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showManual = true } label: { Label("Enter IP", systemImage: "keyboard") }
            }
        }
        .sheet(isPresented: $showManual) {
            ManualIPSheet { host, port, _ in model?.useManual(host: host, port: port) }
        }
        .onAppear {
            if model == nil { model = CanonPairingModel(app: app) }
            model?.start()
        }
        .onDisappear { model?.stop() }
    }

    @ViewBuilder private func content(_ model: CanonPairingModel) -> some View {
        PairingHero(phase: model.phase, cameraName: model.camera?.name)
        if let known = model.knownCanon, model.phase.rawValue < CanonPairingModel.Phase.pairing.rawValue {
            Button { model.reconnect(known) } label: {
                ActionCard(title: "Reconnect \(known.0.displayName)", subtitle: "Already paired. Join its Wi-Fi and tap here.", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
        stage(.camera, model) {
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                CameraMenuPath(["Wireless features", "Wi-Fi/Bluetooth connection", "Connect to EOS Utility", "Add a device to connect to"])
                Text("Choose camera access point mode. The camera shows a network name and password.")
                    .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                if model.phase == .camera {
                    Button("Done, the camera shows a network name") { model.cameraReady() }
                        .buttonStyle(.tetherPrimary).controlSize(.regular)
                }
            }
        }
        stage(.network, model) {
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                HStack(spacing: TetherSpace.s) {
                    Image(systemName: "wifi").foregroundStyle(model.onCameraNetwork ? TetherColor.ok : TetherColor.ink2)
                    Text(model.ssid ?? "Not on Wi-Fi").font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                    if model.onCameraNetwork { Text("Camera network").font(TetherFont.hud).foregroundStyle(TetherColor.ok) }
                }
                Text(model.onCameraNetwork
                     ? "Good. The phone is on the camera's network."
                     : "Settings → Wi-Fi → join the network the camera shows (it starts with EOS). Come back here.")
                    .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                if model.phase == .network {
                    HStack {
                        Button { MacSupport.openWiFiSettings() } label: { Label("Open Wi-Fi Settings", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.tetherSecondary).controlSize(.regular)
                        if !model.onCameraNetwork {
                            Button("I'm on it") { model.networkReady() }.buttonStyle(.tetherPrimary).controlSize(.regular)
                        }
                    }
                }
            }
        }
        stage(.finding, model) {
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                if let cam = model.camera {
                    Label("\(cam.name) · \(cam.host)", systemImage: "camera.fill").font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                } else if model.phase == .finding {
                    HStack(spacing: TetherSpace.s) {
                        ProgressView().controlSize(.small).tint(TetherColor.accent)
                        Text("Scanning the network… \(model.scanSeconds)s").font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                            .contentTransition(.numericText())
                    }
                    if model.scanSeconds >= 20 {
                        Text("Still looking. Check the camera is still on its pairing screen, or enter its IP address (shown on the camera under the network name).")
                            .font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
                    }
                }
            }
        }
        stage(.pairing, model) {
            VStack(alignment: .leading, spacing: TetherSpace.m) {
                CameraScreenMock(waiting: model.handshake == .awaitingConfirmation, done: model.phase == .done)
                ForEach(CanonPairingModel.HandshakeRow.allCases, id: \.self) { row in
                    HandshakeStageRow(row: row, state: model.state(of: row))
                }
                if model.phase == .pairing, let left = model.secondsLeft {
                    HStack(spacing: TetherSpace.s) {
                        PairingCountdown(fraction: Double(left) / PTPIPIdentity.pairingTimeout)
                        Text(model.handshake == .awaitingConfirmation ? "Press OK on the camera · \(left)s" : "Talking to the camera · \(left)s")
                            .font(TetherFont.callout).foregroundStyle(TetherColor.ink1).contentTransition(.numericText())
                    }
                }
                if model.attempts > 1, model.phase == .pairing {
                    Text("The camera dropped the link while saving the pairing; trying again (\(model.attempts)).")
                        .font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
                }
                if model.phase == .finding, model.camera != nil {
                    Button("Pair now") { model.pair() }.buttonStyle(.tetherPrimary)
                }
            }
        }
        if let failure = model.failure {
            SectionCard(title: "Didn't pair", systemImage: "exclamationmark.triangle") {
                Text(failure).font(TetherFont.callout).foregroundStyle(TetherColor.danger).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try again") { model.pair() }.buttonStyle(.tetherPrimary).controlSize(.regular)
                    Button("Start over") { model.restart() }.buttonStyle(.tetherSecondary).controlSize(.regular)
                }
            }
        }
        if model.phase == .done {
            SectionCard(title: "Paired", systemImage: "checkmark.seal.fill") {
                Text("The camera saved \"Open Tether\". Next time, put it in Connect to EOS Utility, join its Wi-Fi, and it connects on its own.")
                    .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                Button("Start shooting") { model.startShooting() }.buttonStyle(.tetherPrimary)
            }
        }
        NavigationLink(value: AppRoute.brandGuide(.canon)) {
            HStack { Image(systemName: "book.pages"); Text("Canon setup guide"); Spacer(); Image(systemName: "chevron.right") }
                .font(.subheadline).padding(14).cardBackground()
        }
        .buttonStyle(.plain)
    }

    private func stage<Content: View>(_ phase: CanonPairingModel.Phase, _ model: CanonPairingModel, @ViewBuilder _ content: () -> Content) -> some View {
        let state = model.stageState(phase)
        return HStack(alignment: .top, spacing: TetherSpace.m) {
            StageBadge(number: phase.rawValue + 1, state: state)
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                Text(phase.title).font(TetherFont.headline).foregroundStyle(state == .pending ? TetherColor.ink2 : TetherColor.ink0)
                if state != .pending { content() }
            }
            Spacer(minLength: 0)
        }
        .padding(TetherSpace.l)
        .tetherGlassCard(tint: state == .running ? TetherColor.accent.opacity(0.08) : nil)
        .animation(Motion.spring(TetherMotion.settle, reduce: reduceMotion), value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(phase.rawValue + 1), \(phase.title), \(state)")
    }
}

// MARK: - Model

@Observable @MainActor
final class CanonPairingModel {
    enum Phase: Int, Comparable {
        case camera, network, finding, pairing, done
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .camera: return "Put the camera in pairing mode"
            case .network: return "Join the camera's Wi-Fi"
            case .finding: return "Find the camera"
            case .pairing: return "Pair"
            case .done: return "Paired"
            }
        }
    }
    enum StageState { case pending, running, done }
    enum HandshakeRow: CaseIterable { case link, hello, confirm, channel, remote }

    private(set) var phase: Phase = .camera
    private(set) var ssid: String?
    private(set) var onCameraNetwork = false
    private(set) var camera: DiscoveredCamera?
    private(set) var scanSeconds = 0
    private(set) var handshake: PTPIPTransport.HandshakeStage?
    private(set) var connectStep: ConnectStep?
    private(set) var attempts = 0
    private(set) var secondsLeft: Int?
    private(set) var failure: String?
    private(set) var knownCanon: (CameraIdentity, host: String?, lastSeen: Date)?
    private var connection: LiveConnection?

    private let app: AppModel
    private var tasks: [Task<Void, Never>] = []
    private var pairingTask: Task<Void, Never>?
    private var userSaidNetworkOK = false

    init(app: AppModel) {
        self.app = app
        knownCanon = (try? app.store.knownCameras())?.first { $0.0.vendor == .canon && $0.host != nil && $0.0.transport == .ptpip }
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshSSID()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in
            try? await self?.app.discovery.start()
            guard let stream = self?.app.discovery.cameras else { return }
            for await list in stream {
                guard let self, !Task.isCancelled else { return }
                self.sawCameras(list)
            }
        })
        tasks.append(Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.phase == .finding { self.scanSeconds += 1 }
                if self.phase == .pairing, let left = self.secondsLeft, left > 0 { self.secondsLeft = left - 1 }
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        if phase != .done { pairingTask?.cancel() }
        Task { await app.discovery.stop() }
    }

    // MARK: Stages

    func stageState(_ p: Phase) -> StageState {
        if phase == .done { return .done }
        if p < phase { return .done }
        if p == phase { return .running }
        return .pending
    }

    func cameraReady() { if phase == .camera { phase = .network; Task { await refreshSSID() } } }
    func networkReady() { userSaidNetworkOK = true; if phase == .network { phase = .finding; scanSeconds = 0 } }

    private func refreshSSID() async {
        ssid = await app.services.ssid.currentSSID()
        onCameraNetwork = ssid.flatMap { CameraWiFiHints.looksLikeCameraNetwork($0) } == .canon
        if onCameraNetwork, phase == .network { phase = .finding; scanSeconds = 0 }
        if onCameraNetwork, phase == .camera { phase = .finding; scanSeconds = 0 }
    }

    private func sawCameras(_ list: [DiscoveredCamera]) {
        // A Canon by name, else anything speaking PTP/IP on a Canon network.
        let pick = list.first { $0.vendor == .canon && $0.transport == .ptpip }
            ?? ((onCameraNetwork || userSaidNetworkOK) ? list.first { $0.transport == .ptpip && $0.vendor == nil } : nil)
        guard let pick else { return }
        if camera?.host != pick.host { camera = pick }
        if phase == .finding, pairingTask == nil { pair() }
    }

    func useManual(host: String, port: UInt16) {
        camera = DiscoveredCamera(id: "manual-\(host)", name: "Canon at \(host)", vendor: .canon, host: host, port: port, method: .manual, transport: .ptpip)
        if phase < .finding { phase = .finding }
        pair()
    }

    func reconnect(_ known: (CameraIdentity, host: String?, lastSeen: Date)) {
        guard let host = known.host else { return }
        camera = DiscoveredCamera(id: "known-\(host)", name: known.0.displayName, vendor: .canon, host: host, port: PTPIPPacket.standardPort, method: .manual, transport: .ptpip)
        phase = .finding
        pair()
    }

    func restart() {
        pairingTask?.cancel(); pairingTask = nil
        failure = nil; camera = nil; handshake = nil; connectStep = nil; attempts = 0; secondsLeft = nil
        phase = onCameraNetwork ? .finding : .camera
        scanSeconds = 0
    }

    // MARK: Pairing

    func pair() {
        guard let camera, pairingTask == nil else { return }
        failure = nil
        phase = .pairing
        handshake = nil
        connectStep = nil
        attempts = 1
        secondsLeft = Int(PTPIPIdentity.pairingTimeout)
        let shoot = SessionPickerField.resolve(nil, app: app)
        pairingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pairingTask = nil }
            do {
                let connection = try await ConnectionBuilder.connectPTPIP(
                    host: camera.host, port: camera.port, vendorHint: .canon, shoot: shoot, services: app.services,
                    progress: { [weak self] step in self?.connectStep = step },
                    pairing: true,
                    handshake: { [weak self] stage in Task { @MainActor in self?.noteHandshake(stage) } })
                self.connection = connection
                self.secondsLeft = nil
                self.phase = .done
                TetherHaptic.connected()
            } catch is CancellationError {
                self.phase = .finding
            } catch {
                self.secondsLeft = nil
                self.failure = Self.explain("\(error)")
                HapticFeedback.error()
            }
        }
    }

    private func noteHandshake(_ stage: PTPIPTransport.HandshakeStage) {
        switch stage {
        case .retrying:
            attempts += 1
            handshake = nil
            secondsLeft = Int(PTPIPIdentity.pairingTimeout)
        default:
            handshake = stage
        }
    }

    func state(of row: HandshakeRow) -> StageState {
        if phase == .done { return .done }
        guard phase == .pairing else { return .pending }
        let reached: Int = {
            switch handshake {
            case nil: return 0
            case .tcpConnected?: return 1
            case .awaitingConfirmation?: return 2
            case .initCommandAcked?: return 3
            case .eventConnected?, .eventAcked?: return 4
            case .retrying?: return 0
            }
        }()
        let remoteDone = connectStep == .ready
        let remoteRunning = connectStep.map { $0 >= .session } ?? false
        switch row {
        case .link: return reached >= 1 ? .done : .running
        case .hello: return reached >= 3 ? .done : (reached == 1 ? .running : (reached == 2 ? .running : .pending))
        case .confirm: return reached >= 3 ? .done : (reached == 2 ? .running : .pending)
        case .channel: return reached >= 4 ? .done : (reached == 3 ? .running : .pending)
        case .remote: return remoteDone ? .done : (remoteRunning ? .running : .pending)
        }
    }

    func startShooting() {
        guard let connection else { return }
        app.activate(connection)
    }

    static func explain(_ raw: String) -> String {
        let first = ConnectFailureCopy.sentence(raw)
        if raw.contains("timeout") || raw.contains("Timeout") {
            return "The camera never answered. Make sure its screen still says it is waiting for a device, then try again. If it went back to the menu, choose Connect to EOS Utility again."
        }
        return first
    }
}

// MARK: - Pieces

/// Phone and camera with a pulse travelling between them as the stages go.
private struct PairingHero: View {
    var phase: CanonPairingModel.Phase
    var cameraName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var t: CGFloat = 0

    var body: some View {
        VStack(spacing: TetherSpace.s) {
            HStack(spacing: TetherSpace.l) {
                device("iphone", label: "This phone", lit: true)
                ZStack {
                    Capsule().fill(TetherColor.hairline).frame(height: 3)
                    if phase >= .finding, phase != .done {
                        Circle().fill(TetherColor.accent).frame(width: 10, height: 10)
                            .offset(x: (t - 0.5) * 120)
                            .shadow(color: TetherColor.accent.opacity(0.8), radius: 6)
                    }
                    if phase == .done {
                        Capsule().fill(TetherColor.ok).frame(height: 3)
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(TetherColor.ok)
                            .background(TetherColor.surface0, in: Circle())
                    }
                }
                .frame(width: 140)
                device("camera.fill", label: cameraName ?? "Canon", lit: phase >= .finding)
            }
            .padding(.top, TetherSpace.s)
            Text(phase == .done ? "Paired" : phase.title).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
        }
        .frame(maxWidth: .infinity)
        .padding(TetherSpace.l)
        .tetherGlassCard()
        .onAppear {
            guard !reduceMotion else { t = 0.5; return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { t = 1 }
        }
        .accessibilityHidden(true)
    }

    private func device(_ symbol: String, label: String, lit: Bool) -> some View {
        VStack(spacing: TetherSpace.xs) {
            Image(systemName: symbol).font(.system(size: 30, weight: .regular))
                .foregroundStyle(lit ? TetherColor.ink0 : TetherColor.ink2)
                .frame(width: 64, height: 64)
                .tetherGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: lit ? TetherColor.accent.opacity(0.18) : nil)
            Text(label).font(TetherFont.hud).foregroundStyle(TetherColor.ink1).lineLimit(1)
        }
        .frame(width: 96)
    }
}

/// What the camera's own screen shows, so the user knows what to press.
private struct CameraScreenMock: View {
    var waiting: Bool
    var done: Bool
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On the camera's screen").font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
            VStack(spacing: 12) {
                Text(done ? "Connected" : "Connect to this smartphone?")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                Text("Open Tether").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 18) {
                    Text("Cancel").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 14).padding(.vertical, 5).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    Text("OK").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 5)
                        .background(done ? TetherColor.ok : Color.white, in: RoundedRectangle(cornerRadius: 4))
                        .scaleEffect(waiting && pulse ? 1.12 : 1)
                        .shadow(color: waiting ? TetherColor.accent.opacity(pulse ? 0.9 : 0.2) : .clear, radius: 10)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color(red: 0.08, green: 0.09, blue: 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            Text(waiting ? "Press OK on the camera now." : (done ? "Saved on the camera." : "When this appears, press OK on the camera."))
                .font(TetherFont.callout).foregroundStyle(waiting ? TetherColor.accent : TetherColor.ink1)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(waiting ? "Press OK on the camera now" : "The camera will ask to connect to Open Tether; press OK")
    }
}

private struct HandshakeStageRow: View {
    var row: CanonPairingModel.HandshakeRow
    var state: CanonPairingModel.StageState

    private var title: String {
        switch row {
        case .link: return "Reached the camera"
        case .hello: return "Introduced this phone as “Open Tether”"
        case .confirm: return "Camera accepted (OK pressed)"
        case .channel: return "Event channel open"
        case .remote: return "Remote control on"
        }
    }

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            Group {
                switch state {
                case .pending: Circle().strokeBorder(TetherColor.hairline, lineWidth: 1.5)
                case .running: ProgressView().controlSize(.small).tint(TetherColor.accent)
                case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(TetherColor.ok)
                }
            }
            .frame(width: 22, height: 22)
            Text(title).font(TetherFont.callout).foregroundStyle(state == .pending ? TetherColor.ink2 : TetherColor.ink0)
            Spacer()
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(state)")
    }
}

private struct PairingCountdown: View {
    var fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(TetherColor.hairline, lineWidth: 3)
            Circle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(TetherColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

private struct StageBadge: View {
    var number: Int
    var state: CanonPairingModel.StageState
    var body: some View {
        ZStack {
            Circle().fill(state == .done ? TetherColor.ok : (state == .running ? TetherColor.accent : TetherColor.surface3))
            if state == .done {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
            } else {
                Text("\(number)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(state == .running ? .white : TetherColor.ink2)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

/// "Menu → A → B → C" as chips, the way the camera's menu reads.
private struct CameraMenuPath: View {
    var items: [String]
    init(_ items: [String]) { self.items = items }
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 6) {
                    Text(item).font(TetherFont.hud).foregroundStyle(TetherColor.ink0)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(TetherColor.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    if i < items.count - 1 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(TetherColor.ink2) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.joined(separator: ", then "))
    }
}

/// Wraps its children onto new lines when they run out of width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
