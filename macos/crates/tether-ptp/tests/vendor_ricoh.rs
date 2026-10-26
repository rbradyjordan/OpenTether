//! Port of `RicohVendorTests.swift` and `HTTPCameraTests.swift` against
//! fake HTTP seams (the reqwest implementation is exercised against a
//! local server in `vendor_http_server.rs`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};
use tether_ptp::device::{CameraEvent, NewObject, TetherProperty, VendorHandler};
use tether_ptp::ptp::{MediaKind, ObjectFormat, PtpError, PtpResult, PtpValue};
use tether_ptp::testing::fake_jpeg;
use tether_ptp::vendors::http_cameras::{GoProHandler, OscHandler};
use tether_ptp::vendors::ricoh::{
    ChunkFn, EndFn, HttpRequest, MjpegFrameSplitter, RicohChangeMessage, RicohHandleMap,
    RicohHandler, RicohHttp, RicohProps, RicohStreamHandle, RicohWebSocket,
};
use tether_ptp::HttpCameraHandler;
use tether_types::{CameraCapabilities as C, CameraVendor, LiveViewQuality, TransportKind};

// MARK: Fakes

/// Canned HTTP for the Ricoh handler. Keyed by "METHOD path" (query kept).
#[derive(Default)]
struct FakeRicohHttp {
    responses: Mutex<HashMap<String, (Vec<u8>, u16)>>,
    requests: Mutex<Vec<HttpRequest>>,
    socket_messages: Mutex<Option<Vec<String>>>,
    stream_chunk: Mutex<Option<ChunkFn>>,
    stream_cancelled: Arc<AtomicBool>,
}

impl FakeRicohHttp {
    fn respond_json(&self, method: &str, path: &str, json: Value) {
        self.respond(method, path, 200, serde_json::to_vec(&json).unwrap());
    }

    fn respond(&self, method: &str, path: &str, status: u16, body: Vec<u8>) {
        self.responses
            .lock()
            .unwrap()
            .insert(format!("{method} {path}"), (body, status));
    }

    fn key(r: &HttpRequest) -> String {
        format!("{} {}", r.method, r.path_and_query())
    }

    fn keys(&self) -> Vec<String> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(Self::key)
            .collect()
    }

    fn requests_for(&self, key: &str) -> Vec<HttpRequest> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| Self::key(r) == key)
            .cloned()
            .collect()
    }
}

struct Handle(Arc<AtomicBool>);

impl RicohStreamHandle for Handle {
    fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

struct Socket(Mutex<Vec<String>>);

#[async_trait]
impl RicohWebSocket for Socket {
    async fn receive_text(&self) -> PtpResult<String> {
        let mut m = self.0.lock().unwrap();
        if m.is_empty() {
            return Err(PtpError::TransportClosed);
        }
        Ok(m.remove(0))
    }
    fn cancel(&self) {}
}

#[async_trait]
impl RicohHttp for FakeRicohHttp {
    async fn send(&self, request: HttpRequest) -> PtpResult<(Vec<u8>, u16)> {
        let key = Self::key(&request);
        self.requests.lock().unwrap().push(request);
        Ok(self
            .responses
            .lock()
            .unwrap()
            .get(&key)
            .cloned()
            .unwrap_or((Vec::new(), 404)))
    }

    fn stream(
        &self,
        request: HttpRequest,
        on_chunk: ChunkFn,
        _on_end: EndFn,
    ) -> Box<dyn RicohStreamHandle> {
        self.requests.lock().unwrap().push(request);
        *self.stream_chunk.lock().unwrap() = Some(on_chunk);
        Box::new(Handle(self.stream_cancelled.clone()))
    }

    fn web_socket(&self, url: &str) -> Option<Arc<dyn RicohWebSocket>> {
        let msgs = self.socket_messages.lock().unwrap().clone()?;
        self.requests
            .lock()
            .unwrap()
            .push(HttpRequest::new("GET", url));
        Some(Arc::new(Socket(Mutex::new(msgs))))
    }
}

type Answer = Box<dyn Fn(&HttpRequest) -> (Vec<u8>, u16) + Send + Sync>;

/// HTTP fake that answers from a closure, so one endpoint can reply by body.
struct ScriptedHttp {
    log: Mutex<Vec<String>>,
    handler: Answer,
}

impl ScriptedHttp {
    fn new(f: impl Fn(&HttpRequest) -> (Vec<u8>, u16) + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            log: Mutex::new(Vec::new()),
            handler: Box::new(f),
        })
    }
    fn log(&self) -> Vec<String> {
        self.log.lock().unwrap().clone()
    }
}

