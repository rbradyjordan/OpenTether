import SwiftUI
import UIKit

struct LiveViewView: View {
    var image: UIImage?
    /// Last focus tap (0…1 of the frame) and a counter that restarts the box animation.
    var focusPoint: CGPoint? = nil
    var focusPointID = 0
    /// The camera's verdict on the last touch, shown on the AF box.
    var focusIndicator: ShootViewModel.FocusIndicator = .focusing
    /// Live view was asked for and the first frame hasn't arrived yet.
    var isStarting = false
    /// Thirds grid with centre lines: straight verticals are the first rule
    /// of interiors, and the centre line shows a tilted camera at once.
    var showGrid = false
    /// Set when the body supports touch AF; called with 0…1 of the frame.
    var onFocus: ((CGPoint) -> Void)? = nil
    /// Press and hold: AF tracks until the finger lifts.
    var onHoldStart: ((CGPoint) -> Void)? = nil
    var onHoldEnd: (() -> Void)? = nil

    @State private var touchStart: Date?
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?

    /// How long a press must last to count as hold-to-track.
    private static let holdDelay: Double = 0.45

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TetherColor.surface0
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    if showGrid {
                        GridOverlay(frame: Self.fittedRect(image.size, in: geo.size))
                    }
                    if let focusPoint {
                        let frame = Self.fittedRect(image.size, in: geo.size)
                        FocusBox(indicator: focusIndicator)
                            .id(focusPointID)
                            .position(x: frame.minX + focusPoint.x * frame.width,
                                      y: frame.minY + focusPoint.y * frame.height)
                    }
                } else {
                    VStack(spacing: TetherSpace.s) {
                        ProgressView().tint(TetherColor.ink1)
                        Text(isStarting ? "Starting live view…" : "Waiting for live view…").font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                    }
                }
                VStack {
                    HStack {
                        TonePill(text: "LIVE", tone: .danger, systemImage: "circle.fill")
                        Spacer()
                        if onFocus != nil, image != nil {
                            Text(holding ? "Tracking, lift to stop" : "Tap to focus · hold to track")
                                .font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
                        }
                    }
                    .padding(TetherSpace.m)
                    Spacer()
                }
                .overlayTypeCap()
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard touchStart == nil else { return }
                        touchStart = Date()
                        guard let point = normalized(value.startLocation, in: geo.size), let onHoldStart else { return }
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(Self.holdDelay * 1_000_000_000))
                            guard !Task.isCancelled, touchStart != nil else { return }
                            holding = true
                            onHoldStart(point)
                        }
                    }
                    .onEnded { value in
                        holdTask?.cancel()
                        holdTask = nil
                        touchStart = nil
                        if holding {
                            holding = false
                            onHoldEnd?()
                        } else if let point = normalized(value.startLocation, in: geo.size) {
                            onFocus?(point)
                        }
                    },
                including: onFocus == nil ? .subviews : .all
            )
        }
        .accessibilityLabel("Live view from the camera")
        .accessibilityHint(onFocus == nil ? "" : "Tap a point to focus there; touch and hold to keep focusing")
    }

    /// 0…1 of the frame, or nil outside the picture.
    private func normalized(_ location: CGPoint, in size: CGSize) -> CGPoint? {
        guard let image else { return nil }
        let frame = Self.fittedRect(image.size, in: size)
        guard frame.contains(location), frame.width > 0, frame.height > 0 else { return nil }
        return CGPoint(x: (location.x - frame.minX) / frame.width, y: (location.y - frame.minY) / frame.height)
    }

    /// The aspect-fit rect of an image of `size` inside `container`.
    static func fittedRect(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

/// The AF box, in Canon's own colours: pulses while the camera works,
/// green when it reports focus, red when AF fails, then fades. While
/// tracking (press and hold) it stays up.
private struct FocusBox: View {
    var indicator: ShootViewModel.FocusIndicator
    @State private var settled = false
    @State private var pulse = false
    @State private var gone = false

    private var color: Color {
        switch indicator {
        case .focused: return TetherColor.ok
        case .failed: return TetherColor.danger
        default: return TetherColor.accent
        }
    }

    private var pulsing: Bool { indicator == .focusing || indicator == .tracking }

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(color, lineWidth: indicator == .focused ? 3 : 2)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? (indicator == .focused ? 0.92 : 1) : 1.35)
            .opacity(gone ? 0 : (pulsing && pulse ? 0.45 : 1))
            .shadow(color: .black.opacity(0.4), radius: 3)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: indicator)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { settled = true }
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pulse = true }
            }
            .task(id: indicator) {
                guard !pulsing else { gone = false; return }
                try? await Task.sleep(nanoseconds: indicator == .unconfirmed ? 400_000_000 : 900_000_000)
                withAnimation(.easeOut(duration: 0.35)) { gone = true }
            }
            .accessibilityHidden(true)
    }
}

/// Thirds in white, centre lines in the accent, drawn over the fitted frame.
private struct GridOverlay: View {
    var frame: CGRect

    var body: some View {
        Canvas { ctx, _ in
            var thirds = Path()
            for i in 1 ... 2 {
                let x = frame.minX + frame.width * CGFloat(i) / 3
                let y = frame.minY + frame.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: frame.minY)); thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
                thirds.move(to: CGPoint(x: frame.minX, y: y)); thirds.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            ctx.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 1)
            var centre = Path()
            centre.move(to: CGPoint(x: frame.midX, y: frame.minY)); centre.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            centre.move(to: CGPoint(x: frame.minX, y: frame.midY)); centre.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            ctx.stroke(centre, with: .color(TetherColor.accent.opacity(0.8)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
