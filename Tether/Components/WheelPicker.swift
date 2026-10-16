import SwiftUI

/// Pure helpers for the wheel so the snapping maths is testable.
enum WheelMath {
    /// Row index nearest to a content offset, clamped to the list.
    static func index(forOffset offset: CGFloat, rowHeight: CGFloat, count: Int) -> Int {
        guard count > 0, rowHeight > 0 else { return 0 }
        let raw = Int((offset / rowHeight).rounded())
        return min(count - 1, max(0, raw))
    }

    /// Steps between two positions (haptic ticks).
    static func steps(from: Int, to: Int) -> Int { abs(to - from) }
}

/// Vertical list that snaps row-by-row (`.viewAligned`), keeps the current
/// value centred, ticks per step and applies the centred value once the
/// wheel comes to rest.
struct WheelPicker: View {
    struct Item: Identifiable, Equatable {
        var id: String
        var label: String
    }

    var items: [Item]
    var current: String?
    var rowHeight: CGFloat = 44
    var onCommit: (String) -> Void

    @State private var position: String?
    @State private var tickCount = 0
    @State private var commitTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let inset = max(0, (geo.size.height - rowHeight) / 2)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item).id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.vertical, inset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .center)
            .scrollIndicators(.hidden)
            .overlay(selectionBand)
            .mask { fadeMask }
        }
        .tetherHaptic(.rate, trigger: tickCount)
        .onAppear { position = current ?? items.first?.id }
        .onChange(of: position) { old, new in
            guard let new, old != nil, old != new else { return }
            tickCount += 1
            scheduleCommit(new)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Value wheel")
    }

    private func row(_ item: Item) -> some View {
        let centred = item.id == position
        return Text(item.label)
            .font(TetherFont.exposure)
            .foregroundStyle(centred ? TetherColor.ink0 : TetherColor.ink2)
            .scaleEffect(centred ? 1 : 0.9)
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.spring(TetherMotion.snap, reduce: reduceMotion)) { position = item.id }
            }
            .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: centred)
            .accessibilityLabel(item.label)
            .accessibilityAddTraits(centred ? [.isButton, .isSelected] : .isButton)
    }

    private var selectionBand: some View {
        RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous)
            .fill(TetherColor.accentSoft)
            .overlay(RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous).strokeBorder(TetherColor.accent, lineWidth: 1))
            .frame(height: rowHeight)
            .padding(.horizontal, TetherSpace.xl)
            .allowsHitTesting(false)
    }

    private var fadeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.25),
            .init(color: .black, location: 0.75),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// "Applies on release": the position binding settles once scrolling
    /// stops, so a short quiet period after the last change is the release.
    private func scheduleCommit(_ id: String) {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, position == id, id != current else { return }
            onCommit(id)
        }
    }
}
