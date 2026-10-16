import SwiftUI

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard(title: "What stays on the phone", systemImage: "iphone") {
                    Text("Every capture, rating, look and session lives in the app's own storage. Nothing is uploaded unless you choose Cloud batch or AI colour match, and the export sheet tells you the cost first.")
                }
                SectionCard(title: "What Open Tether never does", systemImage: "hand.raised") {
                    Text("• Join a Wi-Fi network for you. You pick the camera's network in Settings.\n• Upload photos in the background.\n• Read your photo library; the Photos permission is add-only.\n• Use your location. Location access is only the key iOS requires to read the Wi-Fi network name.")
                }
                SectionCard(title: "Generic PTP import vs vendor control", systemImage: "camera.badge.ellipsis") {
                    Text("Any PTP camera can be imported from over USB using the standard Picture Transfer Protocol. Remote capture, live view and exposure control use each maker's documented or community-documented vendor extensions. Open Tether is not affiliated with or endorsed by Canon, Nikon, Sony, Fujifilm, Ricoh, Leica, OM Digital Solutions or Panasonic; brand names are used only to identify compatible equipment. Features are enabled from what the connected body reports, never from a model list, so a camera may offer fewer controls than its siblings.")
                }
                SectionCard(title: "Cloud account", systemImage: "icloud") {
                    Text("The device registers anonymously with a random identifier. Credits and purchases are tied to that identifier and to your App Store account. Delete the app to remove the registration from your device.")
                }
            }
            .font(.footnote)
            .padding(16)
        }
        .tetherScreen()
        .navigationTitle("Privacy & legal")
    }
}
