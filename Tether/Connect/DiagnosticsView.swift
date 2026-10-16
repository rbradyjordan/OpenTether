import SwiftUI
import TetherCore
import UIKit

/// Runs the wired or wireless checklist against the real browser/transport.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    var wired: Bool

    @State private var report: DiagnosticReport?
    @State private var running = false
    @State private var shareText: ShareText?
    @State private var host = RicohProbe.defaultHost
    @State private var port = "\(PTPIPPacket.standardPort)"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !wired {
                    SectionCard(title: "Camera to probe", systemImage: "network") {
                        TextField("Host", text: $host).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityLabel("Camera host")
                        TextField("Port", text: $port).textFieldStyle(.roundedBorder).keyboardType(.numberPad).accessibilityLabel("Camera port")
                    }
                }
                if let report {
                    SectionCard(title: report.verdict, systemImage: "stethoscope") {
                        ForEach(report.checks) { check in checkRow(check) }
                    }
                }
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "Checking…" : (report == nil ? "Run diagnostic" : "Run again"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(running)
                if let report, report.finishedAt != nil {
                    Button { shareText = ShareText(text: report.shareText) } label: {
                        Label("Share report", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(wired ? "Cable diagnostic" : "Wireless diagnostic")
        .sheet(item: $shareText) { item in ShareSheet(items: [item.text]) }
        .onAppear {
            if !wired, let first = app.discovery.current.first {
                host = first.host
                port = "\(first.port)"
            }
        }
    }

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                outcomeIcon(check.outcome)
                Text(check.title).font(.subheadline.weight(.medium))
                Spacer()
            }
            Text(check.outcome.detail).font(.footnote).foregroundStyle(color(check.outcome))
            if check.outcome.isFailure || isWarn(check.outcome) {
                Text(check.tip).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func isWarn(_ o: DiagnosticCheck.Outcome) -> Bool { if case .warn = o { return true }; return false }

    private func color(_ o: DiagnosticCheck.Outcome) -> Color {
        switch o {
        case .pass: return Theme.success
        case .warn: return Theme.warning
        case .fail: return Theme.danger
        default: return Theme.textSecondary
        }
    }

    @ViewBuilder private func outcomeIcon(_ o: DiagnosticCheck.Outcome) -> some View {
        switch o {
        case .pending: Image(systemName: "circle").foregroundStyle(Theme.textSecondary)
        case .running: ProgressView().controlSize(.small)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.textSecondary)
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        let runner = DiagnosticRunner(checks: wired ? wiredChecks() : wirelessChecks())
        let stream = runner.events
        let watcher = Task { @MainActor in
            for await event in stream {
                switch event {
                case .updated(let r), .finished(let r): report = r
                }
            }
        }
        report = await runner.run()
        watcher.cancel()
    }

    // MARK: Probes

    private func wiredChecks() -> [DiagnosticCheck] {
        let browser = app.services.usbBrowser
        let log = app.services.ptpLog
        let shoot = app.shoot
        let shootIsLive = shoot?.isLive == true
        let liveIdentity = shootIsLive ? shoot?.identity : nil
        let liveBattery: Int? = shoot?.properties.first { $0.property == .batteryLevel }?.raw.intValue.map { Int($0) }
        let holder = TransportHolder()
        let probes = WiredDiagnostics.Probes(
            deviceOnBus: {
                browser.start()
                for await event in browser.events {
                    if case .devices(let list) = event { return list.first }
                }
                return nil
            },
            authorization: { await browser.requestAuthorizations() },
            openSession: {
                if shootIsLive { return .success(()) }
                guard let candidate = await Self.firstCandidate(browser), let device = browser.device(id: candidate.id) else {
                    return .failure(ConnectError.deviceGone)
                }
                let transport = ImageCaptureCoreTransport(device: device)
                do {
                    try await transport.open()
                    holder.transport = transport
                    return .success(())
                } catch { return .failure(error) }
            },
            deviceInfo: {
                if let identity = liveIdentity {
                    return .success(PTPDeviceInfo(manufacturer: identity.manufacturer, model: identity.model,
                                                  deviceVersion: identity.firmware, serialNumber: identity.serialNumber))
                }
                guard let transport = holder.transport else { return .failure(PTPError.notConnected) }
                let engine = PTPEngine(transport: transport, log: log)
                do {
                    let info = try await engine.getDeviceInfo()
                    await transport.close()
                    return .success(info)
                } catch {
                    await transport.close()
                    return .failure(error)
                }
            },
            battery: { liveBattery },
            powerSource: {
                await MainActor.run {
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    switch UIDevice.current.batteryState {
                    case .charging, .full: return "iPhone is being charged over the cable"
                    default: return nil
                    }
                }
            }
        )
        return WiredDiagnostics.checks(probes)
    }

    private static func firstCandidate(_ browser: USBCameraBrowser) async -> USBCameraCandidate? {
        for await event in browser.events {
            if case .devices(let list) = event { return list.first }
        }
        return nil
    }

    private func wirelessChecks() -> [DiagnosticCheck] {
        let ssid = app.services.ssid
        let p = UInt16(port) ?? PTPIPPacket.standardPort
        let probes = WirelessDiagnostics.Probes(
            ssid: { await ssid.currentSSID() },
            localAddresses: { CameraDiscoverer.localIPv4Addresses() },
            reachable: { host, port in await TCPProbe.reachable(host: host, port: port) },
            host: host.trimmingCharacters(in: .whitespaces),
            port: p
        )
        return WirelessDiagnostics.checks(probes)
    }
}

/// Lets the "open session" probe hand its transport to the "device info" probe.
final class TransportHolder: @unchecked Sendable {
    var transport: ImageCaptureCoreTransport?
}

struct ShareText: Identifiable {
    var id = UUID()
    var text: String
}
