//! Ricoh GR III / Theta over HTTP + WebSocket, and the HTTP seam every
//! HTTP camera shares. Ported from `RicohHandler.swift`.
//!
//! Not a PTP device: `prepare` reads `/v1/props`, capture POSTs
//! `/v1/camera/shoot`, new photos arrive over `/v1/changes` (or by polling
//! `/v1/photos`), and live view is the MJPEG stream at `/v1/liveview`.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use serde_json::{Map, Value};
use tether_types::{
    jpeg_payload, CameraCapabilities, CameraIdentity, CameraVendor, CaptureDestination,
    LiveViewFrame, LiveViewQuality, TransportKind,
};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use super::live_frame;
use crate::device::property::format;
use crate::device::{
    vendor_props, CameraEvent, NewObject, PropertyChoice, PropertyDescriptor, PropertyForm,
    TetherProperty, VendorHandler,
};
use crate::ptp::transport::lock;
use crate::ptp::{
    ObjectFormat, ProgressFn, PtpError, PtpEvent, PtpObjectInfo, PtpResult, PtpValue,
};

// MARK: - HTTP seam

/// One HTTP request as the HTTP camera handlers build it.
#[derive(Debug, Clone, PartialEq)]
pub struct HttpRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub timeout: Duration,
}

impl HttpRequest {
    pub fn new(method: &str, url: impl Into<String>) -> Self {
        Self {
            method: method.into(),
            url: url.into(),
            headers: Vec::new(),
            body: None,
            timeout: Duration::from_secs(60),
        }
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// The URL path (no query); empty when the URL does not parse.
    pub fn path(&self) -> String {
        reqwest::Url::parse(&self.url)
            .map(|u| u.path().to_string())
            .unwrap_or_default()
    }

    /// The URL path plus `?query` when there is one.
    pub fn path_and_query(&self) -> String {
        match reqwest::Url::parse(&self.url) {
            Ok(u) => match u.query() {
                Some(q) => format!("{}?{q}", u.path()),
                None => u.path().to_string(),
            },
            Err(_) => String::new(),
        }
    }

    pub fn body_text(&self) -> String {
        self.body
            .as_deref()
            .map(|b| String::from_utf8_lossy(b).into_owned())
            .unwrap_or_default()
    }
}

/// Bytes of a long-lived response body, as they arrive.
pub type ChunkFn = Arc<dyn Fn(Vec<u8>) + Send + Sync>;
/// The stream ended: None for a clean end, else why.
pub type EndFn = Arc<dyn Fn(Option<PtpError>) + Send + Sync>;

/// The HTTP/WebSocket surface the HTTP camera handlers need.
/// [`ReqwestRicohHttp`] is the real one; tests inject a fake.
#[async_trait]
pub trait RicohHttp: Send + Sync {
    /// One request; returns the body and HTTP status.
    async fn send(&self, request: HttpRequest) -> PtpResult<(Vec<u8>, u16)>;
    /// A long-lived response body (multipart live view) delivered in chunks.
    /// Returns a handle that stops the stream.
    fn stream(
        &self,
        request: HttpRequest,
        on_chunk: ChunkFn,
        on_end: EndFn,
    ) -> Box<dyn RicohStreamHandle>;
    /// A WebSocket for `/v1/changes`, or None when there is none (the
    /// handler then polls `/v1/photos`).
    fn web_socket(&self, url: &str) -> Option<Arc<dyn RicohWebSocket>>;
}

pub trait RicohStreamHandle: Send + Sync {
    fn cancel(&self);
}

#[async_trait]
pub trait RicohWebSocket: Send + Sync {
    /// Next text message. Errors when the socket closes.
    async fn receive_text(&self) -> PtpResult<String>;
    fn cancel(&self);
}

fn http_error(e: impl std::fmt::Display) -> PtpError {
    PtpError::Http(e.to_string())
}

/// reqwest (rustls) + tokio-tungstenite implementation. VERIFY: endpoint
/// shapes come from the community notes on the GR II/III Wi-Fi API, not
/// from Ricoh documentation.
pub struct ReqwestRicohHttp {
    client: reqwest::Client,
    stream_client: reqwest::Client,
}

impl Default for ReqwestRicohHttp {
    fn default() -> Self {
        Self::new()
    }
}

impl ReqwestRicohHttp {
    pub fn new() -> Self {
        Self::with_client(reqwest::Client::new())
    }

    /// Uses `client` for plain requests; streams get their own client with
    /// a 60 s idle timeout and no total limit (live view runs for hours).
    pub fn with_client(client: reqwest::Client) -> Self {
        let stream_client = reqwest::Client::builder()
            .read_timeout(Duration::from_secs(60))
            .build()
            .unwrap_or_else(|_| client.clone());
        Self {
            client,
            stream_client,
        }
    }

    fn build(client: &reqwest::Client, r: &HttpRequest) -> PtpResult<reqwest::RequestBuilder> {
        let method = reqwest::Method::from_bytes(r.method.as_bytes()).map_err(http_error)?;
        let mut b = client.request(method, &r.url);
        for (k, v) in &r.headers {
            b = b.header(k, v);
        }
        if let Some(body) = &r.body {
            b = b.body(body.clone());
        }
        Ok(b)
    }
}

struct AbortOnCancel(tokio::task::AbortHandle);

impl RicohStreamHandle for AbortOnCancel {
    fn cancel(&self) {
        self.0.abort();
    }
}

struct NoStream;

impl RicohStreamHandle for NoStream {
    fn cancel(&self) {}
}

#[async_trait]
impl RicohHttp for ReqwestRicohHttp {
    async fn send(&self, request: HttpRequest) -> PtpResult<(Vec<u8>, u16)> {
        let resp = Self::build(&self.client, &request)?
            .timeout(request.timeout)
            .send()
            .await
            .map_err(http_error)?;
        let status = resp.status().as_u16();
        let body = resp.bytes().await.map_err(http_error)?;
        Ok((body.to_vec(), status))
    }

