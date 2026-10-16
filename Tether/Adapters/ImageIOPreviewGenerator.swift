import Foundation
import ImageIO
import TetherCore
import UniformTypeIdentifiers

/// Decodes JPEG/HEIF/RAW with ImageIO. For RAW the embedded preview (or a
/// quick thumbnail when none is embedded) becomes the proxy, so the canvas
/// never waits for a full RAW demosaic.
struct ImageIOPreviewGenerator: PreviewGenerating {
    var proxyMaxPixels: Int = 2048
    var thumbnailMaxPixels: Int = 320
    var proxyQuality: Double = 0.9

    func makePreviews(original: Data, kind: MediaKind, filename: String) async -> PreviewOutput {
        guard kind.isStill else { return PreviewOutput() }
        let data = original
        let proxyMax = proxyMaxPixels
        let thumbMax = thumbnailMaxPixels
        let quality = proxyQuality
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return PreviewOutput() }
            var width = 0, height = 0
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
                height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
                if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                    swap(&width, &height)
                }
            }
            let proxy = Self.thumbnail(source, maxPixels: proxyMax).flatMap { Self.jpeg($0, quality: quality) }
            let thumb = Self.thumbnail(source, maxPixels: thumbMax).flatMap { Self.jpeg($0, quality: 0.8) }
            return PreviewOutput(proxyJPEG: proxy, thumbnailJPEG: thumb, width: width, height: height)
        }.value
    }

    private static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
