import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TetherCore
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Applies a `CubeLUT` with CIColorCube (developing RAW first when asked)
/// and writes JPEG, HEIF or TIFF. Serves both the on-screen canvas (`LookRendering`) and the
/// export queue (`ExportRenderer`).
final class CoreImageLookRenderer: LookRendering, ExportRenderer, @unchecked Sendable {
    private let context: CIContext

    init() {
        context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    }

    // MARK: LookRendering

    func render(image: Data, look: CubeLUT?, strength: Double, maxPixelSize: Int?) async throws -> Data {
        let output = try renderImage(data: image, look: look, strength: strength, maxPixelSize: maxPixelSize)
        guard let jpeg = output.jpegData(compressionQuality: 0.92) else { throw ExportError.renderFailed("JPEG encode failed") }
        return jpeg
    }

    /// UIImage variant for the canvas so the view skips a JPEG round-trip.
    func renderImage(data: Data, look: CubeLUT?, strength: Double, maxPixelSize: Int?,
                     rawFilenameHint: String? = nil) throws -> UIImage {
        guard var ci = Self.decode(data, rawFilenameHint: rawFilenameHint) else {
            throw ExportError.renderFailed("Could not decode image")
        }
        if let maxPixelSize, maxPixelSize > 0 {
            let longEdge = max(ci.extent.width, ci.extent.height)
            if longEdge > CGFloat(maxPixelSize) {
                let scale = CGFloat(maxPixelSize) / longEdge
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        if let look, strength > 0 {
            let lut = strength < 1 ? look.blended(strength: Float(strength)) : look
            let filter = CIFilter.colorCube()
            filter.inputImage = ci
            filter.cubeDimension = Float(lut.size)
            filter.cubeData = lut.colorCubeData
            if let out = filter.outputImage { ci = out }
        }
        let extent = ci.extent.integral
        guard let cg = context.createCGImage(ci, from: extent) else { throw ExportError.renderFailed("Core Image render failed") }
        return UIImage(cgImage: cg)
    }

    /// RAW goes through the system RAW engine (full demosaic, the camera's
    /// as-shot white balance and lens profile); everything else decodes as is.
    private static func decode(_ data: Data, rawFilenameHint: String?) -> CIImage? {
        if let hint = rawFilenameHint {
            let ext = (hint as NSString).pathExtension
            let filter = CIRAWFilter(imageData: data, identifierHint: UTType(filenameExtension: ext)?.identifier)
            if let out = filter?.outputImage { return out }
        }
        return CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    // MARK: ExportRenderer

    func render(original: URL, item: ExportJob.Item, look: CubeLUT?, options: ExportOptions) async throws -> URL {
        // Untouched JPEG and HEIF go out byte-for-byte.
        if look == nil && options.maxLongEdge == nil && (item.kind == .jpeg || item.kind == .heif) {
            return original
        }
        let data = try Data(contentsOf: original)
        let isRAW = item.kind == .raw
        let image = try renderImage(data: data, look: look, strength: 1, maxPixelSize: options.maxLongEdge,
                                    rawFilenameHint: isRAW ? item.filename : nil)
        let quality = CGFloat(max(0.3, min(1, options.jpegQuality)))
        // The delivered extension always matches the bytes: HEIF stays HEIF;
        // developed RAW becomes what the export asked for.
        let format: RAWOutput = isRAW ? options.rawOutput : (item.kind == .heif ? .heif : .jpeg)
        let encoded: Data?
        switch format {
        case .heif: encoded = image.heicData()
        case .tiff16: encoded = Self.tiff16(image)
        case .jpeg, .original: encoded = image.jpegData(compressionQuality: quality)
        }
        guard let jpeg = encoded else { throw ExportError.renderFailed("Image encode failed") }
        let ext = "." + (format.fileExtension ?? "jpg")
        let name = ((options.filenamePrefix ?? "") + (item.filename as NSString).deletingPathExtension) + ext
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-export-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        return url
    }

    /// 16 bits per channel, Display P3, uncompressed: the hand-off format for retouchers.
    private static func tiff16(_ image: UIImage) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let width = cg.width, height = cg.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let deep = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, deep, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
