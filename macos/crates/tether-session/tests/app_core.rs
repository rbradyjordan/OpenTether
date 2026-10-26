//! `AppCore` end to end: the demo session, an FTP push into the receiver
//! on 127.0.0.1, a scripted camera with a hot folder, and the library,
//! review, undo and export paths.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tether_library::delivery::{ExportDestination, ExportOptions};
use tether_library::library::CaptureFilter;
use tether_library::{CaptureFlag, ColorLabel};
use tether_net::{CameraDiscoverer, FtpClient, FtpDestination, FtpSecurity};
use tether_ptp::ptp::{
    DataType, DevicePropCode, EventCode, ObjectFormat, OperationCode, PropForm, PtpDevicePropDesc,
    PtpEvent, PtpObjectInfo, PtpValue,
};
use tether_ptp::testing::{ok, ScriptedTransport};
use tether_ptp::TetherProperty;
use tether_session::app_core::{ExportRequest, FtpDestinationInput, LibraryQuery, LibrarySource};
use tether_session::events::{CaptureDto, PropertyInput};
use tether_session::platform::{MemorySecrets, PhotoLibrary};
use tether_session::{AppCore, AppCoreConfig, AppEvent, ImageKind, TetherStatus};
use tokio::sync::broadcast;

const WAIT: Duration = Duration::from_secs(30);

#[derive(Default)]
struct FakePhotos {
    added: Mutex<Vec<String>>,
}

#[async_trait::async_trait]
impl PhotoLibrary for FakePhotos {
    async fn request_add_only(&self) -> bool {
        true
    }
    async fn add_image(&self, file: &Path) -> Result<Option<String>, String> {
        let name = file.file_name().unwrap().to_string_lossy().to_string();
        self.added.lock().unwrap().push(name.clone());
        Ok(Some(format!("local-{name}")))
    }
}

async fn open(dir: &Path) -> (AppCore, Arc<FakePhotos>) {
    let photos = Arc::new(FakePhotos::default());
    let mut config = AppCoreConfig::at(dir.join("Open Tether"));
    config.secrets = Arc::new(MemorySecrets::default());
    config.photos = photos.clone();
    config.discovery = Some(Arc::new(CameraDiscoverer::with_sources(
        Vec::new(),
        Duration::from_secs(30),
        Duration::from_secs(5),
    )));
    config.demo_frame_size = (480, 320);
    (AppCore::open(config).await.unwrap(), photos)
}

