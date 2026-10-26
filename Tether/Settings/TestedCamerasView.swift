import SwiftUI
import TetherCore

/// A camera body and how it connects, for the compatibility list.
struct TestedCamera: Identifiable, Hashable {
    var vendor: String, model: String, transports: [String], status: String, notes: String
    var id: String { "\(vendor)/\(model)" }
}

/// The compatibility list, shipped with the app.
struct TestedCamerasView: View {
    @State private var query = ""
    private let cameras = TestedCamerasView.list

    private var filtered: [TestedCamera] {
        query.isEmpty ? cameras : cameras.filter { "\($0.vendor) \($0.model) \($0.notes)".localizedCaseInsensitiveContains(query) }
    }

    private var vendors: [String] { Array(Set(filtered.map(\.vendor))).sorted() }

    var body: some View {
        List {
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
        .tetherList()
        .navigationTitle("Tested cameras")
    }

    private func color(_ status: String) -> Color {
        switch status.lowercased() {
        case "verified", "works": return Theme.success
        case "partial", "beta": return Theme.warning
        default: return Theme.textSecondary
        }
    }

    static let list: [TestedCamera] = [
        .init(vendor: "Canon", model: "EOS R5 / R6 / R6 II", transports: ["usb", "ptpip"], status: "expected", notes: "PC / EOS Utility mode"),
        .init(vendor: "Nikon", model: "Z 6II / Z 7II / Z 8", transports: ["usb", "ptpip"], status: "expected", notes: "USB power delivery off"),
        .init(vendor: "Sony", model: "α7 IV / α7R V / α1", transports: ["usb", "ptpip"], status: "expected", notes: "PC Remote, single session"),
        .init(vendor: "Fujifilm", model: "X-T5 / X-H2 / GFX 100 II", transports: ["usb", "ptpip"], status: "expected", notes: "USB Tether Shooting Auto"),
        .init(vendor: "Ricoh", model: "GR III / GR IIIx", transports: ["ricohHTTP"], status: "expected", notes: "Wi-Fi only"),
        .init(vendor: "Leica", model: "SL2 / Q3 / M11", transports: ["usb"], status: "expected", notes: "USB mode PTP"),
        .init(vendor: "OM System", model: "OM-1 / OM-5", transports: ["usb"], status: "expected", notes: "PC (Tether) mode"),
        .init(vendor: "Panasonic", model: "S5 II / GH6", transports: ["usb"], status: "expected", notes: "USB Mode PC(Tether)"),
        .init(vendor: "Pentax", model: "K-1 II / K-3 III / KP", transports: ["usb"], status: "expected", notes: "USB Connection: PTP; import, capture if offered"),
        .init(vendor: "Sigma", model: "fp / fp L / BF", transports: ["usb"], status: "expected", notes: "USB Mode: Camera Control"),
        .init(vendor: "Hasselblad", model: "X2D / X1D II / 907X", transports: ["usb"], status: "expected", notes: "USB: PTP; import"),
        .init(vendor: "GoPro", model: "HERO9 – HERO13", transports: ["wifi"], status: "expected", notes: "Open GoPro API; photo mode"),
        .init(vendor: "Ricoh", model: "Theta X / Z1 / SC2", transports: ["wifi"], status: "expected", notes: "Open Spherical Camera API"),
        .init(vendor: "Insta360", model: "OSC-capable bodies", transports: ["wifi"], status: "expected", notes: "Open Spherical Camera API"),
        .init(vendor: "Canon", model: "PowerShot (G series)", transports: ["usb"], status: "expected", notes: "Import as you shoot"),
        .init(vendor: "Sony", model: "RX100 / RX10 / ZV (not PC Remote)", transports: ["usb"], status: "expected", notes: "Import as you shoot; PC Remote for control"),
        .init(vendor: "Any brand", model: "PTP over USB", transports: ["usb"], status: "expected", notes: "Import as you shoot"),
    ]
}
