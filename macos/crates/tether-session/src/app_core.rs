//! `AppCore`: the one object the Tauri shell talks to. It owns the store,
//! the review editor, workspace memory, the capture cache, discovery, the
//! USB browser, the FTP receiver, the export queue, the live shoot and the
//! settings, and reports everything on one broadcast of [`AppEvent`]s.
//!
//! Ports the iOS app layer that orchestrates `TetherCore`: `AppModel`,
//! `AppServices`, `AppSettings`, `FilesImport`, the Connect view models,
//! `FTPReceiverModel`, `DemoSession`, `ShootViewModel`, `LibraryModel` and
//! `CommandDispatcher`. Methods are async and take `&self`; `AppCore` is a
//! cheap, `Send + Sync` handle (clone it freely).
//!
//! The methods live in submodules by area: [`shoot`] (sessions, the live
//! shoot, reconnect, demo, import), [`connect`] (USB, discovery, FTP
//! receiver, diagnostics), [`library`] (queries, review commands,
//! collections, looks, catalog sync) and [`export`].

mod connect;
mod export;
mod library;
mod shoot;

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use tether_library::delivery::{ExportEvent, ExportQueue, ExportQueueConfig, ImageExportRenderer};
use tether_library::library::{
    AutomationEvent, EditorEvent, ReviewEditor, SessionAutomations, WorkspaceMemory,
};
use tether_library::looks::{BuiltInLooks, LookResolver};
use tether_library::previews::{ImagePreviewGenerator, PreviewGenerating};
use tether_library::{CaptureItem, CaptureState, MediaKind, SessionStore, ShootSession};
use tether_net::CameraDiscoverer;
use tether_ptp::ptp::PtpLog;
use tether_ptp::TetherProperty;
use tether_types::LiveViewFrame;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;

use crate::cache::CaptureCacheProxy;
use crate::error::{lock, Error, Result};
use crate::events::{
    AppEvent, CaptureDto, ExportJobDto, FtpFileDto, FtpReceiverStatus, PropertyDto, ToastKind,
};
use crate::platform::{KeychainSecrets, PhotoLibrary, SecretStore, SystemPhotoLibrary};
use crate::session::{
    ConnectServices, ReconnectContext, SessionEvent, TetherSession, TetherStatus,
};
use crate::settings::AppSettings;
use crate::sinks::{FtpUploaderFactory, RoutingExportSink};

pub use export::{ExportRequest, FtpDestinationInput};
pub use library::{
    CatalogChangeDto, CatalogPreview, CollectionUpdate, ExportRecordDto, KnownCameraDto,
    LibraryPage, LibraryQuery, LibrarySource, LibraryStatsDto, LookDto,
};

/// Which file of a capture to serve.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ImageKind {
    /// The small grid thumbnail (falls back to the preview).
    Thumb,
    /// The JPEG proxy for RAW, else the original.
    Preview,
    /// The file as the camera wrote it.
    Original,
}

/// Where everything lives and which platform hooks to use.
pub struct AppCoreConfig {
    /// `tether.sqlite` and `Captures/` live here.
    pub storage_root: PathBuf,
    /// Where cameras' FTP uploads land before they are ingested.
    pub ftp_inbox: PathBuf,
    /// Where `Files` / `Share` exports go.
    pub exports_root: PathBuf,
    pub secrets: Arc<dyn SecretStore>,
    pub photos: Arc<dyn PhotoLibrary>,
    pub previews: Arc<dyn PreviewGenerating>,
    /// `None`: the default sources (SSDP, Bonjour, Fuji, Ricoh/GoPro/OSC probes).
    pub discovery: Option<Arc<CameraDiscoverer>>,
    /// Demo frame size (the iOS demo draws 2400 × 1600).
    pub demo_frame_size: (u32, u32),
}

impl AppCoreConfig {
    /// Everything under `root` (`Captures/`, `FTP Inbox/`, `Exports/`), with
    /// the Keychain, Photos, and the real preview generator.
    pub fn at(root: impl Into<PathBuf>) -> Self {
        let root = root.into();
        Self {
            ftp_inbox: root.join("FTP Inbox"),
            exports_root: root.join("Exports"),
            storage_root: root,
            secrets: Arc::new(KeychainSecrets::default()),
            photos: Arc::new(SystemPhotoLibrary),
            previews: Arc::new(ImagePreviewGenerator::default()),
            discovery: None,
            demo_frame_size: crate::demo::FRAME_SIZE,
        }
    }

