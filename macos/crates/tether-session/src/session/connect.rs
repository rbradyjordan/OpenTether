//! The one place a transport becomes a running [`TetherSession`]
//! (`Tether/Shoot/ConnectionBuilder.swift` + `LiveConnection.swift`).

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tether_library::previews::PreviewGenerating;
use tether_library::{SessionStatus, SessionStore, ShootSession};
use tether_ptp::ptp::PtpLog;
use tether_ptp::ptpip::{HandshakeStage, PtpIpIdentity};
use tether_ptp::vendors::{
    GoProHandler, HttpCameraHandler, OscHandler, ReqwestRicohHttp, RicohHandler,
};
use tether_ptp::{
    camera_identity, PtpEngine, PtpIpConfig, PtpIpTransport, PtpTransport, VendorHandler,
    VendorRegistry,
};
use tether_types::{CameraIdentity, CameraVendor, TransportKind};

use super::reconnect::ReconnectContext;
use super::tether_session::TetherSession;
use crate::cache::CaptureCacheProxy;
use crate::error::{ConnectError, Result};

/// Connecting-screen steps (`ConnectStep` in the app).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConnectStep {
    Link,
    InitCommand,
    InitEvent,
    Session,
    DeviceInfo,
    VendorGate,
    Ready,
}

impl ConnectStep {
    /// The steps the connecting screen lists for a transport.
    pub fn steps(transport: TransportKind) -> Vec<ConnectStep> {
        use ConnectStep::*;
        match transport {
            TransportKind::PtpIp => vec![
                Link,
                InitCommand,
                InitEvent,
                Session,
                DeviceInfo,
                VendorGate,
                Ready,
            ],
            TransportKind::Usb => vec![Link, Session, DeviceInfo, VendorGate, Ready],
            TransportKind::RicohHttp | TransportKind::Http => {
                vec![Link, DeviceInfo, VendorGate, Ready]
            }
            TransportKind::FtpPush => vec![Link, Ready],
        }
    }
}

pub type ConnectProgress = Arc<dyn Fn(ConnectStep) + Send + Sync>;

/// What the builder needs from the app.
#[derive(Clone)]
pub struct ConnectServices {
    pub store: Arc<SessionStore>,
    pub cache: Arc<CaptureCacheProxy>,
    pub previews: Arc<dyn PreviewGenerating>,
    pub ptp_log: Option<Arc<PtpLog>>,
}

impl ConnectServices {
    /// PTP/IP wants a stable client GUID so cameras that pair by GUID
    /// recognise us.
    pub fn stable_guid(&self) -> uuid::Uuid {
        if let Some(u) = self
            .store
            .setting("ptpip.guid")
            .and_then(|s| uuid::Uuid::parse_str(&s).ok())
        {
            return u;
        }
        let u = uuid::Uuid::new_v4();
        self.store
            .set_setting("ptpip.guid", Some(&u.to_string().to_uppercase()));
        u
    }
}

/// Everything the shoot needs after a successful connect.
#[derive(Clone)]
pub struct LiveConnection {
    pub session: TetherSession,
    pub shoot: ShootSession,
    pub identity: Option<CameraIdentity>,
    pub context: ReconnectContext,
    /// True when resumed from the store without a camera link.
    pub needs_reconnect: bool,
}

fn report(progress: &Option<ConnectProgress>, step: ConnectStep) {
    if let Some(p) = progress {
        p(step);
    }
}

fn make_session(
    shoot: &ShootSession,
    identity: Option<CameraIdentity>,
    transport: TransportKind,
    host: Option<&str>,
    handler: Option<Arc<dyn VendorHandler>>,
    engine: Option<Arc<PtpEngine>>,
    services: &ConnectServices,
) -> Result<TetherSession> {
    let mut s = shoot.clone();
    if identity.is_some() {
        s.camera = identity.clone();
    }
    s.transport = Some(transport);
    if let Some(h) = host {
        s.last_host = Some(h.to_string());
    }
    s.status = SessionStatus::Active;
    services.store.save_session(&s)?;
    if let Some(id) = &identity {
        let _ = services.store.remember_camera(id, host);
    }
    Ok(TetherSession::new(
        s,
        identity,
        handler,
        engine,
        services.store.clone(),
        services.cache.clone(),
        Some(services.previews.clone()),
    ))
}

/// Any PTP transport (USB, PTP/IP, or a scripted one in tests): open,
/// read DeviceInfo, pick the vendor handler, start the session.
#[allow(clippy::too_many_arguments)]
pub async fn connect_ptp(
    transport: Arc<dyn PtpTransport>,
    kind: TransportKind,
    fallback_id: &str,
    host: Option<&str>,
    context: ReconnectContext,
    shoot: &ShootSession,
    services: &ConnectServices,
    progress: Option<ConnectProgress>,
) -> Result<LiveConnection> {
    let engine = Arc::new(PtpEngine::with_log(
        transport.clone(),
        services.ptp_log.clone(),
    ));
    report(&progress, ConnectStep::Link);
    transport.open().await?;
    report(&progress, ConnectStep::Session);
    let info = engine.connect(1).await?;
    report(&progress, ConnectStep::DeviceInfo);
    let handler = VendorRegistry::make_handler(engine.clone(), info.clone(), kind);
    let identity = camera_identity(&info, kind, handler.capabilities(), fallback_id);
    let session = make_session(
        shoot,
        Some(identity.clone()),
        kind,
        host,
        Some(handler),
        Some(engine),
        services,
    )?;
    report(&progress, ConnectStep::VendorGate);
    session.start().await?;
    report(&progress, ConnectStep::Ready);
    let context = match context {
        ReconnectContext::Usb { device_id, serial } => ReconnectContext::Usb {
            device_id,
            serial: serial
                .filter(|s| !s.is_empty())
                .or(Some(info.serial_number.clone())),
        },
        ReconnectContext::PtpIp { host, port, .. } => ReconnectContext::PtpIp {
            host,
            port,
            vendor: Some(identity.vendor),
        },
        other => other,
    };
    Ok(LiveConnection {
        shoot: session.session(),
        session,
        identity: Some(identity),
        context,
        needs_reconnect: false,
    })
}

