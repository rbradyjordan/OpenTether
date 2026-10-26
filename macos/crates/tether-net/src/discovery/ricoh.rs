//! Ricoh GR / Theta expose an HTTP API on their own access point at a fixed
//! address. We poll `/v1/props` and accept any 200 whose JSON names a model.
//! Ported from `RicohProbe.swift`.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{CameraVendor, TransportKind};
use tokio::sync::watch;
use tokio::task::JoinHandle;

use super::{
    json_value_text, CameraDiscovering, DiscoveredCamera, DiscoveryError, DiscoveryMethod,
    DiscoveryState, HttpProbing, ReqwestProber,
};
use crate::lock;

pub struct RicohProbe {
    inner: Arc<Inner>,
    task: Mutex<Option<JoinHandle<()>>>,
}

struct Inner {
    state: DiscoveryState,
    prober: Arc<dyn HttpProbing>,
    url: String,
    interval: Duration,
    timeout: Duration,
}

impl Default for RicohProbe {
    fn default() -> Self {
        Self::new()
    }
}

impl RicohProbe {
    pub const DEFAULT_HOST: &'static str = "192.168.0.1";
    pub const DEFAULT_URL: &'static str = "http://192.168.0.1/v1/props";
    pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(10);
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(2);

    pub fn new() -> Self {
        Self::with_prober(Arc::new(ReqwestProber::new()), Self::DEFAULT_URL)
    }

    pub fn with_prober(prober: Arc<dyn HttpProbing>, url: impl Into<String>) -> Self {
        Self::configured(
            prober,
            url.into(),
            Self::DEFAULT_INTERVAL,
            Self::DEFAULT_TIMEOUT,
        )
    }

    /// Full control over the poll interval and per-request timeout.
    pub fn configured(
        prober: Arc<dyn HttpProbing>,
        url: String,
        interval: Duration,
        timeout: Duration,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                state: DiscoveryState::new(),
                prober,
                url,
                interval,
                timeout,
            }),
            task: Mutex::new(None),
        }
    }

    pub fn current(&self) -> Vec<DiscoveredCamera> {
        self.inner.state.snapshot()
    }

    pub fn last_error(&self) -> Option<String> {
        self.inner.state.last_error()
    }

    /// One GET; emits or removes the entry.
    pub async fn probe_once(&self) {
        self.inner.probe_once().await
    }

    /// Pure: builds the entry from a `/v1/props` body. Requires a `model`.
    pub fn camera_from_props(body: &[u8], host: &str) -> Option<DiscoveredCamera> {
        let obj: serde_json::Map<String, serde_json::Value> = serde_json::from_slice(body).ok()?;
        let model = obj.get("model")?.as_str()?.trim();
        if model.is_empty() {
            return None;
        }
        let mut details = BTreeMap::from([("model".to_string(), model.to_string())]);
        for key in [
            "serialNumber",
            "firmwareVersion",
            "manufacturer",
            "batteryLevel",
            "channel",
            "ssid",
        ] {
            if let Some(v) = obj.get(key) {
                details.insert(key.to_string(), json_value_text(v));
            }
        }
        Some(
            DiscoveredCamera::new(
                host,
                model,
                Some(CameraVendor::Ricoh),
                host,
                80,
                DiscoveryMethod::RicohHttp,
                TransportKind::RicohHttp,
            )
            .with_details(details),
        )
    }
}

impl Inner {
    async fn probe_once(&self) {
        match self.prober.get(&self.url, self.timeout).await {
            Ok((body, status)) => {
                let host = reqwest::Url::parse(&self.url)
                    .ok()
                    .and_then(|u| u.host_str().map(str::to_string))
                    .unwrap_or_else(|| RicohProbe::DEFAULT_HOST.to_string());
                match (status == 200)
                    .then(|| RicohProbe::camera_from_props(&body, &host))
                    .flatten()
                {
                    Some(cam) => self.state.upsert(cam),
                    None => self.state.remove(|_| true),
                }
            }
            Err(e) => {
                self.state.fail(format!("Ricoh probe: {e}"));
                // No reply: the camera AP isn't the current network. Drop stale entries.
                self.state.remove(|_| true);
            }
        }
    }
}

#[async_trait]
impl CameraDiscovering for RicohProbe {
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
        "RicohProbe"
    }
}

impl Drop for RicohProbe {
    fn drop(&mut self) {
        if let Some(t) = lock(&self.task).take() {
            t.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const PROPS: &str = r#"{"errCode":200,"errMsg":"OK","model":"RICOH GR IIIx","firmwareVersion":"1.50","serialNumber":"1234567","batteryLevel":80}"#;

    #[test]
    fn camera_from_props() {
        let cam = RicohProbe::camera_from_props(PROPS.as_bytes(), "192.168.0.1").unwrap();
        assert_eq!(cam.name, "RICOH GR IIIx");
        assert_eq!(cam.vendor, Some(CameraVendor::Ricoh));
        assert_eq!(cam.transport, TransportKind::RicohHttp);
        assert_eq!(cam.method, DiscoveryMethod::RicohHttp);
        assert_eq!(cam.port, 80);
        assert_eq!(cam.id, "192.168.0.1");
        assert_eq!(cam.details["firmwareVersion"], "1.50");
        assert_eq!(cam.details["batteryLevel"], "80");
        assert!(RicohProbe::camera_from_props(br#"{"errCode":200}"#, "x").is_none());
        assert!(RicohProbe::camera_from_props(b"<html>", "x").is_none());
    }
}
