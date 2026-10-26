// Per-brand setup copy, ported from Tether/Connect/BrandGuides.swift (Mac wording).
import type { CameraVendor } from "../../api";

export interface GuideStep { text: string; symbol: string }
export interface BrandGuide { vendor: CameraVendor; summary: string; wired: GuideStep[]; wireless: GuideStep[]; notes: string[] }

export const BRAND_GUIDES: BrandGuide[] = [
  {
    vendor: "canon",
    summary: "EOS bodies tether over USB-C or Wi-Fi once they are in the PC / EOS Utility connection mode.",
    wired: [{ text: "Menu → Wireless/Communication settings → Wi-Fi/Bluetooth connection → Disable Wi-Fi so USB wins.", symbol: "wifi.slash" }, { text: "Plug the camera into the Mac with a data-capable USB-C cable.", symbol: "cable.connector" }, { text: "If asked, choose PC connection / EOS Utility mode on the camera.", symbol: "laptopcomputer" }],
    wireless: [{ text: "Menu → Wireless settings → Wi-Fi/Bluetooth connection → Connect to EOS Utility.", symbol: "antenna.radiowaves.left.and.right" }, { text: "Pick 'Camera access point mode' and note the network name and password.", symbol: "key" }, { text: "On the Mac: the Wi-Fi menu in the menu bar → join that network. Come back to Open Tether and tap the camera.", symbol: "wifi" }],
    notes: ["Open Tether puts the body into remote-control mode and releases it when the session ends.", "Captures can go to the card, the Mac only, or both (Destination in the exposure bar)."],
  },
  {
    vendor: "nikon",
    summary: "Z bodies need USB power delivery off and the USB connection set to PC; Wi-Fi uses the camera's own access point.",
    wired: [{ text: "Setup menu → USB power delivery → OFF (otherwise the camera charges and never talks).", symbol: "battery.100.bolt" }, { text: "Setup menu → USB connection → PC (not Mass Storage / MTP).", symbol: "laptopcomputer" }, { text: "Connect the cable. Open Tether switches the body to application mode (ChangeApplicationMode) and back afterwards.", symbol: "cable.connector" }],
    wireless: [{ text: "Setup menu → Connect to smart device / Connect to PC → Wi-Fi connection → Camera access point.", symbol: "antenna.radiowaves.left.and.right" }, { text: "Join the camera network in the Wi-Fi menu in the menu bar, then return to Open Tether.", symbol: "wifi" }],
    notes: ["Some Z bodies need the first connection pairing to be confirmed on the camera screen."],
  },
  {
    vendor: "sony",
    summary: "Alpha bodies tether in PC Remote mode; only one PC Remote session at a time.",
    wired: [{ text: "Menu → Network → Transfer/Remote → Remote shoot setting / PC Remote → ON.", symbol: "laptopcomputer" }, { text: "USB Connection → PC Remote (older bodies: USB connection → PC Remote; Smartphone Connect → OFF).", symbol: "cable.connector" }, { text: "Still Img. Save Dest. → PC+Camera (or PC only) decides where frames land.", symbol: "internaldrive" }],
    wireless: [{ text: "Menu → Network → Wi-Fi → Wi-Fi Connect ON, then PC Remote Function → Connection method: Access point / Wi-Fi Direct.", symbol: "antenna.radiowaves.left.and.right" }, { text: "Join the DIRECT-xxxx network in the Wi-Fi menu in the menu bar. Return to Open Tether.", symbol: "wifi" }],
    notes: ["Close Imaging Edge / Capture One before connecting: Sony allows a single remote session.", "Turn Smartphone Connect off; it blocks PC Remote on many bodies."],
  },
  {
    vendor: "fujifilm",
    summary: "X and GFX bodies need Connection Setting → USB Tether Shooting Auto (USB) or PC Connection Mode (Wi-Fi). On Wi-Fi the camera dials the app.",
    wired: [{ text: "Setup → Connection Setting → Connection Mode → USB Tether Shooting Auto.", symbol: "cable.connector" }, { text: "Connect the cable and wait for the camera to switch to tether mode.", symbol: "laptopcomputer" }],
    wireless: [{ text: "Setup → Connection Setting → Connection Mode → Wireless Tether Shooting Fixed / PC Connection Mode.", symbol: "antenna.radiowaves.left.and.right" }, { text: "Join the FUJIFILM-xxxx network. Open Tether listens; the camera connects to the Mac.", symbol: "wifi" }],
    notes: ["Fujifilm pushes events slowly; the filmstrip may lag the shutter by a second."],
  },
  {
    vendor: "ricoh",
    summary: "GR III / IIIx are controlled over the camera's own Wi-Fi. Over USB they import only. (Theta: see 360° cameras.)",
    wired: [],
    wireless: [{ text: "GR III: Menu → Wireless settings → Wi-Fi → ON (or hold the Wi-Fi button). Note the password printed on the camera's sticker / menu.", symbol: "antenna.radiowaves.left.and.right" }, { text: "Join GR_xxxxxx in the Wi-Fi menu in the menu bar. The camera is always 192.168.0.1.", symbol: "wifi" }, { text: "Back in Open Tether the Ricoh shows up automatically; tap Connect.", symbol: "camera" }],
    notes: ["The GR sleeps fast; half-press the shutter to wake it before connecting.", "RAW (DNG) captures download the camera's JPEG proxy first for speed."],
  },
  {
    vendor: "leica",
    summary: "Wired only. Set the USB mode to PTP.",
    wired: [{ text: "Menu → Camera settings → USB mode → PTP (not Mass Storage / Apple Mode).", symbol: "cable.connector" }],
    wireless: [],
    notes: ["Wireless control is not implemented for Leica; use the cable."],
  },
  {
    vendor: "olympus",
    summary: "OM System / Olympus: wired only, in the body's PC (Tether) mode.",
    wired: [{ text: "Connect the cable; on the camera's USB mode prompt choose PC / Control (Tether), not Storage / MTP.", symbol: "cable.connector" }, { text: "Menu → Utility → USB mode → Control if the prompt does not appear.", symbol: "laptopcomputer" }],
    wireless: [],
    notes: ["Wireless control is not implemented for OM System; use the cable."],
  },
  {
    vendor: "panasonic",
    summary: "Lumix: wired only, in PC(Tether) USB mode.",
    wired: [{ text: "Setup → USB Mode → PC(Tether).", symbol: "cable.connector" }, { text: "Connect the cable; the camera shows a tether icon when the link is up.", symbol: "laptopcomputer" }],
    wireless: [],
    notes: ["Wireless control is not implemented for Lumix; use the cable."],
  },
  {
    vendor: "pentax",
    summary: "Pentax K-series over USB-C or USB: photos import as you shoot; remote capture when the body offers it.",
    wired: [{ text: "Setup menu → USB Connection → PTP (not MSC).", symbol: "cable.connector" }, { text: "Connect the cable and shoot; each frame lands in Open Tether.", symbol: "camera" }],
    wireless: [],
    notes: ["Pentax's own remote-control extensions are not implemented yet; the shutter button on the camera always works."],
  },
  {
    vendor: "sigma",
    summary: "Sigma fp / fp L / BF over USB-C: frames import as you shoot; remote capture when the body offers it.",
    wired: [{ text: "Menu → System → USB Mode → Camera Control (or PTP), not Mass Storage or UVC/UAC.", symbol: "cable.connector" }, { text: "Connect the cable and shoot.", symbol: "camera" }],
    wireless: [],
    notes: ["DNG files arrive as originals with their XMP sidecar on export."],
  },
  {
    vendor: "hasselblad",
    summary: "X2D / X1D / 907X over USB-C: frames import as you shoot (3FR and JPEG).",
    wired: [{ text: "Settings → Connectivity → USB → PTP (Phocus control off).", symbol: "cable.connector" }, { text: "Connect the cable and shoot.", symbol: "camera" }],
    wireless: [],
    notes: ["Hasselblad's Phocus control protocol is private, so exposure control stays on the camera."],
  },
  {
    vendor: "gopro",
    summary: "HERO9 and later over the camera's Wi-Fi: remote shutter, and every still (JPEG or GoPro RAW) lands on the Mac.",
    wired: [],
    wireless: [{ text: "Pair the GoPro once with GoPro Quik so its Wi-Fi can be turned on.", symbol: "link" }, { text: "On the camera: Preferences → Connections → Wireless Connections → On (or swipe down → Connect).", symbol: "antenna.radiowaves.left.and.right" }, { text: "On the Mac: the Wi-Fi menu in the menu bar → join the GoPro's network (password under Connections → Camera Info).", symbol: "wifi" }, { text: "Back in Open Tether the GoPro shows up automatically (10.5.5.9); tap it.", symbol: "camera" }],
    notes: ["Open Tether switches the camera to photo mode on connect.", "Videos stay on the card; only stills are downloaded."],
  },
  {
    vendor: "osc",
    summary: "Ricoh Theta, Insta360 and other 360° cameras that speak the Open Spherical Camera API.",
    wired: [],
    wireless: [{ text: "Turn on the camera's Wi-Fi (access point / direct mode).", symbol: "antenna.radiowaves.left.and.right" }, { text: "Join its network in the Wi-Fi menu in the menu bar (Theta: THETAxxxx, password = serial digits).", symbol: "wifi" }, { text: "Back in Open Tether the camera shows up automatically (Theta 192.168.1.1, Insta360 192.168.42.1); tap it.", symbol: "camera" }],
    notes: ["Equirectangular JPEGs import at full size; stitching happens in the camera."],
  },
];

