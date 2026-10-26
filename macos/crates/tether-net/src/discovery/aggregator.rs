//! Aggregates every discovery source into one deduplicated list. Entries not
//! re-seen within `expiry` disappear; a source that fails to start is logged
//! in `last_errors` and the others keep going. Ported from `CameraDiscoverer.swift`.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use chrono::{TimeDelta, Utc};
use tether_types::{CameraVendor, TransportKind};
use tokio::sync::watch;
use tokio::task::JoinHandle;

use super::{
    BonjourDiscoverer, CameraDiscovering, DiscoveredCamera, DiscoveryError, DiscoveryMethod,
    FujiDiscoverer, HttpCameraProbe, RicohProbe, SsdpDiscoverer,
};
use crate::{lock, net};

pub struct CameraDiscoverer {
    expiry: Duration,
    sweep_interval: Duration,
    sources: Vec<Arc<dyn CameraDiscovering>>,
    inner: Arc<Inner>,
}

struct Inner {
    state: Mutex<State>,
    tx: watch::Sender<Vec<DiscoveredCamera>>,
    expiry: Duration,
}

#[derive(Default)]
struct State {
    entries: HashMap<String, DiscoveredCamera>,
    manual: HashMap<String, DiscoveredCamera>,
    errors: BTreeMap<String, String>,
    running: bool,
    tasks: Vec<JoinHandle<()>>,
}

impl Default for CameraDiscoverer {
    fn default() -> Self {
        Self::new(Self::DEFAULT_EXPIRY)
    }
}

impl CameraDiscoverer {
    pub const DEFAULT_EXPIRY: Duration = Duration::from_secs(30);
    pub const DEFAULT_SWEEP_INTERVAL: Duration = Duration::from_secs(5);

    /// Default sources: SSDP (Sony), Bonjour (Canon/Nikon/…), Fuji dial-back,
    /// and probes of the fixed addresses Ricoh GR, GoPro and OSC 360° cameras use.
    pub fn new(expiry: Duration) -> Self {
        Self::with_sources(
            vec![
                Arc::new(SsdpDiscoverer::new()),
                Arc::new(BonjourDiscoverer::new()),
                Arc::new(FujiDiscoverer::default()),
                Arc::new(RicohProbe::new()),
                Arc::new(HttpCameraProbe::new()),
            ],
            expiry,
            Self::DEFAULT_SWEEP_INTERVAL,
        )
    }

    pub fn with_sources(
        sources: Vec<Arc<dyn CameraDiscovering>>,
        expiry: Duration,
        sweep_interval: Duration,
    ) -> Self {
        let (tx, _) = watch::channel(Vec::new());
        Self {
            expiry,
            sweep_interval,
            sources,
            inner: Arc::new(Inner {
                state: Mutex::new(State::default()),
                tx,
                expiry,
            }),
        }
    }

    pub fn expiry(&self) -> Duration {
        self.expiry
    }

    pub fn sweep_interval(&self) -> Duration {
        self.sweep_interval
    }

    /// The merged list now: controllable cameras first, then by id.
    pub fn current(&self) -> Vec<DiscoveredCamera> {
        merged(&lock(&self.inner.state))
    }

    /// Source name → last start error.
    pub fn last_errors(&self) -> BTreeMap<String, String> {
        lock(&self.inner.state).errors.clone()
    }

    pub fn local_ipv4_addresses() -> Vec<String> {
        net::local_ipv4_addresses()
    }

    pub fn broadcast_addresses() -> Vec<String> {
        net::broadcast_addresses()
    }

    /// Adds (or refreshes) a user-entered camera and returns its id. Manual
    /// entries never expire. Pass [`crate::PTPIP_STANDARD_PORT`] for PTP/IP bodies.
    pub fn add_manual(
        &self,
        host: &str,
        port: u16,
        vendor: Option<CameraVendor>,
        name: Option<&str>,
    ) -> String {
        let transport = match vendor {
            Some(CameraVendor::Ricoh) => TransportKind::RicohHttp,
            Some(CameraVendor::Gopro) | Some(CameraVendor::Osc) => TransportKind::Http,
            _ => TransportKind::PtpIp,
        };
        let name = name
            .map(str::to_string)
            .or_else(|| vendor.map(|v| v.display_name().to_string()))
            .unwrap_or_else(|| host.to_string());
        let mut cam = DiscoveredCamera::new(
            format!("manual:{host}:{port}"),
            name,
            vendor,
            host,
            port,
            DiscoveryMethod::Manual,
            transport,
        );
        let controllable = cam.is_controllable();
        cam.details
            .insert("controllable".into(), controllable.to_string());
        let id = cam.id.clone();
        lock(&self.inner.state).manual.insert(id.clone(), cam);
        self.inner.publish();
        id
    }

