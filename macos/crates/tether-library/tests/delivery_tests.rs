//! The export queue end to end, the export renderer, previews and session
//! automations (Swift `ExportQueueTests`, the export part of `InteropTests`,
//! `AutomationScenarioTests`).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use image::{DynamicImage, ImageBuffer, Rgb};
use tether_library::delivery::{
    DirectoryFiles, ExportDestination, ExportEvent, ExportItem, ExportJob, ExportOptions,
    ExportQueue, ExportQueueConfig, ExportRenderer, ExportSink, HotFolder, ImageExportRenderer,
    RawOutput, Uploader,
};
use tether_library::interop::{
    exif, jpeg_xmp, FolderLayout, MetadataProfile, NamingTemplate, XmpPacket,
};
use tether_library::library::memory::{ExportMemory, SessionTemplate};
use tether_library::library::{
    AutomationEvent, AutomationRules, CaptureFilter, ExportDestinationKey, ReviewEditor,
    SessionAutomations, WorkspaceMemory,
};
use tether_library::looks::{CubeLut, LookResolver, LookStack};
use tether_library::previews::ImagePreviewGenerator;
use tether_library::store::{FolderKind, StoredFolderDestination, StoredFtpDestination};
use tether_library::{
    imaging, CaptureFlag, CaptureItem, CaptureState, MediaKind, Result, SessionStore, ShootSession,
};
use tether_types::TransportKind;
use tokio::sync::broadcast;

/// Copies deliveries into a folder, like the Mac "Files"/folder sink.
struct FolderSink {
    root: PathBuf,
}

#[async_trait::async_trait]
impl ExportSink for FolderSink {
    async fn deliver(
        &self,
        file: &Path,
        item: &ExportItem,
        _: &ExportDestination,
    ) -> Result<Option<String>> {
        let dest = self.root.join(item.delivered_relative_path());
        std::fs::create_dir_all(dest.parent().unwrap())?;
        std::fs::copy(file, &dest)?;
        Ok(Some(dest.to_string_lossy().to_string()))
    }

    async fn prepare_directories(&self, dirs: &[String], _: &ExportDestination) -> Result<()> {
        for d in dirs {
            std::fs::create_dir_all(self.root.join(d))?;
        }
        Ok(())
    }
}

#[derive(Default)]
struct FakeSink {
    delivered: Mutex<Vec<String>>,
    fail_for: Mutex<Vec<String>>,
}

#[async_trait::async_trait]
impl ExportSink for FakeSink {
    async fn deliver(
        &self,
        _: &Path,
        item: &ExportItem,
        _: &ExportDestination,
    ) -> Result<Option<String>> {
        if self.fail_for.lock().unwrap().contains(&item.id) {
            return Err(tether_library::Error::Delivery("nope".into()));
        }
        self.delivered.lock().unwrap().push(item.id.clone());
        Ok(Some(format!("local-{}", item.id)))
    }
}

async fn finished(rx: &mut broadcast::Receiver<ExportEvent>) -> ExportJob {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if let Ok(ExportEvent::Finished(j)) = rx.recv().await {
                return j;
            }
        }
    })
    .await
    .expect("the job finishes")
}

fn jpeg_bytes(w: u32, h: u32) -> Vec<u8> {
    imaging::encode_jpeg(
        &DynamicImage::ImageRgb8(ImageBuffer::from_pixel(w, h, Rgb([180u8, 120, 90]))),
        0.9,
    )
    .unwrap()
}

struct Env {
    store: Arc<SessionStore>,
    root: tempfile::TempDir,
}

impl Env {
    fn new() -> Self {
        Self {
            store: Arc::new(SessionStore::in_memory().unwrap()),
            root: tempfile::tempdir().unwrap(),
        }
    }

    fn files(&self) -> Arc<DirectoryFiles> {
        Arc::new(DirectoryFiles::new(self.root.path()))
    }

