//! Cameras controlled over HTTP on their own Wi-Fi access point, built on
//! the same seam as the Ricoh GR handler ([`RicohHttp`]): GoPro (Open GoPro
//! API) and 360° cameras that speak Google's Open Spherical Camera API
//! (Ricoh Theta, Insta360 and others). Both find new photos by listing the
//! card and diffing, and download them by path. Ported from
//! `HTTPCameras.swift`.
//!
//! Swift's `HTTPCameraProbe` (discovery of these cameras on their fixed
//! addresses) belongs to `tether-net`; the per-brand `probe(body)` checks and
//! default hosts it uses are here.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde_json::{json, Map, Value};
use tether_types::{
    CameraCapabilities, CameraIdentity, CameraVendor, CaptureDestination, TransportKind,
};

use super::ricoh::{
    json_body, last_path_component, path_extension, HttpRequest, ReqwestRicohHttp, RicohHandleMap,
    RicohHttp,
};
use crate::device::{CameraEvent, NewObject, PropertyDescriptor, TetherProperty, VendorHandler};
use crate::ptp::transport::lock;
use crate::ptp::{
    ObjectFormat, ProgressFn, PtpError, PtpEvent, PtpObjectInfo, PtpResult, PtpValue,
};

/// A camera handler reached over HTTP (no PTP engine). The connection
/// builder asks it who it is before starting a session.
#[async_trait]
pub trait HttpCameraHandler: VendorHandler {
    async fn probe_identity(&self) -> PtpResult<CameraIdentity>;
}

/// One entry of a card listing: the path to fetch and the file name to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListedFile {
    pub path: String,
    pub name: String,
}

/// Shared plumbing: requests, the "new file" diff and path ↔ handle mapping.
pub struct HttpFileCamera {
    pub base_url: String,
    pub http: Arc<dyn RicohHttp>,
    pub handles: RicohHandleMap,
    state: Mutex<FileState>,
}

#[derive(Default)]
struct FileState {
    known: Option<HashSet<String>>,
    names: HashMap<String, String>,
}

impl HttpFileCamera {
    pub fn new(base_url: &str, http: Arc<dyn RicohHttp>) -> Self {
        Self {
            base_url: base_url.to_string(),
            http,
            handles: RicohHandleMap::new(),
            state: Mutex::new(FileState::default()),
        }
    }

    pub fn url(&self, path: &str) -> String {
        if path.starts_with("http://") || path.starts_with("https://") {
            return path.to_string();
        }
        let base = self.base_url.strip_suffix('/').unwrap_or(&self.base_url);
        format!("{base}{path}")
    }

    /// The host of the base URL ("camera" when it has none).
    pub fn host(&self) -> String {
        reqwest::Url::parse(&self.base_url)
            .ok()
            .and_then(|u| u.host_str().map(str::to_string))
            .unwrap_or_else(|| "camera".into())
    }

    pub async fn request(
        &self,
        method: &str,
        path: &str,
        json: Option<Map<String, Value>>,
        timeout: Duration,
    ) -> PtpResult<Vec<u8>> {
        let mut req = HttpRequest::new(method, self.url(path));
        req.timeout = timeout;
        if let Some(body) = json {
            req.headers.push((
                "Content-Type".into(),
                "application/json;charset=utf-8".into(),
            ));
            req.body = Some(json_body(body));
        }
        let (data, status) = self.http.send(req).await?;
        if !(200..300).contains(&status) {
            return Err(PtpError::Unsupported(format!(
                "The camera answered HTTP {status} to {path}."
            )));
        }
        Ok(data)
    }

