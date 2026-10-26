//! SSDP (UPnP) discovery for Sony cameras: active M-SEARCH on the multicast
//! group plus passive NOTIFY listening. A hit is only accepted after its
//! device description proves a Sony imaging service.
//! Ported from `SSDPDiscoverer.swift`.

use std::collections::{HashMap, HashSet};
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use quick_xml::events::Event;
use tether_types::{CameraVendor, TransportKind};
use tokio::net::UdpSocket;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use super::{
    CameraDiscovering, DiscoveredCamera, DiscoveryError, DiscoveryMethod, DiscoveryState,
    HttpProbing, ReqwestProber,
};
use crate::net::{bind_udp, decode_text, ip_filter};
use crate::{lock, PTPIP_STANDARD_PORT};

// MARK: - Pure parsing

/// One SSDP datagram: an M-SEARCH response (`HTTP/1.1 200 OK`) or a
/// `NOTIFY * HTTP/1.1`. Header names are lower-cased.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SsdpMessage {
    pub start_line: String,
    pub headers: HashMap<String, String>,
}

impl SsdpMessage {
    pub const MULTICAST_GROUP: &'static str = "239.255.255.250";
    pub const PORT: u16 = 1900;
    pub const SONY_DIGITAL_IMAGING: &'static str = "urn:schemas-sony-com:service:DigitalImaging:1";
    pub const SONY_SCALAR_WEB_API: &'static str = "urn:schemas-sony-com:service:ScalarWebAPI:1";
    pub const SEARCH_TARGETS: [&'static str; 3] = [
        Self::SONY_DIGITAL_IMAGING,
        Self::SONY_SCALAR_WEB_API,
        "ssdp:all",
    ];

    pub fn is_response(&self) -> bool {
        self.start_line.to_uppercase().starts_with("HTTP/") && self.start_line.contains("200")
    }

    pub fn is_notify(&self) -> bool {
        self.start_line.to_uppercase().starts_with("NOTIFY")
    }

    pub fn is_bye_bye(&self) -> bool {
        self.get("nts")
            .map(|v| v.to_lowercase().contains("byebye"))
            .unwrap_or(false)
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.headers.get(&name.to_lowercase()).map(String::as_str)
    }

    pub fn usn(&self) -> Option<&str> {
        self.get("usn")
    }

    pub fn location(&self) -> Option<&str> {
        self.get("location")
    }

    pub fn search_target(&self) -> Option<&str> {
        self.get("st").or_else(|| self.get("nt"))
    }

    pub fn server(&self) -> Option<&str> {
        self.get("server")
    }

    /// `uuid:xxxx` out of the USN, or the whole USN when it has no uuid part.
    pub fn uuid(&self) -> Option<String> {
        let usn = self.usn()?;
        match usn.to_ascii_lowercase().find("uuid:") {
            Some(i) => {
                let rest = &usn[i + 5..];
                let id = rest.split(':').next().unwrap_or("").trim();
                (!id.is_empty()).then(|| id.to_string())
            }
            None => Some(usn.to_string()),
        }
    }

    /// Host part of the LOCATION URL.
    pub fn location_host(&self) -> Option<String> {
        url_host(self.location()?.trim())
    }

    /// Mentions a Sony imaging service in ST/NT/USN/SERVER.
    pub fn mentions_sony(&self) -> bool {
        let hay = format!(
            "{} {} {}",
            self.search_target().unwrap_or(""),
            self.usn().unwrap_or(""),
            self.server().unwrap_or("")
        )
        .to_lowercase();
        hay.contains("sony-com") || hay.contains("sony")
    }

    pub fn parse(text: &str) -> Option<Self> {
        let normalized = text.replace("\r\n", "\n");
        let mut lines = normalized.split('\n');
        let first = lines.next()?.trim_matches(|c| c == ' ' || c == '\t');
        if first.is_empty() {
            return None;
        }
        let up = first.to_uppercase();
        if !(up.starts_with("HTTP/") || up.starts_with("NOTIFY") || up.starts_with("M-SEARCH")) {
            return None;
        }
        let mut headers = HashMap::new();
        for line in lines {
            if line.trim().is_empty() {
                break;
            }
            let Some((k, v)) = line.split_once(':') else {
                continue;
            };
            let key = k.trim().to_lowercase();
            if key.is_empty() {
                continue;
            }
            headers.insert(key, v.trim().to_string());
        }
        Some(Self {
            start_line: first.to_string(),
            headers,
        })
    }

