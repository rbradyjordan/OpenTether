//! Bonjour (mDNS) discovery of PTP/IP cameras via `mdns-sd`. Each found
//! service is resolved; the first usable IPv4 address wins.
//! Ported from `BonjourDiscoverer.swift` (NetServiceBrowser there).

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use mdns_sd::{ServiceDaemon, ServiceEvent};
use tether_types::TransportKind;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use super::{CameraDiscovering, DiscoveredCamera, DiscoveryError, DiscoveryMethod, DiscoveryState};
use crate::net::ip_filter;
use crate::{lock, PTPIP_STANDARD_PORT};

/// Brand from what a camera calls itself on mDNS (`BonjourBrandMapper`).
/// Canon advertises `_ptp._tcp` with hostnames like `EOSR5-xxxx.local` /
/// `nicname.canon.com`, Nikon `_ptp._tcp`/`_lnp._tcp` (`NIKON Z 6_2`), Sony
/// `ILCE-7M4`, Fuji `X-T5` / `GFX100`, Leica `LEICA SL2`, OM `OM-1`, Lumix `LUMIX S5`.
pub mod brand {
    use tether_types::CameraVendor;

    /// Service types browsed, in Bonjour's own spelling (domain appended when browsing).
    pub const SERVICE_TYPES: [&str; 3] = ["_ptp._tcp.", "_lnp._tcp.", "_bonjour._tcp."];

    pub fn vendor_for(host: Option<&str>, service_name: Option<&str>) -> Option<CameraVendor> {
        let hay = format!("{} {}", host.unwrap_or(""), service_name.unwrap_or("")).to_lowercase();
        let has = |s: &str| hay.contains(s);
        let any = |list: &[&str]| list.iter().any(|s| hay.contains(s));
        if any(&["canon", "nicname.canon.com", "eos"]) {
            return Some(CameraVendor::Canon);
        }
        if has("nikon") {
            return Some(CameraVendor::Nikon);
        }
        if any(&["sony", "ilce", "dsc-", "ilme", "zv-"]) {
            return Some(CameraVendor::Sony);
        }
        if any(&["fuji", "x-t", "gfx", "x-h", "x-pro", "x-s", "x100"]) {
            return Some(CameraVendor::Fujifilm);
        }
        if has("leica") {
            return Some(CameraVendor::Leica);
        }
        if any(&["olympus", "om-", "om system", "e-m"]) {
            return Some(CameraVendor::Olympus);
        }
        if any(&["lumix", "panasonic", "dc-"]) {
            return Some(CameraVendor::Panasonic);
        }
        if has("hasselblad") {
            return Some(CameraVendor::Hasselblad);
        }
        if any(&["ricoh", "pentax"]) {
            return Some(CameraVendor::Ricoh);
        }
        None
    }
}

pub struct BonjourDiscoverer {
    state: Arc<DiscoveryState>,
    running: Mutex<Option<Running>>,
}

struct Running {
    daemon: ServiceDaemon,
    tasks: Vec<JoinHandle<()>>,
}

impl Default for BonjourDiscoverer {
    fn default() -> Self {
        Self::new()
    }
}

impl BonjourDiscoverer {
    pub fn new() -> Self {
        Self {
            state: Arc::new(DiscoveryState::new()),
            running: Mutex::new(None),
        }
    }

    pub fn current(&self) -> Vec<DiscoveredCamera> {
        self.state.snapshot()
    }

    pub fn last_error(&self) -> Option<String> {
        self.state.last_error()
    }

    pub fn identifier(service_name: &str) -> String {
        format!("bonjour:{service_name}")
    }

