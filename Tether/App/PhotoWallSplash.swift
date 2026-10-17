import SwiftUI

/// iPhone launch: a wall of the author's photographs in staggered
/// columns that drift slowly in opposite directions, darkened toward the
/// middle, with the icon and wordmark on a glass plate. Photos fade in one
/// after another. Under Reduce Motion the wall is still and simply fades in.
struct PhotoWallSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    /// 0…1: how much of the wall has faded in.
    @State private var revealed: Double = 0
    @State private var plateIn = false

    static let introDuration: Duration = .milliseconds(2600)
    static let photos = (1 ... 18).map { String(format: "SplashPhotos/photo%02d", $0) }

    /// Column count follows the width so tiles stay a similar size.
    private func columns(for width: CGFloat) -> Int { max(3, min(7, Int((width / 220).rounded()))) }

    var body: some View {
        GeometryReader { geo in
            let cols = columns(for: geo.size.width)
            let gap: CGFloat = 6
            let colWidth = (geo.size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
            ZStack {
                Color.black
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let t = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0 ..< cols, id: \.self) { col in
                            column(col, of: cols, width: colWidth, gap: gap, height: geo.size.height)
                                // Alternate columns drift up and down, ~14 pt/s.
                                .offset(y: -geo.size.height * 0.25 + CGFloat(col.isMultiple(of: 2) ? 1 : -1) * CGFloat(t) * 14)
                        }
                    }
                    .padding(.horizontal, gap)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                // Darken toward the centre so the plate reads; keep the edges lively.
                RadialGradient(colors: [.black.opacity(0.62), .black.opacity(0.18), .clear],
                               center: .center, startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.55)
                LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                plate
                    .opacity(plateIn ? 1 : 0)
                    .scaleEffect(plateIn || reduceMotion ? 1 : 0.94)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open Tether")
        .accessibilityAddTraits(.isHeader)
        .task { await play() }
    }

    /// One column: photos at their own aspect ratio, starting at a
    /// different photo per column so neighbours never repeat.
    private func column(_ col: Int, of cols: Int, width: CGFloat, gap: CGFloat, height: CGFloat) -> some View {
        // Enough tiles to cover the screen plus the drift and the start offset.
        let rows = Int((height * 1.9) / (width * 0.87 + gap)) + 2
        return VStack(spacing: gap) {
            ForEach(0 ..< rows, id: \.self) { row in
                let index = (col * 5 + row * 3) % Self.photos.count
                // Scattered reveal order, so the whole wall fills at once.
                let threshold = Double((row * 37 + col * 61 + index * 13) % 97) / 97
                Image(Self.photos[index])
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: width * (row.isMultiple(of: 3) ? 1.25 : 0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .opacity(threshold < revealed ? 1 : 0)
                    .animation(.easeOut(duration: 0.45), value: revealed)
            }
        }
        .frame(width: width)
    }

    private var plate: some View {
        VStack(spacing: TetherSpace.m) {
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 96, height: 96)
            Text("Open Tether")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, TetherColor.steel], startPoint: .top, endPoint: .bottom))
            Text("Tethered capture, wherever you shoot")
                .font(TetherFont.callout)
                .foregroundStyle(TetherColor.ink1)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .tetherGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }

    private func play() async {
        start = Date()
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { revealed = 1.01; plateIn = true }
            return
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.15)) { plateIn = true }
        // Tiles pop in all over the wall over ~0.6 s.
        for step in 1 ... 12 {
            try? await Task.sleep(for: .milliseconds(50))
            revealed = Double(step) / 12 + 0.01
        }
    }
}

#Preview { PhotoWallSplash() }