    fn stream(
        &self,
        request: HttpRequest,
        on_chunk: ChunkFn,
        on_end: EndFn,
    ) -> Box<dyn RicohStreamHandle> {
        let builder = match Self::build(&self.stream_client, &request) {
            Ok(b) => b,
            Err(e) => {
                on_end(Some(e));
                return Box::new(NoStream);
            }
        };
        let Ok(rt) = tokio::runtime::Handle::try_current() else {
            on_end(Some(PtpError::Http(
                "No async runtime for the stream.".into(),
            )));
            return Box::new(NoStream);
        };
        let task = rt.spawn(async move {
            let resp = match builder.send().await {
                Ok(r) => r,
                Err(e) => return on_end(Some(http_error(e))),
            };
            let mut body = resp.bytes_stream();
            while let Some(chunk) = body.next().await {
                match chunk {
                    Ok(c) => on_chunk(c.to_vec()),
                    Err(e) => return on_end(Some(http_error(e))),
                }
            }
            on_end(None);
        });
        Box::new(AbortOnCancel(task.abort_handle()))
    }

    fn web_socket(&self, url: &str) -> Option<Arc<dyn RicohWebSocket>> {
        Some(Arc::new(TungsteniteWebSocket::new(url)))
    }
}

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A WebSocket that connects on the first `receive_text` (like
/// URLSessionWebSocketTask, which connects in the background).
pub struct TungsteniteWebSocket {
    url: String,
    stream: tokio::sync::Mutex<Option<WsStream>>,
    cancelled: AtomicBool,
    cancel: Notify,
}

impl TungsteniteWebSocket {
    pub fn new(url: &str) -> Self {
        Self {
            url: url.to_string(),
            stream: tokio::sync::Mutex::new(None),
            cancelled: AtomicBool::new(false),
            cancel: Notify::new(),
        }
    }
}

#[async_trait]
impl RicohWebSocket for TungsteniteWebSocket {
    async fn receive_text(&self) -> PtpResult<String> {
        use tokio_tungstenite::tungstenite::Message;
        let cancelled = self.cancel.notified();
        tokio::pin!(cancelled);
        cancelled.as_mut().enable();
        if self.cancelled.load(Ordering::SeqCst) {
            return Err(PtpError::Cancelled);
        }
        let mut guard = self.stream.lock().await;
        if guard.is_none() {
            let connect = tokio_tungstenite::connect_async(self.url.as_str());
            let (ws, _) = tokio::select! {
                r = connect => r.map_err(http_error)?,
                _ = cancelled.as_mut() => return Err(PtpError::Cancelled),
            };
            *guard = Some(ws);
        }
        let Some(ws) = guard.as_mut() else {
            return Err(PtpError::TransportClosed);
        };
        loop {
            let msg = tokio::select! {
                m = ws.next() => m,
                _ = cancelled.as_mut() => return Err(PtpError::Cancelled),
            };
            match msg {
                None | Some(Ok(Message::Close(_))) => return Err(PtpError::TransportClosed),
                Some(Err(e)) => return Err(http_error(e)),
                Some(Ok(Message::Text(t))) => return Ok(t.to_string()),
                Some(Ok(Message::Binary(b))) => {
                    if let Ok(s) = String::from_utf8(b.to_vec()) {
                        return Ok(s);
                    }
                }
                Some(Ok(_)) => continue,
            }
        }
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.cancel.notify_waiters();
    }
}

// MARK: - Wire helpers

fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from > haystack.len() {
        return None;
    }
    haystack[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|i| from + i)
}

/// Splits a `multipart/x-mixed-replace` MJPEG body into JPEG frames. Feed
/// chunks as they arrive; frames come out whole. Handles `Content-Length`
/// parts and, when the header lacks it, parts delimited by the next boundary.
#[derive(Debug, Clone, Default)]
pub struct MjpegFrameSplitter {
    buffer: Vec<u8>,
    boundary: Option<Vec<u8>>,
    frames_emitted: usize,
}

impl MjpegFrameSplitter {
    pub fn new(boundary: Option<&str>) -> Self {
        Self {
            boundary: boundary.map(|b| {
                let b = b.strip_prefix("--").unwrap_or(b);
                format!("--{b}").into_bytes()
            }),
            ..Default::default()
        }
    }

    pub fn frames_emitted(&self) -> usize {
        self.frames_emitted
    }

    pub fn feed(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(chunk);
        let mut frames = Vec::new();
        while let Some(f) = self.next_frame() {
            frames.push(f);
        }
        frames
    }

