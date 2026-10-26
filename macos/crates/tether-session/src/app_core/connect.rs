//! Connecting: USB cameras, network discovery and manual IP, the FTP
//! receiver, and the diagnostics checklists (`USBConnectViewModel`,
//! `WiFiConnectViewModel`, `FTPReceiverModel`, `DiagnosticsView`).

use std::sync::Arc;

use chrono::Utc;
use tether_net::{
    CameraDiscoverer, CameraDiscovering, DiscoveredCamera, FtpServer, FtpServerConfig,
    FtpServerEvent,
};
use tether_types::CameraVendor;
use tokio::sync::broadcast;

use super::AppCore;
use crate::diagnostics::{
    self, probe, DiagnosticEvent, DiagnosticReport, DiagnosticRunner, WirelessProbes,
};
use crate::error::{lock, Error, Result};
use crate::events::{
    AppEvent, FtpFileDto, FtpReceiverStatus, ShootStateDto, ToastKind, UsbAuthorizationDto,
    UsbDeviceDto,
};
use crate::session::connect::{self, ConnectProgress, ConnectStep};
use crate::session::ReconnectContext;

impl AppCore {
    fn connect_progress(&self) -> ConnectProgress {
        let events = self.inner.events.clone();
        Arc::new(move |step: ConnectStep| {
            let _ = events.send(AppEvent::ConnectProgress {
                step: Some(step),
                error: None,
            });
        })
    }

    fn connect_failed(&self, e: &Error) {
        self.emit(AppEvent::ConnectProgress {
            step: None,
            error: Some(e.to_string()),
        });
    }

    fn shoot_for(&self, session_id: Option<String>) -> Result<tether_library::ShootSession> {
        match session_id {
            Some(id) => self.load_session(&id),
            None => self.new_session(String::new(), None),
        }
    }

    // MARK: USB

