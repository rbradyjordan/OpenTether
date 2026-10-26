//! Ports of the Swift `TetherSessionTests` (PipelineTests.swift) over the
//! scripted transport, plus the connection builder and a fake vendor for
//! live view, touch AF and rating write-back.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_library::previews::ImagePreviewGenerator;
use tether_library::{
    CaptureFlag, CaptureItem, CaptureState, ColorLabel, MediaKind, SessionStatus, SessionStore,
    ShootSession,
};
use tether_ptp::ptp::{
    DataType, DevicePropCode, ObjectFormat, OperationCode, ProgressFn, PropForm, PtpDevicePropDesc,
    PtpEvent, PtpObjectInfo, PtpValue,
};
use tether_ptp::testing::{fake_jpeg, ok, ScriptedTransport};
use tether_ptp::{
    camera_identity, CameraEvent, FocusResult, GenericPtpHandler, NewObject, PropertyDescriptor,
    PtpEngine, PtpError, PtpResult, PtpTransport, TetherProperty, VendorHandler,
};
use tether_session::session::connect::{self, ConnectServices, ConnectStep};
use tether_session::{
    CaptureCacheProxy, ReconnectContext, SessionEvent, TetherSession, TetherStatus,
};
use tether_types::{
    CameraCapabilities, CameraVendor, CaptureDestination, LiveViewFrame, LiveViewQuality,
    TransportKind,
};
use tokio::sync::broadcast;

const WAIT: Duration = Duration::from_secs(10);

struct Env {
    transport: Arc<ScriptedTransport>,
    engine: Arc<PtpEngine>,
    store: Arc<SessionStore>,
    cache: Arc<CaptureCacheProxy>,
    _dir: tempfile::TempDir,
}

fn script(t: &ScriptedTransport, payload: Vec<u8>) {
    let len = payload.len() as u32;
    t.on(OperationCode::GET_OBJECT_INFO, move |req| {
        let info = PtpObjectInfo {
            object_format: ObjectFormat::EXIF_JPEG,
            object_compressed_size: len,
            image_pix_width: 600,
            image_pix_height: 400,
            filename: format!("IMG_{:04}.JPG", req.parameters[0]),
            capture_date: "20261016T120000".into(),
            ..Default::default()
        };
        ok(info.encoded())
    });
    t.on(OperationCode::GET_PARTIAL_OBJECT, move |req| {
        let off = req.parameters[1] as usize;
        let want = req.parameters[2] as usize;
        ok(payload[off..payload.len().min(off + want)].to_vec())
    });
    t.on(OperationCode::GET_DEVICE_PROP_DESC, |req| {
        let desc = PtpDevicePropDesc {
            code: DevicePropCode(req.parameters[0] as u16),
            data_type: DataType::UINT16,
            is_writable: true,
            factory_default: PtpValue::UInt16(400),
            current: PtpValue::UInt16(400),
            form: PropForm::Enumeration(vec![PtpValue::UInt16(280), PtpValue::UInt16(400)]),
        };
        ok(desc.encoded())
    });
    t.on(OperationCode::INITIATE_CAPTURE, |_| ok(Vec::new()));
}

fn env() -> Env {
    let transport = ScriptedTransport::generic();
    script(&transport, fake_jpeg(5000));
    let engine = Arc::new(PtpEngine::new(transport.clone()));
    let dir = tempfile::tempdir().unwrap();
    Env {
        transport,
        engine,
        store: Arc::new(SessionStore::in_memory().unwrap()),
        cache: Arc::new(CaptureCacheProxy::new(dir.path().join("captures"))),
        _dir: dir,
    }
}

/// The next ready capture matching `pred`.
async fn ready(
    rx: &mut broadcast::Receiver<SessionEvent>,
    pred: impl Fn(&CaptureItem) -> bool,
) -> CaptureItem {
    tokio::time::timeout(WAIT, async {
        loop {
            if let Ok(SessionEvent::Capture(c)) = rx.recv().await {
                if c.state.is_ready() && pred(&c) {
                    return *c;
                }
            }
        }
    })
    .await
    .expect("a ready capture")
}

