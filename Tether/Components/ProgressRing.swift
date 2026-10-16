import SwiftUI

/// Clockwise download ring. When `completed` flips true the ring flashes `ok`
/// and fades out, so the thumbnail can settle underneath it.
struct ProgressRing: View {
    /// nil = indeterminate
    var progress: Double?
    var completed = false
    var lineWidth: CGFloat = 3

    @State private var spin = false
    @State private var flashed = false
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(TetherColor.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(flashed ? TetherColor.ok : TetherColor.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .animation(progress == nil && !completed ? .linear(duration: 1).repeatForever(autoreverses: false) : nil, value: spin)
                .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: progress)
        }
        .opacity(faded ? 0 : 1)
        .onAppear { if progress == nil, !completed { spin = true } }
        .onChange(of: completed) { _, done in if done { finish() } }
        .accessibilityLabel(accessibilityText)
    }

    private var trimEnd: Double {
        if completed { return 1 }
        return progress.map { max(0.02, min(1, $0)) } ?? 0.3
    }

    private var accessibilityText: String {
        if completed { return "Downloaded" }
        return progress.map { "Downloading, \(Int($0 * 100)) percent" } ?? "Downloading"
    }

    /// Flash to ok, then fade: two short steps so the eye catches the "landed" beat.
    private func finish() {
        spin = false
        withAnimation(.easeOut(duration: 0.12)) { flashed = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 250_000_000 : 350_000_000)
            withAnimation(.easeOut(duration: reduceMotion ? 0.16 : 0.3)) { faded = true }
        }
    }
}
