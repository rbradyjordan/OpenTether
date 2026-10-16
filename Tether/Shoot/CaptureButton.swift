import SwiftUI

/// Tap = capture with AF. Long-press = capture without AF.
struct CaptureButton: View {
    var enabled: Bool
    var busy: Bool
    var onCapture: (_ autofocus: Bool) -> Void

    @State private var pressing = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.textSecondary, lineWidth: 3).frame(width: 66, height: 66)
            Circle().fill(enabled ? Color.white : Theme.textSecondary.opacity(0.4))
                .frame(width: pressing ? 48 : 54, height: pressing ? 48 : 54)
            if busy { ProgressView().tint(.black) }
        }
        .contentShape(Circle())
        .onTapGesture { if enabled { onCapture(true) } }
        .onLongPressGesture(minimumDuration: 0.45, pressing: { pressing = $0 }) {
            if enabled { onCapture(false) }
        }
        .animation(.easeOut(duration: 0.12), value: pressing)
        .accessibilityLabel("Shutter")
        .accessibilityHint("Double tap to capture with autofocus. Hold to capture without autofocus.")
        .accessibilityAddTraits(.isButton)
        .opacity(enabled ? 1 : 0.6)
    }
}