#[tokio::test]
async fn capture_flow_downloads_and_persists() {
    let e = env();
    let info = e.engine.connect(1).await.unwrap();
    let handler: Arc<dyn VendorHandler> =
        Arc::new(GenericPtpHandler::new(e.engine.clone(), info.clone(), None));
    let mut shoot = ShootSession::new("Test");
    shoot.destination = CaptureDestination::Both;
    shoot.transport = Some(TransportKind::Usb);
    e.store.save_session(&shoot).unwrap();
    let identity = camera_identity(&info, TransportKind::Usb, handler.capabilities(), "x");
    let session = TetherSession::new(
        shoot.clone(),
        Some(identity),
        Some(handler),
        Some(e.engine.clone()),
        e.store.clone(),
        e.cache.clone(),
        None,
    );
    let mut rx = session.subscribe();
    session.start().await.unwrap();
    let snap = session.snapshot();
    assert_eq!(snap.status, TetherStatus::Ready);
    assert!(!snap.properties.is_empty());

    session.capture(true).await.unwrap();
    assert_eq!(
        e.transport
            .requests_for(OperationCode::INITIATE_CAPTURE)
            .len(),
        1
    );
    e.transport.push(PtpEvent::new(
        tether_ptp::ptp::EventCode::OBJECT_ADDED,
        [0x21],
    ));
    // A duplicate (push + poll) is ignored.
    e.transport.push(PtpEvent::new(
        tether_ptp::ptp::EventCode::OBJECT_ADDED,
        [0x21],
    ));

    let item = ready(&mut rx, |_| true).await;
    assert_eq!(item.filename, "IMG_0033.JPG");
    assert_eq!(item.kind, MediaKind::Jpeg);
    assert_eq!(item.width, 600);
    assert_eq!(item.bytes, 5000);
    assert!(item.exposure.as_ref().unwrap().aperture.is_some());
    assert_eq!(
        e.cache
            .load(item.relative_path.as_deref().unwrap())
            .unwrap()
            .len(),
        5000
    );
    assert_eq!(e.store.captures_in_session(&shoot.id).unwrap().len(), 1);
    let snap = session.snapshot();
    assert_eq!(
        snap.selected_item_id.as_deref(),
        Some(item.id.as_str()),
        "show newest selects the new frame"
    );
    assert_eq!(snap.session.capture_count, 1);

    // Review state round-trips through the store.
    session.rate(&item.id, 5).await;
    session.flag(&item.id, CaptureFlag::Pick);
    session.label(&item.id, ColorLabel::Red);
    let stored = e.store.capture(&item.id).unwrap().unwrap();
    assert_eq!(stored.rating, 5);
    assert_eq!(stored.flag, CaptureFlag::Pick);
    assert_eq!(stored.color_label, ColorLabel::Red);
    session.flag(&item.id, CaptureFlag::Pick);
    assert_eq!(
        e.store.capture(&item.id).unwrap().unwrap().flag,
        CaptureFlag::None,
        "toggling clears"
    );

    // Keep current selection: a new frame does not steal focus.
    session.set_show_newest_capture(false);
    e.transport.push(PtpEvent::new(
        tether_ptp::ptp::EventCode::OBJECT_ADDED,
        [0x22],
    ));
    ready(&mut rx, |c| c.handle == 0x22).await;
    let snap = session.snapshot();
    assert_eq!(snap.items.len(), 2);
    assert_eq!(snap.selected_item_id.as_deref(), Some(item.id.as_str()));

    session.stop(true).await;
    assert_eq!(
        e.store.session(&shoot.id).unwrap().unwrap().status,
        SessionStatus::Ended
    );
    assert!(!e.engine.is_session_open());
}

