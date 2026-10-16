import SwiftUI
import UIKit

struct LiveViewView: View {
    var image: UIImage?

    var body: some View {
        ZStack {
            Theme.background
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for live view…").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            VStack {
                HStack {
                    Text("LIVE").font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.danger, in: Capsule())
                    Spacer()
                }
                .padding(10)
                Spacer()
            }
        }
        .accessibilityLabel("Live view from the camera")
    }
}