    /// Diff a full listing against the last one. The first listing only
    /// seeds, so photos already on the card are not imported.
    pub fn announce(&self, listing: &[ListedFile]) -> Vec<CameraEvent> {
        let mut s = lock(&self.state);
        for item in listing {
            s.names.insert(item.path.clone(), item.name.clone());
        }
        let Some(seen) = s.known.clone() else {
            s.known = Some(listing.iter().map(|i| i.path.clone()).collect());
            return Vec::new();
        };
        let mut known = seen.clone();
        known.extend(listing.iter().map(|i| i.path.clone()));
        s.known = Some(known);
        listing
            .iter()
            .filter(|i| !seen.contains(&i.path))
            .map(|i| {
                let name = s
                    .names
                    .get(&i.path)
                    .cloned()
                    .unwrap_or_else(|| last_path_component(&i.path).to_string());
                CameraEvent::ObjectAdded(NewObject {
                    handle: self.handles.handle_for(&i.path),
                    storage_id: 0x0001_0001,
                    info: Some(Self::object_info(&name)),
                    in_sdram: false,
                })
            })
            .collect()
    }

    pub async fn download(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        let Some(path) = self.handles.path_for(object.handle) else {
            return Err(PtpError::Unsupported(format!(
                "Unknown photo {}.",
                object.handle
            )));
        };
        let data = self
            .request("GET", &path, None, Duration::from_secs(120))
            .await?;
        if let Some(p) = &progress {
            p(data.len(), Some(data.len()));
        }
        let name = lock(&self.state)
            .names
            .get(&path)
            .cloned()
            .unwrap_or_else(|| last_path_component(&path).to_string());
        let mut info = Self::object_info(&name);
        info.object_compressed_size = u32::try_from(data.len()).unwrap_or(u32::MAX);
        Ok((info, data))
    }

    pub fn object_info(name: &str) -> PtpObjectInfo {
        let ext = path_extension(name).to_lowercase();
        let format = if ext == "jpg" || ext == "jpeg" {
            ObjectFormat::EXIF_JPEG
        } else {
            ObjectFormat::UNDEFINED
        };
        PtpObjectInfo {
            storage_id: 0x0001_0001,
            object_format: format,
            filename: name.to_string(),
            ..Default::default()
        }
    }

    pub fn json(data: &[u8]) -> Option<Map<String, Value>> {
        match serde_json::from_slice::<Value>(data) {
            Ok(Value::Object(m)) => Some(m),
            _ => None,
        }
    }
}

fn str_field(m: &Map<String, Value>, key: &str) -> Option<String> {
    m.get(key).and_then(Value::as_str).map(str::to_string)
}

// MARK: - GoPro

/// Open GoPro paths.
pub mod gopro_path {
    pub const INFO: &str = "/gopro/camera/info";
    pub const MEDIA_LIST: &str = "/gopro/media/list";
    pub const SHUTTER_START: &str = "/gopro/camera/shutter/start";
    pub const PHOTO_GROUP: &str = "/gopro/camera/presets/set_group?id=1001";
    pub const EXTERNAL_CONTROL: &str = "/gopro/camera/control/set_ui_controller?p=2";
    pub const KEEP_ALIVE: &str = "/gopro/camera/keep_alive";
    pub const MEDIA: &str = "/videos/DCIM/";
}

/// GoPro HERO9 and later through the Open GoPro HTTP API on the camera's
/// access point (http://10.5.5.9:8080). Turn on the camera's Wi-Fi from its
/// Connections menu (or once from GoPro Quik), join it, then connect.
/// Stills (JPEG and GoPro RAW .GPR) arrive as they are taken.
pub struct GoProHandler {
    pub files: HttpFileCamera,
    last_keep_alive: Mutex<Option<Instant>>,
}

impl GoProHandler {
    pub const DEFAULT_HOST: &'static str = "10.5.5.9:8080";
    pub const CAPABILITIES: CameraCapabilities = CameraCapabilities::REMOTE_CAPTURE
        .union(CameraCapabilities::CARD_CAPTURE)
        .union(CameraCapabilities::WIRELESS);

    /// The GoPro on its own access point, over reqwest.
    pub fn new() -> Self {
        Self::with_http(
            &format!("http://{}", Self::DEFAULT_HOST),
            Arc::new(ReqwestRicohHttp::new()),
        )
    }

