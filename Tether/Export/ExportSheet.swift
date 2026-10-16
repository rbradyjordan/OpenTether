import SwiftUI
import TetherCore

struct ExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var sessionID: String
    var items: [CaptureItem]
    var selectedID: String?
    var look: LookStack

    @State private var scope: ExportScope = .all
    @State private var minRating = 3
    @State private var destination: ExportDestinationChoice = .photos
    @State private var applyLook = true
    @State private var includeRAW = false
    @State private var resize = false
    @State private var longEdge = 2048
    @State private var quality = 0.92
    @State private var ftpDestinations: [StoredFTPDestination] = []
    @State private var error: String?

    private var effectiveScope: ExportScope { if case .rated = scope { return .rated(min: minRating) }; return scope }
    private var chosen: [CaptureItem] { effectiveScope.filter(items, selectedID: selectedID) }
    private var options: ExportOptions {
        ExportOptions(applyLook: applyLook, watermark: false, maxLongEdge: resize ? longEdge : nil, jpegQuality: quality, includeRAW: includeRAW)
    }
    private var previewItems: [ExportJob.Item] {
        chosen.filter { $0.kind != .raw || includeRAW }.filter { $0.kind.isStill }
            .map { ExportJob.Item(id: $0.id, filename: $0.filename, kind: $0.kind, bytes: $0.bytes) }
    }
    private var quote: CreditsState.Quote { app.credits.quote(for: previewItems, forceWatermark: false) }

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    Picker("Scope", selection: $scope) {
                        ForEach(ExportScope.presets) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.segmented)
                    if case .rated = scope {
                        Stepper("Minimum rating: \(minRating)", value: $minRating, in: 1 ... 5)
                    }
                    LabeledContent("Frames", value: "\(previewItems.count)")
                }
                Section("Where") {
                    Picker("Destination", selection: $destination) {
                        Text("Photos").tag(ExportDestinationChoice.photos)
                        Text("Files").tag(ExportDestinationChoice.files)
                        Text("Share").tag(ExportDestinationChoice.share)
                        ForEach(ftpDestinations) { d in Text("FTP · \(d.name)").tag(ExportDestinationChoice.ftp(d.id)) }
                        Text("Cloud batch").tag(ExportDestinationChoice.cloud)
                    }
                    NavigationLink("FTP destinations", value: AppRoute.ftpDestinations)
                }
                Section("Options") {
                    Toggle("Apply look", isOn: $applyLook).disabled(look.isNeutral)
                    Toggle("Include RAW files", isOn: $includeRAW)
                    Toggle("Resize", isOn: $resize)
                    if resize {
                        Picker("Long edge", selection: $longEdge) {
                            Text("1024 px").tag(1024)
                            Text("2048 px").tag(2048)
                            Text("3000 px").tag(3000)
                            Text("4096 px").tag(4096)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("JPEG quality \(Int(quality * 100))")
                        Slider(value: $quality, in: 0.5 ... 1, step: 0.02) { Text("JPEG quality") }
                    }
                }
                Section {
                    HStack {
                        Text(CreditsFormatting.quoteText(quote, tier: app.credits.tier))
                        Spacer()
                        NavigationLink("Credits", value: AppRoute.credits).font(.subheadline)
                    }
                    if quote.watermarkedItems > 0 {
                        Text("You are out of free credits; watermarked frames carry a translucent TETHER mark. Buy credits or go Pro to remove it.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                } header: { Text("Cost") }
                if let error { Section { Text(error).foregroundStyle(Theme.danger) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export \(previewItems.count)") { Task { await enqueue() } }.disabled(previewItems.isEmpty)
                }
            }
            .onAppear {
                ftpDestinations = (try? app.store.ftpDestinations()) ?? []
                if look.isNeutral { applyLook = false }
            }
        }
    }

    private func enqueue() async {
        guard let session = try? app.store.session(sessionID) else { error = "Session not found"; return }
        let job = await app.exportQueue.makeJob(session: session, captures: chosen, destination: destination.destination,
                                                options: options, look: look, credits: app.credits)
        do {
            try await app.exportQueue.enqueue(job)
            app.toast = ToastMessage(text: "Exporting \(job.items.count) frames to \(job.destination.displayName)", systemImage: "arrow.up.doc")
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
