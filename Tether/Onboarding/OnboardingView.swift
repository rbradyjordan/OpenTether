import Photos
import SwiftUI
import TetherCore

/// Three full-bleed pages, paged, with a progress indicator; one line each.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var localNetworkAsked = false
    @State private var photosStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @State private var ssidState: SSIDAuthorization = .notDetermined

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $page) {
                ForEach(OnboardingContent.pages) { p in
                    OnboardingPageView(page: p) {
                        if p.asksPermissions { permissionButtons }
                    }
                    .tag(p.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            footer
        }
        .background(TetherColor.surface0)
        .forceDark()
        .task { ssidState = await app.services.ssid.authorizationState }
    }

    private var footer: some View {
        VStack(spacing: TetherSpace.l) {
            PageProgress(count: OnboardingContent.pages.count, current: page)
            Button {
                if OnboardingContent.isLast(page) { finish() } else {
                    withAnimation(Motion.spring(TetherMotion.settle, reduce: reduceMotion)) { page += 1 }
                }
            } label: {
                Text(OnboardingContent.isLast(page) ? "Start shooting" : "Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.tetherPrimary)
            .controlSize(.large)
            .contentTransition(.numericText())
        }
        .frame(maxWidth: TetherLayout.readableWidth)
        .padding(.horizontal, TetherSpace.xl)
        .padding(.bottom, TetherSpace.xl)
    }

    private var permissionButtons: some View {
        VStack(spacing: TetherSpace.s) {
            PermissionRow(title: "Local network", symbol: "network", done: localNetworkAsked) {
                // Starting discovery triggers the system prompt; stop again right away.
                Task {
                    try? await app.discovery.start()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await app.discovery.stop()
                    localNetworkAsked = true
                }
            }
            PermissionRow(title: "Save to Photos", symbol: "photo.on.rectangle", done: photosStatus == .authorized || photosStatus == .limited) {
                Task { photosStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            }
            // The Mac never shares the Wi-Fi name with apps, so there is nothing to ask.
            if ssidState != .unavailable {
                PermissionRow(title: "Wi-Fi name", symbol: "wifi", done: ssidState == .authorized) {
                    Task {
                        await app.services.ssid.requestAuthorization()
                        ssidState = await app.services.ssid.authorizationState
                    }
                }
            }
        }
    }

    private func finish() {
        app.settings.hasOnboarded = true
    }
}

/// Graphite page with a coloured glow, a hero up top (the app icon, gently
/// floating, or a symbol medallion) and the title and line below it.
private struct OnboardingPageView<Extra: View>: View {
    var page: OnboardingPage
    @ViewBuilder var extra: () -> Extra
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [page.glow.opacity(0.38), page.glow.opacity(0.08), .clear],
                           center: UnitPoint(x: 0.5, y: 0.18), startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: TetherSpace.l) {
                    hero
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, TetherSpace.l)
                    Text(page.title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(TetherColor.ink0)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.line).font(TetherFont.body).foregroundStyle(TetherColor.ink1)
                        .fixedSize(horizontal: false, vertical: true)
                    extra()
                }
                .frame(maxWidth: TetherLayout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, TetherSpace.xl)
                .padding(.top, 72)
                .padding(.bottom, 160)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { float = true }
        }
    }

    @ViewBuilder private var hero: some View {
        if let heroImage = page.heroImage {
            Image(heroImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 200, height: 200)
                .shadow(color: page.glow.opacity(0.45), radius: 40, y: 12)
                .offset(y: float ? -6 : 6)
                .accessibilityHidden(true)
        } else {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [page.glow.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 110))
                    .frame(width: 220, height: 220)
                Image(systemName: page.symbol)
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 128, height: 128)
                    .tetherGlass(in: Circle(), tint: page.glow.opacity(0.35))
            }
            .frame(height: 200)
            .offset(y: float ? -4 : 4)
            .accessibilityHidden(true)
        }
    }
}

/// Paged progress: the current page is a short bar, the rest are dots.
private struct PageProgress: View {
    var count: Int
    var current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: TetherSpace.s) {
            ForEach(0 ..< max(count, 1), id: \.self) { i in
                Capsule()
                    .fill(i == current ? TetherColor.accent : TetherColor.ink2.opacity(0.5))
                    .frame(width: i == current ? 24 : 8, height: 8)
            }
        }
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// Permission with its state spelled out, not only coloured.
private struct PermissionRow: View {
    var title: String
    var symbol: String
    var done: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            IconTile(systemImage: symbol, size: 36)
            Text(title).font(TetherFont.callout.weight(.medium)).foregroundStyle(TetherColor.ink0)
            Spacer()
            if done {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(TetherFont.callout.weight(.semibold))
                    .foregroundStyle(TetherColor.ok)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.tetherSecondary)
                    .controlSize(.small)
            }
        }
        .animation(TetherMotion.snap, value: done)
        .padding(.horizontal, TetherSpace.l)
        .padding(.vertical, TetherSpace.s)
        .tetherCard()
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "granted" : "not yet asked")
    }
}
