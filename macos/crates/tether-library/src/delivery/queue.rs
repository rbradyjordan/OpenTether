//! The resumable export queue (`Delivery/ExportQueue.swift`).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

use crate::capture_item::{CaptureItem, MediaKind, ShootSession};
use crate::delivery::job::{
    ExportDestination, ExportItem, ExportJob, ExportOptions, ExportStatus, ItemState, RawOutput,
};
use crate::delivery::ExportError;
use crate::interop::naming::{NamingContext, SessionManifest};
use crate::interop::xmp::{jpeg_xmp, MetadataProfile, XmpPacket};
use crate::library::{ExportDestinationKey, WorkspaceMemory};
use crate::looks::{CubeLut, LookResolver, LookStack};
use crate::store::{SessionStore, StoredFtpDestination};
use crate::{util, Error, Result};

/// Platform hook: saving to Photos / a folder / the share sheet. The app
/// (session crate) supplies it; tests use fakes.
#[async_trait::async_trait]
pub trait ExportSink: Send + Sync {
    /// Delivers one file; returns a stable identifier (Photos local
    /// identifier, file path…).
    async fn deliver(
        &self,
        file: &Path,
        item: &ExportItem,
        destination: &ExportDestination,
    ) -> Result<Option<String>>;

    /// Create empty folders up front (Capture One expects its four even
    /// when one stays empty). Default: nothing.
    async fn prepare_directories(
        &self,
        _directories: &[String],
        _destination: &ExportDestination,
    ) -> Result<()> {
        Ok(())
    }
}

/// Produces the bytes to export for one capture: the original, or a
/// re-rendered JPEG / developed RAW. Returns the file to deliver.
#[async_trait::async_trait]
pub trait ExportRenderer: Send + Sync {
    async fn render(
        &self,
        original: &Path,
        item: &ExportItem,
        look: Option<&CubeLut>,
        options: &ExportOptions,
    ) -> Result<PathBuf>;
}

/// Exports originals untouched.
#[derive(Debug, Clone, Copy, Default)]
pub struct PassthroughRenderer;

#[async_trait::async_trait]
impl ExportRenderer for PassthroughRenderer {
    async fn render(
        &self,
        original: &Path,
        _: &ExportItem,
        _: Option<&CubeLut>,
        _: &ExportOptions,
    ) -> Result<PathBuf> {
        Ok(original.to_path_buf())
    }
}

/// FTP upload, implemented by the session crate over `tether-net`'s client.
#[async_trait::async_trait]
pub trait Uploader: Send + Sync {
    /// Uploads `data` to `remote_path` (absolute on the server), creating
    /// folders as needed.
    async fn upload(&self, data: Vec<u8>, remote_path: &str) -> Result<()>;
}

/// Makes an uploader for a saved FTP destination (`None` if it can't, e.g.
/// no password in the Keychain).
pub trait UploaderFactory: Send + Sync {
    fn uploader(&self, destination: &StoredFtpDestination) -> Option<Arc<dyn Uploader>>;
}

impl<F> UploaderFactory for F
where
    F: Fn(&StoredFtpDestination) -> Option<Arc<dyn Uploader>> + Send + Sync,
{
    fn uploader(&self, destination: &StoredFtpDestination) -> Option<Arc<dyn Uploader>> {
        self(destination)
    }
}

/// Where capture files live: relative paths (as stored on captures) to
/// absolute paths. The session crate's capture cache implements it.
pub trait CaptureFiles: Send + Sync {
    fn path_for(&self, relative: &str) -> Result<PathBuf>;
}

/// [`CaptureFiles`] over a storage root, with the iOS path rules (no
/// absolute paths, no `..`, no empty components).
#[derive(Debug, Clone)]
pub struct DirectoryFiles {
    pub root: PathBuf,
}

