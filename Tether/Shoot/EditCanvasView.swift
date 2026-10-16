import SwiftUI
import TetherCore
import UIKit

/// Shows the displayed item (proxy when there is one) through the current
/// look. A new frame crossfades in with `settle`; while bytes land a thin
/// progress bar sits under the blurred thumbnail.
struct EditCanvasView: View {
    var model: ShootViewModel
    @State private var image: UIImage?
    @State private var renderedKey = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TetherColor.surface0
            if let item = model.displayedItem {
                frame(item)
            } else if model.isImportOnly {
                EmptyState(systemImage: "arrow.down.circle", title: "Import only",
                           message: "Press the camera's shutter; frames show up here.")
            } else {
                EmptyState(systemImage: "camera.aperture", title: model.isLive ? "Ready" : model.statusText,
                           message: model.isLive ? "Take a picture to see it here." : "")
            }
        }
        .task(id: renderKey) { await render() }
    }

    @ViewBuilder private func frame(_ item: CaptureItem) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .id(renderedKey)
                    .transition(.opacity)
            } else if let thumb = item.thumbnailRelativePath {
                AsyncImageView(cache: model.renderCache.proxyCache, relativePath: thumb)
                    .blur(radius: 6)
                    .transition(.opacity)
            } else {
                ProgressView().tint(TetherColor.ink1)
            }
            if case .downloading(let r, let t) = item.state {
                VStack {
                    Spacer()
                    ProgressView(value: Double(r), total: Double(max(t ?? r, 1)))
                        .tint(TetherColor.accent)
                        .padding(.horizontal, TetherSpace.xxl + TetherSpace.s)
                        .padding(.bottom, 60)
                        .accessibilityLabel("Downloading \(item.filename)")
                }
            }
        }
        .animation(Motion.spring(TetherMotion.settle, reduce: reduceMotion), value: renderedKey)
    }

    private var renderKey: String {
        let item = model.displayedItem
        return "\(item?.id ?? "-")|\(item?.previewRelativePath ?? "-")|\(model.lookStack.lookID ?? "-")|\(model.lookStack.strength)"
    }

    private func render() async {
        guard let item = model.displayedItem, let path = item.previewRelativePath else {
            image = nil
            renderedKey = ""
            return
        }
        let key = renderKey
        let result = await model.renderCache.image(for: path, look: model.lookStack)
        if key == renderKey {
            withAnimation(Motion.spring(TetherMotion.settle, reduce: reduceMotion)) {
                image = result
                renderedKey = key
            }
        }
    }
}

extension LookRenderCache {
    /// The underlying byte cache, for thumbnails that skip the look.
    var proxyCache: CaptureCacheProxy { cacheProxy }
}
