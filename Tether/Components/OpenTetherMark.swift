import SwiftUI

/// The Open Tether mark: the capture ring left open at the top right, its end
/// running on as a cable to a connector dot, and the shutter disc inside.
/// SwiftUI only (no UIKit) so `scripts/render-app-icon.swift` can draw the
/// app icon from this same file on macOS.
///
/// Each part takes a 0…1 progress so the splash can draw it in.
struct OpenTetherMark: View, Animatable {
    var ring: CGFloat = 1
    var cable: CGFloat = 1
    var disc: CGFloat = 1
    var ringColor: Color
    var cableColor: Color
    var discColor: Color

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(ring, AnimatablePair(cable, disc)) }
        set { ring = newValue.first; cable = newValue.second.first; disc = newValue.second.second }
    }

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
            let line = s * OpenTetherMark.lineWidth

            // Ring: clockwise from the lower edge of the opening round to the top,
            // where it leaves as the cable.
            let c = p(OpenTetherMark.center.x, OpenTetherMark.center.y)
            let r = OpenTetherMark.radius * s
            let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
            if ring > 0 {
                let start = Angle.degrees(OpenTetherMark.openingDegrees)
                let sweep = (270 - OpenTetherMark.openingDegrees) * Double(ring)
                var path = Path()
                path.addArc(center: c, radius: r, startAngle: start, endAngle: start + .degrees(sweep), clockwise: false)
                context.stroke(path, with: .color(ringColor), style: style)
            }

            // Cable: carries on from the top of the ring along its tangent, out
            // through the opening to the connector dot.
            if cable > 0 {
                let top = CGPoint(x: c.x, y: c.y - r)
                let end = p(OpenTetherMark.plug.x, OpenTetherMark.plug.y)
                var path = Path()
                path.move(to: top)
                path.addCurve(to: end, control1: CGPoint(x: top.x + 0.20 * s, y: top.y),
                              control2: CGPoint(x: end.x - 0.16 * s, y: end.y))
                context.stroke(path.trimmedPath(from: 0, to: cable), with: .color(cableColor), style: style)
                let dot = OpenTetherMark.plugRadius * s * max(0, min(1, (cable - 0.85) / 0.15))
                if dot > 0 {
                    context.fill(Path(ellipseIn: CGRect(x: end.x - dot, y: end.y - dot, width: dot * 2, height: dot * 2)),
                                 with: .color(cableColor))
                }
            }

            // Shutter disc.
            if disc > 0 {
                let d = OpenTetherMark.discRadius * s * disc
                context.fill(Path(ellipseIn: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)), with: .color(discColor))
            }
        }
        .accessibilityHidden(true)
    }

    static let center = CGPoint(x: 0.42, y: 0.58)
    static let radius: CGFloat = 0.30
    static let discRadius: CGFloat = 0.185
    /// The ring starts here (degrees, clockwise from 3 o'clock) and runs round to 12 o'clock.
    static let openingDegrees: Double = -28
    static let plug = CGPoint(x: 0.83, y: 0.19)
    static let plugRadius: CGFloat = 0.06
    static let lineWidth: CGFloat = 0.075
}
