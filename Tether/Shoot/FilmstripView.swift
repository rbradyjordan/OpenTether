import SwiftUI
import TetherCore

/// Horizontal strip of captures. New frames slide in from the right at 0.9
/// scale with a download ring; with "Keep selection" on, a count badge
/// increments instead of the canvas changing.
struct FilmstripView: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: TetherSpace.s) {
                    ForEach(model.items) { item in
                        FilmstripCell(item: item, selected: item.id == model.displayedItem?.id,
                                      pairCount: model.pairCount(for: item), cache: model.renderCache.proxyCache)
                            .id(item.id)
                            .onTapGesture { model.select(item.id) }
                            .contextMenu {
                                CommandMenuContent(commands: app.commands.available(selection: [item.id], inShoot: true), exclude: ["select.", "camera.", "session."]) { cmd in
                                    app.commands.preferShootSurface = true
                                    app.commands.run(cmd, on: [item.id])
                                    app.commands.preferShootSurface = false
                                }
                            }
                            .transition(arrival)
                    }
                }
                .padding(.horizontal, TetherSpace.m)
                .padding(.vertical, TetherSpace.s)
                .animation(Motion.spring(TetherMotion.arrive, reduce: reduceMotion), value: model.items.count)
            }
            .onChange(of: model.displayedItem?.id) { _, id in
                if let id { withAnimation(Motion.spring(TetherMotion.snap, reduce: reduceMotion)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: model.items.count) { _, _ in
                // Keep the newest frame in view when it arrives and we are following it.
                if model.shootSession.showNewestCapture, let last = model.items.last {
                    withAnimation(Motion.spring(TetherMotion.arrive, reduce: reduceMotion)) { proxy.scrollTo(last.id, anchor: .trailing) }
                }
            }
        }
        .overlay(alignment: .topTrailing) { unseenBadge }
        .background(TetherColor.surface0)
        .accessibilityLabel("Filmstrip, \(model.items.count) captures")
    }

    private var arrival: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.9)).combined(with: .opacity),
            removal: .opacity
        )
    }

    @ViewBuilder private var unseenBadge: some View {
        if model.unseenCount > 0 {
            Button { model.showNewest() } label: {
                HStack(spacing: TetherSpace.xs) {
                    Text("\(model.unseenCount)").contentTransition(.numericText())
                    Text("new")
                }
                .font(TetherFont.hud)
                .foregroundStyle(.white)
                .padding(.horizontal, TetherSpace.s + 2)
                .padding(.vertical, TetherSpace.xs)
                .background(TetherColor.accent, in: Capsule())
                .frame(minHeight: TetherHit.min)
            }
            .buttonStyle(.plain)
            .padding(.trailing, TetherSpace.m)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .tetherAnimation(TetherMotion.snap, value: model.unseenCount)
            .accessibilityLabel("\(model.unseenCount) new frames")
            .accessibilityHint("Double tap to show the newest")
        }
    }
}

struct FilmstripCell: View {
    var item: CaptureItem
    var selected: Bool
    var pairCount: Int
    var cache: CaptureCacheProxy

    /// Set when the cell first appears before the file has landed, so the
    /// ring is kept around long enough to flash `ok` on completion.
    @State private var sawDownloading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let side: CGFloat = 72

    var body: some View {
        ZStack {
            AsyncImageView(cache: cache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath, contentMode: .fill, maxPixelSize: 320)
                .frame(width: Self.side, height: Self.side)
                .clipped()
                .opacity(item.flag == .reject ? 0.4 : 1)
            if !item.state.isReady {
                Color.black.opacity(0.45)
            }
            if item.state.isFailed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TetherColor.danger)
                    .accessibilityHidden(true)
            } else if !item.state.isReady || sawDownloading {
                ProgressRing(progress: item.state.progress, completed: item.state.isReady)
                    .frame(width: 28, height: 28)
            }
            badges
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous)
                .strokeBorder(selected ? TetherColor.accent : TetherColor.hairline, lineWidth: selected ? 2 : 0.5)
        )
        .scaleEffect(item.state.isReady ? 1 : 0.94)
        .animation(Motion.spring(TetherMotion.arrive, reduce: reduceMotion), value: item.state.isReady)
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: selected)
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: item.flag)
        .onAppear { if !item.state.isReady { sawDownloading = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? AccessibilityTraits([.isSelected, .isButton]) : AccessibilityTraits.isButton)
    }

    private var badges: some View {
        VStack {
            HStack(spacing: 3) {
                if item.flag == .pick { Image(systemName: "flag.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(TetherColor.ok) }
                if item.flag == .reject { Image(systemName: "xmark.circle.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(TetherColor.danger) }
                if item.colorLabel != .none { Circle().fill(ColorLabelStyle.color(for: item.colorLabel)).frame(width: 8, height: 8) }
                Spacer()
                if pairCount > 1 || item.isRAW {
                    Text(pairCount > 1 ? "R+J" : "RAW")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Spacer()
            HStack { RatingDots(rating: item.rating); Spacer() }
        }
        .padding(TetherSpace.xs)
    }

    private var accessibilityText: String {
        var parts = [item.filename]
        if !item.state.isReady { parts.append(item.state.isFailed ? "failed" : "downloading") }
        if item.rating > 0 { parts.append("\(item.rating) stars") }
        if item.flag != .none { parts.append(item.flag.rawValue) }
        if item.colorLabel != .none { parts.append("\(item.colorLabel.rawValue) label") }
        return parts.joined(separator: ", ")
    }
}
