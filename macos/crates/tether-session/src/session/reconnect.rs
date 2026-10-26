//! Mid-shoot recovery: the core `ReconnectPolicy` (`Capture/ReconnectPolicy.swift`)
//! and the app's `ReconnectContext` / `ReconnectStrategy`
//! (`Tether/Shoot/ReconnectStrategy.swift`). Pure logic, unit-tested.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use tether_library::ShootSession;
use tether_net::RicohProbe;
use tether_ptp::usb::UsbCameraCandidate;
use tether_types::{CameraIdentity, CameraVendor, TransportKind};

/// PTP/IP's standard TCP port.
pub const PTPIP_PORT: u16 = 15740;

/// What the core policy would do to get the link back.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PolicyStrategy {
    /// Wait for the same USB device to reappear, then reopen the session.
    #[serde(rename_all = "camelCase")]
    WaitForUsbDevice {
        candidate_id: Option<String>,
        serial: Option<String>,
    },
    /// Dial the camera's last address again (PTP/IP or HTTP).
    Redial { host: String, port: u16 },
    /// Nothing to reconnect: the camera pushes to us.
    FtpPassive,
    /// We cannot reconnect without the user (no host remembered).
    AskUser { message: String },
}

/// Mid-shoot recovery: what to do when the link drops, with exponential
/// backoff between attempts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReconnectPolicy {
    pub strategy: PolicyStrategy,
    pub attempts: u32,
    pub max_attempts: u32,
}

impl ReconnectPolicy {
    pub const DEFAULT_MAX_ATTEMPTS: u32 = 8;

    pub fn new(
        session: &ShootSession,
        identity: Option<&CameraIdentity>,
        usb_candidate_id: Option<&str>,
        max_attempts: u32,
    ) -> Self {
        let strategy = match session.transport.or(identity.map(|i| i.transport)) {
            Some(TransportKind::Usb) => PolicyStrategy::WaitForUsbDevice {
                candidate_id: usb_candidate_id.map(str::to_string),
                serial: identity.map(|i| i.serial_number.clone()),
            },
            Some(TransportKind::PtpIp) => match &session.last_host {
                Some(h) => PolicyStrategy::Redial {
                    host: h.clone(),
                    port: PTPIP_PORT,
                },
                None => PolicyStrategy::AskUser {
                    message: "The camera's address is unknown. Find it on the network again."
                        .into(),
                },
            },
            Some(TransportKind::RicohHttp) => PolicyStrategy::Redial {
                host: session
                    .last_host
                    .clone()
                    .unwrap_or_else(|| RicohProbe::DEFAULT_HOST.into()),
                port: 80,
            },
            Some(TransportKind::Http) => match &session.last_host {
                Some(h) => PolicyStrategy::Redial {
                    host: h.clone(),
                    port: 80,
                },
                None => PolicyStrategy::AskUser {
                    message: "Join the camera's Wi-Fi again, then pick it from the list.".into(),
                },
            },
            Some(TransportKind::FtpPush) => PolicyStrategy::FtpPassive,
            None => PolicyStrategy::AskUser {
                message: "This session has no camera link.".into(),
            },
        };
        Self {
            strategy,
            attempts: 0,
            max_attempts,
        }
    }

    /// Exponential backoff (0.5 s, 1 s, 2 s…) capped at 15 s; `None` when we
    /// should stop trying.
    pub fn next_delay(&mut self) -> Option<Duration> {
        if self.attempts >= self.max_attempts {
            return None;
        }
        self.attempts += 1;
        let secs = (0.5 * 2f64.powi(self.attempts as i32 - 1)).min(15.0);
        Some(Duration::from_secs_f64(secs))
    }

    pub fn user_message(&self) -> String {
        match &self.strategy {
            PolicyStrategy::WaitForUsbDevice { .. } => {
                "Plug the camera back in. Open Tether reconnects as soon as it sees it.".into()
            }
            PolicyStrategy::Redial { host, .. } => {
                format!("Reconnecting to the camera at {host}…")
            }
            PolicyStrategy::FtpPassive => {
                "The camera sends files when it is ready. Check it is still on the same Wi-Fi."
                    .into()
            }
            PolicyStrategy::AskUser { message } => message.clone(),
        }
    }

    /// True when a USB candidate is the camera we lost.
    pub fn matches(&self, candidate: &UsbCameraCandidate) -> bool {
        let PolicyStrategy::WaitForUsbDevice {
            candidate_id,
            serial,
        } = &self.strategy
        else {
            return false;
        };
        if candidate_id.as_deref() == Some(candidate.id.as_str()) {
            return true;
        }
        if let Some(s) = serial.as_deref().filter(|s| !s.is_empty()) {
            if candidate.serial_number.as_deref() == Some(s) {
                return true;
            }
        }
        candidate_id.is_none() && serial.is_none()
    }
}

