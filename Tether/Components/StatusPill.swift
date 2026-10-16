import SwiftUI

/// One line: dot (ok/warn/danger) · camera model · transport glyph · battery · "3 ↓".
/// Tapping expands into the diagnostics sheet when `onTap` is set.
struct StatusPill: View {
    enum Tone { case neutral, ok, warn, danger }

    var tone: Tone = .neutral
    var title: String
    var transportSymbol: String?
    var battery: String?
    var downloads: Int = 0
    var detail: String?
    var onTap: (() -> Void)?

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { label }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens diagnostics")
            } else {
                label
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(onTap == nil ? AccessibilityTraits() : AccessibilityTraits.isButton)
    }

    private var label: some View {
        HStack(spacing: TetherSpace.s) {
            Circle().fill(toneColor).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            Text(title).font(TetherFont.hud).foregroundStyle(TetherColor.ink0).lineLimit(1)
            if let transportSymbol {
                Image(systemName: transportSymbol).font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
            }
            if let battery {
                HStack(spacing: 2) {
                    Image(systemName: "battery.75percent").imageScale(.small)
                    Text(battery).contentTransition(.numericText())
                }
                .font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
            }
            if downloads > 0 {
                Text("\(downloads) ↓")
                    .font(TetherFont.hud)
                    .foregroundStyle(TetherColor.accent)
                    .contentTransition(.numericText())
            }
            if let detail {
                Text(detail).font(TetherFont.hud).foregroundStyle(toneColor).lineLimit(1)
            }
        }
        .padding(.horizontal, TetherSpace.m)
        .frame(minHeight: 32)
        .background(TetherColor.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(TetherColor.hairline, lineWidth: 0.5))
        .frame(minHeight: TetherHit.min)
        .contentShape(Rectangle())
        .tetherAnimation(TetherMotion.snap, value: downloads)
    }

    private var toneColor: Color {
        switch tone {
        case .neutral: return TetherColor.ink2
        case .ok: return TetherColor.ok
        case .warn: return TetherColor.warn
        case .danger: return TetherColor.danger
        }
    }

    private var toneWord: String {
        switch tone {
        case .neutral: return ""
        case .ok: return "ready"
        case .warn: return "attention"
        case .danger: return "disconnected"
        }
    }

    private var accessibilityText: String {
        var parts: [String] = [title]
        if !toneWord.isEmpty { parts.append(toneWord) }
        if let detail { parts.append(detail) }
        if let battery { parts.append("battery \(battery)") }
        if downloads > 0 { parts.append("\(downloads) downloading") }
        return parts.joined(separator: ", ")
    }
}

/// Small tone-only pill for secondary states ("LIVE", "Reconnecting", counts).
struct TonePill: View {
    var text: String
    var tone: StatusPill.Tone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: TetherSpace.xs) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).font(TetherFont.hud).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, TetherSpace.s + 2)
        .padding(.vertical, TetherSpace.xs)
        .background(background, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return TetherColor.ink1
        case .ok: return TetherColor.ok
        case .warn: return TetherColor.warn
        case .danger: return .white
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return TetherColor.surface3
        case .ok: return TetherColor.ok.opacity(0.18)
        case .warn: return TetherColor.warn.opacity(0.18)
        case .danger: return TetherColor.danger
        }
    }
}
