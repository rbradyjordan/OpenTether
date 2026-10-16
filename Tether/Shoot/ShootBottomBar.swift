import SwiftUI
import TetherCore

struct ShootBottomBar: View {
    @Bindable var model: ShootViewModel

    var body: some View {
        VStack(spacing: 6) {
            if let item = model.displayedItem {
                HStack(spacing: 14) {
                    RatingStars(rating: item.rating, size: 18) { model.rate(item.id, stars: $0) }
                    Spacer()
                    FlagButtons(flag: item.flag) { model.flag(item.id, $0) }
                    Menu {
                        ForEach(TetherCoreColorLabel.allCases) { label in
                            Button(label == .none ? "Clear label" : label.rawValue.capitalized) { model.label(item.id, label) }
                        }
                    } label: {
                        Image(systemName: "circle.fill").font(.title3)
                            .foregroundStyle(item.colorLabel == .none ? Theme.textSecondary : ColorLabelStyle.color(for: item.colorLabel))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Colour label, currently \(item.colorLabel.rawValue)")
                }
                .padding(.horizontal, 14)
            }
            HStack(alignment: .center, spacing: 0) {
                tool("Compare", "rectangle.split.2x1") { model.sheet = .compare }
                    .disabled(model.readyItems.count < 2)
                tool("Review", "person.crop.rectangle") { model.showClientReview = true }
                    .disabled(model.readyItems.isEmpty)
                shutter
                tool("Looks", "camera.filters") { model.sheet = .looks }
                tool("Export", "square.and.arrow.up") { model.sheet = .export }
                    .disabled(model.readyItems.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .padding(.top, 6)
        .background(Theme.surface)
    }

    @ViewBuilder private var shutter: some View {
        if model.canCapture {
            CaptureButton(enabled: model.isLive, busy: model.isCapturing) { af in model.capture(autofocus: af) }
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 2) {
                Image(systemName: "arrow.down.circle").font(.title2)
                Text("Import only").font(.caption2)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 66)
            .accessibilityLabel("Import only, this camera has no remote capture")
        }
    }

    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