fn json_ok(v: Value) -> (Vec<u8>, u16) {
    (serde_json::to_vec(&v).unwrap(), 200)
}

#[async_trait]
impl RicohHttp for ScriptedHttp {
    async fn send(&self, request: HttpRequest) -> PtpResult<(Vec<u8>, u16)> {
        self.log.lock().unwrap().push(format!(
            "{} {} {}",
            request.method,
            request.url,
            request.body_text()
        ));
        Ok((self.handler)(&request))
    }
    fn stream(&self, _r: HttpRequest, _c: ChunkFn, _e: EndFn) -> Box<dyn RicohStreamHandle> {
        Box::new(Handle(Arc::new(AtomicBool::new(false))))
    }
    fn web_socket(&self, _url: &str) -> Option<Arc<dyn RicohWebSocket>> {
        None
    }
}

// MARK: Ricoh

fn props() -> Value {
    json!({
        "errCode": 200, "errMsg": "OK", "model": "RICOH GR III", "firmwareVersion": "1.41", "serialNo": "GR3-0001",
        "battery": {"level": 72}, "av": "2.8", "tv": "1/250", "sv": "200", "xv": "-0.3", "WBMode": "auto",
        "avList": ["2.8", "4.0", "5.6"], "tvList": ["1/125", "1/250", "1/500"], "svList": ["auto", "100", "200"],
        "xvList": ["-0.3", "0.0", "0.3"], "WBModeList": ["auto", "daylight", "shade"],
    })
}

fn make_handler(socket: Option<Vec<&str>>) -> (RicohHandler, Arc<FakeRicohHttp>) {
    let http = Arc::new(FakeRicohHttp::default());
    *http.socket_messages.lock().unwrap() =
        socket.map(|s| s.into_iter().map(str::to_string).collect());
    http.respond_json("GET", "/v1/props", props());
    http.respond_json(
        "GET",
        "/v1/photos",
        json!({"dirs": [{"name": "100RICOH", "files": ["R0000001.JPG", "R0000001.DNG"]}]}),
    );
    http.respond_json(
        "POST",
        "/v1/camera/shoot",
        json!({"errCode": 200, "errMsg": "OK"}),
    );
    http.respond_json(
        "PUT",
        "/v1/params/camera",
        json!({"errCode": 200, "errMsg": "OK"}),
    );
    let h = RicohHandler::with_http("http://192.168.0.1", http.clone());
    (h, http)
}

fn object(e: &CameraEvent) -> &NewObject {
    match e {
        CameraEvent::ObjectAdded(o) => o,
        other => panic!("expected ObjectAdded, got {other:?}"),
    }
}

