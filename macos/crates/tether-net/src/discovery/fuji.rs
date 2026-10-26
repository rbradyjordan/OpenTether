//! Fujifilm "PC AutoSave"/wireless-tether discovery. We broadcast a
//! DISCOVERY datagram; a camera on the same network answers by opening a TCP
//! connection *to us* and sending a text block that names itself.
//! Ported from `FujiDiscoverer.swift`.

use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{CameraVendor, TransportKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::Instant;

use super::{CameraDiscovering, DiscoveredCamera, DiscoveryError, DiscoveryMethod, DiscoveryState};
use crate::net::{bind_tcp_listener, bind_udp, broadcast_addresses};
use crate::{lock, PTPIP_STANDARD_PORT};

/// Wire constants (`FujiConstants`).
pub struct FujiConstants;

impl FujiConstants {
    /// UDP port the camera listens on for DISCOVERY. VERIFY against a real X-series body (PCSS/1.0).
    pub const DISCOVERY_PORT: u16 = 51562;
    /// TCP port the camera dials back to on us. VERIFY (PC AutoSave registration port).
    pub const DIAL_BACK_PORT: u16 = 51560;
    pub const SERVICE: &'static str = "PCSS/1.0";
    pub const CLIENT_NAME: &'static str = "Tether";
    /// How long we wait for the dial-back text after the camera connects.
    pub const DIAL_BACK_READ_TIMEOUT: Duration = Duration::from_secs(5);
    /// Seconds between DISCOVERY broadcasts.
    pub const BROADCAST_INTERVAL: Duration = Duration::from_secs(5);
}

/// The DISCOVERY datagram (`FujiDiscoveryMessage.datagram`).
pub fn datagram(broadcast: &str, name: &str, mx: u32, port: u16) -> Vec<u8> {
    format!(
        "DISCOVERY * HTTP/1.1\r\nHOST: {broadcast}:{port}\r\nMX: {mx}\r\nSERVICE: {}\r\nDSCNAME: {name}\r\n\r\n",
        FujiConstants::SERVICE
    )
    .into_bytes()
}

/// Camera's dial-back block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FujiDialBack {
    pub start_line: String,
    /// Header names lower-cased.
    pub headers: HashMap<String, String>,
}

impl FujiDialBack {
    pub fn get(&self, key: &str) -> Option<&str> {
        self.headers.get(&key.to_lowercase()).map(String::as_str)
    }

    /// DSCNAME, falling back to IMPORT/NAME/MODEL-style headers.
    pub fn camera_name(&self) -> Option<&str> {
        [
            "dscname",
            "name",
            "model",
            "import",
            "friendlyname",
            "camera",
        ]
        .iter()
        .filter_map(|k| self.headers.get(*k))
        .find(|v| !v.is_empty())
        .map(String::as_str)
    }

    pub fn is_notify(&self) -> bool {
        self.start_line.to_uppercase().starts_with("NOTIFY")
    }
}

/// Lenient parse: first non-empty line is the start line, then `Key: value`
/// pairs (keys lower-cased), stopping at a blank line.
pub fn parse_dial_back(text: &str) -> Option<FujiDialBack> {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = normalized
        .split('\n')
        .map(|l| l.trim_matches(|c| c == ' ' || c == '\t'))
        .collect();
    let first = lines.iter().position(|l| !l.is_empty())?;
    let mut start = lines[first].to_string();
    let mut body: Vec<&str> = lines[first + 1..].to_vec();
    // Some firmware omits the start line: then the first line is already a header.
    let up = start.to_uppercase();
    if start.contains(':')
        && !up.starts_with("NOTIFY")
        && !up.starts_with("HTTP")
        && !start.contains(" * ")
    {
        body.insert(0, lines[first]);
        start.clear();
    }
    let mut headers = HashMap::new();
    for line in body {
        if line.is_empty() {
            break;
        }
        let Some((k, v)) = line.split_once(':') else {
            continue;
        };
        let key = k.trim().to_lowercase();
        if !key.is_empty() {
            headers.insert(key, v.trim().to_string());
        }
    }
    if start.is_empty() && headers.is_empty() {
        return None;
    }
    Some(FujiDialBack {
        start_line: start,
        headers,
    })
}

/// Settings for [`FujiDiscoverer`].
#[derive(Debug, Clone)]
pub struct FujiOptions {
    /// Preferred dial-back port; falls back to an ephemeral port when busy.
    pub listen_port: u16,
    pub broadcast_interval: Duration,
    /// `None` = `net::broadcast_addresses()` at send time.
    pub broadcast_addresses: Option<Vec<String>>,
    pub broadcast_enabled: bool,
}

impl Default for FujiOptions {
    fn default() -> Self {
        Self {
            listen_port: FujiConstants::DIAL_BACK_PORT,
            broadcast_interval: FujiConstants::BROADCAST_INTERVAL,
            broadcast_addresses: None,
            broadcast_enabled: true,
        }
    }
}