    pub fn m_search(st: &str, mx: u32) -> String {
        format!(
            "M-SEARCH * HTTP/1.1\r\nHOST: {}:{}\r\nMAN: \"ssdp:discover\"\r\nMX: {mx}\r\nST: {st}\r\nUSER-AGENT: Tether/1.0 UPnP/1.1\r\n\r\n",
            Self::MULTICAST_GROUP,
            Self::PORT
        )
    }
}

/// Host of a URL without IPv6 brackets (Foundation's `URL.host`).
pub(crate) fn url_host(s: &str) -> Option<String> {
    let url = reqwest::Url::parse(s).ok()?;
    let host = url.host_str()?;
    Some(
        host.trim_start_matches('[')
            .trim_end_matches(']')
            .to_string(),
    )
}

/// The UPnP device-description document a camera serves at LOCATION.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SsdpDeviceDescription {
    pub friendly_name: String,
    pub manufacturer: String,
    pub model_name: String,
    pub service_types: Vec<String>,
    pub udn: String,
    /// Sony puts the camera's own API base URLs in `av:X_ScalarWebAPI_ServiceList`.
    pub scalar_web_api_urls: Vec<String>,
}

impl SsdpDeviceDescription {
    pub fn is_sony_imaging(&self) -> bool {
        self.service_types.iter().any(|s| {
            let l = s.to_lowercase();
            l.contains("sony-com") && (l.contains("digitalimaging") || l.contains("scalarwebapi"))
        })
    }

    /// Lenient: a document that breaks after the root `<device>` opened still
    /// yields what was read; one without any `<device>` is rejected.
    pub fn parse(xml: &[u8]) -> Option<Self> {
        let mut reader = quick_xml::Reader::from_reader(xml);
        reader.config_mut().trim_text(false);
        let mut d = Self::default();
        let mut saw_device = false;
        let mut path: Vec<String> = Vec::new();
        let mut text = String::new();
        let mut buf = Vec::new();

        let end = |name: &str, path: &mut Vec<String>, text: &mut String, d: &mut Self| {
            let value = text.trim().to_string();
            // Only the root device's identity, not embedded devices'.
            let depth = path.iter().filter(|p| *p == "device").count();
            match name {
                "friendlyName" if depth == 1 && d.friendly_name.is_empty() => {
                    d.friendly_name = value
                }
                "manufacturer" if depth == 1 && d.manufacturer.is_empty() => d.manufacturer = value,
                "modelName" if depth == 1 && d.model_name.is_empty() => d.model_name = value,
                "UDN" if depth == 1 && d.udn.is_empty() => d.udn = value,
                "serviceType" if !value.is_empty() => d.service_types.push(value),
                "X_ScalarWebAPI_ActionList_URL" | "X_ScalarWebAPI_LiveView_URL"
                    if !value.is_empty() =>
                {
                    d.scalar_web_api_urls.push(value)
                }
                _ => {}
            }
            text.clear();
            path.pop();
        };

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(e)) => {
                    let name = String::from_utf8_lossy(e.local_name().as_ref()).into_owned();
                    if name == "device" {
                        saw_device = true;
                    }
                    path.push(name);
                    text.clear();
                }
                Ok(Event::Empty(e)) => {
                    let name = String::from_utf8_lossy(e.local_name().as_ref()).into_owned();
                    if name == "device" {
                        saw_device = true;
                    }
                    path.push(name.clone());
                    text.clear();
                    end(&name, &mut path, &mut text, &mut d);
                }
                Ok(Event::Text(t)) => match t.unescape() {
                    Ok(s) => text.push_str(&s),
                    Err(_) => text.push_str(&String::from_utf8_lossy(t.as_ref())),
                },
                Ok(Event::CData(c)) => text.push_str(&String::from_utf8_lossy(c.as_ref())),
                Ok(Event::End(e)) => {
                    let name = String::from_utf8_lossy(e.local_name().as_ref()).into_owned();
                    end(&name, &mut path, &mut text, &mut d);
                }
                Ok(Event::Eof) | Err(_) => break,
                Ok(_) => {}
            }
            buf.clear();
        }
        saw_device.then_some(d)
    }
}

