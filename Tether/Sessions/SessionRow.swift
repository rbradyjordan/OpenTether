import SwiftUI
import TetherCore

/// Large session card: name, meta line, counts, and a 3-up strip of the
/// newest frames.
struct SessionCard: View {
    @Environment(AppModel.self) private var app
    var session: ShootSession
    var counts: SessionStore.SessionCounts
    var isLive = false

    @State private var thumbs: [CaptureItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: TetherSpace.m) {
            ThumbnailStrip(items: thumbs, cache: app.cache)
            HStack(alignment: .firstTextBaseline, spacing: TetherSpace.m) {
                VStack(alignment: .leading, spacing: TetherSpace.xs) {
                    HStack(spacing: TetherSpace.s) {
                        Image(systemName: icon).font(TetherFont.hud).foregroundStyle(isLive ? TetherColor.accent : TetherColor.ink2)
                        Text(session.name).font(TetherFont.headline).foregroundStyle(TetherColor.ink0).lineLimit(1)
                        if isLive { TonePill(text: "Live", tone: .ok) }
                    }
                    Text(subtitle).font(TetherFont.hud).foregroundStyle(TetherColor.ink1).lineLimit(2)
                }
                Spacer(minLength: TetherSpace.xs)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(counts.total)").font(TetherFont.exposure).foregroundStyle(TetherColor.ink0).contentTransition(.numericText())
                    HStack(spacing: TetherSpace.s) {
                        if counts.picks > 0 { Label("\(counts.picks)", systemImage: "flag.fill").foregroundStyle(TetherColor.ok) }
                        if counts.rejects > 0 { Label("\(counts.rejects)", systemImage: "xmark.circle.fill").foregroundStyle(TetherColor.danger) }
                    }
                    .font(TetherFont.hud)
                }
            }
            .padding(.horizontal, TetherSpace.l)
            .padding(.bottom, TetherSpace.l)
        }
        .tetherCard()
        .task(id: session.id + "\(counts.total)") {
            thumbs = Array(((try? app.store.captures(in: session.id)) ?? []).filter { $0.state.isReady }.suffix(3).reversed())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.name), \(counts.total) frames, \(counts.picks) picks, \(session.status.rawValue)")
    }

    private var icon: String {
        switch session.transport {
        case .usb?: return "cable.connector"
        case .ptpip?, .ricohHTTP?, .http?: return "wifi"
        case .ftpPush?: return "arrow.down.doc"
        case nil: return "rectangle.stack"
        }
    }

    private var subtitle: String {
        var parts = [session.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let camera = session.camera { parts.append(camera.displayName) }
        if session.status != .ended { parts.append(session.status.rawValue.capitalized) }
        if let tag = session.workflowTag, !tag.isEmpty { parts.append("#\(tag)") }
        return parts.joined(separator: " · ")
    }
}

/// Three newest frames edge to edge; empty slots show a quiet surface.
private struct ThumbnailStrip: View {
    var items: [CaptureItem]
    var cache: CaptureCacheProxy

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { i in
                ZStack {
                    if i < items.count {
                        AsyncImageView(cache: cache, relativePath: items[i].thumbnailRelativePath ?? items[i].previewRelativePath,
                                       contentMode: .fill, maxPixelSize: 480)
                    } else {
                        Rectangle().fill(TetherColor.surface3)
                            .overlay(Image(systemName: "photo").foregroundStyle(TetherColor.ink2.opacity(i == 0 && items.isEmpty ? 1 : 0)))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipped()
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: TetherRadius.card, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: TetherRadius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Compact row kept for lists that need one line per session.
struct SessionRow: View {
    var session: ShootSession
    var counts: SessionStore.SessionCounts

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(TetherFont.hud).foregroundStyle(TetherColor.ink1)
            }
            Spacer()
            Text("\(counts.total)").font(TetherFont.exposure).foregroundStyle(TetherColor.ink0)
        }
        .frame(minHeight: TetherHit.min)
        .accessibilityElement(children: .combine)
    }
}
