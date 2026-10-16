import SwiftUI

struct ToastMessage: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var systemImage: String?
    var action: String?
}

struct ToastView: View {
    var toast: ToastMessage
    var onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: TetherSpace.m) {
            if let systemImage = toast.systemImage {
                Image(systemName: systemImage).foregroundStyle(TetherColor.accent)
            }
            Text(toast.text).font(TetherFont.callout).foregroundStyle(TetherColor.ink0).lineLimit(2)
            if let action = toast.action, let onAction {
                Button(action, action: onAction)
                    .font(TetherFont.callout.weight(.semibold))
                    .tint(TetherColor.accent)
                    .frame(minHeight: TetherHit.min)
            }
        }
        .padding(.horizontal, TetherSpace.l)
        .padding(.vertical, TetherSpace.m)
        .background(TetherColor.surface3, in: Capsule())
        .overlay(Capsule().strokeBorder(TetherColor.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func toast(_ toast: Binding<ToastMessage?>, onAction: (() -> Void)? = nil) -> some View {
        modifier(ToastHost(toast: toast, onAction: onAction))
    }
}

private struct ToastHost: ViewModifier {
    @Binding var toast: ToastMessage?
    var onAction: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = toast {
                ToastView(toast: t, onAction: onAction)
                    .padding(.top, TetherSpace.s)
                    .padding(.horizontal, TetherSpace.l)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: t.id) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if toast?.id == t.id {
                            withAnimation(Motion.spring(TetherMotion.settle, reduce: reduceMotion)) { toast = nil }
                        }
                    }
            }
        }
        .animation(Motion.spring(TetherMotion.arrive, reduce: reduceMotion), value: toast)
    }
}
