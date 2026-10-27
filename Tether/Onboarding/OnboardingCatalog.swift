import SwiftUI
import TetherCore

/// What the onboarding knows about cameras: the brands it offers, Canon body
/// families (their menus differ by generation), the connection paths and the
/// tailored setup steps for each. Copy only; no logic beyond picking.

// MARK: - Connection

/// How the camera reaches the phone. `cameraNetwork` is the camera's own
/// access point; `sameNetwork` is both on one router (studios, home).
enum OnboardingConnection: String, CaseIterable, Identifiable, Codable {
    case usb, cameraNetwork, sameNetwork, ftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usb: return "USB-C cable"
        case .cameraNetwork: return "Wi-Fi: the camera's network"
        case .sameNetwork: return "Wi-Fi: my router"
        case .ftp: return "FTP push"
        }
    }

    /// For sentences: "EOS R5 Mark II over USB-C".
    var shortTitle: String {
        switch self {
        case .usb: return "USB-C"
        case .cameraNetwork: return "the camera's Wi-Fi"
        case .sameNetwork: return "your Wi-Fi router"
        case .ftp: return "FTP"
        }
    }

    var symbol: String {
        switch self {
        case .usb: return "cable.connector"
        case .cameraNetwork: return "antenna.radiowaves.left.and.right"
        case .sameNetwork: return "wifi.router"
        case .ftp: return "arrow.down.doc"
        }
    }

    var pitch: String {
        switch self {
        case .usb: return "Fastest and most reliable. Full control: shutter, live view, settings."
        case .cameraNetwork: return "No cable, no router. The camera makes a hotspot and the phone joins it."
        case .sameNetwork: return "Camera and phone on the same Wi-Fi, like a studio router. The phone keeps its internet."
        case .ftp: return "The camera sends each photo as you shoot. Import only, no remote shutter."
        }
    }

    /// Short trade-offs shown under the card.
    var tradeoffs: [String] {
        switch self {
        case .usb: return ["Needs a data-capable USB-C cable", "Camera Wi-Fi must be off"]
        case .cameraNetwork: return ["One-time pairing on the camera", "The phone has no internet while joined"]
        case .sameNetwork: return ["One-time pairing on the camera", "Both must stay on the same network"]
        case .ftp: return ["Works with nearly every pro body", "Set up once in the camera's FTP menu"]
        }
    }

    var isWireless: Bool { self == .cameraNetwork || self == .sameNetwork }
    var needsLocalNetwork: Bool { self != .usb }
}

// MARK: - Bodies

/// Canon menus moved between generations; the setup copy follows the body.
enum CanonFamily: String, CaseIterable, Identifiable, Codable {
    /// 2023+: R5 Mark II, R6 Mark II, R1, R8, R50, R100. "Network" menu.
    case networkMenu
    /// 2020–22: R5, R6, R3, R7, R10. "Wireless features" menu.
    case wirelessMenu
    /// EOS R, RP, Ra and recent DSLRs (5D IV, 90D, 6D II). "Wireless communication settings".
    case classic

    var id: String { rawValue }

    /// The menu path to EOS Utility pairing, step by step as the camera shows it.
    var pairingMenuPath: [String] {
        switch self {
        case .networkMenu:
            return ["MENU", "Network", "Network settings: Enable", "Connection option settings", "Remote control (EOS Utility)", "SET1"]
        case .wirelessMenu:
            return ["MENU", "Wireless features", "Wi-Fi/Bluetooth connection", "Remote control (EOS Utility)", "Add a device to connect to"]
        case .classic:
            return ["MENU", "Wireless communication settings", "Wi-Fi function", "Remote control (EOS Utility)", "Add a device to connect to"]
        }
    }

    /// Where Wi-Fi is switched off so USB is heard.
    var wifiOffPath: String {
        switch self {
        case .networkMenu: return "Network → Network settings → Disable (or Airplane mode → On)"
        case .wirelessMenu: return "Wireless features → Wi-Fi settings → Wi-Fi: Disable (or Airplane mode → On)"
        case .classic: return "Wireless communication settings → Wi-Fi settings → Wi-Fi: Disable"
        }
    }

    /// Where an old pairing is cleared when the camera refuses to connect.
    var clearPairingPath: String {
        switch self {
        case .networkMenu: return "Network → Connection settings → SET1 → Erase settings"
        case .wirelessMenu: return "Wireless features → Wi-Fi/Bluetooth connection → Remote control (EOS Utility) → Edit/clear settings"
        case .classic: return "Wireless communication settings → Wi-Fi function → Remote control → Clear settings"
        }
    }
}