impl DirectoryFiles {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn validate(relative: &str) -> Result<&str> {
        let bad = relative.is_empty()
            || relative.starts_with('/')
            || relative.contains('\\')
            || relative.contains('\0')
            || relative.split('/').any(|c| c.is_empty() || c == "..");
        if bad {
            Err(Error::InvalidPath(relative.to_string()))
        } else {
            Ok(relative)
        }
    }
}

impl CaptureFiles for DirectoryFiles {
    fn path_for(&self, relative: &str) -> Result<PathBuf> {
        Ok(self.root.join(Self::validate(relative)?))
    }
}

/// What the queue reports.
#[derive(Debug, Clone, PartialEq)]
pub enum ExportEvent {
    Updated(ExportJob),
    Finished(ExportJob),
}

/// Everything the queue needs.
pub struct ExportQueueConfig {
    pub store: Arc<SessionStore>,
    pub files: Arc<dyn CaptureFiles>,
    pub sink: Arc<dyn ExportSink>,
    pub renderer: Arc<dyn ExportRenderer>,
    pub looks: Arc<LookResolver>,
    pub memory: Option<Arc<WorkspaceMemory>>,
    pub uploaders: Option<Arc<dyn UploaderFactory>>,
    /// Where rendered files and companions are staged.
    pub temp_dir: PathBuf,
}

impl ExportQueueConfig {
    /// Pass-through renderer, no memory, no FTP, the system temp folder.
    pub fn new(
        store: Arc<SessionStore>,
        files: Arc<dyn CaptureFiles>,
        sink: Arc<dyn ExportSink>,
        looks: Arc<LookResolver>,
    ) -> Self {
        Self {
            store,
            files,
            sink,
            renderer: Arc::new(PassthroughRenderer),
            looks,
            memory: None,
            uploaders: None,
            temp_dir: std::env::temp_dir(),
        }
    }
}

struct QueueInner {
    cfg: ExportQueueConfig,
    running: Mutex<bool>,
    paused: AtomicBool,
    events: broadcast::Sender<ExportEvent>,
}

/// Resumable export queue. Persists every job and item state through the
/// store; [`ExportQueue::resume`] on launch continues interrupted jobs. One
/// job at a time, items sequential (Photos and FTP both prefer that).
/// Cloning shares the queue.
#[derive(Clone)]
pub struct ExportQueue {
    inner: Arc<QueueInner>,
}

impl ExportQueue {
    pub fn new(cfg: ExportQueueConfig) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            inner: Arc::new(QueueInner {
                cfg,
                running: Mutex::new(false),
                paused: AtomicBool::new(false),
                events,
            }),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ExportEvent> {
        self.inner.events.subscribe()
    }

    // MARK: Enqueue