    fn next_frame(&mut self) -> Option<Vec<u8>> {
        const CRLF: &[u8] = b"\r\n";
        const HEADER_END: &[u8] = b"\r\n\r\n";
        // Locate the boundary line.
        if self.boundary.is_none() {
            let dash = find(&self.buffer, b"--", 0)?;
            let eol = find(&self.buffer, CRLF, dash)?;
            self.boundary = Some(self.buffer[dash..eol].to_vec());
        }
        let b = self.boundary.clone()?;
        let b_start = find(&self.buffer, &b, 0)?;
        let b_end = b_start + b.len();
        let header_end = find(&self.buffer, HEADER_END, b_end)?;
        let header_text = String::from_utf8_lossy(&self.buffer[b_end..header_end]).into_owned();
        let body_start = header_end + HEADER_END.len();
        let mut length: Option<usize> = None;
        for line in header_text.split(['\r', '\n']) {
            if let Some((k, v)) = line.split_once(':') {
                if k.trim().eq_ignore_ascii_case("content-length") {
                    length = v.trim().parse().ok();
                }
            }
        }
        let (frame, consumed_end) = match length {
            Some(n) => {
                if self.buffer.len() - body_start < n {
                    return None;
                }
                (
                    self.buffer[body_start..body_start + n].to_vec(),
                    body_start + n,
                )
            }
            None => {
                let next = find(&self.buffer, &b, body_start)?;
                let mut end = next;
                if end >= 2 && self.buffer[end - 2] == 0x0D && self.buffer[end - 1] == 0x0A {
                    end -= 2;
                }
                (self.buffer[body_start..end.max(body_start)].to_vec(), next)
            }
        };
        self.buffer.drain(..consumed_end);
        self.frames_emitted += 1;
        Some(jpeg_payload(&frame).map(<[u8]>::to_vec).unwrap_or(frame))
    }
}

/// Parses the JSON messages `/v1/changes` pushes. VERIFY: message shape
/// (`{"changed":["storage"], ...}` with photo paths somewhere inside) is
/// from community notes; we therefore collect every photo-looking path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RicohChangeMessage {
    pub photo_paths: Vec<String>,
    pub camera_changed: bool,
    pub storage_changed: bool,
}

impl RicohChangeMessage {
    pub const PHOTO_EXTENSIONS: [&'static str; 5] = ["jpg", "jpeg", "dng", "mov", "mp4"];

    pub fn parse(text: &str) -> Option<RicohChangeMessage> {
        let json: Value = serde_json::from_str(text).ok()?;
        let mut paths = Vec::new();
        Self::collect_paths(&json, &mut paths);
        let (mut camera, mut storage) = (false, false);
        if let Value::Object(dict) = &json {
            let changed: Vec<String> = match dict.get("changed") {
                Some(Value::Array(a)) => a
                    .iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect(),
                Some(Value::String(s)) => vec![s.clone()],
                _ => Vec::new(),
            };
            camera = changed.iter().any(|c| {
                let c = c.to_lowercase();
                c.contains("camera") || c.contains("param")
            });
            storage = changed.iter().any(|c| {
                let c = c.to_lowercase();
                c.contains("storage") || c.contains("photo")
            });
            if dict.contains_key("camera") {
                camera = true;
            }
            if dict.contains_key("storage")
                || dict.contains_key("photos")
                || dict.contains_key("photo")
            {
                storage = true;
            }
        }
        let mut seen = HashSet::new();
        let unique: Vec<String> = paths
            .into_iter()
            .filter(|p| seen.insert(p.clone()))
            .collect();
        let storage_changed = storage || !unique.is_empty();
        Some(RicohChangeMessage {
            photo_paths: unique,
            camera_changed: camera,
            storage_changed,
        })
    }

    pub fn is_photo_path(s: &str) -> bool {
        if !s.contains('/') || s.starts_with("http") {
            return false;
        }
        let ext = path_extension(s).to_lowercase();
        Self::PHOTO_EXTENSIONS.contains(&ext.as_str())
    }

    fn collect_paths(value: &Value, out: &mut Vec<String>) {
        match value {
            Value::String(s) => {
                if Self::is_photo_path(s) {
                    out.push(s.strip_prefix('/').unwrap_or(s).to_string());
                }
            }
            Value::Array(a) => a.iter().for_each(|v| Self::collect_paths(v, out)),
            Value::Object(d) => d.values().for_each(|v| Self::collect_paths(v, out)),
            _ => {}
        }
    }
}

/// NSString.lastPathComponent.
pub(crate) fn last_path_component(path: &str) -> &str {
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(path)
}

/// NSString.pathExtension (of the last component; "" when none).
pub(crate) fn path_extension(path: &str) -> &str {
    let name = last_path_component(path);
    match name.rfind('.') {
        Some(i) if i > 0 => &name[i + 1..],
        _ => "",
    }
}

/// Stable u32 handles for photo paths (FNV-1a, never 0).
#[derive(Debug, Default)]
pub struct RicohHandleMap {
    inner: Mutex<(HashMap<String, u32>, HashMap<u32, String>)>,
}

impl RicohHandleMap {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn hash(path: &str) -> u32 {
        let mut h: u32 = 0x811C_9DC5;
        for byte in path.bytes() {
            h ^= u32::from(byte);
            h = h.wrapping_mul(0x0100_0193);
        }
        if h == 0 {
            1
        } else {
            h
        }
    }

    pub fn handle_for(&self, path: &str) -> u32 {
        let mut m = lock(&self.inner);
        if let Some(&h) = m.0.get(path) {
            return h;
        }
        let mut h = Self::hash(path);
        while m.1.contains_key(&h) {
            h = h.wrapping_add(1);
            if h == 0 {
                h = 1;
            }
        }
        m.0.insert(path.to_string(), h);
        m.1.insert(h, path.to_string());
        h
    }

