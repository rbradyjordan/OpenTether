import SwiftUI
import TetherCore
import UIKit

/// Haptic detents for the strength slider at 0 / 50 / 100 %. Pure so the
/// snapping can be unit-tested.
enum LookStrengthDetent {
    static let stops: [Double] = [0, 0.5, 1]
    static let radius: Double = 0.03

    /// The value snapped onto a stop when within `radius`, and which stop hit.
    static func snap(_ value: Double) -> (value: Double, stop: Double?) {
        for stop in stops where abs(value - stop) <= radius { return (stop, stop) }
        return (value, nil)
    }
}

/// Three-column grid of look tiles rendered on the current frame's thumbnail,
/// plus a strength slider. Always dark.
struct LooksSheet: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var strength: Double = 1
    @State private var selectedID: String?
    @State private var refreshing = false
    @State private var lastStop: Double?
    @State private var detentTick = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: TetherSpace.s), count: 3)

    /// The frame every tile previews on.
    private var sampleThumb: String? {
        let item = model.displayedItem
        return item?.thumbnailRelativePath ?? item?.previewRelativePath
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TetherSpace.l) {
                    LazyVGrid(columns: columns, spacing: TetherSpace.s) {
                        LookTile(cache: model.renderCache, thumb: sampleThumb, lookID: nil, name: "None", family: "", hint: nil,
                                 selected: selectedID == nil) { choose(nil) }
                        ForEach(app.looks) { look in
                            LookTile(cache: model.renderCache, thumb: sampleThumb, lookID: look.id, name: look.name, family: look.family,
                                     hint: look.hint, selected: selectedID == look.id) { choose(look.id) }
                        }
                    }
                    if selectedID != nil { strengthControl }
                    Text("Looks apply to the canvas, new captures and exports with 'Apply look' on. Originals are never changed.")
                        .font(TetherFont.hud).foregroundStyle(TetherColor.ink2)
                    Button { model.sheet = .colorMatch } label: {
                        Label("AI colour match from a reference frame", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity, minHeight: TetherHit.min)
                    }
                    .buttonStyle(.bordered).tint(TetherColor.ink1)
                    .disabled(model.readyItems.isEmpty)
                }
                .padding(TetherSpace.l)
            }
            .background(TetherColor.surface1)
            .navigationTitle("Looks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refreshing = true
                        Task { await app.refreshCloud(); refreshing = false }
                    } label: { if refreshing { ProgressView() } else { Label("Refresh", systemImage: "arrow.clockwise") } }
                    .accessibilityLabel("Refresh looks from the cloud")
                }
            }
            .onAppear {
                selectedID = model.lookStack.lookID
                strength = model.lookStack.strength
            }
        }
        .forceDark()
        .tetherHaptic(.rate, trigger: detentTick)
        .presentationDetents([.medium, .large])
    }

    private var strengthControl: some View {
        VStack(alignment: .leading, spacing: TetherSpace.xs) {
            HStack {
                Text("Strength").tetherCaption().foregroundStyle(TetherColor.ink2)
                Spacer()
                Text("\(Int((strength * 100).rounded()))%")
                    .font(TetherFont.exposure).foregroundStyle(TetherColor.ink0)
                    .contentTransition(.numericText())
                    .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: strength)
            }
            Slider(value: $strength, in: 0 ... 1) { Text("Strength") }
                .tint(TetherColor.accent)
                .onChange(of: strength) { _, value in
                    let snapped = LookStrengthDetent.snap(value)
                    if let stop = snapped.stop {
                        if lastStop != stop { lastStop = stop; detentTick += 1 }
                        if snapped.value != value { strength = snapped.value; return }
                    } else {
                        lastStop = nil
                    }
                    apply()
                }
                .accessibilityValue("\(Int((strength * 100).rounded())) percent")
        }
        .padding(TetherSpace.l)
        .tetherCard()
    }

    private func choose(_ id: String?) {
        withAnimation(Motion.spring(TetherMotion.snap, reduce: reduceMotion)) { selectedID = id }
        apply()
    }

    private func apply() {
        model.setLook(LookStack(lookID: selectedID, strength: strength))
    }
}

/// One look on the current frame. Falls back to a hint gradient with no frame.
private struct LookTile: View {
    var cache: LookRenderCache
    var thumb: String?
    var lookID: String?
    var name: String
    var family: String
    var hint: LookDescriptor.Hint?
    var selected: Bool
    var action: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: TetherSpace.xs) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else if thumb != nil {
                        ShimmerPlaceholder()
                    } else {
                        swatch
                    }
                }
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: TetherRadius.chip, style: .continuous)
                        .strokeBorder(selected ? TetherColor.accent : TetherColor.hairline, lineWidth: selected ? 2 : 0.5)
                )
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white, TetherColor.accent)
                            .padding(TetherSpace.xs)
                    }
                }
                Text(name).font(TetherFont.hud).foregroundStyle(TetherColor.ink0).lineLimit(1)
                Text(family.isEmpty ? " " : family).tetherCaption().foregroundStyle(TetherColor.ink2).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: TetherHit.min)
        .task(id: "\(thumb ?? "-")|\(lookID ?? "-")") {
            guard let thumb else { image = nil; return }
            image = await cache.image(for: thumb, look: LookStack(lookID: lookID, strength: 1), maxPixelSize: 320)
        }
        .accessibilityLabel("\(name) look\(family.isEmpty ? "" : ", \(family)")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var swatch: LinearGradient {
        guard let hint else {
            return LinearGradient(colors: [TetherColor.surface3, TetherColor.surface2], startPoint: .top, endPoint: .bottom)
        }
        let warm = Color(hue: hint.warmth >= 0 ? 0.08 : 0.6, saturation: min(1, abs(hint.warmth) * 0.6 + 0.2), brightness: 0.8)
        let base = Color(white: 0.5 + hint.contrast * 0.2)
        return LinearGradient(colors: [warm, base], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