/// A camera body the user can pick. Canon is listed by model because its
/// menus differ; other brands are one entry each.
struct OnboardingBody: Identifiable, Hashable {
    var id: String
    var name: String
    var vendor: CameraVendor
    var canonFamily: CanonFamily?
    /// Shown as a chip ("Most popular", "USB-C 10 Gbps").
    var note: String?

    static let canon: [OnboardingBody] = [
        OnboardingBody(id: "canon.r5m2", name: "EOS R5 Mark II", vendor: .canon, canonFamily: .networkMenu, note: "Tested"),
        OnboardingBody(id: "canon.r6m2", name: "EOS R6 Mark II", vendor: .canon, canonFamily: .networkMenu),
        OnboardingBody(id: "canon.r1", name: "EOS R1", vendor: .canon, canonFamily: .networkMenu),
        OnboardingBody(id: "canon.r8", name: "EOS R8", vendor: .canon, canonFamily: .networkMenu),
        OnboardingBody(id: "canon.r50", name: "EOS R50 / R100", vendor: .canon, canonFamily: .networkMenu),
        OnboardingBody(id: "canon.r5", name: "EOS R5", vendor: .canon, canonFamily: .wirelessMenu),
        OnboardingBody(id: "canon.r6", name: "EOS R6", vendor: .canon, canonFamily: .wirelessMenu),
        OnboardingBody(id: "canon.r3", name: "EOS R3", vendor: .canon, canonFamily: .wirelessMenu),
        OnboardingBody(id: "canon.r7", name: "EOS R7 / R10", vendor: .canon, canonFamily: .wirelessMenu),
        OnboardingBody(id: "canon.rp", name: "EOS R / RP", vendor: .canon, canonFamily: .classic),
        OnboardingBody(id: "canon.dslr", name: "EOS DSLR (5D IV, 6D II, 90D…)", vendor: .canon, canonFamily: .classic),
    ]

    /// Brands in the picker, most common first. `generic` covers everything else.
    static let brands: [CameraVendor] = [.canon, .nikon, .sony, .fujifilm, .panasonic, .olympus, .leica, .ricoh, .gopro, .osc, .generic]

    static func brandBody(_ vendor: CameraVendor) -> OnboardingBody {
        OnboardingBody(id: "brand.\(vendor.rawValue)", name: vendor.displayName, vendor: vendor)
    }
}

extension CameraVendor {
    /// Hero symbol for the brand tile (no logos: brand names stay as text).
    var onboardingSymbol: String {
        switch self {
        case .gopro: return "camera.on.rectangle"
        case .osc: return "globe"
        case .ricoh: return "camera.viewfinder"
        case .generic: return "questionmark.circle"
        default: return "camera"
        }
    }

    /// Connections this brand can use, best first.
    var onboardingConnections: [OnboardingConnection] {
        switch self {
        case .canon, .nikon, .sony: return [.usb, .cameraNetwork, .sameNetwork, .ftp]
        case .fujifilm: return [.usb, .cameraNetwork, .ftp]
        case .ricoh: return [.cameraNetwork, .usb]
        case .gopro, .osc: return [.cameraNetwork]
        case .panasonic, .olympus: return [.usb, .ftp]
        default: return [.usb, .ftp]
        }
    }
}

// MARK: - Setup guide

/// One instruction in the tailored guide. `cameraScreen` is the text the
/// camera's own screen shows at that moment (drawn as a little LCD).
struct SetupStep: Identifiable, Hashable {
    var id: String { text }
    var text: String
    var symbol: String
    var where_: Place
    var cameraScreen: [String]? = nil
    var detail: String? = nil

    enum Place: String { case camera = "On the camera", phone = "On the phone", app = "In Open Tether" }
}

struct Troubleshoot: Identifiable, Hashable {
    var id: String { problem }
    var problem: String
    var fix: String
}

/// The tailored guide for a body + connection.
struct SetupGuide {
    var intro: String
    var steps: [SetupStep]
    var troubleshooting: [Troubleshoot]
    /// The Canon pairing explainer (four stages) is shown for EOS Utility Wi-Fi.
    var showsCanonPairing: Bool

