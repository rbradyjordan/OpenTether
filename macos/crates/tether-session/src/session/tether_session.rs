//! The live state of one tethered shoot (`Capture/TetherSession.swift`).
//!
//! Drives the vendor handler, receives captures, writes them through the
//! cache and the store, makes previews, and exposes a snapshot plus an event
//! stream. The Swift actor becomes a cloneable handle over shared state
//! behind a std mutex that is never held across an `.await`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tether_library::interop::{jpeg_xmp, XmpPacket};
use tether_library::library::LiveCaptureHook;
use tether_library::looks::LookStack;
use tether_library::previews::{NoPreviewGenerator, PreviewGenerating};
use tether_library::{
    CaptureFlag, CaptureItem, CaptureState, ColorLabel, ExposureSummary, MediaKind, RoutingRules,
    SessionStatus, SessionStore, ShootSession,
};
use tether_ptp::ptp::{PtpObjectInfo, PtpValue, TransportHealth};
use tether_ptp::{
    CameraEvent, FocusResult, NewObject, PropertyDescriptor, PtpEngine, PtpError, PtpResult,
    TetherProperty, VendorHandler,
};
use tether_types::{
    CameraCapabilities, CameraIdentity, CameraVendor, CaptureDestination, LiveViewFrame,
    LiveViewQuality, TransportKind,
};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;

use crate::cache::{extension, CaptureCacheProxy};
use crate::error::lock;

/// Where the link is. `Disconnected` carries the reason shown to the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", content = "reason", rename_all = "camelCase")]
pub enum TetherStatus {
    Idle,
    Connecting,
    Preparing,
    Ready,
    Capturing,
    Reconnecting,
    Disconnected(String),
    Ended,
}

impl TetherStatus {
    pub fn is_live(&self) -> bool {
        matches!(self, Self::Ready | Self::Capturing)
    }

    /// The status line the shoot screen shows.
    pub fn text(&self) -> String {
        match self {
            Self::Idle => "Idle".into(),
            Self::Connecting => "Connecting".into(),
            Self::Preparing => "Preparing".into(),
            Self::Ready => "Ready".into(),
            Self::Capturing => "Capturing".into(),
            Self::Reconnecting => "Reconnecting".into(),
            Self::Disconnected(r) => r.clone(),
            Self::Ended => "Ended".into(),
        }
    }
}

/// What a session tells its listeners.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Status(TetherStatus),
    Capture(Box<CaptureItem>),
    Properties(Vec<PropertyDescriptor>),
    LiveView(LiveViewFrame),
    Warning(String),
    Selection(Option<String>),
    /// Rust addition: a capture was deleted from the session.
    Removed(String),
}

/// A consistent copy of the session's state.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub session: ShootSession,
    pub identity: Option<CameraIdentity>,
    pub status: TetherStatus,
    pub items: Vec<CaptureItem>,
    pub properties: Vec<PropertyDescriptor>,
    pub selected_item_id: Option<String>,
    pub live_view_active: bool,
    pub downloads_in_flight: usize,
    pub transport_health: Option<TransportHealth>,
}

impl Snapshot {
    /// The selected frame, else the newest ready one.
    pub fn displayed_item(&self) -> Option<&CaptureItem> {
        self.items
            .iter()
            .find(|i| Some(&i.id) == self.selected_item_id.as_ref())
            .or_else(|| self.items.iter().rev().find(|i| i.state.is_ready()))
    }

    pub fn ready_items(&self) -> Vec<&CaptureItem> {
        self.items.iter().filter(|i| i.state.is_ready()).collect()
    }
}

/// `tether-ptp` and `tether-library` both define `MediaKind` with the same
/// raw values; this maps one onto the other.
pub fn library_kind(kind: tether_ptp::ptp::MediaKind) -> MediaKind {
    MediaKind::from_raw(kind.raw()).unwrap_or(MediaKind::Other)
}

struct State {
    session: ShootSession,
    handler: Option<Arc<dyn VendorHandler>>,
    engine: Option<Arc<PtpEngine>>,
    items: Vec<CaptureItem>,
    properties: Vec<PropertyDescriptor>,
    status: TetherStatus,
    selected: Option<String>,
    known_handles: HashSet<u32>,
    download_queue: VecDeque<NewObject>,
    downloading: bool,
    event_task: Option<JoinHandle<()>>,
    poll_task: Option<JoinHandle<()>>,
    live_view_task: Option<JoinHandle<()>>,
    refresh_task: Option<JoinHandle<()>>,
    transport_health: Option<TransportHealth>,
    /// Sidecars that arrived on their own (FTP push), by pair key, so the
    /// photo or its RAW/JPEG twin picks them up whichever lands first.
    pending_sidecars: HashMap<String, XmpPacket>,
}

impl State {
    fn abort_loops(&mut self, live_view: bool) {
        for t in [self.event_task.take(), self.poll_task.take()]
            .into_iter()
            .flatten()
        {
            t.abort();
        }
        if live_view {
            if let Some(t) = self.live_view_task.take() {
                t.abort();
            }
        }
    }
}