    /// `~/Library/Application Support/Open Tether/` (inside the sandbox
    /// container, which macOS maps automatically).
    pub fn default_location() -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        Self::at(
            home.join("Library")
                .join("Application Support")
                .join("Open Tether"),
        )
    }
}

/// The live shoot.
pub(crate) struct ActiveShoot {
    pub session: TetherSession,
    pub context: ReconnectContext,
    pub forwarder: Option<JoinHandle<()>>,
    pub automations: Option<SessionAutomations>,
    pub automations_task: Option<JoinHandle<()>>,
    pub reconnect_task: Option<JoinHandle<()>>,
    pub reconnecting: bool,
    pub reconnect_error: Option<String>,
    /// Resumed from the store without a link: the status stays
    /// "disconnected" until a reconnect succeeds.
    pub pending_reconnect: bool,
    pub demo_task: Option<JoinHandle<()>>,
}

impl ActiveShoot {
    fn abort_tasks(&mut self) {
        for t in [
            self.forwarder.take(),
            self.automations_task.take(),
            self.reconnect_task.take(),
            self.demo_task.take(),
        ]
        .into_iter()
        .flatten()
        {
            t.abort();
        }
        if let Some(a) = &self.automations {
            a.stop();
        }
    }
}

#[derive(Default)]
pub(crate) struct FtpState {
    pub server: Option<Arc<tether_net::FtpServer>>,
    pub tasks: Vec<JoinHandle<()>>,
    pub status: FtpReceiverStatus,
    pub received: VecDeque<FtpFileDto>,
}

pub(crate) struct Inner {
    pub store: Arc<SessionStore>,
    pub memory: Arc<WorkspaceMemory>,
    pub editor: Arc<ReviewEditor>,
    pub cache: Arc<CaptureCacheProxy>,
    pub previews: Arc<dyn PreviewGenerating>,
    pub looks: Arc<LookResolver>,
    pub queue: ExportQueue,
    pub discovery: Arc<CameraDiscoverer>,
    pub secrets: Arc<dyn SecretStore>,
    pub ptp_log: Arc<PtpLog>,
    #[cfg(target_os = "macos")]
    pub usb: tether_ptp::usb::UsbCameraBrowser,
    pub settings: Mutex<AppSettings>,
    pub ftp: Mutex<FtpState>,
    pub ftp_inbox: PathBuf,
    pub exports_root: PathBuf,
    pub active: Mutex<Option<ActiveShoot>>,
    pub live_frame: Mutex<Option<(String, LiveViewFrame)>>,
    pub events: broadcast::Sender<AppEvent>,
    pub tasks: Mutex<Vec<JoinHandle<()>>>,
    pub demo_frame_size: (u32, u32),
}

impl Drop for Inner {
    fn drop(&mut self) {
        for t in lock(&self.tasks).drain(..) {
            t.abort();
        }
        if let Some(mut a) = lock(&self.active).take() {
            a.abort_tasks();
        }
        let mut ftp = lock(&self.ftp);
        for t in ftp.tasks.drain(..) {
            t.abort();
        }
        if let Some(s) = ftp.server.take() {
            s.stop();
        }
    }
}

/// See the module docs.
#[derive(Clone)]
pub struct AppCore {
    pub(crate) inner: Arc<Inner>,
}

impl std::fmt::Debug for AppCore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppCore")
            .field("store", &self.inner.store.path())
            .finish_non_exhaustive()
    }
}

