import SwiftUI
import TetherCore

struct PropertyPickerSheet: View {
    var model: ShootViewModel
    var property: TetherProperty
    @Environment(\.dismiss) private var dismiss

    private var descriptor: PropertyDescriptor? { model.properties.first { $0.property == property } }

    var body: some View {
        NavigationStack {
            List {
                if let descriptor {
                    ForEach(descriptor.choices) { choice in
                        Button {
                            model.setProperty(property, raw: choice.raw)
                            HapticFeedback.selection()
                            dismiss()
                        } label: {
                            HStack {
                                Text(choice.display).foregroundStyle(.primary)
                                Spacer()
                                if choice.raw == descriptor.raw { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .accessibilityAddTraits(choice.raw == descriptor.raw ? .isSelected : [])
                    }
                } else {
                    Text("This setting is not available right now.").foregroundStyle(Theme.textSecondary)
                }
            }
            .navigationTitle(property.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
