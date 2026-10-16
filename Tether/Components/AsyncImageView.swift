import SwiftUI
import TetherCore
import UIKit

/// Decoded-image memory cache keyed by relative path. UIImage decoding is the
/// expensive part, so this sits in front of `CaptureCacheProxy`'s byte LRU.
final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSString, UIImage>()

    init(countLimit: Int = 400, costLimit: Int = 160 << 20) {
        cache.countLimit = countLimit
        cache.totalCostLimit = costLimit
    }

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func remove(_ key: String) { cache.removeObject(forKey: key as NSString) }
    func removeAll() { cache.removeAllObjects() }
}

/// Loads a capture file (thumbnail / proxy / original) from the cache proxy.
struct AsyncImageView: View {
    let cache: CaptureCacheProxy
    var relativePath: String?
    var contentMode: ContentMode = .fit
    /// Optional downsampled decode size (points); nil = full decode.
    var maxPixelSize: Int?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed || relativePath == nil {
                Rectangle().fill(Theme.surfaceRaised)
                    .overlay(Image(systemName: "photo").foregroundStyle(Theme.textSecondary))
            } else {
                Rectangle().fill(Theme.surface)
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private var cacheKey: String { "\(relativePath ?? "-")#\(maxPixelSize ?? 0)" }

    private func load() async {
        guard let relativePath else { return }
        if let hit = ImageMemoryCache.shared.image(for: cacheKey) { image = hit; return }
        let path = relativePath
        let maxPx = maxPixelSize
        let proxy = cache
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? proxy.load(path) else { return nil }
            return ImageDecoding.decode(data, maxPixelSize: maxPx)
        }.value
        if let decoded {
            ImageMemoryCache.shared.store(decoded, for: cacheKey)
            image = decoded
        } else {
            failed = true
        }
    }
}

enum ImageDecoding {
    /// ImageIO downsampling decode; cheaper than UIImage(data:) for large files.
    static func decode(_ data: Data, maxPixelSize: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }
}
