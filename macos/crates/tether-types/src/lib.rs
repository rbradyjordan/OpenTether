//! Types shared by every Open Tether crate: camera brand, capabilities,
//! transport kind, the connected camera's identity and live-view frames.
//! Ported from `TetherCore/Device/CameraModel.swift` and `PTP/PTPTransport.swift`.
//! Serialised names match the iOS app's raw values so stores and exports agree.

use bitflags::bitflags;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum CameraVendor {
    Canon,
    Nikon,
    Sony,
    Fujifilm,
    Ricoh,
    Leica,
    Olympus,
    Panasonic,
    Hasselblad,
    Generic,
    Pentax,
    Sigma,
    Samsung,
    /// GoPro HERO (Open GoPro HTTP API over the camera's Wi-Fi).
    Gopro,
    /// 360° cameras speaking the Open Spherical Camera API (Theta, Insta360…).
    Osc,
}

/// PTP vendor extension IDs (DeviceInfo.VendorExtensionID) that name a brand.
pub mod vendor_extension {
    pub const NIKON: u32 = 0x000A;
    pub const CANON: u32 = 0x000B;
    pub const PENTAX: u32 = 0x000D;
    pub const FUJI: u32 = 0x000E;
    pub const SONY: u32 = 0x0011;
    pub const SAMSUNG: u32 = 0x001A;
    pub const PANASONIC: u32 = 0x001C;
    pub const OLYMPUS: u32 = 0x001D;
    pub const LEICA: u32 = 0x001E;
}

impl CameraVendor {
    pub const ALL: [CameraVendor; 15] = [
        Self::Canon,
        Self::Nikon,
        Self::Sony,
        Self::Fujifilm,
        Self::Ricoh,
        Self::Leica,
        Self::Olympus,
        Self::Panasonic,
        Self::Hasselblad,
        Self::Generic,
        Self::Pentax,
        Self::Sigma,
        Self::Samsung,
        Self::Gopro,
        Self::Osc,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Canon => "canon",
            Self::Nikon => "nikon",
            Self::Sony => "sony",
            Self::Fujifilm => "fujifilm",
            Self::Ricoh => "ricoh",
            Self::Leica => "leica",
            Self::Olympus => "olympus",
            Self::Panasonic => "panasonic",
            Self::Hasselblad => "hasselblad",
            Self::Generic => "generic",
            Self::Pentax => "pentax",
            Self::Sigma => "sigma",
            Self::Samsung => "samsung",
            Self::Gopro => "gopro",
            Self::Osc => "osc",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|v| v.raw() == s)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Canon => "Canon",
            Self::Nikon => "Nikon",
            Self::Sony => "Sony",
            Self::Fujifilm => "Fujifilm",
            Self::Ricoh => "Ricoh",
            Self::Leica => "Leica",
            Self::Olympus => "OM System / Olympus",
            Self::Panasonic => "Panasonic Lumix",
            Self::Hasselblad => "Hasselblad",
            Self::Pentax => "Pentax",
            Self::Sigma => "Sigma",
            Self::Samsung => "Samsung NX",
            Self::Gopro => "GoPro",
            Self::Osc => "360° camera (Theta, Insta360…)",
            Self::Generic => "Generic PTP camera",
        }
    }

    /// Resolved from DeviceInfo strings and the vendor extension ID, never
    /// from a model allowlist.
    pub fn detect(
        manufacturer: &str,
        model: &str,
        vendor_extension_desc: &str,
        vendor_extension_id: u32,
    ) -> Self {
        let m = format!("{manufacturer} {model} {vendor_extension_desc}").to_lowercase();
        let has = |s: &str| m.contains(s);
        if has("canon") {
            return Self::Canon;
        }
        if has("nikon") {
            return Self::Nikon;
        }
        if has("sony") {
            return Self::Sony;
        }
        if has("fuji") {
            return Self::Fujifilm;
        }
        // Pentax bodies report "RICOH IMAGING" as the maker: check the model first.
        if has("pentax") {
            return Self::Pentax;
        }
        if has("theta") || has("insta360") {
            return Self::Osc;
        }
        if has("ricoh") {
            return Self::Ricoh;
        }
        if has("leica") {
            return Self::Leica;
        }
        if has("olympus") || has("om digital") || has("om system") {
            return Self::Olympus;
        }
        if has("panasonic") || has("lumix") {
            return Self::Panasonic;
        }
        if has("hasselblad") {
            return Self::Hasselblad;
        }
        if has("sigma") {
            return Self::Sigma;
        }
        if has("samsung") {
            return Self::Samsung;
        }
        if has("gopro") {
            return Self::Gopro;
        }
        use vendor_extension as v;
        match vendor_extension_id {
            v::CANON => Self::Canon,
            v::NIKON => Self::Nikon,
            v::SONY => Self::Sony,
            v::FUJI => Self::Fujifilm,
            v::PANASONIC => Self::Panasonic,
            v::OLYMPUS => Self::Olympus,
            v::LEICA => Self::Leica,
            v::PENTAX => Self::Pentax,
            v::SAMSUNG => Self::Samsung,
            _ => Self::Generic,
        }
    }

    /// USB vendor IDs, used only to pre-filter the device list.
    pub fn usb_vendor_id(self) -> Option<u16> {
        match self {
            Self::Canon => Some(0x04A9),
            Self::Nikon => Some(0x04B0),
            Self::Sony => Some(0x054C),
            Self::Fujifilm => Some(0x04CB),
            Self::Ricoh | Self::Pentax => Some(0x25FB),
            Self::Leica => Some(0x1A98),
            Self::Olympus => Some(0x07B4),
            Self::Panasonic => Some(0x04DA),
            Self::Hasselblad => Some(0x2A5F),
            Self::Sigma => Some(0x1003),
            Self::Samsung => Some(0x04E8),
            Self::Gopro => Some(0x2672),
            Self::Osc | Self::Generic => None,
        }
    }

    /// Wireless control is limited to the brands whose protocols we implement.
    pub fn supports_wireless_control(self) -> bool {
        matches!(
            self,
            Self::Canon
                | Self::Nikon
                | Self::Sony
                | Self::Fujifilm
                | Self::Ricoh
                | Self::Gopro
                | Self::Osc
        )
    }

    /// The GR series only imports over USB (its control API is Wi-Fi only).
    pub fn supports_wired_control(self) -> bool {
        self != Self::Ricoh
    }

    /// Brands controlled over HTTP rather than PTP/IP on Wi-Fi.
    pub fn uses_http_control(self) -> bool {
        matches!(self, Self::Ricoh | Self::Gopro | Self::Osc)
    }
}