impl AppCore {
    /// Opens the store and wires every service, then launches: sessions
    /// still "active" from a crash become interrupted, the export queue
    /// resumes, and the event forwarders start. Needs a Tokio runtime.
    pub async fn open(config: AppCoreConfig) -> Result<AppCore> {
        std::fs::create_dir_all(&config.storage_root)?;
        std::fs::create_dir_all(&config.ftp_inbox)?;
        let db = config.storage_root.join("tether.sqlite");
        let store = Arc::new(SessionStore::open(&db.to_string_lossy())?);
        let memory = Arc::new(WorkspaceMemory::new(store.clone()));
        let editor = Arc::new(ReviewEditor::new(store.clone(), Some(memory.clone())));
        let cache = Arc::new(CaptureCacheProxy::new(config.storage_root.join("Captures")));
        // Every look is on the device: the built-ins, imported cubes and colour matches.
        BuiltInLooks::install(&store)?;
        tether_ptp::install_built_ins();
        let looks = Arc::new(LookResolver::new(store.clone(), None));
        let temp_dir = std::env::temp_dir().join("open-tether-exports");
        let _ = std::fs::create_dir_all(&temp_dir);
        let sink = Arc::new(RoutingExportSink {
            store: store.clone(),
            photos: config.photos.clone(),
            exports_root: config.exports_root.clone(),
        });
        let mut qc = ExportQueueConfig::new(store.clone(), cache.clone(), sink, looks.clone());
        qc.renderer = Arc::new(ImageExportRenderer {
            temp_dir: temp_dir.clone(),
            ..Default::default()
        });
        qc.memory = Some(memory.clone());
        qc.uploaders = Some(Arc::new(FtpUploaderFactory {
            secrets: config.secrets.clone(),
        }));
        qc.temp_dir = temp_dir;
        let queue = ExportQueue::new(qc);
        let settings = AppSettings::load(&store);
        let (events, _) = broadcast::channel(4096);
        let core = AppCore {
            inner: Arc::new(Inner {
                discovery: config.discovery.clone().unwrap_or_else(|| {
                    Arc::new(CameraDiscoverer::new(CameraDiscoverer::DEFAULT_EXPIRY))
                }),
                store,
                memory,
                editor,
                cache,
                previews: config.previews.clone(),
                looks,
                queue,
                secrets: config.secrets.clone(),
                ptp_log: Arc::new(PtpLog::new(500)),
                #[cfg(target_os = "macos")]
                usb: tether_ptp::usb::UsbCameraBrowser::new(),
                settings: Mutex::new(settings),
                ftp: Mutex::new(FtpState::default()),
                ftp_inbox: config.ftp_inbox.clone(),
                exports_root: config.exports_root.clone(),
                active: Mutex::new(None),
                live_frame: Mutex::new(None),
                events,
                tasks: Mutex::new(Vec::new()),
                demo_frame_size: config.demo_frame_size,
            }),
        };
        core.launch().await?;
        Ok(core)
    }

    async fn launch(&self) -> Result<()> {
        // Anything still "active" was cut off by a crash or force-quit.
        self.inner.store.mark_interrupted_sessions()?;
        self.observe_editor();
        self.observe_exports();
        self.inner.queue.resume();
        if lock(&self.inner.settings).auto_start_ftp {
            if let Err(e) = self.ftp_start().await {
                self.toast(e.to_string(), ToastKind::Warning);
            }
        }
        Ok(())
    }

    /// Every event from now on.
    pub fn subscribe(&self) -> broadcast::Receiver<AppEvent> {
        self.inner.events.subscribe()
    }

    pub(crate) fn emit(&self, e: AppEvent) {
        let _ = self.inner.events.send(e);
    }

    pub(crate) fn toast(&self, text: impl Into<String>, kind: ToastKind) {
        self.emit(AppEvent::Toast {
            text: text.into(),
            kind,
        });
    }

    pub(crate) fn keep(&self, task: JoinHandle<()>) {
        let mut tasks = lock(&self.inner.tasks);
        tasks.retain(|t| !t.is_finished());
        tasks.push(task);
    }

    pub(crate) fn connect_services(&self) -> ConnectServices {
        ConnectServices {
            store: self.inner.store.clone(),
            cache: self.inner.cache.clone(),
            previews: self.inner.previews.clone(),
            ptp_log: Some(self.inner.ptp_log.clone()),
        }
    }

    pub fn store(&self) -> &Arc<SessionStore> {
        &self.inner.store
    }

    pub fn cache(&self) -> &Arc<CaptureCacheProxy> {
        &self.inner.cache
    }

    pub fn memory(&self) -> &Arc<WorkspaceMemory> {
        &self.inner.memory
    }

    /// The PTP transaction log (for the diagnostics screen).
    pub fn ptp_log_lines(&self) -> Vec<String> {
        self.inner
            .ptp_log
            .recent()
            .iter()
            .map(|e| e.line())
            .collect()
    }

