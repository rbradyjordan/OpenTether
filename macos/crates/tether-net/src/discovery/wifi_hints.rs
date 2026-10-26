//! Camera access-point naming conventions → brand (`CameraWiFiHints` in
//! `SSIDMonitor.swift`). Used for the "you're on a camera network" hint, not
//! for routing. macOS does not give a sandboxed app the Wi-Fi name, so the
//! caller supplies it (typed by the user, or from a future CoreWLAN bridge).

use tether_types::CameraVendor;

pub fn looks_like_camera_network(ssid: &str) -> Option<CameraVendor> {
    let u = ssid.trim_matches(|c| c == ' ' || c == '\t').to_uppercase();
    let starts = |list: &[&str]| list.iter().any(|p| u.starts_with(p));
    if starts(&["EOS", "CANON"]) || u.contains("_CANON") {
        return Some(CameraVendor::Canon);
    }
    if starts(&["NIKON", "Z 5", "Z5_", "Z6_", "Z7_", "D850"]) {
        return Some(CameraVendor::Nikon);
    }
    if starts(&["DIRECT-"]) {
        return Some(CameraVendor::Sony);
    }
    if starts(&["FUJIFILM", "X-T", "X-H", "GFX", "X-PRO", "X100"]) {
        return Some(CameraVendor::Fujifilm);
    }
    if starts(&["GR_", "GR-", "RICOH", "THETA", "PENTAX"]) {
        return Some(CameraVendor::Ricoh);
    }
    if starts(&["LEICA"]) {
        return Some(CameraVendor::Leica);
    }
    if starts(&["OM-", "OLYMPUS", "E-M", "OMSYSTEM"]) {
        return Some(CameraVendor::Olympus);
    }
    if starts(&["LUMIX", "PANASONIC", "DC-"]) {
        return Some(CameraVendor::Panasonic);
    }
    if starts(&["HASSELBLAD"]) {
        return Some(CameraVendor::Hasselblad);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn camera_network_hints() {
        let h = looks_like_camera_network;
        assert_eq!(h("EOSR5_123-456_Canon0A"), Some(CameraVendor::Canon));
        assert_eq!(h("Canon EOS R6"), Some(CameraVendor::Canon));
        assert_eq!(h("Nikon Z 6_2"), Some(CameraVendor::Nikon));
        assert_eq!(h("DIRECT-xyz:ILCE-7M4"), Some(CameraVendor::Sony));
        assert_eq!(h("FUJIFILM-X-T5-ABCD"), Some(CameraVendor::Fujifilm));
        assert_eq!(h("GR_ABC123"), Some(CameraVendor::Ricoh));
        assert_eq!(h("RICOH GR IIIx"), Some(CameraVendor::Ricoh));
        assert_eq!(h("Leica SL2-S"), Some(CameraVendor::Leica));
        assert_eq!(h("OM-1-ABC"), Some(CameraVendor::Olympus));
        assert_eq!(h("LUMIX-S5II"), Some(CameraVendor::Panasonic));
        assert_eq!(h("HomeWiFi-5G"), None);
        assert_eq!(h(""), None);
    }
}
