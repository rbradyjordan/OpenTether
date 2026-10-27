import SwiftUI
import TetherCore

/// A hands-on tour: a drawn shoot screen whose parts light up when tapped
/// (or step by step with Next), then culling and the library/export.
struct TourStep: View {
    enum Chapter: Int, CaseIterable, Identifiable {
        case shoot, cull, library
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .shoot: return "Shoot"
            case .cull: return "Cull"
            case .library: return "Library & export"
            }
        }
    }

    @State private var chapter: Chapter = .shoot
    @State private var hotspot: ShootHotspot = .status

    var body: some View {
        OnboardingPageScaffold(eyebrow: "Quick tour", title: "Around the shoot screen",
                               subtitle: "Tap any part of the screen below to see what it does.") {
            Picker("Chapter", selection: $chapter) {
                ForEach(Chapter.allCases) { c in Text(c.title).tag(c) }
            }
            .pickerStyle(.segmented)

            switch chapter {
            case .shoot:
                ShootScreenMock(selected: $hotspot)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                HotspotCallout(hotspot: hotspot) {
                    withAnimation(TetherMotion.snap) {
                        if let next = ShootHotspot(rawValue: hotspot.rawValue + 1) { hotspot = next } else { chapter = .cull }
                    }
                }
            case .cull:
                CullingCard()
            case .library:
                LibraryCard()
            }
        }
        .animation(TetherMotion.snap, value: chapter)
    }
}

// MARK: - Shoot screen mock

enum ShootHotspot: Int, CaseIterable, Identifiable {
    case status, canvas, exposure, filmstrip, rating, shutter
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .status: return "Connection pill"
        case .canvas: return "The frame"
        case .exposure: return "Exposure bar"
        case .filmstrip: return "Filmstrip"
        case .rating: return "Rate and flag"
        case .shutter: return "Shutter"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "dot.radiowaves.left.and.right"
        case .canvas: return "photo"
        case .exposure: return "dial.medium"
        case .filmstrip: return "film"
        case .rating: return "star"
        case .shutter: return "circle.inset.filled"
        }
    }

    var text: String {
        switch self {
        case .status: return "Camera name, battery and downloads. Tap it for diagnostics; if the link drops it turns amber and reconnects on its own."
        case .canvas: return "The newest frame, the moment it lands. Pinch to zoom, double-tap for 100 %. With live view on, tap to focus there."
        case .exposure: return "ISO, aperture, shutter, white balance and drive. Tap one to change it on the camera; it updates as you turn the dials."
        case .filmstrip: return "Every frame of the session. Tap one to review it; \"Following newest\" jumps back to the latest."
        case .rating: return "Stars, pick and reject, right where your thumb is. Ratings travel with the file into Lightroom and Capture One."
        case .shutter: return "Tap to focus and fire. Press, hold and release to fire without refocusing. Live view and looks are in the menus beside it."
        }
    }
}

