//! Session automations (`Library/SessionAutomations.swift`).
//!
//! The hands-free parts of a power user's workflow, driven by the session's
//! template and routing:
//!
//! - every frame that lands gets the template's tags and joins its collection;
//! - when `auto_export_picks` is on, a frame flagged Pick is exported with the
//!   remembered export settings, debounced so a burst of picks becomes one job;
//! - when the session ends, memory learns from it.
//!
//! It only observes (the editor's events, plus the live session's capture and
//! end notifications that the session crate forwards), so it is testable
//! without a camera.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;

use crate::capture_item::{CaptureFlag, CaptureItem, MediaKind, ShootSession};
use crate::delivery::{ExportDestination, ExportJob, ExportOptions, ExportQueue};
use crate::library::editor::{EditorEvent, ReviewEditor};
use crate::library::memory::{SessionTemplate, WorkspaceMemory};
use crate::looks::LookStack;
use crate::store::SessionStore;

fn default_debounce() -> f64 {
    2.0
}

/// What happens automatically during a session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AutomationRules {
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(
        rename = "addToCollectionID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub add_to_collection_id: Option<String>,
    #[serde(rename = "autoExportPicks", default)]
    pub auto_export_picks: bool,
    #[serde(rename = "autoExportDestination")]
    pub auto_export_destination: ExportDestination,
    #[serde(rename = "autoExportOptions", default)]
    pub auto_export_options: ExportOptions,
    /// Seconds.
    #[serde(default = "default_debounce")]
    pub debounce: f64,
}

impl Default for AutomationRules {
    fn default() -> Self {
        Self {
            tags: Vec::new(),
            add_to_collection_id: None,
            auto_export_picks: false,
            auto_export_destination: ExportDestination::Photos,
            auto_export_options: ExportOptions::default(),
            debounce: 2.0,
        }
    }
}

