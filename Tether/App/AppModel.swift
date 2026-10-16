import Foundation
import Observation
import TetherCore
import UIKit

/// Root observable: owns the services, the session list, credits, looks,
/// export jobs, the FTP receiver and the active shoot.
@Observable @MainActor
final class AppModel {
    let services: AppServices
    let settings: AppSettings
    let purchases: StoreKitPurchases
    let ftpReceiver: FTPReceiverModel
    /// Between-session memory, the undoable review editor, the library and the
    /// one command dispatcher every menu goes through.
    let memory: WorkspaceMemory
    let editor: ReviewEditor
    private(set) var library: LibraryModel!
    private(set) var commands: CommandDispatcher!

    private(set) var cloud: TetherCloudClient
    var store: SessionStore { services.store }
    var cache: CaptureCacheProxy { services.cache }
    var exportQueue: ExportQueue { services.exportQueue }
    var discovery: CameraDiscoverer { services.discovery }

    var sessions: [ShootSession] = []
    var counts: [String: SessionStore.SessionCounts] = [:]
    var interrupted: [ShootSession] = []
    var looks: [LookDescriptor] = []
    var exportJobs: [ExportJob] = []
    var credits = CreditsState()
    var cloudReachable: Bool?
    var shoot: ShootViewModel?
    var selectedTab: AppTab = .shoot
    /// Regular width: the shoot screen is a full-screen cover over the split view.
    var showShootCover = false
    var toast: ToastMessage?
    var startupError: String?

    private var exportEventsTask: Task<Void, Never>?
    private var automations: SessionAutomations?
    private var automationsTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(services: AppServices, settings: AppSettings) {
        self.services = services
        self.settings = settings
        self.cloud = services.cloud
        let cloudBox = CloudBox(client: services.cloud)
        self.purchases = StoreKitPurchases(cloud: { cloudBox.client })
        self.ftpReceiver = FTPReceiverModel(inbox: services.ftpInbox, settings: settings)
        self.cloudBox = cloudBox
        let memory = WorkspaceMemory(store: services.store)
        let editor = ReviewEditor(store: services.store, memory: memory)
        self.memory = memory
        self.editor = editor
        self.library = LibraryModel(store: services.store, memory: memory, editor: editor)
        self.commands = CommandDispatcher(app: self)
        ftpReceiver.onFileReceived = { [weak self] url, from in
            await self?.shoot?.ingestFTPFile(url, from: from)
        }
    }

    private let cloudBox: CloudBox

    /// Builds everything; a failure here is shown instead of the UI.
    static func boot() -> AppModel? {
        guard let services = try? AppServices.make() else { return nil }
        return AppModel(services: services, settings: AppSettings(store: services.store))
    }

    // MARK: Launch

    func launch() async {
        // Anything still "active" was cut off by a crash or force-quit: mark it first,
        // then load the list so the Resume banner is right from the first frame.
        try? store.markInterruptedSessions()
        reloadSessions()
        reloadLooks()
        reloadExportJobs()
        observeExports()
        library.start()
        await exportQueue.resume()
        Task { await refreshCloud() }
    }

    func reloadSessions() {
        sessions = (try? store.sessions()) ?? []
        interrupted = (try? store.interruptedSessions()) ?? []
        var c: [String: SessionStore.SessionCounts] = [:]
        for s in sessions { c[s.id] = (try? store.counts(in: s.id)) ?? SessionStore.SessionCounts() }
        counts = c
    }

    func reloadLooks() { looks = (try? store.looks()) ?? [] }
    func reloadExportJobs() { exportJobs = (try? store.exportJobs()) ?? [] }

