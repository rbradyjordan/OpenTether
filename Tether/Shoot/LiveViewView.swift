import SwiftUI
import UIKit

struct LiveViewView: View {
    var image: UIImage?

    var body: some View {
        ZStack {
            TetherColor.surface0
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: TetherSpace.s) {
                    ProgressView().tint(TetherColor.ink1)
                    Text("Waiting for live view…").font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                }
            }
            VStack {
                HStack {
                    TonePill(text: "LIVE", tone: .danger, systemImage: "circle.fill")
                    Spacer()
                }
                .padding(TetherSpace.m)
                Spacer()
            }
            .overlayTypeCap()
        }
        .accessibilityLabel("Live view from the camera")
    }
}
