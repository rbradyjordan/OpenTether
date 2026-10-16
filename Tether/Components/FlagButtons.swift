import SwiftUI
import TetherCore

struct FlagButtons: View {
    var flag: CaptureFlag
    var onFlag: (CaptureFlag) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { onFlag(.pick) } label: {
                Label("Pick", systemImage: flag == .pick ? "flag.fill" : "flag")
                    .foregroundStyle(flag == .pick ? Theme.success : Theme.textSecondary)
            }
            .accessibilityLabel(flag == .pick ? "Picked, tap to clear" : "Pick")
            Button { onFlag(.reject) } label: {
                Label("Reject", systemImage: flag == .reject ? "xmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(flag == .reject ? Theme.danger : Theme.textSecondary)
            }
            .accessibilityLabel(flag == .reject ? "Rejected, tap to clear" : "Reject")
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.plain)
    }
}

struct ColorLabelPicker: View {
    var current: TetherCoreColorLabel
    var onPick: (TetherCoreColorLabel) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TetherCoreColorLabel.allCases.filter { $0 != .none }) { label in
                Button { onPick(label) } label: {
                    Circle()
                        .fill(ColorLabelStyle.color(for: label))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(.white, lineWidth: current == label ? 3 : 0))
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label.rawValue.capitalized) label")
                .accessibilityAddTraits(current == label ? .isSelected : [])
            }
        }
    }
}