    /// Build a job from captures. RAW is skipped unless `include_raw`.
    /// Names and folders are resolved now so the UI can preview them;
    /// RAW+JPEG twins share one base name (rendered from the pair's first
    /// sequence number) so Lightroom and Capture One stack them again.
    pub fn make_job(
        &self,
        session: &ShootSession,
        captures: &[CaptureItem],
        destination: ExportDestination,
        options: ExportOptions,
        look: LookStack,
    ) -> ExportJob {
        let store = &self.inner.cfg.store;
        let mut items: Vec<ExportItem> = captures
            .iter()
            .filter(|c| {
                c.state.is_ready()
                    && (c.kind != MediaKind::Raw || options.include_raw)
                    && c.kind.is_still()
            })
            .map(|c| ExportItem::new(c.id.clone(), c.filename.clone(), c.kind, c.bytes))
            .collect();
        let caps: HashMap<&str, &CaptureItem> =
            captures.iter().map(|c| (c.id.as_str(), c)).collect();
        let mut pair_sequence: HashMap<String, i64> = HashMap::new();
        for c in captures {
            let key = format!(
                "{}/{}",
                c.session_id,
                CaptureItem::pair_key_for(&c.filename)
            );
            let e = pair_sequence.entry(key).or_insert(c.sequence);
            *e = (*e).min(c.sequence);
        }
        let camera = session
            .camera
            .as_ref()
            .map(|c| c.display_name().to_string());
        let mut used_bases: HashSet<String> = HashSet::new();
        let mut pair_base: HashMap<String, String> = HashMap::new();
        let mut used_names: HashSet<String> = HashSet::new();
        for item in items.iter_mut() {
            let Some(c) = caps.get(item.id.as_str()) else {
                continue;
            };
            let dir = options.layout.directory(c, Some(&session.name), None);
            let ext = (if c.kind == MediaKind::Raw {
                options.raw_output.file_extension()
            } else {
                None
            })
            .unwrap_or_else(|| util::path_extension(&c.filename))
            .to_string();
            let pair_key = format!(
                "{}/{}",
                c.session_id,
                CaptureItem::pair_key_for(&c.filename)
            );
            let slot = format!("{}|{}", dir.to_lowercase(), pair_key);
            let base = match pair_base.get(&slot) {
                Some(shared) => shared.clone(),
                None => {
                    let tags = store.tags(&c.id).unwrap_or_default();
                    let rendered = options.naming.render(
                        c,
                        &NamingContext {
                            session_name: Some(&session.name),
                            index: pair_sequence.get(&pair_key).copied().unwrap_or(c.sequence),
                            camera: camera.as_deref(),
                            tags: &tags,
                            client: session.workflow_tag.as_deref(),
                            now: None,
                        },
                    );
                    let mut base = rendered.clone();
                    let mut n = 1;
                    while used_bases.contains(&format!("{dir}/{base}").to_lowercase()) {
                        n += 1;
                        base = format!("{rendered}-{n}");
                    }
                    used_bases.insert(format!("{dir}/{base}").to_lowercase());
                    pair_base.insert(slot, base.clone());
                    base
                }
            };
            let with_ext = |b: &str| {
                if ext.is_empty() {
                    b.to_string()
                } else {
                    format!("{b}.{ext}")
                }
            };
            let mut name = with_ext(&base);
            let mut n = 1;
            while used_names.contains(&format!("{dir}/{name}").to_lowercase()) {
                n += 1;
                name = with_ext(&format!("{base}-{n}"));
            }
            used_names.insert(format!("{dir}/{name}").to_lowercase());
            item.export_filename = Some(name);
            item.export_directory = Some(dir);
        }
        ExportJob::new(session.id.clone(), destination, options, look, items)
    }

    /// Persists the job and starts the worker (needs a Tokio runtime; without
    /// one the job waits for [`ExportQueue::resume`]).
    pub fn enqueue(&self, job: &ExportJob) -> Result<()> {
        self.inner.cfg.store.save_export_job(job)?;
        let _ = self.inner.events.send(ExportEvent::Updated(job.clone()));
        self.kick();
        Ok(())
    }

    /// Stops after the item in flight; the job is left `Paused`.
    pub fn pause(&self) {
        self.inner.paused.store(true, Ordering::SeqCst);
    }

    /// Continues paused and interrupted jobs (call on launch too).
    pub fn resume(&self) {
        self.inner.paused.store(false, Ordering::SeqCst);
        self.kick();
    }

    pub fn jobs(&self, session_id: Option<&str>) -> Result<Vec<ExportJob>> {
        self.inner.cfg.store.export_jobs(session_id)
    }

    /// Re-queues a job's failed items (done ones are not repeated).
    pub fn retry(&self, job_id: &str) -> Result<()> {
        let Some(mut job) = self.inner.cfg.store.export_job(job_id)? else {
            return Ok(());
        };
        for item in job.items.iter_mut().filter(|i| i.is_failed()) {
            item.state = ItemState::Pending;
        }
        job.status = ExportStatus::Queued;
        self.inner.cfg.store.save_export_job(&job)?;
        let _ = self.inner.events.send(ExportEvent::Updated(job));
        self.kick();
        Ok(())
    }