    /// Ask for camera access where undecided and start browsing; device
    /// lists then arrive as `UsbDevices` events.
    #[cfg(target_os = "macos")]
    pub async fn usb_start(&self) -> Result<()> {
        let mut rx = self.inner.usb.events();
        let weak = Arc::downgrade(&self.inner);
        self.keep(tokio::spawn(async move {
            use tether_ptp::usb::UsbBrowserEvent;
            while let Some(ev) = rx.recv().await {
                let Some(inner) = weak.upgrade() else { return };
                let core = AppCore { inner };
                match ev {
                    UsbBrowserEvent::Devices(list) => core.emit(AppEvent::UsbDevices {
                        devices: list.iter().map(UsbDeviceDto::from).collect(),
                    }),
                    UsbBrowserEvent::Authorization(a) => core.emit(AppEvent::UsbAuthorization {
                        authorization: a.into(),
                    }),
                    UsbBrowserEvent::Error(m) => core.toast(m, ToastKind::Error),
                }
            }
        }));
        self.inner.usb.start().await;
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    pub async fn usb_start(&self) -> Result<()> {
        Err(Error::msg("USB is only available on macOS."))
    }

    #[cfg(target_os = "macos")]
    pub fn usb_devices(&self) -> Vec<UsbDeviceDto> {
        self.inner
            .usb
            .candidates()
            .iter()
            .map(UsbDeviceDto::from)
            .collect()
    }

    #[cfg(not(target_os = "macos"))]
    pub fn usb_devices(&self) -> Vec<UsbDeviceDto> {
        Vec::new()
    }

    /// What the system has on record, without prompting.
    #[cfg(target_os = "macos")]
    pub async fn usb_authorization(&self) -> UsbAuthorizationDto {
        self.inner.usb.current_authorization().await.into()
    }

    #[cfg(not(target_os = "macos"))]
    pub async fn usb_authorization(&self) -> UsbAuthorizationDto {
        tether_ptp::usb::UsbAuthorizationState::default().into()
    }

    #[cfg(target_os = "macos")]
    pub async fn usb_request_authorization(&self) -> UsbAuthorizationDto {
        let a = self.inner.usb.request_authorizations().await;
        if a.can_send_ptp() {
            self.inner.usb.start().await;
        }
        a.into()
    }

    #[cfg(not(target_os = "macos"))]
    pub async fn usb_request_authorization(&self) -> UsbAuthorizationDto {
        self.usb_authorization().await
    }

    /// Open a USB camera into a session (`None`: a new one) and make it the
    /// live shoot.
    #[cfg(target_os = "macos")]
    pub async fn connect_usb(
        &self,
        device_id: &str,
        session_id: Option<String>,
    ) -> Result<ShootStateDto> {
        let shoot = self.shoot_for(session_id)?;
        let serial = self
            .inner
            .usb
            .candidates()
            .into_iter()
            .find(|c| c.id == device_id)
            .and_then(|c| c.serial_number);
        match connect::connect_usb(
            &self.inner.usb,
            device_id,
            serial,
            &shoot,
            &self.connect_services(),
            Some(self.connect_progress()),
        )
        .await
        {
            Ok(c) => Ok(self.activate(c).await),
            Err(e) => {
                self.connect_failed(&e);
                Err(e)
            }
        }
    }

    #[cfg(not(target_os = "macos"))]
    pub async fn connect_usb(
        &self,
        _device_id: &str,
        _session_id: Option<String>,
    ) -> Result<ShootStateDto> {
        Err(Error::msg("USB is only available on macOS."))
    }

    /// Any PTP transport (a custom one, or a scripted camera in tests):
    /// open it, pick the vendor handler and make it the live shoot.
    pub async fn connect_transport(
        &self,
        transport: Arc<dyn tether_ptp::PtpTransport>,
        session_id: Option<String>,
    ) -> Result<ShootStateDto> {
        let shoot = self.shoot_for(session_id)?;
        let kind = transport.kind();
        let context = match kind {
            tether_types::TransportKind::Usb => ReconnectContext::Usb {
                device_id: String::new(),
                serial: None,
            },
            _ => ReconnectContext::Unknown,
        };
        match connect::connect_ptp(
            transport,
            kind,
            "custom",
            None,
            context,
            &shoot,
            &self.connect_services(),
            Some(self.connect_progress()),
        )
        .await
        {
            Ok(c) => Ok(self.activate(c).await),
            Err(e) => {
                self.connect_failed(&e);
                Err(e)
            }
        }
    }

    // MARK: Network

    /// Start looking for cameras on the network; the merged list arrives
    /// as `DiscoveryUpdated` events.
    pub async fn start_discovery(&self) -> Result<()> {
        let discovery = self.inner.discovery.clone();
        discovery
            .start()
            .await
            .map_err(|e| Error::msg(e.to_string()))?;
        let mut rx = discovery.cameras();
        let weak = Arc::downgrade(&self.inner);
        self.keep(tokio::spawn(async move {
            loop {
                let list = rx.borrow_and_update().clone();
                let Some(inner) = weak.upgrade() else { return };
                AppCore { inner }.emit(AppEvent::DiscoveryUpdated { cameras: list });
                if rx.changed().await.is_err() {
                    return;
                }
            }
        }));
        Ok(())
    }

    pub async fn stop_discovery(&self) {
        self.inner.discovery.stop().await;
    }

    pub fn discovered_cameras(&self) -> Vec<DiscoveredCamera> {
        self.inner.discovery.current()
    }

    /// Source name → last start error (e.g. "local network access denied").
    pub fn discovery_errors(&self) -> std::collections::BTreeMap<String, String> {
        self.inner.discovery.last_errors()
    }

    /// Adds a user-entered camera (never expires); returns its id.
    pub fn add_manual_camera(
        &self,
        host: &str,
        port: Option<u16>,
        vendor: Option<CameraVendor>,
    ) -> String {
        let port = port.unwrap_or(match vendor {
            Some(v) if v.uses_http_control() => 80,
            _ => tether_net::PTPIP_STANDARD_PORT,
        });
        let id = self
            .inner
            .discovery
            .add_manual(host.trim(), port, vendor, None);
        self.emit(AppEvent::DiscoveryUpdated {
            cameras: self.inner.discovery.current(),
        });
        id
    }

    pub fn remove_manual_camera(&self, id: &str) {
        self.inner.discovery.remove_manual(id);
    }

    /// Connect to a camera from the discovery list.
    pub async fn connect_discovered(
        &self,
        camera_id: &str,
        session_id: Option<String>,
    ) -> Result<ShootStateDto> {
        let camera = self
            .inner
            .discovery
            .current()
            .into_iter()
            .find(|c| c.id == camera_id)
            .ok_or_else(|| Error::NotFound(format!("Camera {camera_id}")))?;
        self.connect_network(&camera.host, camera.port, camera.vendor, session_id)
            .await
    }

    /// Connect by address: HTTP brands (Ricoh, GoPro, OSC) over HTTP,
    /// everything else over PTP/IP.
    pub async fn connect_network(
        &self,
        host: &str,
        port: u16,
        vendor: Option<CameraVendor>,
        session_id: Option<String>,
    ) -> Result<ShootStateDto> {
        let shoot = self.shoot_for(session_id)?;
        let services = self.connect_services();
        let progress = Some(self.connect_progress());
        self.emit(AppEvent::ConnectProgress {
            step: Some(ConnectStep::Link),
            error: None,
        });
        let result = match vendor.filter(|v| v.uses_http_control()) {
            Some(v) => {
                let host = if port == 80 || host.contains(':') {
                    host.to_string()
                } else {
                    format!("{host}:{port}")
                };
                connect::connect_http(v, &host, &shoot, &services, progress).await
            }
            None => connect::connect_ptpip(host, port, vendor, &shoot, &services, progress).await,
        };
        match result {
            Ok(c) => Ok(self.activate(c).await),
            Err(e) => {
                self.connect_failed(&e);
                Err(e)
            }
        }
    }

    // MARK: FTP receiver

    pub fn ftp_status(&self) -> FtpReceiverStatus {
        let s = self.settings();
        let mut st = lock(&self.inner.ftp).status.clone();
        st.username = s.ftp_username;
        st.password = s.ftp_password;
        if st.primary_address.is_none() {
            st.primary_address = st
                .addresses
                .first()
                .cloned()
                .or_else(|| CameraDiscoverer::local_ipv4_addresses().into_iter().next());
        }
        st
    }

    /// Files received since launch, newest first (at most 200).
    pub fn ftp_received(&self) -> Vec<FtpFileDto> {
        lock(&self.inner.ftp).received.iter().cloned().collect()
    }

    fn publish_ftp(&self) {
        self.emit(AppEvent::FtpServer {
            status: self.ftp_status(),
        });
    }

    /// Start the on-Mac FTP server cameras push to. Files that arrive go to
    /// the live FTP-push shoot.
    pub async fn ftp_start(&self) -> Result<FtpReceiverStatus> {
        if lock(&self.inner.ftp).server.is_some() {
            return Ok(self.ftp_status());
        }
        let settings = self.settings();
        let mut config = FtpServerConfig::new(self.inner.ftp_inbox.clone());
        config.port = settings.ftp_port;
        config.username = settings.ftp_username.clone();
        config.password = settings.ftp_password.clone();
        config.allow_anonymous = false;
        let server = Arc::new(FtpServer::new(config));
        let mut events = server.events();
        let files = server.take_received_files();
        let port = match server.start().await {
            Ok(p) => p,
            Err(e) => {
                let msg = format!(
                    "Could not start the FTP server on port {}: {e}",
                    settings.ftp_port
                );
                lock(&self.inner.ftp).status.last_error = Some(msg.clone());
                self.publish_ftp();
                return Err(Error::msg(msg));
            }
        };
        let weak = Arc::downgrade(&self.inner);
        let events_task = tokio::spawn(async move {
            loop {
                let ev = match events.recv().await {
                    Ok(e) => e,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                };
                let Some(inner) = weak.upgrade() else { return };
                AppCore { inner }.on_ftp_event(ev);
            }
        });
        let weak = Arc::downgrade(&self.inner);
        let files_task = tokio::spawn(async move {
            let Some(mut files) = files else { return };
            while let Some(f) = files.recv().await {
                let Some(inner) = weak.upgrade() else { return };
                let core = AppCore { inner };
                let dto = FtpFileDto {
                    name: f
                        .path
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default(),
                    bytes: f.size,
                    from: f.client.clone(),
                    at: Utc::now(),
                    duration_ms: f.duration.as_millis() as u64,
                };
                {
                    let mut ftp = lock(&core.inner.ftp);
                    ftp.received.push_front(dto.clone());
                    ftp.received.truncate(200);
                }
                core.emit(AppEvent::FtpFileReceived { file: dto });
                core.ingest_ftp_file(&f.path, &f.client).await;
            }
        });
        {
            let mut ftp = lock(&self.inner.ftp);
            ftp.server = Some(server);
            ftp.tasks = vec![events_task, files_task];
            ftp.status.is_running = true;
            ftp.status.port = Some(port);
            ftp.status.addresses = FtpServer::advertised_addresses();
            ftp.status.primary_address = FtpServer::primary_address();
            ftp.status.last_error = None;
            ftp.status.clients = 0;
        }
        self.publish_ftp();
        Ok(self.ftp_status())
    }

    pub async fn ftp_stop(&self) {
        let (server, tasks) = {
            let mut ftp = lock(&self.inner.ftp);
            ftp.status.is_running = false;
            ftp.status.port = None;
            ftp.status.clients = 0;
            (ftp.server.take(), std::mem::take(&mut ftp.tasks))
        };
        if let Some(s) = server {
            s.stop();
        }
        for t in tasks {
            t.abort();
        }
        self.publish_ftp();
    }

    fn on_ftp_event(&self, ev: FtpServerEvent) {
        {
            let mut ftp = lock(&self.inner.ftp);
            let st = &mut ftp.status;
            match &ev {
                FtpServerEvent::Started { port, addresses } => {
                    st.port = Some(*port);
                    st.addresses = addresses.clone();
                }
                FtpServerEvent::ClientConnected(_) => st.clients += 1,
                FtpServerEvent::ClientDisconnected(_) => st.clients = st.clients.saturating_sub(1),
                FtpServerEvent::LoginFailed(who) => {
                    st.last_error = Some(format!(
                        "Login failed from {who}. Check the username and password on the camera."
                    ))
                }
                FtpServerEvent::Rebound { addresses } => st.addresses = addresses.clone(),
                FtpServerEvent::Error(m) => st.last_error = Some(m.clone()),
                FtpServerEvent::Stopped => st.is_running = false,
                _ => return,
            }
        }
        self.publish_ftp();
    }

    /// A file a camera pushed: into the live FTP-push shoot, else it waits
    /// in the inbox.
    async fn ingest_ftp_file(&self, path: &std::path::Path, from: &str) {
        let session = lock(&self.inner.active)
            .as_ref()
            .filter(|a| {
                a.context == ReconnectContext::Ftp
                    || a.session.session().transport == Some(tether_types::TransportKind::FtpPush)
            })
            .map(|a| a.session.clone());
        match session {
            Some(s) => {
                s.ingest_file(path, from, None, true).await;
            }
            None => self.toast(
                format!(
                    "Received {} — start an FTP session to collect it",
                    path.file_name().unwrap_or_default().to_string_lossy()
                ),
                ToastKind::Info,
            ),
        }
    }

    // MARK: Diagnostics

    async fn run_diagnostics(&self, runner: DiagnosticRunner) -> DiagnosticReport {
        let mut rx = runner.subscribe();
        let events = self.inner.events.clone();
        let forward = tokio::spawn(async move {
            while let Ok(ev) = rx.recv().await {
                let (report, finished) = match ev {
                    DiagnosticEvent::Updated(r) => (r, false),
                    DiagnosticEvent::Finished(r) => (r, true),
                };
                let _ = events.send(AppEvent::Diagnostics { report, finished });
                if finished {
                    return;
                }
            }
        });
        let report = runner.run().await;
        let _ = forward.await;
        report
    }

    /// The wireless checklist against `host:port` (macOS does not give
    /// apps the Wi-Fi name, so that check warns).
    pub async fn run_wireless_diagnostics(&self, host: &str, port: u16) -> DiagnosticReport {
        let probes = WirelessProbes {
            ssid: probe(|| async { None }),
            local_addresses: probe(|| async { CameraDiscoverer::local_ipv4_addresses() }),
            reachable: Arc::new(|h: String, p: u16| {
                Box::pin(async move {
                    diagnostics::tcp::reachable(&h, p, diagnostics::tcp::DEFAULT_TIMEOUT).await
                })
            }),
            host: host.to_string(),
            port,
        };
        self.run_diagnostics(DiagnosticRunner::new(
            diagnostics::wireless_checks(probes),
            true,
        ))
        .await
    }

    /// The wired checklist over the USB browser. When the live shoot is a
    /// USB camera its open session answers instead of opening another.
    #[cfg(target_os = "macos")]
    pub async fn run_wired_diagnostics(&self) -> DiagnosticReport {
        use crate::diagnostics::WiredProbes;
        use tether_ptp::PtpEngine;

        let core = self.clone();
        let live = self.active_session().ok().filter(|s| {
            s.identity().map(|i| i.transport) == Some(tether_types::TransportKind::Usb)
                && s.status().is_live()
        });
        let battery = live
            .as_ref()
            .and_then(|s| {
                s.properties()
                    .into_iter()
                    .find(|p| p.property == tether_ptp::TetherProperty::BatteryLevel)
            })
            .and_then(|p| p.raw.int_value());
        let c1 = core.clone();
        let c2 = core.clone();
        let c3 = core.clone();
        let live_open = live.is_some();
        let engine: Arc<tokio::sync::Mutex<Option<Arc<PtpEngine>>>> = Default::default();
        let e1 = engine.clone();
        let e2 = engine.clone();
        let probes = WiredProbes {
            device_on_bus: probe(move || {
                let c = c1.clone();
                async move { c.inner.usb.candidates().into_iter().next() }
            }),
            authorization: probe(move || {
                let c = c2.clone();
                async move { c.inner.usb.current_authorization().await }
            }),
            open_session: probe(move || {
                let c = c3.clone();
                let slot = e1.clone();
                async move {
                    if live_open {
                        return Ok(());
                    }
                    let Some(dev) = c.inner.usb.candidates().into_iter().next() else {
                        return Err("No camera".to_string());
                    };
                    let Some(t) = c.inner.usb.transport(&dev.id) else {
                        return Err(crate::ConnectError::DeviceGone.to_string());
                    };
                    let t: Arc<dyn tether_ptp::PtpTransport> = Arc::new(t);
                    t.open().await.map_err(|e| e.to_string())?;
                    *slot.lock().await = Some(Arc::new(PtpEngine::new(t)));
                    Ok(())
                }
            }),
            device_info: probe(move || {
                let slot = e2.clone();
                let live = live.clone();
                async move {
                    if let Some(s) = &live {
                        let id = s.identity().cloned();
                        return id
                            .map(|i| tether_ptp::ptp::PtpDeviceInfo {
                                manufacturer: i.manufacturer,
                                model: i.model,
                                device_version: i.firmware,
                                serial_number: i.serial_number,
                                ..Default::default()
                            })
                            .ok_or_else(|| "No camera".to_string());
                    }
                    let engine = slot.lock().await.clone();
                    match engine {
                        Some(e) => {
                            let r = e.get_device_info().await.map_err(|e| e.to_string());
                            e.disconnect().await;
                            r
                        }
                        None => Err("No session".into()),
                    }
                }
            }),
            battery: probe(move || async move { battery }),
            power_source: probe(|| async { None }),
        };
        self.run_diagnostics(DiagnosticRunner::new(
            diagnostics::wired_checks(probes),
            true,
        ))
        .await
    }

    #[cfg(not(target_os = "macos"))]
    pub async fn run_wired_diagnostics(&self) -> DiagnosticReport {
        use crate::diagnostics::WiredProbes;
        let probes = WiredProbes {
            device_on_bus: probe(|| async { None }),
            authorization: probe(|| async { Default::default() }),
            open_session: probe(|| async { Err("USB is only available on macOS.".to_string()) }),
            device_info: probe(|| async { Err("USB is only available on macOS.".to_string()) }),
            battery: probe(|| async { None }),
            power_source: probe(|| async { None }),
        };
        self.run_diagnostics(DiagnosticRunner::new(
            diagnostics::wired_checks(probes),
            true,
        ))
        .await
    }
}
