//! The cable / power / Wi-Fi diagnostic (`Diagnostics/CableDiagnostic.swift`):
//! an ordered list of checks, each with a result and a plain-language tip.
//! Checks are injected so the app wires the real USB / network probes and
//! tests script the outcomes.

pub mod tcp;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use tether_net::discovery::wifi_hints;
use tether_ptp::detect_vendor;
use tether_ptp::ptp::PtpDeviceInfo;
use tether_ptp::usb::{usb_id_hex, UsbAuthorizationState, UsbCameraCandidate};
use tokio::sync::broadcast;

pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;
/// A probe: an async closure the checklist calls.
pub type Probe<T> = Arc<dyn Fn() -> BoxFuture<T> + Send + Sync>;

/// Wraps an async closure as a [`Probe`].
pub fn probe<T, F, Fut>(f: F) -> Probe<T>
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: Future<Output = T> + Send + 'static,
{
    Arc::new(move || Box::pin(f()))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", content = "detail", rename_all = "camelCase")]
pub enum Outcome {
    Pending,
    Running,
    Pass(String),
    Warn(String),
    Fail(String),
    Skipped(String),
}

impl Outcome {
    pub fn is_failure(&self) -> bool {
        matches!(self, Self::Fail(_))
    }

    pub fn is_pass(&self) -> bool {
        matches!(self, Self::Pass(_))
    }

    pub fn detail(&self) -> String {
        match self {
            Self::Pending => "Waiting".into(),
            Self::Running => "Checking…".into(),
            Self::Pass(s) | Self::Warn(s) | Self::Fail(s) | Self::Skipped(s) => s.clone(),
        }
    }
}

/// One check: what it is, how to fix it, and how to run it.
#[derive(Clone)]
pub struct DiagnosticCheck {
    pub id: String,
    pub title: String,
    pub tip: String,
    pub run: Probe<Outcome>,
}

impl DiagnosticCheck {
    pub fn new(id: &str, title: &str, tip: &str, run: Probe<Outcome>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            tip: tip.into(),
            run,
        }
    }
}

/// A check's state in a report (serialisable for the UI).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    pub id: String,
    pub title: String,
    pub tip: String,
    pub outcome: Outcome,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticReport {
    pub checks: Vec<CheckResult>,
    pub started_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
}

