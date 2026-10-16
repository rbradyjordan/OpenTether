// Renders the Open Tether app icons (default, dark, tinted; 1024 pt) from
// the same `OpenTetherMark` the splash draws. Run on macOS from tether-ios/:
//
//   swiftc -parse-as-library scripts/render-app-icon.swift Tether/Components/OpenTetherMark.swift -o /tmp/render-app-icon
//   /tmp/render-app-icon Tether/Assets.xcassets/AppIcon.appiconset
import AppKit
import SwiftUI

private let accent = Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x2C / 255)

private struct IconView: View {
    enum Variant { case light, dark, tinted }
    var variant: Variant

    var body: some View {
        ZStack {
            switch variant {
            case .light:
                LinearGradient(colors: [Color(white: 0.11), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
            case .dark, .tinted:
                Color.clear
            }
            OpenTetherMark(ringColor: variant == .tinted ? .white : accent,
                           cableColor: variant == .tinted ? .white : accent,
                           discColor: variant == .tinted ? Color(white: 0.75) : .white)
                .frame(width: 720, height: 720)
        }
        .frame(width: 1024, height: 1024)
    }
}

@main
struct RenderAppIcon {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
        for (variant, name) in [(IconView.Variant.light, "AppIcon.png"), (.dark, "AppIcon-dark.png"), (.tinted, "AppIcon-tinted.png")] {
            let renderer = ImageRenderer(content: IconView(variant: variant))
            renderer.scale = 1
            renderer.isOpaque = variant == .light
            guard let cg = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: out.appendingPathComponent(name))
            print("wrote \(name) \(cg.width)×\(cg.height)")
        }
    }
}
