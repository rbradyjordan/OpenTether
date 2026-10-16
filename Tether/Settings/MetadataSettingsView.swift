import SwiftUI
import TetherCore

/// Settings → Metadata & interoperability. Edits the `MetadataProfile` that
/// exports embed and a live XMP preview for the frame the library has in focus
/// (or the newest frame when nothing is selected).
struct MetadataSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var profile = MetadataProfile()
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Who") {
                TextField("Creator", text: text(\.creator)).textContentType(.name)
                TextField("Copyright, {year} allowed", text: text(\.copyright))
                LabeledContent("Resolves to", value: profile.copyrightLine() ?? "—")
            }
            Section {
                TextField("Caption template", text: text(\.captionTemplate))
                TextField("Hierarchical keyword root", text: text(\.hierarchicalRoot))
                Toggle("Session name as keyword", isOn: $profile.sessionAsKeyword)
            } header: { Text("Keywords and captions") } footer: {
                Text("Caption tokens: {session} {date} {camera} {client} {orig} {rating}. Keywords become Lightroom hierarchical subjects under the root.")
            }
            Section("Where metadata goes") {
                Toggle("Embed XMP in exported JPEGs", isOn: $profile.embedInJPEG)
                Toggle("Write .xmp sidecars for RAW", isOn: $profile.writeSidecarsForRAW)
                Toggle("Write .xmp sidecars for JPEG", isOn: $profile.writeSidecarsForJPEG)
                Toggle("Read XMP from incoming files", isOn: $profile.readIncomingXMP)
            }
            XMPPreviewSection(profile: profile)
        }
        .tetherList()
        .navigationTitle("Metadata")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !loaded { profile = app.memory.get(WorkspaceMemory.metadataProfile); loaded = true } }
        .onChange(of: profile) { _, p in if loaded { app.memory.set(WorkspaceMemory.metadataProfile, p) } }
    }

    /// Optional-string fields edit as plain text; empty saves back as nil.
    private func text(_ path: WritableKeyPath<MetadataProfile, String?>) -> Binding<String> {
        Binding(get: { profile[keyPath: path] ?? "" }, set: { profile[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
}

/// The packet exactly as an export would write it, for the inspected frame.
private struct XMPPreviewSection: View {
    @Environment(AppModel.self) private var app
    var profile: MetadataProfile

    private var item: CaptureItem? {
        app.library.inspectedItem ?? (try? app.store.captures(matching: CaptureFilter(), sort: .captureTimeDescending, limit: 1))?.first
    }

    var body: some View {
        Section {
            if let item {
                let session = try? app.store.session(item.sessionID)
                let packet = XMPPacket(capture: item, tags: app.library.tags(for: item.id), profile: profile, sessionName: session?.name)
                Text(packet.serialized())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(TetherColor.ink1)
                    .textSelection(.enabled)
                    .lineLimit(40)
            } else {
                Text("Shoot or import a frame to preview its XMP.").font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
            }
        } header: {
            Text(item.map { "XMP preview · \($0.filename)" } ?? "XMP preview")
        }
    }
}