#[tokio::test]
async fn property_write_and_disconnect() {
    let e = env();
    e.transport
        .on(OperationCode::SET_DEVICE_PROP_VALUE, |_| ok(Vec::new()));
    let info = e.engine.connect(1).await.unwrap();
    let handler: Arc<dyn VendorHandler> =
        Arc::new(GenericPtpHandler::new(e.engine.clone(), info, None));
    let shoot = ShootSession::new("Test");
    e.store.save_session(&shoot).unwrap();
    let session = TetherSession::new(
        shoot.clone(),
        None,
        Some(handler),
        Some(e.engine.clone()),
        e.store.clone(),
        e.cache.clone(),
        None,
    );
    session.start().await.unwrap();
    session
        .set_property(TetherProperty::Aperture, PtpValue::UInt16(280))
        .await
        .unwrap();
    let snap = session.snapshot();
    let ap = snap
        .properties
        .iter()
        .find(|p| p.property == TetherProperty::Aperture)
        .unwrap();
    assert_eq!(ap.display, "ƒ/2.8");
    session.handle(CameraEvent::Disconnected);
    assert_eq!(
        session.snapshot().status,
        TetherStatus::Disconnected("The camera disconnected.".into())
    );
    assert_eq!(
        e.store.session(&shoot.id).unwrap().unwrap().status,
        SessionStatus::Interrupted
    );
    assert_eq!(
        session.capture(true).await.unwrap_err(),
        PtpError::NotConnected
    );
}

#[tokio::test]
async fn ftp_ingest_without_camera() {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    let dir = tempfile::tempdir().unwrap();
    let cache = Arc::new(CaptureCacheProxy::new(dir.path().join("c")));
    let mut shoot = ShootSession::new("FTP");
    shoot.transport = Some(TransportKind::FtpPush);
    store.save_session(&shoot).unwrap();
    let session = TetherSession::new(shoot, None, None, None, store, cache, None);
    session.start().await.unwrap();
    assert_eq!(session.status(), TetherStatus::Ready);
    let tmp = dir.path().join("DSC_0001.NEF");
    std::fs::write(&tmp, [1u8; 10]).unwrap();
    session.ingest_file(&tmp, "192.168.1.9", None, true).await;
    let snap = session.snapshot();
    let first = snap.items.first().unwrap();
    assert_eq!(first.kind, MediaKind::Raw);
    assert_eq!(first.source, TransportKind::FtpPush);
    assert!(first.state.is_ready());
    assert!(!tmp.exists(), "moved into the session");
}

#[tokio::test]
async fn ingest_adopts_sidecar_metadata_whichever_lands_first() {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    let dir = tempfile::tempdir().unwrap();
    let cache = Arc::new(CaptureCacheProxy::new(dir.path().join("c")));
    let mut shoot = ShootSession::new("FTP");
    shoot.transport = Some(TransportKind::FtpPush);
    store.save_session(&shoot).unwrap();
    let session = TetherSession::new(shoot, None, None, None, store.clone(), cache, None);
    session.start().await.unwrap();
    // Sidecar first (Photo Mechanic style), then the photo.
    let mut photo = CaptureItem::new(
        "x",
        1,
        1,
        "DSC_0002.JPG",
        MediaKind::Jpeg,
        0,
        TransportKind::FtpPush,
    );
    photo.rating = 4;
    photo.color_label = ColorLabel::Green;
    let packet = tether_library::interop::XmpPacket::from_capture(
        &photo,
        &["client".to_string()],
        &Default::default(),
        None,
    );
    let xmp = dir.path().join("DSC_0002.xmp");
    std::fs::write(&xmp, packet.data()).unwrap();
    assert!(session.ingest_file(&xmp, "cam", None, true).await.is_none());
    assert!(!xmp.exists());
    let jpg = dir.path().join("DSC_0002.JPG");
    std::fs::write(&jpg, fake_jpeg(100)).unwrap();
    let item = session.ingest_file(&jpg, "cam", None, true).await.unwrap();
    assert_eq!(item.rating, 4);
    assert_eq!(item.color_label, ColorLabel::Green);
    assert_eq!(store.tags(&item.id).unwrap(), vec!["client".to_string()]);
}