    pub fn path_for(&self, handle: u32) -> Option<String> {
        lock(&self.inner).1.get(&handle).cloned()
    }
}

/// All Ricoh endpoint paths and parameter keys in one place. VERIFY: every
/// path/key comes from community reverse-engineering of the GR II/III app.
pub mod codes {
    use super::*;

    pub const PROPS: &str = "/v1/props"; // VERIFY
    pub const SHOOT: &str = "/v1/camera/shoot"; // VERIFY
    pub const PARAMS: &str = "/v1/params/camera"; // VERIFY
    pub const PHOTOS: &str = "/v1/photos"; // VERIFY
    pub const LIVEVIEW: &str = "/v1/liveview"; // VERIFY
    pub const CHANGES: &str = "/v1/changes"; // VERIFY (WebSocket)
    /// VERIFY: JPEG proxy for DNG originals.
    pub const VIEW_SIZE_QUERY: &str = "size=view";

    pub const PARAM_KEYS: [&str; 9] = [
        "av",
        "tv",
        "sv",
        "xv",
        "WBMode",
        "shootMode",
        "exposureMode",
        "stillSize",
        "stillFormat",
    ];

    pub fn key_for(p: TetherProperty) -> Option<&'static str> {
        use TetherProperty as P;
        Some(match p {
            P::Aperture => "av",
            P::ShutterSpeed => "tv",
            P::Iso => "sv",
            P::ExposureCompensation => "xv",
            P::WhiteBalance => "WBMode",
            P::ExposureProgram => "exposureMode",
            P::ImageSize => "stillSize",
            P::ImageQuality => "stillFormat",
            _ => return None,
        })
    }

    /// Foundation's `capitalized`: first letter of each word upper, rest lower.
    fn capitalized(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        let mut start = true;
        for c in s.chars() {
            if c.is_alphanumeric() {
                if start {
                    out.extend(c.to_uppercase());
                } else {
                    out.extend(c.to_lowercase());
                }
                start = false;
            } else {
                out.push(c);
                start = true;
            }
        }
        out
    }

    pub fn display(p: TetherProperty, s: &str) -> String {
        match p {
            TetherProperty::Aperture => match s.parse::<f64>() {
                Ok(f) => super::super::f_number(f),
                Err(_) => s.to_string(),
            },
            TetherProperty::ShutterSpeed => {
                if s.contains('/') || s.eq_ignore_ascii_case("bulb") {
                    return s.to_string();
                }
                match s.parse::<f64>() {
                    Ok(secs) => format::shutter_seconds(secs),
                    Err(_) => s.to_string(),
                }
            }
            TetherProperty::Iso => {
                if s.eq_ignore_ascii_case("auto") {
                    "Auto".into()
                } else {
                    s.to_string()
                }
            }
            TetherProperty::ExposureCompensation => match s.parse::<f64>() {
                Ok(ev) => format::exposure_compensation((ev * 1000.0).round() as i64),
                Err(_) => s.to_string(),
            },
            TetherProperty::WhiteBalance => capitalized(&s.replace('_', " ")),
            _ => s.to_string(),
        }
    }
}

/// NSNumber.stringValue for a JSON scalar.
fn scalar_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(if *b { "1" } else { "0" }.into()),
        _ => None,
    }
}

/// NSNumber.intValue for a JSON number.
fn number_int(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::Bool(b) => Some(i64::from(*b)),
        _ => None,
    }
}

/// The subset of `/v1/props` we use. VERIFY: key names from GR II/III notes.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RicohProps {
    pub model: String,
    pub firmware: String,
    pub serial: String,
    pub battery_percent: Option<i64>,
    /// Shooting parameters by API key (av, tv, sv, xv, WBMode, …).
    pub params: HashMap<String, String>,
    /// Allowed values per API key (avList, tvList, …).
    pub lists: HashMap<String, Vec<String>>,
}

impl RicohProps {
    pub fn parse(data: &[u8]) -> PtpResult<RicohProps> {
        let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(data) else {
            return Err(PtpError::Malformed(
                "Ricoh /v1/props is not a JSON object".into(),
            ));
        };
        let str_of = |keys: &[&str]| -> String {
            keys.iter()
                .find_map(|k| root.get(*k).and_then(scalar_string))
                .unwrap_or_default()
        };
        let battery_percent = match root.get("battery") {
            Some(Value::String(s)) => s.parse().ok(),
            Some(Value::Object(d)) => d
                .get("level")
                .and_then(number_int)
                .or_else(|| d.get("percent").and_then(number_int)),
            Some(v) => number_int(v),
            None => None,
        };
        let mut params = HashMap::new();
        let mut lists = HashMap::new();
        for key in codes::PARAM_KEYS {
            if let Some(s) = root.get(key).and_then(scalar_string) {
                params.insert(key.to_string(), s);
            }
            if let Some(Value::Array(arr)) = root.get(&format!("{key}List")) {
                lists.insert(
                    key.to_string(),
                    arr.iter().filter_map(scalar_string).collect(),
                );
            }
        }
        Ok(RicohProps {
            model: str_of(&["model"]),
            firmware: str_of(&["firmwareVersion", "firmware"]),
            serial: str_of(&["serialNo", "serialNumber", "serial"]),
            battery_percent,
            params,
            lists,
        })
    }
}