    /// Writes the original under `<session>/originals/` and saves the capture.
    fn add(
        &self,
        session: &ShootSession,
        seq: i64,
        name: &str,
        kind: MediaKind,
        data: &[u8],
    ) -> CaptureItem {
        let rel = format!("{}/originals/{name}", session.directory_name());
        let abs = self.root.path().join(&rel);
        std::fs::create_dir_all(abs.parent().unwrap()).unwrap();
        std::fs::write(&abs, data).unwrap();
        let mut c = CaptureItem::new(
            &session.id,
            seq,
            seq as u32,
            name,
            kind,
            data.len() as i64,
            TransportKind::Usb,
        );
        c.relative_path = Some(rel);
        c.state = CaptureState::Ready;
        self.store.save_capture(&c).unwrap();
        c
    }
}

#[tokio::test]
async fn job_runs_persists_and_retries() {
    let env = Env::new();
    let shoot = ShootSession::new("Export");
    env.store.save_session(&shoot).unwrap();
    let mut caps: Vec<CaptureItem> = (1..=3)
        .map(|i| {
            env.add(
                &shoot,
                i,
                &format!("IMG_{i}.JPG"),
                MediaKind::Jpeg,
                &[1, 2, 3],
            )
        })
        .collect();
    let mut raw = CaptureItem::new(
        &shoot.id,
        4,
        4,
        "IMG_1.CR3",
        MediaKind::Raw,
        3,
        TransportKind::Usb,
    );
    raw.state = CaptureState::Ready;
    env.store.save_capture(&raw).unwrap();
    caps.push(raw);

    let sink = Arc::new(FakeSink::default());
    sink.fail_for.lock().unwrap().push(caps[1].id.clone());
    let looks = Arc::new(LookResolver::new(env.store.clone(), None));
    let queue = ExportQueue::new(ExportQueueConfig::new(
        env.store.clone(),
        env.files(),
        sink.clone(),
        looks,
    ));
    let job = queue.make_job(
        &shoot,
        &caps,
        ExportDestination::Photos,
        ExportOptions::default(),
        LookStack::none(),
    );
    assert_eq!(job.items.len(), 3, "RAW excluded");
    let mut rx = queue.subscribe();
    queue.enqueue(&job).unwrap();
    let f = finished(&mut rx).await;
    assert_eq!(f.status.key(), "failed");
    assert_eq!(f.failed_items().len(), 1);
    assert_eq!(sink.delivered.lock().unwrap().len(), 2);
    assert_eq!(
        env.store.export_jobs(Some(&shoot.id)).unwrap()[0]
            .status
            .key(),
        "failed"
    );

    sink.fail_for.lock().unwrap().clear();
    queue.retry(&job.id).unwrap();
    let f = finished(&mut rx).await;
    assert_eq!(f.status.key(), "completed");
    assert_eq!(
        sink.delivered.lock().unwrap().len(),
        3,
        "only the failed item re-ran"
    );
    assert_eq!(f.progress(), 1.0);
    assert_eq!(
        env.store
            .count_matching(&CaptureFilter {
                exported_to: Some(ExportDestinationKey::Photos),
                ..Default::default()
            })
            .unwrap(),
        3
    );
}

