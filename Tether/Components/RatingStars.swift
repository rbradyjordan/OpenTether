import SwiftUI

/// Tap a star to rate; tapping the current rating clears it.
struct RatingStars: View {
    var rating: Int
    var size: CGFloat = 22
    var onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1 ... 5, id: \.self) { star in
                Button {
                    onRate(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(star <= rating ? Theme.accent : Theme.textSecondary)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star <= rating ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating, \(rating) of 5")
    }
}

/// Compact read-only dots for the filmstrip.
struct RatingDots: View {
    var rating: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< max(0, min(5, rating)), id: \.self) { _ in
                Circle().fill(Theme.accent).frame(width: 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}
