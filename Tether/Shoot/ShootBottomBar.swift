import SwiftUI
import TetherCore

/// Bottom 40 %: rating centred with Reject / Pick flanking it, then the
/// capture ring centred with Looks and Export beside it and everything
/// secondary in one trailing menu.
struct ShootBottomBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ShootViewModel

    var body: some View {
        VStack(spacing: TetherSpace.s) {
            if let item = model.displayedItem {
                ratingRow(item)
            } else {
                Color.clear.frame(height: TetherHit.min)
            }
            captureRow
        }
        .padding(.top, TetherSpace.s)
        .padding(.bottom, TetherSpace.xs)
        .background(TetherColor.surface1)
        .overlay(alignment: .top) { Rectangle().fill(TetherColor.hairline).frame(height: 0.5) }
        .overlayTypeCap()
    }

    private func ratingRow(_ item: CaptureItem) -> some View {
        HStack(spacing: TetherSpace.m) {
            FlagButton(kind: .reject, flag: item.flag) { model.flag(item.id, $0) }
            Spacer(minLength: 0)
            RatingStars(rating: item.rating, size: 28) { model.rate(item.id, stars: $0) }
            Spacer(minLength: 0)
            FlagButton(kind: .pick, flag: item.flag) { model.flag(item.id, $0) }
        }
        .padding(.horizontal, TetherSpace.l)
    }

    private var captureRow: some View {
        ZStack {
            shutter
            HStack(spacing: TetherSpace.xs) {
                tool("Looks", "camera.filters") { model.sheet = .looks }
                Spacer()
                tool("Export", "square.and.arrow.up") { model.sheet = .export }
                    .disabled(model.readyItems.isEmpty)
                secondaryMenu
            }
            .padding(.horizontal, TetherSpace.s)
        }
        .frame(minHeight: CaptureRing.diameter + TetherSpace.s)
    }

    @ViewBuilder private var shutter: some View {
        if model.canCapture {
            CaptureRing(enabled: model.isLive, busy: model.isCapturing) { af in model.capture(autofocus: af) }
        } else {
            VStack(spacing: 2) {
                Image(systemName: "arrow.down.circle").font(.system(size: 22, weight: .medium))
                Text("Import only").tetherCaption()
            }
            .foregroundStyle(TetherColor.ink1)
            .frame(width: CaptureRing.diameter, height: CaptureRing.diameter)
            .accessibilityLabel("Import only, this camera has no remote capture")
        }
    }

    /// Everything secondary, generated from the shared command list for the
    /// displayed frame (compare uses the previous frame as the other half).
    private var secondaryMenu: some View {
        Menu {
            if model.readyItems.count >= 2 {
                Button { model.sheet = .compare } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
            }
            if !model.readyItems.isEmpty {
                Button { model.showClientReview = true } label: { Label("Client review", systemImage: "person.crop.rectangle") }
            }
            Button { model.sheet = .exportProgress } label: { Label("Export progress", systemImage: "arrow.up.doc") }
            Divider()
            let ids = model.displayedItem.map { [$0.id] } ?? []
            CommandMenuContent(commands: app.commands.available(selection: ids, inShoot: true),
                               exclude: ["select.", "view.", "camera.", "session.", "export.again", "flag.", "rate."]) { cmd in
                app.commands.preferShootSurface = true
                app.commands.run(cmd, on: ids)
                app.commands.preferShootSurface = false
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(TetherColor.ink1)
                .frame(width: TetherHit.min, height: TetherHit.min)
        }
        .accessibilityLabel("More actions")
    }

    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(title).tetherCaption()
            }
            .foregroundStyle(TetherColor.ink1)
            .frame(minWidth: 56, minHeight: TetherHit.min + 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