#[tokio::test]
async fn recovery_refetches_card_objects_and_fails_sdram_ones() {
    let e = env();
    let shoot = ShootSession::new("Recover");
    e.store.save_session(&shoot).unwrap();
    // Left behind by a crash: one card object half-downloaded, one SDRAM object.
    let mut a = CaptureItem::new(
        &shoot.id,
        1,
        0x55,
        "IMG_0085.JPG",
        MediaKind::Jpeg,
        0,
        TransportKind::Usb,
    );
    a.state = CaptureState::Downloading {
        received: 10,
        total: Some(100),
    };
    e.store.save_capture(&a).unwrap();
    let b = CaptureItem::new(
        &shoot.id,
        2,
        0xFFFF_0001,
        "sdram",
        MediaKind::Jpeg,
        0,
        TransportKind::Usb,
    );
    e.store.save_capture(&b).unwrap();
    let info = e.engine.connect(1).await.unwrap();
    let session = TetherSession::new(
        shoot.clone(),
        None,
        Some(Arc::new(GenericPtpHandler::new(
            e.engine.clone(),
            info,
            None,
        ))),
        Some(e.engine.clone()),
        e.store.clone(),
        e.cache.clone(),
        None,
    );
    let mut rx = session.subscribe();
    session.start().await.unwrap();
    ready(&mut rx, |_| true).await;
    let items = e.store.captures_in_session(&shoot.id).unwrap();
    assert_eq!(items.len(), 2);
    assert!(items
        .iter()
        .any(|i| i.handle == 0x55 && i.state.is_ready() && i.filename == "IMG_0085.JPG"));
    assert!(items
        .iter()
        .any(|i| i.handle == 0xFFFF_0001 && i.state.is_failed()));
}

#[tokio::test]
async fn connection_builder_connects_captures_and_makes_previews() {
    let dir = tempfile::tempdir().unwrap();
    let transport = ScriptedTransport::generic();
    let jpeg = tether_session::demo::frame(0, 640, 426);
    script(&transport, jpeg.clone());
    let services = ConnectServices {
        store: Arc::new(SessionStore::in_memory().unwrap()),
        cache: Arc::new(CaptureCacheProxy::new(dir.path().join("c"))),
        previews: Arc::new(ImagePreviewGenerator::default()),
        ptp_log: None,
    };
    let shoot = ShootSession::new("Builder");
    let steps = Arc::new(Mutex::new(Vec::new()));
    let s2 = steps.clone();
    let conn = connect::connect_ptp(
        transport.clone(),
        TransportKind::Usb,
        "usb-1",
        None,
        ReconnectContext::Usb {
            device_id: "usb-1".into(),
            serial: None,
        },
        &shoot,
        &services,
        Some(Arc::new(move |s| s2.lock().unwrap().push(s))),
    )
    .await
    .unwrap();
    assert_eq!(
        *steps.lock().unwrap(),
        vec![
            ConnectStep::Link,
            ConnectStep::Session,
            ConnectStep::DeviceInfo,
            ConnectStep::VendorGate,
            ConnectStep::Ready
        ]
    );
    assert_eq!(
        conn.context,
        ReconnectContext::Usb {
            device_id: "usb-1".into(),
            serial: Some("SN0001".into())
        }
    );
    let identity = conn.identity.clone().unwrap();
    assert_eq!(identity.id, "generic-SN0001");
    let stored = services.store.session(&shoot.id).unwrap().unwrap();
    assert_eq!(stored.transport, Some(TransportKind::Usb));
    assert_eq!(
        stored.camera.as_ref().map(|c| c.id.as_str()),
        Some("generic-SN0001")
    );
    assert_eq!(services.store.known_cameras().unwrap().len(), 1);

    let session = conn.session.clone();
    let mut rx = session.subscribe();
    session.capture(false).await.unwrap();
    transport.push(PtpEvent::new(tether_ptp::ptp::EventCode::OBJECT_ADDED, [7]));
    let item = ready(&mut rx, |_| true).await;
    assert_eq!(item.filename, "IMG_0007.JPG");
    assert_eq!((item.width, item.height), (640, 426));
    let thumb = item.thumbnail_relative_path.as_deref().expect("thumbnail");
    assert!(services.cache.exists(thumb));
    let proxy = item.proxy_relative_path.as_deref().expect("proxy");
    assert!(services.cache.exists(proxy));
    assert_eq!(item.camera_id.as_deref(), Some("generic-SN0001"));
    session.stop(true).await;
}

