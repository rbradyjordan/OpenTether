import CoreGraphics
import Foundation

/// Pure geometry for the library grid: zoom levels, pinch mapping and the
/// index maths behind drag-to-range-select. Kept free of SwiftUI so it is
/// unit-tested.
enum GridMath {
    static let columnRange: ClosedRange<Int> = 2 ... 6
    static let spacing: CGFloat = 2

    static func clampColumns(_ n: Int) -> Int {
        min(columnRange.upperBound, max(columnRange.lowerBound, n))
    }

    /// Pinching out (scale > 1) shows fewer, larger tiles.
    static func columns(afterPinch scale: CGFloat, from base: Int) -> Int {
        guard scale > 0, scale.isFinite else { return clampColumns(base) }
        return clampColumns(Int((Double(base) / Double(scale)).rounded()))
    }

    /// The zoom level is "columns on a phone"; wider screens show
    /// proportionally more so tiles stay about the same size (iPad, Split View).
    static let phoneWidth: CGFloat = 400

    static func displayColumns(zoom: Int, width: CGFloat) -> Int {
        guard width > phoneWidth * 1.5 else { return max(1, zoom) }
        return max(zoom, Int((CGFloat(zoom) * width / phoneWidth).rounded()))
    }

    static func tileSide(width: CGFloat, columns: Int, spacing: CGFloat = GridMath.spacing) -> CGFloat {
        let cols = max(1, columns)
        return max(0, (width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
    }

    /// Which tile a point in grid coordinates lands on; nil outside the grid.
    static func index(at point: CGPoint, width: CGFloat, columns: Int, count: Int, spacing: CGFloat = GridMath.spacing) -> Int? {
        guard count > 0, columns > 0, point.x >= 0, point.y >= 0, point.x <= width else { return nil }
        let pitch = tileSide(width: width, columns: columns, spacing: spacing) + spacing
        guard pitch > 0 else { return nil }
        let col = min(columns - 1, Int(point.x / pitch))
        let row = Int(point.y / pitch)
        let i = row * columns + col
        return i < count ? i : nil
    }

    /// Inclusive range between two tile indices in either direction.
    static func range(from a: Int, to b: Int) -> ClosedRange<Int> {
        min(a, b) ... max(a, b)
    }

    /// Zoom menu labels: "2 per row" … "6 per row".
    static func zoomTitle(_ columns: Int) -> String { "\(columns) per row" }
}
