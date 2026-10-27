import Photos
import SwiftUI
import TetherCore

// MARK: - Welcome

struct WelcomeStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var float = false
    @State private var shown = false

    private let features: [(String, String, String)] = [
        ("cable.connector", "USB-C or Wi-Fi", "Control the camera: shutter, live view, exposure. Or let it push frames over FTP."),
        ("square.stack.3d.down.right", "Every frame, instantly", "Frames land as you shoot, ready to rate, flag, tag and compare."),
        ("paintpalette", "Looks and client review", "Apply a look to everything, then hand the phone to the client."),
        ("square.and.arrow.up", "Export your way", "Photos, a Files folder, a Capture One or Lightroom hot folder, or your FTP server."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: TetherSpace.xl) {
                Image("BrandIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 148, height: 148)
                    .shadow(color: TetherColor.accent.opacity(0.45), radius: 36, y: 12)
                    .offset(y: float ? -5 : 5)
                    .accessibilityHidden(true)
                VStack(spacing: TetherSpace.s) {
                    Text("Shoot tethered.\nReview live.")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(TetherColor.ink0)
                    Text("Open Tether connects your camera to this phone so every frame lands the moment you take it.")
                        .font(TetherFont.body).foregroundStyle(TetherColor.ink1)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: TetherSpace.s) {
                    ForEach(Array(features.enumerated()), id: \.offset) { i, f in
                        HStack(alignment: .top, spacing: TetherSpace.m) {
                            IconTile(systemImage: f.0, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.1).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                                Text(f.2).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(TetherSpace.m)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: TetherRadius.control, style: .continuous))
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || reduceMotion ? 0 : 14)
                        .animation(reduceMotion ? .none : TetherMotion.arrive.delay(0.08 * Double(i) + 0.15), value: shown)
                        .accessibilityElement(children: .combine)
                    }
                }
                Label("Free, local, private: no account, no servers, no tracking.", systemImage: "lock.shield")
                    .font(TetherFont.caption).foregroundStyle(TetherColor.ink2)
            }
            .frame(maxWidth: TetherLayout.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TetherSpace.xl)
            .padding(.top, TetherSpace.l)
            .padding(.bottom, TetherSpace.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            shown = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { float = true }
        }
    }
}

// MARK: - Camera

struct CameraStep: View {
    @Bindable var model: OnboardingModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: TetherSpace.s)]

    var body: some View {
        OnboardingPageScaffold(eyebrow: "Your camera", title: "What are you shooting with?",
                               subtitle: "Setup steps, menu names and pairing differ by brand and body. Pick yours and Open Tether tailors the rest.") {
            LazyVGrid(columns: columns, spacing: TetherSpace.s) {
                ForEach(OnboardingBody.brands, id: \.self) { vendor in
                    BrandTile(vendor: vendor, selected: model.brand == vendor) {
                        withAnimation(TetherMotion.snap) { model.pickBrand(vendor) }
                    }
                }
            }
            if model.brand == .canon {
                VStack(alignment: .leading, spacing: TetherSpace.s) {
                    Text("Which EOS?").font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                    Text("Canon moved its network menus between generations.")
                        .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                    VStack(spacing: TetherSpace.xs) {
                        ForEach(OnboardingBody.canon) { b in
                            ModelRow(item: b, selected: model.body == b) {
                                withAnimation(TetherMotion.snap) { model.pickBody(b) }
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Button {
                withAnimation(TetherMotion.snap) { model.pickNoCamera() }
            } label: {
                HStack {
                    Image(systemName: model.noCameraYet ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.noCameraYet ? TetherColor.accent : TetherColor.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No camera with me right now").font(TetherFont.callout.weight(.semibold)).foregroundStyle(TetherColor.ink0)
                        Text("Skip ahead and try the demo session at the end.").font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
                    }
                    Spacer()
                }
                .padding(TetherSpace.m)
                .frame(minHeight: TetherHit.min)
                .hairlineBorder()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BrandTile: View {
    var vendor: CameraVendor
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                HStack {
                    Image(systemName: vendor.onboardingSymbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? TetherColor.accent : TetherColor.ink1)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(TetherColor.accent) }
                }
                Text(vendor == .generic ? "Something else" : vendor.displayName)
                    .font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Text(capabilityLine).font(TetherFont.caption).foregroundStyle(TetherColor.ink2).lineLimit(1)
            }
            .padding(TetherSpace.m)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(selected ? TetherColor.accentSoft : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: TetherRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TetherRadius.control, style: .continuous)
                .stroke(selected ? TetherColor.accent.opacity(0.7) : TetherColor.hairline, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var capabilityLine: String {
        let c = vendor.onboardingConnections
        var parts: [String] = []
        if c.contains(.usb) { parts.append("USB") }
        if c.contains(.cameraNetwork) { parts.append("Wi-Fi") }
        if c.contains(.ftp) { parts.append("FTP") }
        return parts.joined(separator: " · ")
    }
}

private struct ModelRow: View {
    var item: OnboardingBody
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(item.name).font(TetherFont.callout.weight(selected ? .semibold : .regular)).foregroundStyle(TetherColor.ink0)
                if let note = item.note {
                    Text(note).font(TetherFont.caption).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(TetherColor.ok.opacity(0.18), in: Capsule()).foregroundStyle(TetherColor.ok)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? TetherColor.accent : TetherColor.ink2)
            }
            .padding(.horizontal, TetherSpace.m)
            .frame(minHeight: TetherHit.min)
            .background(selected ? TetherColor.accentSoft : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
