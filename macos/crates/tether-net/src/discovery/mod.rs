//! Camera discovery on the local network. Each source implements
//! [`CameraDiscovering`] and publishes its full current list through a watch
//! channel; [`CameraDiscoverer`] merges every source into one deduplicated,
//! expiring list (with user-entered manual cameras on top).
//! Ported from `TetherCore/Discovery/`.

mod aggregator;
mod bonjour;
mod fuji;
mod http_cameras;
mod http_probe;
mod ricoh;
mod ssdp;
pub mod wifi_hints;

use std::collections::BTreeMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tether_types::{CameraVendor, TransportKind};
use tokio::sync::watch;

pub use aggregator::CameraDiscoverer;
pub use bonjour::{brand as bonjour_brand, BonjourDiscoverer};
pub use fuji::{
    datagram as fuji_datagram, parse_dial_back as fuji_parse_dial_back, FujiConstants,
    FujiDialBack, FujiDiscoverer, FujiOptions,
};
pub use http_cameras::HttpCameraProbe;
pub use http_probe::{HttpProbing, ProbeError, ReqwestProber};
pub use ricoh::RicohProbe;
pub use ssdp::{SsdpDeviceDescription, SsdpDiscoverer, SsdpMessage};

use crate::lock;

/// How a camera was found. Serialised names match the Swift raw values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DiscoveryMethod {
    #[serde(rename = "ssdp")]
    Ssdp,
    #[serde(rename = "bonjour")]
    Bonjour,
    #[serde(rename = "fujiUDP")]
    FujiUdp,
    #[serde(rename = "ricohHTTP")]
    RicohHttp,
    #[serde(rename = "httpProbe")]
    HttpProbe,
    #[serde(rename = "manual")]
    Manual,
}

/// A camera seen on the network but not yet connected. `id` is the dedupe
/// key: UUID/USN for SSDP, service name for Bonjour, host for Fuji, Ricoh and
/// manual entries.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredCamera {
    pub id: String,
    pub name: String,
    pub vendor: Option<CameraVendor>,
    pub host: String,
    pub port: u16,
    pub method: DiscoveryMethod,
    pub transport: TransportKind,
    pub last_seen: DateTime<Utc>,
    pub details: BTreeMap<String, String>,
}

impl DiscoveredCamera {
    /// A fresh entry seen now, with no details.
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        vendor: Option<CameraVendor>,
        host: impl Into<String>,
        port: u16,
        method: DiscoveryMethod,
        transport: TransportKind,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            vendor,
            host: host.into(),
            port,
            method,
            transport,
            last_seen: Utc::now(),
            details: BTreeMap::new(),
        }
    }

    pub fn with_details(mut self, details: BTreeMap<String, String>) -> Self {
        self.details = details;
        self
    }

    /// True when we implement a wireless protocol for this brand.
    pub fn is_controllable(&self) -> bool {
        self.vendor
            .map(|v| v.supports_wireless_control())
            .unwrap_or(false)
    }
}

/// Errors starting a discovery source.
#[derive(Debug, thiserror::Error)]
pub enum DiscoveryError {
    #[error("Could not bind {what}: {source}")]
    Bind {
        what: String,
        #[source]
        source: std::io::Error,
    },
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("mDNS: {0}")]
    Mdns(String),
}

/// One discovery source. `cameras` yields the source's full current list and
/// re-emits it whenever it changes; every call gets its own receiver that
/// starts with the latest list.
#[async_trait]
pub trait CameraDiscovering: Send + Sync {
    fn cameras(&self) -> watch::Receiver<Vec<DiscoveredCamera>>;
    async fn start(&self) -> Result<(), DiscoveryError>;
    async fn stop(&self);

    /// Name used as the key in [`CameraDiscoverer::last_errors`] and in the
    /// `source` detail (the Swift type name). Defaults to the Rust type name.
    fn source_name(&self) -> &'static str {
        let full = std::any::type_name::<Self>();
        full.rsplit("::").next().unwrap_or(full)
    }
}