// MARK: - Discoverer

pub struct SsdpDiscoverer {
    inner: Arc<Inner>,
    tasks: Mutex<Option<Vec<JoinHandle<()>>>>,
}

struct Inner {
    state: DiscoveryState,
    prober: Arc<dyn HttpProbing>,
    search_interval: Duration,
    description_timeout: Duration,
    socket: Mutex<Option<Arc<UdpSocket>>>,
    pending_locations: Mutex<HashSet<String>>,
}

impl Default for SsdpDiscoverer {
    fn default() -> Self {
        Self::new()
    }
}

impl SsdpDiscoverer {
    pub const SEARCH_INTERVAL: Duration = Duration::from_secs(10);
    pub const DESCRIPTION_TIMEOUT: Duration = Duration::from_secs(3);

    pub fn new() -> Self {
        Self::with_prober(Arc::new(ReqwestProber::new()))
    }

    pub fn with_prober(prober: Arc<dyn HttpProbing>) -> Self {
        Self {
            inner: Arc::new(Inner {
                state: DiscoveryState::new(),
                prober,
                search_interval: Self::SEARCH_INTERVAL,
                description_timeout: Self::DESCRIPTION_TIMEOUT,
                socket: Mutex::new(None),
                pending_locations: Mutex::new(HashSet::new()),
            }),
            tasks: Mutex::new(None),
        }
    }

    pub fn current(&self) -> Vec<DiscoveredCamera> {
        self.inner.state.snapshot()
    }

    pub fn last_error(&self) -> Option<String> {
        self.inner.state.last_error()
    }

    /// Sends one M-SEARCH per search target.
    pub async fn send_searches(&self) {
        self.inner.send_searches().await
    }

    /// Handles one datagram's text. Exposed so tests can drive the pipeline
    /// without a socket: parse → byebye removal → description fetch → emit.
    pub async fn ingest(&self, text: &str, source_host: &str) {
        self.inner.ingest(text, source_host).await
    }
}

impl Inner {
    async fn send_searches(&self) {
        let Some(s) = lock(&self.socket).clone() else {
            return;
        };
        let group: Ipv4Addr = Ipv4Addr::new(239, 255, 255, 250);
        for st in SsdpMessage::SEARCH_TARGETS {
            let text = SsdpMessage::m_search(st, 3);
            if let Err(e) = s.send_to(text.as_bytes(), (group, SsdpMessage::PORT)).await {
                self.state.fail(format!("SSDP send failed: {e}"));
            }
        }
    }

