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
                Image(systemName: "camera.aperture").font(.system(size: 56)).foregroundStyle(Theme.accent).padding(.top, 30)
                Text("Tether").font(.largeTitle.weight(.bold))
                Text("Version \(version)").foregroundStyle(Theme.textSecondary)
                Text("Camera tethering for iPhone and iPad: USB-C, Wi-Fi and FTP push, with looks, client review and resumable exports.")
                    .multilineTextAlignment(.center).font(.subheadline).padding(.horizontal)
                Text("Made by Brady Jordan.").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("About")
    }
}