/// Waits for an event matching `f`, returning what `f` extracted.
async fn wait_for<T>(
    rx: &mut broadcast::Receiver<AppEvent>,
    mut f: impl FnMut(&AppEvent) -> Option<T>,
) -> T {
    tokio::time::timeout(WAIT, async {
        loop {
            match rx.recv().await {
                Ok(e) => {
                    if let Some(t) = f(&e) {
                        return t;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(e) => panic!("event stream closed: {e}"),
            }
        }
    })
    .await
    .expect("event in time")
}

fn ready_capture(e: &AppEvent) -> Option<CaptureDto> {
    match e {
        AppEvent::CaptureAdded { capture } | AppEvent::CaptureUpdated { capture }
            if capture.state == "ready" =>
        {
            Some((**capture).clone())
        }
        _ => None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn demo_session_end_to_end() {
    let dir = tempfile::tempdir().unwrap();
    let (core, photos) = open(dir.path()).await;
    let mut rx = core.subscribe();
    let state = core.start_demo(Duration::ZERO).await.unwrap();
    assert!(state.session.is_demo);
    assert_eq!(state.camera_name, "Demo camera");
    assert_eq!(state.status, TetherStatus::Ready);

    let mut frames = Vec::new();
    while frames.len() < tether_session::demo::FRAME_COUNT {
        let c = wait_for(&mut rx, ready_capture).await;
        if !frames.iter().any(|f: &CaptureDto| f.id == c.id) {
            frames.push(c);
        }
    }
    assert_eq!(frames[0].filename, "DEMO_0001.JPG");
    assert!(frames.iter().all(|f| f.has_thumbnail && f.width == 480));
    let thumb = core.image_path(&frames[0].id, ImageKind::Thumb).unwrap();
    assert!(thumb.exists());
    let original = core.image_path(&frames[0].id, ImageKind::Original).unwrap();
    assert_eq!(&std::fs::read(&original).unwrap()[..2], &[0xFF, 0xD8]);
    let shoot = core.shoot_state().unwrap();
    assert_eq!(shoot.items.len(), 8);
    assert_eq!(
        shoot.selected_item_id.as_deref(),
        Some(frames[7].id.as_str())
    );

    // Review through the editor: undoable, mirrored into the live shoot.
    let ids: Vec<String> = frames.iter().take(2).map(|f| f.id.clone()).collect();
    core.rate(&ids, 4).unwrap();
    core.flag(&ids[..1], CaptureFlag::Pick).unwrap();
    core.label(&ids[..1], ColorLabel::Blue).unwrap();
    core.add_tags(&["hero".to_string()], &ids[..1]).unwrap();
    assert_eq!(core.get_capture(&ids[0]).unwrap().rating, 4);
    assert_eq!(core.tags(&ids[0]).unwrap(), vec!["hero".to_string()]);
    let live = core.shoot_state().unwrap();
    assert_eq!(
        live.items.iter().find(|i| i.id == ids[1]).unwrap().rating,
        4
    );
    assert_eq!(core.undo_state().0.as_deref(), Some("Tag #hero"));
    assert_eq!(core.undo().unwrap().as_deref(), Some("Tag #hero"));
    assert!(core.tags(&ids[0]).unwrap().is_empty());
    core.redo().unwrap();
    assert_eq!(core.tags(&ids[0]).unwrap(), vec!["hero".to_string()]);

    // Library queries: session source, picks filter, search, collections.
    let session_id = shoot.session.id.clone();
    let page = core
        .library_query(&LibraryQuery {
            source: LibrarySource::Session(session_id.clone()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(page.total, 8);
    assert_eq!(page.title, "Demo shoot");
    let picks = core
        .library_query(&LibraryQuery {
            source: LibrarySource::Collection("builtin.all".into()),
            filter: Some(CaptureFilter {
                flags: Some([CaptureFlag::Pick].into_iter().collect()),
                ..Default::default()
            }),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(picks.total, 1);
    let search = core
        .library_query(&LibraryQuery {
            search: Some("DEMO_0003".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(search.items.len(), 1);
    let col = core.create_collection("Selects", &ids, None, None).unwrap();
    assert_eq!(col.count, 2);
    let manual = core
        .library_query(&LibraryQuery {
            source: LibrarySource::Collection(col.id.clone()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(manual.total, 2);
    let smart = core
        .save_smart_collection(
            "Four stars",
            CaptureFilter {
                min_rating: Some(4),
                ..Default::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(smart.count, 2);
    assert!(core.collections().unwrap().iter().any(|c| c.id == smart.id));

    // Looks: built-ins, colour match, render.
    let looks = core.looks().unwrap();
    assert!(looks.iter().any(|l| l.is_built_in));
    let matched = core
        .color_match(&frames[0].id, &frames[7].id, 1.0, "Dusk match")
        .await
        .unwrap();
    assert_eq!(matched.family, "Colour match");
    let rendered = core
        .render_with_look(
            &frames[1].id,
            tether_library::looks::LookStack::new(Some(matched.id.clone()), 0.8),
            Some(200),
        )
        .await
        .unwrap();
    assert_eq!(&rendered[..2], &[0xFF, 0xD8]);

    // Export: to a picked folder and to Photos.
    let out = dir.path().join("Picked");
    std::fs::create_dir_all(&out).unwrap();
    let jobs = core
        .export_to_folder(
            &ids,
            &out,
            Some(vec![1, 2, 3]),
            Some(ExportOptions::default()),
        )
        .unwrap();
    assert_eq!(jobs.len(), 1);
    let finished = wait_for(&mut rx, |e| match e {
        AppEvent::ExportFinished { job } => Some(job.clone()),
        _ => None,
    })
    .await;
    assert_eq!(finished.status, "completed", "{finished:?}");
    assert!(out.join("DEMO_0001.JPG").exists());
    assert!(out.join("DEMO_0002.JPG").exists());
    let folders = core.folder_destinations().unwrap();
    assert_eq!(folders.len(), 1);
    assert_eq!(folders[0].bookmark, vec![1, 2, 3]);
    core.export(ExportRequest {
        ids: ids[..1].to_vec(),
        destination: ExportDestination::Photos,
        options: None,
        look: None,
    })
    .unwrap();
    let finished = wait_for(&mut rx, |e| match e {
        AppEvent::ExportFinished { job } if job.destination == "photos" => Some(job.clone()),
        _ => None,
    })
    .await;
    assert_eq!(finished.status, "completed");
    assert_eq!(photos.added.lock().unwrap().len(), 1);
    assert!(core.export_jobs(None).unwrap().len() >= 2);

    // Delete one frame from the live shoot.
    core.delete_captures(&[frames[5].id.clone()]).unwrap();
    assert_eq!(core.shoot_state().unwrap().items.len(), 7);

    // End: the session is ended and listed as a demo.
    core.end_shoot().await.unwrap();
    assert!(core.shoot_state().is_none());
    let sessions = core.list_sessions().unwrap();
    let demo = sessions.iter().find(|s| s.id == session_id).unwrap();
    assert!(demo.is_demo);
    assert_eq!(demo.status, tether_library::SessionStatus::Ended);
    assert_eq!(demo.counts.total, 7);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ftp_push_lands_as_a_capture() {
    let dir = tempfile::tempdir().unwrap();
    let (core, _) = open(dir.path()).await;
    let mut settings = core.settings();
    settings.ftp_port = 0; // ephemeral
    core.update_settings(settings.clone()).await.unwrap();
    let mut rx = core.subscribe();
    let state = core.start_ftp_session(None).await.unwrap();
    assert_eq!(state.camera_name, "FTP receiver");
    let status = core.ftp_status();
    assert!(status.is_running);
    let port = status.port.unwrap();
    assert_ne!(port, 0);

    let jpeg = tether_session::demo::frame(3, 320, 200);
    let mut dest = FtpDestination::new("127.0.0.1");
    dest.port = port;
    dest.username = settings.ftp_username.clone();
    dest.password = settings.ftp_password.clone();
    dest.security = FtpSecurity::Plain;
    dest.passive = true;
    FtpClient::new(dest)
        .with_timeout(Duration::from_secs(10))
        .upload(&jpeg, "/DSC_0001.JPG", None)
        .await
        .unwrap();

    let received = wait_for(&mut rx, |e| match e {
        AppEvent::FtpFileReceived { file } => Some(file.clone()),
        _ => None,
    })
    .await;
    assert_eq!(received.name, "DSC_0001.JPG");
    assert_eq!(received.bytes, jpeg.len() as u64);
    let capture = wait_for(&mut rx, ready_capture).await;
    assert_eq!(capture.filename, "DSC_0001.JPG");
    assert_eq!(capture.session_id, state.session.id);
    assert_eq!(capture.source, tether_types::TransportKind::FtpPush);
    assert_eq!(capture.bytes, jpeg.len() as i64);
    assert!(core
        .image_path(&capture.id, ImageKind::Preview)
        .unwrap()
        .exists());
    assert_eq!(core.ftp_received().len(), 1);
    core.ftp_stop().await;
    assert!(!core.ftp_status().is_running);
}

fn scripted_camera() -> Arc<ScriptedTransport> {
    let t = ScriptedTransport::generic();
    let payload = tether_session::demo::frame(2, 360, 240);
    let len = payload.len() as u32;
    t.on(OperationCode::GET_OBJECT_INFO, move |req| {
        ok(PtpObjectInfo {
            object_format: ObjectFormat::EXIF_JPEG,
            object_compressed_size: len,
            filename: format!("IMG_{:04}.JPG", req.parameters[0]),
            ..Default::default()
        }
        .encoded())
    });
    t.on(OperationCode::GET_PARTIAL_OBJECT, move |req| {
        let off = req.parameters[1] as usize;
        let want = req.parameters[2] as usize;
        ok(payload[off..payload.len().min(off + want)].to_vec())
    });
    t.on(OperationCode::GET_DEVICE_PROP_DESC, |req| {
        ok(PtpDevicePropDesc {
            code: DevicePropCode(req.parameters[0] as u16),
            data_type: DataType::UINT16,
            is_writable: true,
            factory_default: PtpValue::UInt16(400),
            current: PtpValue::UInt16(400),
            form: PropForm::Enumeration(vec![PtpValue::UInt16(280), PtpValue::UInt16(400)]),
        }
        .encoded())
    });
    t.on(OperationCode::INITIATE_CAPTURE, |_| ok(Vec::new()));
    t.on(OperationCode::SET_DEVICE_PROP_VALUE, |_| ok(Vec::new()));
    t
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn scripted_camera_capture_hot_folder_and_settings() {
    let dir = tempfile::tempdir().unwrap();
    let (core, _) = open(dir.path()).await;
    let session = core.create_session(Some("Studio".into()), None).unwrap();
    let hot = dir.path().join("Hot");
    std::fs::create_dir_all(&hot).unwrap();
    let folder = core.add_folder_destination(&hot, None).unwrap();
    core.set_hot_folder(&session.id, Some(folder.id.clone()))
        .unwrap();
    let mut rx = core.subscribe();
    let t = scripted_camera();
    let state = core
        .connect_transport(t.clone(), Some(session.id.clone()))
        .await
        .unwrap();
    assert_eq!(state.status, TetherStatus::Ready);
    assert!(state.can_capture);
    assert_eq!(state.camera_name, "PTP-1");
    assert!(!state.properties.is_empty());

    // Exposure: by choice index.
    let ap = core
        .properties()
        .unwrap()
        .into_iter()
        .find(|p| p.property == TetherProperty::Aperture)
        .unwrap();
    assert_eq!(ap.choices, vec!["ƒ/2.8".to_string(), "ƒ/4".to_string()]);
    core.set_property(TetherProperty::Aperture, PropertyInput::Choice(0))
        .await
        .unwrap();
    assert_eq!(
        core.properties()
            .unwrap()
            .iter()
            .find(|p| p.property == TetherProperty::Aperture)
            .unwrap()
            .display,
        "ƒ/2.8"
    );

    core.capture(true).await.unwrap();
    t.push(PtpEvent::new(EventCode::OBJECT_ADDED, [0x31]));
    let c = wait_for(&mut rx, ready_capture).await;
    assert_eq!(c.filename, "IMG_0049.JPG");
    assert_eq!(c.camera_id.as_deref(), Some("generic-SN0001"));
    // The hot folder gets the original under its camera name.
    let copied = hot.join("IMG_0049.JPG");
    tokio::time::timeout(WAIT, async {
        while !copied.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("hot folder copy");

    // Disconnect: the status reaches the UI; reconnect has nothing to redial.
    t.push(PtpEvent::new(EventCode::DEVICE_RESET, []));
    let status = wait_for(&mut rx, |e| match e {
        AppEvent::ConnectionStatus { status, .. } if !status.is_live() => Some(status.clone()),
        _ => None,
    })
    .await;
    assert_eq!(
        status,
        TetherStatus::Disconnected("The camera disconnected.".into())
    );
    assert!(core.capture(true).await.is_err());

    // Known cameras and diagnostics against a closed port.
    assert_eq!(core.known_cameras().unwrap().len(), 1);
    let report = core.run_wireless_diagnostics("127.0.0.1", 1).await;
    assert_eq!(report.checks.len(), 3);
    assert!(report.checks[2].outcome.is_failure());

    core.end_shoot().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sessions_ftp_destinations_and_import() {
    let dir = tempfile::tempdir().unwrap();
    let (core, _) = open(dir.path()).await;
    let s = core.create_session(None, None).unwrap();
    assert!(!s.name.is_empty());
    core.rename_session(&s.id, "Renamed").unwrap();
    assert_eq!(core.session(&s.id).unwrap().name, "Renamed");

    let d = core
        .save_ftp_destination(FtpDestinationInput {
            id: None,
            name: "NAS".into(),
            host: "10.0.0.5".into(),
            port: 21,
            username: "brady".into(),
            security: "plain".into(),
            passive: true,
            remote_directory: String::new(),
            password: Some("secret".into()),
        })
        .unwrap();
    assert_eq!(d.remote_directory, "/");
    assert_eq!(core.ftp_destinations().unwrap().len(), 1);
    core.delete_ftp_destination(&d.id).unwrap();
    assert!(core.ftp_destinations().unwrap().is_empty());

    // Import a folder with a sidecar into that session.
    let src = dir.path().join("Card");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(
        src.join("A_0001.JPG"),
        tether_session::demo::frame(1, 160, 100),
    )
    .unwrap();
    std::fs::write(src.join("notes.txt"), b"x").unwrap();
    let n = core
        .import_files(vec![src.clone()], Some(s.id.clone()))
        .await
        .unwrap();
    assert_eq!(n, 1);
    assert!(
        src.join("A_0001.JPG").exists(),
        "the user's file is untouched"
    );
    assert_eq!(core.session(&s.id).unwrap().counts.ready, 1);

    // Interrupted sessions are offered for resume; dismissing ends them.
    let mut interrupted = core.store().session(&s.id).unwrap().unwrap();
    interrupted.status = tether_library::SessionStatus::Interrupted;
    core.store().save_session(&interrupted).unwrap();
    assert_eq!(core.interrupted_sessions().unwrap().len(), 1);
    core.dismiss_interrupted(&s.id).unwrap();
    assert!(core.interrupted_sessions().unwrap().is_empty());

    // Resume an FTP session from the store: no reconnect needed.
    let mut ftp = core.store().session(&s.id).unwrap().unwrap();
    ftp.transport = Some(tether_types::TransportKind::FtpPush);
    core.store().save_session(&ftp).unwrap();
    let mut settings = core.settings();
    settings.ftp_port = 0;
    core.update_settings(settings).await.unwrap();
    let state = core.resume_session(&s.id).await.unwrap();
    assert_eq!(state.status, TetherStatus::Ready);
    assert_eq!(state.items.len(), 1);
    core.delete_session(&s.id).await.unwrap();
    assert!(core.shoot_state().is_none());
    assert!(core.list_sessions().unwrap().iter().all(|x| x.id != s.id));
    core.ftp_stop().await;
}
