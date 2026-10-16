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
            Button(OnboardingContent.isLast(page) ? "Start" : "Next") {
                if OnboardingContent.isLast(page) { finish() } else {
                    withAnimation(Motion.spring(TetherMotion.settle, reduce: reduceMotion)) { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TetherColor.accent)
            .controlSize(.large)
            .font(TetherFont.headline)
            .frame(maxWidth: .infinity)
            .contentTransition(.numericText())
        }
        .padding(.horizontal, TetherSpace.xl)
        .padding(.bottom, TetherSpace.xl)
    }

    private var permissionButtons: some View {
        VStack(spacing: TetherSpace.s) {
            PermissionRow(title: "Local network", done: localNetworkAsked) {
                // Starting discovery triggers the system prompt; stop again right away.
                Task {
                    try? await app.discovery.start()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await app.discovery.stop()
                    localNetworkAsked = true
                }
            }
            PermissionRow(title: "Photos (add only)", done: photosStatus == .authorized || photosStatus == .limited) {
                Task { photosStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            }
            PermissionRow(title: "Location for the Wi-Fi name", done: ssidState == .authorized) {
                Task {
                    await app.services.ssid.requestAuthorization()
                    ssidState = await app.services.ssid.authorizationState
                }
            }
            Text("Skip any of these; Tether asks again when a feature needs it.")
                .font(TetherFont.hud).foregroundStyle(TetherColor.ink2)
        }
    }

    private func finish() {
        app.settings.hasOnboarded = true
        Task { await app.refreshCloud() } // registers the device; failure is tolerated
    }
}

/// Full-bleed gradient placeholder with a large symbol, title in display type.
private struct OnboardingPageView<Extra: View>: View {
    var page: OnboardingPage
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: page.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Image(systemName: page.symbol)
                .font(.system(size: 160, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 80)
                .padding(.trailing, -30)
                .accessibilityHidden(true)
            LinearGradient(colors: [.clear, TetherColor.surface0.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: TetherSpace.l) {
                    Text(page.title).font(TetherFont.display).foregroundStyle(TetherColor.ink0)
                    Text(page.line).font(TetherFont.body).foregroundStyle(TetherColor.ink1)
                        .fixedSize(horizontal: false, vertical: true)
                    extra()
                }
                .padding(.horizontal, TetherSpace.xl)
                .padding(.top, 220)
                .padding(.bottom, 140)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
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
    var done: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? TetherColor.ok : TetherColor.ink2)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(TetherFont.callout).foregroundStyle(TetherColor.ink0)
            Spacer()
            Button(done ? "Granted" : "Allow", action: action)
                .buttonStyle(.bordered)
                .tint(done ? TetherColor.ok : TetherColor.accent)
                .frame(minHeight: TetherHit.min)
                .disabled(done)
        }
        .padding(.horizontal, TetherSpace.l)
        .padding(.vertical, TetherSpace.s)
        .tetherCard()
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "granted" : "not yet asked")
    }
}