    // MARK: Worker

    fn kick(&self) {
        if self.inner.paused.load(Ordering::SeqCst) {
            return;
        }
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        {
            let mut running = self.inner.running.lock().unwrap_or_else(|e| e.into_inner());
            if *running {
                return;
            }
            *running = true;
        }
        let this = self.clone();
        handle.spawn(async move { this.drain().await });
    }

    async fn drain(&self) {
        loop {
            let next = {
                let mut running = self.inner.running.lock().unwrap_or_else(|e| e.into_inner());
                let next = if self.inner.paused.load(Ordering::SeqCst) {
                    None
                } else {
                    self.inner
                        .cfg
                        .store
                        .pending_export_jobs()
                        .ok()
                        .and_then(|j| j.into_iter().next())
                };
                if next.is_none() {
                    *running = false;
                }
                next
            };
            match next {
                Some(job) => self.run(job).await,
                None => return,
            }
        }
    }

    fn save(&self, job: &ExportJob) {
        let _ = self.inner.cfg.store.save_export_job(job);
        let _ = self.inner.events.send(ExportEvent::Updated(job.clone()));
    }

    fn profile(&self) -> MetadataProfile {
        self.inner
            .cfg
            .memory
            .as_ref()
            .map(|m| m.get(WorkspaceMemory::METADATA_PROFILE))
            .unwrap_or_default()
    }

    async fn run(&self, input: ExportJob) {
        let mut job = input;
        job.status = ExportStatus::Running;
        job.attempts += 1;
        self.save(&job);
        let lut = self.inner.cfg.looks.lut(&job.look).await.ok().flatten();
        let store = &self.inner.cfg.store;
        let session_name = store
            .session(&job.session_id)
            .ok()
            .flatten()
            .map(|s| s.name);

        if job.destination.delivers_files()
            && !matches!(job.destination, ExportDestination::Ftp { .. })
        {
            let scaffold = job.options.layout.scaffold(session_name.as_deref());
            if !scaffold.is_empty() {
                let _ = self
                    .inner
                    .cfg
                    .sink
                    .prepare_directories(&scaffold, &job.destination)
                    .await;
            }
        }
        for idx in 0..job.items.len() {
            if self.inner.paused.load(Ordering::SeqCst) {
                job.status = ExportStatus::Paused;
                self.save(&job);
                return;
            }
            if job.items[idx].is_done() || job.items[idx].is_failed() {
                continue;
            }
            if let Err(e) = self
                .export(idx, &mut job, lut.as_ref(), session_name.as_deref())
                .await
            {
                job.items[idx].state = ItemState::Failed(e.to_string());
                self.save(&job);
            }
        }
        let failed = job.failed_items().len();
        job.status = if failed == 0 {
            ExportStatus::Completed
        } else {
            ExportStatus::Failed(format!("{failed} of {} failed", job.items.len()))
        };
        if failed == 0 {
            self.write_manifest_if_wanted(&job).await;
        }
        self.save(&job);
        let _ = self.inner.events.send(ExportEvent::Finished(job));
    }

    fn temp_path(&self, name: &str) -> PathBuf {
        self.inner.cfg.temp_dir.join(format!(
            "tether-{}-{}",
            uuid::Uuid::new_v4(),
            util::last_path_component(name)
        ))
    }

