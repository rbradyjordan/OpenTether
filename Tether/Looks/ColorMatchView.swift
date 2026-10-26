import ImageIO
import SwiftUI
import TetherCore

/// Pick a reference and a target frame from this session; the match is
/// computed on the phone (`ColorMatch`) and saved as a look.
struct ColorMatchView: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var referenceID: String?
    @State private var targetID: String?
    @State private var strength: Double = 0.8
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picker("Reference (the look you want)", $referenceID)
                    picker("Target (a frame from this session)", $targetID)
                    VStack(alignment: .leading) {
                        Text("Strength \(Int(strength * 100))%").font(.subheadline)
                        Slider(value: $strength, in: 0.1 ... 1, step: 0.05) { Text("Strength") }.tint(Theme.accent)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                    Button {
                        Task { await run() }
                    } label: {
                        Label(working ? "Matching…" : "Match and apply", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.tetherPrimary).controlSize(.large)
                    .disabled(working || referenceID == nil || targetID == nil || referenceID == targetID)
                }
                .padding(16)
            }
            .tetherScreen()
            .navigationTitle("Colour match")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                targetID = model.displayedItem?.id
                referenceID = model.readyItems.first { $0.id != targetID }?.id
            }
        }
    }

    private func picker(_ title: String, _ selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.readyItems) { item in
                        AsyncImageView(cache: model.renderCache.proxyCache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath, contentMode: .fill, maxPixelSize: 320)
                            .frame(width: 80, height: 80).clipped().cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.wrappedValue == item.id ? Theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { selection.wrappedValue = item.id }
                            .accessibilityLabel(item.filename)
                            .accessibilityAddTraits(selection.wrappedValue == item.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    private func run() async {
        guard let ref = model.items.first(where: { $0.id == referenceID })?.previewRelativePath,
              let tgt = model.items.first(where: { $0.id == targetID })?.previewRelativePath else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let refData = try app.cache.load(ref)
            let tgtData = try app.cache.load(tgt)
            let k = Float(strength)
            let cube: Data = try await Task.detached(priority: .userInitiated) {
                guard let refPixels = ColorSampler.samples(refData), let tgtPixels = ColorSampler.samples(tgtData) else {
                    throw ExportError.renderFailed("Could not read one of the frames")
                }
                return Data(ColorMatch.lut(reference: refPixels, target: tgtPixels, strength: k, title: "Colour match").serialized().utf8)
            }.value
            let id = "match.\(UUID().uuidString)"
            let descriptor = LookDescriptor(id: id, name: "Match \(Date().formatted(date: .omitted, time: .shortened))",
                                            family: "Colour match", size: 25, sha256: "", cubeURL: "local:\(id)")
            try app.store.saveLook(descriptor, cube: cube)
            app.reloadLooks()
            model.setLook(LookStack(lookID: descriptor.id, strength: 1))
            HapticFeedback.success()
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Downsamples a frame to 64 × 64 and returns its pixels as RGB in 0…1.
enum ColorSampler {
    static func samples(_ data: Data, side: Int = 64) -> [SIMD3<Float>]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 0, to: bytes.count, by: 4).map {
            SIMD3(Float(bytes[$0]) / 255, Float(bytes[$0 + 1]) / 255, Float(bytes[$0 + 2]) / 255)
        }
    }
}