private struct ShootScreenMock: View {
    @Binding var selected: ShootHotspot
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            // Status row
            HStack {
                zone(.status) {
                    HStack(spacing: 5) {
                        Circle().fill(TetherColor.ok).frame(width: 7, height: 7)
                        Text("EOS R5 Mark II").font(.system(size: 11, weight: .semibold))
                        Image(systemName: "battery.75").font(.system(size: 11))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.white.opacity(0.1), in: Capsule())
                }
                Spacer()
                Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(TetherColor.ink2)
            }
            // Canvas
            zone(.canvas) {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x6E8FB5), Color(hex: 0xD99A6C), Color(hex: 0x3B3F55)], startPoint: .top, endPoint: .bottom)
                    Circle().fill(Color(hex: 0xFFD98A)).frame(width: 34, height: 34).offset(x: 40, y: 10)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 120)); p.addCurve(to: CGPoint(x: 320, y: 110), control1: CGPoint(x: 90, y: 70), control2: CGPoint(x: 220, y: 150))
                        p.addLine(to: CGPoint(x: 320, y: 200)); p.addLine(to: CGPoint(x: 0, y: 200)); p.closeSubpath()
                    }.fill(Color(hex: 0x262A3A))
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            // Exposure bar
            zone(.exposure) {
                HStack {
                    ForEach(["ISO 400", "f/2.8", "1/250", "AWB"], id: \.self) { t in
                        Text(t).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            // Filmstrip
            zone(.filmstrip) {
                HStack(spacing: 4) {
                    ForEach(0 ..< 6, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [Color(hex: 0x6E8FB5).opacity(0.6 + Double(i) * 0.06), Color(hex: 0x3B3F55)], startPoint: .top, endPoint: .bottom))
                            .frame(height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == 5 ? TetherColor.accent : .clear, lineWidth: 1.5))
                    }
                }
            }
            // Rating + shutter
            HStack {
                zone(.rating) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle").font(.system(size: 13))
                        ForEach(0 ..< 5, id: \.self) { i in Image(systemName: i < 3 ? "star.fill" : "star").font(.system(size: 11)).foregroundStyle(i < 3 ? TetherColor.pick : TetherColor.ink2) }
                        Image(systemName: "flag").font(.system(size: 13))
                    }
                    .padding(6)
                }
                Spacer()
                zone(.shutter) {
                    Circle().stroke(Color.white, lineWidth: 3).frame(width: 46, height: 46)
                        .overlay(Circle().fill(Color.white).padding(6))
                }
            }
        }
        .foregroundStyle(TetherColor.ink0)
        .padding(12)
        .background(Color(hex: 0x0A0B0E), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } } }
    }

    private func zone<C: View>(_ h: ShootHotspot, @ViewBuilder _ content: () -> C) -> some View {
        let on = selected == h
        return Button { withAnimation(TetherMotion.snap) { selected = h } } label: {
            content()
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(TetherColor.accent, lineWidth: 2)
                        .opacity(on ? (pulse ? 1 : 0.45) : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(h.title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

private struct HotspotCallout: View {
    var hotspot: ShootHotspot
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.s) {
            HStack(spacing: TetherSpace.s) {
                IconTile(systemImage: hotspot.symbol, active: true, size: 32)
                Text(hotspot.title).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                Spacer()
                Text("\(hotspot.rawValue + 1)/\(ShootHotspot.allCases.count)")
                    .font(TetherFont.caption).monospacedDigit().foregroundStyle(TetherColor.ink2)
            }
            Text(hotspot.text).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                .fixedSize(horizontal: false, vertical: true)
                .id(hotspot)
                .transition(.opacity)
            HStack {
                Spacer()
                Button(hotspot.rawValue + 1 < ShootHotspot.allCases.count ? "Next" : "Culling →", action: next)
                    .buttonStyle(.tetherSecondary).controlSize(.small)
            }
        }
        .padding(TetherSpace.l)
        .tetherCard()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Culling

private struct CullingCard: View {
    @State private var rating = 0
    @State private var flag: CaptureFlag = .none

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.l) {
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                Text("Try it").font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                HStack(spacing: TetherSpace.m) {
                    Button { withAnimation(TetherMotion.snap) { flag = flag == .reject ? .none : .reject } } label: {
                        Image(systemName: flag == .reject ? "xmark.circle.fill" : "xmark.circle")
                            .font(.system(size: 26)).foregroundStyle(flag == .reject ? TetherColor.danger : TetherColor.ink1)
                            .frame(width: TetherHit.min, height: TetherHit.min)
                    }
                    .accessibilityLabel("Reject")
                    RatingStars(rating: rating, size: 28) { r in withAnimation(TetherMotion.snap) { rating = r }; TetherHaptic.rate() }
                    Button { withAnimation(TetherMotion.snap) { flag = flag == .pick ? .none : .pick } } label: {
                        Image(systemName: flag == .pick ? "flag.fill" : "flag")
                            .font(.system(size: 24)).foregroundStyle(flag == .pick ? TetherColor.pick : TetherColor.ink1)
                            .frame(width: TetherHit.min, height: TetherHit.min)
                    }
                    .accessibilityLabel("Pick")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, TetherSpace.s)
                .tetherCard()
                Text(feedback).font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
            }
            VStack(alignment: .leading, spacing: TetherSpace.s) {
                Text("Faster with gestures and keys").font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                shortcut("hand.draw", "Swipe left or right", "Next or previous frame (full screen)")
                shortcut("star", "Drag across the stars", "Rate in one move")
                shortcut("iphone.gen3.radiowaves.left.and.right", "Shake", "Undo the last edit")
                shortcut("keyboard", "1–5, 0", "Rate, clear rating (iPad keyboard)")
                shortcut("keyboard", "P · X · U", "Pick · reject · unflag")
                shortcut("command", "⌘K", "Command palette: every action by name")
            }
            Label("Client review hands the phone over full-screen: they browse and pick, nothing else.", systemImage: "person.crop.rectangle")
                .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
        }
    }

    private var feedback: String {
        switch (rating, flag) {
        case (0, .none): return "Tap the stars, then pick or reject."
        case (_, .reject): return "Filter rejects out in one tap, or delete them together."
        case (_, .pick): return "Picks can export themselves the moment you flag them."
        default: return "\(rating) star\(rating == 1 ? "" : "s"). Saved to the frame and its XMP sidecar."
        }
    }

    private func shortcut(_ symbol: String, _ keys: String, _ what: String) -> some View {
        HStack(spacing: TetherSpace.m) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(TetherColor.ink2)
            Text(keys).font(TetherFont.callout.weight(.semibold)).foregroundStyle(TetherColor.ink0)
            Spacer()
            Text(what).font(TetherFont.callout).foregroundStyle(TetherColor.ink1).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Library

private struct LibraryCard: View {
    private let items: [(String, String, String)] = [
        ("photo.on.rectangle.angled", "One library for every session", "Search by name, tag or #hashtag; filter by rating, flag, colour, camera or date."),
        ("rectangle.stack.badge.plus", "Collections and smart collections", "Hand-picked sets, or rules like \"4★ and up this week\" that fill themselves."),
        ("paintpalette", "Looks", "Built-in looks, your own .cube LUTs, or match the colour of a reference shot."),
        ("square.and.arrow.up", "Export anywhere", "Photos, a Files folder, an FTP server, or a hot folder for Capture One or Lightroom, with sidecars and naming you choose."),
        ("arrow.triangle.2.circlepath", "Round-trip ratings", "Read ratings and picks back from a Lightroom or Capture One catalog."),
    ]

    var body: some View {
        VStack(spacing: TetherSpace.s) {
            ForEach(items, id: \.1) { item in
                HStack(alignment: .top, spacing: TetherSpace.m) {
                    IconTile(systemImage: item.0, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                        Text(item.2).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(TetherSpace.m)
                .tetherCard()
                .accessibilityElement(children: .combine)
            }
        }
    }
}
