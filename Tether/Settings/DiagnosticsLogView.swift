import SwiftUI
import TetherCore

/// Recent PTP transactions from `PTPLog`, newest first.
struct DiagnosticsLogView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [PTPLog.Entry] = []
    @State private var share: ShareItems?

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No transactions recorded yet. Connect a camera and come back.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.line).font(.caption.monospaced()).lineLimit(3)
                    Text(entry.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(entry.error == nil ? Theme.surface : Theme.danger.opacity(0.15))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("PTP log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button { shareLog() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { app.services.ptpLog.clear(); reload() } label: { Label("Clear", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Log actions")
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .onAppear(perform: reload)
    }

    private func reload() { entries = app.services.ptpLog.recent.reversed() }

    private func shareLog() {
        let text = entries.reversed().map { "\($0.at.formatted(date: .omitted, time: .standard)) \($0.line)" }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-ptp-log.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        share = ShareItems(urls: [url])
    }
}
