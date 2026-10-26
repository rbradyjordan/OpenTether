import SwiftUI
import TetherCore

/// Wheel-style picker over the camera's own list of values. The current
/// value starts centred, each step ticks, and the centred value applies once
/// the wheel rests.
struct PropertyPickerSheet: View {
    var model: ShootViewModel
    var property: TetherProperty
    @Environment(\.dismiss) private var dismiss

    private var descriptor: PropertyDescriptor? { model.properties.first { $0.property == property } }

    private var items: [WheelPicker.Item] {
        (descriptor?.choices ?? []).enumerated().map { WheelPicker.Item(id: String($0.offset), label: $0.element.display) }
    }

    private var currentID: String? {
        guard let descriptor, let index = descriptor.choices.firstIndex(where: { $0.raw == descriptor.raw }) else { return nil }
        return String(index)
    }

    var body: some View {
        VStack(spacing: TetherSpace.m) {
            header
            if let descriptor, !descriptor.choices.isEmpty {
                WheelPicker(items: items, current: currentID) { id in
                    guard let index = Int(id), descriptor.choices.indices.contains(index) else { return }
                    model.setProperty(property, raw: descriptor.choices[index].raw)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
                Text("This setting is not available right now.")
                    .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                Spacer()
            }
        }
        .padding(.top, TetherSpace.l)
        .tetherScreen()
        .forceDark()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: TetherSpace.xs) {
                Text(ExposureFormatting.caption(for: property)).tetherCaption().foregroundStyle(TetherColor.ink2)
                Text(ExposureFormatting.value(for: property, display: descriptor?.display))
                    .font(TetherFont.exposure)
                    .foregroundStyle(TetherColor.ink0)
                    .contentTransition(.numericText())
                    .tetherAnimation(TetherMotion.snap, value: descriptor?.display)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Done") { dismiss() }
                .font(TetherFont.headline)
                .frame(minHeight: TetherHit.min)
        }
        .padding(.horizontal, TetherSpace.l)
    }
}
