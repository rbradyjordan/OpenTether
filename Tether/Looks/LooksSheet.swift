import SwiftUI
import TetherCore

struct LooksSheet: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var strength: Double = 1
    @State private var selectedID: String?
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        lookCell(nil, name: "None", family: "")
                        ForEach(app.looks) { look in lookCell(look.id, name: look.name, family: look.family) }
                    }
                    if selectedID != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Strength \(Int(strength * 100))%").font(.subheadline)
                            Slider(value: $strength, in: 0 ... 1, step: 0.05) { Text("Strength") }
                                .tint(Theme.accent)
                                .onChange(of: strength) { _, _ in apply() }
                        }
                    }
                    Text("The look applies to the canvas and to new captures (and to exports when 'Apply look' is on). Originals are never changed.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                    Button {
                        model.sheet = .colorMatch
                    } label: { Label("AI colour match from a reference frame", systemImage: "wand.and.stars") }
                        .buttonStyle(.bordered)
                        .disabled(model.readyItems.count < 1)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Looks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refreshing = true
                        Task { await app.refreshCloud(); refreshing = false }
                    } label: { if refreshing { ProgressView() } else { Label("Refresh", systemImage: "arrow.clockwise") } }
                    .accessibilityLabel("Refresh looks from the cloud")
                }
            }
            .onAppear {
                selectedID = model.lookStack.lookID
                strength = model.lookStack.strength
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func lookCell(_ id: String?, name: String, family: String) -> some View {
        Button {
            selectedID = id
            apply()
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10).fill(swatch(id)).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedID == id ? Theme.accent : Theme.stroke, lineWidth: selectedID == id ? 2 : 1))
                Text(name).font(.caption.weight(.medium)).lineLimit(1)
                if !family.isEmpty { Text(family).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) look\(family.isEmpty ? "" : ", \(family)")")
        .accessibilityAddTraits(selectedID == id ? .isSelected : [])
    }

    private func swatch(_ id: String?) -> LinearGradient {
        guard let id, let look = app.looks.first(where: { $0.id == id }), let hint = look.hint else {
            return LinearGradient(colors: [Theme.surfaceRaised, Theme.surface], startPoint: .top, endPoint: .bottom)
        }
        let warm = Color(hue: hint.warmth >= 0 ? 0.08 : 0.6, saturation: min(1, abs(hint.warmth) * 0.6 + 0.2), brightness: 0.8)
        let base = Color(white: 0.5 + hint.contrast * 0.2)
        return LinearGradient(colors: [warm, base], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func apply() {
        model.setLook(LookStack(lookID: selectedID, strength: strength))
    }
}