    pub fn remove_manual(&self, id: &str) {
        lock(&self.inner.state).manual.remove(id);
        self.inner.publish();
    }

    /// Drops every expired entry now (also runs on the sweep timer).
    pub fn sweep(&self) {
        self.inner.sweep()
    }
}

fn merged(state: &State) -> Vec<DiscoveredCamera> {
    let mut all = state.entries.clone();
    for (k, v) in &state.manual {
        all.entry(k.clone()).or_insert_with(|| v.clone());
    }
    let mut list: Vec<DiscoveredCamera> = all.into_values().collect();
    list.sort_by(|a, b| {
        b.is_controllable()
            .cmp(&a.is_controllable())
            .then_with(|| a.id.cmp(&b.id))
    });
    list
}

impl Inner {
    fn publish(&self) {
        let list = merged(&lock(&self.state));
        self.tx.send_replace(list);
    }

    fn sweep(&self) {
        let cutoff = Utc::now() - TimeDelta::from_std(self.expiry).unwrap_or(TimeDelta::MAX);
        let changed = {
            let mut st = lock(&self.state);
            let before = st.entries.len();
            st.entries.retain(|_, c| c.last_seen >= cutoff);
            st.entries.len() != before
        };
        if changed {
            self.publish();
        }
    }

    fn absorb(&self, list: Vec<DiscoveredCamera>, source: &str) {
        {
            let mut st = lock(&self.state);
            let now = Utc::now();
            for mut cam in list {
                let controllable = cam.is_controllable();
                cam.details
                    .insert("controllable".into(), controllable.to_string());
                cam.details.insert("source".into(), source.to_string());
                match st.entries.get_mut(&cam.id) {
                    Some(existing) => {
                        // Keep the richer record but always refresh lastSeen and address.
                        existing.host = cam.host;
                        existing.port = cam.port;
                        existing.last_seen = cam.last_seen.max(now);
                        existing.vendor = cam.vendor.or(existing.vendor);
                        existing.name = cam.name;
                        existing.details.extend(cam.details);
                    }
                    None => {
                        cam.last_seen = now;
                        st.entries.insert(cam.id.clone(), cam);
                    }
                }
            }
        }
        self.publish();
    }
}

#[async_trait]
impl CameraDiscovering for CameraDiscoverer {
    fn cameras(&self) -> watch::Receiver<Vec<DiscoveredCamera>> {
        self.inner.tx.subscribe()
    }

    async fn start(&self) -> Result<(), DiscoveryError> {
        {
            let mut st = lock(&self.inner.state);
            if st.running {
                return Ok(());
            }
            st.running = true;
        }
        for source in &self.sources {
            let name = source.source_name();
            if let Err(e) = source.start().await {
                lock(&self.inner.state)
                    .errors
                    .insert(name.to_string(), e.to_string());
            }
            let mut rx = source.cameras();
            let inner = self.inner.clone();
            let t = tokio::spawn(async move {
                loop {
                    let list = rx.borrow_and_update().clone();
                    inner.absorb(list, name);
                    if rx.changed().await.is_err() {
                        return;
                    }
                }
            });
            lock(&self.inner.state).tasks.push(t);
        }
        let inner = self.inner.clone();
        let every = self.sweep_interval;
        let sweeper = tokio::spawn(async move {
            loop {
                tokio::time::sleep(every).await;
                inner.sweep();
            }
        });
        lock(&self.inner.state).tasks.push(sweeper);
        Ok(())
    }

    async fn stop(&self) {
        let tasks = {
            let mut st = lock(&self.inner.state);
            st.running = false;
            std::mem::take(&mut st.tasks)
        };
        tasks.iter().for_each(|t| t.abort());
        for s in &self.sources {
            s.stop().await;
        }
        lock(&self.inner.state).entries.clear();
        self.inner.publish();
    }

    fn source_name(&self) -> &'static str {
        "CameraDiscoverer"
    }
}

impl Drop for CameraDiscoverer {
    fn drop(&mut self) {
        lock(&self.inner.state).tasks.iter().for_each(|t| t.abort());
    }
}
