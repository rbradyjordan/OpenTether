import SwiftUI
import TetherCore

/// Step list for a connect attempt. Checks bounce in as steps complete; a
/// failure is one sentence and one button. Dark tokens regardless of the screen.
struct ConnectingProgressView: View {
    var progress: ConnectProgress
    var onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.m) {
            HStack {
                Text(progress.failure == nil ? "Connecting" : "Could not connect")
                    .font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                Spacer()
                if progress.failure == nil { ProgressView().controlSize(.small).tint(TetherColor.ink1) }
            }
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                ForEach(progress.steps, id: \.rawValue) { step in
                    StepRow(title: step.title(for: progress.transport), state: progress.state(of: step))
                }
            }
            if let failure = progress.failure {
                Text(ConnectFailureCopy.sentence(failure))
                    .font(TetherFont.callout)
                    .foregroundStyle(TetherColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Button(progress.failure == nil ? "Cancel" : "Try again", action: onCancel)
                .buttonStyle(.bordered)
                .tint(progress.failure == nil ? TetherColor.ink1 : TetherColor.accent)
                .frame(maxWidth: .infinity, minHeight: TetherHit.min)
        }
        .padding(TetherSpace.l)
        .tetherCard()
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: progress)
        .darkSurface()
    }
}

private struct StepRow: View {
    var title: String
    var state: ConnectProgress.StepState

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            icon.frame(width: 22, height: 22)
            Text(title)
                .font(TetherFont.callout)
                .foregroundStyle(state == .pending ? TetherColor.ink2 : TetherColor.ink0)
            Spacer()
            Text(word).tetherCaption().foregroundStyle(TetherColor.ink2)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(word)")
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending:
            Circle().strokeBorder(TetherColor.hairline, lineWidth: 1.5)
        case .running:
            ProgressView().controlSize(.small).tint(TetherColor.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(TetherColor.ok)
                .symbolEffect(.bounce, value: state == .done)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(TetherColor.danger)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private var word: String {
        switch state {
        case .pending: return "waiting"
        case .running: return "now"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// Errors arrive as thrown descriptions; the card shows the first sentence only.
enum ConnectFailureCopy {
    static func sentence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The camera did not answer." }
        if let first = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first {
            let s = String(first).trimmingCharacters(in: .whitespaces)
            return s.hasSuffix(".") ? s : s + "."
        }
        return trimmed
    }
}
