import SwiftUI

struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                    Text(title).font(.headline)
                }
                .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// A tappable hub card.
struct ActionCard: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var badge: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.2), in: Capsule()).foregroundStyle(Theme.accent)
                    }
                }
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .cardBackground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(badge.map { "\(title), \($0). \(subtitle)" } ?? "\(title). \(subtitle)")
    }
}
