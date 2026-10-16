import SwiftUI

/// Display-type title, one line of guidance, at most one action.
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: TetherSpace.m) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(TetherColor.ink2)
                .padding(.bottom, TetherSpace.xs)
            Text(title)
                .font(TetherFont.display)
                .foregroundStyle(TetherColor.ink0)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(TetherFont.callout)
                    .foregroundStyle(TetherColor.ink1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(TetherColor.accent)
                    .controlSize(.large)
                    .padding(.top, TetherSpace.s)
            }
        }
        .padding(TetherSpace.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
