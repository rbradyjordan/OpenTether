import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TetherCore
import UIKit

/// Applies a `CubeLUT` with CIColorCube, optionally stamps a watermark, and
/// writes JPEG. Serves both the on-screen canvas (`LookRendering`) and the
/// export queue (`ExportRenderer`).
final class CoreImageLookRenderer: LookRendering, ExportRenderer, @unchecked Sendable {
    private let context: CIContext
    private let watermarkText = "TETHER"

    init() {
        context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    }

    // MARK: LookRendering

    func render(image: Data, look: CubeLUT?, strength: Double, maxPixelSize: Int?) async throws -> Data {
        let output = try renderImage(data: image, look: look, strength: strength, maxPixelSize: maxPixelSize, watermark: false)
        guard let jpeg = output.jpegData(compressionQuality: 0.92) else { throw ExportError.renderFailed("JPEG encode failed") }
        return jpeg
    }

    /// UIImage variant for the canvas so the view skips a JPEG round-trip.
    func renderImage(data: Data, look: CubeLUT?, strength: Double, maxPixelSize: Int?, watermark: Bool) throws -> UIImage {
        guard var ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
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
        let base = UIImage(cgImage: cg)
        return watermark ? stamp(base) : base
    }

    // MARK: ExportRenderer

    func render(original: URL, item: ExportJob.Item, look: CubeLUT?, options: ExportOptions) async throws -> URL {
        if look == nil && !options.watermark && options.maxLongEdge == nil && item.kind == .jpeg {
            return original
        }
        let data = try Data(contentsOf: original)
        let image = try renderImage(data: data, look: look, strength: 1, maxPixelSize: options.maxLongEdge, watermark: options.watermark)
        guard let jpeg = image.jpegData(compressionQuality: CGFloat(max(0.3, min(1, options.jpegQuality)))) else {
            throw ExportError.renderFailed("JPEG encode failed")
        }
        let name = ((options.filenamePrefix ?? "") + (item.filename as NSString).deletingPathExtension) + ".jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-export-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        return url
    }

    // MARK: Watermark

    /// Translucent "TETHER" bottom-right, sized relative to the long edge.
    private func stamp(_ image: UIImage) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            let fontSize = max(14, min(size.width, size.height) * 0.045)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.45),
                .kern: fontSize * 0.18,
            ]
            let text = NSAttributedString(string: watermarkText, attributes: attrs)
            let textSize = text.size()
            let margin = fontSize * 0.8
            let origin = CGPoint(x: size.width - textSize.width - margin, y: size.height - textSize.height - margin)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: fontSize * 0.15, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            text.draw(at: origin)
        }
    }
}