    // MARK: Settings

    pub fn settings(&self) -> AppSettings {
        lock(&self.inner.settings).clone()
    }

    /// Saves settings; a running FTP receiver restarts when its
    /// credentials or port changed.
    pub async fn update_settings(&self, new: AppSettings) -> Result<AppSettings> {
        let restart = {
            let mut s = lock(&self.inner.settings);
            let changed = s.ftp_username != new.ftp_username
                || s.ftp_password != new.ftp_password
                || s.ftp_port != new.ftp_port;
            *s = new.clone();
            changed
        };
        new.save(&self.inner.store);
        if restart && self.ftp_status().is_running {
            self.ftp_stop().await;
            self.ftp_start().await?;
        }
        Ok(new)
    }

    // MARK: Images

    /// The file to serve for a capture. `Thumb` falls back to the preview,
    /// `Preview` to the original (never a RAW original).
    pub fn image_path(&self, capture_id: &str, kind: ImageKind) -> Result<PathBuf> {
        let c = self
            .inner
            .store
            .capture(capture_id)?
            .ok_or_else(|| Error::NotFound(format!("Capture {capture_id}")))?;
        let relative = match kind {
            ImageKind::Thumb => c
                .thumbnail_relative_path
                .as_deref()
                .or(c.preview_relative_path()),
            ImageKind::Preview => c.preview_relative_path(),
            ImageKind::Original => c.relative_path.as_deref(),
        };
        let relative =
            relative.ok_or_else(|| Error::NotFound(format!("{:?} of {}", kind, c.filename)))?;
        let path = self.inner.cache.url(relative)?;
        if !path.exists() {
            return Err(Error::NotFound(path.display().to_string()));
        }
        Ok(path)
    }

    /// The newest live-view frame (JPEG bytes) and its sequence number.
    pub fn live_view_frame(&self) -> Option<(u64, Vec<u8>)> {
        let f = lock(&self.inner.live_frame);
        let (_, frame) = f.as_ref()?;
        let jpeg = tether_types::jpeg_payload(&frame.jpeg).unwrap_or(&frame.jpeg);
        Some((frame.sequence, jpeg.to_vec()))
    }

    // MARK: Forwarders

    fn observe_editor(&self) {
        let mut rx = self.inner.editor.subscribe();
        let weak = Arc::downgrade(&self.inner);
        self.keep(tokio::spawn(async move {
            loop {
                let ev = match rx.recv().await {
                    Ok(e) => e,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                };
                let Some(inner) = weak.upgrade() else { return };
                let core = AppCore { inner };
                match ev {
                    EditorEvent::Changed(ids) => core.emit(AppEvent::LibraryChanged { ids }),
                    EditorEvent::UndoAvailable(_) | EditorEvent::RedoAvailable(_) => {
                        core.emit(AppEvent::UndoState {
                            undo_title: core.inner.editor.undo_title(),
                            redo_title: core.inner.editor.redo_title(),
                        })
                    }
                }
            }
        }));
    }

    fn observe_exports(&self) {
        let mut rx = self.inner.queue.subscribe();
        let weak = Arc::downgrade(&self.inner);
        self.keep(tokio::spawn(async move {
            loop {
                let ev = match rx.recv().await {
                    Ok(e) => e,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                };
                let Some(inner) = weak.upgrade() else { return };
                let core = AppCore { inner };
                match ev {
                    ExportEvent::Updated(job) => core.emit(AppEvent::ExportProgress {
                        job: ExportJobDto::from(&job),
                    }),
                    ExportEvent::Finished(job) => {
                        let ok = job.status.key() == "completed";
                        core.toast(
                            if ok {
                                format!("Export to {} finished", job.destination.display_name())
                            } else {
                                "Export finished with errors".to_string()
                            },
                            if ok {
                                ToastKind::Success
                            } else {
                                ToastKind::Warning
                            },
                        );
                        core.emit(AppEvent::ExportFinished {
                            job: ExportJobDto::from(&job),
                        });
                    }
                }
            }
        }));
    }

