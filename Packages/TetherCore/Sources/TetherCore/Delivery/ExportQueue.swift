import Foundation

/// Platform hooks the queue needs: saving to Photos / Files and rendering a
/// JPEG with a look and watermark. The app supplies these; tests use fakes.
public protocol ExportSink: Sendable {
    /// Returns a stable identifier (Photos local identifier, file path…).
    func deliver(fileURL: URL, item: ExportJob.Item, destination: ExportDestination) async throws -> String?
}

public protocol ExportRenderer: Sendable {
    /// Produce the bytes to export for one capture: original or re-rendered JPEG.
    func render(original: URL, item: ExportJob.Item, look: CubeLUT?, options: ExportOptions) async throws -> URL
}

/// Pass-through renderer: exports originals untouched (used when no look and no watermark).
public struct PassthroughRenderer: ExportRenderer {
    public init() {}
    public func render(original: URL, item: ExportJob.Item, look: CubeLUT?, options: ExportOptions) async throws -> URL { original }
}

/// Resumable export queue. Persists every job and item state through the
/// store; `resume()` on launch continues interrupted jobs. One job at a time,
/// items sequential (Photos and FTP both prefer that).
public actor ExportQueue {
    public enum Event: Sendable { case updated(ExportJob), finished(ExportJob), creditsChanged(CreditsState) }

    private let store: SessionStore
    private let cache: CaptureCacheProxy
    private let sink: ExportSink
    private let renderer: ExportRenderer
    private var cloud: TetherCloudClient?
    private let looks: LookResolver
    private let memory: WorkspaceMemory?
    private let ftpClientFactory: (@Sendable (StoredFTPDestination) -> FTPUploadingBox?)?
    private var running = false
    private var paused = false
    private var current: Task<Void, Never>?
    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    public init(store: SessionStore, cache: CaptureCacheProxy, sink: ExportSink, renderer: ExportRenderer = PassthroughRenderer(),
                cloud: TetherCloudClient? = nil, looks: LookResolver, memory: WorkspaceMemory? = nil,
                ftpClientFactory: (@Sendable (StoredFTPDestination) -> FTPUploadingBox?)? = nil) {
        self.store = store
        self.cache = cache
        self.sink = sink
        self.renderer = renderer
        self.cloud = cloud
        self.looks = looks
        self.memory = memory
        self.ftpClientFactory = ftpClientFactory
        var c: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        continuation = c
    }

    // MARK: Enqueue

    /// Build a job from captures. RAW is skipped unless `includeRAW`.
    public func makeJob(session: ShootSession, captures: [CaptureItem], destination: ExportDestination,
                        options: ExportOptions, look: LookStack, credits: CreditsState?) -> ExportJob {
        var items = captures.filter { $0.state.isReady && ($0.kind != .raw || options.includeRAW) && $0.kind.isStill }
            .map { ExportJob.Item(id: $0.id, filename: $0.filename, kind: $0.kind, bytes: $0.bytes) }
        if let credits {
            let watermarkAll = options.watermark || credits.watermarkRequired
            var remaining = credits.tier == .pro ? Int.max : credits.balance
            for i in items.indices where items[i].kind != .raw {
                if watermarkAll { items[i].watermark = true; continue }
                if remaining > 0 { remaining -= 1 } else { items[i].watermark = true }
            }
        }
        // Interop: resolve names and folders now so the UI can preview them.
        let caps = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0) })
        var used = Set<String>()
        for i in items.indices {
            guard let c = caps[items[i].id] else { continue }
            let dir = options.layout.directory(for: c, sessionName: session.name)
            let ext = (c.filename as NSString).pathExtension
            var base = options.naming.render(capture: c, sessionName: session.name, index: c.sequence, camera: session.camera?.displayName,
                                             tags: (try? store.tags(for: c.id)) ?? [], client: session.workflowTag)
            var name = ext.isEmpty ? base : "\(base).\(ext)"
            var n = 1
            while used.contains((dir + "/" + name).lowercased()) { n += 1; name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)" }
            used.insert((dir + "/" + name).lowercased())
            _ = base
            base = ""
            items[i].exportFilename = name
            items[i].exportDirectory = dir
        }
        return ExportJob(sessionID: session.id, destination: destination, options: options, look: look, items: items)
    }

    /// Where companions (sidecars, manifests) make sense: anywhere files land as files.
    private func deliversFiles(_ d: ExportDestination) -> Bool {
        switch d { case .photos, .share: return false; default: return true }
    }

    public func enqueue(_ job: ExportJob) throws {
        try store.save(job)
        continuation.yield(.updated(job))
        kick()
    }

    /// Swap the cloud client when the user changes the server URL.
    public func setCloud(_ client: TetherCloudClient?) { cloud = client }

    public func pause() { paused = true; current?.cancel() }
    public func resume() { paused = false; kick() }

    public func jobs(sessionID: String? = nil) throws -> [ExportJob] { try store.exportJobs(sessionID: sessionID) }

    public func retry(_ jobID: String) throws {
        guard var job = try store.exportJobs().first(where: { $0.id == jobID }) else { return }
        for i in job.items.indices { if case .failed = job.items[i].state { job.items[i].state = .pending } }
        job.status = .queued
        try store.save(job)
        continuation.yield(.updated(job))
        kick()
    }

    // MARK: Worker

    private func kick() {
        guard !running, !paused else { return }
        running = true
        current = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { running = false }
        while !paused, !Task.isCancelled {
            guard let next = (try? store.pendingExportJobs())?.first else { return }
            await run(next)
        }
    }

    private func run(_ input: ExportJob) async {
        var job = input
        job.status = .running
        job.attempts += 1
        save(job)
        let lut = try? await looks.lut(for: job.look)

        do {
            if case .cloudBatch = job.destination { try await ensureCloudBatch(&job) }
            for idx in job.items.indices {
                if Task.isCancelled || paused { job.status = .paused; save(job); return }
                guard !job.items[idx].isDone else { continue }
                if case .failed = job.items[idx].state { continue }
                do {
                    try await export(item: idx, of: &job, lut: lut)
                } catch is CancellationError {
                    job.status = .paused; save(job); return
                } catch {
                    job.items[idx].state = .failed("\(error)")
                    save(job)
                }
            }
            if case .cloudBatch = job.destination, let cloud, let b = job.cloudBatchID, job.failedItems.isEmpty {
                _ = try await cloud.completeBatch(b)
            }
            job.status = job.failedItems.isEmpty ? .completed : .failed("\(job.failedItems.count) of \(job.items.count) failed")
            if job.failedItems.isEmpty { await writeManifestIfWanted(job) }
        } catch {
            job.status = .failed("\(error)")
        }
        save(job)
        continuation.yield(.finished(job))
    }

    private func export(item idx: Int, of job: inout ExportJob, lut: CubeLUT?) async throws {
        let item = job.items[idx]
        guard let capture = try store.capture(item.id), let rel = capture.relativePath else {
            job.items[idx].state = .skipped("original missing")
            save(job)
            return
        }
        job.items[idx].state = .uploading(0)
        save(job)
        let original = try cache.url(for: rel)
        var options = job.options
        options.watermark = item.watermark
        var rendered = item.kind == .raw ? original : try await renderer.render(original: original, item: item, look: job.options.applyLook ? lut : nil, options: options)
        let profile = memory?.get(WorkspaceMemory.metadataProfile) ?? MetadataProfile()
        let sessionName = try store.session(job.sessionID)?.name
        let packet = XMPPacket(capture: capture, tags: try store.tags(for: capture.id), profile: profile, sessionName: sessionName)
        if job.options.embedMetadata, profile.embedInJPEG, item.kind == .jpeg {
            if let data = try? Data(contentsOf: rendered), let stamped = try? JPEGXMP.embed(packet, in: data) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tether-xmp-\(UUID().uuidString).jpg")
                try stamped.write(to: tmp)
                if rendered != original { try? FileManager.default.removeItem(at: rendered) }
                rendered = tmp
            }
        }
        var sidecar: (Data, String)?
        if job.options.writeSidecars, deliversFiles(job.destination),
           (item.kind == .raw && profile.writeSidecarsForRAW) || (item.kind != .raw && profile.writeSidecarsForJPEG) {
            let base = ((item.exportFilename ?? item.filename) as NSString).deletingPathExtension
            sidecar = (packet.data, base + ".xmp")
        }

        switch job.destination {
        case .cloudBatch:
            guard let cloud else { throw CloudError.notRegistered }
            guard let put = job.items[idx].remoteID else { throw CloudError.decoding("no put url for item") }
            let already = try await cloud.storedBytes(putURL: put)
            let size = (try? FileManager.default.attributesOfItem(atPath: rendered.path)[.size] as? Int) ?? 0
            if already == 0 || already != size {
                try await cloud.upload(fileURL: rendered, to: put, contentType: item.kind == .raw ? "application/octet-stream" : "image/jpeg")
            }
            job.items[idx].state = .done(put)
            try? store.recordExport(captureID: item.id, destination: .cloud, jobID: job.id, remoteID: put)
        case .ftp(let destinationID):
            guard let dest = try store.ftpDestinations().first(where: { $0.id == destinationID }),
                  let client = ftpClientFactory?(dest) else { throw ExportError.ftpDestinationMissing }
            let data = try Data(contentsOf: rendered)
            let remote = (dest.remoteDirectory as NSString).appendingPathComponent(item.filename)
            try await client.upload(data, remote)
            job.items[idx].state = .done(remote)
            try? store.recordExport(captureID: item.id, destination: .ftp, jobID: job.id, remoteID: remote)
        default:
            let id = try await sink.deliver(fileURL: rendered, item: item, destination: job.destination)
            job.items[idx].state = .done(id)
            let key: CaptureFilter.ExportDestinationKey = { if case .photos = job.destination { return .photos }; return .files }()
            try? store.recordExport(captureID: item.id, destination: key, jobID: job.id, remoteID: id)
        }
        if rendered != original { try? FileManager.default.removeItem(at: rendered) }
        if let (data, name) = sidecar { try await deliverCompanion(data, named: name, directory: item.exportDirectory, job: job) }
        save(job)
    }

    /// Send a generated file (sidecar, manifest) the same way the photos went.
    private func deliverCompanion(_ data: Data, named name: String, directory: String?, job: ExportJob) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tether-companion-\(UUID().uuidString)-\(name)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let item = ExportJob.Item(id: "companion-\(name)", filename: name, kind: .other, bytes: data.count, exportFilename: name, exportDirectory: directory, isCompanion: true)
        switch job.destination {
        case .ftp(let destinationID):
            guard let dest = try store.ftpDestinations().first(where: { $0.id == destinationID }), let client = ftpClientFactory?(dest) else { return }
            try await client.upload(data, (dest.remoteDirectory as NSString).appendingPathComponent(item.deliveredRelativePath))
        case .cloudBatch:
            break // the cloud batch keeps metadata in the manifest it already stores
        default:
            _ = try await sink.deliver(fileURL: tmp, item: item, destination: job.destination)
        }
    }

    /// Manifest (JSON + CSV) for a finished job, when the destination holds files.
    private func writeManifestIfWanted(_ job: ExportJob) async {
        guard job.options.writeManifest, deliversFiles(job.destination), let session = try? store.session(job.sessionID) else { return }
        let caps = (try? store.captures(ids: job.items.filter { !$0.isCompanion }.map(\.id))) ?? []
        var tags: [String: [String]] = [:], colls: [String: [String]] = [:]
        let names = Dictionary(uniqueKeysWithValues: job.items.compactMap { i in i.exportFilename.map { (i.id, $0) } })
        for c in caps {
            tags[c.id] = try? store.tags(for: c.id)
            colls[c.id] = (try? store.collectionIDs(containing: c.id))?.compactMap { try? store.collection($0)?.name }
        }
        let manifest = SessionManifest(session: session, captures: caps, tags: tags, collections: colls, exportedNames: names)
        let base = NamingTemplate.safe(session.name)
        if let json = try? manifest.json() { try? await deliverCompanion(json, named: "\(base)-manifest.json", directory: job.options.layout == .captureOne ? "\(base)/Output" : "", job: job) }
        try? await deliverCompanion(Data(manifest.csv().utf8), named: "\(base)-manifest.csv", directory: job.options.layout == .captureOne ? "\(base)/Output" : "", job: job)
    }

    private func ensureCloudBatch(_ job: inout ExportJob) async throws {
        guard job.cloudBatchID == nil else { return }
        guard let cloud else { throw CloudError.notRegistered }
        let session = try store.session(job.sessionID)
        let reqs = job.items.map { TetherCloudClient.BatchItemRequest(clientID: $0.id, filename: $0.filename, kind: $0.kind == .raw ? "raw" : "jpeg", bytes: $0.bytes) }
        var manifest: SessionManifest?
        if job.options.writeManifest, let session {
            let caps = try store.captures(ids: job.items.map(\.id))
            var tags: [String: [String]] = [:], colls: [String: [String]] = [:]
            for c in caps {
                tags[c.id] = try? store.tags(for: c.id)
                colls[c.id] = (try? store.collectionIDs(containing: c.id))?.compactMap { try? store.collection($0)?.name }
            }
            let names = Dictionary(uniqueKeysWithValues: job.items.compactMap { i in i.exportFilename.map { (i.id, $0) } })
            manifest = SessionManifest(session: session, captures: caps, tags: tags, collections: colls, exportedNames: names)
        }
        let batch = try await cloud.createBatch(sessionName: session?.name ?? "Session", watermark: job.options.watermark, lookID: job.look.lookID, items: reqs, manifest: manifest)
        job.cloudBatchID = batch.batchID
        job.creditsCharged = batch.creditsCharged
        for b in batch.items {
            if let i = job.items.firstIndex(where: { $0.id == b.clientID }) {
                job.items[i].remoteID = b.putURL
                job.items[i].watermark = b.watermark
            }
        }
        save(job)
        if let me = try? await cloud.me() { continuation.yield(.creditsChanged(me.state)) }
    }

    private func save(_ job: ExportJob) {
        try? store.save(job)
        continuation.yield(.updated(job))
    }
}

public enum ExportError: Error, CustomStringConvertible {
    case ftpDestinationMissing
    case renderFailed(String)
    public var description: String {
        switch self {
        case .ftpDestinationMissing: return "The FTP destination for this export no longer exists."
        case .renderFailed(let s): return "Could not render the export: \(s)"
        }
    }
}

/// Type-erased FTP uploader so the queue does not depend on the FTP module's
/// concrete types (which live in `FTP/`).
public struct FTPUploadingBox: Sendable {
    public let upload: @Sendable (Data, String) async throws -> Void
    public init(upload: @escaping @Sendable (Data, String) async throws -> Void) { self.upload = upload }
}