/// Swift's `JSONSerialization` with `.sortedKeys` (serde_json maps are sorted).
pub(crate) fn json_body(body: Map<String, Value>) -> Vec<u8> {
    serde_json::to_vec(&Value::Object(body)).unwrap_or_default()
}

// MARK: - Handler

struct RicohState {
    pending: Vec<CameraEvent>,
    known_photos: Option<HashSet<String>>,
    last_props: Option<RicohProps>,
    event_task: Option<JoinHandle<()>>,
    socket: Option<Arc<dyn RicohWebSocket>>,
    live_stream: Option<Box<dyn RicohStreamHandle>>,
    splitter: MjpegFrameSplitter,
    latest_frame: Option<LiveViewFrame>,
    frame_sequence: u64,
    live_view_error: Option<PtpError>,
    photo_poll_interval: Duration,
}

struct RicohInner {
    base_url: String,
    http: Arc<dyn RicohHttp>,
    handles: RicohHandleMap,
    prefer_view_proxy_for_raw: AtomicBool,
    state: Mutex<RicohState>,
}

/// Ricoh GR III / Theta over HTTP + WebSocket. Not a PTP device.
pub struct RicohHandler {
    inner: Arc<RicohInner>,
}

impl RicohHandler {
    pub const DEFAULT_BASE_URL: &'static str = "http://192.168.0.1";

    pub const CAPABILITIES: CameraCapabilities = CameraCapabilities::REMOTE_CAPTURE
        .union(CameraCapabilities::CARD_CAPTURE)
        .union(CameraCapabilities::LIVE_VIEW)
        .union(CameraCapabilities::PROPERTY_CONTROL)
        .union(CameraCapabilities::AUTOFOCUS)
        .union(CameraCapabilities::WIRELESS)
        .union(CameraCapabilities::REDUCED_IMAGE);

    /// A GR at `base_url` (usually [`Self::DEFAULT_BASE_URL`]) over reqwest.
    pub fn new(base_url: &str) -> Self {
        Self::with_http(base_url, Arc::new(ReqwestRicohHttp::new()))
    }

    pub fn with_http(base_url: &str, http: Arc<dyn RicohHttp>) -> Self {
        Self {
            inner: Arc::new(RicohInner {
                base_url: base_url.to_string(),
                http,
                handles: RicohHandleMap::new(),
                prefer_view_proxy_for_raw: AtomicBool::new(true),
                state: Mutex::new(RicohState {
                    pending: Vec::new(),
                    known_photos: None,
                    last_props: None,
                    event_task: None,
                    socket: None,
                    live_stream: None,
                    splitter: MjpegFrameSplitter::default(),
                    latest_frame: None,
                    frame_sequence: 0,
                    live_view_error: None,
                    photo_poll_interval: Duration::from_secs(1),
                }),
            }),
        }
    }

    pub fn base_url(&self) -> &str {
        &self.inner.base_url
    }

    pub fn handles(&self) -> &RicohHandleMap {
        &self.inner.handles
    }

    /// Interval for the `/v1/photos` polling fallback (default 1 s).
    pub fn set_photo_poll_interval(&self, d: Duration) {
        lock(&self.inner.state).photo_poll_interval = d;
    }

    /// Fetch a JPEG proxy (`?size=view`) instead of the DNG original (default on).
    pub fn set_prefer_view_proxy_for_raw(&self, on: bool) {
        self.inner
            .prefer_view_proxy_for_raw
            .store(on, Ordering::SeqCst);
    }

    /// The props read last (`prepare`, `read_properties`, `probe_identity`).
    pub fn last_props(&self) -> Option<RicohProps> {
        lock(&self.inner.state).last_props.clone()
    }

    pub fn shoot_body(autofocus: bool) -> Vec<u8> {
        let mut m = Map::new();
        m.insert("af".into(), Value::Bool(autofocus));
        json_body(m)
    }

    pub async fn fetch_props(&self) -> PtpResult<RicohProps> {
        self.inner.fetch_props().await
    }

    /// True when `host` answers `/v1/props` with JSON that names a model.
    pub async fn probe(host: &str, timeout: Duration, http: Option<Arc<dyn RicohHttp>>) -> bool {
        let base = if host.starts_with("http") {
            host.to_string()
        } else {
            format!("http://{host}")
        };
        let mut req = HttpRequest::new("GET", format!("{base}{}", codes::PROPS));
        req.timeout = timeout;
        let client: Arc<dyn RicohHttp> = match http {
            Some(h) => h,
            None => Arc::new(ReqwestRicohHttp::with_client(
                reqwest::Client::builder()
                    .timeout(timeout)
                    .build()
                    .unwrap_or_default(),
            )),
        };
        let Ok((data, 200)) = client.send(req).await else {
            return false;
        };
        matches!(serde_json::from_slice::<Value>(&data), Ok(Value::Object(root)) if root.contains_key("model"))
    }

    /// Lists `/v1/photos` as `dir/file` paths. VERIFY: `{"dirs":[{"name":..,"files":[..]}]}`.
    pub fn photo_paths(data: &[u8]) -> Vec<String> {
        let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(data) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        if let Some(Value::Array(dirs)) = root.get("dirs") {
            for d in dirs {
                let Some(name) = d.get("name").and_then(Value::as_str) else {
                    continue;
                };
                if let Some(Value::Array(files)) = d.get("files") {
                    for f in files.iter().filter_map(Value::as_str) {
                        out.push(format!("{name}/{f}"));
                    }
                }
            }
        }
        if let Some(Value::Array(flat)) = root.get("photos") {
            out.extend(flat.iter().filter_map(Value::as_str).map(str::to_string));
        }
        out
    }

