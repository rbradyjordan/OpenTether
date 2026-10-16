import SwiftUI
import TetherCore

/// One flag control: Pick (flag) or Reject (×). 44 pt target, label plus
/// glyph change so state never relies on colour alone.
struct FlagButton: View {
    enum Kind { case pick, reject }

    var kind: Kind
    var flag: CaptureFlag
    var onFlag: (CaptureFlag) -> Void

    private var isOn: Bool { flag == target }
    private var target: CaptureFlag { kind == .pick ? .pick : .reject }

    var body: some View {
        Button {
            if kind == .pick { TetherHaptic.pick() } else { TetherHaptic.reject() }
            onFlag(isOn ? .none : target)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isOn ? tint : TetherColor.ink1)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: TetherHit.min, height: TetherHit.min)
                .background(isOn ? tint.opacity(0.16) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .pick ? "Pick" : "Reject")
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityHint(isOn ? "Double tap to clear" : "")
    }

    private var symbol: String {
        switch kind {
        case .pick: return isOn ? "flag.fill" : "flag"
        case .reject: return isOn ? "xmark.circle.fill" : "xmark.circle"
        }
    }

    private var tint: Color { kind == .pick ? TetherColor.ok : TetherColor.danger }
}

/// Pick and Reject side by side (used where the stars are not between them).
struct FlagButtons: View {
    var flag: CaptureFlag
    var onFlag: (CaptureFlag) -> Void

    var body: some View {
        HStack(spacing: TetherSpace.s) {
            FlagButton(kind: .reject, flag: flag, onFlag: onFlag)
            FlagButton(kind: .pick, flag: flag, onFlag: onFlag)
        }
    }
}

struct ColorLabelPicker: View {
    var current: TetherCoreColorLabel
    var onPick: (TetherCoreColorLabel) -> Void

    var body: some View {
        HStack(spacing: TetherSpace.s) {
            ForEach(TetherCoreColorLabel.allCases.filter { $0 != .none }) { label in
                Button { onPick(current == label ? .none : label) } label: {
                    Circle()
                        .fill(ColorLabelStyle.color(for: label))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black.opacity(0.75)).opacity(current == label ? 1 : 0)
                        )
                        .frame(width: TetherHit.min, height: TetherHit.min)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label.rawValue.capitalized) label")
                .accessibilityAddTraits(current == label ? .isSelected : [])
            }
        }
    }
}