impl AutomationRules {
    /// Rules for a session: the template's tags and collection (else the
    /// remembered session defaults' tags), the session's auto-export switch
    /// and the last export's destination and options.
    pub fn from_template(
        template: Option<&SessionTemplate>,
        session: &ShootSession,
        memory: &WorkspaceMemory,
    ) -> Self {
        let last = memory.get(WorkspaceMemory::LAST_EXPORT);
        Self {
            tags: template
                .map(|t| t.tags.clone())
                .unwrap_or_else(|| memory.get(WorkspaceMemory::SESSION_DEFAULTS).tags),
            add_to_collection_id: template.and_then(|t| t.add_to_collection_id.clone()),
            auto_export_picks: session.routing.auto_export_picks,
            auto_export_destination: last.destination,
            auto_export_options: last.options,
            debounce: 2.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum AutomationEvent {
    Tagged { capture_id: String },
    AddedToCollection { capture_id: String },
    ExportQueued(Box<ExportJob>),
    Error(String),
}

#[derive(Default)]
struct State {
    session: Option<ShootSession>,
    seen: HashSet<String>,
    pending_picks: HashSet<String>,
    exported_picks: HashSet<String>,
    debounce: Option<JoinHandle<()>>,
    tasks: Vec<JoinHandle<()>>,
}

struct Inner {
    store: Arc<SessionStore>,
    editor: Arc<ReviewEditor>,
    queue: Option<ExportQueue>,
    memory: Arc<WorkspaceMemory>,
    rules: Mutex<AutomationRules>,
    state: Mutex<State>,
    events: broadcast::Sender<AutomationEvent>,
}

/// See the module docs. Cloning shares the automations.
#[derive(Clone)]
pub struct SessionAutomations {
    inner: Arc<Inner>,
}

impl SessionAutomations {
    pub fn new(
        session: ShootSession,
        rules: AutomationRules,
        store: Arc<SessionStore>,
        editor: Arc<ReviewEditor>,
        queue: Option<ExportQueue>,
        memory: Arc<WorkspaceMemory>,
    ) -> Self {
        let (events, _) = broadcast::channel(128);
        Self {
            inner: Arc::new(Inner {
                store,
                editor,
                queue,
                memory,
                rules: Mutex::new(rules),
                state: Mutex::new(State {
                    session: Some(session),
                    ..Default::default()
                }),
                events,
            }),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AutomationEvent> {
        self.inner.events.subscribe()
    }

    pub fn rules(&self) -> AutomationRules {
        self.inner
            .rules
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    pub fn update_rules(&self, rules: AutomationRules) {
        *self.inner.rules.lock().unwrap_or_else(|e| e.into_inner()) = rules;
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.inner.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn session_id(&self) -> Option<String> {
        self.state().session.as_ref().map(|s| s.id.clone())
    }

    fn emit(&self, e: AutomationEvent) {
        let _ = self.inner.events.send(e);
    }

    /// Start observing the editor (must run inside a Tokio runtime). The
    /// session crate also forwards [`Self::capture_ready`] and
    /// [`Self::session_ended`] from the live shoot.
    pub fn attach(&self) {
        self.stop();
        let mut rx = self.inner.editor.subscribe();
        let weak = Arc::downgrade(&self.inner);
        let task = tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(EditorEvent::Changed(ids)) => {
                        let Some(inner) = weak.upgrade() else { return };
                        SessionAutomations { inner }.on_edited(&ids);
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
        });
        self.state().tasks.push(task);
    }

    pub fn stop(&self) {
        let mut s = self.state();
        for t in s.tasks.drain(..) {
            t.abort();
        }
        if let Some(d) = s.debounce.take() {
            d.abort();
        }
    }

    // MARK: Reactions

    /// A capture finished downloading in the live session.
    pub fn capture_ready(&self, item: &CaptureItem) {
        if !item.state.is_ready() || self.session_id().as_deref() != Some(item.session_id.as_str())
        {
            return;
        }
        if !self.state().seen.insert(item.id.clone()) {
            return;
        }
        let rules = self.rules();
        let ids = [item.id.clone()];
        if !rules.tags.is_empty() {
            match self.inner.store.add_tags(&rules.tags, &ids) {
                Ok(()) => self.emit(AutomationEvent::Tagged {
                    capture_id: item.id.clone(),
                }),
                Err(e) => self.emit(AutomationEvent::Error(e.to_string())),
            }
        }
        if let Some(cid) = &rules.add_to_collection_id {
            match self.inner.store.add_to_collection(&ids, cid) {
                Ok(()) => self.emit(AutomationEvent::AddedToCollection {
                    capture_id: item.id.clone(),
                }),
                Err(e) => self.emit(AutomationEvent::Error(e.to_string())),
            }
        }
        if rules.auto_export_picks && item.flag == CaptureFlag::Pick {
            self.schedule_pick(&item.id);
        }
    }

    fn on_edited(&self, ids: &[String]) {
        if !self.rules().auto_export_picks {
            return;
        }
        let Some(session_id) = self.session_id() else {
            return;
        };
        for item in self.inner.store.captures_by_ids(ids).unwrap_or_default() {
            if item.session_id == session_id
                && item.flag == CaptureFlag::Pick
                && item.state.is_ready()
                && item.kind != MediaKind::Raw
            {
                self.schedule_pick(&item.id);
            }
        }
    }

    fn schedule_pick(&self, id: &str) {
        let delay = Duration::from_secs_f64(self.rules().debounce.max(0.0));
        let mut s = self.state();
        if s.exported_picks.contains(id) {
            return;
        }
        s.pending_picks.insert(id.to_string());
        if let Some(d) = s.debounce.take() {
            d.abort();
        }
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let weak = Arc::downgrade(&self.inner);
        s.debounce = Some(handle.spawn(async move {
            tokio::time::sleep(delay).await;
            if let Some(inner) = weak.upgrade() {
                SessionAutomations { inner }.flush_picks();
            }
        }));
    }

    /// Enqueue one export job for everything picked since the last flush.
    pub fn flush_picks(&self) {
        let Some(queue) = &self.inner.queue else {
            return;
        };
        let (ids, session) = {
            let mut s = self.state();
            if s.pending_picks.is_empty() {
                return;
            }
            let ids: Vec<String> = s.pending_picks.drain().collect();
            s.exported_picks.extend(ids.iter().cloned());
            (ids, s.session.clone())
        };
        let Some(session) = session else { return };
        let rules = self.rules();
        let result = self.inner.store.captures_by_ids(&ids).and_then(|caps| {
            let job = queue.make_job(
                &session,
                &caps,
                rules.auto_export_destination.clone(),
                rules.auto_export_options.clone(),
                LookStack::new(session.look_id.clone(), session.look_strength),
            );
            if !job.items.is_empty() {
                queue.enqueue(&job)?;
            }
            Ok(job)
        });
        match result {
            Ok(job) if !job.items.is_empty() => {
                self.emit(AutomationEvent::ExportQueued(Box::new(job)))
            }
            Ok(_) => {}
            Err(e) => {
                let mut s = self.state();
                for id in &ids {
                    s.exported_picks.remove(id);
                }
                drop(s);
                self.emit(AutomationEvent::Error(format!("Auto-export failed: {e}")));
            }
        }
    }

    /// The live session ended: memory learns from it and pending picks go out.
    pub fn session_ended(&self, final_session: ShootSession) {
        self.inner.memory.learn(&final_session);
        self.state().session = Some(final_session);
        self.flush_picks();
    }

    pub fn pending_pick_count(&self) -> usize {
        self.state().pending_picks.len()
    }
}