/// How the live connection was made, kept so a dropped link can be
/// re-opened the same way.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ReconnectContext {
    #[serde(rename_all = "camelCase")]
    Usb {
        device_id: String,
        serial: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    PtpIp {
        host: String,
        port: u16,
        vendor: Option<CameraVendor>,
    },
    Ricoh {
        host: String,
    },
    /// GoPro or an OSC 360° camera over HTTP on its own Wi-Fi.
    Http {
        host: String,
        vendor: CameraVendor,
    },
    Ftp,
    Unknown,
}

impl ReconnectContext {
    /// Rebuilt from a stored session after a relaunch.
    pub fn from_session(session: &ShootSession) -> Self {
        match session.transport {
            Some(TransportKind::Usb) => Self::Usb {
                device_id: session
                    .camera
                    .as_ref()
                    .map(|c| c.id.clone())
                    .unwrap_or_default(),
                serial: session.camera.as_ref().map(|c| c.serial_number.clone()),
            },
            Some(TransportKind::PtpIp) => Self::PtpIp {
                host: session.last_host.clone().unwrap_or_default(),
                port: PTPIP_PORT,
                vendor: session.camera.as_ref().map(|c| c.vendor),
            },
            Some(TransportKind::RicohHttp) => Self::Ricoh {
                host: session
                    .last_host
                    .clone()
                    .unwrap_or_else(|| RicohProbe::DEFAULT_HOST.into()),
            },
            Some(TransportKind::FtpPush) => Self::Ftp,
            Some(TransportKind::Http) => {
                match (
                    &session.last_host,
                    session.camera.as_ref().map(|c| c.vendor),
                ) {
                    (Some(host), Some(vendor)) => Self::Http {
                        host: host.clone(),
                        vendor,
                    },
                    _ => Self::Unknown,
                }
            }
            None => Self::Unknown,
        }
    }
}

/// What the reconnect sheet should do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ReconnectStrategy {
    /// Watch the USB browser until a camera with this serial (or any camera) returns.
    WaitForUsbDevice {
        serial: Option<String>,
    },
    RetryHost {
        host: String,
        port: u16,
        vendor: Option<CameraVendor>,
    },
    RetryRicoh {
        host: String,
    },
    RetryHttp {
        host: String,
        vendor: CameraVendor,
    },
    /// FTP push: the server keeps listening; nothing to re-open.
    NothingToDo,
    /// No usable information: send the user back to Connect.
    StartFresh,
}

impl ReconnectStrategy {
    pub fn choose(context: &ReconnectContext) -> Self {
        match context {
            ReconnectContext::Usb { serial, .. } => Self::WaitForUsbDevice {
                serial: serial.clone(),
            },
            ReconnectContext::PtpIp { host, port, vendor } => {
                if host.is_empty() {
                    Self::StartFresh
                } else {
                    Self::RetryHost {
                        host: host.clone(),
                        port: *port,
                        vendor: *vendor,
                    }
                }
            }
            ReconnectContext::Ricoh { host } => {
                if host.is_empty() {
                    Self::StartFresh
                } else {
                    Self::RetryRicoh { host: host.clone() }
                }
            }
            ReconnectContext::Http { host, vendor } => Self::RetryHttp {
                host: host.clone(),
                vendor: *vendor,
            },
            ReconnectContext::Ftp => Self::NothingToDo,
            ReconnectContext::Unknown => Self::StartFresh,
        }
    }

    pub fn title(&self) -> String {
        match self {
            Self::WaitForUsbDevice { .. } => "Waiting for the cable".into(),
            Self::RetryHost { host, .. } => format!("Reconnecting to {host}"),
            Self::RetryRicoh { host } => format!("Reconnecting to the Ricoh at {host}"),
            Self::RetryHttp { vendor, .. } => format!(
                "Reconnecting to the {}",
                if *vendor == CameraVendor::Gopro {
                    "GoPro"
                } else {
                    "camera"
                }
            ),
            Self::NothingToDo => "FTP receiver is still listening".into(),
            Self::StartFresh => "Connect again".into(),
        }
    }

