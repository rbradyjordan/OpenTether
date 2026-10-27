import SwiftUI
import TetherCore
import UIKit

struct WiFiConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var model: WiFiConnectViewModel?
    @State private var session: ShootSession?
    @State private var showManual = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let model { content(model) }
            }
            .padding(16)
        }
        .tetherScreen()
        .navigationTitle("Wi-Fi")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showManual = true } label: { Label("Enter IP", systemImage: "keyboard") }
            }
        }
        .sheet(isPresented: $showManual) {
            ManualIPSheet { host, port, vendor in model?.addManual(host: host, port: port, vendor: vendor) }
        }
        .onAppear {
            if model == nil { model = WiFiConnectViewModel(discovery: app.discovery, ssid: app.services.ssid) }
            model?.start()
        }
        .onDisappear { model?.stop() }
    }

    @ViewBuilder private func content(_ model: WiFiConnectViewModel) -> some View {
        SessionPickerField(selection: $session)
        ssidBanner(model)
        if model.cameraNetworkVendor == .canon || model.cameras.contains(where: { $0.vendor == .canon }) {
            SectionCard(title: "First time with this camera?", systemImage: "link") {
                Text("Canon bodies pair once. On the camera, choose Connect to EOS Utility → Add a device to connect to, join its Wi-Fi, then tap Connect here. The camera shows \"Open Tether\": press OK on the camera to finish. After that it connects without asking.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        if let progress = model.progress {
            ConnectingProgressView(progress: progress) { model.progress = nil }
        }
        if model.cameras.isEmpty {
            SectionCard(title: "Looking on this network", systemImage: "dot.radiowaves.left.and.right") {
                HStack { ProgressView().controlSize(.small); Text("Scanning this network for cameras…").font(.subheadline) }
                Text("The camera must be in its remote-control Wi-Fi mode (Canon: Connect to EOS Utility; Nikon: Connect to PC; Sony: PC Remote), and the phone must be on the camera's network. A scan takes about ten seconds. Still nothing? Use Enter IP.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                if !model.discoveryErrors.isEmpty {
                    ForEach(model.discoveryErrors.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(model.discoveryErrors[key] ?? "")").font(.caption2).foregroundStyle(Theme.warning)
                    }
                }
            }
        } else {
            ForEach(model.groups, id: \.vendor) { group in
                SectionCard(title: group.vendor?.displayName ?? "Unknown brand", systemImage: "camera") {
                    ForEach(group.cameras) { camera in
                        cameraRow(camera, model)
                    }
                }
            }
        }
        NavigationLink(value: AppRoute.diagnostics(wired: false)) {
            HStack { Image(systemName: "stethoscope"); Text("Run the wireless diagnostic"); Spacer(); Image(systemName: "chevron.right") }
                .font(.subheadline).padding(14).cardBackground()
        }
        .buttonStyle(.plain)
    }

    private func ssidBanner(_ model: WiFiConnectViewModel) -> some View {
        SectionCard(title: "Current Wi-Fi", systemImage: "wifi") {
            if let ssid = model.ssid {
                Text(ssid).font(.title3.weight(.semibold))
                if let vendor = model.cameraNetworkVendor {
                    Label("Looks like a \(vendor.displayName) camera network", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(Theme.success)
                } else {
                    Label("This does not look like a camera network. Join the camera's own Wi-Fi first.", systemImage: "info.circle")
                        .font(.subheadline).foregroundStyle(Theme.warning)
                }
            } else if model.ssidAuthorization == .unavailable {
                Text("macOS does not share the network name with apps. Check the Wi-Fi menu in the menu bar: it should show the camera's network.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else if model.ssidAuthorization == .denied {
                Text("Location access is off, so the network name is hidden. Open Tether only uses it to recognise camera networks.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Network name unavailable").font(.subheadline).foregroundStyle(Theme.textSecondary)
                if model.ssidAuthorization == .notDetermined {
                    Button("Allow reading the network name") { model.requestSSIDAccess() }.buttonStyle(.tetherSecondary).controlSize(.small)
                }
            }
            Text("Open Tether never joins a Wi-Fi network for you.").font(.caption).foregroundStyle(Theme.textSecondary)
            Button {
                MacSupport.openWiFiSettings()
            } label: {
                Label("Open Wi-Fi Settings", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.tetherSecondary)
        }
    }

    private func cameraRow(_ camera: DiscoveredCamera, _ model: WiFiConnectViewModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.name).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(camera.host):\(camera.port)").font(.caption).foregroundStyle(Theme.textSecondary)
                    MethodBadge(method: camera.method)
                    if !camera.isControllable {
                        Text("import only").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.warning.opacity(0.2), in: Capsule()).foregroundStyle(Theme.warning)
                    }
                }
            }
            Spacer()
            if model.connectingID == camera.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect") { model.connect(camera, shoot: SessionPickerField.resolve(session, app: app), app: app) }
                    .buttonStyle(.tetherPrimary).controlSize(.small).disabled(model.isConnecting)
                    .accessibilityLabel("Connect to \(camera.name)")
            }
        }
    }
}

struct MethodBadge: View {
    var method: DiscoveryMethod
    var body: some View {
        Text(label).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.surfaceRaised, in: Capsule()).foregroundStyle(Theme.textSecondary)
            .accessibilityLabel("Found via \(label)")
    }
    private var label: String {
        switch method {
        case .ssdp: return "SSDP"
        case .bonjour: return "Bonjour"
        case .fujiUDP: return "Fuji"
        case .ricohHTTP, .httpProbe: return "HTTP"
        case .manual: return "Manual"
        case .portScan: return "Scan"
        }
    }
}
