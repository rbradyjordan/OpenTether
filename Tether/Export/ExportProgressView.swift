import SwiftUI
import TetherCore

struct ExportProgressView: View {
    @Environment(AppModel.self) private var app
    var sessionID: String?
    @State private var shareURLs: [URL]?
    @State private var paused = false

    private var jobs: [ExportJob] { app.exportJobs.filter { sessionID == nil || $0.sessionID == sessionID } }

    var body: some View {
        List {
            if jobs.isEmpty {
                EmptyState(systemImage: "arrow.up.doc", title: "No exports yet", message: "Exports from the shoot screen show up here with per-frame progress.")
                    .listRowBackground(Color.clear)
            }
            ForEach(jobs) { job in jobRow(job) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Exports")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    paused.toggle()
                    Task { if paused { await app.exportQueue.pause() } else { await app.exportQueue.resume() } }
                } label: { Label(paused ? "Resume all" : "Pause all", systemImage: paused ? "play.fill" : "pause.fill") }
            }
        }
        .sheet(item: Binding(get: { shareURLs.map(ShareItems.init) }, set: { shareURLs = $0?.urls })) { items in
            ShareSheet(items: items.urls)
        }
    }

    private func jobRow(_ job: ExportJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(job.destination.displayName, systemImage: icon(job.destination)).font(.headline)
                Spacer()
                Text(statusText(job.status)).font(.caption).foregroundStyle(color(job.status))
            }
            ProgressView(value: job.progress).tint(Theme.accent)
            Text("\(job.items.filter(\.isDone).count) of \(job.items.count) done · \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            DisclosureGroup("Frames") {
                ForEach(job.items) { item in
                    HStack {
                        Text(item.filename).font(.caption).lineLimit(1)
                        if item.watermark { Image(systemName: "drop.halffull").font(.caption2).foregroundStyle(Theme.warning).accessibilityLabel("watermarked") }
                        Spacer()
                        Text(itemState(item.state)).font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .font(.subheadline)
            HStack {
                if !job.failedItems.isEmpty || job.status.key == "failed" {
                    Button("Retry failed") { Task { try? await app.exportQueue.retry(job.id) } }.buttonStyle(.bordered).controlSize(.small)
                }
                if case .share = job.destination, job.status.key == "completed" {
                    Button("Share files") {
                        shareURLs = job.items.compactMap { item in
                            if case .done(let path?) = item.state { return URL(fileURLWithPath: path) }
                            return nil
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if job.creditsCharged > 0 { Text("\(job.creditsCharged) credits").font(.caption).foregroundStyle(Theme.textSecondary) }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.surface)
    }

    private func icon(_ d: ExportDestination) -> String {
        switch d {
        case .photos: return "photo.on.rectangle"
        case .files: return "folder"
        case .share: return "square.and.arrow.up"
        case .ftp: return "server.rack"
        case .cloudBatch: return "icloud.and.arrow.up"
        }
    }

    private func statusText(_ s: ExportJob.Status) -> String {
        switch s {
        case .queued: return "Queued"
        case .running: return "Running"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed(let m): return m
        }
    }

    private func color(_ s: ExportJob.Status) -> Color {
        switch s {
        case .completed: return Theme.success
        case .failed: return Theme.danger
        case .running: return Theme.accent
        default: return Theme.textSecondary
        }
    }

    private func itemState(_ s: ExportJob.Item.State) -> String {
        switch s {
        case .pending: return "waiting"
        case .uploading(let p): return "\(Int(p * 100))%"
        case .done: return "done"
        case .skipped(let r): return "skipped: \(r)"
        case .failed(let r): return "failed: \(r)"
        }
    }
}

struct ShareItems: Identifiable {
    var urls: [URL]
    var id: String { urls.map(\.path).joined(separator: "|") }
}