    /// Mirrors one live session's events onto the app broadcast, and runs
    /// what the shoot screen did on each: hot folder copies, automations,
    /// exposure memory.
    pub(crate) fn forward_session(&self, session: &TetherSession) -> JoinHandle<()> {
        let mut rx = session.subscribe();
        let weak = Arc::downgrade(&self.inner);
        let s = session.downgrade();
        let mut known: HashMap<String, CaptureItem> = session
            .snapshot()
            .items
            .into_iter()
            .map(|i| (i.id.clone(), i))
            .collect();
        tokio::spawn(async move {
            loop {
                let ev = match rx.recv().await {
                    Ok(e) => e,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                };
                let (Some(inner), Some(session)) = (weak.upgrade(), s.upgrade()) else {
                    return;
                };
                AppCore { inner }.on_session_event(&session, ev, &mut known);
            }
        })
    }

    fn on_session_event(
        &self,
        session: &TetherSession,
        ev: SessionEvent,
        known: &mut HashMap<String, CaptureItem>,
    ) {
        let session_id = session.session().id;
        match ev {
            SessionEvent::Status(status) => {
                let (shown, ftp, reconnecting) = {
                    let a = lock(&self.inner.active);
                    match a.as_ref().filter(|a| a.session.same_session(session)) {
                        Some(a) => (
                            if a.pending_reconnect {
                                None
                            } else {
                                Some(status.clone())
                            },
                            a.context == ReconnectContext::Ftp,
                            a.reconnecting,
                        ),
                        None => (Some(status.clone()), false, false),
                    }
                };
                let Some(status) = shown else { return };
                if let TetherStatus::Disconnected(reason) = &status {
                    if !ftp && !reconnecting {
                        self.toast(reason.clone(), ToastKind::Warning);
                    }
                }
                self.emit(AppEvent::ConnectionStatus {
                    session_id,
                    text: status.text(),
                    status,
                });
            }
            SessionEvent::Capture(item) => {
                let item = *item;
                let previous = known.insert(item.id.clone(), item.clone());
                let became_ready =
                    item.state.is_ready() && !previous.as_ref().is_some_and(|p| p.state.is_ready());
                if let CaptureState::Downloading { received, total } = item.state {
                    self.emit(AppEvent::DownloadProgress {
                        capture_id: item.id.clone(),
                        received,
                        total,
                        in_flight: session.snapshot().downloads_in_flight,
                    });
                }
                let dto = Box::new(CaptureDto::from(&item));
                if previous.is_none() {
                    self.emit(AppEvent::CaptureAdded { capture: dto });
                } else {
                    self.emit(AppEvent::CaptureUpdated { capture: dto });
                }
                let shoot = session.session();
                // Culling here flows to the hot folder's sidecar (one per
                // RAW+JPEG pair: the RAW's, else the JPEG's).
                if let Some(p) = &previous {
                    let review_changed = p.rating != item.rating
                        || p.flag != item.flag
                        || p.color_label != item.color_label;
                    let owns_sidecar = item.kind == MediaKind::Raw
                        || !known
                            .values()
                            .any(|o| o.pair_key == item.pair_key && o.kind == MediaKind::Raw);
                    if p.state.is_ready() && !became_ready && review_changed && owns_sidecar {
                        self.refresh_hot_folder_sidecar(&item, &shoot);
                    }
                }
                if became_ready {
                    self.send_to_hot_folder(&item, &shoot);
                    let automations = lock(&self.inner.active)
                        .as_ref()
                        .filter(|a| a.session.same_session(session))
                        .and_then(|a| a.automations.clone());
                    if let Some(a) = automations {
                        a.capture_ready(&item);
                    }
                    self.emit(AppEvent::LibraryChanged {
                        ids: vec![item.id.clone()],
                    });
                    if !shoot.show_newest_capture {
                        self.toast(format!("New frame {}", item.filename), ToastKind::Info);
                    }
                }
            }
            SessionEvent::Properties(p) => {
                if let Some(id) = session.identity().map(|i| i.id.clone()) {
                    let bar: Vec<(&str, &str)> = TetherProperty::EXPOSURE_BAR
                        .iter()
                        .filter_map(|bp| p.iter().find(|d| d.property == *bp))
                        .map(|d| (d.property.raw(), d.display.as_str()))
                        .collect();
                    self.inner.memory.remember_exposure(&id, bar);
                }
                self.emit(AppEvent::Properties {
                    properties: p.iter().map(PropertyDto::from).collect(),
                });
            }
            SessionEvent::LiveView(frame) => {
                let (sequence, width, height) = (frame.sequence, frame.width, frame.height);
                *lock(&self.inner.live_frame) = Some((session_id.clone(), frame));
                self.emit(AppEvent::LiveViewFrame {
                    session_id,
                    sequence,
                    width,
                    height,
                });
            }
            SessionEvent::Warning(w) => self.toast(w, ToastKind::Warning),
            SessionEvent::Selection(id) => self.emit(AppEvent::Selection { capture_id: id }),
            SessionEvent::Removed(id) => {
                known.remove(&id);
                self.emit(AppEvent::CaptureRemoved { id });
            }
        }
    }

