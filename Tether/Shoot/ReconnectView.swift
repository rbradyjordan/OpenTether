import SwiftUI
import TetherCore

struct ReconnectView: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let strategy = model.reconnectStrategy
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: icon(strategy)).font(.system(size: 44)).foregroundStyle(Theme.accent).padding(.top, 20)
                Text(strategy.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(strategy.detail).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                if model.isReconnecting { ProgressView().padding(.top, 4) }
                if let error = model.reconnectError { Text(error).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
                Spacer()
                buttons(strategy)
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("Connection lost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { model.cancelReconnect(); dismiss() } } }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(model.isReconnecting)
        .onAppear { if case .waitForUSBDevice = strategy { model.reconnect() } }
    }

    @ViewBuilder private func buttons(_ strategy: ReconnectStrategy) -> some View {
        switch strategy {
        case .nothingToDo:
            Button("Continue") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
        case .startFresh:
            Button("Go to Connect") {
                dismiss()
                Task { await app.endShoot(); app.selectedTab = .shoot }
            }.buttonStyle(.borderedProminent).controlSize(.large)
        default:
            Button(model.isReconnecting ? "Reconnecting…" : "Reconnect now") { model.reconnect() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isReconnecting)
            Button("End session", role: .destructive) {
                dismiss()
                Task { await app.endShoot() }
            }
        }
    }

    private func icon(_ s: ReconnectStrategy) -> String {
        switch s {
        case .waitForUSBDevice: return "cable.connector"
        case .retryHost, .retryRicoh: return "wifi.exclamationmark"
        case .nothingToDo: return "antenna.radiowaves.left.and.right"
        case .startFresh: return "questionmark.circle"
        }
    }
}
