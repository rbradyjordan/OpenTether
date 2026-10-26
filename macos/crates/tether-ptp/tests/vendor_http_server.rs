//! The HTTP cameras over the real reqwest + tokio-tungstenite client
//! (`ReqwestRicohHttp`) against a local HTTP/WebSocket server: GoPro, OSC
//! and Ricoh GR flows end to end, live-view streaming, the `/v1/changes`
//! socket and transport errors.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::SinkExt;
use serde_json::{json, Value};
use tether_ptp::device::{CameraEvent, NewObject, VendorHandler};
use tether_ptp::ptp::{MediaKind, PtpError};
use tether_ptp::testing::fake_jpeg;
use tether_ptp::vendors::http_cameras::{GoProHandler, OscHandler};
use tether_ptp::vendors::ricoh::{HttpRequest, ReqwestRicohHttp, RicohHandler, RicohHttp};
use tether_ptp::HttpCameraHandler;
use tether_types::LiveViewQuality;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;

/// A request as the server saw it.
#[derive(Debug, Clone)]
struct Seen {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Seen {
    fn path(&self) -> &str {
        self.target.split('?').next().unwrap_or("")
    }
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }
}

enum Reply {
    Full(u16, Vec<u8>),
    /// A multipart stream: these chunks, then the connection stays open.
    Stream(Vec<Vec<u8>>),
    /// Upgrade to a WebSocket and send these text messages, then close.
    Socket(Vec<String>),
}

type Route = Arc<dyn Fn(&Seen) -> Reply + Send + Sync>;

struct Server {
    addr: SocketAddr,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl Server {
    async fn start(route: impl Fn(&Seen) -> Reply + Send + Sync + 'static) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let route: Route = Arc::new(route);
        let s2 = seen.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let (route, seen) = (route.clone(), s2.clone());
                tokio::spawn(async move {
                    let _ = serve(stream, route, seen).await;
                });
            }
        });
        Server { addr, seen }
    }

    fn base(&self) -> String {
        format!("http://{}", self.addr)
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    fn targets(&self) -> Vec<String> {
        self.seen()
            .into_iter()
            .map(|s| format!("{} {}", s.method, s.target))
            .collect()
    }
}