struct Inner {
    identity: Option<CameraIdentity>,
    store: Arc<SessionStore>,
    cache: Arc<CaptureCacheProxy>,
    previews: Arc<dyn PreviewGenerating>,
    state: Mutex<State>,
    events: broadcast::Sender<SessionEvent>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        let s = self.state.get_mut().unwrap_or_else(|e| e.into_inner());
        s.abort_loops(true);
        if let Some(t) = s.refresh_task.take() {
            t.abort();
        }
    }
}

/// See [`TetherSession::downgrade`].
#[derive(Clone)]
pub struct WeakTetherSession(Weak<Inner>);

impl WeakTetherSession {
    pub fn upgrade(&self) -> Option<TetherSession> {
        TetherSession::from_weak(&self.0)
    }
}

/// One tethered shoot. Cloning shares the session.
#[derive(Clone)]
pub struct TetherSession {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for TetherSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TetherSession")
            .field("session", &self.session().id)
            .finish_non_exhaustive()
    }
}

impl TetherSession {
    /// Properties shown on the shoot screen; vendors fill what they have.
    pub const TRACKED_PROPERTIES: [TetherProperty; 11] = [
        TetherProperty::ShutterSpeed,
        TetherProperty::Aperture,
        TetherProperty::Iso,
        TetherProperty::ExposureCompensation,
        TetherProperty::WhiteBalance,
        TetherProperty::BatteryLevel,
        TetherProperty::CaptureDestination,
        TetherProperty::StorageFreeImages,
        TetherProperty::ExposureProgram,
        TetherProperty::DriveMode,
        TetherProperty::FocusMode,
    ];

    pub fn new(
        session: ShootSession,
        identity: Option<CameraIdentity>,
        handler: Option<Arc<dyn VendorHandler>>,
        engine: Option<Arc<PtpEngine>>,
        store: Arc<SessionStore>,
        cache: Arc<CaptureCacheProxy>,
        previews: Option<Arc<dyn PreviewGenerating>>,
    ) -> Self {
        let items = store.captures_in_session(&session.id).unwrap_or_default();
        let known_handles = items.iter().map(|i| i.handle).collect();
        let selected = items
            .iter()
            .rev()
            .find(|i| i.state.is_ready())
            .map(|i| i.id.clone());
        let (events, _) = broadcast::channel(1024);
        Self {
            inner: Arc::new(Inner {
                identity,
                store,
                cache,
                previews: previews.unwrap_or_else(|| Arc::new(NoPreviewGenerator)),
                state: Mutex::new(State {
                    session,
                    handler,
                    engine,
                    items,
                    properties: Vec::new(),
                    status: TetherStatus::Idle,
                    selected,
                    known_handles,
                    download_queue: VecDeque::new(),
                    downloading: false,
                    event_task: None,
                    poll_task: None,
                    live_view_task: None,
                    refresh_task: None,
                    transport_health: None,
                    pending_sidecars: HashMap::new(),
                }),
                events,
            }),
        }
    }

    /// A handle that does not keep the session alive (for transport
    /// callbacks the session itself owns).
    pub fn downgrade(&self) -> WeakTetherSession {
        WeakTetherSession(self.weak())
    }

    fn from_weak(weak: &Weak<Inner>) -> Option<Self> {
        weak.upgrade().map(|inner| Self { inner })
    }

    fn weak(&self) -> Weak<Inner> {
        Arc::downgrade(&self.inner)
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        lock(&self.inner.state)
    }