bitflags! {
    /// Runtime capability flags, assigned by the vendor handler from what the
    /// body reports, never from a per-model table. Bit values match iOS.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
    pub struct CameraCapabilities: u32 {
        const REMOTE_CAPTURE   = 1 << 0;
        const SDRAM_CAPTURE    = 1 << 1;
        const CARD_CAPTURE     = 1 << 2;
        const LIVE_VIEW        = 1 << 3;
        const PROPERTY_CONTROL = 1 << 4;
        const PARTIAL_TRANSFER = 1 << 5;
        const RATING           = 1 << 6;
        const REDUCED_IMAGE    = 1 << 7;
        const WIRELESS         = 1 << 8;
        const AUTOFOCUS        = 1 << 9;
        const BULB_CAPTURE     = 1 << 10;
        const THUMBNAILS       = 1 << 11;
        const EVENT_PUSH       = 1 << 12;
        const IMPORT_ONLY      = 1 << 13;
        const TOUCH_AUTOFOCUS  = 1 << 14;
    }
}

// Stored and sent as the raw bit mask, like iOS.
impl Serialize for CameraCapabilities {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_u32(self.bits())
    }
}

impl<'de> Deserialize<'de> for CameraCapabilities {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self::from_bits_retain(u32::deserialize(d)?))
    }
}

impl CameraCapabilities {
    pub fn summary(self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if self.contains(Self::REMOTE_CAPTURE) {
            out.push("Remote capture");
        }
        if self.contains(Self::SDRAM_CAPTURE) {
            out.push("Capture without card");
        }
        if self.contains(Self::LIVE_VIEW) {
            out.push("Live view");
        }
        if self.contains(Self::PROPERTY_CONTROL) {
            out.push("Exposure control");
        }
        if self.contains(Self::AUTOFOCUS) {
            out.push("Autofocus");
        }
        if self.contains(Self::PARTIAL_TRANSFER) {
            out.push("Resumable transfer");
        }
        if self.contains(Self::RATING) {
            out.push("Rating sync");
        }
        if self.contains(Self::IMPORT_ONLY) {
            out.push("Import only");
        }
        out
    }
}

