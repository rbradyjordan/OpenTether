//! Store round-trips and migrations (Swift `StoreTests`, plus schema checks).

use std::sync::Arc;

use rusqlite::Connection;
use tether_library::delivery::{
    ExportDestination, ExportItem, ExportJob, ExportOptions, ExportStatus,
};
use tether_library::looks::LookStack;
use tether_library::store::{FolderKind, StoredFolderDestination, StoredFtpDestination};
use tether_library::{
    CaptureFlag, CaptureItem, CaptureState, MediaKind, SessionStatus, SessionStore, ShootSession,
};
use tether_types::{
    CameraCapabilities, CameraIdentity, CameraVendor, CaptureDestination, TransportKind,
};

fn camera() -> CameraIdentity {
    CameraIdentity {
        id: "canon-1".into(),
        vendor: CameraVendor::Canon,
        manufacturer: "Canon".into(),
        model: "EOS R5".into(),
        serial_number: "1".into(),
        firmware: "1.8".into(),
        transport: TransportKind::PtpIp,
        capabilities: CameraCapabilities::REMOTE_CAPTURE,
    }
}

#[test]
fn sessions_and_captures_persist() {
    let store = SessionStore::in_memory().unwrap();
    let mut s = ShootSession::new("Studio A");
    s.destination = CaptureDestination::Host;
    store.save_session(&s).unwrap();
    assert_eq!(store.sessions(200).unwrap().len(), 1);
    assert_eq!(
        store.session(&s.id).unwrap().unwrap().destination,
        CaptureDestination::Host
    );

    let mut c = CaptureItem::new(
        &s.id,
        1,
        0x10,
        "IMG_0001.CR3",
        MediaKind::Raw,
        100,
        TransportKind::Usb,
    );
    store.save_capture(&c).unwrap();
    let mut j = CaptureItem::new(
        &s.id,
        2,
        0x11,
        "IMG_0001.JPG",
        MediaKind::Jpeg,
        50,
        TransportKind::Usb,
    );
    j.state = CaptureState::Ready;
    j.flag = CaptureFlag::Pick;
    j.rating = 4;
    store.save_capture(&j).unwrap();
    let names: Vec<String> = store
        .captures_in_session(&s.id)
        .unwrap()
        .into_iter()
        .map(|c| c.filename)
        .collect();
    assert_eq!(names, ["IMG_0001.CR3", "IMG_0001.JPG"]);
    assert_eq!(j.pair_key, c.pair_key);
    assert_eq!(store.next_sequence(&s.id).unwrap(), 3);
    let counts = store.counts(&s.id).unwrap();
    assert_eq!(
        (counts.total, counts.ready, counts.picks, counts.rated),
        (2, 1, 1, 1)
    );

    c.state = CaptureState::Downloading {
        received: 10,
        total: Some(100),
    };
    store.save_capture(&c).unwrap();
    assert_eq!(
        store.capture(&c.id).unwrap().unwrap().state,
        CaptureState::Downloading {
            received: 10,
            total: Some(100)
        }
    );

    // Recovery: active sessions become interrupted on relaunch.
    store.mark_interrupted_sessions().unwrap();
    assert_eq!(
        store.interrupted_sessions().unwrap()[0].status,
        SessionStatus::Interrupted
    );
    s.status = SessionStatus::Ended;
    store.save_session(&s).unwrap();
    assert!(store.interrupted_sessions().unwrap().is_empty());

    store.delete_session(&s.id).unwrap();
    assert!(
        store.captures_in_session(&s.id).unwrap().is_empty(),
        "cascade delete"
    );
}

#[test]
fn export_jobs_looks_settings_and_cameras() {
    let store = SessionStore::in_memory().unwrap();
    let job = ExportJob::new(
        "s",
        ExportDestination::Photos,
        ExportOptions::default(),
        LookStack::none(),
        vec![ExportItem::new("a", "a.jpg", MediaKind::Jpeg, 1)],
    );
    store.save_export_job(&job).unwrap();
    assert_eq!(store.pending_export_jobs().unwrap().len(), 1);
    let mut done = job.clone();
    done.status = ExportStatus::Completed;
    store.save_export_job(&done).unwrap();
    assert_eq!(store.pending_export_jobs().unwrap().len(), 0);
    assert_eq!(store.export_jobs(Some("s")).unwrap().len(), 1);

    store.set_setting("cloud.url", Some("http://x"));
    assert_eq!(store.setting("cloud.url").as_deref(), Some("http://x"));
    store.set_setting("cloud.url", None);
    assert!(store.setting("cloud.url").is_none());

    let cam = camera();
    store.remember_camera(&cam, Some("192.168.1.2")).unwrap();
    store.remember_camera(&cam, None).unwrap();
    let known = store.known_cameras().unwrap();
    assert_eq!(known.len(), 1);
    assert_eq!(
        known[0].host.as_deref(),
        Some("192.168.1.2"),
        "nil host keeps the previous one"
    );

    let d = StoredFtpDestination::new("Studio NAS", "10.0.0.5", "brady");
    store.save_ftp_destination(&d).unwrap();
    assert_eq!(
        store.ftp_destinations().unwrap()[0].password_keychain_key,
        format!("ftp.{}", d.id)
    );

    let f =
        StoredFolderDestination::new("Shoots", vec![1, 2, 3, 255], FolderKind::CaptureOneSession);
    store.save_folder_destination(&f).unwrap();
    assert_eq!(store.folder_destination(&f.id).unwrap().unwrap(), f);
}