    private func observeExports() {
        exportEventsTask?.cancel()
        let stream = exportQueue.events
        exportEventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .updated(let job):
                    upsertJob(job)
                    if job.status.key == "running" { beginBackgroundTask() }
                case .finished(let job):
                    upsertJob(job)
                    endBackgroundTaskIfIdle()
                    HapticFeedback.success()
                    toast = ToastMessage(text: job.status.key == "completed" ? "Export to \(job.destination.displayName) finished" : "Export finished with errors",
                                         systemImage: job.status.key == "completed" ? "checkmark.circle" : "exclamationmark.triangle")
                case .creditsChanged(let state):
                    credits = state
                }
            }
        }
    }

    private func upsertJob(_ job: ExportJob) {
        if let i = exportJobs.firstIndex(where: { $0.id == job.id }) { exportJobs[i] = job } else { exportJobs.insert(job, at: 0) }
    }

    // MARK: Cloud

    func applyCloudBaseURL(_ text: String) {
        settings.cloudBaseURL = text
        cloud = TetherCloudClient(baseURL: settings.cloudURL, tokens: services.tokens)
        cloudBox.client = cloud
        Task { await refreshCloud() }
    }

    func refreshCloud() async {
        cloudReachable = await cloud.health()
        guard cloudReachable == true else { return }
        await registerIfNeeded()
        if let me = try? await cloud.me() {
            credits = me.state
            settings.accountID = me.accountID
        }
        if let remote = try? await cloud.looks() {
            for look in remote { try? store.saveLook(look, cube: nil) }
            reloadLooks()
        }
    }

    func registerIfNeeded() async {
        guard !cloud.isRegistered else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let reg = try? await cloud.register(deviceID: settings.deviceID, appVersion: version) {
            settings.accountID = reg.accountID
        }
    }

    func refreshCredits() async {
        if let me = try? await cloud.me() { credits = me.state }
    }

    // MARK: Sessions

    func createSession(_ draft: ShootSession) {
        try? store.save(draft)
        reloadSessions()
    }

    /// Makes a live connection the active shoot and switches to the Shoot tab.
    func activate(_ connection: LiveConnection) {
        if let previous = shoot, previous.shootSession.id != connection.shoot.id {
            Task { await previous.end() }
        }
        let vm = ShootViewModel(connection: connection, app: self)
        shoot = vm
        selectedTab = .shoot
        showShootCover = true
        reloadSessions()
        Task { await editor.attach(session: connection.session) }
        library.attachLive(connection.session)
        startAutomations(for: connection)
    }

    func endShoot() async {
        guard let shoot else { return }
        await shoot.end()
        await automations?.stop()
        automationsTask?.cancel()
        automations = nil
        await editor.attach(session: nil)
        library.attachLive(nil)
        memory.learn(from: shoot.shootSession)
        self.shoot = nil
        showShootCover = false
        reloadSessions()
        library.reloadSources()
    }

    /// Template tags, auto-collection and auto-export of picks run beside the
    /// live session; their outcomes surface as toasts.
    private func startAutomations(for connection: LiveConnection) {
        let templateID = memory.get(WorkspaceMemory.sessionDefaults).templateID
        let template = memory.templates().first { $0.id == templateID }
        let rules = SessionAutomations.Rules.from(template: template, session: connection.shoot, memory: memory)
        let auto = SessionAutomations(session: connection.shoot, rules: rules, store: store, editor: editor, queue: exportQueue, memory: memory)
        automations = auto
        automationsTask?.cancel()
        let stream = auto.events
        automationsTask = Task { [weak self] in
            await auto.attach(to: connection.session)
            for await event in stream {
                guard let self else { return }
                switch event {
                case .exportQueued(let job):
                    let n = job.items.count
                    toast = ToastMessage(text: "\(n) pick\(n == 1 ? "" : "s") exporting to \(job.destination.displayName)", systemImage: "arrow.up.doc")
                case .error(let message):
                    toast = ToastMessage(text: message, systemImage: "exclamationmark.triangle")
                case .tagged, .addedToCollection:
                    library.reloadSources()
                }
            }
        }
    }

    /// Returns to the live shoot from anywhere (tab on iPhone, cover on iPad).
    func showShoot() {
        selectedTab = .shoot
        showShootCover = true
    }

    func deleteSession(_ session: ShootSession) {
        if shoot?.shootSession.id == session.id { shoot = nil }
        cache.removeSession(session)
        try? store.deleteSession(session.id)
        reloadSessions()
    }

    func dismissInterrupted(_ session: ShootSession) {
        var s = session
        s.status = .ended
        s.endedAt = Date()
        try? store.save(s)
        reloadSessions()
    }

    /// Resume a session from the store without a camera: the shoot screen then
    /// offers reconnect based on the stored transport/lastHost.
    func resume(_ session: ShootSession) {
        var s = session
        s.status = .active
        try? store.save(s)
        let tether = TetherSession(session: s, identity: s.camera, handler: nil, engine: nil,
                                   store: store, cache: cache, previews: services.previews)
        let context = ReconnectContext.from(session: s)
        let connection = LiveConnection(session: tether, shoot: s, identity: s.camera, context: context, needsReconnect: context != .ftp)
        if context == .ftp { Task { try? await tether.start() } }
        activate(connection)
    }

    // MARK: Scene phase

    func didEnterBackground() {
        // We keep the session object alive; iOS will suspend sockets. On return
        // the transport reports closed and the reconnect sheet appears.
        beginBackgroundTask()
    }

    func didBecomeActive() {
        endBackgroundTaskIfIdle()
        shoot?.checkTransportAfterForeground()
    }

    /// Limitation: a plain `beginBackgroundTask` gives ~30 s to finish exports;
    /// no BGProcessingTask scheduling yet, so long exports pause and resume
    /// from the store on next launch.
    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "tether.exports") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTaskIfIdle() {
        let busy = exportJobs.contains { $0.status.key == "running" }
        if !busy { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

/// Mutable reference so closures built at init see the current cloud client.
final class CloudBox: @unchecked Sendable {
    var client: TetherCloudClient
    init(client: TetherCloudClient) { self.client = client }
}