    /// Every event from now on; each caller gets its own receiver.
    pub fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.inner.events.subscribe()
    }

    pub fn identity(&self) -> Option<&CameraIdentity> {
        self.inner.identity.as_ref()
    }

    pub fn session(&self) -> ShootSession {
        self.state().session.clone()
    }

    pub fn status(&self) -> TetherStatus {
        self.state().status.clone()
    }

    pub fn handler(&self) -> Option<Arc<dyn VendorHandler>> {
        self.state().handler.clone()
    }

    pub fn capabilities(&self) -> CameraCapabilities {
        self.state()
            .handler
            .as_ref()
            .map(|h| h.capabilities())
            .or_else(|| self.inner.identity.as_ref().map(|i| i.capabilities))
            .unwrap_or_default()
    }

    pub fn same_session(&self, other: &TetherSession) -> bool {
        Arc::ptr_eq(&self.inner, &other.inner)
    }

    pub fn snapshot(&self) -> Snapshot {
        let s = self.state();
        Snapshot {
            session: s.session.clone(),
            identity: self.inner.identity.clone(),
            status: s.status.clone(),
            items: s.items.clone(),
            properties: s.properties.clone(),
            selected_item_id: s.selected.clone(),
            live_view_active: s.live_view_task.is_some(),
            downloads_in_flight: s.download_queue.len() + usize::from(s.downloading),
            transport_health: s.transport_health.clone(),
        }
    }

    // MARK: Lifecycle

    /// Prepare the camera (vendor gate), apply the destination, read the
    /// settings bar, then start the event and poll loops. Safe to call again
    /// after a reconnect.
    pub async fn start(&self) -> PtpResult<()> {
        let Some(handler) = self.handler() else {
            // FTP-push sessions have no camera link; they only ingest files.
            self.set_status(TetherStatus::Ready);
            return Ok(());
        };
        self.set_status(TetherStatus::Preparing);
        let result = async {
            handler.prepare().await?;
            let destination = self.state().session.destination;
            match handler.set_capture_destination(destination).await {
                Ok(()) => {}
                Err(PtpError::Unsupported(m)) => self.warn(m),
                Err(e) => return Err(e),
            }
            self.refresh_properties().await;
            self.start_loops();
            let changed = {
                let mut s = self.state();
                let changed = s.session.status != SessionStatus::Active;
                s.session.status = SessionStatus::Active;
                changed
            };
            if changed {
                self.persist_session();
            }
            self.set_status(TetherStatus::Ready);
            self.recover_pending_downloads();
            Ok(())
        }
        .await;
        if let Err(e) = &result {
            self.set_status(TetherStatus::Disconnected(e.to_string()));
        }
        result
    }

    pub async fn stop(&self, ended: bool) {
        let (handler, engine) = {
            let mut s = self.state();
            s.abort_loops(false);
            if let Some(t) = s.refresh_task.take() {
                t.abort();
            }
            (s.handler.clone(), s.engine.clone())
        };
        self.stop_live_view().await;
        if let Some(h) = handler {
            h.teardown().await;
        }
        if let Some(e) = engine {
            e.disconnect().await;
        }
        {
            let mut s = self.state();
            s.session.status = if ended {
                SessionStatus::Ended
            } else {
                SessionStatus::Interrupted
            };
            if ended {
                s.session.ended_at = Some(Utc::now());
            }
        }
        self.persist_session();
        self.set_status(if ended {
            TetherStatus::Ended
        } else {
            TetherStatus::Disconnected("Stopped".into())
        });
    }

    /// Reconnect over a fresh transport while keeping the session, its items
    /// and selection: swap the camera link and run `start` again.
    pub async fn reattach(
        &self,
        handler: Option<Arc<dyn VendorHandler>>,
        engine: Option<Arc<PtpEngine>>,
    ) -> PtpResult<()> {
        let old = {
            let mut s = self.state();
            s.abort_loops(true);
            s.engine.take()
        };
        if let Some(e) = old {
            e.disconnect().await;
        }
        {
            let mut s = self.state();
            s.handler = handler;
            s.engine = engine;
        }
        self.set_status(TetherStatus::Reconnecting);
        self.start().await
    }

    /// The transport dropped (cable pulled, Wi-Fi lost). The UI offers reconnect.
    pub fn mark_disconnected(&self, reason: impl Into<String>) {
        {
            let mut s = self.state();
            s.abort_loops(true);
            s.session.status = SessionStatus::Interrupted;
        }
        self.persist_session();
        self.set_status(TetherStatus::Disconnected(reason.into()));
    }

    fn start_loops(&self) {
        let (handler, engine) = {
            let mut s = self.state();
            s.abort_loops(false);
            (s.handler.clone(), s.engine.clone())
        };
        let Some(handler) = handler else { return };
        let mut event_task = None;
        if let Some(engine) = engine {
            let weak = self.weak();
            let stream = engine.events();
            let h = handler.clone();
            event_task = Some(tokio::spawn(async move {
                while let Some(ev) = stream.next().await {
                    let Some(this) = Self::from_weak(&weak) else {
                        return;
                    };
                    if let Some(t) = h.translate(&ev).await {
                        this.handle(t);
                    }
                }
                if let Some(this) = Self::from_weak(&weak) {
                    this.mark_disconnected("The camera connection closed.");
                }
            }));
        }
        let interval = handler.event_poll_interval();
        let weak = self.weak();
        let poll_task = tokio::spawn(async move {
            let mut failures = 0;
            loop {
                tokio::time::sleep(interval).await;
                if weak.strong_count() == 0 {
                    return;
                }
                match handler.poll_events().await {
                    Ok(events) => {
                        let Some(this) = Self::from_weak(&weak) else {
                            return;
                        };
                        for ev in events {
                            this.handle(ev);
                        }
                        failures = 0;
                    }
                    Err(e) => {
                        failures += 1;
                        if failures >= 5 {
                            if let Some(this) = Self::from_weak(&weak) {
                                this.mark_disconnected(format!(
                                    "Lost contact with the camera: {e}"
                                ));
                            }
                            return;
                        }
                    }
                }
            }
        });
        let mut s = self.state();
        s.event_task = event_task;
        s.poll_task = Some(poll_task);
    }

    // MARK: Camera control

    pub async fn capture(&self, autofocus: bool) -> PtpResult<()> {
        let handler = {
            let s = self.state();
            match (&s.handler, s.status.is_live()) {
                (Some(h), true) => h.clone(),
                _ => return Err(PtpError::NotConnected),
            }
        };
        self.set_status(TetherStatus::Capturing);
        let r = handler.capture(autofocus).await;
        if self.status() == TetherStatus::Capturing {
            self.set_status(TetherStatus::Ready);
        }
        r
    }

    pub async fn set_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()> {
        let handler = self.handler().ok_or(PtpError::NotConnected)?;
        handler.write_property(property, raw.clone()).await?;
        let updated = {
            let mut s = self.state();
            let found = s.properties.iter_mut().find(|p| p.property == property);
            match found {
                Some(p) => {
                    if let Some(c) = p.choices().iter().find(|c| c.raw == raw) {
                        p.display = c.display.clone();
                    }
                    p.raw = raw;
                    Some(s.properties.clone())
                }
                None => None,
            }
        };
        if let Some(p) = updated {
            self.send(SessionEvent::Properties(p));
        }
        self.schedule_refresh(Duration::from_millis(400));
        Ok(())
    }

    pub async fn refresh_properties(&self) {
        let Some(handler) = self.handler() else {
            return;
        };
        if let Ok(p) = handler.read_properties(&Self::TRACKED_PROPERTIES).await {
            self.state().properties = p.clone();
            self.send(SessionEvent::Properties(p));
        }
    }

    pub fn properties(&self) -> Vec<PropertyDescriptor> {
        self.state().properties.clone()
    }

    fn schedule_refresh(&self, after: Duration) {
        let weak = self.weak();
        let task = tokio::spawn(async move {
            tokio::time::sleep(after).await;
            if let Some(this) = Self::from_weak(&weak) {
                this.refresh_properties().await;
            }
        });
        if let Some(old) = self.state().refresh_task.replace(task) {
            old.abort();
        }
    }

    pub async fn set_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if let Some(h) = self.handler() {
            h.set_capture_destination(destination).await?;
        }
        self.state().session.destination = destination;
        self.persist_session();
        Ok(())
    }

    // MARK: Live view

    pub async fn start_live_view(&self, quality: LiveViewQuality) -> PtpResult<()> {
        let handler = {
            let s = self.state();
            match (&s.handler, &s.live_view_task) {
                (Some(h), None) => h.clone(),
                _ => return Ok(()),
            }
        };
        handler.start_live_view(quality).await?;
        let weak = self.weak();
        let task = tokio::spawn(async move {
            let mut sequence: u64 = 0;
            loop {
                if weak.strong_count() == 0 {
                    return;
                }
                match handler.next_live_view_frame().await {
                    Ok(Some(mut frame)) => {
                        sequence += 1;
                        frame.sequence = sequence;
                        match Self::from_weak(&weak) {
                            Some(this) => this.send(SessionEvent::LiveView(frame)),
                            None => return,
                        }
                    }
                    Ok(None) => tokio::time::sleep(Duration::from_millis(33)).await,
                    Err(e) => {
                        if let Some(this) = Self::from_weak(&weak) {
                            this.warn(format!("Live view stopped: {e}"));
                            // This task is the live-view task: let it go
                            // without aborting itself, then tell the camera.
                            this.state().live_view_task.take();
                        }
                        handler.stop_live_view().await;
                        return;
                    }
                }
            }
        });
        self.state().live_view_task = Some(task);
        Ok(())
    }

    pub async fn stop_live_view(&self) {
        let (task, handler) = {
            let mut s = self.state();
            (s.live_view_task.take(), s.handler.clone())
        };
        let Some(task) = task else { return };
        task.abort();
        if let Some(h) = handler {
            h.stop_live_view().await;
        }
    }

    pub fn live_view_active(&self) -> bool {
        self.state().live_view_task.is_some()
    }

    fn live_handler(&self) -> PtpResult<Arc<dyn VendorHandler>> {
        let s = self.state();
        match (&s.handler, s.status.is_live()) {
            (Some(h), true) => Ok(h.clone()),
            _ => Err(PtpError::NotConnected),
        }
    }

    /// Touch AF: focus at a point of the live-view frame, 0…1 from the top left.
    pub async fn focus(&self, x: f64, y: f64) -> PtpResult<FocusResult> {
        let h = self.live_handler()?;
        h.focus(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)).await
    }

    /// Press-and-hold focus: AF runs until `stop_tracking_focus`.
    pub async fn start_tracking_focus(&self, x: f64, y: f64) -> PtpResult<()> {
        let h = self.live_handler()?;
        h.start_tracking_focus(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0))
            .await
    }

    pub async fn stop_tracking_focus(&self) {
        if let Some(h) = self.handler() {
            h.stop_tracking_focus().await;
        }
    }

    // MARK: Events → captures

    pub fn handle(&self, event: CameraEvent) {
        match event {
            CameraEvent::ObjectAdded(obj) => {
                {
                    let mut s = self.state();
                    if s.known_handles.contains(&obj.handle) && !obj.in_sdram {
                        return;
                    }
                    s.known_handles.insert(obj.handle);
                    // Card-only: the camera keeps it; nothing to fetch.
                    if !(s.session.destination.wants_transfer()
                        || obj.in_sdram
                        || s.session.transport == Some(TransportKind::PtpIp))
                    {
                        return;
                    }
                    s.download_queue.push_back(obj);
                }
                self.pump_downloads();
            }
            CameraEvent::ObjectRemoved { handle } => {
                self.state().known_handles.remove(&handle);
            }
            CameraEvent::PropertyChanged(_) => self.schedule_refresh(Duration::from_millis(200)),
            CameraEvent::CaptureComplete => {
                if self.status() == TetherStatus::Capturing {
                    self.set_status(TetherStatus::Ready);
                }
            }
            CameraEvent::StorageChanged => self.schedule_refresh(Duration::from_millis(500)),
            CameraEvent::CameraBusy(busy) => {
                let status = self.status();
                if busy && status == TetherStatus::Ready {
                    self.set_status(TetherStatus::Capturing);
                } else if !busy && status == TetherStatus::Capturing {
                    self.set_status(TetherStatus::Ready);
                }
            }
            CameraEvent::ShutterPressed => self.set_status(TetherStatus::Capturing),
            CameraEvent::Warning(w) => self.warn(w),
            CameraEvent::Disconnected => self.mark_disconnected("The camera disconnected."),
            CameraEvent::Raw(_) => {}
        }
    }

    fn pump_downloads(&self) {
        let next = {
            let mut s = self.state();
            if s.downloading {
                return;
            }
            let Some(next) = s.download_queue.pop_front() else {
                return;
            };
            s.downloading = true;
            next
        };
        let this = self.clone();
        tokio::spawn(async move {
            this.download(next).await;
            this.state().downloading = false;
            this.pump_downloads();
        });
    }

    async fn download(&self, obj: NewObject) {
        let Some(handler) = self.handler() else {
            return;
        };
        let session = self.session();
        let seq = self
            .inner
            .store
            .next_sequence(&session.id)
            .unwrap_or_else(|_| self.state().items.len() as i64 + 1);
        let info = obj.info.as_ref();
        let mut item = CaptureItem::new(
            session.id.clone(),
            seq,
            obj.handle,
            info.map(|i| i.filename.clone())
                .filter(|f| !f.is_empty())
                .unwrap_or_else(|| format!("capture-{seq}")),
            info.map(|i| library_kind(i.media_kind()))
                .unwrap_or(MediaKind::Other),
            info.map(|i| i.object_compressed_size as i64).unwrap_or(0),
            self.inner
                .identity
                .as_ref()
                .map(|i| i.transport)
                .unwrap_or(TransportKind::Usb),
        );
        item.look_id = session.look_id.clone();
        item.camera_id = self.inner.identity.as_ref().map(|i| i.id.clone());
        item.exposure = Some(self.exposure_summary());
        if let Some(info) = info {
            apply_info(info, &mut item);
        }
        item.state = CaptureState::Downloading {
            received: 0,
            total: (item.bytes > 0).then_some(item.bytes),
        };
        self.upsert(item.clone());

        let id = item.id.clone();
        let weak = self.weak();
        let progress_id = id.clone();
        let progress: tether_ptp::ptp::ProgressFn = Arc::new(move |received, total| {
            if let Some(this) = Self::from_weak(&weak) {
                this.progress(&progress_id, received, total);
            }
        });
        match handler.fetch_object(&obj, Some(progress)).await {
            Ok((info, data)) => {
                if let Err(e) = self.finish_download(&id, &info, data, &session).await {
                    self.fail(&id, &item.filename, &e.to_string());
                    return;
                }
                let delete = {
                    let s = self.state();
                    obj.in_sdram
                        && self.inner.identity.as_ref().map(|i| i.vendor)
                            == Some(CameraVendor::Generic)
                        && s.session.destination == CaptureDestination::Host
                };
                let engine = self.state().engine.clone();
                if let (true, Some(engine)) = (delete, engine) {
                    let _ = engine.delete_object(obj.handle).await;
                }
            }
            Err(e) => {
                self.fail(&id, &item.filename, &e.to_string());
                if e == PtpError::TransportClosed {
                    self.mark_disconnected("The camera connection closed during a download.");
                }
            }
        }
    }

    async fn finish_download(
        &self,
        id: &str,
        info: &PtpObjectInfo,
        data: Vec<u8>,
        session: &ShootSession,
    ) -> crate::Result<()> {
        let Some(mut current) = self.state().items.iter().find(|i| i.id == id).cloned() else {
            return Ok(());
        };
        apply_info(info, &mut current);
        current.bytes = data.len() as i64;
        let cache = &self.inner.cache;
        current.relative_path =
            Some(cache.store(&data, &cache.original_path(session, &current.filename))?);
        let out = self
            .inner
            .previews
            .make_previews(data, current.kind, current.filename.clone())
            .await;
        if out.width > 0 {
            current.width = out.width;
            current.height = out.height;
        }
        if let Some(p) = out.proxy_jpeg {
            current.proxy_relative_path = cache
                .store(&p, &cache.proxy_path(session, &current.filename))
                .ok();
        }
        if let Some(t) = out.thumbnail_jpeg {
            current.thumbnail_relative_path = cache
                .store(&t, &cache.thumbnail_path(session, &current.filename))
                .ok();
        }
        current.state = CaptureState::Ready;
        current.received_at = Utc::now();
        self.upsert(current.clone());
        let select = {
            let mut s = self.state();
            s.session.capture_count += 1;
            s.session.show_newest_capture || s.selected.is_none()
        };
        self.persist_session();
        if select {
            self.select(Some(current.id));
        }
        Ok(())
    }

    fn fail(&self, id: &str, filename: &str, error: &str) {
        let failed = self.state().items.iter().find(|i| i.id == id).cloned();
        if let Some(mut f) = failed {
            f.state = CaptureState::Failed(error.to_string());
            self.upsert(f);
        }
        self.warn(format!("Download of {filename} failed: {error}"));
    }

    fn exposure_summary(&self) -> ExposureSummary {
        let props = self.state().properties.clone();
        ExposureSummary::from_properties(
            props.iter().map(|p| (p.property.raw(), p.display.as_str())),
        )
    }

    fn progress(&self, id: &str, received: usize, total: Option<usize>) {
        let item = {
            let mut s = self.state();
            let Some(i) = s.items.iter_mut().find(|i| i.id == id) else {
                return;
            };
            let total = total.map(|t| t as i64).or((i.bytes > 0).then_some(i.bytes));
            i.state = CaptureState::Downloading {
                received: received as i64,
                total,
            };
            i.clone()
        };
        self.send(SessionEvent::Capture(Box::new(item)));
    }

    /// Captures left half-downloaded by a crash: card objects can be fetched
    /// again by handle; SDRAM ones are gone and marked failed.
    fn recover_pending_downloads(&self) {
        let pending: Vec<CaptureItem> = self
            .state()
            .items
            .iter()
            .filter(|i| !i.state.is_ready() && !i.state.is_failed())
            .cloned()
            .collect();
        for item in pending {
            if item.handle == 0 || item.handle >= 0xFFFF_0000 || item.handle == 0x8000_0001 {
                let mut f = item;
                f.state =
                    CaptureState::Failed("Lost when the app stopped (camera buffer only)".into());
                self.upsert(f);
            } else {
                {
                    let mut s = self.state();
                    s.known_handles.remove(&item.handle);
                    s.items.retain(|i| i.id != item.id);
                }
                let _ = self.inner.store.delete_capture(&item.id);
                self.handle(CameraEvent::ObjectAdded(NewObject::new(item.handle)));
            }
        }
    }

    // MARK: FTP push and file ingest

    /// A file the camera pushed to our FTP server, or one imported from disk:
    /// adopt it as a capture. `sidecar` is its XMP when the caller already
    /// matched one; otherwise `<name>.xmp` beside it is used.
    /// `consume_source` deletes the file and sidecar afterwards: only for
    /// private copies (FTP inbox, temporary import copies), never a user folder.
    pub async fn ingest_file(
        &self,
        path: &Path,
        _from: &str,
        sidecar: Option<&Path>,
        consume_source: bool,
    ) -> Option<CaptureItem> {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "capture".into());
        // A sidecar on its own is metadata, not a frame: apply it to the
        // frame (and its twin) already here, and remember it for the half
        // of the pair still to come.
        if extension(&name).eq_ignore_ascii_case("xmp") {
            let key = CaptureItem::pair_key_for(crate::cache::delete_extension(&name));
            if let Some(packet) = std::fs::read(path)
                .ok()
                .and_then(|d| XmpPacket::parse(&d).ok())
            {
                let targets: Vec<CaptureItem> = {
                    let mut s = self.state();
                    s.pending_sidecars.insert(key.clone(), packet.clone());
                    s.items
                        .iter()
                        .filter(|i| i.pair_key == key)
                        .cloned()
                        .collect()
                };
                for mut target in targets {
                    let tags = packet.apply_to(&mut target);
                    let id = target.id.clone();
                    self.upsert(target);
                    if !tags.is_empty() {
                        let _ = self.inner.store.add_tags(&tags, &[id]);
                    }
                }
            }
            if consume_source {
                let _ = std::fs::remove_file(path);
            }
            return None;
        }
        let session = self.session();
        let seq = self
            .inner
            .store
            .next_sequence(&session.id)
            .unwrap_or_else(|_| self.state().items.len() as i64 + 1);
        let kind = MediaKind::from_filename(&name);
        let mut item = CaptureItem::new(
            session.id.clone(),
            seq,
            seq as u32,
            name.clone(),
            kind,
            0,
            TransportKind::FtpPush,
        );
        item.look_id = session.look_id.clone();
        item.camera_id = self.inner.identity.as_ref().map(|i| i.id.clone());
        let mut incoming_tags: Vec<String> = Vec::new();
        let result: crate::Result<()> = async {
            let data = std::fs::read(path)?;
            item.bytes = data.len() as i64;
            let cache = &self.inner.cache;
            item.relative_path = Some(cache.store(&data, &cache.original_path(&session, &name))?);
            let out = self
                .inner
                .previews
                .make_previews(data.clone(), kind, name.clone())
                .await;
            item.width = out.width;
            item.height = out.height;
            if let Some(p) = out.proxy_jpeg {
                item.proxy_relative_path = cache.store(&p, &cache.proxy_path(&session, &name)).ok();
            }
            if let Some(t) = out.thumbnail_jpeg {
                item.thumbnail_relative_path =
                    cache.store(&t, &cache.thumbnail_path(&session, &name)).ok();
            }
            item.state = CaptureState::Ready;
            // Interop: metadata that came with the file (Photo Mechanic /
            // Capture One sidecar, or an embedded packet) seeds rating,
            // flag, label and tags.
            let mut candidates: Vec<PathBuf> = Vec::new();
            if let Some(s) = sidecar {
                candidates.push(s.to_path_buf());
            }
            candidates.push(path.with_extension("xmp"));
            let mut appended = path.as_os_str().to_owned();
            appended.push(".xmp");
            candidates.push(PathBuf::from(appended));
            let sidecar_path = candidates
                .iter()
                .find(|c| c.exists())
                .unwrap_or(&candidates[0])
                .clone();
            let pending = self.state().pending_sidecars.get(&item.pair_key).cloned();
            if let Some(packet) = std::fs::read(&sidecar_path)
                .ok()
                .and_then(|d| XmpPacket::parse(&d).ok())
            {
                incoming_tags = packet.apply_to(&mut item);
                self.state()
                    .pending_sidecars
                    .insert(item.pair_key.clone(), packet);
                if consume_source {
                    let _ = std::fs::remove_file(&sidecar_path);
                }
            } else if let Some(packet) = pending {
                incoming_tags = packet.apply_to(&mut item);
            } else if kind == MediaKind::Jpeg {
                if let Ok(packet) = jpeg_xmp::extract(&data) {
                    incoming_tags = packet.apply_to(&mut item);
                }
            }
            if consume_source {
                let _ = std::fs::remove_file(path);
            }
            self.upsert(item.clone());
            if !incoming_tags.is_empty() {
                let _ = self
                    .inner
                    .store
                    .add_tags(&incoming_tags, std::slice::from_ref(&item.id));
            }
            Ok(())
        }
        .await;
        if let Err(e) = result {
            item.state = CaptureState::Failed(e.to_string());
        }
        self.upsert(item.clone());
        let select = {
            let mut s = self.state();
            s.session.capture_count += 1;
            s.session.show_newest_capture || s.selected.is_none()
        };
        self.persist_session();
        if select {
            self.select(Some(item.id.clone()));
        }
        Some(item)
    }

    // MARK: Review

    pub fn select(&self, id: Option<String>) {
        self.state().selected = id.clone();
        self.send(SessionEvent::Selection(id));
    }

    pub fn set_routing(&self, routing: RoutingRules) {
        self.state().session.routing = routing;
        self.persist_session();
    }

    pub fn set_show_newest_capture(&self, on: bool) {
        let latest = {
            let mut s = self.state();
            s.session.show_newest_capture = on;
            s.items
                .iter()
                .rev()
                .find(|i| i.state.is_ready())
                .map(|i| i.id.clone())
        };
        self.persist_session();
        if let (true, Some(latest)) = (on, latest) {
            self.select(Some(latest));
        }
    }

    pub fn set_look(&self, stack: &LookStack) {
        {
            let mut s = self.state();
            s.session.look_id = stack.look_id.clone();
            s.session.look_strength = stack.strength;
        }
        self.persist_session();
    }

    fn item(&self, id: &str) -> Option<CaptureItem> {
        self.state().items.iter().find(|i| i.id == id).cloned()
    }

    fn twins(&self, item: &CaptureItem) -> Vec<CaptureItem> {
        self.state()
            .items
            .iter()
            .filter(|t| t.pair_key == item.pair_key && t.id != item.id)
            .cloned()
            .collect()
    }

    pub async fn rate(&self, id: &str, stars: i64) {
        let Some(mut item) = self.item(id) else {
            return;
        };
        item.set_rating(stars);
        self.upsert(item.clone());
        if let Some(h) = self
            .handler()
            .filter(|h| h.capabilities().contains(CameraCapabilities::RATING))
        {
            let _ = h.set_rating(item.handle, item.rating as i32).await;
        }
        // Keep the pair in sync.
        for mut twin in self.twins(&item) {
            twin.rating = item.rating;
            self.upsert(twin);
        }
    }

    /// Flag toggles: setting the flag it already has clears it.
    pub fn flag(&self, id: &str, flag: CaptureFlag) {
        let Some(mut item) = self.item(id) else {
            return;
        };
        item.flag = if item.flag == flag {
            CaptureFlag::None
        } else {
            flag
        };
        self.upsert(item.clone());
        for mut twin in self.twins(&item) {
            twin.flag = item.flag;
            self.upsert(twin);
        }
    }

    pub fn label(&self, id: &str, color: ColorLabel) {
        let Some(mut item) = self.item(id) else {
            return;
        };
        item.color_label = if item.color_label == color {
            ColorLabel::None
        } else {
            color
        };
        self.upsert(item.clone());
        for mut twin in self.twins(&item) {
            twin.color_label = item.color_label;
            self.upsert(twin);
        }
    }

    pub fn delete(&self, id: &str) {
        let Some(item) = self.item(id) else {
            return;
        };
        for p in [
            &item.relative_path,
            &item.proxy_relative_path,
            &item.thumbnail_relative_path,
        ]
        .into_iter()
        .flatten()
        {
            self.inner.cache.remove(p);
        }
        let reselect = {
            let mut s = self.state();
            s.items.retain(|i| i.id != id);
            (s.selected.as_deref() == Some(id)).then(|| {
                s.items
                    .iter()
                    .rev()
                    .find(|i| i.state.is_ready())
                    .map(|i| i.id.clone())
            })
        };
        let _ = self.inner.store.delete_capture(id);
        self.send(SessionEvent::Removed(id.to_string()));
        if let Some(next) = reselect {
            self.select(next);
        }
    }

    pub fn rename(&self, name: &str) {
        self.state().session.name = name.to_string();
        self.persist_session();
    }

    /// The library edited one of our captures (rating, flag, label): take
    /// the stored version so the filmstrip agrees without a second write.
    pub fn replace_from_store(&self, item: &CaptureItem) {
        let previous_rating = {
            let mut s = self.state();
            if item.session_id != s.session.id {
                return;
            }
            let Some(slot) = s.items.iter_mut().find(|i| i.id == item.id) else {
                return;
            };
            let previous = slot.rating;
            *slot = item.clone();
            previous
        };
        self.send(SessionEvent::Capture(Box::new(item.clone())));
        // Library edits reach the camera too when it keeps ratings.
        if item.rating != previous_rating {
            if let Some(h) = self
                .handler()
                .filter(|h| h.capabilities().contains(CameraCapabilities::RATING))
            {
                let (handle, stars) = (item.handle, item.rating as i32);
                if let Ok(rt) = tokio::runtime::Handle::try_current() {
                    rt.spawn(async move {
                        let _ = h.set_rating(handle, stars).await;
                    });
                }
            }
        }
    }

    pub fn update_transport_health(&self, health: TransportHealth) {
        self.state().transport_health = Some(health);
    }

    // MARK: Internals

    fn upsert(&self, item: CaptureItem) {
        {
            let mut s = self.state();
            match s.items.iter_mut().find(|i| i.id == item.id) {
                Some(slot) => *slot = item.clone(),
                None => s.items.push(item.clone()),
            }
        }
        let _ = self.inner.store.save_capture(&item);
        self.send(SessionEvent::Capture(Box::new(item)));
    }

    fn persist_session(&self) {
        let s = self.session();
        let _ = self.inner.store.save_session(&s);
    }

    fn set_status(&self, status: TetherStatus) {
        self.state().status = status.clone();
        self.send(SessionEvent::Status(status));
    }

    fn warn(&self, s: impl Into<String>) {
        self.send(SessionEvent::Warning(s.into()));
    }

    fn send(&self, e: SessionEvent) {
        let _ = self.inner.events.send(e);
    }
}

impl LiveCaptureHook for TetherSession {
    fn replace_from_store(&self, items: &[CaptureItem]) {
        for i in items {
            TetherSession::replace_from_store(self, i);
        }
    }
}

fn apply_info(info: &PtpObjectInfo, item: &mut CaptureItem) {
    if !info.filename.is_empty() {
        item.filename = info.filename.clone();
        item.pair_key = CaptureItem::pair_key_for(&info.filename);
    }
    item.kind = library_kind(info.media_kind());
    if info.object_compressed_size > 0 {
        item.bytes = info.object_compressed_size as i64;
    }
    if info.image_pix_width > 0 {
        item.width = info.image_pix_width as i64;
        item.height = info.image_pix_height as i64;
    }
    if let Some(d) = info.capture_date_value() {
        item.captured_at = d;
    }
}