    async fn ingest(&self, text: &str, source_host: &str) {
        let Some(msg) = SsdpMessage::parse(text) else {
            return;
        };
        if !(msg.is_response() || msg.is_notify()) {
            return;
        }
        let (Some(usn), Some(id)) = (msg.usn().map(str::to_string), msg.uuid()) else {
            return;
        };
        if msg.is_bye_bye() {
            self.state
                .remove(|c| c.id == id || c.details.get("usn") == Some(&usn));
            return;
        }
        let Some(location) = msg.location().map(str::to_string) else {
            return;
        };
        let Some(host) = url_host(&location) else {
            return;
        };
        if !ip_filter::is_usable(&host) {
            return;
        }
        // Skip obviously non-camera UPnP noise unless asked for all.
        let st = msg.search_target().unwrap_or("").to_lowercase();
        if !msg.mentions_sony()
            && !(st.is_empty()
                || st.contains("upnp:rootdevice")
                || st.contains("mediaserver")
                || st.contains("basic"))
        {
            return;
        }
        if !lock(&self.pending_locations).insert(location.clone()) {
            return;
        }
        let fetched = self.prober.get(&location, self.description_timeout).await;
        lock(&self.pending_locations).remove(&location);

        let (body, status) = match fetched {
            Ok(r) => r,
            Err(e) => {
                self.state
                    .fail(format!("SSDP description fetch failed for {location}: {e}"));
                return;
            }
        };
        if !(200..300).contains(&status) {
            return;
        }
        let Some(desc) = SsdpDeviceDescription::parse(&body) else {
            return;
        };
        if !desc.is_sony_imaging() {
            return;
        }
        let mut details: std::collections::BTreeMap<String, String> = [
            ("location", location.clone()),
            ("usn", usn),
            ("model", desc.model_name.clone()),
            ("manufacturer", desc.manufacturer.clone()),
            ("udn", desc.udn.clone()),
            ("serviceTypes", desc.service_types.join(",")),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        if let Some(server) = msg.server() {
            details.insert("server".into(), server.to_string());
        }
        if !desc.scalar_web_api_urls.is_empty() {
            details.insert("scalarWebAPI".into(), desc.scalar_web_api_urls.join(","));
        }
        if source_host != host {
            details.insert("sourceHost".into(), source_host.to_string());
        }
        let name = if !desc.friendly_name.is_empty() {
            desc.friendly_name.clone()
        } else if !desc.model_name.is_empty() {
            desc.model_name.clone()
        } else {
            "Sony camera".to_string()
        };
        self.state.upsert(
            DiscoveredCamera::new(
                id,
                name,
                Some(CameraVendor::Sony),
                host,
                PTPIP_STANDARD_PORT,
                DiscoveryMethod::Ssdp,
                TransportKind::PtpIp,
            )
            .with_details(details),
        );
    }
}

async fn receive_loop(inner: Arc<Inner>, sock: Arc<UdpSocket>) {
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match sock.recv_from(&mut buf).await {
            Ok((n, from)) => {
                let text = decode_text(&buf[..n]);
                let host = from.ip().to_string();
                let inner = inner.clone();
                tokio::spawn(async move { inner.ingest(&text, &host).await });
            }
            Err(e) => {
                inner.state.fail(format!("SSDP receive failed: {e}"));
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

/// The passive NOTIFY listener on :1900, joined to the SSDP group.
fn listen_socket() -> std::io::Result<UdpSocket> {
    let s = bind_udp(SsdpMessage::PORT, false)?;
    s.join_multicast_v4(Ipv4Addr::new(239, 255, 255, 250), Ipv4Addr::UNSPECIFIED)?;
    s.set_multicast_ttl_v4(2)?;
    Ok(s)
}

#[async_trait]
impl CameraDiscovering for SsdpDiscoverer {
    fn cameras(&self) -> watch::Receiver<Vec<DiscoveredCamera>> {
        self.inner.state.subscribe()
    }

    async fn start(&self) -> Result<(), DiscoveryError> {
        if lock(&self.tasks).is_some() {
            return Ok(());
        }
        // Unicast replies come back to the ephemeral socket; NOTIFYs to :1900.
        let s = Arc::new(bind_udp(0, false).map_err(|source| DiscoveryError::Bind {
            what: "SSDP search socket".into(),
            source,
        })?);
        let l = match listen_socket() {
            Ok(l) => Some(Arc::new(l)),
            Err(e) => {
                self.inner
                    .state
                    .fail(format!("SSDP passive listen unavailable: {e}"));
                None
            }
        };
        *lock(&self.inner.socket) = Some(s.clone());
        let mut tasks = Vec::new();
        for sock in std::iter::once(s).chain(l) {
            tasks.push(tokio::spawn(receive_loop(self.inner.clone(), sock)));
        }
        let inner = self.inner.clone();
        tasks.push(tokio::spawn(async move {
            loop {
                inner.send_searches().await;
                tokio::time::sleep(inner.search_interval).await;
            }
        }));
        *lock(&self.tasks) = Some(tasks);
        Ok(())
    }

    async fn stop(&self) {
        if let Some(ts) = lock(&self.tasks).take() {
            ts.iter().for_each(|t| t.abort());
        }
        lock(&self.inner.socket).take();
    }

    fn source_name(&self) -> &'static str {
        "SSDPDiscoverer"
    }
}

impl Drop for SsdpDiscoverer {
    fn drop(&mut self) {
        if let Some(ts) = lock(&self.tasks).take() {
            ts.iter().for_each(|t| t.abort());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const SONY_RESPONSE: &str = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: http://192.168.122.1:64321/dd.xml\r\nSERVER: UPnP/1.0 SonyImagingDevice/1.0\r\nST: urn:schemas-sony-com:service:ScalarWebAPI:1\r\nUSN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::urn:schemas-sony-com:service:ScalarWebAPI:1\r\nX-AV-Physical-Unit-Info: pa=\"ILCE-7M4\";\r\n\r\n";
    const SONY_NOTIFY: &str = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nNT: upnp:rootdevice\r\nNTS: ssdp:alive\r\nLOCATION: http://192.168.122.1:64321/dd.xml\r\nUSN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::upnp:rootdevice\r\n\r\n";

    #[test]
    fn parses_response_headers_case_insensitively() {
        let m = SsdpMessage::parse(SONY_RESPONSE).unwrap();
        assert!(m.is_response());
        assert!(!m.is_notify());
        assert_eq!(m.location(), Some("http://192.168.122.1:64321/dd.xml"));
        assert_eq!(m.get("Location"), m.location());
        assert_eq!(m.location_host().as_deref(), Some("192.168.122.1"));
        assert_eq!(
            m.uuid().as_deref(),
            Some("00000000-0005-0010-8000-1c994c1b4f3a")
        );
        assert_eq!(
            m.search_target(),
            Some("urn:schemas-sony-com:service:ScalarWebAPI:1")
        );
        assert!(m.mentions_sony());
        assert_eq!(m.get("ext"), Some(""));
    }

    #[test]
    fn parses_notify_and_rejects_garbage() {
        let m = SsdpMessage::parse(SONY_NOTIFY).unwrap();
        assert!(m.is_notify());
        assert!(!m.is_bye_bye());
        assert_eq!(m.search_target(), Some("upnp:rootdevice"));
        assert!(SsdpMessage::parse("hello world").is_none());
        assert!(SsdpMessage::parse("").is_none());
        let bye =
            SsdpMessage::parse("NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nUSN: uuid:abc::x\r\n\r\n")
                .unwrap();
        assert!(bye.is_bye_bye());
        assert_eq!(bye.uuid().as_deref(), Some("abc"));
        let no_uuid = SsdpMessage::parse("NOTIFY * HTTP/1.1\r\nUSN: plain-id\r\n\r\n").unwrap();
        assert_eq!(no_uuid.uuid().as_deref(), Some("plain-id"));
    }

    #[test]
    fn m_search_format() {
        let s = SsdpMessage::m_search(SsdpMessage::SONY_DIGITAL_IMAGING, 3);
        assert!(s.starts_with("M-SEARCH * HTTP/1.1\r\n"));
        assert!(s.contains("HOST: 239.255.255.250:1900\r\n"));
        assert!(s.contains("MAN: \"ssdp:discover\"\r\n"));
        assert!(s.contains("MX: 3\r\n"));
        assert!(s.contains("ST: urn:schemas-sony-com:service:DigitalImaging:1\r\n"));
        assert!(s.ends_with("\r\n\r\n"));
        assert_eq!(SsdpMessage::SEARCH_TARGETS.len(), 3);
        assert!(SsdpMessage::SEARCH_TARGETS.contains(&"ssdp:all"));
        // Our own M-SEARCH parses but is neither a response nor a notify.
        let parsed = SsdpMessage::parse(&s).unwrap();
        assert!(!(parsed.is_response() || parsed.is_notify()));
    }

    #[test]
    fn ipv6_location_host_has_no_brackets() {
        assert_eq!(
            url_host("http://[fd00::5]:8080/dd.xml").as_deref(),
            Some("fd00::5")
        );
    }
}
