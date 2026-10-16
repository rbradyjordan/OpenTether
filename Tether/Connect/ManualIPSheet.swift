import SwiftUI
import TetherCore

struct ManualIPSheet: View {
    var onAdd: (String, UInt16, CameraVendor?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "\(PTPIPPacket.standardPort)"
    @State private var vendor: CameraVendor? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera address") {
                    TextField("192.168.1.2", text: $host)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Host or IP address")
                    TextField("Port", text: $port).keyboardType(.numberPad).accessibilityLabel("Port")
                }
                Section("Brand") {
                    Picker("Brand", selection: $vendor) {
                        Text("Detect from the camera").tag(CameraVendor?.none)
                        ForEach(CameraVendor.allCases.filter { $0.supportsWirelessControl }) { v in
                            Text(v.displayName).tag(CameraVendor?.some(v))
                        }
                    }
                    Text("Ricoh GR: 192.168.0.1 · GoPro: 10.5.5.9 port 8080 · Theta: 192.168.1.1 · Insta360: 192.168.42.1. Everything else is PTP/IP on 15740.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .tetherList()
            .navigationTitle("Enter IP address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let p = UInt16(port) ?? Self.defaultPort(vendor)
                        onAdd(host.trimmingCharacters(in: .whitespaces), p, vendor)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: vendor) { _, v in
                port = "\(Self.defaultPort(v))"
                if host.isEmpty, let suggested = Self.defaultHost(v) { host = suggested }
            }
        }
        .presentationDetents([.medium])
    }

    static func defaultPort(_ vendor: CameraVendor?) -> UInt16 {
        switch vendor {
        case .ricoh?, .osc?: return 80
        case .gopro?: return 8080
        default: return PTPIPPacket.standardPort
        }
    }

    static func defaultHost(_ vendor: CameraVendor?) -> String? {
        switch vendor {
        case .ricoh?: return RicohProbe.defaultHost
        case .gopro?: return "10.5.5.9"
        case .osc?: return OSCHandler.defaultHosts.first
        default: return nil
        }
    }
}