#[tokio::test]
async fn props_map_to_identity() {
    let (h, _) = make_handler(None);
    let id = h.probe_identity().await.unwrap();
    assert_eq!(id.vendor, CameraVendor::Ricoh);
    assert_eq!(id.transport, TransportKind::RicohHttp);
    assert_eq!(id.model, "RICOH GR III");
    assert_eq!(id.firmware, "1.41");
    assert_eq!(id.serial_number, "GR3-0001");
    assert_eq!(id.id, "ricoh-GR3-0001");
    assert!(id.capabilities.contains(C::REMOTE_CAPTURE));
    assert!(id.capabilities.contains(C::LIVE_VIEW));
    assert!(!id.capabilities.contains(C::SDRAM_CAPTURE));
    let flat = RicohProps::parse(br#"{"model":"RICOH GR II","battery":55}"#).unwrap();
    assert_eq!(flat.battery_percent, Some(55));
    let s = RicohProps::parse(br#"{"model":"GR","battery":"40","serialNumber":7}"#).unwrap();
    assert_eq!(s.battery_percent, Some(40));
    assert_eq!(s.serial, "7");
    assert!(RicohProps::parse(b"[]").is_err());
    // No serial: the id falls back to the host.
    let http = Arc::new(FakeRicohHttp::default());
    http.respond_json("GET", "/v1/props", json!({"model": "RICOH GR III"}));
    let anon = RicohHandler::with_http("http://192.168.0.1/", http);
    assert_eq!(anon.probe_identity().await.unwrap().id, "ricoh-192.168.0.1");
}

#[tokio::test]
async fn shoot_posts_af_flag() {
    let (h, http) = make_handler(None);
    h.capture(true).await.unwrap();
    h.capture(false).await.unwrap();
    let shoots = http.requests_for("POST /v1/camera/shoot");
    assert_eq!(shoots.len(), 2);
    assert_eq!(shoots[0].body_text(), "{\"af\":true}");
    assert_eq!(shoots[1].body_text(), "{\"af\":false}");
    assert_eq!(shoots[0].header("Content-Type"), Some("application/json"));
    assert_eq!(RicohHandler::shoot_body(true), b"{\"af\":true}");
    http.respond_json(
        "POST",
        "/v1/camera/shoot",
        json!({"errCode": 500, "errMsg": "busy"}),
    );
    let e = h.capture(true).await.unwrap_err();
    assert!(e.to_string().contains("busy"));
    http.respond("POST", "/v1/camera/shoot", 503, vec![]);
    assert!(h
        .capture(true)
        .await
        .unwrap_err()
        .to_string()
        .contains("503"));
}

#[test]
fn mjpeg_splitter_with_content_length_across_chunks() {
    let (j1, j2) = (fake_jpeg(300), fake_jpeg(120));
    let mut body = Vec::new();
    for j in [&j1, &j2] {
        body.extend(
            format!(
                "--boundarydonotcross\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
                j.len()
            )
            .bytes(),
        );
        body.extend(j.iter());
        body.extend(b"\r\n");
    }
    let mut s = MjpegFrameSplitter::default();
    let mut frames = Vec::new();
    for chunk in body.chunks(37) {
        frames.extend(s.feed(chunk));
    }
    assert_eq!(frames, vec![j1, j2]);
    assert_eq!(s.frames_emitted(), 2);
}

#[test]
fn mjpeg_splitter_without_content_length_uses_next_boundary() {
    let (j1, j2) = (fake_jpeg(64), fake_jpeg(80));
    let mut body = b"--frame\r\nContent-Type: image/jpeg\r\n\r\n".to_vec();
    body.extend(&j1);
    body.extend(b"\r\n--frame\r\nContent-Type: image/jpeg\r\n\r\n");
    body.extend(&j2);
    let mut s = MjpegFrameSplitter::default();
    assert_eq!(s.feed(&body), vec![j1]); // j2 waits for its closing boundary
    assert_eq!(s.feed(b"\r\n--frame\r\n"), vec![j2]);
}

#[tokio::test]
async fn live_view_frames_flow_through_handler() {
    let (h, http) = make_handler(None);
    h.start_live_view(LiveViewQuality::Medium).await.unwrap();
    assert_eq!(http.keys().last().unwrap(), "GET /v1/liveview");
    let j = fake_jpeg(90);
    let mut body = format!("--b\r\nContent-Length: {}\r\n\r\n", j.len()).into_bytes();
    body.extend(&j);
    body.extend(b"\r\n");
    let chunk = http.stream_chunk.lock().unwrap().clone().unwrap();
    chunk(body);
    let frame = h.next_live_view_frame().await.unwrap().unwrap();
    assert_eq!(frame.jpeg, j);
    assert_eq!(frame.sequence, 1);
    assert!(h.next_live_view_frame().await.unwrap().is_none());
    h.stop_live_view().await;
    assert!(http.stream_cancelled.load(Ordering::SeqCst));
}

#[tokio::test]
async fn change_messages_become_object_added_with_stable_handles() {
    let (h, _) = make_handler(None);
    h.prepare().await.unwrap(); // seeds R0000001.JPG / .DNG as known; no socket → polling task
    h.teardown().await;
    assert!(h.poll_events().await.unwrap().is_empty());
    h.handle_change(
        r#"{"changed":["storage"],"storage":{"latestPhoto":"100RICOH/R0000002.JPG","available":true}}"#,
    );
    h.handle_change(r#"{"changed":["camera"],"camera":{"av":"4.0"}}"#);
    h.handle_change(
        r#"{"changed":["storage"],"storage":{"photos":["/100RICOH/R0000002.JPG","100RICOH/R0000002.DNG"]}}"#,
    ); // first one repeats
    let events = h.poll_events().await.unwrap();
    assert_eq!(events.len(), 3);
    let a = object(&events[0]);
    assert_eq!(a.info.as_ref().unwrap().filename, "R0000002.JPG");
    assert_eq!(a.handle, h.handles().handle_for("100RICOH/R0000002.JPG"));
    assert_eq!(a.handle, RicohHandleMap::hash("100RICOH/R0000002.JPG"));
    assert_eq!(events[1], CameraEvent::PropertyChanged(None));
    let b = object(&events[2]);
    assert_eq!(b.info.as_ref().unwrap().filename, "R0000002.DNG");
    assert_eq!(b.info.as_ref().unwrap().object_format, ObjectFormat::DNG);
    assert_ne!(a.handle, b.handle);
    assert_eq!(
        h.handles().path_for(b.handle).as_deref(),
        Some("100RICOH/R0000002.DNG")
    );
    assert!(h.poll_events().await.unwrap().is_empty());
    // Storage change without paths.
    h.handle_change(r#"{"changed":["storage"]}"#);
    assert_eq!(
        h.poll_events().await.unwrap(),
        vec![CameraEvent::StorageChanged]
    );
}

#[tokio::test]
async fn web_socket_messages_are_consumed() {
    let (h, http) = make_handler(Some(vec![
        r#"{"changed":["storage"],"storage":{"latestPhoto":"100RICOH/R0000009.JPG"}}"#,
    ]));
    h.prepare().await.unwrap();
    assert!(http.keys().iter().any(|k| k.ends_with("/v1/changes")));
    let mut events = Vec::new();
    for _ in 0..50 {
        events = h.poll_events().await.unwrap();
        if !events.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    h.teardown().await;
    assert_eq!(events.len(), 1);
    assert_eq!(
        object(&events[0]).info.as_ref().unwrap().filename,
        "R0000009.JPG"
    );
}

#[tokio::test]
async fn dropped_socket_falls_back_to_polling() {
    let (h, http) = make_handler(Some(vec![]));
    h.set_photo_poll_interval(Duration::from_millis(20));
    h.prepare().await.unwrap();
    http.respond_json(
        "GET",
        "/v1/photos",
        json!({"dirs": [{"name": "100RICOH", "files": ["R0000001.JPG", "R0000001.DNG", "R0000004.JPG"]}]}),
    );
    let mut events = Vec::new();
    for _ in 0..100 {
        events = h.poll_events().await.unwrap();
        if !events.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    h.teardown().await;
    assert_eq!(
        object(&events[0]).info.as_ref().unwrap().filename,
        "R0000004.JPG"
    );
}

#[tokio::test]
async fn photo_polling_fallback_diffs_listing() {
    let (h, http) = make_handler(None);
    h.prepare().await.unwrap();
    h.teardown().await;
    http.respond_json(
        "GET",
        "/v1/photos",
        json!({"dirs": [{"name": "100RICOH", "files": ["R0000001.JPG", "R0000001.DNG", "R0000003.JPG"]}]}),
    );
    h.poll_photos_once().await;
    let events = h.poll_events().await.unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(
        object(&events[0]).info.as_ref().unwrap().filename,
        "R0000003.JPG"
    );
}

#[tokio::test]
async fn fetch_object_uses_view_proxy_for_dng_and_full_for_jpeg() {
    let (h, http) = make_handler(None);
    let (jpeg, proxy, dng) = (fake_jpeg(200), fake_jpeg(100), vec![0x49u8; 400]);
    http.respond("GET", "/v1/photos/100RICOH/R0000005.JPG", 200, jpeg.clone());
    http.respond(
        "GET",
        "/v1/photos/100RICOH/R0000005.DNG?size=view",
        200,
        proxy.clone(),
    );
    http.respond("GET", "/v1/photos/100RICOH/R0000005.DNG", 200, dng.clone());
    let jh = h.handles().handle_for("100RICOH/R0000005.JPG");
    let (ji, jd) = h.fetch_object(&NewObject::new(jh), None).await.unwrap();
    assert_eq!(jd, jpeg);
    assert_eq!(ji.filename, "R0000005.JPG");
    assert_eq!(ji.object_compressed_size, 200);
    let dh = h.handles().handle_for("100RICOH/R0000005.DNG");
    let (di, dd) = h.fetch_object(&NewObject::new(dh), None).await.unwrap();
    assert_eq!(dd, proxy);
    assert_eq!(di.filename, "R0000005.JPG");
    assert_eq!(di.object_format, ObjectFormat::EXIF_JPEG);
    h.set_prefer_view_proxy_for_raw(false);
    let (oi, od) = h.fetch_object(&NewObject::new(dh), None).await.unwrap();
    assert_eq!(od, dng);
    assert_eq!(oi.filename, "R0000005.DNG");
    assert_eq!(oi.media_kind(), MediaKind::Raw);
    assert_eq!(
        h.fetch_original("100RICOH/R0000005.DNG").await.unwrap(),
        dng
    );
    assert!(h.fetch_object(&NewObject::new(0xDEAD), None).await.is_err());
}

#[tokio::test]
async fn properties_read_display_and_write() {
    let (h, http) = make_handler(None);
    let props = h
        .read_properties(&[
            TetherProperty::Aperture,
            TetherProperty::ShutterSpeed,
            TetherProperty::Iso,
            TetherProperty::ExposureCompensation,
            TetherProperty::WhiteBalance,
            TetherProperty::BatteryLevel,
            TetherProperty::CaptureDestination,
        ])
        .await
        .unwrap();
    let by = |p: TetherProperty| props.iter().find(|d| d.property == p).unwrap().clone();
    assert_eq!(by(TetherProperty::Aperture).display, "ƒ/2.8");
    let apertures: Vec<String> = by(TetherProperty::Aperture)
        .choices()
        .iter()
        .map(|c| c.display.clone())
        .collect();
    assert_eq!(apertures, ["ƒ/2.8", "ƒ/4", "ƒ/5.6"]);
    assert_eq!(by(TetherProperty::ShutterSpeed).display, "1/250");
    assert_eq!(by(TetherProperty::Iso).display, "200");
    assert_eq!(by(TetherProperty::Iso).choices()[0].display, "Auto");
    assert_eq!(by(TetherProperty::ExposureCompensation).display, "-0.3");
    assert_eq!(by(TetherProperty::WhiteBalance).display, "Auto");
    assert_eq!(by(TetherProperty::BatteryLevel).display, "72%");
    assert!(!by(TetherProperty::CaptureDestination).is_writable);
    h.write_property(
        TetherProperty::Aperture,
        by(TetherProperty::Aperture).choices()[1].raw.clone(),
    )
    .await
    .unwrap();
    assert_eq!(
        http.requests_for("PUT /v1/params/camera")[0].body_text(),
        "{\"av\":\"4.0\"}"
    );
    h.write_property(TetherProperty::Iso, PtpValue::UInt16(400))
        .await
        .unwrap();
    assert_eq!(
        http.requests_for("PUT /v1/params/camera")[1].body_text(),
        "{\"sv\":\"400\"}"
    );
    assert!(h
        .write_property(TetherProperty::BatteryLevel, PtpValue::UInt8(1))
        .await
        .is_err());
}

#[tokio::test]
async fn probe_requires_model_in_json() {
    let http = Arc::new(FakeRicohHttp::default());
    http.respond_json("GET", "/v1/props", json!({"model": "RICOH GR III"}));
    assert!(RicohHandler::probe("192.168.0.1", Duration::from_secs(1), Some(http.clone())).await);
    assert_eq!(http.keys(), vec!["GET /v1/props"]);
    assert_eq!(
        http.requests.lock().unwrap()[0].url,
        "http://192.168.0.1/v1/props"
    );
    let other = Arc::new(FakeRicohHttp::default());
    other.respond_json("GET", "/v1/props", json!({"hello": "world"}));
    assert!(!RicohHandler::probe("http://10.0.0.5", Duration::from_secs(1), Some(other)).await);
    let missing = Arc::new(FakeRicohHttp::default());
    assert!(!RicohHandler::probe("10.0.0.6", Duration::from_secs(1), Some(missing)).await);
}

#[test]
fn handle_map_is_stable_and_resolves_collisions() {
    let m = RicohHandleMap::new();
    let a = m.handle_for("100RICOH/R0000001.JPG");
    assert_eq!(a, m.handle_for("100RICOH/R0000001.JPG"));
    assert_ne!(a, 0);
    assert_eq!(m.path_for(a).as_deref(), Some("100RICOH/R0000001.JPG"));
    assert_eq!(m.path_for(a.wrapping_add(7)), None);
    assert_eq!(RicohChangeMessage::parse("not json"), None);
    let s = RicohChangeMessage::parse(r#"{"changed":["storage"]}"#).unwrap();
    assert!(s.storage_changed);
    assert!(s.photo_paths.is_empty());
    // Paths that are URLs or have no directory are not photos.
    assert!(!RicohChangeMessage::is_photo_path(
        "http://x/100RICOH/A.JPG"
    ));
    assert!(!RicohChangeMessage::is_photo_path("A.JPG"));
    assert!(RicohChangeMessage::is_photo_path("100RICOH/A.mov"));
}

// MARK: GoPro / OSC (HTTPCameraTests.swift)

#[tokio::test]
async fn gopro_lists_stills_captures_and_downloads() {
    let files = Arc::new(Mutex::new(vec![
        "GOPR0001.JPG".to_string(),
        "GX010002.MP4".to_string(),
    ]));
    let f2 = files.clone();
    let http = ScriptedHttp::new(move |req| match req.path().as_str() {
        "/gopro/camera/info" => json_ok(
            json!({"info": {"model_name": "HERO12 Black", "serial_number": "C350", "firmware_version": "H23.01"}}),
        ),
        "/gopro/media/list" => {
            let fs: Vec<Value> = f2.lock().unwrap().iter().map(|n| json!({"n": n})).collect();
            json_ok(json!({"media": [{"d": "100GOPRO", "fs": fs}]}))
        }
        "/videos/DCIM/100GOPRO/GOPR0003.GPR" => (vec![1, 2, 3], 200),
        _ => (b"{}".to_vec(), 200),
    });
    let gopro = GoProHandler::with_http("http://10.5.5.9:8080", http.clone());
    let id = gopro.probe_identity().await.unwrap();
    assert_eq!(id.model, "HERO12 Black");
    assert_eq!(id.vendor, CameraVendor::Gopro);
    assert_eq!(id.transport, TransportKind::Http);
    assert_eq!(id.id, "gopro-C350");
    gopro.prepare().await.unwrap();
    assert!(
        http.log()
            .iter()
            .any(|l| l.contains("presets/set_group?id=1001")),
        "switched to photo mode"
    );
    gopro.capture(true).await.unwrap();
    assert!(http
        .log()
        .iter()
        .any(|l| l.contains("/gopro/camera/shutter/start")));
    let first = gopro.poll_events().await.unwrap();
    assert!(
        !first
            .iter()
            .any(|e| matches!(e, CameraEvent::ObjectAdded(_))),
        "card contents at connect are not imported"
    );
    assert!(http.log().iter().any(|l| l.contains("keep_alive")));
    files.lock().unwrap().push("GOPR0003.GPR".into());
    let events = gopro.poll_events().await.unwrap();
    let obj = events
        .iter()
        .find_map(|e| match e {
            CameraEvent::ObjectAdded(o) => Some(o.clone()),
            _ => None,
        })
        .expect("new still announced");
    assert_eq!(obj.info.as_ref().unwrap().filename, "GOPR0003.GPR");
    let (info, data) = gopro.fetch_object(&obj, None).await.unwrap();
    assert_eq!(data, vec![1, 2, 3]);
    assert_eq!(info.media_kind(), MediaKind::Raw, "GoPro RAW is RAW");
    assert_eq!(info.object_compressed_size, 3);
    assert!(gopro
        .write_property(TetherProperty::Iso, PtpValue::UInt8(1))
        .await
        .is_err());
    assert!(gopro
        .read_properties(&[TetherProperty::Iso])
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn osc_camera_takes_and_imports_by_file_url() {
    let entries = Arc::new(Mutex::new(vec![json!({
        "name": "R0010001.JPG", "fileUrl": "http://192.168.1.1/files/100RICOH/R0010001.JPG"
    })]));
    let e2 = entries.clone();
    let http = ScriptedHttp::new(move |req| {
        let path = req.path();
        if path == "/osc/info" {
            return json_ok(
                json!({"manufacturer": "RICOH", "model": "RICOH THETA Z1", "serialNumber": "10010", "firmwareVersion": "3.0"}),
            );
        }
        if path == "/files/100RICOH/R0010002.JPG" {
            return (vec![9], 200);
        }
        let body: Value = req
            .body
            .as_deref()
            .and_then(|b| serde_json::from_slice(b).ok())
            .unwrap_or(json!({}));
        match body["name"].as_str() {
            Some("camera.listFiles") => {
                let list = e2.lock().unwrap().clone();
                json_ok(
                    json!({"name": "camera.listFiles", "state": "done", "results": {"entries": list, "totalEntries": list.len()}}),
                )
            }
            Some("camera.takePicture") => {
                json_ok(json!({"name": "camera.takePicture", "state": "inProgress", "id": "1"}))
            }
            _ => json_ok(json!({"state": "done"})),
        }
    });
    let theta = OscHandler::with_http("http://192.168.1.1", http.clone());
    let id = theta.probe_identity().await.unwrap();
    assert_eq!(id.model, "RICOH THETA Z1");
    assert_eq!(id.manufacturer, "RICOH");
    assert_eq!(id.id, "osc-10010");
    theta.prepare().await.unwrap();
    assert!(
        http.log().iter().any(|l| l.contains("\"clientVersion\":2")),
        "switched to API level 2"
    );
    theta.capture(false).await.unwrap();
    let take = http
        .log()
        .into_iter()
        .find(|l| l.contains("camera.takePicture"))
        .unwrap();
    assert!(!take.contains("parameters"), "no empty parameters object");
    entries.lock().unwrap().push(json!({
        "name": "R0010002.JPG", "fileUrl": "http://192.168.1.1/files/100RICOH/R0010002.JPG"
    }));
    let events = theta.poll_events().await.unwrap();
    let obj = object(&events[0]).clone();
    assert_eq!(obj.info.as_ref().unwrap().filename, "R0010002.JPG");
    let (_, data) = theta.fetch_object(&obj, None).await.unwrap();
    assert_eq!(data, vec![9]);
}

#[tokio::test]
async fn osc_errors_surface() {
    let http = ScriptedHttp::new(|_| {
        json_ok(json!({"error": {"code": "disabledCommand", "message": "Busy"}}))
    });
    let e = OscHandler::with_http("http://192.168.1.1", http)
        .capture(false)
        .await
        .unwrap_err();
    assert!(e.to_string().contains("Busy"));
    let http = ScriptedHttp::new(|_| json_ok(json!({"error": {"code": "disabledCommand"}})));
    let e = OscHandler::with_http("http://192.168.1.1", http)
        .capture(false)
        .await
        .unwrap_err();
    assert!(e.to_string().contains("disabledCommand"));
}

#[tokio::test]
async fn http_cameras_are_card_only() {
    let http = ScriptedHttp::new(|_| (vec![], 200));
    let g = GoProHandler::with_http("http://10.5.5.9:8080", http.clone());
    let o = OscHandler::with_http("http://192.168.1.1", http);
    for d in [
        tether_types::CaptureDestination::Host,
        tether_types::CaptureDestination::Both,
    ] {
        assert!(g.set_capture_destination(d).await.is_err());
        assert!(o.set_capture_destination(d).await.is_err());
    }
    assert_eq!(g.capabilities(), GoProHandler::CAPABILITIES);
    assert!(o.capabilities().contains(C::WIRELESS));
    // A serial-less GoPro is named by its host.
    assert_eq!(g.probe_identity().await.unwrap().id, "gopro-10.5.5.9");
}
