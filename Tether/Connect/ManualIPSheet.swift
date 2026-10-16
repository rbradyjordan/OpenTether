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
                    Text("Ricoh uses HTTP on port 80 (usually 192.168.0.1). Everything else is PTP/IP on 15740.")
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
                        let p = UInt16(port) ?? (vendor == .ricoh ? 80 : PTPIPPacket.standardPort)
                        onAdd(host.trimmingCharacters(in: .whitespaces), p, vendor)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: vendor) { _, v in if v == .ricoh { port = "80" } else if port == "80" { port = "\(PTPIPPacket.standardPort)" } }
        }
        .presentationDetents([.medium])
    }
}
