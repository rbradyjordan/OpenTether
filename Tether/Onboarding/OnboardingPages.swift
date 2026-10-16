import Foundation

struct OnboardingPage: Identifiable {
    var id: Int
    var title: String
    var symbol: String
    var lines: [String]
}

enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(id: 0, title: "Shoot tethered, review live", symbol: "camera.aperture", lines: [
            "Plug a camera into the phone with USB-C, or join its Wi-Fi, or let it push files over FTP.",
            "Every frame lands on the canvas as it is taken; rate, flag, compare and hand the phone to the client.",
            "Apply looks without touching originals, then export to Photos, Files, FTP or a cloud batch.",
        ]),
        OnboardingPage(id: 1, title: "What Tether never does", symbol: "hand.raised", lines: [
            "It never joins a Wi-Fi network for you. You choose the camera's network in Settings.",
            "It never uploads a photo without asking. Cloud exports and AI colour match show their cost first.",
            "It never reads your photo library; saving is add-only. Location is used only to read the Wi-Fi name.",
        ]),
        OnboardingPage(id: 2, title: "Permissions", symbol: "lock.shield", lines: [
            "Local network: to find cameras and receive FTP pushes.",
            "Photos (add only): to save exports into an album.",
            "Location (while using): the only way iOS reveals the Wi-Fi network name.",
        ]),
    ]
}