#[tokio::test]
async fn failed_download_marks_the_capture_failed() {
    let e = env();
    e.transport.on(OperationCode::GET_PARTIAL_OBJECT, |_| {
        tether_ptp::testing::fail(tether_ptp::ptp::ResponseCode::GENERAL_ERROR)
    });
    let info = e.engine.connect(1).await.unwrap();
    let shoot = ShootSession::new("Fail");
    e.store.save_session(&shoot).unwrap();
    let session = TetherSession::new(
        shoot,
        None,
        Some(Arc::new(GenericPtpHandler::new(
            e.engine.clone(),
            info,
            None,
        ))),
        Some(e.engine.clone()),
        e.store.clone(),
        e.cache.clone(),
        None,
    );
    let mut rx = session.subscribe();
    session.start().await.unwrap();
    e.transport
        .push(PtpEvent::new(tether_ptp::ptp::EventCode::OBJECT_ADDED, [9]));
    let failed = tokio::time::timeout(WAIT, async {
        loop {
            if let Ok(SessionEvent::Capture(c)) = rx.recv().await {
                if c.state.is_failed() {
                    return *c;
                }
            }
        }
    })
    .await
    .unwrap();
    // As on iOS the info came with the failed fetch, so the placeholder name stays.
    assert!(failed.filename.starts_with("capture-"));
    assert_eq!(failed.handle, 9);
    assert!(
        session.status().is_live(),
        "a failed download is not a dropped link"
    );
}

/// A camera with live view, touch AF and rating write-back.
#[derive(Default)]
struct FakeCamera {
    frames: AtomicU32,
    ratings: Mutex<Vec<(u32, i32)>>,
}

#[async_trait]
impl VendorHandler for FakeCamera {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Canon
    }
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities::LIVE_VIEW
            | CameraCapabilities::RATING
            | CameraCapabilities::TOUCH_AUTOFOCUS
            | CameraCapabilities::REMOTE_CAPTURE
    }
    fn event_poll_interval(&self) -> Duration {
        Duration::from_secs(3600)
    }
    async fn prepare(&self) -> PtpResult<()> {
        Ok(())
    }
    async fn teardown(&self) {}
    async fn set_capture_destination(&self, _d: CaptureDestination) -> PtpResult<()> {
        Ok(())
    }
    async fn capture(&self, _af: bool) -> PtpResult<()> {
        Ok(())
    }
    async fn translate(&self, _e: &PtpEvent) -> Option<CameraEvent> {
        None
    }
    async fn read_properties(&self, _p: &[TetherProperty]) -> PtpResult<Vec<PropertyDescriptor>> {
        Ok(Vec::new())
    }
    async fn write_property(&self, _p: TetherProperty, _raw: PtpValue) -> PtpResult<()> {
        Ok(())
    }
    async fn fetch_object(
        &self,
        _o: &NewObject,
        _p: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        Err(PtpError::NotConnected)
    }
    async fn start_live_view(&self, _q: LiveViewQuality) -> PtpResult<()> {
        Ok(())
    }
    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        let n = self.frames.fetch_add(1, Ordering::SeqCst);
        if n >= 3 {
            return Err(PtpError::TransportClosed);
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
        Ok(Some(LiveViewFrame {
            jpeg: fake_jpeg(64),
            sequence: 0,
            timestamp: chrono::Utc::now(),
            width: Some(8),
            height: Some(8),
        }))
    }
    async fn set_rating(&self, handle: u32, stars: i32) -> PtpResult<()> {
        self.ratings.lock().unwrap().push((handle, stars));
        Ok(())
    }
    async fn focus(&self, x: f64, y: f64) -> PtpResult<FocusResult> {
        assert!((0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y));
        Ok(FocusResult::Focused)
    }
}