    /// Pure mapping from a resolved service to an entry.
    pub fn camera(
        service_name: &str,
        service_type: &str,
        host_name: Option<&str>,
        host: &str,
        port: u16,
        txt: &BTreeMap<String, String>,
    ) -> DiscoveredCamera {
        let vendor = brand::vendor_for(host_name, Some(service_name)).or_else(|| {
            brand::vendor_for(
                txt.get("ty").map(String::as_str),
                txt.get("model").map(String::as_str),
            )
        });
        let mut details = BTreeMap::from([("serviceType".to_string(), service_type.to_string())]);
        if let Some(h) = host_name {
            details.insert("hostname".into(), h.to_string());
        }
        for (k, v) in txt {
            details.insert(format!("txt.{k}"), v.clone());
        }
        if let Some(model) = txt.get("ty").or_else(|| txt.get("model")) {
            details.insert("model".into(), model.clone());
        }
        DiscoveredCamera::new(
            Self::identifier(service_name),
            service_name,
            vendor,
            host,
            port,
            DiscoveryMethod::Bonjour,
            TransportKind::PtpIp,
        )
        .with_details(details)
    }
}

/// `Instance._ptp._tcp.local.` → `Instance` (given the browsed type).
fn instance_name<'a>(fullname: &'a str, ty_domain: &str) -> &'a str {
    fullname
        .strip_suffix(ty_domain)
        .and_then(|s| s.strip_suffix('.'))
        .unwrap_or(fullname)
}

async fn browse_loop(
    state: Arc<DiscoveryState>,
    service_type: &'static str,
    ty_domain: String,
    rx: mdns_sd::Receiver<ServiceEvent>,
) {
    while let Ok(event) = rx.recv_async().await {
        match event {
            ServiceEvent::ServiceResolved(info) => {
                let addresses: Vec<String> =
                    info.get_addresses().iter().map(|a| a.to_string()).collect();
                let Some(host) = ip_filter::preferred(&addresses) else {
                    continue;
                };
                let txt: BTreeMap<String, String> = info
                    .get_properties()
                    .iter()
                    .map(|p| (p.key().to_string(), p.val_str().to_string()))
                    .collect();
                let hostname = info.get_hostname();
                let port = if info.get_port() > 0 {
                    info.get_port()
                } else {
                    PTPIP_STANDARD_PORT
                };
                let name = instance_name(info.get_fullname(), &ty_domain);
                state.upsert(BonjourDiscoverer::camera(
                    name,
                    service_type,
                    (!hostname.is_empty()).then_some(hostname),
                    &host,
                    port,
                    &txt,
                ));
            }
            ServiceEvent::ServiceRemoved(_, fullname) => {
                let id = BonjourDiscoverer::identifier(instance_name(&fullname, &ty_domain));
                state.remove(|c| c.id == id);
            }
            _ => {}
        }
    }
}

#[async_trait]
impl CameraDiscovering for BonjourDiscoverer {
    fn cameras(&self) -> watch::Receiver<Vec<DiscoveredCamera>> {
        self.state.subscribe()
    }

    async fn start(&self) -> Result<(), DiscoveryError> {
        let mut running = lock(&self.running);
        if running.is_some() {
            return Ok(());
        }
        let daemon = ServiceDaemon::new().map_err(|e| DiscoveryError::Mdns(e.to_string()))?;
        let mut tasks = Vec::new();
        for ty in brand::SERVICE_TYPES {
            let ty_domain = format!("{ty}local.");
            match daemon.browse(&ty_domain) {
                Ok(rx) => tasks.push(tokio::spawn(browse_loop(
                    self.state.clone(),
                    ty,
                    ty_domain,
                    rx,
                ))),
                Err(e) => self.state.fail(format!("Bonjour browse failed: {e}")),
            }
        }
        *running = Some(Running { daemon, tasks });
        Ok(())
    }

    async fn stop(&self) {
        let r = lock(&self.running).take();
        if let Some(r) = r {
            for t in r.tasks {
                t.abort();
            }
            let _ = r.daemon.shutdown();
        }
        self.state.clear();
    }

    fn source_name(&self) -> &'static str {
        "BonjourDiscoverer"
    }
}