/// PTP/IP over Wi-Fi or Ethernet.
pub async fn connect_ptpip(
    host: &str,
    port: u16,
    vendor_hint: Option<CameraVendor>,
    shoot: &ShootSession,
    services: &ConnectServices,
    progress: Option<ConnectProgress>,
) -> Result<LiveConnection> {
    let trimmed = host.trim();
    if trimmed.is_empty() {
        return Err(ConnectError::BadHost(host.to_string()).into());
    }
    let guid = PtpIpIdentity::guid(&services.stable_guid());
    let mut config = PtpIpConfig::new(trimmed, guid);
    config.port = port;
    config.vendor_hint = vendor_hint;
    if let Some(p) = progress.clone() {
        config.on_progress = Some(Arc::new(move |stage| match stage {
            HandshakeStage::TcpConnected => p(ConnectStep::InitCommand),
            HandshakeStage::InitCommandAcked | HandshakeStage::EventConnected => {
                p(ConnectStep::InitEvent)
            }
            HandshakeStage::EventAcked => p(ConnectStep::Session),
        }));
    }
    let transport: Arc<dyn PtpTransport> = Arc::new(PtpIpTransport::new(config));
    connect_ptp(
        transport,
        TransportKind::PtpIp,
        &format!("ptpip-{trimmed}"),
        Some(trimmed),
        ReconnectContext::PtpIp {
            host: trimmed.to_string(),
            port,
            vendor: vendor_hint,
        },
        shoot,
        services,
        progress,
    )
    .await
}

/// Cameras controlled over HTTP on their own Wi-Fi: Ricoh GR, GoPro, and
/// 360° cameras speaking the Open Spherical Camera API.
pub async fn connect_http(
    vendor: CameraVendor,
    host: &str,
    shoot: &ShootSession,
    services: &ConnectServices,
    progress: Option<ConnectProgress>,
) -> Result<LiveConnection> {
    let trimmed = host.trim();
    if trimmed.is_empty() || trimmed.contains(char::is_whitespace) {
        return Err(ConnectError::BadHost(host.to_string()).into());
    }
    let base = format!("http://{trimmed}");
    report(&progress, ConnectStep::Link);
    let http = Arc::new(ReqwestRicohHttp::new());
    let (handler, identity): (Arc<dyn VendorHandler>, CameraIdentity) = match vendor {
        CameraVendor::Gopro => {
            let h = Arc::new(GoProHandler::with_http(&base, http));
            let id = h.probe_identity().await?;
            (h, id)
        }
        CameraVendor::Osc => {
            let h = Arc::new(OscHandler::with_http(&base, http));
            let id = h.probe_identity().await?;
            (h, id)
        }
        _ => {
            let h = Arc::new(RicohHandler::with_http(&base, http));
            let id = h.probe_identity().await?;
            (h, id)
        }
    };
    report(&progress, ConnectStep::DeviceInfo);
    let transport = if vendor == CameraVendor::Ricoh {
        TransportKind::RicohHttp
    } else {
        TransportKind::Http
    };
    let session = make_session(
        shoot,
        Some(identity.clone()),
        transport,
        Some(trimmed),
        Some(handler),
        None,
        services,
    )?;
    report(&progress, ConnectStep::VendorGate);
    session.start().await?;
    report(&progress, ConnectStep::Ready);
    let context = if vendor == CameraVendor::Ricoh {
        ReconnectContext::Ricoh {
            host: trimmed.to_string(),
        }
    } else {
        ReconnectContext::Http {
            host: trimmed.to_string(),
            vendor,
        }
    };
    Ok(LiveConnection {
        shoot: session.session(),
        session,
        identity: Some(identity),
        context,
        needs_reconnect: false,
    })
}

/// FTP push: no camera link; the session only ingests files the receiver
/// hands it.
pub async fn start_ftp_session(
    shoot: &ShootSession,
    services: &ConnectServices,
) -> Result<LiveConnection> {
    let session = make_session(
        shoot,
        None,
        TransportKind::FtpPush,
        None,
        None,
        None,
        services,
    )?;
    session.start().await?;
    Ok(LiveConnection {
        shoot: session.session(),
        session,
        identity: None,
        context: ReconnectContext::Ftp,
        needs_reconnect: false,
    })
}

/// USB through ImageCaptureCore (macOS).
#[cfg(target_os = "macos")]
pub async fn connect_usb(
    browser: &tether_ptp::usb::UsbCameraBrowser,
    device_id: &str,
    serial: Option<String>,
    shoot: &ShootSession,
    services: &ConnectServices,
    progress: Option<ConnectProgress>,
) -> Result<LiveConnection> {
    let Some(transport) = browser.transport(device_id) else {
        return Err(ConnectError::DeviceGone.into());
    };
    let transport = Arc::new(transport);
    let connection = connect_ptp(
        transport.clone(),
        TransportKind::Usb,
        device_id,
        None,
        ReconnectContext::Usb {
            device_id: device_id.to_string(),
            serial,
        },
        shoot,
        services,
        progress,
    )
    .await?;
    let weak = connection.session.downgrade();
    transport.set_on_disconnect(Some(Arc::new(move |reason: String| {
        if let Some(s) = weak.upgrade() {
            s.mark_disconnected(reason);
        }
    })));
    Ok(connection)
}
