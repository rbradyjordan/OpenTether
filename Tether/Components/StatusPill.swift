import SwiftUI

struct StatusPill: View {
    var title: String
    var subtitle: String?
    var tint: Color = Theme.textSecondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            } else {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
            Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceRaised, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }
}