/// Where the camera writes a capture. `Host` = SDRAM only; `Both` = card plus a copy to us.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CaptureDestination {
    Card,
    Host,
    Both,
}

impl CaptureDestination {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Card => "Card only",
            Self::Host => "Mac only (no card)",
            Self::Both => "Card + Mac",
        }
    }
    pub fn wants_transfer(self) -> bool {
        self != Self::Card
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TransportKind {
    /// ImageCaptureCore (requestSendPTPCommand).
    #[serde(rename = "usb")]
    Usb,
    /// In-house PTP/IP over TCP.
    #[serde(rename = "ptpip")]
    PtpIp,
    /// Ricoh GR / Theta HTTP + WebSocket controller.
    #[serde(rename = "ricohHTTP")]
    RicohHttp,
    /// The camera pushes files to our FTP server.
    #[serde(rename = "ftpPush")]
    FtpPush,
    /// GoPro / Open Spherical Camera HTTP APIs on the camera's Wi-Fi.
    #[serde(rename = "http")]
    Http,
}

impl TransportKind {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Usb => "USB",
            Self::PtpIp => "Wi-Fi (PTP/IP)",
            Self::RicohHttp => "Wi-Fi (Ricoh)",
            Self::FtpPush => "FTP push",
            Self::Http => "Wi-Fi",
        }
    }
}

/// A connected camera as the app shows it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraIdentity {
    /// Stable: `<vendor>-<serial>` when the serial is known, else a transport-provided id.
    pub id: String,
    pub vendor: CameraVendor,
    pub manufacturer: String,
    pub model: String,
    pub serial_number: String,
    pub firmware: String,
    pub transport: TransportKind,
    pub capabilities: CameraCapabilities,
}

impl CameraIdentity {
    pub fn display_name(&self) -> &str {
        if self.model.is_empty() {
            self.vendor.display_name()
        } else {
            &self.model
        }
    }

    /// The id rule from iOS: serial-based when known.
    pub fn stable_id(vendor: CameraVendor, serial: &str, fallback: &str) -> String {
        if serial.is_empty() {
            fallback.to_string()
        } else {
            format!("{}-{}", vendor.raw(), serial)
        }
    }
}

/// One live-view frame from the camera.
#[derive(Debug, Clone)]
pub struct LiveViewFrame {
    pub jpeg: Vec<u8>,
    pub sequence: u64,
    pub timestamp: DateTime<Utc>,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LiveViewQuality {
    Low,
    Medium,
    High,
}

/// Finds the JPEG inside a vendor live-view payload: from the first SOI
/// marker to the last EOI marker (vendor headers vary in length).
pub fn jpeg_payload(bytes: &[u8]) -> Option<&[u8]> {
    if bytes.len() < 4 {
        return None;
    }
    let start = bytes.windows(2).position(|w| w == [0xFF, 0xD8])?;
    let end = bytes[start..]
        .windows(2)
        .rposition(|w| w == [0xFF, 0xD9])
        .map(|i| start + i + 2)
        .filter(|&e| e > start + 2)
        .unwrap_or(bytes.len());
    Some(&bytes[start..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_pentax_before_ricoh() {
        assert_eq!(
            CameraVendor::detect("RICOH IMAGING", "PENTAX K-3 Mark III", "", 0),
            CameraVendor::Pentax
        );
        assert_eq!(
            CameraVendor::detect("RICOH", "GR III", "", 0),
            CameraVendor::Ricoh
        );
        assert_eq!(
            CameraVendor::detect("", "", "", vendor_extension::CANON),
            CameraVendor::Canon
        );
    }

    #[test]
    fn serialises_like_ios() {
        assert_eq!(
            serde_json::to_string(&TransportKind::RicohHttp).unwrap(),
            "\"ricohHTTP\""
        );
        assert_eq!(
            serde_json::to_string(&CameraVendor::Gopro).unwrap(),
            "\"gopro\""
        );
        let caps = CameraCapabilities::REMOTE_CAPTURE | CameraCapabilities::LIVE_VIEW;
        assert_eq!(serde_json::to_string(&caps).unwrap(), "9");
    }

    #[test]
    fn finds_jpeg_inside_header() {
        let data = [0u8, 1, 2, 0xFF, 0xD8, 9, 9, 0xFF, 0xD9, 7];
        assert_eq!(
            jpeg_payload(&data).unwrap(),
            &[0xFF, 0xD8, 9, 9, 0xFF, 0xD9]
        );
    }
}
