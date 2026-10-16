import Foundation
import TetherCore

/// Per-brand setup copy. Menu photos are placeholders (SF Symbols) until real
/// screenshots are shot.
struct BrandGuide: Identifiable {
    struct Step: Identifiable {
        var id: String { text }
        var text: String
        var symbol: String
    }

    var vendor: CameraVendor
    var id: String { vendor.rawValue }
    var summary: String
    var wired: [Step]
    var wireless: [Step]
    var notes: [String]

    static let all: [BrandGuide] = [
        BrandGuide(vendor: .canon,
                   summary: "EOS bodies tether over USB-C or Wi-Fi once they are in the PC / EOS Utility connection mode.",
                   wired: [
                       Step(text: "Menu → Wireless/Communication settings → Wi-Fi/Bluetooth connection → Disable Wi-Fi so USB wins.", symbol: "wifi.slash"),
                       Step(text: "Plug the camera into the phone with a data-capable USB-C cable.", symbol: "cable.connector"),
                       Step(text: "If asked, choose PC connection / EOS Utility mode on the camera.", symbol: "laptopcomputer"),
                   ],
                   wireless: [
                       Step(text: "Menu → Wireless settings → Wi-Fi/Bluetooth connection → Connect to EOS Utility.", symbol: "antenna.radiowaves.left.and.right"),
                       Step(text: "Pick 'Camera access point mode' and note the network name and password.", symbol: "key"),
                       Step(text: "On the phone: Settings → Wi-Fi → join that network. Come back to Open Tether and tap the camera.", symbol: "wifi"),
                   ],
                   notes: ["Open Tether puts the body into remote-control mode and releases it when the session ends.",
                           "Captures can go to the card, the phone only, or both (Destination in the exposure bar)."]),
        BrandGuide(vendor: .nikon,
                   summary: "Z bodies need USB power delivery off and the USB connection set to PC; Wi-Fi uses the camera's own access point.",
                   wired: [
                       Step(text: "Setup menu → USB power delivery → OFF (otherwise the camera charges and never talks).", symbol: "battery.100.bolt"),
                       Step(text: "Setup menu → USB connection → PC (not Mass Storage / MTP).", symbol: "laptopcomputer"),
                       Step(text: "Connect the cable. Open Tether switches the body to application mode (ChangeApplicationMode) and back afterwards.", symbol: "cable.connector"),
                   ],
                   wireless: [
                       Step(text: "Setup menu → Connect to smart device / Connect to PC → Wi-Fi connection → Camera access point.", symbol: "antenna.radiowaves.left.and.right"),
                       Step(text: "Join the camera network in Settings → Wi-Fi, then return to Open Tether.", symbol: "wifi"),
                   ],
                   notes: ["Some Z bodies need the first connection pairing to be confirmed on the camera screen."]),
        BrandGuide(vendor: .sony,
                   summary: "Alpha bodies tether in PC Remote mode; only one PC Remote session at a time.",
                   wired: [
                       Step(text: "Menu → Network → Transfer/Remote → Remote shoot setting / PC Remote → ON.", symbol: "laptopcomputer"),
                       Step(text: "USB Connection → PC Remote (older bodies: USB connection → PC Remote; Smartphone Connect → OFF).", symbol: "cable.connector"),
                       Step(text: "Still Img. Save Dest. → PC+Camera (or PC only) decides where frames land.", symbol: "internaldrive"),
                   ],
                   wireless: [
                       Step(text: "Menu → Network → Wi-Fi → Wi-Fi Connect ON, then PC Remote Function → Connection method: Access point / Wi-Fi Direct.", symbol: "antenna.radiowaves.left.and.right"),
                       Step(text: "Join the DIRECT-xxxx network in Settings → Wi-Fi. Return to Open Tether.", symbol: "wifi"),
                   ],
                   notes: ["Close Imaging Edge / Capture One before connecting: Sony allows a single remote session.",
                           "Turn Smartphone Connect off; it blocks PC Remote on many bodies."]),
        BrandGuide(vendor: .fujifilm,
                   summary: "X and GFX bodies need Connection Setting → USB Tether Shooting Auto (USB) or PC Connection Mode (Wi-Fi). On Wi-Fi the camera dials the app.",
                   wired: [
                       Step(text: "Setup → Connection Setting → Connection Mode → USB Tether Shooting Auto.", symbol: "cable.connector"),
                       Step(text: "Connect the cable and wait for the camera to switch to tether mode.", symbol: "laptopcomputer"),
                   ],
                   wireless: [
                       Step(text: "Setup → Connection Setting → Connection Mode → Wireless Tether Shooting Fixed / PC Connection Mode.", symbol: "antenna.radiowaves.left.and.right"),
                       Step(text: "Join the FUJIFILM-xxxx network. Open Tether listens; the camera connects to the phone.", symbol: "wifi"),
                   ],
                   notes: ["Fujifilm pushes events slowly; the filmstrip may lag the shutter by a second."]),
        BrandGuide(vendor: .ricoh,
                   summary: "GR III / IIIx and Theta are wireless only, over the camera's own Wi-Fi and HTTP API.",
                   wired: [],
                   wireless: [
                       Step(text: "GR III: Menu → Wireless settings → Wi-Fi → ON (or hold the Wi-Fi button). Note the password printed on the camera's sticker / menu.", symbol: "antenna.radiowaves.left.and.right"),
                       Step(text: "Join GR_xxxxxx in Settings → Wi-Fi. The camera is always 192.168.0.1.", symbol: "wifi"),
                       Step(text: "Back in Open Tether the Ricoh shows up automatically; tap Connect.", symbol: "camera"),
                   ],
                   notes: ["The GR sleeps fast; half-press the shutter to wake it before connecting.",
                           "RAW (DNG) captures download the camera's JPEG proxy first for speed."]),
        BrandGuide(vendor: .leica,
                   summary: "Wired only. Set the USB mode to PTP.",
                   wired: [Step(text: "Menu → Camera settings → USB mode → PTP (not Mass Storage / Apple Mode).", symbol: "cable.connector")],
                   wireless: [],
                   notes: ["Wireless control is not implemented for Leica; use the cable."]),
        BrandGuide(vendor: .olympus,
                   summary: "OM System / Olympus: wired only, in the body's PC (Tether) mode.",
                   wired: [
                       Step(text: "Connect the cable; on the camera's USB mode prompt choose PC / Control (Tether), not Storage / MTP.", symbol: "cable.connector"),
                       Step(text: "Menu → Utility → USB mode → Control if the prompt does not appear.", symbol: "laptopcomputer"),
                   ],
                   wireless: [],
                   notes: ["Wireless control is not implemented for OM System; use the cable."]),
        BrandGuide(vendor: .panasonic,
                   summary: "Lumix: wired only, in PC(Tether) USB mode.",
                   wired: [
                       Step(text: "Setup → USB Mode → PC(Tether).", symbol: "cable.connector"),
                       Step(text: "Connect the cable; the camera shows a tether icon when the link is up.", symbol: "laptopcomputer"),
                   ],
                   wireless: [],
                   notes: ["Wireless control is not implemented for Lumix; use the cable."]),
    ]