    /// One `/v1/photos` poll; announces paths not seen before.
    pub async fn poll_photos_once(&self) {
        self.inner.poll_photos_once().await;
    }

    /// Feeds one `/v1/changes` message. Exposed for tests.
    pub fn handle_change(&self, text: &str) {
        self.inner.handle_change(text);
    }

    /// Feeds raw multipart bytes. Exposed for tests.
    pub fn ingest_live_view(&self, chunk: &[u8]) {
        self.inner.ingest_live_view(chunk);
    }

    pub fn descriptors(properties: &[TetherProperty], p: &RicohProps) -> Vec<PropertyDescriptor> {
        let mut out = Vec::new();
        for &prop in properties {
            if prop == TetherProperty::BatteryLevel {
                if let Some(b) = p.battery_percent {
                    out.push(PropertyDescriptor::new(
                        TetherProperty::BatteryLevel,
                        PtpValue::UInt8(b.clamp(0, 255) as u8),
                        format::battery(b),
                        false,
                        PropertyForm::Other,
                    ));
                }
                continue;
            }
            if prop == TetherProperty::CaptureDestination {
                out.push(vendor_props::destination_descriptor(
                    CaptureDestination::Card,
                    &[CaptureDestination::Card],
                    false,
                ));
                continue;
            }
            let Some(key) = codes::key_for(prop) else {
                continue;
            };
            let Some(value) = p.params.get(key) else {
                continue;
            };
            let choices: Vec<PropertyChoice> = p
                .lists
                .get(key)
                .map(|l| {
                    l.iter()
                        .map(|v| {
                            PropertyChoice::new(
                                PtpValue::String(v.clone()),
                                codes::display(prop, v),
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            let form = if choices.is_empty() {
                PropertyForm::Other
            } else {
                PropertyForm::Choices(choices)
            };
            out.push(PropertyDescriptor::new(
                prop,
                PtpValue::String(value.clone()),
                codes::display(prop, value),
                true,
                form,
            ));
        }
        out
    }

    pub fn object_info(path: &str, size: usize) -> PtpObjectInfo {
        let name = last_path_component(path).to_string();
        let ext = path_extension(&name).to_lowercase();
        let format = match ext.as_str() {
            "dng" => ObjectFormat::DNG,
            "jpg" | "jpeg" => ObjectFormat::EXIF_JPEG,
            "mov" | "mp4" => ObjectFormat::MP4,
            _ => ObjectFormat::UNDEFINED,
        };
        PtpObjectInfo {
            storage_id: 0x0001_0001,
            object_format: format,
            object_compressed_size: u32::try_from(size).unwrap_or(u32::MAX),
            filename: name,
            ..Default::default()
        }
    }

    /// The untouched original regardless of the view-proxy preference.
    pub async fn fetch_original(&self, path: &str) -> PtpResult<Vec<u8>> {
        self.inner
            .get(&format!("{}/{path}", codes::PHOTOS), None)
            .await
    }

    fn start_event_stream(&self) {
        let inner = &self.inner;
        let ws_url = web_socket_url(&inner.url(codes::CHANGES, None));
        let weak = Arc::downgrade(inner);
        let socket = inner.http.web_socket(&ws_url);
        let mut s = lock(&inner.state);
        if let Some(t) = s.event_task.take() {
            t.abort();
        }
        let task = match socket {
            Some(ws) => {
                s.socket = Some(ws.clone());
                tokio::spawn(async move {
                    loop {
                        let r = ws.receive_text().await;
                        let Some(inner) = weak.upgrade() else { return };
                        match r {
                            Ok(text) => inner.handle_change(&text),
                            Err(_) => {
                                // Socket dropped: fall back to polling.
                                lock(&inner.state).socket = None;
                                drop(inner);
                                RicohInner::poll_loop(weak).await;
                                return;
                            }
                        }
                    }
                })
            }
            None => tokio::spawn(RicohInner::poll_loop(weak)),
        };
        s.event_task = Some(task);
    }
}

impl Drop for RicohHandler {
    fn drop(&mut self) {
        let mut s = lock(&self.inner.state);
        if let Some(t) = s.event_task.take() {
            t.abort();
        }
        if let Some(ws) = s.socket.take() {
            ws.cancel();
        }
        if let Some(l) = s.live_stream.take() {
            l.cancel();
        }
    }
}

/// http(s):// → ws(s)://.
fn web_socket_url(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = url.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        url.to_string()
    }
}

impl RicohInner {
    fn url(&self, path: &str, query: Option<&str>) -> String {
        let mut s = self.base_url.trim_end_matches('/').to_string();
        // Swift removed one trailing slash; trimming all is equivalent for real bases.
        s.push_str(path);
        if let Some(q) = query {
            s.push('?');
            s.push_str(q);
        }
        s
    }

    async fn get(&self, path: &str, query: Option<&str>) -> PtpResult<Vec<u8>> {
        let mut req = HttpRequest::new("GET", self.url(path, query));
        req.timeout = Duration::from_secs(30);
        let (data, status) = self.http.send(req).await?;
        if !(200..300).contains(&status) {
            return Err(PtpError::Unsupported(format!(
                "Ricoh {path} answered HTTP {status}."
            )));
        }
        Ok(data)
    }

    async fn send_json(
        &self,
        method: &str,
        path: &str,
        body: Map<String, Value>,
    ) -> PtpResult<Vec<u8>> {
        let mut req = HttpRequest::new(method, self.url(path, None));
        req.timeout = Duration::from_secs(30);
        req.headers
            .push(("Content-Type".into(), "application/json".into()));
        req.body = Some(json_body(body));
        let (data, status) = self.http.send(req).await?;
        if !(200..300).contains(&status) {
            return Err(PtpError::Unsupported(format!(
                "Ricoh {path} answered HTTP {status}."
            )));
        }
        if let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(&data) {
            if let Some(code) = root.get("errCode").and_then(number_int) {
                if code != 200 {
                    let msg = root
                        .get("errMsg")
                        .and_then(Value::as_str)
                        .map_or_else(|| format!("error {code}"), str::to_string);
                    return Err(PtpError::Unsupported(format!(
                        "Ricoh rejected {path}: {msg}"
                    )));
                }
            }
        }
        Ok(data)
    }

    async fn fetch_props(&self) -> PtpResult<RicohProps> {
        let p = RicohProps::parse(&self.get(codes::PROPS, None).await?)?;
        lock(&self.state).last_props = Some(p.clone());
        Ok(p)
    }

    async fn seed_photos(&self) {
        let Ok(data) = self.get(codes::PHOTOS, None).await else {
            return;
        };
        lock(&self.state).known_photos =
            Some(RicohHandler::photo_paths(&data).into_iter().collect());
    }

    async fn poll_photos_once(&self) {
        let Ok(data) = self.get(codes::PHOTOS, None).await else {
            return;
        };
        let mut events = Vec::new();
        self.announce(&RicohHandler::photo_paths(&data), &mut events);
        if !events.is_empty() {
            lock(&self.state).pending.extend(events);
        }
    }

    async fn poll_loop(weak: Weak<RicohInner>) {
        loop {
            let Some(inner) = weak.upgrade() else { return };
            inner.poll_photos_once().await;
            let d = lock(&inner.state)
                .photo_poll_interval
                .max(Duration::from_millis(100));
            drop(inner);
            tokio::time::sleep(d).await;
        }
    }

    fn handle_change(&self, text: &str) {
        let Some(parsed) = RicohChangeMessage::parse(text) else {
            return;
        };
        let mut events = Vec::new();
        if parsed.camera_changed {
            events.push(CameraEvent::PropertyChanged(None));
        }
        if !parsed.photo_paths.is_empty() {
            self.announce(&parsed.photo_paths, &mut events);
        } else if parsed.storage_changed {
            events.push(CameraEvent::StorageChanged);
        }
        if !events.is_empty() {
            lock(&self.state).pending.extend(events);
        }
    }

    fn announce(&self, paths: &[String], events: &mut Vec<CameraEvent>) {
        let (seeded, fresh) = {
            let mut s = lock(&self.state);
            let seeded = s.known_photos.is_some();
            let known = s.known_photos.get_or_insert_with(HashSet::new);
            let fresh: Vec<String> = paths
                .iter()
                .filter(|p| known.insert((*p).clone()))
                .cloned()
                .collect();
            (seeded, fresh)
        };
        if !seeded {
            return;
        }
        for p in fresh {
            events.push(CameraEvent::ObjectAdded(NewObject {
                handle: self.handles.handle_for(&p),
                storage_id: 0x0001_0001,
                info: Some(RicohHandler::object_info(&p, 0)),
                in_sdram: false,
            }));
        }
    }

    fn ingest_live_view(&self, chunk: &[u8]) {
        let mut s = lock(&self.state);
        for frame in s.splitter.feed(chunk) {
            s.frame_sequence += 1;
            let seq = s.frame_sequence;
            s.latest_frame = Some(live_frame(frame, seq));
        }
    }
}

#[async_trait]
impl VendorHandler for RicohHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Ricoh
    }

    fn capabilities(&self) -> CameraCapabilities {
        Self::CAPABILITIES
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(500)
    }

    async fn prepare(&self) -> PtpResult<()> {
        self.inner.fetch_props().await?;
        self.inner.seed_photos().await;
        self.start_event_stream();
        Ok(())
    }

    async fn teardown(&self) {
        let (task, socket) = {
            let mut s = lock(&self.inner.state);
            (s.event_task.take(), s.socket.take())
        };
        if let Some(t) = task {
            t.abort();
        }
        if let Some(ws) = socket {
            ws.cancel();
        }
        self.stop_live_view().await;
    }

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "Ricoh cameras write to the card; the file is copied over afterwards.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, autofocus: bool) -> PtpResult<()> {
        let mut body = Map::new();
        body.insert("af".into(), Value::Bool(autofocus));
        self.inner
            .send_json("POST", codes::SHOOT, body)
            .await
            .map(|_| ())
    }

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        Ok(std::mem::take(&mut lock(&self.inner.state).pending))
    }

