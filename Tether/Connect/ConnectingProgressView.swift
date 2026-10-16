import SwiftUI
import TetherCore

struct ConnectingProgressView: View {
    var progress: ConnectProgress
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(progress.steps, id: \.rawValue) { step in
                HStack(spacing: 10) {
                    icon(for: progress.state(of: step))
                    Text(step.title(for: progress.transport)).font(.subheadline)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
            if let failure = progress.failure {
                Text(failure).font(.footnote).foregroundStyle(Theme.danger).padding(.top, 4)
            }
            HStack {
                Spacer()
                Button(progress.failure == nil ? "Cancel" : "Close", action: onCancel).buttonStyle(.bordered)
            }
        }
        .padding(16)
        .cardBackground()
    }

    @ViewBuilder private func icon(for state: ConnectProgress.StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(Theme.textSecondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        }
    }
}
