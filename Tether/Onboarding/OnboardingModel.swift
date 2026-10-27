import Observation
import Photos
import SwiftUI
import TetherCore

/// State for the first-run flow: which camera, how it connects, which
/// permissions are in place and the workflow defaults. Nothing is saved until
/// `finish`, except permission answers (the system keeps those).
@Observable @MainActor
final class OnboardingModel {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, camera, connection, setup, permissions, workflow, tour, ready
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .camera: return "Camera"
            case .connection: return "Connection"
            case .setup: return "Setup"
            case .permissions: return "Permissions"
            case .workflow: return "Workflow"
            case .tour: return "Tour"
            case .ready: return "Ready"
            }
        }
    }

    // MARK: Navigation

    private(set) var step: Step = .welcome
    /// +1 moving forward, -1 back; drives the slide direction.
    private(set) var direction = 1

    /// Steps that apply: no connection or setup without a camera.
    var steps: [Step] {
        Step.allCases.filter { s in
            switch s {
            case .connection, .setup: return body != nil
            default: return true
            }
        }
    }

    var index: Int { steps.firstIndex(of: step) ?? 0 }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { step == .ready }

    func next() {
        guard index + 1 < steps.count else { return }
        direction = 1
        step = steps[index + 1]
    }

    func back() {
        guard index > 0 else { return }
        direction = -1
        step = steps[index - 1]
    }

    func go(to target: Step) {
        guard steps.contains(target) else { return }
        direction = (steps.firstIndex(of: target) ?? 0) >= index ? 1 : -1
        step = target
    }

    /// Whether Continue is allowed on this step.
    var canContinue: Bool {
        switch step {
        case .camera: return body != nil || noCameraYet
        case .connection: return connection != nil
        default: return true
        }
    }

    // MARK: Camera

    var brand: CameraVendor?
    var body: OnboardingBody?
    var noCameraYet = false

    func pickBrand(_ vendor: CameraVendor) {
        brand = vendor
        noCameraYet = false
        // Canon needs a model (menus differ); every other brand is one entry.
        body = vendor == .canon ? nil : OnboardingBody.brandBody(vendor)
        connection = body?.vendor.onboardingConnections.first
    }

    func pickBody(_ b: OnboardingBody) {
        body = b
        noCameraYet = false
        // Keep the user's connection if this body offers it too.
        if !(connection.map(b.vendor.onboardingConnections.contains) ?? false) {
            connection = b.vendor.onboardingConnections.first
        }
    }

    func pickNoCamera() {
        brand = nil
        body = nil
        connection = nil
        noCameraYet = true
    }

    // MARK: Connection

    var connection: OnboardingConnection?

    var availableConnections: [OnboardingConnection] {
        body?.vendor.onboardingConnections ?? OnboardingConnection.allCases
    }

    // MARK: Setup checklist

    /// Steps the user ticked in the tailored guide.
    var checked: Set<String> = []

    func toggle(_ step: SetupStep) {
        if checked.contains(step.id) { checked.remove(step.id) } else { checked.insert(step.id) }
    }

    // MARK: Permissions

    enum Need: Equatable { case required, recommended, optional, notNeeded }

    var photos: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    var usb = USBAuthorizationState()
    var ssid: SSIDAuthorization = .notDetermined
    /// iOS doesn't report Local Network status; we track whether we asked.
    var localNetworkAsked = false
    var askingLocalNetwork = false

    var localNetworkNeed: Need {
        guard let connection else { return noCameraYet ? .optional : .recommended }
        return connection.needsLocalNetwork ? .required : .optional
    }

    var usbNeed: Need {
        guard let connection else { return .optional }
        return connection == .usb ? .required : .optional
    }

    var ssidNeed: Need {
        guard let connection else { return .optional }
        return connection == .cameraNetwork ? .recommended : (connection == .usb ? .notNeeded : .optional)
    }

    var photosNeed: Need { .recommended }

    func refreshPermissions(app: AppModel) async {
        photos = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        usb = app.services.usbBrowser.currentAuthorization()
        ssid = await app.services.ssid.authorizationState
    }

    func askLocalNetwork(app: AppModel) {
        guard !askingLocalNetwork else { return }
        askingLocalNetwork = true
        // Starting discovery triggers the system prompt; stop again shortly after.
        Task {
            try? await app.discovery.start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await app.discovery.stop()
            localNetworkAsked = true
            askingLocalNetwork = false
        }
    }

    func askPhotos() {
        Task { photos = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
    }

    func askUSB(app: AppModel) {
        Task { usb = await app.services.usbBrowser.requestAuthorizations() }
    }

    func askSSID(app: AppModel) {
        Task {
            await app.services.ssid.requestAuthorization()
            ssid = await app.services.ssid.authorizationState
        }
    }

    // MARK: Workflow

    var shootKind: ShootKind = .other {
        didSet {
            namePattern = shootKind.namePattern
            destination = shootKind.suggestedDestination
        }
    }
    var destination: CaptureDestination = .both
    var jpegTarget: RoutingRules.Target = .photos
    var rawTarget: RoutingRules.Target = .files
    var autoExportPicks = false
    var lookID: String?
    var namePattern = ShootKind.other.namePattern

    /// Starts from whatever was saved before (replaying the intro keeps it).
    func load(app: AppModel) {
        let d = app.memory.get(WorkspaceMemory.sessionDefaults)
        destination = d.destination
        jpegTarget = d.routing.jpeg
        rawTarget = d.routing.raw
        autoExportPicks = d.autoExportPicks
        lookID = d.look.lookID
        namePattern = d.namePattern
        if let raw = app.store.setting(Keys.body) {
            if let b = OnboardingBody.canon.first(where: { $0.id == raw }) {
                brand = .canon; body = b
            } else if raw.hasPrefix("brand."), let v = CameraVendor(rawValue: String(raw.dropFirst(6))) {
                brand = v; body = OnboardingBody.brandBody(v)
            }
        }
        if let raw = app.store.setting(Keys.connection) { connection = OnboardingConnection(rawValue: raw) }
    }

    /// Saves the choices and leaves onboarding. `then` runs after the root
    /// view has switched (connect now, start the demo…).
    func finish(app: AppModel) {
        var d = app.memory.get(WorkspaceMemory.sessionDefaults)
        d.destination = destination
        d.routing = RoutingRules(jpeg: jpegTarget, raw: rawTarget, autoExportPicks: autoExportPicks, liveFolderID: d.routing.liveFolderID)
        d.autoExportPicks = autoExportPicks
        d.look = LookStack(lookID: lookID)
        d.namePattern = namePattern
        if shootKind == .realEstate { d.templateID = WorkspaceMemory.SessionTemplate.listing.id }
        app.memory.set(WorkspaceMemory.sessionDefaults, d)
        app.store.setSetting(Keys.body, body?.id)
        app.store.setSetting(Keys.connection, connection?.rawValue)
        app.store.setSetting(Keys.shootKind, shootKind.rawValue)
        app.settings.hasOnboarded = true
    }

    #if DEBUG
    /// Simulator screenshots: `-OTOnboardingStep setup -OTOnboardingBody canon.r5m2 -OTOnboardingConnection cameraNetwork`.
    func applyDebugLaunchArguments() {
        let args = UserDefaults.standard
        if let raw = args.string(forKey: "OTOnboardingBody") {
            if let b = OnboardingBody.canon.first(where: { $0.id == raw }) { brand = .canon; pickBody(b) }
            else if let v = CameraVendor(rawValue: raw) { pickBrand(v) }
        }
        if let raw = args.string(forKey: "OTOnboardingConnection") { connection = OnboardingConnection(rawValue: raw) }
        if let raw = args.string(forKey: "OTOnboardingStep"), let s = Step.allCases.first(where: { "\($0)" == raw }) { step = s }
    }
    #endif

    enum Keys {
        static let body = "onboarding.body"
        static let connection = "onboarding.connection"
        static let shootKind = "onboarding.shootKind"
    }
}