    async fn translate(&self, _event: &PtpEvent) -> Option<CameraEvent> {
        None
    }

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        let p = self.inner.fetch_props().await?;
        Ok(Self::descriptors(properties, &p))
    }

    async fn write_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()> {
        let Some(key) = codes::key_for(property) else {
            return Err(super::cannot_set(property));
        };
        let value = if let Some(s) = raw.string_value() {
            s.to_string()
        } else if let Some(n) = raw.int_value() {
            n.to_string()
        } else {
            return Err(PtpError::Unsupported(format!(
                "Unsupported value for {}.",
                property.display_name()
            )));
        };
        let mut body = Map::new();
        body.insert(key.into(), Value::String(value));
        self.inner
            .send_json("PUT", codes::PARAMS, body)
            .await
            .map(|_| ())
    }

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        let path = self.inner.handles.path_for(object.handle).or_else(|| {
            object
                .info
                .as_ref()
                .map(|i| i.filename.clone())
                .filter(|f| !f.is_empty())
        });
        let Some(path) = path else {
            return Err(PtpError::Unsupported(format!(
                "Unknown Ricoh photo handle {}.",
                object.handle
            )));
        };
        let is_raw = path_extension(&path).eq_ignore_ascii_case("dng");
        let use_proxy = is_raw && self.inner.prefer_view_proxy_for_raw.load(Ordering::SeqCst);
        let data = self
            .inner
            .get(
                &format!("{}/{path}", codes::PHOTOS),
                use_proxy.then_some(codes::VIEW_SIZE_QUERY),
            )
            .await?;
        let mut info = Self::object_info(&path, data.len());
        if use_proxy {
            info.object_format = ObjectFormat::EXIF_JPEG;
            let stem = match info.filename.rfind('.') {
                Some(i) if i > 0 => info.filename[..i].to_string(),
                _ => info.filename.clone(),
            };
            info.filename = format!("{stem}.JPG");
        }
        if let Some(p) = &progress {
            p(data.len(), Some(data.len()));
        }
        Ok((info, data))
    }

    async fn start_live_view(&self, _quality: LiveViewQuality) -> PtpResult<()> {
        self.stop_live_view().await;
        {
            let mut s = lock(&self.inner.state);
            s.splitter = MjpegFrameSplitter::default();
            s.latest_frame = None;
            s.live_view_error = None;
        }
        let req = HttpRequest::new("GET", self.inner.url(codes::LIVEVIEW, None));
        let chunk_target = Arc::downgrade(&self.inner);
        let end_target = Arc::downgrade(&self.inner);
        let handle = self.inner.http.stream(
            req,
            Arc::new(move |chunk| {
                if let Some(inner) = chunk_target.upgrade() {
                    inner.ingest_live_view(&chunk);
                }
            }),
            Arc::new(move |error| {
                if let Some(inner) = end_target.upgrade() {
                    lock(&inner.state).live_view_error = error;
                }
            }),
        );
        lock(&self.inner.state).live_stream = Some(handle);
        Ok(())
    }

    async fn stop_live_view(&self) {
        let stream = lock(&self.inner.state).live_stream.take();
        if let Some(s) = stream {
            s.cancel();
        }
    }

    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        let mut s = lock(&self.inner.state);
        if s.latest_frame.is_none() {
            if let Some(e) = s.live_view_error.take() {
                return Err(e);
            }
        }
        Ok(s.latest_frame.take())
    }
}