impl DiagnosticReport {
    pub fn verdict(&self) -> &'static str {
        if self.checks.iter().any(|c| c.outcome.is_failure()) {
            return "Something is blocking the tether";
        }
        if self
            .checks
            .iter()
            .any(|c| matches!(c.outcome, Outcome::Warn(_)))
        {
            return "Working, with warnings";
        }
        if self.finished_at.is_none() {
            return "Checking…";
        }
        "Everything looks good"
    }

    pub fn first_failure(&self) -> Option<&CheckResult> {
        self.checks.iter().find(|c| c.outcome.is_failure())
    }

    /// Text the user can paste into a support message.
    pub fn share_text(&self) -> String {
        let mut s = format!(
            "Tether diagnostic {}\n",
            self.started_at.to_rfc3339_opts(SecondsFormat::Secs, true)
        );
        for c in &self.checks {
            let mark = match c.outcome {
                Outcome::Pass(_) => "✓",
                Outcome::Warn(_) => "!",
                Outcome::Fail(_) => "✗",
                Outcome::Skipped(_) => "–",
                _ => "…",
            };
            s += &format!("{mark} {}: {}\n", c.title, c.outcome.detail());
        }
        s
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiagnosticEvent {
    Updated(DiagnosticReport),
    Finished(DiagnosticReport),
}

/// Runs checks in order, stopping early when a prerequisite fails (there
/// is no point probing PTP when no device is on the bus).
pub struct DiagnosticRunner {
    checks: Vec<DiagnosticCheck>,
    report: DiagnosticReport,
    stop_on_failure: bool,
    events: broadcast::Sender<DiagnosticEvent>,
}

impl DiagnosticRunner {
    pub fn new(checks: Vec<DiagnosticCheck>, stop_on_failure: bool) -> Self {
        let report = DiagnosticReport {
            checks: checks
                .iter()
                .map(|c| CheckResult {
                    id: c.id.clone(),
                    title: c.title.clone(),
                    tip: c.tip.clone(),
                    outcome: Outcome::Pending,
                })
                .collect(),
            started_at: Utc::now(),
            finished_at: None,
        };
        let (events, _) = broadcast::channel(64);
        Self {
            checks,
            report,
            stop_on_failure,
            events,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<DiagnosticEvent> {
        self.events.subscribe()
    }

    pub async fn run(mut self) -> DiagnosticReport {
        let mut halted = false;
        for i in 0..self.checks.len() {
            if halted {
                self.report.checks[i].outcome =
                    Outcome::Skipped("Skipped because an earlier check failed".into());
                let _ = self
                    .events
                    .send(DiagnosticEvent::Updated(self.report.clone()));
                continue;
            }
            self.report.checks[i].outcome = Outcome::Running;
            let _ = self
                .events
                .send(DiagnosticEvent::Updated(self.report.clone()));
            let outcome = (self.checks[i].run)().await;
            let failed = outcome.is_failure();
            self.report.checks[i].outcome = outcome;
            let _ = self
                .events
                .send(DiagnosticEvent::Updated(self.report.clone()));
            if failed && self.stop_on_failure {
                halted = true;
            }
        }
        self.report.finished_at = Some(Utc::now());
        let _ = self
            .events
            .send(DiagnosticEvent::Finished(self.report.clone()));
        self.report
    }
}

/// Probes for the wired checklist; the app passes closures over its USB
/// browser and transport.
#[derive(Clone)]
pub struct WiredProbes {
    pub device_on_bus: Probe<Option<UsbCameraCandidate>>,
    pub authorization: Probe<UsbAuthorizationState>,
    pub open_session: Probe<Result<(), String>>,
    pub device_info: Probe<Result<PtpDeviceInfo, String>>,
    pub battery: Probe<Option<i64>>,
    /// "USB-C PD 15 W" when the OS tells us.
    pub power_source: Probe<Option<String>>,
}

/// The standard wired checklist.
pub fn wired_checks(p: WiredProbes) -> Vec<DiagnosticCheck> {
    let bus = p.device_on_bus.clone();
    let auth = p.authorization.clone();
    let open = p.open_session.clone();
    let info = p.device_info.clone();
    let battery = p.battery.clone();
    let power = p.power_source.clone();
    vec![
        DiagnosticCheck::new(
            "bus",
            "Camera on the cable",
            "If your camera doesn't appear, try disconnecting and reconnecting the USB-C cable. Use a data-capable cable (not charge-only). Some cameras need their USB mode set to PC Remote / PTP before they appear. Try the camera's other port if it has two, and skip hubs.",
            probe(move || {
                let bus = bus.clone();
                async move {
                    match bus().await {
                        Some(d) => Outcome::Pass(format!(
                            "{} ({}, USB {}:{})",
                            d.name,
                            d.vendor_guess.display_name(),
                            usb_id_hex(d.usb_vendor_id),
                            usb_id_hex(d.usb_product_id)
                        )),
                        None => Outcome::Fail("No camera is visible on USB. Try disconnecting and reconnecting the USB-C cable, then check the cable, the camera's USB connection mode, and that the camera is on.".into()),
                    }
                }
            }),
        ),
        DiagnosticCheck::new(
            "auth",
            "Permissions",
            "Open Tether needs both Camera Control and Contents access to send PTP commands (System Settings → Privacy & Security).",
            probe(move || {
                let auth = auth.clone();
                async move {
                    let a = auth().await;
                    if a.can_send_ptp() {
                        Outcome::Pass(a.summary())
                    } else {
                        Outcome::Fail(a.summary())
                    }
                }
            }),
        ),
        DiagnosticCheck::new(
            "session",
            "Open a session",
            "If another app (Photos, Image Capture, the camera maker's app) has the camera open, close it. Sony bodies allow only one PC Remote session at a time.",
            probe(move || {
                let open = open.clone();
                async move {
                    match open().await {
                        Ok(()) => Outcome::Pass("Session open".into()),
                        Err(e) => Outcome::Fail(e),
                    }
                }
            }),
        ),
        DiagnosticCheck::new(
            "ptp",
            "Talk PTP",
            "GetDeviceInfo is the first PTP command. If it fails the camera is in MTP/mass-storage mode or needs its remote/tether mode enabled.",
            probe(move || {
                let info = info.clone();
                async move {
                    match info().await {
                        Ok(info) => {
                            let v = detect_vendor(&info);
                            let note = if v.supports_wired_control() { "" } else { " (import only)" };
                            Outcome::Pass(format!(
                                "{} {}, firmware {}, {} operations{note}",
                                info.manufacturer,
                                info.model,
                                info.device_version,
                                info.operations_supported.len()
                            ))
                        }
                        Err(e) => Outcome::Fail(e),
                    }
                }
            }),
        ),
        DiagnosticCheck::new(
            "power",
            "Power",
            "Long sessions drain both batteries. A USB-C PD hub that powers the Mac and the camera at once avoids mid-shoot shutdowns.",
            probe(move || {
                let battery = battery.clone();
                let power = power.clone();
                async move {
                    let b = battery().await;
                    let src = power().await;
                    match (b, src) {
                        (Some(b), Some(s)) if b < 20 => Outcome::Warn(format!("Camera battery {b}%, {s}")),
                        (Some(b), Some(s)) => Outcome::Pass(format!("Camera battery {b}%, {s}")),
                        (Some(b), None) if b < 20 => Outcome::Warn(format!("Camera battery low ({b}%)")),
                        (Some(b), None) => Outcome::Pass(format!("Camera battery {b}%")),
                        (None, Some(s)) => Outcome::Pass(s),
                        (None, None) => Outcome::Warn("Battery level not reported by this camera".into()),
                    }
                }
            }),
        ),
    ]
}

/// Probes for the wireless checklist.
#[derive(Clone)]
pub struct WirelessProbes {
    pub ssid: Probe<Option<String>>,
    pub local_addresses: Probe<Vec<String>>,
    pub reachable: Arc<dyn Fn(String, u16) -> BoxFuture<bool> + Send + Sync>,
    pub host: String,
    pub port: u16,
}

/// macOS does not share the network name with apps without Location access.
pub const SSID_UNAVAILABLE: &str =
    "macOS does not share the network name with apps; check the Wi-Fi menu shows the camera's network";

/// The wireless checklist.
pub fn wireless_checks(p: WirelessProbes) -> Vec<DiagnosticCheck> {
    let ssid = p.ssid.clone();
    let addrs = p.local_addresses.clone();
    let reachable = p.reachable.clone();
    let (host, port) = (p.host.clone(), p.port);
    vec![
        DiagnosticCheck::new(
            "wifi",
            "On the camera's Wi-Fi",
            "Join the camera's own network from the Wi-Fi menu first. Open Tether never joins it for you.",
            probe(move || {
                let ssid = ssid.clone();
                async move {
                    let Some(s) = ssid().await else {
                        return Outcome::Warn(SSID_UNAVAILABLE.into());
                    };
                    match wifi_hints::looks_like_camera_network(&s) {
                        Some(v) => Outcome::Pass(format!("{s} looks like a {} camera network", v.display_name())),
                        None => Outcome::Warn(format!("Connected to {s}. If that is not the camera, join the camera's network.")),
                    }
                }
            }),
        ),
        DiagnosticCheck::new(
            "ip",
            "Address on that network",
            "The Mac needs an address from the camera (usually 192.168.x.x).",
            probe(move || {
                let addrs = addrs.clone();
                async move {
                    let a: Vec<String> = addrs()
                        .await
                        .into_iter()
                        .filter(|a| !a.starts_with("169.254.") && !a.starts_with("127."))
                        .collect();
                    if a.is_empty() {
                        Outcome::Fail("No usable IPv4 address yet; wait a moment or rejoin the network.".into())
                    } else {
                        Outcome::Pass(a.join(", "))
                    }
                }
            }),
        ),
        DiagnosticCheck::new(
            "tcp",
            "Camera answers",
            "PTP/IP listens on TCP 15740; Ricoh on HTTP port 80. The camera must be in its remote/PC-connection mode.",
            probe(move || {
                let reachable = reachable.clone();
                let host = host.clone();
                async move {
                    if reachable(host.clone(), port).await {
                        Outcome::Pass(format!("{host}:{port} is open"))
                    } else {
                        Outcome::Fail(format!("{host}:{port} did not answer"))
                    }
                }
            }),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use tether_ptp::testing::generic_info;
    use tether_ptp::usb::Grant;

    fn wired(
        bus: Option<UsbCameraCandidate>,
        auth: UsbAuthorizationState,
        battery: Option<i64>,
        power: Option<&'static str>,
    ) -> WiredProbes {
        WiredProbes {
            device_on_bus: probe(move || {
                let b = bus.clone();
                async move { b }
            }),
            authorization: probe(move || async move { auth }),
            open_session: probe(|| async { Ok(()) }),
            device_info: probe(|| async { Ok(generic_info()) }),
            battery: probe(move || async move { battery }),
            power_source: probe(move || async move { power.map(str::to_string) }),
        }
    }

    #[tokio::test]
    async fn wired_checklist_stops_at_first_failure() {
        let p = wired(
            None,
            UsbAuthorizationState::new(Grant::Granted, Grant::Granted),
            Some(80),
            None,
        );
        let report = DiagnosticRunner::new(wired_checks(p), true).run().await;
        assert!(report.checks[0].outcome.is_failure());
        assert_eq!(
            report
                .checks
                .iter()
                .filter(|c| matches!(c.outcome, Outcome::Skipped(_)))
                .count(),
            4
        );
        assert_eq!(report.first_failure().unwrap().id, "bus");
        assert!(report.share_text().contains("✗ Camera on the cable"));
        assert_eq!(report.verdict(), "Something is blocking the tether");
    }

    #[tokio::test]
    async fn wired_checklist_passes() {
        let cam = UsbCameraCandidate::new("1", "EOS R5", 0x04A9, 1, Some("s".into()), false);
        let p = wired(
            Some(cam),
            UsbAuthorizationState::new(Grant::NotRequired, Grant::Granted),
            Some(15),
            Some("USB-C PD"),
        );
        let runner = DiagnosticRunner::new(wired_checks(p), true);
        let mut rx = runner.subscribe();
        let report = runner.run().await;
        assert!(report.first_failure().is_none());
        assert_eq!(report.verdict(), "Working, with warnings");
        assert!(report.checks[0].outcome.detail().contains("Canon"));
        assert!(report.checks[0].outcome.detail().contains("0x04A9"));
        assert!(report.checks[3]
            .outcome
            .detail()
            .contains("Generic Camera Co."));
        let mut finished = false;
        while let Ok(e) = rx.try_recv() {
            finished |= matches!(e, DiagnosticEvent::Finished(_));
        }
        assert!(finished);
    }

    #[tokio::test]
    async fn wireless_checklist() {
        let p = WirelessProbes {
            ssid: probe(|| async { Some("EOS-R5_Canon0A".to_string()) }),
            local_addresses: probe(|| async {
                vec!["169.254.1.1".to_string(), "192.168.1.5".to_string()]
            }),
            reachable: Arc::new(|_, _| Box::pin(async { true })),
            host: "192.168.1.1".into(),
            port: 15740,
        };
        let report = DiagnosticRunner::new(wireless_checks(p), true).run().await;
        assert!(report.first_failure().is_none());
        assert!(report.checks[0].outcome.detail().contains("Canon"));
        assert_eq!(report.checks[1].outcome.detail(), "192.168.1.5");
        assert_eq!(report.verdict(), "Everything looks good");
    }

    #[tokio::test]
    async fn wireless_unreachable_and_no_ssid() {
        let p = WirelessProbes {
            ssid: probe(|| async { None }),
            local_addresses: probe(|| async { vec!["10.0.0.3".to_string()] }),
            reachable: Arc::new(|_, _| Box::pin(async { false })),
            host: "10.0.0.9".into(),
            port: 15740,
        };
        let report = DiagnosticRunner::new(wireless_checks(p), true).run().await;
        assert_eq!(
            report.checks[0].outcome,
            Outcome::Warn(SSID_UNAVAILABLE.into())
        );
        assert_eq!(
            report.checks[2].outcome,
            Outcome::Fail("10.0.0.9:15740 did not answer".into())
        );
    }
}