    pub fn with_http(base_url: &str, http: Arc<dyn RicohHttp>) -> Self {
        Self {
            files: HttpFileCamera::new(base_url, http),
            last_keep_alive: Mutex::new(None),
        }
    }

    /// True when a camera-info body names a model.
    pub fn probe(body: &[u8]) -> bool {
        let Some(root) = HttpFileCamera::json(body) else {
            return false;
        };
        let info = match root.get("info") {
            Some(Value::Object(i)) => i,
            _ => &root,
        };
        info.contains_key("model_name")
    }

    /// `{"media":[{"d":"100GOPRO","fs":[{"n":"GOPR0001.JPG"}]}]}` → still paths.
    pub fn stills(media_list: &[u8]) -> Vec<ListedFile> {
        let Some(root) = HttpFileCamera::json(media_list) else {
            return Vec::new();
        };
        let Some(Value::Array(media)) = root.get("media") else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for dir in media {
            let Some(d) = dir.get("d").and_then(Value::as_str) else {
                continue;
            };
            let Some(Value::Array(fs)) = dir.get("fs") else {
                continue;
            };
            for file in fs {
                let Some(n) = file.get("n").and_then(Value::as_str) else {
                    continue;
                };
                let ext = path_extension(n).to_lowercase();
                if !["jpg", "jpeg", "gpr"].contains(&ext.as_str()) {
                    continue;
                }
                out.push(ListedFile {
                    path: format!("{}{d}/{n}", gopro_path::MEDIA),
                    name: n.to_string(),
                });
            }
        }
        out
    }

    async fn get(&self, path: &str, timeout: Duration) -> PtpResult<Vec<u8>> {
        self.files.request("GET", path, None, timeout).await
    }

    async fn list_stills(&self) -> PtpResult<Vec<ListedFile>> {
        Ok(Self::stills(
            &self
                .get(gopro_path::MEDIA_LIST, Duration::from_secs(30))
                .await?,
        ))
    }
}

impl Default for GoProHandler {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl HttpCameraHandler for GoProHandler {
    async fn probe_identity(&self) -> PtpResult<CameraIdentity> {
        let root =
            HttpFileCamera::json(&self.get(gopro_path::INFO, Duration::from_secs(30)).await?)
                .unwrap_or_default();
        let info = match root.get("info") {
            Some(Value::Object(i)) => i.clone(),
            _ => root,
        };
        let model = str_field(&info, "model_name").unwrap_or_else(|| "GoPro".into());
        let serial = str_field(&info, "serial_number").unwrap_or_default();
        let id = if serial.is_empty() {
            format!("gopro-{}", self.files.host())
        } else {
            format!("gopro-{serial}")
        };
        Ok(CameraIdentity {
            id,
            vendor: CameraVendor::Gopro,
            manufacturer: "GoPro".into(),
            model,
            serial_number: serial,
            firmware: str_field(&info, "firmware_version").unwrap_or_default(),
            transport: TransportKind::Http,
            capabilities: Self::CAPABILITIES,
        })
    }
}

#[async_trait]
impl VendorHandler for GoProHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Gopro
    }

    fn capabilities(&self) -> CameraCapabilities {
        Self::CAPABILITIES
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_secs(1)
    }

    async fn prepare(&self) -> PtpResult<()> {
        // Newer bodies want an external controller claim; older ones ignore it.
        let t = Duration::from_secs(30);
        let _ = self.get(gopro_path::EXTERNAL_CONTROL, t).await;
        let _ = self.get(gopro_path::PHOTO_GROUP, t).await;
        self.files.announce(&self.list_stills().await?);
        Ok(())
    }

    async fn teardown(&self) {}

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "GoPro saves to its card; frames are downloaded from there.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, _autofocus: bool) -> PtpResult<()> {
        self.get(gopro_path::SHUTTER_START, Duration::from_secs(30))
            .await
            .map(|_| ())
    }

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        let due = {
            let mut last = lock(&self.last_keep_alive);
            let due = last.is_none_or(|t| t.elapsed() > Duration::from_secs(3));
            if due {
                *last = Some(Instant::now());
            }
            due
        };
        if due {
            let _ = self
                .get(gopro_path::KEEP_ALIVE, Duration::from_secs(3))
                .await;
        }
        Ok(self.files.announce(&self.list_stills().await?))
    }

    async fn translate(&self, _event: &PtpEvent) -> Option<CameraEvent> {
        None
    }

    async fn read_properties(
        &self,
        _properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        Ok(Vec::new())
    }

    async fn write_property(&self, _property: TetherProperty, _raw: PtpValue) -> PtpResult<()> {
        Err(PtpError::Unsupported(
            "Change settings on the GoPro itself.".into(),
        ))
    }

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        self.files.download(object, progress).await
    }
}

