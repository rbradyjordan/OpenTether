import SwiftUI
import TetherCore

/// Chips for `TetherProperty.exposureBar`. Greyed when the camera offers no
/// property control; hidden entirely for FTP-only sessions.
struct ExposureBarView: View {
    @Bindable var model: ShootViewModel

    var body: some View {
        if model.identity != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TetherProperty.exposureBar) { property in
                        let descriptor = model.properties.first { $0.property == property }
                        chip(property, descriptor)
                    }
                    if let dest = model.properties.first(where: { $0.property == .captureDestination }) {
                        chip(.captureDestination, dest)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .disabled(!model.canControlProperties || !model.isLive)
            .opacity(model.canControlProperties ? 1 : 0.45)
            .accessibilityLabel(model.canControlProperties ? "Exposure settings" : "Exposure settings, read only on this camera")
        }
    }

    private func chip(_ property: TetherProperty, _ descriptor: PropertyDescriptor?) -> some View {
        Button {
            if let descriptor, descriptor.isWritable, !descriptor.choices.isEmpty { model.sheet = .property(property) }
        } label: {
            VStack(spacing: 2) {
                Text(property.displayName.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(descriptor?.display ?? "—").font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minWidth: 64)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(descriptor?.isWritable == true ? Theme.stroke : .clear))
        }
        .buttonStyle(.plain)
        .disabled(descriptor == nil || descriptor?.isWritable == false)
        .accessibilityLabel("\(property.displayName) \(descriptor?.display ?? "unknown")")
        .accessibilityHint(descriptor?.isWritable == true ? "Double tap to change" : "")
    }
}
