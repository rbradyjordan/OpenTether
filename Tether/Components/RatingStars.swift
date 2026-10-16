import SwiftUI

/// Pure index maths for the star row so the drag can be unit-tested.
enum RatingMath {
    /// Which star (1…count) a horizontal position falls on; 0 left of the row.
    static func star(atX x: CGFloat, starSize: CGFloat, spacing: CGFloat, count: Int = 5) -> Int {
        guard count > 0, starSize > 0 else { return 0 }
        if x < 0 { return 0 }
        let pitch = starSize + spacing
        let index = Int(x / pitch) + 1
        return min(count, max(0, index))
    }

    /// Tapping the current rating clears it; anything else sets it.
    static func tapped(_ star: Int, current: Int) -> Int {
        star == current ? 0 : star
    }
}

/// Five stars; tap one or drag across the row. Fill is `pick`, plus a tick
/// under the current star so colour is never the only signal.
struct RatingStars: View {
    var rating: Int
    var size: CGFloat = 28
    var spacing: CGFloat = 6
    var onRate: (Int) -> Void

    @State private var dragValue: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Int { dragValue ?? rating }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1 ... 5, id: \.self) { star in
                starView(star)
            }
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .tetherHaptic(.rate, trigger: dragValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "No stars" : "\(rating) of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onRate(min(5, rating + 1))
            case .decrement: onRate(max(0, rating - 1))
            @unknown default: break
            }
        }
    }

    private func starView(_ star: Int) -> some View {
        let filled = star <= shown
        return VStack(spacing: 2) {
            Image(systemName: filled ? "star.fill" : "star")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(filled ? TetherColor.pick : TetherColor.ink2)
                .scaleEffect(filled && dragValue != nil ? 1.08 : 1)
                .contentTransition(.symbolEffect(.replace))
            Circle()
                .fill(star == shown && shown > 0 ? TetherColor.pick : .clear)
                .frame(width: 4, height: 4)
        }
        .frame(width: size, height: max(TetherHit.min, size + 10))
        .contentShape(Rectangle())
        .onTapGesture { onRate(RatingMath.tapped(star, current: rating)) }
        .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: shown)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let star = RatingMath.star(atX: value.location.x, starSize: size, spacing: spacing)
                if star != dragValue { dragValue = star }
            }
            .onEnded { value in
                let star = RatingMath.star(atX: value.location.x, starSize: size, spacing: spacing)
                dragValue = nil
                if star != rating { onRate(star) }
            }
    }
}

/// Compact read-only dots for the filmstrip and grids.
struct RatingDots: View {
    var rating: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< max(0, min(5, rating)), id: \.self) { _ in
                Circle().fill(TetherColor.pick).frame(width: 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}
