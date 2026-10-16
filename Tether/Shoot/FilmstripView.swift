import SwiftUI
import TetherCore

struct FilmstripView: View {
    var model: ShootViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(model.items) { item in
                        FilmstripCell(item: item, selected: item.id == model.displayedItem?.id,
                                      pairCount: model.pairCount(for: item), cache: model.renderCache.proxyCache)
                            .id(item.id)
                            .onTapGesture { model.select(item.id) }
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: model.displayedItem?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .background(Theme.surface.opacity(0.6))
        .accessibilityLabel("Filmstrip, \(model.items.count) captures")
    }
}

struct FilmstripCell: View {
    var item: CaptureItem
    var selected: Bool
    var pairCount: Int
    var cache: CaptureCacheProxy

    var body: some View {
        ZStack {
            AsyncImageView(cache: cache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath, contentMode: .fill, maxPixelSize: 320)
                .frame(width: 72, height: 72)
                .clipped()
            if !item.state.isReady {
                Color.black.opacity(0.45)
                if item.state.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                } else {
                    ProgressRing(progress: item.state.progress).frame(width: 28, height: 28)
                }
            }
            VStack {
                HStack(spacing: 3) {
                    if item.flag == .pick { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Theme.success) }
                    if item.flag == .reject { Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(Theme.danger) }
                    if item.colorLabel != .none { Circle().fill(ColorLabelStyle.color(for: item.colorLabel)).frame(width: 8, height: 8) }
                    Spacer()
                    if pairCount > 1 || item.isRAW {
                        Text(item.isRAW ? (pairCount > 1 ? "R+J" : "RAW") : "R+J").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1).background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Spacer()
                HStack { RatingDots(rating: item.rating); Spacer() }
            }
            .padding(4)
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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
