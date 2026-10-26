//! Probes the fixed addresses GoPro and OSC cameras use on their own access
//! point, so they show up in the Wi-Fi list without typing an address.
//! Ported from `HTTPCameraProbe` in `Vendors/HTTPCameras.swift`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;
use tether_types::{CameraVendor, TransportKind};
use tokio::sync::watch;
use tokio::task::JoinHandle;

use super::{
    split_host_port, CameraDiscovering, DiscoveredCamera, DiscoveryError, DiscoveryMethod,
    DiscoveryState, HttpProbing, ReqwestProber,
};
use crate::lock;

pub struct HttpCameraProbe {
    inner: Arc<Inner>,
    task: Mutex<Option<JoinHandle<()>>>,
}

struct Inner {
    state: DiscoveryState,
    prober: Arc<dyn HttpProbing>,
    gopro_host: String,
    osc_hosts: Vec<String>,
    interval: Duration,
    timeout: Duration,
}

impl Default for HttpCameraProbe {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpCameraProbe {
    /// Open GoPro API on the camera's access point (`GoProHandler.defaultHost`).
    pub const GOPRO_DEFAULT_HOST: &'static str = "10.5.5.9:8080";
    pub const GOPRO_INFO_PATH: &'static str = "/gopro/camera/info";
    /// Theta / Insta360 access-point addresses (`OSCHandler.defaultHosts`).
    pub const OSC_DEFAULT_HOSTS: [&'static str; 2] = ["192.168.1.1", "192.168.42.1"];
    pub const OSC_INFO_PATH: &'static str = "/osc/info";
    pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(10);
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(2);

    pub fn new() -> Self {
        Self::with_prober(Arc::new(ReqwestProber::new()))
    }

    pub fn with_prober(prober: Arc<dyn HttpProbing>) -> Self {
        Self::with_hosts(
            prober,
            Self::GOPRO_DEFAULT_HOST.to_string(),
            Self::OSC_DEFAULT_HOSTS
                .iter()
                .map(|s| s.to_string())
                .collect(),
        )
    }

    /// Probes other `host[:port]`s (tests point these at a local server).
    pub fn with_hosts(
        prober: Arc<dyn HttpProbing>,
        gopro_host: String,
        osc_hosts: Vec<String>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                state: DiscoveryState::new(),
                prober,
                gopro_host,
                osc_hosts,
                interval: Self::DEFAULT_INTERVAL,
                timeout: Self::DEFAULT_TIMEOUT,
            }),
            task: Mutex::new(None),
        }
    }

    pub fn current(&self) -> Vec<DiscoveredCamera> {
        self.inner.state.snapshot()
    }

    pub async fn probe_once(&self) {
        self.inner.probe_once().await
    }

    /// `GoProHandler.probe`: any JSON with `model_name` (top level or under `info`).
    pub fn gopro_model(body: &[u8]) -> Option<String> {
        let root: Value = serde_json::from_slice(body).ok()?;
        let info = root.get("info").filter(|v| v.is_object()).unwrap_or(&root);
        let model = info.get("model_name")?;
        Some(model.as_str().unwrap_or("GoPro").to_string())
    }

    /// `OSCHandler.probe`: any JSON object with `model`.
    pub fn osc_model(body: &[u8]) -> Option<String> {
        let root: Value = serde_json::from_slice(body).ok()?;
        let model = root.as_object()?.get("model")?;
        Some(model.as_str().unwrap_or("360° camera").to_string())
    }
}

impl Inner {
    async fn probe_once(&self) {
        let mut found: Vec<DiscoveredCamera> = Vec::new();
        let url = format!(
            "http://{}{}",
            self.gopro_host,
            HttpCameraProbe::GOPRO_INFO_PATH
        );
        if let Ok((body, 200)) = self.prober.get(&url, self.timeout).await {
            if let Some(model) = HttpCameraProbe::gopro_model(&body) {
                let (host, port) = split_host_port(&self.gopro_host, 8080);
                found.push(DiscoveredCamera::new(
                    self.gopro_host.clone(),
                    model,
                    Some(CameraVendor::Gopro),
                    host,
                    port,
                    DiscoveryMethod::HttpProbe,
                    TransportKind::Http,
                ));
            }
        }
        for h in &self.osc_hosts {
            let url = format!("http://{h}{}", HttpCameraProbe::OSC_INFO_PATH);
            let Ok((body, 200)) = self.prober.get(&url, self.timeout).await else {
                continue;
            };
            let Some(model) = HttpCameraProbe::osc_model(&body) else {
                continue;
            };
            let (host, port) = split_host_port(h, 80);
            found.push(DiscoveredCamera::new(
                h.clone(),
                model,
                Some(CameraVendor::Osc),
                host,
                port,
                DiscoveryMethod::HttpProbe,
                TransportKind::Http,
            ));
        }
        let ids: Vec<String> = found.iter().map(|c| c.id.clone()).collect();
        self.state.remove(|c| !ids.contains(&c.id));
        for cam in found {
            self.state.upsert(cam);
        }
    }
}

#[async_trait]
impl CameraDiscovering for HttpCameraProbe {
    fn cameras(&self) -> watch::Receiver<Vec<DiscoveredCamera>> {
        self.inner.state.subscribe()
    }

    async fn start(&self) -> Result<(), DiscoveryError> {
        let mut task = lock(&self.task);
        if task.is_some() {
            return Ok(());
        }
        let inner = self.inner.clone();
        *task = Some(tokio::spawn(async move {
            loop {
                inner.probe_once().await;
                tokio::time::sleep(inner.interval).await;
            }
        }));
        Ok(())
    }

    async fn stop(&self) {
        if let Some(t) = lock(&self.task).take() {
            t.abort();
        }
    }

    fn source_name(&self) -> &'static str {
        "HTTPCameraProbe"
    }
}

impl Drop for HttpCameraProbe {
    fn drop(&mut self) {
        if let Some(t) = lock(&self.task).take() {
            t.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_bodies() {
        assert_eq!(
            HttpCameraProbe::gopro_model(br#"{"info":{"model_name":"HERO12 Black"}}"#).as_deref(),
            Some("HERO12 Black")
        );
        assert_eq!(
            HttpCameraProbe::gopro_model(br#"{"model_name":"HERO9"}"#).as_deref(),
            Some("HERO9")
        );
        assert!(HttpCameraProbe::gopro_model(b"{}").is_none());
        assert_eq!(
            HttpCameraProbe::osc_model(br#"{"model":"RICOH THETA X"}"#).as_deref(),
            Some("RICOH THETA X")
        );
        assert!(HttpCameraProbe::osc_model(b"[1]").is_none());
    }
}
