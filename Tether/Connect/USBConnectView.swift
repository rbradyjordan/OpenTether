import SwiftUI
import TetherCore

struct USBConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var model: USBConnectViewModel?
    @State private var session: ShootSession?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let model {
                    content(model)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("USB-C")
        .onAppear {
            if model == nil { model = USBConnectViewModel(browser: app.services.usbBrowser) }
            model?.start()
        }
        .onDisappear { model?.stop() }
    }

    @ViewBuilder private func content(_ model: USBConnectViewModel) -> some View {
        SessionPickerField(selection: $session)

        SectionCard(title: "Permissions", systemImage: "lock.shield") {
            HStack {
                Image(systemName: model.authorization.canSendPTP ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.authorization.canSendPTP ? Theme.success : Theme.warning)
                Text(model.authorization.summary).font(.subheadline)
                Spacer()
                if !model.authorization.canSendPTP {
                    Button("Allow") { model.requestAuthorizations() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }

        if let progress = model.progress {
            ConnectingProgressView(progress: progress) { model.progress = nil }
        }

        SectionCard(title: "Cameras on the cable", systemImage: "camera") {
            if model.devices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { ProgressView().controlSize(.small); Text("Looking for a camera…").font(.subheadline) }
                    Text("Use a data-capable USB-C cable and set the camera's USB mode to PC Remote / PTP. No hubs for the first try.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            } else {
                ForEach(model.devices) { device in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.subheadline.weight(.medium))
                            Text("\(device.vendorGuess.displayName) · \(USBIDs.hex(device.usbVendorID)):\(USBIDs.hex(device.usbProductID))\(device.serialNumber.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            if !device.vendorGuess.supportsWiredControl {
                                Text("Import only over USB for this brand").font(.caption2).foregroundStyle(Theme.warning)
                            }
                        }
                        Spacer()
                        Button("Connect") {
                            model.connect(device, shoot: SessionPickerField.resolve(session, app: app), app: app)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isConnecting || !model.authorization.canSendPTP)
                        .accessibilityLabel("Connect to \(device.name)")
                    }
                }
            }
            if let error = model.browserError {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
        }

        NavigationLink(value: AppRoute.diagnostics(wired: true)) {
            HStack {
                Image(systemName: "stethoscope")
                Text("Something wrong? Run the cable diagnostic")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.subheadline)
            .padding(14)
            .cardBackground()
        }
        .buttonStyle(.plain)

        NavigationLink(value: AppRoute.brandGuides) {
            Text("Camera menu settings for USB tethering").font(.footnote).foregroundStyle(Theme.accent)
        }
    }
}
