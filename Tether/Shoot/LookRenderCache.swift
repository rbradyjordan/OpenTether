import Foundation
import TetherCore
import UIKit

/// Renders the displayed capture through the current look, memoised per
/// (file, look, strength). The canvas asks for one image at a time, so a
/// small LRU is plenty.
final class LookRenderCache: @unchecked Sendable {
    private let renderer: CoreImageLookRenderer
    private let resolver: LookResolver
    let cacheProxy: CaptureCacheProxy
    private let images = NSCache<NSString, UIImage>()

    init(renderer: CoreImageLookRenderer, resolver: LookResolver, cache: CaptureCacheProxy) {
        self.renderer = renderer
        self.resolver = resolver
        self.cacheProxy = cache
        images.countLimit = 24
    }

    func image(for relativePath: String, look: LookStack, maxPixelSize: Int = 2048) async -> UIImage? {
        let key = "\(relativePath)|\(look.lookID ?? "-")|\(String(format: "%.2f", look.strength))|\(maxPixelSize)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        let lut: CubeLUT? = look.isNeutral ? nil : try? await resolver.lut(for: look)
        let renderer = renderer
        let proxy = cacheProxy
        let rendered: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? proxy.load(relativePath) else { return nil }
            if lut == nil { return ImageDecoding.decode(data, maxPixelSize: maxPixelSize) }
            // The resolver already blended strength into the LUT.
            return try? renderer.renderImage(data: data, look: lut, strength: 1, maxPixelSize: maxPixelSize, watermark: false)
        }.value
        if let rendered { images.setObject(rendered, forKey: key) }
        return rendered
    }

    func clear() { images.removeAllObjects() }
}
