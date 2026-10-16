import SwiftUI
import TetherCore

/// One grid tile: thumbnail, rating dots, flag, label dot, RAW / pair badge,
/// download ring while not ready, look dot. Tap opens the loupe; in selection
/// mode tap toggles. The context menu is `Commands.available` for this tile.
struct LibraryTile: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var item: CaptureItem
    var stack: CaptureStack
    @Bindable var model: LibraryModel
    var side: CGFloat

    private var selected: Bool { model.selection.contains(item.id) }
    private var collapsedPair: Bool { stack.isPair && model.stackPairs && !model.expandedStacks.contains(stack.id) }
    private var ids: [String] { selected ? model.selection.ids : [item.id] }

    var body: some View {
        ZStack {
            AsyncImageView(cache: app.cache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath, contentMode: .fill, maxPixelSize: 480)
                .frame(width: side, height: side)
                .clipped()
                .opacity(item.flag == .reject ? 0.4 : 1)
            if !item.state.isReady { Color.black.opacity(0.45) }
            if item.state.isFailed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TetherColor.danger).accessibilityHidden(true)
            } else if !item.state.isReady {
                ProgressRing(progress: item.state.progress).frame(width: 28, height: 28)
            }
            TileBadges(item: item, pairCount: collapsedPair ? stack.items.count : 0)
            if model.selectionMode || selected { selectionMark }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 140 ? TetherRadius.chip : 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side > 140 ? TetherRadius.chip : 4, style: .continuous)
            .strokeBorder(selected ? TetherColor.accent : TetherColor.hairline, lineWidth: selected ? 2 : 0.5))
        .scaleEffect(selected && model.selectionMode ? 0.96 : 1)
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? AccessibilityTraits([.isButton, .isSelected]) : .isButton)
        .accessibilityAction(named: "Select") { model.toggle(item.id); model.selectionMode = true }
    }

    private func tap() {
        if model.selectionMode { model.toggle(item.id); TetherHaptic.rate(); return }
        model.focusedID = item.id
        model.rememberScroll(item.id)
        model.loupeID = item.id
    }

    private var selectionMark: some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? TetherColor.accent : .white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(TetherSpace.xs)
            }
            Spacer()
        }
    }

    @ViewBuilder private var menu: some View {
        if stack.isPair, model.stackPairs {
            Button { model.toggleStack(stack.id) } label: { Label(collapsedPair ? "Expand stack" : "Collapse stack", systemImage: "square.2.layers.3d") }
        }
        if !model.selectionMode {
            Button { model.selectionMode = true; model.toggle(item.id) } label: { Label("Select", systemImage: "checkmark.circle") }
        }
        Button { model.focusedID = item.id; model.inspectorOpen = true } label: { Label("Inspector", systemImage: "info.circle") }
        Divider()
        CommandMenuContent(commands: app.commands.available(selection: ids, collection: model.collection), exclude: ["select."]) { cmd in
            app.commands.run(cmd, on: ids, in: model.collection)
        }
    }

    private var accessibilityText: String {
        var parts = [item.filename]
        if collapsedPair { parts.append("RAW and JPEG pair") }
        if !item.state.isReady { parts.append(item.state.isFailed ? "failed" : "downloading") }
        if item.rating > 0 { parts.append("\(item.rating) stars") }
        if item.flag != .none { parts.append(item.flag.rawValue) }
        if item.colorLabel != .none { parts.append("\(item.colorLabel.rawValue) label") }
        if item.lookID != nil { parts.append("look applied") }
        return parts.joined(separator: ", ")
    }
}

/// Corner badges shared by grid tiles; reads at 2–6 columns.
struct TileBadges: View {
    var item: CaptureItem
    var pairCount: Int

    var body: some View {
        VStack {
            HStack(spacing: 3) {
                if item.flag == .pick { Image(systemName: "flag.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(TetherColor.ok) }
                if item.flag == .reject { Image(systemName: "xmark.circle.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(TetherColor.danger) }
                if item.colorLabel != .none { Circle().fill(ColorLabelStyle.color(for: item.colorLabel)).frame(width: 8, height: 8) }
                Spacer()
                if pairCount > 1 || item.isRAW {
                    Text(pairCount > 1 ? "R+J" : "RAW")
                        .font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Spacer()
            HStack {
                RatingDots(rating: item.rating)
                Spacer()
                if item.lookID != nil {
                    Image(systemName: "camera.filters").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }
        }
        .padding(TetherSpace.xs)
        .accessibilityHidden(true)
    }
}
