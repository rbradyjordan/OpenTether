import SwiftUI
import TetherCore

/// Disconnect is a dim and a sheet, never an alert: a danger pill, the
/// reconnect strategy in one sentence, one button, and always a way out.
struct ReconnectView: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let strategy = model.reconnectStrategy
        VStack(alignment: .leading, spacing: TetherSpace.l) {
            HStack {
                TonePill(text: "Connection lost", tone: .danger, systemImage: "bolt.slash.fill")
                Spacer()
                if model.isReconnecting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Reconnecting")
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TetherColor.ink1)
                        .frame(width: TetherHit.min, height: TetherHit.min)
                        .tetherGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Close")
            }
            Text(strategy.title)
                .font(TetherFont.title)
                .foregroundStyle(TetherColor.ink0)
            Text(sentence(strategy))
                .font(TetherFont.callout)
                .foregroundStyle(TetherColor.ink1)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.reconnectError {
                Text(error)
                    .font(TetherFont.hud)
                    .foregroundStyle(TetherColor.danger)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            button(strategy)
            HStack {
                Button("Not now") { dismiss() }
                Spacer()
                Button("End session", role: .destructive) {
                    dismiss()
                    Task { await app.endShoot() }
                }
                .foregroundStyle(TetherColor.danger)
            }
            .font(TetherFont.callout.weight(.medium))
            .foregroundStyle(TetherColor.ink1)
            .frame(minHeight: TetherHit.min)
        }
        .padding(TetherSpace.xl)
        .tetherScreen()
        .forceDark()
        .presentationDetents([.fraction(0.5)])
        .presentationDragIndicator(.visible)
        // Swiping away never cancels: reconnecting carries on and the red
        // status pill brings this back.
        .onDisappear { model.snoozeReconnect() }
        .onAppear { if case .waitForUSBDevice = strategy { model.reconnect() } }
    }

    /// One sentence that says what to do next.
    private func sentence(_ strategy: ReconnectStrategy) -> String {
        let detail = strategy.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = detail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first {
            return String(first).trimmingCharacters(in: .whitespaces) + "."
        }
        return detail
    }

    @ViewBuilder private func button(_ strategy: ReconnectStrategy) -> some View {
        switch strategy {
        case .nothingToDo:
            primary("Continue") { dismiss() }
        case .startFresh:
            primary("Go to Connect") {
                dismiss()
                Task { await app.endShoot(); app.selectedTab = .shoot }
            }
        default:
            primary(model.isReconnecting ? "Reconnecting…" : "Reconnect now") { model.reconnect() }
                .disabled(model.isReconnecting)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TetherFont.headline)
                .frame(maxWidth: .infinity, minHeight: TetherHit.min + 8)
        }
        .buttonStyle(.tetherPrimary)
        .tint(TetherColor.accent)
        .contentTransition(.numericText())
    }
}