#[tokio::test]
async fn export_writes_capture_one_tree_sidecars_embedded_xmp_and_manifest() {
    let env = Env::new();
    let memory = Arc::new(WorkspaceMemory::new(env.store.clone()));
    memory.set(
        WorkspaceMemory::METADATA_PROFILE,
        &MetadataProfile {
            creator: Some("Brady Jordan".into()),
            write_sidecars_for_jpeg: true,
            ..Default::default()
        },
    );
    let out = tempfile::tempdir().unwrap();
    let shoot = ShootSession::new("AW26");
    env.store.save_session(&shoot).unwrap();
    let jpeg_data = vec![0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x00, 0xFF, 0xD9];
    let mut jpeg = env.add(&shoot, 1, "IMG_0001.JPG", MediaKind::Jpeg, &jpeg_data);
    let mut raw = env.add(&shoot, 2, "IMG_0001.CR3", MediaKind::Raw, &[1, 2, 3]);
    for c in [&mut jpeg, &mut raw] {
        c.flag = CaptureFlag::Pick;
        c.rating = 5;
        env.store.save_capture(c).unwrap();
    }
    env.store
        .add_tags(&["hero"], &[jpeg.id.clone(), raw.id.clone()])
        .unwrap();

    let mut cfg = ExportQueueConfig::new(
        env.store.clone(),
        env.files(),
        Arc::new(FolderSink {
            root: out.path().to_path_buf(),
        }),
        Arc::new(LookResolver::new(env.store.clone(), None)),
    );
    cfg.memory = Some(memory);
    let queue = ExportQueue::new(cfg);
    let options = ExportOptions {
        include_raw: true,
        naming: NamingTemplate::new("{session}_{seq:3}"),
        layout: FolderLayout::CaptureOne,
        write_manifest: true,
        ..Default::default()
    };
    let job = queue.make_job(
        &shoot,
        &[jpeg.clone(), raw.clone()],
        ExportDestination::Files,
        options,
        LookStack::none(),
    );
    assert_eq!(
        job.items
            .iter()
            .map(|i| i.delivered_relative_path())
            .collect::<Vec<_>>(),
        ["AW26/Selects/AW26_001.JPG", "AW26/Selects/AW26_001.CR3"],
        "RAW+JPEG twins keep one base name so Lightroom / Capture One re-pair them"
    );
    let mut rx = queue.subscribe();
    queue.enqueue(&job).unwrap();
    assert_eq!(finished(&mut rx).await.status.key(), "completed");

    let p = |r: &str| out.path().join(r);
    assert!(p("AW26/Selects/AW26_001.JPG").exists());
    assert!(p("AW26/Selects/AW26_001.CR3").exists());
    assert!(
        p("AW26/Selects/AW26_001.xmp").exists(),
        "one sidecar for the pair"
    );
    assert!(
        !p("AW26/Selects/AW26_001-1.xmp").exists(),
        "no duplicate sidecar"
    );
    assert!(p("AW26/Output/AW26-manifest.json").exists());
    assert!(p("AW26/Output/AW26-manifest.csv").exists());
    assert!(
        p("AW26/Trash").is_dir() && p("AW26/Capture").is_dir(),
        "Capture One scaffold"
    );
    let stamped = std::fs::read(p("AW26/Selects/AW26_001.JPG")).unwrap();
    let packet = jpeg_xmp::extract(&stamped).unwrap();
    assert_eq!(packet.rating, Some(5));
    assert!(packet.pick);
    assert_eq!(packet.creator.as_deref(), Some("Brady Jordan"));
    assert!(packet.keywords.contains(&"hero".to_string()));
    let side = XmpPacket::parse(&std::fs::read(p("AW26/Selects/AW26_001.xmp")).unwrap()).unwrap();
    assert_eq!(side.rating, Some(5));
    assert_eq!(
        env.store
            .count_matching(&CaptureFilter {
                exported_to: Some(ExportDestinationKey::Files),
                ..Default::default()
            })
            .unwrap(),
        2,
        "companions are not recorded as exports"
    );
}

struct FakeFtp {
    uploads: Mutex<Vec<(String, usize)>>,
}

#[async_trait::async_trait]
impl Uploader for FakeFtp {
    async fn upload(&self, data: Vec<u8>, remote_path: &str) -> Result<()> {
        self.uploads
            .lock()
            .unwrap()
            .push((remote_path.to_string(), data.len()));
        Ok(())
    }
}