#[test]
fn reads_rows_written_by_ios() {
    // JSON as Swift's JSONEncoder writes it (dates since 2001, enums with
    // payloads as nested objects, a TransportKind raw value).
    let store = SessionStore::in_memory().unwrap();
    let session_json = r#"{"id":"S1","name":"From iPhone","createdAt":782000000,"status":"ended","destination":"both",
        "routing":{"jpeg":"photos","raw":"cloud","video":"files","autoExportPicks":false},"lookStrength":1,
        "showNewestCapture":true,"captureCount":2,"transport":"ricohHTTP"}"#;
    let s: ShootSession = serde_json::from_str(session_json).unwrap();
    assert_eq!(
        s.routing.raw,
        tether_library::RoutingTarget::Files,
        "unknown targets open as Files"
    );
    assert_eq!(s.transport, Some(TransportKind::RicohHttp));
    assert_eq!(s.created_at.timestamp(), 782_000_000 + 978_307_200);
    store.save_session(&s).unwrap();
    let job_json = r#"{"id":"J","sessionID":"S1","destination":{"ftp":{"destinationID":"nas"}},
        "options":{"applyLook":false,"jpegQuality":0.8,"includeRAW":true},"look":{"strength":1},
        "createdAt":782000000,"status":{"failed":{"_0":"1 of 2 failed"}},"attempts":1,
        "items":[{"id":"a","filename":"a.jpg","kind":"jpeg","bytes":1,"state":{"done":{"_0":"/nas/a.jpg"}}},
                 {"id":"b","filename":"b.jpg","kind":"jpeg","bytes":1,"state":{"done":{}}}]}"#;
    let job: ExportJob = serde_json::from_str(job_json).unwrap();
    assert_eq!(
        job.destination,
        ExportDestination::Ftp {
            destination_id: "nas".into()
        }
    );
    assert_eq!(
        job.options.naming.pattern, "{orig}",
        "options saved before interop fields decode with defaults"
    );
    assert!(job.options.embed_metadata);
    assert_eq!(job.status.key(), "failed");
    assert_eq!(job.progress(), 1.0);
    let back = serde_json::to_string(&job).unwrap();
    assert!(back.contains(r#""destination":{"ftp":{"destinationID":"nas"}}"#));
    assert!(back.contains(r#""state":{"done":{}}"#));
}

#[test]
fn migrates_an_older_database_in_place() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.sqlite");
    {
        // The first iOS schema: captures without camera_id / look_id.
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL, ended_at REAL,
                status TEXT NOT NULL, json TEXT NOT NULL);
             CREATE TABLE captures (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL, filename TEXT NOT NULL, kind TEXT NOT NULL, pair_key TEXT NOT NULL,
                rating INTEGER NOT NULL DEFAULT 0, flag TEXT NOT NULL DEFAULT 'none', color TEXT NOT NULL DEFAULT 'none',
                state TEXT NOT NULL, received_at REAL NOT NULL, json TEXT NOT NULL);",
        )
        .unwrap();
    }
    let path_s = path.to_string_lossy().to_string();
    let store = SessionStore::open(&path_s).unwrap();
    let mut s = ShootSession::new("Old");
    s.camera = Some(camera());
    store.save_session(&s).unwrap();
    let mut c = CaptureItem::new(&s.id, 1, 1, "A.JPG", MediaKind::Jpeg, 1, TransportKind::Usb);
    c.camera_id = Some("canon-1".into());
    c.state = CaptureState::Ready;
    store.save_capture(&c).unwrap();
    assert_eq!(
        store
            .collections()
            .unwrap()
            .iter()
            .filter(|c| c.is_built_in)
            .count(),
        6
    );
    drop(store);

    // Reopening is idempotent and keeps everything.
    let store = Arc::new(SessionStore::open(&path_s).unwrap());
    assert_eq!(store.collections().unwrap().len(), 6);
    assert_eq!(
        store.session(&s.id).unwrap().unwrap().camera.unwrap().model,
        "EOS R5"
    );
    assert_eq!(store.library_stats().unwrap().cameras, 1);
    let conn = Connection::open(&path).unwrap();
    let cols: Vec<String> = conn
        .prepare("PRAGMA table_info(captures)")
        .unwrap()
        .query_map([], |r| r.get::<_, String>(1))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert!(cols.contains(&"camera_id".to_string()) && cols.contains(&"look_id".to_string()));
    let mode: String = conn
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(mode, "wal");
}

#[test]
fn folder_kinds() {
    assert_eq!(
        StoredFolderDestination::detect_kind(&["Capture", "Selects", "Job.cosessiondb"]),
        FolderKind::CaptureOneSession
    );
    assert_eq!(
        StoredFolderDestination::detect_kind(&["Capture"]),
        FolderKind::Plain
    );
    let json = serde_json::to_string(&StoredFolderDestination::new(
        "x",
        vec![0, 1],
        FolderKind::LightroomAutoImport,
    ))
    .unwrap();
    assert!(
        json.contains(r#""bookmark":"AAE=""#) && json.contains(r#""kind":"lightroomAutoImport""#)
    );
}
