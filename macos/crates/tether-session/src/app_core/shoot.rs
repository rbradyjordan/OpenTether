//! Sessions and the live shoot (`AppModel` session handling,
//! `ShootViewModel`, `DemoSession`, `FilesImport`).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use tether_library::interop::FileImportPlan;
use tether_library::library::WorkspaceMemory;
use tether_library::looks::LookStack;
use tether_library::{RoutingRules, SessionStatus, ShootSession};
use tether_ptp::{FocusResult, TetherProperty};
use tether_types::{CameraCapabilities, CaptureDestination, LiveViewQuality, TransportKind};

use super::{ActiveShoot, AppCore};
use crate::error::{lock, Error, Result};
use crate::events::{
    AppEvent, CaptureDto, CountsDto, PropertyDto, PropertyInput, SessionDto, ShootStateDto,
    ToastKind,
};
use crate::session::connect::{self, LiveConnection};
use crate::session::{
    ReconnectContext, ReconnectPolicy, ReconnectStrategy, TetherSession, TetherStatus,
};

impl AppCore {
    // MARK: Sessions

    pub(crate) fn session_dto(&self, s: &ShootSession) -> SessionDto {
        let counts = self
            .inner
            .store
            .counts(&s.id)
            .map(CountsDto::from)
            .unwrap_or_default();
        SessionDto::new(s, counts)
    }

    /// Every session, newest first, with tallies.
    pub fn list_sessions(&self) -> Result<Vec<SessionDto>> {
        Ok(self
            .inner
            .store
            .sessions(10_000)?
            .iter()
            .map(|s| self.session_dto(s))
            .collect())
    }

    /// Sessions cut off by a crash or quit, except the live one.
    pub fn interrupted_sessions(&self) -> Result<Vec<SessionDto>> {
        let live = self.active_session_id();
        Ok(self
            .inner
            .store
            .interrupted_sessions()?
            .iter()
            .filter(|s| Some(&s.id) != live.as_ref())
            .map(|s| self.session_dto(s))
            .collect())
    }

    pub fn session(&self, id: &str) -> Result<SessionDto> {
        Ok(self.session_dto(&self.load_session(id)?))
    }

    pub(crate) fn load_session(&self, id: &str) -> Result<ShootSession> {
        // The live session's copy is the newest.
        if let Some(s) = lock(&self.inner.active)
            .as_ref()
            .map(|a| a.session.session())
            .filter(|s| s.id == id)
        {
            return Ok(s);
        }
        self.inner
            .store
            .session(id)?
            .ok_or_else(|| Error::NotFound(format!("Session {id}")))
    }

    /// A new session configured from a template (or the remembered
    /// defaults). An empty name is filled from the template's pattern.
    pub fn create_session(
        &self,
        name: Option<String>,
        template_id: Option<String>,
    ) -> Result<SessionDto> {
        let s = self.new_session(name.unwrap_or_default(), template_id.as_deref())?;
        self.emit(AppEvent::SessionsChanged);
        Ok(self.session_dto(&s))
    }

    pub(crate) fn new_session(
        &self,
        name: String,
        template_id: Option<&str>,
    ) -> Result<ShootSession> {
        let memory = &self.inner.memory;
        let template =
            template_id.and_then(|id| memory.templates().into_iter().find(|t| t.id == id));
        let mut s = ShootSession::new(name.trim());
        let index = self.inner.store.sessions(10_000)?.len() as i64 + 1;
        memory.configure(&mut s, template.as_ref(), None, index);
        if s.name.is_empty() {
            let d = memory.get(WorkspaceMemory::SESSION_DEFAULTS);
            s.name = d
                .name_pattern
                .replace(
                    "{date}",
                    &chrono::Local::now().format("%Y-%m-%d").to_string(),
                )
                .replace("{camera}", "Shoot")
                .replace("{name}", "Shoot")
                .replace("{n}", &format!("{index:03}"))
                .trim()
                .to_string();
        }
        self.inner.store.save_session(&s)?;
        Ok(s)
    }