#[tokio::test]
async fn ftp_uploads_through_the_uploader_trait_and_hot_folder_refreshes_sidecars() {
    let env = Env::new();
    let shoot = ShootSession::new("Press");
    env.store.save_session(&shoot).unwrap();
    let raw = env.add(&shoot, 1, "DSC0001.ARW", MediaKind::Raw, &[1, 2, 3, 4]);
    let dest = StoredFtpDestination {
        remote_directory: "/incoming".into(),
        ..StoredFtpDestination::new("Desk", "10.0.0.2", "me")
    };
    env.store.save_ftp_destination(&dest).unwrap();
    let ftp = Arc::new(FakeFtp {
        uploads: Mutex::new(Vec::new()),
    });
    let mut cfg = ExportQueueConfig::new(
        env.store.clone(),
        env.files(),
        Arc::new(FakeSink::default()),
        Arc::new(LookResolver::new(env.store.clone(), None)),
    );
    let f2 = ftp.clone();
    cfg.uploaders = Some(Arc::new(move |_: &StoredFtpDestination| {
        Some(f2.clone() as Arc<dyn Uploader>)
    }));
    let queue = ExportQueue::new(cfg);
    let folder = StoredFolderDestination::new("C1", vec![], FolderKind::CaptureOneSession);
    let options = HotFolder::options(&folder, false);
    assert_eq!(options.layout, FolderLayout::CaptureOneSessionRoot);
    let job = queue.make_job(
        &shoot,
        std::slice::from_ref(&raw),
        ExportDestination::Ftp {
            destination_id: dest.id.clone(),
        },
        options,
        LookStack::none(),
    );
    let mut rx = queue.subscribe();
    queue.enqueue(&job).unwrap();
    let done = finished(&mut rx).await;
    assert_eq!(done.status.key(), "completed", "{:?}", done.items);
    let uploads = ftp.uploads.lock().unwrap().clone();
    assert_eq!(
        uploads.iter().map(|u| u.0.as_str()).collect::<Vec<_>>(),
        [
            "/incoming/Capture/DSC0001.xmp",
            "/incoming/Capture/DSC0001.ARW"
        ],
        "sidecar first"
    );
    assert_eq!(
        env.store.export_history(&raw.id).unwrap()[0]
            .remote_id
            .as_deref(),
        Some("/incoming/Capture/DSC0001.ARW")
    );

    // Metadata-only refresh writes just the sidecar again.
    let refresh = queue.make_job(
        &shoot,
        &[raw],
        ExportDestination::Ftp {
            destination_id: dest.id,
        },
        HotFolder::options(&folder, true),
        LookStack::none(),
    );
    queue.enqueue(&refresh).unwrap();
    finished(&mut rx).await;
    assert_eq!(ftp.uploads.lock().unwrap().len(), 3);
    assert!(ftp.uploads.lock().unwrap()[2].0.ends_with(".xmp"));
}

