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
        .padding(.bottom, TetherSpace.s)
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
            HStack(spacing: 0) {
                tool("Looks", "camera.filters") { model.sheet = .looks }
                Spacer()
                Spacer().frame(width: CaptureRing.diameter + TetherSpace.xl)
                Spacer()
                HStack(spacing: 0) {
                    tool("Export", "square.and.arrow.up") { model.sheet = .export }
                        .disabled(model.readyItems.isEmpty)
                    secondaryMenu
                }
            }
            .padding(.horizontal, TetherSpace.m)
        }
        .frame(minHeight: CaptureRing.diameter + TetherSpace.s)
    }

    @ViewBuilder private var shutter: some View {
        if model.canCapture {
            CaptureRing(enabled: model.isLive, busy: model.isCapturing) { af in model.capture(autofocus: af) }
        } else {
            // No remote shutter on this path: show that frames arrive on their own.
            VStack(spacing: TetherSpace.xs) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(model.isLive ? TetherColor.accent : TetherColor.ink2)
                    .symbolEffect(.pulse, isActive: model.isLive)
                    .frame(width: 56, height: 56)
                    .tetherGlass(in: Circle(), tint: model.isLive ? TetherColor.accent.opacity(0.2) : nil)
                Text(model.isLive ? "Auto-import" : "Waiting").font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Auto-import. Shoot on the camera; frames arrive here. This connection has no remote shutter.")
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
            VStack(spacing: TetherSpace.xs) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TetherColor.ink0)
                    .frame(width: 44, height: 44)
                    .tetherGlass(in: Circle(), interactive: true)
                Text("More").font(TetherFont.caption).foregroundStyle(TetherColor.ink1)
            }
            .frame(minWidth: 64)
        }
        .accessibilityLabel("More actions")
    }

    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: TetherSpace.xs) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TetherColor.ink0)
                    .frame(width: 44, height: 44)
                    .tetherGlass(in: Circle(), interactive: true)
                Text(title).font(TetherFont.caption).foregroundStyle(TetherColor.ink1).lineLimit(1)
            }
            .frame(minWidth: 64)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
    }
}