#[tokio::test]
async fn live_view_touch_focus_and_rating_write_back() {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    let dir = tempfile::tempdir().unwrap();
    let cache = Arc::new(CaptureCacheProxy::new(dir.path().join("c")));
    let shoot = ShootSession::new("Fake");
    store.save_session(&shoot).unwrap();
    let mut existing = CaptureItem::new(
        &shoot.id,
        1,
        0x42,
        "IMG_1.JPG",
        MediaKind::Jpeg,
        1,
        TransportKind::Usb,
    );
    existing.state = CaptureState::Ready;
    store.save_capture(&existing).unwrap();
    let cam = Arc::new(FakeCamera::default());
    let session = TetherSession::new(
        shoot,
        None,
        Some(cam.clone()),
        None,
        store.clone(),
        cache,
        None,
    );
    let mut rx = session.subscribe();
    session.start().await.unwrap();
    assert_eq!(
        session.focus(2.0, -1.0).await.unwrap(),
        FocusResult::Focused
    );
    session
        .start_live_view(LiveViewQuality::Medium)
        .await
        .unwrap();
    let mut seqs = Vec::new();
    let mut warned = false;
    tokio::time::timeout(WAIT, async {
        loop {
            match rx.recv().await {
                Ok(SessionEvent::LiveView(f)) => seqs.push(f.sequence),
                Ok(SessionEvent::Warning(w)) if w.starts_with("Live view stopped") => {
                    warned = true;
                    break;
                }
                _ => {}
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(seqs, vec![1, 2, 3]);
    assert!(warned);
    assert!(!session.live_view_active());

    // A library edit reaches the camera.
    let mut edited = existing.clone();
    edited.rating = 3;
    tether_library::library::LiveCaptureHook::replace_from_store(&session, &[edited]);
    tokio::time::timeout(WAIT, async {
        while cam.ratings.lock().unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(*cam.ratings.lock().unwrap(), vec![(0x42, 3)]);
    assert_eq!(session.snapshot().items[0].rating, 3);
}

#[tokio::test]
async fn delete_removes_files_and_reselects() {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    let dir = tempfile::tempdir().unwrap();
    let cache = Arc::new(CaptureCacheProxy::new(dir.path().join("c")));
    let mut shoot = ShootSession::new("Del");
    shoot.transport = Some(TransportKind::FtpPush);
    store.save_session(&shoot).unwrap();
    let session = TetherSession::new(shoot, None, None, None, store.clone(), cache.clone(), None);
    session.start().await.unwrap();
    let mut ids = Vec::new();
    for n in 1..=2 {
        let p = dir.path().join(format!("A_{n}.JPG"));
        std::fs::write(&p, fake_jpeg(50)).unwrap();
        ids.push(session.ingest_file(&p, "x", None, true).await.unwrap());
    }
    assert_eq!(
        session.snapshot().selected_item_id.as_deref(),
        Some(ids[1].id.as_str())
    );
    let path = ids[1].relative_path.clone().unwrap();
    assert!(cache.exists(&path));
    session.delete(&ids[1].id);
    assert!(!cache.exists(&path));
    assert!(store.capture(&ids[1].id).unwrap().is_none());
    assert_eq!(
        session.snapshot().selected_item_id.as_deref(),
        Some(ids[0].id.as_str())
    );
    let _ = PtpTransport::kind(&*ScriptedTransport::generic());
}
