import SwiftUI

/// iPad / Mac launch, after Lightroom's splash but dark: a wide graphite card
/// with the name, copyright and a status line on the left and one of the
/// author's photographs inset on the right (a different one each launch),
/// floating over a dimmed mosaic of the other photographs, with the company
/// name below. Under Reduce Motion it simply fades in.
struct CardSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backdropIn = false
    @State private var cardIn = false
    @State private var status = Self.steps[0]
    @State private var hero = PhotoWallSplash.photos.randomElement() ?? PhotoWallSplash.photos[0]

    static let introDuration: Duration = .milliseconds(2400)
    private static let steps = ["Reading preferences…", "Opening the library…", "Loading looks…", "Looking for cameras…"]

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return v.isEmpty ? "" : "Version \(v)"
    }

    /// Every photograph except the one on the card.
    private var others: [String] { PhotoWallSplash.photos.filter { $0 != hero } }

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 80, 880)
            let height = width * 0.52
            ZStack {
                Color.black
                mosaic(in: geo.size)
                    .opacity(backdropIn ? 1 : 0)
                // Dim the mosaic, most of all behind the card.
                RadialGradient(colors: [.black.opacity(0.82), .black.opacity(0.62)],
                               center: .center, startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.6)
                VStack(spacing: 28) {
                    card(width: width, height: height)
                    Text("CalendTree")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .opacity(cardIn ? 1 : 0)
                .scaleEffect(cardIn || reduceMotion ? 1 : 0.97)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open Tether, \(status)")
        .accessibilityAddTraits(.isHeader)
        .task { await play() }
    }

    // MARK: Card

    private func card(width: CGFloat, height: CGFloat) -> some View {
        let inset: CGFloat = 12
        return HStack(spacing: 0) {
            textPanel
                .frame(width: width * 0.42, height: height, alignment: .topLeading)
            Image(hero)
                .resizable()
                .scaledToFill()
                .frame(width: width * 0.58 - inset, height: height - inset * 2)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.trailing, inset)
        }
        .frame(width: width, height: height)
        .background(TetherColor.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TetherColor.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.7), radius: 40, y: 18)
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image("BrandIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 46, height: 46)
                Text("Open Tether")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(TetherColor.ink0)
            }
            .padding(.bottom, 22)
            Text("© 2026 CalendTree, LLC. All rights reserved.")
                .padding(.bottom, 10)
            Text("Free and local: no account, no servers, no tracking. Your photographs stay on this device until you export them.")
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            Text(status)
                .foregroundStyle(TetherColor.ink1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: status)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TetherColor.accent)
                Text("Tethered capture, wherever you shoot")
                    .foregroundStyle(TetherColor.ink1)
                Spacer(minLength: 0)
            }
            Text(version)
                .padding(.top, 6)
        }
        .font(.system(size: 12))
        .foregroundStyle(TetherColor.ink2)
        .padding(26)
    }

    // MARK: Backdrop

    /// The other photographs in staggered columns, filling the screen.
    private func mosaic(in size: CGSize) -> some View {
        let cols = max(4, min(8, Int((size.width / 200).rounded())))
        let gap: CGFloat = 6
        let colWidth = (size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let rows = Int((size.height * 1.3) / (colWidth * 0.87 + gap)) + 2
        let pool = others
        return HStack(alignment: .top, spacing: gap) {
            ForEach(0 ..< cols, id: \.self) { col in
                VStack(spacing: gap) {
                    ForEach(0 ..< rows, id: \.self) { row in
                        Image(pool[(col * 5 + row * 3) % pool.count])
                            .resizable()
                            .scaledToFill()
                            .frame(width: colWidth, height: colWidth * (row.isMultiple(of: 3) ? 1.25 : 0.68))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                // Stagger the columns like a contact wall.
                .offset(y: col.isMultiple(of: 2) ? -colWidth * 0.4 : -colWidth * 0.1)
            }
        }
        .padding(.horizontal, gap)
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .blur(radius: 1.5)
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { backdropIn = true; cardIn = true }
        } else {
            withAnimation(.easeOut(duration: 0.6)) { backdropIn = true }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(0.12)) { cardIn = true }
        }
        for step in Self.steps {
            status = step
            try? await Task.sleep(for: .milliseconds(520))
        }
    }
}

#Preview { CardSplash() }