export const guideFor = (v: CameraVendor) => BRAND_GUIDES.find((g) => g.vendor === v);

export const FTP_CAPABLE: CameraVendor[] = ["canon", "nikon", "sony", "fujifilm", "panasonic", "olympus"];

export function ftpInstructions(vendor: CameraVendor, host: string, port: number, username: string): string {
  const target = `Server: ${host}  Port: ${port}  User: ${username}  Passive mode: on  Encryption: off (plain FTP on the local network).`;
  switch (vendor) {
    case "canon": return `Menu → Network → FTP transfer settings → Set/Change settings → Connection wizard. ${target} Enable 'Auto transfer' so every frame is sent as it is taken.`;
    case "nikon": return `Setup → Connect to FTP server → Network settings → Create profile. ${target} Choose 'Send during shooting' under Options.`;
    case "sony": return `Menu → Network → Transfer/Remote → FTP Transfer Func. → Server Setting → new server. ${target} Then 'FTP Transfer' → Auto FTP Transfer ON.`;
    case "fujifilm": return `Setup → Connection Setting → FTP transfer settings. ${target} Turn on 'Transfer during shooting'.`;
    case "panasonic": return `Setup → Wi-Fi → Wi-Fi Function → New Connection → Send Images While Recording → FTP server. ${target}`;
    case "olympus": return `Menu → Network settings → FTP → register a server. ${target} Enable sending while shooting.`;
    default: return `Configure the camera's FTP transfer to: ${target}`;
  }
}
