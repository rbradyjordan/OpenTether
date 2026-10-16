import SwiftUI
import TetherCore

/// Matrix from the cloud with a built-in fallback when offline.
struct TestedCamerasView: View {
    @Environment(AppModel.self) private var app
    @State private var cameras: [TetherCloudClient.TestedCamera] = TestedCamerasView.fallback
    @State private var offline = false
    @State private var query = ""

    private var filtered: [TetherCloudClient.TestedCamera] {
        query.isEmpty ? cameras : cameras.filter { "\($0.vendor) \($0.model) \($0.notes)".localizedCaseInsensitiveContains(query) }
    }

    private var vendors: [String] { Array(Set(filtered.map(\.vendor))).sorted() }

    var body: some View {
        List {
            if offline {
                Text("Showing the built-in list; the cloud was unreachable.").font(.footnote).foregroundStyle(Theme.warning)
            }
            ForEach(vendors, id: \.self) { vendor in
                Section(vendor) {
                    ForEach(filtered.filter { $0.vendor == vendor }) { cam in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(cam.model).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(cam.status.capitalized).font(.caption).foregroundStyle(color(cam.status))
                            }
                            Text(cam.transports.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.textSecondary)
                            if !cam.notes.isEmpty { Text(cam.notes).font(.caption2).foregroundStyle(Theme.textSecondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Model")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Tested cameras")
        .task {
            if let remote = try? await app.cloud.testedCameras(), !remote.isEmpty { cameras = remote } else { offline = true }
        }
    }

    private func color(_ status: String) -> Color {
        switch status.lowercased() {
        case "verified", "works": return Theme.success
        case "partial", "beta": return Theme.warning
        default: return Theme.textSecondary
        }
    }

    static let fallback: [TetherCloudClient.TestedCamera] = [
        .init(vendor: "Canon", model: "EOS R5 / R6 / R6 II", transports: ["usb", "ptpip"], status: "expected", notes: "PC / EOS Utility mode"),
        .init(vendor: "Nikon", model: "Z 6II / Z 7II / Z 8", transports: ["usb", "ptpip"], status: "expected", notes: "USB power delivery off"),
        .init(vendor: "Sony", model: "α7 IV / α7R V / α1", transports: ["usb", "ptpip"], status: "expected", notes: "PC Remote, single session"),
        .init(vendor: "Fujifilm", model: "X-T5 / X-H2 / GFX 100 II", transports: ["usb", "ptpip"], status: "expected", notes: "USB Tether Shooting Auto"),
        .init(vendor: "Ricoh", model: "GR III / GR IIIx", transports: ["ricohHTTP"], status: "expected", notes: "Wi-Fi only"),
        .init(vendor: "Leica", model: "SL2 / Q3 / M11", transports: ["usb"], status: "expected", notes: "USB mode PTP"),
        .init(vendor: "OM System", model: "OM-1 / OM-5", transports: ["usb"], status: "expected", notes: "PC (Tether) mode"),
        .init(vendor: "Panasonic", model: "S5 II / GH6", transports: ["usb"], status: "expected", notes: "USB Mode PC(Tether)"),
    ]
}
