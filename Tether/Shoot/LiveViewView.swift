import SwiftUI
import UIKit

struct LiveViewView: View {
    var image: UIImage?
    /// Last focus tap (0…1 of the frame) and a counter that restarts the box animation.
    var focusPoint: CGPoint? = nil
    var focusPointID = 0
    /// Set when the body supports touch AF; called with 0…1 of the frame.
    var onFocus: ((CGPoint) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TetherColor.surface0
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    if let focusPoint {
                        let frame = Self.fittedRect(image.size, in: geo.size)
                        FocusBox()
                            .id(focusPointID)
                            .position(x: frame.minX + focusPoint.x * frame.width,
                                      y: frame.minY + focusPoint.y * frame.height)
                    }
                } else {
                    VStack(spacing: TetherSpace.s) {
                        ProgressView().tint(TetherColor.ink1)
                        Text("Waiting for live view…").font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                    }
                }
                VStack {
                    HStack {
                        TonePill(text: "LIVE", tone: .danger, systemImage: "circle.fill")
                        Spacer()
                        if onFocus != nil, image != nil {
                            Text("Tap to focus").font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
                        }
                    }
                    .padding(TetherSpace.m)
                    Spacer()
                }
                .overlayTypeCap()
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard let onFocus, let image else { return }
                let frame = Self.fittedRect(image.size, in: geo.size)
                guard frame.contains(location), frame.width > 0, frame.height > 0 else { return }
                onFocus(CGPoint(x: (location.x - frame.minX) / frame.width, y: (location.y - frame.minY) / frame.height))
            }
        }
        .accessibilityLabel("Live view from the camera")
        .accessibilityHint(onFocus == nil ? "" : "Tap a point to focus there")
    }

    /// The aspect-fit rect of an image of `size` inside `container`.
    static func fittedRect(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

/// The AF box: lands slightly large, settles, then fades back.
private struct FocusBox: View {
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(TetherColor.accent, lineWidth: 2)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.35)
            .opacity(settled ? 0.85 : 1)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { settled = true } }
            .allowsHitTesting(false)
    }
}