pub struct FujiDiscoverer {
    inner: Arc<Inner>,
    running: Mutex<Option<Running>>,
}

struct Inner {
    state: DiscoveryState,
    options: FujiOptions,
    udp: Mutex<Option<Arc<UdpSocket>>>,
}

struct Running {
    port: u16,
    tasks: Vec<JoinHandle<()>>,
}

impl Default for FujiDiscoverer {
    fn default() -> Self {
        Self::new(FujiOptions::default())
    }
}

impl FujiDiscoverer {
    pub fn new(options: FujiOptions) -> Self {
        Self {
            inner: Arc::new(Inner {
                state: DiscoveryState::new(),
                options,
                udp: Mutex::new(None),
            }),
            running: Mutex::new(None),
        }
    }

    pub fn current(&self) -> Vec<DiscoveredCamera> {
        self.inner.state.snapshot()
    }

    pub fn last_error(&self) -> Option<String> {
        self.inner.state.last_error()
    }

    /// Port the dial-back listener actually bound (`None` when stopped).
    pub fn listening_port(&self) -> Option<u16> {
        lock(&self.running).as_ref().map(|r| r.port)
    }

    /// Sends one DISCOVERY datagram to every broadcast target.
    pub async fn send_broadcast(&self) {
        self.inner.send_broadcast().await
    }

    /// Records a dial-back text from `peer` as a camera.
    pub fn ingest(&self, text: &str, peer: &str) {
        self.inner.ingest(text, peer)
    }
}

impl Inner {
    async fn send_broadcast(&self) {
        let Some(u) = lock(&self.udp).clone() else {
            return;
        };
        let targets = self
            .options
            .broadcast_addresses
            .clone()
            .unwrap_or_else(broadcast_addresses);
        for b in targets {
            let packet = datagram(
                &b,
                FujiConstants::CLIENT_NAME,
                5,
                FujiConstants::DISCOVERY_PORT,
            );
            let Ok(ip) = b.parse::<Ipv4Addr>() else {
                self.state
                    .fail(format!("Fuji broadcast to {b} failed: bad address"));
                continue;
            };
            if let Err(e) = u
                .send_to(&packet, (ip, FujiConstants::DISCOVERY_PORT))
                .await
            {
                self.state
                    .fail(format!("Fuji broadcast to {b} failed: {e}"));
            }
        }
    }

    fn ingest(&self, text: &str, peer: &str) {
        let Some(dial) = parse_dial_back(text) else {
            return;
        };
        let name = dial.camera_name().unwrap_or("Fujifilm camera").to_string();
        let mut details: std::collections::BTreeMap<String, String> =
            dial.headers.clone().into_iter().collect();
        details.insert("startLine".into(), dial.start_line.clone());
        self.state.upsert(
            DiscoveredCamera::new(
                peer,
                name,
                Some(CameraVendor::Fujifilm),
                peer,
                PTPIP_STANDARD_PORT,
                DiscoveryMethod::FujiUdp,
                TransportKind::PtpIp,
            )
            .with_details(details),
        );
    }

    async fn handle_dial_back(self: Arc<Self>, mut stream: TcpStream, peer: String) {
        let mut buffer: Vec<u8> = Vec::new();
        let deadline = Instant::now() + FujiConstants::DIAL_BACK_READ_TIMEOUT;
        let mut chunk = [0u8; 4096];
        while Instant::now() < deadline && buffer.len() < 64 * 1024 {
            let remaining = deadline
                .saturating_duration_since(Instant::now())
                .max(Duration::from_millis(50));
            match tokio::time::timeout(remaining, stream.read(&mut chunk)).await {
                Ok(Ok(n)) if n > 0 => {
                    buffer.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&buffer);
                    if text.contains("\r\n\r\n") || text.contains("\n\n") {
                        break;
                    }
                }
                _ => break,
            }
        }
        if buffer.is_empty() {
            return;
        }
        self.ingest(&String::from_utf8_lossy(&buffer), &peer);
        // Acknowledge so the camera settles; it then exposes PTP/IP on 15740.
        // VERIFY the exact reply the camera expects.
        let ack = format!(
            "HTTP/1.1 200 OK\r\nSERVICE: {}\r\nDSCNAME: {}\r\n\r\n",
            FujiConstants::SERVICE,
            FujiConstants::CLIENT_NAME
        );
        let _ = stream.write_all(ack.as_bytes()).await;
        let _ = stream.shutdown().await;
    }
}