/// Reads one request head without consuming it when it is a WebSocket
/// upgrade (tungstenite reads the handshake itself).
async fn serve(
    mut stream: TcpStream,
    route: Route,
    seen: Arc<Mutex<Vec<Seen>>>,
) -> std::io::Result<()> {
    let mut peek = vec![0u8; 8192];
    let head_len = loop {
        let n = stream.peek(&mut peek).await?;
        if n == 0 {
            return Ok(());
        }
        if let Some(i) = peek[..n].windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    };
    let head = String::from_utf8_lossy(&peek[..head_len]).into_owned();
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let method = first.next().unwrap_or("").to_string();
    let target = first.next().unwrap_or("").to_string();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        .collect();
    let mut req = Seen {
        method,
        target,
        headers,
        body: Vec::new(),
    };
    if req
        .header("Upgrade")
        .is_some_and(|u| u.eq_ignore_ascii_case("websocket"))
    {
        seen.lock().unwrap().push(req.clone());
        let Reply::Socket(messages) = route(&req) else {
            return Ok(());
        };
        let mut ws = tokio_tungstenite::accept_async(stream)
            .await
            .map_err(std::io::Error::other)?;
        for m in messages {
            ws.send(Message::text(m))
                .await
                .map_err(std::io::Error::other)?;
        }
        let _ = ws.close(None).await;
        return Ok(());
    }
    let mut discard = vec![0u8; head_len];
    stream.read_exact(&mut discard).await?;
    let len: usize = req
        .header("Content-Length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    req.body = vec![0u8; len];
    stream.read_exact(&mut req.body).await?;
    seen.lock().unwrap().push(req.clone());
    match route(&req) {
        Reply::Full(status, body) => {
            let head = format!(
                "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(head.as_bytes()).await?;
            stream.write_all(&body).await?;
            stream.shutdown().await?;
        }
        Reply::Stream(chunks) => {
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nConnection: close\r\n\r\n")
                .await?;
            for c in chunks {
                stream.write_all(&c).await?;
                stream.flush().await?;
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            tokio::time::sleep(Duration::from_secs(30)).await;
        }
        Reply::Socket(_) => {}
    }
    Ok(())
}

fn json_reply(v: Value) -> Reply {
    Reply::Full(200, serde_json::to_vec(&v).unwrap())
}

fn http() -> Arc<dyn RicohHttp> {
    Arc::new(ReqwestRicohHttp::new())
}

async fn wait_for<T>(mut f: impl FnMut() -> Option<T>) -> T {
    for _ in 0..300 {
        if let Some(v) = f() {
            return v;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out");
}

// MARK: Transport

#[tokio::test]
async fn reqwest_transport_sends_method_headers_and_body() {
    let server = Server::start(|s| {
        if s.path() == "/teapot" {
            Reply::Full(418, b"short and stout".to_vec())
        } else {
            Reply::Full(200, s.body.clone())
        }
    })
    .await;
    let client = ReqwestRicohHttp::new();
    let mut req = HttpRequest::new("PUT", format!("{}/echo?x=1", server.base()));
    req.headers
        .push(("Content-Type".into(), "application/json".into()));
    req.body = Some(b"{\"a\":1}".to_vec());
    let (body, status) = client.send(req).await.unwrap();
    assert_eq!(status, 200);
    assert_eq!(body, b"{\"a\":1}");
    let s = &server.seen()[0];
    assert_eq!(s.method, "PUT");
    assert_eq!(s.target, "/echo?x=1");
    assert_eq!(s.header("Content-Type"), Some("application/json"));
    let (body, status) = client
        .send(HttpRequest::new("GET", format!("{}/teapot", server.base())))
        .await
        .unwrap();
    assert_eq!((status, body.as_slice()), (418, &b"short and stout"[..]));
}

#[tokio::test]
async fn connection_failures_are_http_errors() {
    // Bind then drop a listener so the port is closed.
    let addr = TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap();
    let e = ReqwestRicohHttp::new()
        .send(HttpRequest::new("GET", format!("http://{addr}/v1/props")))
        .await
        .unwrap_err();
    assert!(matches!(e, PtpError::Http(_)), "{e:?}");
    assert!(!RicohHandler::probe(&addr.to_string(), Duration::from_secs(1), None).await);
}

// MARK: GoPro

#[tokio::test]
async fn gopro_end_to_end_over_http() {
    let files = Arc::new(Mutex::new(vec![
        "GOPR0001.JPG".to_string(),
        "GX010002.MP4".to_string(),
    ]));
    let f2 = files.clone();
    let jpeg = fake_jpeg(2048);
    let j2 = jpeg.clone();
    let server = Server::start(move |s| match s.path() {
        "/gopro/camera/info" => json_reply(json!({
            "info": {"model_name": "HERO11 Black", "serial_number": "C3471", "firmware_version": "H22.01.02"}
        })),
        "/gopro/media/list" => {
            let fs: Vec<Value> = f2.lock().unwrap().iter().map(|n| json!({"n": n})).collect();
            json_reply(json!({"id": "1", "media": [{"d": "100GOPRO", "fs": fs}]}))
        }
        "/videos/DCIM/100GOPRO/GOPR0003.JPG" => Reply::Full(200, j2.clone()),
        _ => json_reply(json!({})),
    })
    .await;
    let gopro = GoProHandler::with_http(&server.base(), http());
    let id = gopro.probe_identity().await.unwrap();
    assert_eq!(id.model, "HERO11 Black");
    assert_eq!(id.firmware, "H22.01.02");
    gopro.prepare().await.unwrap();
    let t = server.targets();
    assert!(t.contains(&"GET /gopro/camera/control/set_ui_controller?p=2".to_string()));
    assert!(t.contains(&"GET /gopro/camera/presets/set_group?id=1001".to_string()));
    gopro.capture(true).await.unwrap();
    assert!(gopro.poll_events().await.unwrap().is_empty());
    files.lock().unwrap().push("GOPR0003.JPG".into());
    let events = gopro.poll_events().await.unwrap();
    let CameraEvent::ObjectAdded(obj) = &events[0] else {
        panic!("{events:?}")
    };
    let (info, data) = gopro.fetch_object(obj, None).await.unwrap();
    assert_eq!(data, jpeg);
    assert_eq!(info.filename, "GOPR0003.JPG");
    assert_eq!(info.media_kind(), MediaKind::Jpeg);
    let t = server.targets();
    assert!(t.contains(&"GET /gopro/camera/shutter/start".to_string()));
    assert_eq!(
        t.iter().filter(|x| x.contains("keep_alive")).count(),
        1,
        "keep-alive at most every 3 s"
    );
}

// MARK: OSC

#[tokio::test]
async fn osc_end_to_end_over_http() {
    let base = Arc::new(Mutex::new(String::new()));
    let b2 = base.clone();
    let entries = Arc::new(Mutex::new(vec!["R0010001.JPG".to_string()]));
    let e2 = entries.clone();
    let server = Server::start(move |s| {
        if s.path() == "/osc/info" {
            return json_reply(json!({"manufacturer": "RICOH", "model": "RICOH THETA X", "serialNumber": "14100", "firmwareVersion": "2.0"}));
        }
        if s.path() == "/files/100RICOH/R0010002.JPG" {
            return Reply::Full(200, vec![7, 7, 7]);
        }
        let body = s.json();
        match body["name"].as_str() {
            Some("camera.listFiles") => {
                assert_eq!(body["parameters"]["fileType"], "image");
                let base = b2.lock().unwrap().clone();
                let list: Vec<Value> = e2
                    .lock()
                    .unwrap()
                    .iter()
                    .map(|n| json!({"name": n, "fileUrl": format!("{base}/files/100RICOH/{n}")}))
                    .collect();
                json_reply(json!({"name": "camera.listFiles", "state": "done", "results": {"entries": list}}))
            }
            Some("camera.takePicture") => json_reply(json!({"name": "camera.takePicture", "state": "inProgress"})),
            Some("camera.setOptions") => json_reply(json!({"state": "done"})),
            _ => Reply::Full(400, vec![]),
        }
    })
    .await;
    *base.lock().unwrap() = server.base();
    let theta = OscHandler::with_http(&server.base(), http());
    let id = theta.probe_identity().await.unwrap();
    assert_eq!(id.model, "RICOH THETA X");
    assert_eq!(id.id, "osc-14100");
    theta.prepare().await.unwrap();
    let posts: Vec<Seen> = server
        .seen()
        .into_iter()
        .filter(|s| s.method == "POST")
        .collect();
    assert_eq!(posts[0].json()["parameters"]["options"]["clientVersion"], 2);
    assert_eq!(
        posts[1].json()["parameters"]["options"]["captureMode"],
        "image"
    );
    assert_eq!(
        posts[0].header("Content-Type"),
        Some("application/json;charset=utf-8")
    );
    theta.capture(false).await.unwrap();
    entries.lock().unwrap().push("R0010002.JPG".into());
    let events = theta.poll_events().await.unwrap();
    let CameraEvent::ObjectAdded(obj) = &events[0] else {
        panic!("{events:?}")
    };
    assert_eq!(obj.info.as_ref().unwrap().filename, "R0010002.JPG");
    let (_, data) = theta.fetch_object(obj, None).await.unwrap();
    assert_eq!(data, vec![7, 7, 7]);
    assert!(theta.fetch_object(&NewObject::new(1), None).await.is_err());
}

// MARK: Ricoh GR

fn ricoh_route(
    photos: Arc<Mutex<Vec<String>>>,
    socket: Arc<Mutex<Vec<String>>>,
    frames: Vec<Vec<u8>>,
) -> impl Fn(&Seen) -> Reply + Send + Sync + 'static {
    move |s| match (s.method.as_str(), s.target.as_str()) {
        (_, "/v1/changes") => Reply::Socket(socket.lock().unwrap().clone()),
        ("GET", "/v1/props") => json_reply(json!({
            "errCode": 200, "model": "RICOH GR IIIx", "firmwareVersion": "1.50", "serialNo": "GRX-42",
            "battery": 88, "av": "2.8", "avList": ["2.8", "4.0"], "tv": "1/1000", "sv": "auto", "xv": "0.0",
        })),
        ("GET", "/v1/photos") => {
            let files = photos.lock().unwrap().clone();
            json_reply(json!({"dirs": [{"name": "100RICOH", "files": files}]}))
        }
        ("POST", "/v1/camera/shoot") => {
            let af = s.json()["af"].as_bool().unwrap_or(false);
            if af {
                json_reply(json!({"errCode": 200, "errMsg": "OK"}))
            } else {
                json_reply(json!({"errCode": 409, "errMsg": "focus required"}))
            }
        }
        ("PUT", "/v1/params/camera") => json_reply(json!({"errCode": 200})),
        ("GET", "/v1/liveview") => Reply::Stream(frames.clone()),
        ("GET", "/v1/photos/100RICOH/R0000010.DNG?size=view") => Reply::Full(200, fake_jpeg(64)),
        ("GET", "/v1/photos/100RICOH/R0000010.DNG") => Reply::Full(200, vec![0x49; 300]),
        _ => Reply::Full(404, vec![]),
    }
}

#[tokio::test]
async fn ricoh_gr_end_to_end_over_http_and_websocket() {
    let photos = Arc::new(Mutex::new(vec!["R0000001.JPG".to_string()]));
    let socket = Arc::new(Mutex::new(vec![
        r#"{"changed":["camera"],"camera":{"av":"4.0"}}"#.to_string(),
        r#"{"changed":["storage"],"storage":{"latestPhoto":"100RICOH/R0000010.DNG"}}"#.to_string(),
    ]));
    let server = Server::start(ricoh_route(photos.clone(), socket, vec![])).await;
    assert!(RicohHandler::probe(&server.addr.to_string(), Duration::from_secs(2), None).await);
    let h = RicohHandler::new(&server.base());
    let id = h.probe_identity().await.unwrap();
    assert_eq!(id.id, "ricoh-GRX-42");
    assert_eq!(id.model, "RICOH GR IIIx");
    h.prepare().await.unwrap();
    // The socket's messages arrive through the event task.
    let mut all = Vec::new();
    let events = wait_for(|| {
        all.extend(futures::executor::block_on(h.poll_events()).unwrap());
        (all.len() >= 2).then(|| all.clone())
    })
    .await;
    assert!(server.seen().iter().any(|s| s.path() == "/v1/changes"));
    assert_eq!(events[0], CameraEvent::PropertyChanged(None));
    let CameraEvent::ObjectAdded(obj) = &events[1] else {
        panic!("{events:?}")
    };
    // DNGs come down as the JPEG view proxy by default.
    let (info, data) = h.fetch_object(obj, None).await.unwrap();
    assert_eq!(info.filename, "R0000010.JPG");
    assert_eq!(data, fake_jpeg(64));
    h.set_prefer_view_proxy_for_raw(false);
    let (info, data) = h.fetch_object(obj, None).await.unwrap();
    assert_eq!(info.filename, "R0000010.DNG");
    assert_eq!(data.len(), 300);
    // errCode in a 200 answer is still a refusal.
    h.capture(true).await.unwrap();
    let e = h.capture(false).await.unwrap_err();
    assert!(e.to_string().contains("focus required"));
    let shoot = server
        .seen()
        .into_iter()
        .find(|s| s.path() == "/v1/camera/shoot")
        .unwrap();
    assert_eq!(shoot.body, b"{\"af\":true}");
    assert_eq!(shoot.header("Content-Type"), Some("application/json"));
    let props = h
        .read_properties(&[
            tether_ptp::TetherProperty::Aperture,
            tether_ptp::TetherProperty::BatteryLevel,
            tether_ptp::TetherProperty::Iso,
        ])
        .await
        .unwrap();
    assert_eq!(props[0].display, "ƒ/2.8");
    assert_eq!(props[1].display, "88%");
    assert_eq!(props[2].display, "Auto");
    h.teardown().await;
}

#[tokio::test]
async fn ricoh_polls_photos_when_the_socket_closes() {
    let photos = Arc::new(Mutex::new(vec!["R0000001.JPG".to_string()]));
    let server = Server::start(ricoh_route(
        photos.clone(),
        Arc::new(Mutex::new(vec![])),
        vec![],
    ))
    .await;
    let h = RicohHandler::new(&server.base());
    h.set_photo_poll_interval(Duration::from_millis(50));
    h.prepare().await.unwrap();
    photos.lock().unwrap().push("R0000002.JPG".into());
    let events = wait_for(|| {
        let e = futures::executor::block_on(h.poll_events()).unwrap();
        (!e.is_empty()).then_some(e)
    })
    .await;
    let CameraEvent::ObjectAdded(obj) = &events[0] else {
        panic!("{events:?}")
    };
    assert_eq!(obj.info.as_ref().unwrap().filename, "R0000002.JPG");
    h.teardown().await;
}

#[tokio::test]
async fn ricoh_live_view_streams_multipart_frames() {
    let (j1, j2) = (fake_jpeg(500), fake_jpeg(700));
    let mut part1 = format!(
        "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
        j1.len()
    )
    .into_bytes();
    part1.extend(&j1);
    part1.extend(b"\r\n");
    let mut part2 = format!(
        "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
        j2.len()
    )
    .into_bytes();
    part2.extend(&j2);
    part2.extend(b"\r\n");
    // Split the second part across writes.
    let (a, b) = part2.split_at(300);
    let server = Server::start(ricoh_route(
        Arc::new(Mutex::new(vec![])),
        Arc::new(Mutex::new(vec![])),
        vec![part1, a.to_vec(), b.to_vec()],
    ))
    .await;
    let h = RicohHandler::new(&server.base());
    h.start_live_view(LiveViewQuality::Medium).await.unwrap();
    let frame = wait_for(|| {
        futures::executor::block_on(h.next_live_view_frame())
            .unwrap()
            .filter(|f| f.sequence == 2)
    })
    .await;
    assert_eq!(frame.jpeg, j2);
    h.stop_live_view().await;
    assert!(server.seen().iter().any(|s| s.path() == "/v1/liveview"));
}

#[tokio::test]
async fn ricoh_live_view_error_surfaces_once_without_a_frame() {
    // Nothing listens: the stream ends with an error the next frame call reports.
    let addr = TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap();
    let h = RicohHandler::new(&format!("http://{addr}"));
    h.start_live_view(LiveViewQuality::Low).await.unwrap();
    let err = wait_for(|| futures::executor::block_on(h.next_live_view_frame()).err()).await;
    assert!(matches!(err, PtpError::Http(_)), "{err:?}");
    assert!(
        h.next_live_view_frame().await.unwrap().is_none(),
        "reported once"
    );
}