    /// Template tags, auto-collection and auto-export of picks run beside
    /// the live session; their outcomes surface as toasts.
    pub(crate) fn start_automations(
        &self,
        shoot: &ShootSession,
    ) -> (SessionAutomations, JoinHandle<()>) {
        let memory = &self.inner.memory;
        let template_id = memory.get(WorkspaceMemory::SESSION_DEFAULTS).template_id;
        let template = memory
            .templates()
            .into_iter()
            .find(|t| Some(&t.id) == template_id.as_ref());
        let rules = tether_library::library::AutomationRules::from_template(
            template.as_ref(),
            shoot,
            memory,
        );
        let auto = SessionAutomations::new(
            shoot.clone(),
            rules,
            self.inner.store.clone(),
            self.inner.editor.clone(),
            Some(self.inner.queue.clone()),
            memory.clone(),
        );
        auto.attach();
        let mut rx = auto.subscribe();
        let weak = Arc::downgrade(&self.inner);
        let task = tokio::spawn(async move {
            loop {
                let ev = match rx.recv().await {
                    Ok(e) => e,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                };
                let Some(inner) = weak.upgrade() else { return };
                let core = AppCore { inner };
                match ev {
                    AutomationEvent::ExportQueued(job) => {
                        let n = job.items.iter().filter(|i| !i.is_companion).count();
                        core.toast(
                            format!(
                                "{n} pick{} exporting to {}",
                                if n == 1 { "" } else { "s" },
                                job.destination.display_name()
                            ),
                            ToastKind::Info,
                        );
                    }
                    AutomationEvent::Error(m) => core.toast(m, ToastKind::Error),
                    AutomationEvent::Tagged { capture_id }
                    | AutomationEvent::AddedToCollection { capture_id } => {
                        core.emit(AppEvent::LibraryChanged {
                            ids: vec![capture_id],
                        })
                    }
                }
            }
        });
        (auto, task)
    }

    // MARK: Hot folder

    /// Copy a frame that just landed into the session's hot folder (if one
    /// is set), through the export queue so naming, layout and sidecars
    /// match every other export. Hot-folder copies are always originals.
    pub(crate) fn send_to_hot_folder(&self, item: &CaptureItem, session: &ShootSession) {
        self.hot_folder_job(item, session, false);
    }

    /// Rewrite a frame's sidecar in the hot folder after it was re-rated,
    /// picked or labelled, so Capture One / Lightroom see the change.
    pub(crate) fn refresh_hot_folder_sidecar(&self, item: &CaptureItem, session: &ShootSession) {
        self.hot_folder_job(item, session, true);
    }

    fn hot_folder_job(&self, item: &CaptureItem, session: &ShootSession, metadata_only: bool) {
        use tether_library::delivery::{ExportDestination, HotFolder};
        use tether_library::looks::LookStack;
        let Some(folder_id) = &session.routing.live_folder_id else {
            return;
        };
        if !metadata_only && !(item.kind.is_still() || item.kind == MediaKind::Video) {
            return;
        }
        let Ok(Some(folder)) = self.inner.store.folder_destination(folder_id) else {
            return;
        };
        let job = self.inner.queue.make_job(
            session,
            std::slice::from_ref(item),
            ExportDestination::Folder {
                destination_id: folder.id.clone(),
            },
            HotFolder::options(&folder, metadata_only),
            LookStack::none(),
        );
        if !job.items.is_empty() {
            let _ = self.inner.queue.enqueue(&job);
        }
    }
}
