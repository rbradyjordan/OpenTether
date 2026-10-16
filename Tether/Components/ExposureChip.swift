import SwiftUI
import TetherCore

/// Normalises the camera's display strings into the chip numerals the design
/// shows: `1/250`, `ƒ/2.8`, `ISO 400`, `+0.3`. Pure so it can be unit-tested.
enum ExposureFormatting {
    static func value(for property: TetherProperty, display: String?) -> String {
        guard let raw = display?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "—" }
        switch property {
        case .aperture:
            return aperture(raw)
        case .iso:
            return iso(raw)
        case .exposureCompensation:
            return compensation(raw)
        default:
            return raw
        }
    }

    static func aperture(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("ƒ/") { return "ƒ/" + String(raw.dropFirst(2)) }
        if lower.hasPrefix("f/") { return "ƒ/" + String(raw.dropFirst(2)) }
        if lower.hasPrefix("f") && raw.dropFirst().first?.isNumber == true { return "ƒ/" + String(raw.dropFirst()) }
        if raw.first?.isNumber == true { return "ƒ/" + raw }
        return raw
    }

    static func iso(_ raw: String) -> String {
        if raw.uppercased().hasPrefix("ISO") { return "ISO " + raw.dropFirst(3).trimmingCharacters(in: .whitespaces) }
        if raw.first?.isNumber == true { return "ISO " + raw }
        return raw
    }

    static func compensation(_ raw: String) -> String {
        if raw.hasPrefix("+") || raw.hasPrefix("-") || raw.hasPrefix("−") { return raw }
        if let v = Double(raw) {
            if v == 0 { return "0" }
            return v > 0 ? "+" + raw : raw
        }
        return raw
    }

    /// Short caption above the numeral.
    static func caption(for property: TetherProperty) -> String {
        switch property {
        case .shutterSpeed: return "Shutter"
        case .aperture: return "Aperture"
        case .iso: return "ISO"
        case .exposureCompensation: return "Comp"
        case .whiteBalance: return "WB"
        default: return property.displayName
        }
    }
}

/// Caption label above a big mono numeral; accent underline when selected;
/// the numeral rolls with `.numericText()` when the camera reports a change.
struct ExposureChip: View {
    var property: TetherProperty
    var value: String
    var selected: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: TetherSpace.xs) {
                Text(ExposureFormatting.caption(for: property))
                    .tetherCaption()
                    .foregroundStyle(TetherColor.ink2)
                Text(value)
                    .font(TetherFont.exposure)
                    .foregroundStyle(enabled ? TetherColor.ink0 : TetherColor.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Rectangle()
                    .fill(selected ? TetherColor.accent : .clear)
                    .frame(height: 2)
                    .frame(maxWidth: 28)
            }
            .padding(.horizontal, TetherSpace.m)
            .padding(.top, TetherSpace.s)
            .padding(.bottom, TetherSpace.xs)
            .frame(minWidth: 72, minHeight: TetherHit.min + 12)
            .tetherChip(selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .tetherAnimation(TetherMotion.snap, value: value)
        .tetherAnimation(TetherMotion.snap, value: selected)
        .accessibilityLabel(property.displayName)
        .accessibilityValue(value)
        .accessibilityHint(enabled ? "Double tap to change" : "Read only on this camera")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