impl Drop for BonjourDiscoverer {
    fn drop(&mut self) {
        if let Some(r) = lock(&self.running).take() {
            for t in r.tasks {
                t.abort();
            }
            let _ = r.daemon.shutdown();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tether_types::CameraVendor;

    #[test]
    fn brand_mapper() {
        use brand::vendor_for as v;
        assert_eq!(
            v(Some("EOSR5-123456.local."), Some("Canon EOS R5")),
            Some(CameraVendor::Canon)
        );
        assert_eq!(
            v(Some("abc.nicname.canon.com"), None),
            Some(CameraVendor::Canon)
        );
        assert_eq!(
            v(Some("NIKON-Z6_2.local."), Some("Z 6_2")),
            Some(CameraVendor::Nikon)
        );
        assert_eq!(v(None, Some("ILCE-7M4")), Some(CameraVendor::Sony));
        assert_eq!(
            v(Some("DSC-RX100M7.local."), None),
            Some(CameraVendor::Sony)
        );
        assert_eq!(v(None, Some("X-T5")), Some(CameraVendor::Fujifilm));
        assert_eq!(
            v(Some("GFX100S.local."), Some("FUJIFILM GFX100S")),
            Some(CameraVendor::Fujifilm)
        );
        assert_eq!(v(None, Some("LEICA SL2")), Some(CameraVendor::Leica));
        assert_eq!(v(Some("OM-1.local."), None), Some(CameraVendor::Olympus));
        assert_eq!(v(None, Some("Olympus E-M1X")), Some(CameraVendor::Olympus));
        assert_eq!(v(None, Some("LUMIX S5")), Some(CameraVendor::Panasonic));
        assert_eq!(
            v(Some("panasonic-dc-gh6.local."), None),
            Some(CameraVendor::Panasonic)
        );
        assert_eq!(v(Some("printer.local."), Some("HP LaserJet")), None);
        assert_eq!(v(None, None), None);
    }

    #[test]
    fn camera_mapping_with_txt() {
        let txt = BTreeMap::from([("ty".to_string(), "Canon EOS R6".to_string())]);
        let cam = BonjourDiscoverer::camera(
            "Canon EOS R6",
            "_ptp._tcp.",
            Some("EOSR6-ABC.local."),
            "192.168.1.30",
            15740,
            &txt,
        );
        assert_eq!(cam.id, "bonjour:Canon EOS R6");
        assert_eq!(cam.vendor, Some(CameraVendor::Canon));
        assert_eq!(cam.method, DiscoveryMethod::Bonjour);
        assert_eq!(cam.transport, TransportKind::PtpIp);
        assert_eq!(cam.details["serviceType"], "_ptp._tcp.");
        assert_eq!(cam.details["hostname"], "EOSR6-ABC.local.");
        assert_eq!(cam.details["model"], "Canon EOS R6");
        assert_eq!(cam.details["txt.ty"], "Canon EOS R6");
        assert!(cam.is_controllable());
        // Brand only in TXT.
        let txt = BTreeMap::from([("model".to_string(), "NIKON Z 8".to_string())]);
        let cam = BonjourDiscoverer::camera("cam", "_ptp._tcp.", None, "10.0.0.3", 15740, &txt);
        assert_eq!(cam.vendor, Some(CameraVendor::Nikon));
        // Unknown brand still surfaces (generic PTP/IP) but uncontrollable.
        let unknown = BonjourDiscoverer::camera(
            "Mystery",
            "_ptp._tcp.",
            None,
            "10.0.0.2",
            15740,
            &BTreeMap::new(),
        );
        assert_eq!(unknown.vendor, None);
        assert!(!unknown.is_controllable());
    }

    #[test]
    fn instance_names() {
        assert_eq!(
            instance_name("Canon EOS R6._ptp._tcp.local.", "_ptp._tcp.local."),
            "Canon EOS R6"
        );
        assert_eq!(instance_name("odd", "_ptp._tcp.local."), "odd");
    }
}