    /// Renames a session; the live one goes through its `TetherSession` so
    /// a later save from the shoot doesn't put the old name back.
    pub fn rename_session(&self, id: &str, name: &str) -> Result<()> {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return Ok(());
        }
        match self.live_session_with_id(id) {
            Some(live) => live.rename(trimmed),
            None => {
                let mut s = self.load_session(id)?;
                s.name = trimmed.to_string();
                self.inner.store.save_session(&s)?;
            }
        }
        self.emit(AppEvent::SessionsChanged);
        Ok(())
    }

    /// Deletes a session, its captures and their files.
    pub async fn delete_session(&self, id: &str) -> Result<()> {
        if self.active_session_id().as_deref() == Some(id) {
            self.end_shoot().await?;
        }
        if let Some(s) = self.inner.store.session(id)? {
            self.inner.cache.remove_session(&s);
        }
        self.inner.store.delete_session(id)?;
        self.emit(AppEvent::SessionsChanged);
        Ok(())
    }

    /// "Don't resume": mark an interrupted session ended.
    pub fn dismiss_interrupted(&self, id: &str) -> Result<()> {
        let mut s = self.load_session(id)?;
        s.status = SessionStatus::Ended;
        s.ended_at = Some(Utc::now());
        self.inner.store.save_session(&s)?;
        self.emit(AppEvent::SessionsChanged);
        Ok(())
    }

    /// Resume a session from the store without a camera: the shoot then
    /// offers reconnect based on the stored transport and last host. FTP
    /// sessions just need the receiver listening again.
    pub async fn resume_session(&self, id: &str) -> Result<ShootStateDto> {
        let mut s = self.load_session(id)?;
        s.status = SessionStatus::Active;
        self.inner.store.save_session(&s)?;
        let tether = TetherSession::new(
            s.clone(),
            s.camera.clone(),
            None,
            None,
            self.inner.store.clone(),
            self.inner.cache.clone(),
            Some(self.inner.previews.clone()),
        );
        let context = ReconnectContext::from_session(&s);
        let ftp = context == ReconnectContext::Ftp;
        if ftp {
            if !self.ftp_status().is_running {
                self.ftp_start().await?;
            }
            tether.start().await?;
        }
        let connection = LiveConnection {
            session: tether,
            shoot: s,
            identity: None,
            context,
            needs_reconnect: !ftp,
        };
        Ok(self.activate(connection).await)
    }

    pub fn templates(&self) -> Vec<tether_library::library::memory::SessionTemplate> {
        self.inner.memory.templates()
    }

    /// "Save as template" from a session as it was shot.
    pub fn save_template_from_session(
        &self,
        session_id: &str,
        name: &str,
    ) -> Result<tether_library::library::memory::SessionTemplate> {
        let s = self.load_session(session_id)?;
        let t = self.inner.memory.template_from(&s, name);
        self.inner.memory.save_template(&t);
        Ok(t)
    }

    pub fn delete_template(&self, id: &str) {
        self.inner.memory.delete_template(id);
    }

    /// Set (or clear) the session's hot folder.
    pub fn set_hot_folder(&self, session_id: &str, folder_id: Option<String>) -> Result<()> {
        let mut s = self.load_session(session_id)?;
        s.routing.live_folder_id = folder_id;
        match self.live_session_with_id(session_id) {
            Some(live) => live.set_routing(s.routing),
            None => self.inner.store.save_session(&s)?,
        }
        self.emit(AppEvent::SessionsChanged);
        Ok(())
    }

    // MARK: The live shoot

    pub(crate) fn active_session(&self) -> Result<TetherSession> {
        lock(&self.inner.active)
            .as_ref()
            .map(|a| a.session.clone())
            .ok_or_else(|| Error::msg("No shoot is open."))
    }

    pub(crate) fn active_session_id(&self) -> Option<String> {
        lock(&self.inner.active)
            .as_ref()
            .map(|a| a.session.session().id)
    }

    fn live_session_with_id(&self, id: &str) -> Option<TetherSession> {
        lock(&self.inner.active)
            .as_ref()
            .map(|a| a.session.clone())
            .filter(|s| s.session().id == id)
    }

    /// Makes a connection the live shoot (ending any other one).
    pub(crate) async fn activate(&self, connection: LiveConnection) -> ShootStateDto {
        let previous = lock(&self.inner.active).take();
        if let Some(mut prev) = previous {
            prev.abort_tasks();
            if prev.session.session().id != connection.shoot.id {
                prev.session.stop(true).await;
                if let Some(a) = &prev.automations {
                    a.session_ended(prev.session.session());
                }
            }
        }
        let session = connection.session.clone();
        self.inner.editor.attach(Some(Arc::new(session.clone())));
        let forwarder = self.forward_session(&session);
        let (automations, automations_task) = self.start_automations(&session.session());
        *lock(&self.inner.active) = Some(ActiveShoot {
            session,
            context: connection.context.clone(),
            forwarder: Some(forwarder),
            automations: Some(automations),
            automations_task: Some(automations_task),
            reconnect_task: None,
            reconnecting: false,
            reconnect_error: None,
            pending_reconnect: connection.needs_reconnect,
            demo_task: None,
        });
        let state = self.shoot_state_inner();
        if connection.needs_reconnect {
            self.emit(AppEvent::ConnectionStatus {
                session_id: connection.shoot.id.clone(),
                status: state.status.clone(),
                text: state.status_text.clone(),
            });
        }
        self.emit(AppEvent::ShootStarted {
            shoot: Box::new(state.clone()),
        });
        self.emit(AppEvent::SessionsChanged);
        state
    }

    /// The live shoot, if one is open.
    pub fn shoot_state(&self) -> Option<ShootStateDto> {
        lock(&self.inner.active).as_ref()?;
        Some(self.shoot_state_inner())
    }

    fn shoot_state_inner(&self) -> ShootStateDto {
        let (session, context, reconnecting, pending, error) = {
            let a = lock(&self.inner.active);
            let a = a.as_ref().expect("checked by caller");
            (
                a.session.clone(),
                a.context.clone(),
                a.reconnecting,
                a.pending_reconnect,
                a.reconnect_error.clone(),
            )
        };
        let snap = session.snapshot();
        let caps = session.capabilities();
        let identity = snap.identity.clone().or(snap.session.camera.clone());
        let status = if reconnecting {
            TetherStatus::Reconnecting
        } else if pending {
            TetherStatus::Disconnected(
                error.unwrap_or_else(|| "Resumed after the app was closed".into()),
            )
        } else {
            snap.status.clone()
        };
        let strategy = ReconnectStrategy::choose(&context);
        let camera_name = match &identity {
            Some(i) => i.display_name().to_string(),
            None if snap.session.workflow_tag.as_deref() == Some(crate::demo::TAG) => {
                "Demo camera".into()
            }
            None if snap.session.transport == Some(TransportKind::FtpPush) => "FTP receiver".into(),
            None => "No camera".into(),
        };
        ShootStateDto {
            session: self.session_dto(&snap.session),
            transport_name: identity
                .as_ref()
                .map(|i| i.transport)
                .or(snap.session.transport)
                .map(|t| t.display_name().to_string())
                .unwrap_or_default(),
            identity: identity.clone(),
            camera_name,
            status_text: status.text(),
            status,
            items: snap.items.iter().map(CaptureDto::from).collect(),
            properties: snap.properties.iter().map(PropertyDto::from).collect(),
            selected_item_id: snap.selected_item_id.clone(),
            live_view_active: snap.live_view_active,
            downloads_in_flight: snap.downloads_in_flight,
            can_capture: caps.contains(CameraCapabilities::REMOTE_CAPTURE),
            can_live_view: caps.contains(CameraCapabilities::LIVE_VIEW),
            can_touch_focus: caps.contains(CameraCapabilities::TOUCH_AUTOFOCUS),
            can_control_properties: caps.contains(CameraCapabilities::PROPERTY_CONTROL),
            is_import_only: identity.is_some()
                && !caps.contains(CameraCapabilities::REMOTE_CAPTURE),
            reconnect_title: strategy.title(),
            reconnect_detail: strategy.detail(),
            reconnect: strategy,
            is_reconnecting: reconnecting,
        }
    }

    /// Ends the live shoot: the session is closed, memory learns from it,
    /// pending auto-exports go out.
    pub async fn end_shoot(&self) -> Result<()> {
        let Some(mut active) = lock(&self.inner.active).take() else {
            return Ok(());
        };
        active.abort_tasks();
        active.session.stop(true).await;
        let final_session = active.session.session();
        match &active.automations {
            Some(a) => a.session_ended(final_session.clone()),
            None => self.inner.memory.learn(&final_session),
        }
        self.inner.editor.attach(None);
        *lock(&self.inner.live_frame) = None;
        self.emit(AppEvent::ShootEnded {
            session_id: final_session.id,
        });
        self.emit(AppEvent::SessionsChanged);
        Ok(())
    }

    pub async fn capture(&self, autofocus: bool) -> Result<()> {
        let s = self.active_session()?;
        if !s
            .capabilities()
            .contains(CameraCapabilities::REMOTE_CAPTURE)
        {
            return Err(Error::msg("This camera can't be fired remotely."));
        }
        s.capture(autofocus).await?;
        Ok(())
    }

    /// One-shot AF at the centre of the frame.
    pub async fn autofocus(&self) -> Result<FocusResult> {
        self.focus_at(0.5, 0.5).await
    }

    /// Touch AF at a point of the live-view frame, 0…1 from the top left.
    pub async fn focus_at(&self, x: f64, y: f64) -> Result<FocusResult> {
        Ok(self.active_session()?.focus(x, y).await?)
    }

    pub async fn start_tracking_focus(&self, x: f64, y: f64) -> Result<()> {
        Ok(self.active_session()?.start_tracking_focus(x, y).await?)
    }

    pub async fn stop_tracking_focus(&self) -> Result<()> {
        self.active_session()?.stop_tracking_focus().await;
        Ok(())
    }

    pub async fn start_live_view(&self, quality: Option<LiveViewQuality>) -> Result<()> {
        let s = self.active_session()?;
        let q = quality.unwrap_or(lock(&self.inner.settings).live_view_quality);
        s.start_live_view(q).await?;
        self.emit(AppEvent::LiveViewState {
            active: s.live_view_active(),
        });
        Ok(())
    }

    pub async fn stop_live_view(&self) -> Result<()> {
        let s = self.active_session()?;
        // Back to the photo at once; the camera catches up behind it.
        self.emit(AppEvent::LiveViewState { active: false });
        *lock(&self.inner.live_frame) = None;
        s.stop_live_view().await;
        Ok(())
    }

    pub fn properties(&self) -> Result<Vec<PropertyDto>> {
        Ok(self
            .active_session()?
            .properties()
            .iter()
            .map(PropertyDto::from)
            .collect())
    }

    pub async fn refresh_properties(&self) -> Result<Vec<PropertyDto>> {
        let s = self.active_session()?;
        s.refresh_properties().await;
        Ok(s.properties().iter().map(PropertyDto::from).collect())
    }

    pub async fn set_property(&self, property: TetherProperty, input: PropertyInput) -> Result<()> {
        let s = self.active_session()?;
        let desc = s
            .properties()
            .into_iter()
            .find(|p| p.property == property)
            .ok_or_else(|| Error::msg(format!("{} is not available.", property.display_name())))?;
        let value = input
            .to_value(&desc)
            .ok_or_else(|| Error::msg("That value is not one the camera offers."))?;
        s.set_property(property, value)
            .await
            .map_err(|e| Error::msg(format!("{}: {e}", property.display_name())))
    }

    pub fn select_capture(&self, id: Option<String>) -> Result<()> {
        self.active_session()?.select(id);
        Ok(())
    }

    pub fn set_show_newest_capture(&self, on: bool) -> Result<()> {
        self.active_session()?.set_show_newest_capture(on);
        Ok(())
    }

    pub async fn set_destination(&self, destination: CaptureDestination) -> Result<()> {
        Ok(self.active_session()?.set_destination(destination).await?)
    }

    pub fn set_routing(&self, session_id: &str, routing: RoutingRules) -> Result<()> {
        match self.live_session_with_id(session_id) {
            Some(live) => live.set_routing(routing),
            None => {
                let mut s = self.load_session(session_id)?;
                s.routing = routing;
                self.inner.store.save_session(&s)?;
            }
        }
        Ok(())
    }

    /// The look new frames and exports of a session use.
    pub fn set_session_look(&self, session_id: &str, look: LookStack) -> Result<()> {
        match self.live_session_with_id(session_id) {
            Some(live) => live.set_look(&look),
            None => {
                let mut s = self.load_session(session_id)?;
                s.look_id = look.look_id.clone();
                s.look_strength = look.strength;
                self.inner.store.save_session(&s)?;
            }
        }
        Ok(())
    }

    // MARK: Reconnect

    /// Re-open the dropped link the way it was made (USB: wait for the
    /// camera to come back; Wi-Fi: redial with backoff). Returns at once;
    /// progress arrives as `Reconnect` and `ConnectionStatus` events.
    pub fn reconnect(&self) -> Result<ReconnectStrategy> {
        let (old, context) = {
            let mut a = lock(&self.inner.active);
            let a = a.as_mut().ok_or_else(|| Error::msg("No shoot is open."))?;
            if a.reconnecting {
                return Ok(ReconnectStrategy::choose(&a.context));
            }
            (a.session.clone(), a.context.clone())
        };
        let strategy = ReconnectStrategy::choose(&context);
        if matches!(
            strategy,
            ReconnectStrategy::NothingToDo | ReconnectStrategy::StartFresh
        ) {
            return Ok(strategy);
        }
        if let Some(a) = lock(&self.inner.active).as_mut() {
            a.reconnecting = true;
            a.reconnect_error = None;
        }
        self.emit_reconnect(&strategy, true, None);
        let this = self.clone();
        let st = strategy.clone();
        let task = tokio::spawn(async move {
            // The old session cannot swap transports: close it first so the
            // new one (over the same stored shoot) owns the camera.
            old.stop(false).await;
            let shoot = old.session();
            let result = this.reconnect_with(&st, &shoot).await;
            match result {
                Ok(connection) => this.adopt(connection),
                Err(e) => {
                    let msg = e.to_string();
                    if let Some(a) = lock(&this.inner.active).as_mut() {
                        a.reconnecting = false;
                        a.reconnect_error = Some(msg.clone());
                        a.reconnect_task = None;
                    }
                    this.emit_reconnect(&st, false, Some(msg.clone()));
                    this.emit(AppEvent::ConnectionStatus {
                        session_id: shoot.id,
                        status: TetherStatus::Disconnected(msg.clone()),
                        text: msg,
                    });
                }
            }
        });
        if let Some(a) = lock(&self.inner.active).as_mut().filter(|a| a.reconnecting) {
            a.reconnect_task = Some(task);
        }
        Ok(strategy)
    }

    pub fn cancel_reconnect(&self) {
        let strategy = {
            let mut a = lock(&self.inner.active);
            let Some(a) = a.as_mut() else { return };
            if let Some(t) = a.reconnect_task.take() {
                t.abort();
            }
            a.reconnecting = false;
            a.reconnect_error = Some("Reconnect cancelled".into());
            ReconnectStrategy::choose(&a.context)
        };
        self.emit_reconnect(&strategy, false, Some("Reconnect cancelled".into()));
    }

    fn emit_reconnect(&self, s: &ReconnectStrategy, reconnecting: bool, error: Option<String>) {
        self.emit(AppEvent::Reconnect {
            reconnecting,
            strategy: s.clone(),
            title: s.title(),
            detail: s.detail(),
            error,
        });
    }

    async fn reconnect_with(
        &self,
        strategy: &ReconnectStrategy,
        shoot: &ShootSession,
    ) -> Result<LiveConnection> {
        let services = self.connect_services();
        let mut policy = ReconnectPolicy::new(
            shoot,
            shoot.camera.as_ref(),
            None,
            ReconnectPolicy::DEFAULT_MAX_ATTEMPTS,
        );
        loop {
            let attempt = match strategy {
                ReconnectStrategy::WaitForUsbDevice { serial } => {
                    return self.reconnect_usb(serial.clone(), shoot).await;
                }
                ReconnectStrategy::RetryHost { host, port, vendor } => {
                    connect::connect_ptpip(host, *port, *vendor, shoot, &services, None).await
                }
                ReconnectStrategy::RetryRicoh { host } => {
                    connect::connect_http(
                        tether_types::CameraVendor::Ricoh,
                        host,
                        shoot,
                        &services,
                        None,
                    )
                    .await
                }
                ReconnectStrategy::RetryHttp { host, vendor } => {
                    connect::connect_http(*vendor, host, shoot, &services, None).await
                }
                ReconnectStrategy::NothingToDo | ReconnectStrategy::StartFresh => {
                    return Err(Error::msg(strategy.detail()));
                }
            };
            match attempt {
                Ok(c) => return Ok(c),
                Err(e) => match policy.next_delay() {
                    Some(d) => tokio::time::sleep(d).await,
                    None => return Err(e),
                },
            }
        }
    }

    #[cfg(target_os = "macos")]
    async fn reconnect_usb(
        &self,
        serial: Option<String>,
        shoot: &ShootSession,
    ) -> Result<LiveConnection> {
        let browser = &self.inner.usb;
        let mut rx = browser.events();
        browser.start().await;
        let candidate = loop {
            let list = browser.candidates();
            let pick = match &serial {
                Some(s) => list
                    .iter()
                    .find(|c| c.serial_number.as_deref() == Some(s.as_str()))
                    .or(list.first()),
                None => list.first(),
            };
            if let Some(c) = pick {
                break c.clone();
            }
            if rx.recv().await.is_none() {
                return Err(crate::ConnectError::DeviceGone.into());
            }
        };
        connect::connect_usb(
            browser,
            &candidate.id,
            candidate.serial_number.clone(),
            shoot,
            &self.connect_services(),
            None,
        )
        .await
    }

    #[cfg(not(target_os = "macos"))]
    async fn reconnect_usb(
        &self,
        _serial: Option<String>,
        _shoot: &ShootSession,
    ) -> Result<LiveConnection> {
        Err(Error::msg("USB is only available on macOS."))
    }

    /// Swap the live shoot's link for a fresh connection, keeping the
    /// automations and the shoot.
    fn adopt(&self, connection: LiveConnection) {
        let session = connection.session.clone();
        let forwarder = self.forward_session(&session);
        self.inner.editor.attach(Some(Arc::new(session.clone())));
        let name = connection
            .identity
            .as_ref()
            .map(|i| i.display_name().to_string())
            .unwrap_or_else(|| "the camera".into());
        let strategy = {
            let mut a = lock(&self.inner.active);
            let Some(a) = a.as_mut() else { return };
            if let Some(f) = a.forwarder.replace(forwarder) {
                f.abort();
            }
            a.session = session;
            a.context = connection.context.clone();
            a.reconnecting = false;
            a.reconnect_error = None;
            a.pending_reconnect = false;
            a.reconnect_task = None;
            ReconnectStrategy::choose(&a.context)
        };
        self.emit_reconnect(&strategy, false, None);
        let state = self.shoot_state_inner();
        self.emit(AppEvent::ConnectionStatus {
            session_id: state.session.id.clone(),
            status: state.status.clone(),
            text: state.status_text.clone(),
        });
        self.emit(AppEvent::ShootStarted {
            shoot: Box::new(state),
        });
        self.toast(format!("Reconnected to {name}"), ToastKind::Success);
    }

    // MARK: FTP-push session

    /// A shoot that only collects what cameras push to the FTP receiver
    /// (started if it isn't running).
    pub async fn start_ftp_session(&self, session_id: Option<String>) -> Result<ShootStateDto> {
        if !self.ftp_status().is_running {
            self.ftp_start().await?;
        }
        let shoot = match session_id {
            Some(id) => self.load_session(&id)?,
            None => self.new_session(String::new(), None)?,
        };
        let connection = connect::start_ftp_session(&shoot, &self.connect_services()).await?;
        Ok(self.activate(connection).await)
    }

    // MARK: Demo

    /// A shoot without a camera: frames arrive one by one, `pace` apart
    /// (zero drops them all at once), so the whole app can be tried.
    pub async fn start_demo(&self, pace: Duration) -> Result<ShootStateDto> {
        if let Some(state) = self.shoot_state() {
            return Ok(state);
        }
        let mut shoot = ShootSession::new(crate::demo::NAME);
        shoot.workflow_tag = Some(crate::demo::TAG.into());
        let connection = connect::start_ftp_session(&shoot, &self.connect_services()).await?;
        let session = connection.session.clone();
        let state = self.activate(connection).await;
        let this = self.clone();
        let (w, h) = self.inner.demo_frame_size;
        let task = tokio::spawn(async move {
            let dir =
                std::env::temp_dir().join(format!("open-tether-demo-{}", uuid::Uuid::new_v4()));
            if std::fs::create_dir_all(&dir).is_err() {
                return;
            }
            for i in 0..crate::demo::FRAME_COUNT {
                if i > 0 && !pace.is_zero() {
                    tokio::time::sleep(pace).await;
                }
                // Stop if the demo was ended or another session took over.
                let still_live = lock(&this.inner.active)
                    .as_ref()
                    .is_some_and(|a| a.session.same_session(&session));
                if !still_live {
                    break;
                }
                let data = tokio::task::spawn_blocking(move || crate::demo::frame(i, w, h))
                    .await
                    .unwrap_or_default();
                let path = dir.join(crate::demo::filename(i));
                if std::fs::write(&path, data).is_ok() {
                    session.ingest_file(&path, "demo", None, true).await;
                }
            }
            let _ = std::fs::remove_dir_all(&dir);
        });
        if let Some(a) = lock(&self.inner.active).as_mut() {
            a.demo_task = Some(task);
        }
        Ok(state)
    }

    // MARK: Import

    /// Import files or folders (with their XMP sidecars) into the live shoot
    /// when there is one (and no other target is given), else into
    /// `target`, else into a new "Import" session. The user's files are
    /// never modified: each is copied out first. Returns how many frames
    /// were imported.
    pub async fn import_files(&self, paths: Vec<PathBuf>, target: Option<String>) -> Result<usize> {
        let mut files = Vec::new();
        for p in paths {
            if p.is_dir() {
                files.extend(FileImportPlan::files_under(&p));
            } else {
                files.push(p);
            }
        }
        let plan = FileImportPlan::new(&files);
        if plan.entries.is_empty() {
            self.toast("No photos found there", ToastKind::Warning);
            return Ok(0);
        }
        let live = self
            .active_session()
            .ok()
            .filter(|s| target.is_none() || target.as_deref() == Some(s.session().id.as_str()));
        let (session, detached) = match live {
            Some(s) => (s, false),
            None => {
                let shoot = match &target {
                    Some(id) => self.load_session(id)?,
                    None => {
                        let s = ShootSession::new(format!(
                            "Import {}",
                            chrono::Local::now().format("%Y-%m-%d %H:%M")
                        ));
                        self.inner.store.save_session(&s)?;
                        s
                    }
                };
                let tether = TetherSession::new(
                    shoot.clone(),
                    shoot.camera.clone(),
                    None,
                    None,
                    self.inner.store.clone(),
                    self.inner.cache.clone(),
                    Some(self.inner.previews.clone()),
                );
                (tether, true)
            }
        };
        let mut imported = 0;
        for entry in &plan.entries {
            // A private copy (file + sidecar side by side); ingest consumes it.
            let tmp = std::env::temp_dir().join(format!("import-{}", uuid::Uuid::new_v4()));
            let copied = (|| -> std::io::Result<(PathBuf, Option<PathBuf>)> {
                std::fs::create_dir_all(&tmp)?;
                let copy = tmp.join(entry.file.file_name().unwrap_or_default());
                std::fs::copy(&entry.file, &copy)?;
                let sidecar = entry.sidecar.as_ref().and_then(|s| {
                    let dest = tmp.join(s.file_name()?);
                    std::fs::copy(s, &dest).ok().map(|_| dest)
                });
                Ok((copy, sidecar))
            })();
            match copied {
                Ok((copy, sidecar)) => {
                    session
                        .ingest_file(&copy, "Files", sidecar.as_deref(), true)
                        .await;
                    imported += 1;
                }
                Err(_) => self.toast(
                    format!(
                        "Could not read {}",
                        entry.file.file_name().unwrap_or_default().to_string_lossy()
                    ),
                    ToastKind::Warning,
                ),
            }
            let _ = std::fs::remove_dir_all(&tmp);
        }
        if detached {
            session.stop(true).await;
        }
        self.emit(AppEvent::SessionsChanged);
        self.toast(
            format!(
                "Imported {imported} frame{}",
                if imported == 1 { "" } else { "s" }
            ),
            ToastKind::Success,
        );
        Ok(imported)
    }
}
