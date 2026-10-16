import SwiftUI
import UIKit

/// Pinch to zoom, drag to pan, double-tap toggles 1:1 and fit.
struct ZoomableImage: View {
    var image: UIImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize

    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let fitScale = min(geo.size.width / max(image.size.width, 1), geo.size.height / max(image.size.height, 1))
            let fitted = CGSize(width: image.size.width * fitScale, height: image.size.height * fitScale)
            Image(uiImage: image)
                .resizable()
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(scale * pinch)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in scale = max(1, min(8, scale * value)); if scale == 1 { offset = .zero } }
                )
                .simultaneousGesture(
                    DragGesture()
                        .updating($drag) { value, state, _ in if scale > 1 { state = value.translation } }
                        .onEnded { value in if scale > 1 { offset.width += value.translation.width; offset.height += value.translation.height } }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1 { scale = 1; offset = .zero } else { scale = max(1.01, 1 / fitScale) }
                    }
                }
                .animation(.interactiveSpring(), value: pinch)
        }
        .clipped()
        .accessibilityLabel("Zoomable image")
        .accessibilityHint("Pinch to zoom, double tap for one to one")
    }
}

/// Loads the looked image for an item.
struct RenderedCaptureImage: View {
    var model: ShootViewModel
    var itemID: String?
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, scale: $scale, offset: $offset)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(itemID ?? "-")|\(model.lookStack.lookID ?? "-")|\(model.lookStack.strength)") {
            guard let path = model.items.first(where: { $0.id == itemID })?.previewRelativePath else { image = nil; return }
            image = await model.renderCache.image(for: path, look: model.lookStack, maxPixelSize: 4096)
        }
    }
}
