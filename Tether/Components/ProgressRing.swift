import SwiftUI

struct ProgressRing: View {
    /// nil = indeterminate
    var progress: Double?
    var lineWidth: CGFloat = 3

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress.map { max(0.02, min(1, $0)) } ?? 0.3)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .animation(progress == nil ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spin)
        }
        .onAppear { if progress == nil { spin = true } }
        .accessibilityLabel(progress.map { "Downloading, \(Int($0 * 100)) percent" } ?? "Downloading")
    }
}