    async fn export(
        &self,
        idx: usize,
        job: &mut ExportJob,
        lut: Option<&CubeLut>,
        session_name: Option<&str>,
    ) -> Result<()> {
        let cfg = &self.inner.cfg;
        let item = job.items[idx].clone();
        let capture = cfg.store.capture(&item.id)?;
        let Some((capture, rel)) = capture.and_then(|c| c.relative_path.clone().map(|r| (c, r)))
        else {
            job.items[idx].state = ItemState::Skipped("original missing".into());
            self.save(job);
            return Ok(());
        };
        job.items[idx].state = ItemState::Uploading(0.0);
        self.save(job);
        let profile = self.profile();
        let tags = cfg.store.tags(&capture.id)?;
        let packet = XmpPacket::from_capture(&capture, &tags, &profile, session_name);
        let base_of = |i: &ExportItem| {
            util::delete_path_extension(i.export_filename.as_deref().unwrap_or(&i.filename))
                .to_string()
        };

        if job.options.metadata_only {
            // Sidecar refresh only; the photo is already where it belongs.
            self.deliver_companion(
                &packet.data(),
                &format!("{}.xmp", base_of(&item)),
                item.export_directory.as_deref(),
                job,
            )
            .await?;
            job.items[idx].state = ItemState::Done(None);
            self.save(job);
            return Ok(());
        }

        let original = cfg.files.path_for(&rel)?;
        let keep_original_raw =
            item.kind == MediaKind::Raw && job.options.raw_output == RawOutput::Original;
        let mut rendered = if keep_original_raw {
            original.clone()
        } else {
            let look = if job.options.apply_look { lut } else { None };
            cfg.renderer
                .render(&original, &item, look, &job.options)
                .await?
        };
        let delivers_jpeg = item.kind == MediaKind::Jpeg
            || (item.kind == MediaKind::Raw && job.options.raw_output == RawOutput::Jpeg);
        if job.options.embed_metadata && profile.embed_in_jpeg && delivers_jpeg {
            if let Ok(data) = tokio::fs::read(&rendered).await {
                if let Ok(stamped) = jpeg_xmp::embed(&packet, &data) {
                    let tmp = self.temp_path("xmp.jpg");
                    tokio::fs::write(&tmp, stamped).await?;
                    if rendered != original {
                        let _ = tokio::fs::remove_file(&rendered).await;
                    }
                    rendered = tmp;
                }
            }
        }
        let mut sidecar: Option<(Vec<u8>, String)> = None;
        let wants_sidecar = (keep_original_raw && profile.write_sidecars_for_raw)
            || (!keep_original_raw && profile.write_sidecars_for_jpeg);
        if job.options.write_sidecars && job.destination.delivers_files() && wants_sidecar {
            let base = base_of(&item);
            // One sidecar per base name: when the RAW twin is in this job its
            // sidecar covers the pair (the JPEG already carries embedded XMP).
            let raw_twin_writes_it = item.kind != MediaKind::Raw
                && profile.write_sidecars_for_raw
                && job.options.raw_output == RawOutput::Original
                && job.items.iter().any(|o| {
                    o.kind == MediaKind::Raw
                        && o.export_directory == item.export_directory
                        && base_of(o) == base
                });
            if !raw_twin_writes_it {
                sidecar = Some((packet.data(), format!("{base}.xmp")));
            }
        }
        // Sidecar first: watched folders (Lightroom Auto Import, Capture One
        // hot folders) then always find the metadata when the photo appears.
        if let Some((data, name)) = &sidecar {
            self.deliver_companion(data, name, item.export_directory.as_deref(), job)
                .await?;
        }

        let result: Result<ItemState> = match &job.destination {
            ExportDestination::Ftp { destination_id } => {
                let dest = cfg
                    .store
                    .ftp_destinations()?
                    .into_iter()
                    .find(|d| &d.id == destination_id);
                let client = dest
                    .as_ref()
                    .and_then(|d| cfg.uploaders.as_ref().and_then(|f| f.uploader(d)));
                let (Some(dest), Some(client)) = (dest, client) else {
                    return Err(ExportError::FtpDestinationMissing.into());
                };
                let data = tokio::fs::read(&rendered).await?;
                // Same naming and folders as every other file destination, so sidecars sit beside their photos.
                let remote =
                    util::append_path(&dest.remote_directory, &item.delivered_relative_path());
                client.upload(data, &remote).await?;
                let _ = cfg.store.record_export(
                    &item.id,
                    ExportDestinationKey::Ftp,
                    &job.id,
                    Some(&remote),
                );
                Ok(ItemState::Done(Some(remote)))
            }
            other => {
                let id = cfg.sink.deliver(&rendered, &item, other).await?;
                let key = if matches!(other, ExportDestination::Photos) {
                    ExportDestinationKey::Photos
                } else {
                    ExportDestinationKey::Files
                };
                let _ = cfg
                    .store
                    .record_export(&item.id, key, &job.id, id.as_deref());
                Ok(ItemState::Done(id))
            }
        };
        if rendered != original {
            let _ = tokio::fs::remove_file(&rendered).await;
        }
        job.items[idx].state = result?;
        self.save(job);
        Ok(())
    }