// MARK: - Open Spherical Camera (Ricoh Theta, Insta360…)

/// Google's Open Spherical Camera API (level 2): `/osc/info`,
/// `camera.takePicture`, `camera.listFiles`, files by `fileUrl`. Ricoh Theta
/// answers at http://192.168.1.1 on its own access point; Insta360 bodies
/// that implement OSC usually at http://192.168.42.1.
pub struct OscHandler {
    pub files: HttpFileCamera,
}

impl OscHandler {
    pub const DEFAULT_HOSTS: [&'static str; 2] = ["192.168.1.1", "192.168.42.1"];
    pub const CAPABILITIES: CameraCapabilities = CameraCapabilities::REMOTE_CAPTURE
        .union(CameraCapabilities::CARD_CAPTURE)
        .union(CameraCapabilities::WIRELESS);

    /// A Theta on its own access point (http://192.168.1.1), over reqwest.
    pub fn new() -> Self {
        Self::with_http("http://192.168.1.1", Arc::new(ReqwestRicohHttp::new()))
    }

    pub fn with_http(base_url: &str, http: Arc<dyn RicohHttp>) -> Self {
        Self {
            files: HttpFileCamera::new(base_url, http),
        }
    }

    /// True when `/osc/info` names a model.
    pub fn probe(body: &[u8]) -> bool {
        HttpFileCamera::json(body).is_some_and(|m| m.contains_key("model"))
    }

    pub async fn execute(&self, name: &str, parameters: Value) -> PtpResult<Map<String, Value>> {
        let mut body = Map::new();
        body.insert("name".into(), Value::String(name.into()));
        if parameters.as_object().is_some_and(|p| !p.is_empty()) {
            body.insert("parameters".into(), parameters);
        }
        let root = HttpFileCamera::json(
            &self
                .files
                .request(
                    "POST",
                    "/osc/commands/execute",
                    Some(body),
                    Duration::from_secs(30),
                )
                .await?,
        )
        .unwrap_or_default();
        if let Some(Value::Object(error)) = root.get("error") {
            let detail = match error.get("message").and_then(Value::as_str) {
                Some(m) => m.to_string(),
                None => error
                    .get("code")
                    .map(|c| c.as_str().map_or_else(|| c.to_string(), str::to_string))
                    .unwrap_or_else(|| "error".into()),
            };
            return Err(PtpError::Unsupported(format!(
                "The camera refused {name}: {detail}"
            )));
        }
        Ok(root)
    }

    /// `{"results":{"entries":[{"name":"R0010001.JPG","fileUrl":"http://…"}]}}`.
    pub fn images(list_files: &Map<String, Value>) -> Vec<ListedFile> {
        let Some(entries) = list_files
            .get("results")
            .and_then(|r| r.get("entries"))
            .and_then(Value::as_array)
        else {
            return Vec::new();
        };
        entries
            .iter()
            .filter_map(|e| {
                let url = e.get("fileUrl")?.as_str()?;
                let name = e
                    .get("name")
                    .and_then(Value::as_str)
                    .map_or_else(|| last_path_component(url).to_string(), str::to_string);
                Some(ListedFile {
                    path: url.to_string(),
                    name,
                })
            })
            .collect()
    }

    async fn list_images(&self) -> PtpResult<Vec<ListedFile>> {
        let root = self
            .execute(
                "camera.listFiles",
                json!({"fileType": "image", "entryCount": 100, "maxThumbSize": 0}),
            )
            .await?;
        Ok(Self::images(&root))
    }
}

impl Default for OscHandler {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl HttpCameraHandler for OscHandler {
    async fn probe_identity(&self) -> PtpResult<CameraIdentity> {
        let info = HttpFileCamera::json(
            &self
                .files
                .request("GET", "/osc/info", None, Duration::from_secs(30))
                .await?,
        )
        .unwrap_or_default();
        let serial = str_field(&info, "serialNumber").unwrap_or_default();
        let id = if serial.is_empty() {
            format!("osc-{}", self.files.host())
        } else {
            format!("osc-{serial}")
        };
        Ok(CameraIdentity {
            id,
            vendor: CameraVendor::Osc,
            manufacturer: str_field(&info, "manufacturer").unwrap_or_default(),
            model: str_field(&info, "model").unwrap_or_else(|| "360° camera".into()),
            serial_number: serial,
            firmware: str_field(&info, "firmwareVersion").unwrap_or_default(),
            transport: TransportKind::Http,
            capabilities: Self::CAPABILITIES,
        })
    }
}

#[async_trait]
impl VendorHandler for OscHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Osc
    }