    pub fn detail(&self) -> String {
        match self {
            Self::WaitForUsbDevice { .. } => "Plug the camera back in. Open Tether reconnects as soon as it reappears and keeps every frame from this session.".into(),
            Self::RetryHost { .. } => "Make sure the Mac is still on the camera's Wi-Fi and the camera is in its PC / remote connection mode.".into(),
            Self::RetryRicoh { .. } => "Stay on the camera's Wi-Fi network. The GR sleeps quickly; half-press the shutter to wake it.".into(),
            Self::RetryHttp { vendor, .. } => if *vendor == CameraVendor::Gopro {
                "Keep the Mac on the GoPro's Wi-Fi and the camera awake (press Mode to wake it).".into()
            } else {
                "Keep the Mac on the camera's Wi-Fi network and the camera switched on.".into()
            },
            Self::NothingToDo => "Cameras push files whenever they want; the session keeps collecting them.".into(),
            Self::StartFresh => "Open Tether does not know how this session was connected. Pick a connection method to continue it.".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tether_types::CameraCapabilities;

    fn candidate(id: &str, serial: Option<&str>) -> UsbCameraCandidate {
        UsbCameraCandidate::new(id, "", 0, 0, serial.map(str::to_string), false)
    }

    #[test]
    fn strategies_and_backoff() {
        let mut usb = ShootSession::new("a");
        usb.transport = Some(TransportKind::Usb);
        let id = CameraIdentity {
            id: "c".into(),
            vendor: CameraVendor::Canon,
            manufacturer: "Canon".into(),
            model: "R5".into(),
            serial_number: "S1".into(),
            firmware: "1".into(),
            transport: TransportKind::Usb,
            capabilities: CameraCapabilities::empty(),
        };
        let mut p = ReconnectPolicy::new(&usb, Some(&id), Some("dev-1"), 3);
        assert_eq!(
            p.strategy,
            PolicyStrategy::WaitForUsbDevice {
                candidate_id: Some("dev-1".into()),
                serial: Some("S1".into())
            }
        );
        assert!(p.matches(&candidate("dev-1", None)));
        assert!(p.matches(&candidate("other", Some("S1"))));
        assert!(!p.matches(&candidate("other", Some("S2"))));
        assert_eq!(p.next_delay(), Some(Duration::from_millis(500)));
        assert_eq!(p.next_delay(), Some(Duration::from_secs(1)));
        assert_eq!(p.next_delay(), Some(Duration::from_secs(2)));
        assert_eq!(p.next_delay(), None);

        let mut wifi = ShootSession::new("b");
        wifi.transport = Some(TransportKind::PtpIp);
        wifi.last_host = Some("192.168.1.4".into());
        assert_eq!(
            ReconnectPolicy::new(&wifi, None, None, 8).strategy,
            PolicyStrategy::Redial {
                host: "192.168.1.4".into(),
                port: 15740
            }
        );
        wifi.last_host = None;
        assert!(matches!(
            ReconnectPolicy::new(&wifi, None, None, 8).strategy,
            PolicyStrategy::AskUser { .. }
        ));
        let mut ftp = ShootSession::new("c");
        ftp.transport = Some(TransportKind::FtpPush);
        assert_eq!(
            ReconnectPolicy::new(&ftp, None, None, 8).strategy,
            PolicyStrategy::FtpPassive
        );
        let mut ricoh = ShootSession::new("d");
        ricoh.transport = Some(TransportKind::RicohHttp);
        assert_eq!(
            ReconnectPolicy::new(&ricoh, None, None, 8).strategy,
            PolicyStrategy::Redial {
                host: "192.168.0.1".into(),
                port: 80
            }
        );
    }

    #[test]
    fn backoff_caps_at_fifteen_seconds() {
        let mut s = ShootSession::new("x");
        s.transport = Some(TransportKind::FtpPush);
        let mut p = ReconnectPolicy::new(&s, None, None, 10);
        let delays: Vec<Duration> = std::iter::from_fn(|| p.next_delay()).collect();
        assert_eq!(delays.len(), 10);
        assert_eq!(*delays.last().unwrap(), Duration::from_secs(15));
    }

    #[test]
    fn app_strategy_from_context() {
        let mut s = ShootSession::new("x");
        s.transport = Some(TransportKind::PtpIp);
        s.last_host = Some("10.0.0.2".into());
        let ctx = ReconnectContext::from_session(&s);
        assert_eq!(
            ReconnectStrategy::choose(&ctx),
            ReconnectStrategy::RetryHost {
                host: "10.0.0.2".into(),
                port: 15740,
                vendor: None
            }
        );
        s.last_host = None;
        assert_eq!(
            ReconnectStrategy::choose(&ReconnectContext::from_session(&s)),
            ReconnectStrategy::StartFresh
        );
        s.transport = Some(TransportKind::FtpPush);
        assert_eq!(
            ReconnectStrategy::choose(&ReconnectContext::from_session(&s)),
            ReconnectStrategy::NothingToDo
        );
        s.transport = Some(TransportKind::RicohHttp);
        assert_eq!(
            ReconnectStrategy::choose(&ReconnectContext::from_session(&s)),
            ReconnectStrategy::RetryRicoh {
                host: "192.168.0.1".into()
            }
        );
        s.transport = Some(TransportKind::Http);
        assert_eq!(
            ReconnectStrategy::choose(&ReconnectContext::from_session(&s)),
            ReconnectStrategy::StartFresh
        );
        assert_eq!(
            ReconnectStrategy::NothingToDo.title(),
            "FTP receiver is still listening"
        );
    }
}