/// Shared state keeper for discoverers: a keyed list plus the watch channel.
/// Public so other crates (and tests) can implement their own sources.
pub struct DiscoveryState {
    entries: Mutex<BTreeMap<String, DiscoveredCamera>>,
    tx: watch::Sender<Vec<DiscoveredCamera>>,
    last_error: Mutex<Option<String>>,
}

impl Default for DiscoveryState {
    fn default() -> Self {
        Self::new()
    }
}

impl DiscoveryState {
    pub fn new() -> Self {
        let (tx, _) = watch::channel(Vec::new());
        Self {
            entries: Mutex::new(BTreeMap::new()),
            tx,
            last_error: Mutex::new(None),
        }
    }

    pub fn subscribe(&self) -> watch::Receiver<Vec<DiscoveredCamera>> {
        self.tx.subscribe()
    }

    /// Current list, sorted by id.
    pub fn snapshot(&self) -> Vec<DiscoveredCamera> {
        lock(&self.entries).values().cloned().collect()
    }

    pub fn upsert(&self, camera: DiscoveredCamera) {
        let list = {
            let mut e = lock(&self.entries);
            e.insert(camera.id.clone(), camera);
            e.values().cloned().collect()
        };
        self.tx.send_replace(list);
    }

    /// Removes matching entries; publishes only when something went.
    pub fn remove(&self, predicate: impl Fn(&DiscoveredCamera) -> bool) {
        let list = {
            let mut e = lock(&self.entries);
            let before = e.len();
            e.retain(|_, c| !predicate(c));
            if e.len() == before {
                return;
            }
            e.values().cloned().collect()
        };
        self.tx.send_replace(list);
    }

    pub fn clear(&self) {
        lock(&self.entries).clear();
        self.tx.send_replace(Vec::new());
    }

    pub fn fail(&self, message: impl Into<String>) {
        let message = message.into();
        tracing::debug!("discovery: {message}");
        *lock(&self.last_error) = Some(message);
    }

    pub fn last_error(&self) -> Option<String> {
        lock(&self.last_error).clone()
    }
}

/// Splits `host[:port]` (IPv4 or hostname), defaulting the port.
pub(crate) fn split_host_port(s: &str, default_port: u16) -> (String, u16) {
    match s.rsplit_once(':') {
        Some((h, p)) if !h.contains(':') => match p.parse() {
            Ok(port) => (h.to_string(), port),
            Err(_) => (s.to_string(), default_port),
        },
        _ => (s.to_string(), default_port),
    }
}

/// Renders a JSON value the way Swift's `"\(value)"` does for
/// `JSONSerialization` output (strings bare, booleans as 1/0).
pub(crate) fn json_value_text(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Bool(b) => if *b { "1" } else { "0" }.to_string(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialises_like_swift() {
        let cam = DiscoveredCamera::new(
            "x",
            "X",
            Some(CameraVendor::Fujifilm),
            "1.2.3.4",
            15740,
            DiscoveryMethod::FujiUdp,
            TransportKind::PtpIp,
        );
        let json = serde_json::to_value(&cam).unwrap();
        assert_eq!(json["method"], "fujiUDP");
        assert_eq!(json["transport"], "ptpip");
        assert_eq!(json["vendor"], "fujifilm");
        assert!(json.get("lastSeen").is_some());
        assert!(cam.is_controllable());
    }

    #[test]
    fn splits_host_port() {
        assert_eq!(
            split_host_port("10.5.5.9:8080", 80),
            ("10.5.5.9".to_string(), 8080)
        );
        assert_eq!(
            split_host_port("192.168.1.1", 80),
            ("192.168.1.1".to_string(), 80)
        );
        assert_eq!(split_host_port("fd00::1", 80), ("fd00::1".to_string(), 80));
    }
}
