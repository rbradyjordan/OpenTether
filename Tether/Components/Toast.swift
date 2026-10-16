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
        HStack(spacing: 10) {
            if let systemImage = toast.systemImage { Image(systemName: systemImage) }
            Text(toast.text).font(.subheadline).lineLimit(2)
            if let action = toast.action, let onAction {
                Button(action, action: onAction).font(.subheadline.weight(.semibold)).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surfaceRaised, in: Capsule())
        .shadow(radius: 8)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func toast(_ toast: Binding<ToastMessage?>, onAction: (() -> Void)? = nil) -> some View {
        overlay(alignment: .top) {
            if let t = toast.wrappedValue {
                ToastView(toast: t, onAction: onAction)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t.id) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if toast.wrappedValue?.id == t.id { withAnimation { toast.wrappedValue = nil } }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: toast.wrappedValue)
    }
}
