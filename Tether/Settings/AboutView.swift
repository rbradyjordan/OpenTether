import SwiftUI

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image("BrandIcon").resizable().interpolation(.high).scaledToFit()
                    .frame(width: 140, height: 140)
                    .shadow(color: TetherColor.accent.opacity(0.35), radius: 30, y: 10)
                    .padding(.top, 24)
                    .accessibilityHidden(true)
                Text("Open Tether").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Version \(version)").foregroundStyle(Theme.textSecondary)
                Text("Camera tethering for iPhone and iPad: USB-C, Wi-Fi and FTP push, with looks, client review and resumable exports.")
                    .multilineTextAlignment(.center).font(.subheadline).padding(.horizontal)
                Text("Made by Brady Jordan.").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
        }
        .tetherScreen()
        .navigationTitle("About")
    }
}
