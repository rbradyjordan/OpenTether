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
/// Fades in on load; the placeholder shimmers unless Reduce Motion is on.
struct AsyncImageView: View {
    let cache: CaptureCacheProxy
    var relativePath: String?
    var contentMode: ContentMode = .fit
    /// Optional downsampled decode size (points); nil = full decode.
    var maxPixelSize: Int?

    @State private var image: UIImage?
    @State private var failed = false
    @State private var fromMemory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(fromMemory ? .identity : .opacity)
            } else if failed || relativePath == nil {
                Rectangle().fill(TetherColor.surface3)
                    .overlay(Image(systemName: "photo").foregroundStyle(TetherColor.ink2))
                    .accessibilityLabel(failed ? "Image unavailable" : "No image")
            } else {
                ShimmerPlaceholder()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: image == nil)
        .task(id: cacheKey) { await load() }
    }

    private var cacheKey: String { "\(relativePath ?? "-")#\(maxPixelSize ?? 0)" }

    private func load() async {
        guard let relativePath else { return }
        if let hit = ImageMemoryCache.shared.image(for: cacheKey) {
            fromMemory = true
            image = hit
            return
        }
        fromMemory = false
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

/// Surface-coloured block with a slow highlight sweep. Static under Reduce Motion.
struct ShimmerPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Rectangle().fill(TetherColor.surface2)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Rectangle()
                    .fill(TetherColor.surface2)
                    .overlay(
                        LinearGradient(
                            colors: [.clear, TetherColor.surface3.opacity(0.9), .clear],
                            startPoint: UnitPoint(x: t * 2 - 1, y: 0.5),
                            endPoint: UnitPoint(x: t * 2, y: 0.5)
                        )
                    )
            }
            .accessibilityHidden(true)
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