    /// Send a generated file (sidecar, manifest) the same way the photos went.
    async fn deliver_companion(
        &self,
        data: &[u8],
        name: &str,
        directory: Option<&str>,
        job: &ExportJob,
    ) -> Result<()> {
        let cfg = &self.inner.cfg;
        let mut item = ExportItem::new(
            format!("companion-{name}"),
            name,
            MediaKind::Other,
            data.len() as i64,
        );
        item.export_filename = Some(name.to_string());
        item.export_directory = directory.map(str::to_string);
        item.is_companion = true;
        match &job.destination {
            ExportDestination::Ftp { destination_id } => {
                let Some(dest) = cfg
                    .store
                    .ftp_destinations()?
                    .into_iter()
                    .find(|d| &d.id == destination_id)
                else {
                    return Ok(());
                };
                let Some(client) = cfg.uploaders.as_ref().and_then(|f| f.uploader(&dest)) else {
                    return Ok(());
                };
                client
                    .upload(
                        data.to_vec(),
                        &util::append_path(&dest.remote_directory, &item.delivered_relative_path()),
                    )
                    .await
            }
            other => {
                let tmp = self.temp_path(name);
                tokio::fs::write(&tmp, data).await?;
                let r = cfg.sink.deliver(&tmp, &item, other).await;
                let _ = tokio::fs::remove_file(&tmp).await;
                r.map(|_| ())
            }
        }
    }

    /// Manifest (JSON + CSV) for a finished job, when the destination holds files.
    async fn write_manifest_if_wanted(&self, job: &ExportJob) {
        let store = &self.inner.cfg.store;
        if !job.options.write_manifest || !job.destination.delivers_files() {
            return;
        }
        let Ok(Some(session)) = store.session(&job.session_id) else {
            return;
        };
        let ids: Vec<String> = job
            .items
            .iter()
            .filter(|i| !i.is_companion)
            .map(|i| i.id.clone())
            .collect();
        let caps = store.captures_by_ids(&ids).unwrap_or_default();
        let mut tags = HashMap::new();
        let mut colls = HashMap::new();
        let names: HashMap<String, String> = job
            .items
            .iter()
            .filter_map(|i| i.export_filename.clone().map(|n| (i.id.clone(), n)))
            .collect();
        for c in &caps {
            tags.insert(c.id.clone(), store.tags(&c.id).unwrap_or_default());
            let names: Vec<String> = store
                .collection_ids_containing(&c.id)
                .unwrap_or_default()
                .iter()
                .filter_map(|id| store.collection(id).ok().flatten().map(|c| c.name))
                .collect();
            colls.insert(c.id.clone(), names);
        }
        let manifest = SessionManifest::new(&session, &caps, &tags, &colls, &names);
        let base = crate::interop::NamingTemplate::safe(&session.name, false);
        let dir = job.options.layout.manifest_directory(Some(&session.name));
        if let Ok(json) = manifest.json() {
            let _ = self
                .deliver_companion(&json, &format!("{base}-manifest.json"), Some(&dir), job)
                .await;
        }
        let _ = self
            .deliver_companion(
                manifest.csv().as_bytes(),
                &format!("{base}-manifest.csv"),
                Some(&dir),
                job,
            )
            .await;
    }
}
