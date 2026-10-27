import SwiftUI
import TetherCore

/// First run: welcome → camera → connection → tailored setup (Canon
/// pairing explained) → permissions → workflow → tour → ready. Each step is
/// a full screen with a glow in its own colour, a stepped progress bar on
/// top and one primary action at the bottom.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = OnboardingModel()
    @State private var loaded = false

    var body: some View {
        ZStack {
            OnboardingBackdrop(color: glow(for: model.step))
            VStack(spacing: 0) {
                topBar
                ZStack {
                    stepView(model.step)
                        .id(model.step)
                        .transition(transition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
        }
        .forceDark()
        .task {
            guard !loaded else { return }
            loaded = true
            model.load(app: app)
            #if DEBUG
            model.applyDebugLaunchArguments()
            #endif
            await model.refreshPermissions(app: app)
        }
        // Coming back from Settings (Wi-Fi, privacy) refreshes the live status.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshPermissions(app: app) } }
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: TetherSpace.m) {
            Button { withAnimation(animation) { model.back() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: TetherHit.min, height: TetherHit.min)
            }
            .opacity(model.isFirst ? 0 : 1)
            .disabled(model.isFirst)
            .accessibilityLabel("Back")

            StepProgress(steps: model.steps, current: model.index)

            Button("Skip") { model.finish(app: app) }
                .font(TetherFont.callout.weight(.medium))
                .foregroundStyle(TetherColor.ink1)
                .frame(minWidth: TetherHit.min, minHeight: TetherHit.min)
                .opacity(model.isLast ? 0 : 1)
                .disabled(model.isLast)
                .accessibilityHint("Finishes setup with the defaults. Replay it any time from Settings.")
        }
        .foregroundStyle(TetherColor.ink0)
        .padding(.horizontal, TetherSpace.m)
        .padding(.top, TetherSpace.xs)
    }

    @ViewBuilder private var footer: some View {
        if !model.isLast {
            VStack(spacing: TetherSpace.s) {
                Button {
                    withAnimation(animation) { model.next() }
                } label: {
                    Text(primaryTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.tetherPrimary)
                .controlSize(.large)
                .disabled(!model.canContinue)
                if let hint = footerHint {
                    Text(hint).font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: TetherLayout.readableWidth)
            .padding(.horizontal, TetherSpace.xl)
            .padding(.top, TetherSpace.m)
            .padding(.bottom, TetherSpace.l)
            .background(alignment: .top) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 40).offset(y: -40).allowsHitTesting(false)
            }
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "Set up my camera"
        case .camera: return model.noCameraYet ? "Continue without a camera" : "Continue"
        case .setup: return "I've done this"
        case .permissions: return "Continue"
        case .tour: return "Finish"
        default: return "Continue"
        }
    }

    private var footerHint: String? {
        switch model.step {
        case .welcome: return "About two minutes. Everything can be changed later in Settings."
        case .camera where model.brand == .canon && model.body == nil: return "Pick your EOS model: Canon menus differ by generation."
        case .setup: return "You can do this later: the steps stay in Connect → Camera setup guides."
        case .permissions: return "Each one is optional. Open Tether asks again when a feature needs it."
        default: return nil
        }
    }

    // MARK: Steps

    @ViewBuilder private func stepView(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .welcome: WelcomeStep()
        case .camera: CameraStep(model: model)
        case .connection: ConnectionStep(model: model)
        case .setup: SetupGuideStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .workflow: WorkflowStep(model: model)
        case .tour: TourStep()
        case .ready: ReadyStep(model: model)
        }
    }

    private var animation: Animation { Motion.spring(TetherMotion.settle, reduce: reduceMotion) }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let forward = model.direction >= 0
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func glow(for step: OnboardingModel.Step) -> Color {
        switch step {
        case .welcome: return Color(hex: 0x4A9DFF)
        case .camera: return Color(hex: 0x5B8CFF)
        case .connection: return Color(hex: 0x37C6C0)
        case .setup: return Color(hex: 0x3DD68C)
        case .permissions: return Color(hex: 0x7B6CFF)
        case .workflow: return Color(hex: 0xF2B63D)
        case .tour: return Color(hex: 0xFF8A5C)
        case .ready: return Color(hex: 0x4A9DFF)
        }
    }
}

// MARK: - Shared pieces

/// Black with one soft glow near the top, cross-fading between steps.
struct OnboardingBackdrop: View {
    var color: Color

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [color.opacity(0.34), color.opacity(0.07), .clear],
                           center: UnitPoint(x: 0.5, y: 0.08), startRadius: 0, endRadius: 520)
                .animation(.easeInOut(duration: 0.6), value: color)
        }
        .ignoresSafeArea()
    }
}

/// One segment per step; done segments fill, the current one is accent.
private struct StepProgress: View {
    var steps: [OnboardingModel.Step]
    var current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element) { i, _ in
                Capsule()
                    .fill(i < current ? TetherColor.accent.opacity(0.55) : (i == current ? TetherColor.accent : Color.white.opacity(0.14)))
                    .frame(height: 4)
            }
        }
        .frame(maxWidth: 360)
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps.count): \(steps[min(current, steps.count - 1)].title)")
    }
}

/// Scrolling page with the standard title block and readable width.
struct OnboardingPageScaffold<Content: View>: View {
    var eyebrow: String
    var title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: TetherSpace.l) {
                VStack(alignment: .leading, spacing: TetherSpace.s) {
                    Text(eyebrow.uppercased())
                        .font(TetherFont.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(TetherColor.accent)
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(TetherColor.ink0)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle).font(TetherFont.body).foregroundStyle(TetherColor.ink1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                content()
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: TetherLayout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TetherSpace.xl)
            .padding(.top, TetherSpace.xl)
            .padding(.bottom, TetherSpace.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        #if DEBUG
        // Simulator screenshots of long pages: `-OTOnboardingScroll 0.5` (fraction) or `1` (bottom).
        .task {
            let f = UserDefaults.standard.double(forKey: "OTOnboardingScroll")
            guard f > 0 else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            proxy.scrollTo("bottom", anchor: UnitPoint(x: 0, y: 1 / max(f, 0.01)))
        }
        #endif
        }
    }
}

/// A selectable card: icon, title, detail, check when selected.
struct ChoiceCard: View {
    var title: String
    var detail: String?
    var symbol: String
    var selected: Bool
    var badge: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: TetherSpace.m) {
                IconTile(systemImage: symbol, active: selected, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: TetherSpace.s) {
                        Text(title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                        if let badge {
                            Text(badge).font(TetherFont.caption).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(TetherColor.accentSoft, in: Capsule()).foregroundStyle(TetherColor.accent)
                        }
                    }
                    if let detail {
                        Text(detail).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? TetherColor.accent : TetherColor.ink2)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(TetherSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? TetherColor.accentSoft : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous)
                .stroke(selected ? TetherColor.accent.opacity(0.7) : TetherColor.hairline, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: TetherRadius.card, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .animation(TetherMotion.snap, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