async fn accept_loop(inner: Arc<Inner>, listener: TcpListener) {
    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                tokio::spawn(
                    inner
                        .clone()
                        .handle_dial_back(stream, addr.ip().to_string()),
                );
            }
            Err(e) => {
                inner.state.fail(format!("Fuji accept failed: {e}"));
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

#[async_trait]
impl CameraDiscovering for FujiDiscoverer {
    fn cameras(&self) -> watch::Receiver<Vec<DiscoveredCamera>> {
        self.inner.state.subscribe()
    }

    async fn start(&self) -> Result<(), DiscoveryError> {
        if lock(&self.running).is_some() {
            return Ok(());
        }
        let preferred = self.inner.options.listen_port;
        let listener = match bind_tcp_listener(Ipv4Addr::UNSPECIFIED, preferred, 16) {
            Ok(l) => l,
            Err(_) => {
                self.inner.state.fail(format!(
                    "Fuji port {preferred} busy; using an ephemeral port (cameras expect {}).",
                    FujiConstants::DIAL_BACK_PORT
                ));
                bind_tcp_listener(Ipv4Addr::UNSPECIFIED, 0, 16).map_err(|source| {
                    DiscoveryError::Bind {
                        what: "Fuji dial-back listener".into(),
                        source,
                    }
                })?
            }
        };
        let port = listener.local_addr()?.port();
        let mut tasks = vec![tokio::spawn(accept_loop(self.inner.clone(), listener))];
        if self.inner.options.broadcast_enabled {
            let u = match bind_udp(0, true) {
                Ok(u) => Arc::new(u),
                Err(source) => {
                    tasks.iter().for_each(|t| t.abort());
                    return Err(DiscoveryError::Bind {
                        what: "Fuji broadcast socket".into(),
                        source,
                    });
                }
            };
            *lock(&self.inner.udp) = Some(u);
            let inner = self.inner.clone();
            tasks.push(tokio::spawn(async move {
                loop {
                    inner.send_broadcast().await;
                    tokio::time::sleep(inner.options.broadcast_interval).await;
                }
            }));
        }
        *lock(&self.running) = Some(Running { port, tasks });
        Ok(())
    }

    async fn stop(&self) {
        if let Some(r) = lock(&self.running).take() {
            r.tasks.iter().for_each(|t| t.abort());
        }
        lock(&self.inner.udp).take();
    }

    fn source_name(&self) -> &'static str {
        "FujiDiscoverer"
    }
}

impl Drop for FujiDiscoverer {
    fn drop(&mut self) {
        if let Some(r) = lock(&self.running).take() {
            r.tasks.iter().for_each(|t| t.abort());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datagram_format() {
        let d = datagram("192.168.0.255", "Tether", 5, FujiConstants::DISCOVERY_PORT);
        assert_eq!(
            String::from_utf8(d).unwrap(),
            "DISCOVERY * HTTP/1.1\r\nHOST: 192.168.0.255:51562\r\nMX: 5\r\nSERVICE: PCSS/1.0\r\nDSCNAME: Tether\r\n\r\n"
        );
        assert_eq!(FujiConstants::DISCOVERY_PORT, 51562);
        assert_eq!(FujiConstants::DIAL_BACK_PORT, 51560);
    }

    #[test]
    fn dial_back_parsing() {
        let full = parse_dial_back(
            "NOTIFY * HTTP/1.1\r\nDSCNAME: X-T5\r\nIMPORT: ptpip\r\nSERVICE: PCSS/1.0\r\n\r\nignored: trailing",
        )
        .unwrap();
        assert!(full.is_notify());
        assert_eq!(full.camera_name(), Some("X-T5"));
        assert_eq!(full.get("Import"), Some("ptpip"));
        assert_eq!(full.get("ignored"), None);

        let no_start = parse_dial_back("dscname:GFX100 II\nmodel:GFX100 II\n").unwrap();
        assert_eq!(no_start.start_line, "");
        assert_eq!(no_start.camera_name(), Some("GFX100 II"));

        let only_model = parse_dial_back("HTTP/1.1 200 OK\r\nMODEL: X-H2S\r\n").unwrap();
        assert_eq!(only_model.camera_name(), Some("X-H2S"));
        assert!(parse_dial_back("   \r\n\r\n").is_none());
    }

    #[test]
    fn ingest_records_peer_as_host() {
        let d = FujiDiscoverer::new(FujiOptions {
            listen_port: 0,
            ..Default::default()
        });
        d.ingest("NOTIFY * HTTP/1.1\r\nDSCNAME: X-T5\r\n\r\n", "192.168.0.10");
        let cam = d.current().into_iter().next().unwrap();
        assert_eq!(cam.id, "192.168.0.10");
        assert_eq!(cam.host, "192.168.0.10");
        assert_eq!(cam.port, 15740);
        assert_eq!(cam.vendor, Some(CameraVendor::Fujifilm));
        assert_eq!(cam.method, DiscoveryMethod::FujiUdp);
        assert_eq!(cam.transport, TransportKind::PtpIp);
        assert_eq!(cam.name, "X-T5");
        assert_eq!(cam.details["startLine"], "NOTIFY * HTTP/1.1");
    }
}