    static func guide(for vendor: CameraVendor) -> BrandGuide? { all.first { $0.vendor == vendor } }

    static let ftpCapable: [CameraVendor] = [.canon, .nikon, .sony, .fujifilm, .panasonic, .olympus]

    static func ftpInstructions(for vendor: CameraVendor, host: String, port: UInt16, username: String) -> String {
        let target = "Server: \(host)  Port: \(port)  User: \(username)  Passive mode: on  Encryption: off (plain FTP on the local network)."
        switch vendor {
        case .canon: return "Menu → Network → FTP transfer settings → Set/Change settings → Connection wizard. \(target) Enable 'Auto transfer' so every frame is sent as it is taken."
        case .nikon: return "Setup → Connect to FTP server → Network settings → Create profile. \(target) Choose 'Send during shooting' under Options."
        case .sony: return "Menu → Network → Transfer/Remote → FTP Transfer Func. → Server Setting → new server. \(target) Then 'FTP Transfer' → Auto FTP Transfer ON."
        case .fujifilm: return "Setup → Connection Setting → FTP transfer settings. \(target) Turn on 'Transfer during shooting'."
        case .panasonic: return "Setup → Wi-Fi → Wi-Fi Function → New Connection → Send Images While Recording → FTP server. \(target)"
        case .olympus: return "Menu → Network settings → FTP → register a server. \(target) Enable sending while shooting."
        default: return "Configure the camera's FTP transfer to: \(target)"
        }
    }
}