#[async_trait]
impl super::HttpCameraHandler for RicohHandler {
    async fn probe_identity(&self) -> PtpResult<CameraIdentity> {
        let p = self.inner.fetch_props().await?;
        let id = if p.serial.is_empty() {
            let host = reqwest::Url::parse(&self.inner.base_url)
                .ok()
                .and_then(|u| u.host_str().map(str::to_string))
                .unwrap_or_else(|| "camera".into());
            format!("ricoh-{host}")
        } else {
            format!("ricoh-{}", p.serial)
        };
        Ok(CameraIdentity {
            id,
            vendor: CameraVendor::Ricoh,
            manufacturer: "Ricoh".into(),
            model: p.model,
            serial_number: p.serial,
            firmware: p.firmware,
            transport: TransportKind::RicohHttp,
            capabilities: Self::CAPABILITIES,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_helpers_match_nsstring() {
        assert_eq!(last_path_component("100RICOH/R0000001.JPG"), "R0000001.JPG");
        assert_eq!(path_extension("100RICOH/R0000001.JPG"), "JPG");
        assert_eq!(path_extension("100RICOH/.hidden"), "");
        assert_eq!(path_extension("dir.d/file"), "");
        assert_eq!(web_socket_url("http://h/v1/changes"), "ws://h/v1/changes");
        assert_eq!(web_socket_url("https://h/x"), "wss://h/x");
    }

    #[test]
    fn display_rules() {
        use TetherProperty as P;
        assert_eq!(codes::display(P::Aperture, "4.0"), "ƒ/4");
        assert_eq!(codes::display(P::Aperture, "f?"), "f?");
        assert_eq!(codes::display(P::ShutterSpeed, "1/250"), "1/250");
        assert_eq!(codes::display(P::ShutterSpeed, "2"), "2\"");
        assert_eq!(codes::display(P::Iso, "auto"), "Auto");
        assert_eq!(codes::display(P::ExposureCompensation, "0.7"), "+0.7");
        assert_eq!(codes::display(P::WhiteBalance, "multi_auto"), "Multi Auto");
        assert_eq!(codes::display(P::ImageSize, "L"), "L");
    }

    #[test]
    fn splitter_with_explicit_boundary() {
        let j = vec![0xFF, 0xD8, 1, 2, 0xFF, 0xD9];
        let mut body = b"--myboundary\r\nContent-Length: 6\r\n\r\n".to_vec();
        body.extend(&j);
        let mut s = MjpegFrameSplitter::new(Some("--myboundary"));
        assert_eq!(s.feed(&body), vec![j]);
    }
}
