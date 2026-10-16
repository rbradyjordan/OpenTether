import SwiftUI
import TetherCore

/// Pick a reference and a target frame from this session; the cloud returns a LUT.
struct ColorMatchView: View {
    @Environment(AppModel.self) private var app
    var model: ShootViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var referenceID: String?
    @State private var targetID: String?
    @State private var strength: Double = 0.8
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picker("Reference (the look you want)", $referenceID)
                    picker("Target (a frame from this session)", $targetID)
                    VStack(alignment: .leading) {
                        Text("Strength \(Int(strength * 100))%").font(.subheadline)
                        Slider(value: $strength, in: 0.1 ... 1, step: 0.05) { Text("Strength") }.tint(Theme.accent)
                    }
                    HStack {
                        Label("\(CreditsState.colorMatchCost) credit", systemImage: "creditcard")
                        Spacer()
                        Text("Balance \(app.credits.balance)").foregroundStyle(Theme.textSecondary)
                    }
                    .font(.subheadline)
                    if app.credits.tier == .free && app.credits.balance < CreditsState.colorMatchCost {
                        NavigationLink("Get credits", value: AppRoute.credits).font(.subheadline)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                    Button {
                        Task { await run() }
                    } label: {
                        Label(working ? "Matching…" : "Match and apply", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(working || referenceID == nil || targetID == nil || referenceID == targetID)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Colour match")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppRoute.self) { route in ConnectRouteView(route: route) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                targetID = model.displayedItem?.id
                referenceID = model.readyItems.first { $0.id != targetID }?.id
            }
        }
    }

    private func picker(_ title: String, _ selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.readyItems) { item in
                        AsyncImageView(cache: model.renderCache.proxyCache, relativePath: item.thumbnailRelativePath ?? item.previewRelativePath, contentMode: .fill, maxPixelSize: 320)
                            .frame(width: 80, height: 80).clipped().cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection.wrappedValue == item.id ? Theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { selection.wrappedValue = item.id }
                            .accessibilityLabel(item.filename)
                            .accessibilityAddTraits(selection.wrappedValue == item.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    private func run() async {
        guard let ref = model.items.first(where: { $0.id == referenceID })?.previewRelativePath,
              let tgt = model.items.first(where: { $0.id == targetID })?.previewRelativePath else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let refData = try app.cache.load(ref)
            let tgtData = try app.cache.load(tgt)
            let result = try await app.cloud.colorMatch(reference: refData, target: tgtData, strength: strength)
            let descriptor = LookDescriptor(id: result.lutID, name: "Match \(Date().formatted(date: .omitted, time: .shortened))",
                                            family: "Colour match", sha256: result.sha256, cubeURL: result.cubeURL)
            let cube = try await app.cloud.cube(descriptor)
            try app.store.saveLook(descriptor, cube: cube)
            app.reloadLooks()
            await app.refreshCredits()
            model.setLook(LookStack(lookID: descriptor.id, strength: 1))
            HapticFeedback.success()
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
