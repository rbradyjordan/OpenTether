import SwiftUI
import TetherCore
import UIKit

/// Shows the displayed item (proxy when there is one) through the current look.
struct EditCanvasView: View {
    var model: ShootViewModel
    @State private var image: UIImage?
    @State private var renderedKey = ""

    var body: some View {
        ZStack {
            Theme.background
            if let item = model.displayedItem {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                } else if let thumb = item.thumbnailRelativePath {
                    AsyncImageView(cache: model.renderCache.proxyCache, relativePath: thumb).blur(radius: 6)
                } else {
                    ProgressView()
                }
                if case .downloading(let r, let t) = item.state {
                    VStack {
                        Spacer()
                        ProgressView(value: Double(r), total: Double(max(t ?? r, 1)))
                            .tint(Theme.accent).padding(.horizontal, 40).padding(.bottom, 60)
                    }
                }
            } else if model.isImportOnly {
                EmptyState(systemImage: "arrow.down.circle", title: "Import only",
                           message: "This camera does not offer remote capture over this connection. Press its shutter; frames show up here.")
            } else {
                EmptyState(systemImage: "camera.aperture", title: model.isLive ? "Ready" : model.statusText,
                           message: model.isLive ? "Take a picture to see it here." : "")
            }
        }
        .task(id: renderKey) { await render() }
    }

    private var renderKey: String {
        let item = model.displayedItem
        return "\(item?.id ?? "-")|\(item?.previewRelativePath ?? "-")|\(model.lookStack.lookID ?? "-")|\(model.lookStack.strength)"
    }

    private func render() async {
        guard let item = model.displayedItem, let path = item.previewRelativePath else { image = nil; return }
        let key = renderKey
        let result = await model.renderCache.image(for: path, look: model.lookStack)
        if key == renderKey {
            withAnimation(.easeOut(duration: 0.15)) { image = result }
            renderedKey = key
        }
    }
}

extension LookRenderCache {
    /// The underlying byte cache, for thumbnails that skip the look.
    var proxyCache: CaptureCacheProxy { cacheProxy }
}
