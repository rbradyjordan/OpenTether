import SwiftUI
import TetherCore

/// The tailored guide: for Canon Wi-Fi a four-stage pairing explainer, then
/// numbered steps (each tagged camera / phone / Open Tether, with what the
/// camera's screen shows), a checklist and troubleshooting.
struct SetupGuideStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: OnboardingModel

    private var guide: SetupGuide {
        SetupGuide.make(body: model.body, connection: model.connection ?? .usb,
                        ftpHost: app.ftpReceiver.primaryAddress ?? "the phone's address",
                        ftpPort: app.settings.ftpPort, ftpUser: app.settings.ftpUsername)
    }

    var body: some View {
        let guide = guide
        OnboardingPageScaffold(eyebrow: "\(model.body?.name ?? "Camera") · \(model.connection?.title ?? "")",
                               title: model.connection?.isWireless == true && model.body?.vendor == .canon ? "Pair once, connect forever" : "Get the camera ready",
                               subtitle: guide.intro) {
            if guide.showsCanonPairing {
                CanonPairingTimeline(sameNetwork: model.connection == .sameNetwork)
            }
            VStack(spacing: TetherSpace.s) {
                ForEach(Array(guide.steps.enumerated()), id: \.element.id) { i, step in
                    GuideStepCard(number: i + 1, step: step, done: model.checked.contains(step.id)) {
                        withAnimation(TetherMotion.snap) { model.toggle(step) }
                    }
                }
            }
            progress(done: guide.steps.filter { model.checked.contains($0.id) }.count, of: guide.steps.count)
            if !guide.troubleshooting.isEmpty {
                VStack(alignment: .leading, spacing: TetherSpace.s) {
                    Text("If something doesn't work").font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                    VStack(spacing: 0) {
                        ForEach(guide.troubleshooting) { t in TroubleshootRow(item: t) }
                    }
                    .tetherCard()
                }
            }
        }
    }

    private func progress(done: Int, of total: Int) -> some View {
        HStack(spacing: TetherSpace.s) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(done == total ? TetherColor.ok : TetherColor.accent)
            Text(done == total ? "All done" : "\(done) of \(total)")
                .font(TetherFont.caption).foregroundStyle(done == total ? TetherColor.ok : TetherColor.ink2)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step card

private struct GuideStepCard: View {
    var number: Int
    var step: SetupStep
    var done: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.m) {
            HStack(alignment: .top, spacing: TetherSpace.m) {
                Button(action: toggle) {
                    ZStack {
                        Circle().fill(done ? TetherColor.ok : Color.white.opacity(0.08)).frame(width: 32, height: 32)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        } else {
                            Text("\(number)").font(.system(.callout, design: .rounded, weight: .bold)).foregroundStyle(TetherColor.ink0)
                        }
                    }
                    .frame(width: TetherHit.min, height: TetherHit.min)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Step \(number), done" : "Mark step \(number) done")
                VStack(alignment: .leading, spacing: 4) {
                    Label(step.where_.rawValue, systemImage: placeSymbol)
                        .font(TetherFont.caption.weight(.semibold))
                        .foregroundStyle(placeColor)
                    Text(step.text).font(TetherFont.headline)
                        .foregroundStyle(done ? TetherColor.ink1 : TetherColor.ink0)
                        .strikethrough(done, color: TetherColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = step.detail, !done {
                        Text(detail).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if let screen = step.cameraScreen, !screen.isEmpty, !done {
                CameraLCD(lines: screen)
                    .padding(.leading, 56)
                    .transition(.opacity)
            }
        }
        .padding(TetherSpace.m)
        .tetherCard()
        .opacity(done ? 0.75 : 1)
    }

    private var placeSymbol: String {
        switch step.where_ {
        case .camera: return "camera"
        case .phone: return "iphone"
        case .app: return "app.badge.checkmark"
        }
    }

    private var placeColor: Color {
        switch step.where_ {
        case .camera: return Color(hex: 0xF2B63D)
        case .phone: return Color(hex: 0x37C6C0)
        case .app: return TetherColor.accent
        }
    }
}

/// The camera's rear screen, drawn: dark panel, menu-path breadcrumbs (or
/// a dialog's lines) with the last item highlighted like the camera's cursor.
struct CameraLCD: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: 0xC0392B)).frame(width: 6, height: 6)
                Text("CAMERA SCREEN").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Color.white.opacity(0.45))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    let last = i == lines.count - 1
                    HStack(spacing: 6) {
                        if lines.count > 2, isPath {
                            Image(systemName: last ? "arrowtriangle.right.fill" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(last ? Color(hex: 0xE8533F) : Color.white.opacity(0.35))
                        }
                        Text(line)
                            .font(.system(size: 13, weight: last ? .semibold : .regular, design: .default))
                            .foregroundStyle(last ? Color.white : Color.white.opacity(0.78))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(last && isPath ? Color(hex: 0xE8533F).opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 10)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color(hex: 0x111214), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(4)
        .background(Color(hex: 0x26282C), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera screen: " + lines.joined(separator: ", "))
    }

    /// Menu paths start at MENU or a top-level menu; dialogs are sentences.
    private var isPath: Bool { lines.first == "MENU" || lines.count > 3 && !lines.contains { $0.hasSuffix(".") } }
}

// MARK: - Canon pairing explainer

/// Camera network → phone joins → Open Tether finds it → OK on the camera,
/// one row each, with a pulse moving down the line.
struct CanonPairingTimeline: View {
    var sameNetwork: Bool
    @State private var active = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stages: [(String, String, String)] {
        [
            (sameNetwork ? "wifi.router" : "antenna.radiowaves.left.and.right",
             sameNetwork ? "Camera joins your router" : "Camera makes a network",
             sameNetwork ? "Set up once in the camera's network menu." : "EOS…_Canon0A, with its own password."),
            ("iphone", sameNetwork ? "Phone on the same Wi-Fi" : "Phone joins it", sameNetwork ? "Same network name as the camera." : "iOS says \"No Internet\". That's fine."),
            ("magnifyingglass", "Open Tether finds the camera", "The camera says \"Start EOS Utility\". Open Tether answers."),
            ("checkmark.seal", "Press OK on the camera", "Within 60 s. Only the first time."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: TetherSpace.m) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(i <= active ? TetherColor.accent : Color.white.opacity(0.08)).frame(width: 36, height: 36)
                            Image(systemName: s.0).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(i <= active ? .white : TetherColor.ink1)
                        }
                        if i < stages.count - 1 {
                            Rectangle().fill(i < active ? TetherColor.accent : Color.white.opacity(0.1))
                                .frame(width: 2, height: 30)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.1).font(TetherFont.callout.weight(.semibold)).foregroundStyle(TetherColor.ink0)
                        Text(s.2).font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
                    }
                    .padding(.top, 7)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(TetherSpace.l)
        .background(TetherColor.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous).stroke(TetherColor.accent.opacity(0.3), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pairing has four stages: " + stages.map { $0.1 }.joined(separator: ", then "))
        .task {
            guard !reduceMotion else { active = stages.count - 1; return }
            while !Task.isCancelled {
                for i in 0 ..< stages.count {
                    withAnimation(.easeInOut(duration: 0.35)) { active = i }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

// MARK: - Troubleshooting

private struct TroubleshootRow: View {
    var item: Troubleshoot
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.s) {
            Button { withAnimation(TetherMotion.snap) { open.toggle() } } label: {
                HStack {
                    Text(item.problem).font(TetherFont.callout.weight(.medium)).foregroundStyle(TetherColor.ink0)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(TetherColor.ink2)
                }
                .frame(minHeight: TetherHit.min)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the fix" : "Shows the fix")
            if open {
                Text(item.fix).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, TetherSpace.m)
                    .transition(.opacity)
            }
            Divider().overlay(TetherColor.hairline)
        }
        .padding(.horizontal, TetherSpace.l)
    }
}
