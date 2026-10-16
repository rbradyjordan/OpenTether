import Foundation
import ImageIO
import TetherCore
import UniformTypeIdentifiers

/// Decodes JPEG/HEIF/RAW with ImageIO. For RAW the embedded preview becomes
/// the proxy, so the canvas never waits for a full RAW demosaic, unless the
/// embedded preview is small (some bodies embed ~1 MP), in which case the RAW
/// is decoded properly. The proxy keeps the original's EXIF/TIFF/GPS so the
/// inspector shows camera facts for RAW too.
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
            var proxyImage = Self.thumbnail(source, maxPixels: proxyMax)
            if kind == .raw, let p = proxyImage, max(p.width, p.height) < proxyMax * 6 / 10,
               let decoded = Self.thumbnail(source, maxPixels: proxyMax, decodeFull: true) {
                proxyImage = decoded
            }
            let metadata = Self.carriedMetadata(source)
            let proxy = proxyImage.flatMap { Self.jpeg($0, quality: quality, metadata: metadata) }
            let thumb = Self.thumbnail(source, maxPixels: thumbMax).flatMap { Self.jpeg($0, quality: 0.8) }
            return PreviewOutput(proxyJPEG: proxy, thumbnailJPEG: thumb, width: width, height: height)
        }.value
    }

    private static func thumbnail(_ source: CGImageSource, maxPixels: Int, decodeFull: Bool = false) -> CGImage? {
        let options: [CFString: Any] = [
            decodeFull ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// EXIF, TIFF, GPS and maker dictionaries from the original, with the
    /// orientation reset (the thumbnail is already rotated upright).
    private static func carriedMetadata(_ source: CGImageSource) -> [CFString: Any] {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyExifAuxDictionary] {
            if let value = props[key] { out[key] = value }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        out[kCGImagePropertyOrientation] = 1
        return out
    }

    static func jpeg(_ image: CGImage, quality: Double, metadata: [CFString: Any] = [:]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var options = metadata
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