    fn capabilities(&self) -> CameraCapabilities {
        Self::CAPABILITIES
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_secs(1)
    }

    async fn prepare(&self) -> PtpResult<()> {
        // Level-1 Thetas need to be switched to API level 2 first; later ones ignore it.
        let _ = self
            .execute(
                "camera.setOptions",
                json!({"options": {"clientVersion": 2}}),
            )
            .await;
        let _ = self
            .execute(
                "camera.setOptions",
                json!({"options": {"captureMode": "image"}}),
            )
            .await;
        self.files.announce(&self.list_images().await?);
        Ok(())
    }

    async fn teardown(&self) {}

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "360° cameras save to their storage; frames are downloaded from there.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, _autofocus: bool) -> PtpResult<()> {
        self.execute("camera.takePicture", json!({}))
            .await
            .map(|_| ())
    }

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        Ok(self.files.announce(&self.list_images().await?))
    }

    async fn translate(&self, _event: &PtpEvent) -> Option<CameraEvent> {
        None
    }

    async fn read_properties(
        &self,
        _properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        Ok(Vec::new())
    }

    async fn write_property(&self, _property: TetherProperty, _raw: PtpValue) -> PtpResult<()> {
        Err(PtpError::Unsupported(
            "Change settings on the camera itself.".into(),
        ))
    }

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        self.files.download(object, progress).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gopro_media_list_skips_video() {
        let body =
            br#"{"media":[{"d":"100GOPRO","fs":[{"n":"A.JPG"},{"n":"B.MP4"},{"n":"C.GPR"}]}]}"#;
        let names: Vec<String> = GoProHandler::stills(body)
            .into_iter()
            .map(|f| f.name)
            .collect();
        assert_eq!(names, ["A.JPG", "C.GPR"]);
        assert_eq!(
            GoProHandler::stills(body)[0].path,
            "/videos/DCIM/100GOPRO/A.JPG"
        );
        assert!(GoProHandler::probe(br#"{"info":{"model_name":"HERO12"}}"#));
        assert!(GoProHandler::probe(br#"{"model_name":"HERO9"}"#));
        assert!(!GoProHandler::probe(b"nope"));
        assert!(OscHandler::probe(br#"{"model":"RICOH THETA X"}"#));
    }

    #[test]
    fn osc_entries_fall_back_to_url_name() {
        let root = HttpFileCamera::json(
            br#"{"results":{"entries":[{"fileUrl":"http://h/files/100RICOH/R1.JPG"},{"name":"x"}]}}"#,
        )
        .unwrap();
        let files = OscHandler::images(&root);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].name, "R1.JPG");
    }
}
