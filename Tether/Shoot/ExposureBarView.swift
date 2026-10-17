import SwiftUI
import TetherCore

/// Exposure chips for `TetherProperty.exposureBar`. Hidden for FTP-only
/// sessions; shown read-only (not greyed into noise) when the camera offers
/// no property control.
struct ExposureBarView: View {
    @Bindable var model: ShootViewModel
    /// A two-column grid for the iPad side panel instead of a scrolling row.
    var grid = false

    var body: some View {
        if model.identity != nil {
            Group {
                if grid {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: TetherSpace.s), GridItem(.flexible())], spacing: TetherSpace.s) {
                        chips
                    }
                    .padding(TetherSpace.m)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TetherSpace.s) { chips }
                            .padding(.horizontal, TetherSpace.m)
                            .padding(.vertical, TetherSpace.s)
                    }
                    .background(TetherColor.surface0)
                }
            }
            .overlayTypeCap()
            .accessibilityLabel(model.canControlProperties ? "Exposure settings" : "Exposure settings, read only on this camera")
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(TetherProperty.exposureBar) { property in
            chip(property, model.properties.first { $0.property == property })
        }
        if let dest = model.properties.first(where: { $0.property == .captureDestination }) {
            chip(.captureDestination, dest)
        }
    }

    @ViewBuilder private func chip(_ property: TetherProperty, _ descriptor: PropertyDescriptor?) -> some View {
        // Honest: a property the camera does not report at all is not shown.
        if let descriptor {
            let writable = descriptor.isWritable && !descriptor.choices.isEmpty && model.canControlProperties && model.isLive
            ExposureChip(property: property,
                         value: ExposureFormatting.value(for: property, display: descriptor.display),
                         selected: isPicking(property),
                         enabled: writable) {
                model.sheet = .property(property)
            }
        }
    }

    private func isPicking(_ property: TetherProperty) -> Bool {
        if case .property(let p) = model.sheet { return p == property }
        return false
    }
}