    static func make(body: OnboardingBody?, connection: OnboardingConnection, ftpHost: String, ftpPort: UInt16, ftpUser: String) -> SetupGuide {
        let vendor = body?.vendor ?? .generic
        if vendor == .canon {
            return canon(family: body?.canonFamily ?? .networkMenu, model: body?.name ?? "your EOS", connection: connection, ftpHost: ftpHost, ftpPort: ftpPort, ftpUser: ftpUser)
        }
        return generic(vendor: vendor, connection: connection, ftpHost: ftpHost, ftpPort: ftpPort, ftpUser: ftpUser)
    }

    // MARK: Canon

    private static func canon(family: CanonFamily, model: String, connection: OnboardingConnection,
                              ftpHost: String, ftpPort: UInt16, ftpUser: String) -> SetupGuide {
        switch connection {
        case .usb:
            return SetupGuide(
                intro: "The \(model) tethers over its USB-C port with full control. The camera ignores USB while any network feature is on, so Wi-Fi goes off first.",
                steps: [
                    SetupStep(text: "Turn the camera's Wi-Fi off.", symbol: "wifi.slash", where_: .camera,
                              cameraScreen: family.wifiOffPath.components(separatedBy: " → "),
                              detail: "If the Canon Camera Connect app is paired over Bluetooth, it can wake Wi-Fi again: turn Bluetooth off too."),
                    SetupStep(text: "Set Auto power off to Disable.", symbol: "powersleep", where_: .camera,
                              cameraScreen: ["Setup", "Power saving", "Auto power off: Disable"],
                              detail: "A sleeping camera drops off the cable mid-shoot."),
                    SetupStep(text: "Plug in a data USB-C cable.", symbol: "cable.connector", where_: .phone,
                              detail: "USB-C iPhones and iPads plug straight in. Lightning iPhones need Apple's Lightning to USB 3 Camera Adapter. Charging-only cables show nothing."),
                    SetupStep(text: "Allow access when iOS asks, then pick the camera.", symbol: "checkmark.shield", where_: .app,
                              detail: "Open Tether switches the camera into remote mode and releases it when the session ends."),
                ],
                troubleshooting: [
                    Troubleshoot(problem: "Nothing appears when I plug in", fix: "Wi-Fi is probably still on. Check \(family.wifiOffPath). Then try another cable: many USB-C cables only charge."),
                    Troubleshoot(problem: "The camera shows a USB icon but no control", fix: "Unplug, quit other photo apps (Image Capture, Lightroom), and plug in again. Only one app can drive the camera."),
                    Troubleshoot(problem: "No card in the camera", fix: "iOS ignores cameras with no card. Insert one, even if you shoot to the phone only."),
                ],
                showsCanonPairing: false)

        case .cameraNetwork, .sameNetwork:
            let ap = connection == .cameraNetwork
            var steps: [SetupStep] = [
                SetupStep(text: "Open the EOS Utility connection.", symbol: "list.bullet.indent", where_: .camera,
                          cameraScreen: family.pairingMenuPath,
                          detail: family == .networkMenu
                            ? "Mark II-generation bodies keep each connection in a slot (SET1–SET20). Use an empty slot or the one you used before."
                            : "Some firmware calls it \"Connect to EOS Utility\". Same thing."),
            ]
            if ap {
                steps += [
                    SetupStep(text: "Choose Camera access point mode, then Easy connection.", symbol: "antenna.radiowaves.left.and.right", where_: .camera,
                              cameraScreen: ["Camera access point mode", "Easy connection", "SSID: EOSR5m2_97A03F-268_Canon0A", "Password: ••••••••"],
                              detail: "The camera shows its network name (it starts with the model and ends in _Canon0A, e.g. EOSR5m2_…_Canon0A) and a password. Leave that screen open."),
                    SetupStep(text: "Join that network in Settings → Wi-Fi.", symbol: "wifi", where_: .phone,
                              detail: "iOS warns \"No Internet Connection\". That's expected: stay joined. Come back to Open Tether."),
                ]
            } else {
                steps += [
                    SetupStep(text: "Choose your router's network and enter its password.", symbol: "wifi.router", where_: .camera,
                              cameraScreen: ["Infrastructure mode", "Select a network", "Your Wi-Fi", "IP address: Auto"],
                              detail: "Use 2.4 GHz if the camera can't see your 5 GHz network. Leave IP on Auto."),
                    SetupStep(text: "Make sure the phone is on the same Wi-Fi.", symbol: "iphone.radiowaves.left.and.right", where_: .phone,
                              detail: "Guest networks often block devices from seeing each other. Use the main network."),
                ]
            }
            steps += [
                SetupStep(text: "The camera says \"Start EOS Utility on the computer\". Leave it there.", symbol: "hourglass", where_: .camera,
                          cameraScreen: ["EOS-97A03F pairing (connection)", "with the computer in progress.", "Start EOS Utility on the", "computer.", "Cancel"],
                          detail: "Open Tether plays the part of EOS Utility, and the phone is the \"computer\". Don't press Cancel: come back to Open Tether."),
                SetupStep(text: "Tap the camera when Open Tether finds it.", symbol: "hand.tap", where_: .app,
                          detail: "It usually appears within a few seconds. If not, tap Enter IP and type the address shown in the camera's network info."),
                SetupStep(text: "Press OK on the camera to accept \"Open Tether\".", symbol: "checkmark.seal", where_: .camera,
                          cameraScreen: ["Connect to this computer?", "Open Tether", "OK    Cancel"],
                          detail: "You have 60 seconds. This happens once: the camera remembers Open Tether in this slot and reconnects without asking."),
            ]
            return SetupGuide(
                intro: ap
                    ? "Canon pairs once over Wi-Fi, the same way it pairs with EOS Utility on a computer. The camera makes its own network, the phone joins it, and you confirm Open Tether on the camera."
                    : "The camera joins your router like any device, Open Tether finds it on the network, and you confirm Open Tether on the camera once.",
                steps: steps,
                troubleshooting: [
                    Troubleshoot(problem: "Open Tether doesn't find the camera", fix: "Check the camera still says \"Start pairing\" and that the phone is on \(ap ? "the camera's network" : "the same Wi-Fi"). Allow Local Network for Open Tether (Settings → Privacy & Security → Local Network). Then use Enter IP with the address in the camera's network info."),
                    Troubleshoot(problem: "The phone leaves the camera's network", fix: "iOS sometimes hops back to a network with internet. In Settings → Wi-Fi, tap the camera's network again; turn off Auto-Join for your home network during the shoot if it keeps happening."),
                    Troubleshoot(problem: "It connects, then stops at \"Vendor remote mode\"", fix: "The camera hasn't finished pairing yet. Look at its screen: if it asks to connect to Open Tether, press OK, then tap Try again. A freshly paired camera can take a few seconds before it accepts remote control."),
                    Troubleshoot(problem: "\"Pairing timed out\"", fix: "The OK on the camera has to come within 60 seconds. Start pairing again on the camera, tap Connect, and press OK when \"Open Tether\" appears."),
                    Troubleshoot(problem: "The camera paired with another computer before", fix: "Each slot remembers one computer. Use a new slot, or clear the old one: \(family.clearPairingPath)."),
                    Troubleshoot(problem: "Camera Connect (smartphone app) grabs the camera", fix: "If the camera is paired with Canon Camera Connect over Bluetooth, it may switch to that app. Turn the camera's Bluetooth off, or remove the pairing in Camera Connect."),
                    Troubleshoot(problem: "It drops after a while", fix: "Set Setup → Power saving → Auto power off: Disable, and keep the camera within a few metres of the phone. RAW files are big over Wi-Fi: shoot to card + phone with JPEG previews for speed."),
                ],
                showsCanonPairing: true)

        case .ftp:
            return SetupGuide(
                intro: "The \(model) can send every frame to an FTP server as you shoot. Open Tether runs that server on the phone: no pairing, import only.",
                steps: [
                    SetupStep(text: "Join the phone and camera to the same network.", symbol: "wifi", where_: .phone,
                              detail: "A router works best. The camera's own access point can't be used for FTP."),
                    SetupStep(text: "Start the receiver in Open Tether (Connect → FTP).", symbol: "antenna.radiowaves.left.and.right", where_: .app,
                              detail: "It shows the phone's address, port \(ftpPort), user \"\(ftpUser)\" and the password."),
                    SetupStep(text: "Create an FTP server profile on the camera.", symbol: "server.rack", where_: .camera,
                              cameraScreen: ["MENU", "Network", "FTP transfer settings", "Set/Change settings", "Connection wizard"],
                              detail: BrandGuide.ftpInstructions(for: .canon, host: ftpHost, port: ftpPort, username: ftpUser)),
                    SetupStep(text: "Turn on Auto transfer.", symbol: "arrow.up.forward.circle", where_: .camera,
                              detail: "Every frame is sent the moment it's written to the card."),
                ],
                troubleshooting: [
                    Troubleshoot(problem: "\"Cannot connect to FTP server\"", fix: "Check the address and port on the camera match Open Tether's receiver screen exactly, and that passive mode is On."),
                    Troubleshoot(problem: "Frames arrive slowly", fix: "Send JPEG only, or reduce the size in the transfer settings. RAW over Wi-Fi takes several seconds per frame."),
                ],
                showsCanonPairing: false)
        }
    }

    // MARK: Other brands

    private static func generic(vendor: CameraVendor, connection: OnboardingConnection,
                                ftpHost: String, ftpPort: UInt16, ftpUser: String) -> SetupGuide {
        let guide = BrandGuide.guide(for: vendor)
        func steps(_ list: [BrandGuide.Step]?, place: SetupStep.Place) -> [SetupStep] {
            (list ?? []).map { SetupStep(text: $0.text, symbol: $0.symbol, where_: $0.text.hasPrefix("On the phone") ? .phone : place) }
        }
        let notes = (guide?.notes ?? []).map { Troubleshoot(problem: "Good to know", fix: $0) }
        switch connection {
        case .usb:
            let base = steps(guide?.wired, place: .camera)
            return SetupGuide(
                intro: guide?.summary ?? "Most cameras tether over USB as long as they are in PC / remote mode.",
                steps: base.isEmpty
                    ? [SetupStep(text: "Set the camera's USB mode to PC, PTP or Remote.", symbol: "laptopcomputer", where_: .camera),
                       SetupStep(text: "Plug in a data USB-C cable.", symbol: "cable.connector", where_: .phone)]
                    : base,
                troubleshooting: notes + [Troubleshoot(problem: "Nothing appears", fix: "Turn the camera's Wi-Fi off, insert a card, and try another cable: many only charge.")],
                showsCanonPairing: false)
        case .cameraNetwork, .sameNetwork:
            return SetupGuide(
                intro: guide?.summary ?? "Join the camera's network, then pick the camera in Open Tether.",
                steps: steps(guide?.wireless, place: .camera) + [SetupStep(text: "Tap the camera when Open Tether finds it.", symbol: "hand.tap", where_: .app)],
                troubleshooting: notes + [Troubleshoot(problem: "Open Tether doesn't find the camera", fix: "Allow Local Network for Open Tether in Settings → Privacy & Security, stay on the camera's network even without internet, then try Enter IP.")],
                showsCanonPairing: false)
        case .ftp:
            let text = BrandGuide.ftpInstructions(for: vendor, host: ftpHost, port: ftpPort, username: ftpUser)
            return SetupGuide(
                intro: "The camera uploads each frame to the FTP server Open Tether runs on the phone. Import only, no remote shutter.",
                steps: [
                    SetupStep(text: "Put the camera and phone on the same network.", symbol: "wifi", where_: .phone),
                    SetupStep(text: "Start the receiver in Open Tether (Connect → FTP).", symbol: "antenna.radiowaves.left.and.right", where_: .app),
                    SetupStep(text: "Register Open Tether as the camera's FTP server.", symbol: "server.rack", where_: .camera, detail: text),
                ],
                troubleshooting: notes,
                showsCanonPairing: false)
        }
    }
}

// MARK: - What you shoot

/// The kind of work, which seeds the workflow defaults.
enum ShootKind: String, CaseIterable, Identifiable {
    case portrait, product, event, realEstate, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: return "Portraits & fashion"
        case .product: return "Product & e-commerce"
        case .event: return "Events & weddings"
        case .realEstate: return "Real estate"
        case .other: return "A bit of everything"
        }
    }

    var symbol: String {
        switch self {
        case .portrait: return "person.crop.rectangle"
        case .product: return "shippingbox"
        case .event: return "party.popper"
        case .realEstate: return "house"
        case .other: return "square.grid.2x2"
        }
    }

    var namePattern: String {
        switch self {
        case .portrait: return "{date} Portraits"
        case .product: return "{date} Products"
        case .event: return "{date} Event"
        case .realEstate: return "Listing {n}"
        case .other: return "{date} {camera}"
        }
    }

    var suggestedDestination: CaptureDestination {
        switch self {
        case .event: return .card      // speed over a long day; pull selects later
        default: return .both
        }
    }
}