#[tokio::test]
async fn renderer_applies_looks_sizes_and_keeps_exif() {
    let dir = tempfile::tempdir().unwrap();
    let mut data = jpeg_bytes(400, 300);
    let seg = exif::minimal_jpeg_exif("Canon", "EOS R5", chrono::Utc::now(), 0.01, 4.0, 200);
    data = imaging::insert_segment(&data, &seg);
    let original = dir.path().join("IMG_0001.JPG");
    std::fs::write(&original, &data).unwrap();
    let renderer = ImageExportRenderer {
        temp_dir: dir.path().to_path_buf(),
        ..Default::default()
    };
    let item = ExportItem::new("a", "IMG_0001.JPG", MediaKind::Jpeg, data.len() as i64);
    // Untouched JPEG goes out byte-for-byte.
    let same = renderer
        .render(&original, &item, None, &ExportOptions::default())
        .await
        .unwrap();
    assert_eq!(same, original);
    let mut t = Vec::new();
    for b in 0..2 {
        for g in 0..2 {
            for r in 0..2 {
                t.extend([1.0 - r as f32, 1.0 - g as f32, 1.0 - b as f32]);
            }
        }
    }
    let invert = CubeLut::new(2, "Invert", t).unwrap();
    let opts = ExportOptions {
        max_long_edge: Some(200),
        filename_prefix: Some("web_".into()),
        ..Default::default()
    };
    let out = renderer
        .render(&original, &item, Some(&invert), &opts)
        .await
        .unwrap();
    assert_eq!(out.file_name().unwrap(), "web_IMG_0001.jpg");
    let bytes = std::fs::read(&out).unwrap();
    let img = imaging::decode(&bytes, Some("x.jpg"), None)
        .unwrap()
        .to_rgb8();
    assert_eq!((img.width(), img.height()), (200, 150));
    let px = img.get_pixel(100, 75);
    assert!(px[2] > px[0], "inverted: blue now dominates {px:?}");
    assert_eq!(exif::read(&bytes).unwrap().model.as_deref(), Some("EOS R5"));
    // 16-bit TIFF output for a RAW (here: its embedded preview, or Core Image).
    let mut raw = b"II*\0\x08\0\0\0\0\0".to_vec();
    raw.extend(jpeg_bytes(320, 240));
    let raw_path = dir.path().join("A.ARW");
    std::fs::write(&raw_path, &raw).unwrap();
    let raw_item = ExportItem::new("r", "A.ARW", MediaKind::Raw, raw.len() as i64);
    let tiff = renderer
        .render(
            &raw_path,
            &raw_item,
            None,
            &ExportOptions {
                raw_output: RawOutput::Tiff16,
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(tiff.extension().unwrap(), "tif");
    let back = imaging::decode(&std::fs::read(&tiff).unwrap(), Some("x.tif"), None).unwrap();
    assert_eq!(back.color(), image::ColorType::Rgb16);
}

#[test]
fn raw_previews_use_the_embedded_jpeg() {
    let mut raw = b"II*\0\x08\0\0\0\0\0".to_vec();
    raw.extend(jpeg_bytes(160, 120));
    raw.extend(jpeg_bytes(1200, 800));
    let generator = ImagePreviewGenerator {
        proxy_max_pixels: 512,
        ..Default::default()
    };
    let out = generator.make_previews_blocking(&raw, MediaKind::Raw, "IMG_0001.ARW");
    assert_eq!((out.width, out.height), (1200, 800));
    let proxy = imaging::decode(&out.proxy_jpeg.unwrap(), Some("p.jpg"), None).unwrap();
    assert_eq!(proxy.width(), 512);
    assert!(out.thumbnail_jpeg.is_some());
}

// MARK: Automations

#[tokio::test]
async fn template_tags_collection_and_auto_export_picks() {
    let env = Env::new();
    let store = env.store.clone();
    let memory = Arc::new(WorkspaceMemory::new(store.clone()));
    let editor = Arc::new(ReviewEditor::new(store.clone(), Some(memory.clone())));
    let sink = Arc::new(FakeSink::default());
    let queue = ExportQueue::new(ExportQueueConfig::new(
        store.clone(),
        env.files(),
        sink.clone(),
        Arc::new(LookResolver::new(store.clone(), None)),
    ));
    let mut shoot = ShootSession::new("Headshots");
    shoot.routing.auto_export_picks = true;
    store.save_session(&shoot).unwrap();
    let client_set = editor
        .create_collection(
            "Headshots delivery",
            &[],
            "rectangle.stack",
            Default::default(),
        )
        .unwrap();
    let rules = AutomationRules {
        tags: vec!["headshots".into(), "Studio B".into()],
        add_to_collection_id: Some(client_set.id.clone()),
        auto_export_picks: true,
        debounce: 0.15,
        ..Default::default()
    };
    let auto = SessionAutomations::new(
        shoot.clone(),
        rules,
        store.clone(),
        editor.clone(),
        Some(queue.clone()),
        memory.clone(),
    );
    auto.attach();
    let mut auto_rx = auto.subscribe();
    let mut queue_rx = queue.subscribe();

    let land = |n: i64| {
        let c = env.add(
            &shoot,
            n,
            &format!("IMG_{n}.JPG"),
            MediaKind::Jpeg,
            &jpeg_bytes(8, 8),
        );
        auto.capture_ready(&c);
        c
    };
    let a = land(1);
    let b = land(2);
    land(3);
    assert_eq!(
        store.tags(&a.id).unwrap(),
        ["headshots", "studio-b"],
        "template tags applied, normalised"
    );
    assert_eq!(
        store.count_in_collection(&client_set).unwrap(),
        3,
        "every frame joined the template's collection"
    );

    // Two picks in quick succession → one export job with two items.
    editor
        .flag(std::slice::from_ref(&a.id), CaptureFlag::Pick)
        .unwrap();
    editor
        .flag(std::slice::from_ref(&b.id), CaptureFlag::Pick)
        .unwrap();
    let queued = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Ok(AutomationEvent::ExportQueued(j)) = auto_rx.recv().await {
                return j;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(queued.items.len(), 2);
    assert_eq!(queued.destination, ExportDestination::Photos);
    finished(&mut queue_rx).await;
    let mut delivered = sink.delivered.lock().unwrap().clone();
    delivered.sort();
    let mut expected = vec![a.id.clone(), b.id.clone()];
    expected.sort();
    assert_eq!(delivered, expected);
    assert_eq!(
        store
            .count_matching(&CaptureFilter {
                exported_to: Some(ExportDestinationKey::Photos),
                ..Default::default()
            })
            .unwrap(),
        2
    );

    // Un-pick and re-pick does not export twice.
    editor
        .flag(std::slice::from_ref(&a.id), CaptureFlag::None)
        .unwrap();
    editor
        .flag(std::slice::from_ref(&a.id), CaptureFlag::Pick)
        .unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(auto.pending_pick_count(), 0);
    assert_eq!(sink.delivered.lock().unwrap().len(), 2);

    // Ending the session teaches memory.
    auto.session_ended(shoot.clone());
    assert!(
        memory
            .get(WorkspaceMemory::SESSION_DEFAULTS)
            .auto_export_picks
    );
    auto.stop();
}

#[test]
fn rules_come_from_template_and_last_export() {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    let memory = WorkspaceMemory::new(store);
    let mut e = ExportMemory {
        destination: ExportDestination::Files,
        ..Default::default()
    };
    e.options.include_raw = true;
    memory.set(WorkspaceMemory::LAST_EXPORT, &e);
    let mut t = SessionTemplate::new("Lookbook");
    t.tags = vec!["lookbook".into()];
    t.add_to_collection_id = Some("c1".into());
    let mut s = ShootSession::new("x");
    s.routing.auto_export_picks = true;
    let r = AutomationRules::from_template(Some(&t), &s, &memory);
    assert_eq!(r.tags, ["lookbook"]);
    assert_eq!(r.add_to_collection_id.as_deref(), Some("c1"));
    assert!(r.auto_export_picks);
    assert_eq!(r.auto_export_destination, ExportDestination::Files);
    assert!(r.auto_export_options.include_raw);
    let mut d = memory.get(WorkspaceMemory::SESSION_DEFAULTS);
    d.tags = vec!["default".into()];
    memory.set(WorkspaceMemory::SESSION_DEFAULTS, &d);
    assert_eq!(
        AutomationRules::from_template(None, &s, &memory).tags,
        ["default"]
    );
}

/// Develops a real RAW (or decodes a HEIF) through Core Image and encodes
/// every export format. Needs a sample: `TETHER_SAMPLE_RAW=/path/IMG.CR3
/// cargo test -p tether-library -- --ignored core_image`.
#[cfg(target_os = "macos")]
#[test]
#[ignore]
fn core_image_develops_a_real_raw() {
    let Ok(path) = std::env::var("TETHER_SAMPLE_RAW") else {
        return;
    };
    let data = std::fs::read(&path).unwrap();
    let name = Path::new(&path)
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_string();
    let t0 = std::time::Instant::now();
    let img = imaging::decode(&data, Some(&name), Some(1600)).unwrap();
    eprintln!(
        "{name}: decoded to {}x{} {:?} in {:?}",
        img.width(),
        img.height(),
        img.color(),
        t0.elapsed()
    );
    assert_eq!(img.width().max(img.height()), 1600);
    let heif = imaging::encode_heif(&img, 0.8).expect("HEIF encodes");
    assert!(heif.len() > 1000 && &heif[4..8] == b"ftyp");
    let back = imaging::decode(&heif, Some("x.heic"), None).unwrap();
    assert_eq!(back.width(), img.width());
    let preview = ImagePreviewGenerator::default().make_previews_blocking(
        &data,
        MediaKind::from_filename(&name),
        &name,
    );
    eprintln!(
        "previews: {}x{}, proxy {} bytes",
        preview.width,
        preview.height,
        preview.proxy_jpeg.as_ref().map_or(0, Vec::len)
    );
    assert!(preview.proxy_jpeg.is_some() && preview.thumbnail_jpeg.is_some());
}
