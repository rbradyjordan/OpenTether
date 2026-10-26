//! Between-session memory (`Library/WorkspaceMemory.swift`).
//!
//! Everything a power user would otherwise re-set every shoot: how the last
//! session was configured, what this camera was last used with, which
//! collection they were looking at and how, recent tags, saved session
//! templates. Backed by the store's `settings` table as typed JSON blobs
//! with defaults, so a missing key is never an error.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Local, Utc};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tether_types::{CameraIdentity, CaptureDestination};

use crate::capture_item::{RoutingRules, ShootSession};
use crate::delivery::{ExportDestination, ExportOptions};
use crate::interop::xmp::MetadataProfile;
use crate::library::{CaptureFilter, CaptureSort};
use crate::looks::LookStack;
use crate::store::SessionStore;
use crate::swift_json;

/// A typed settings key with its default.
pub struct Key<T> {
    /// Full settings key, e.g. `memory.session.defaults`.
    pub name: &'static str,
    pub default: fn() -> T,
}

impl<T> Clone for Key<T> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<T> Copy for Key<T> {}

fn default_true() -> bool {
    true
}

/// How the last session was set up; the New Session sheet starts here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SessionDefaults {
    pub destination: CaptureDestination,
    pub routing: RoutingRules,
    pub look: LookStack,
    #[serde(rename = "showNewestCapture")]
    pub show_newest_capture: bool,
    #[serde(rename = "autoExportPicks")]
    pub auto_export_picks: bool,
    #[serde(rename = "namePattern")]
    pub name_pattern: String,
    pub tags: Vec<String>,
    #[serde(rename = "templateID", skip_serializing_if = "Option::is_none")]
    pub template_id: Option<String>,
}

impl Default for SessionDefaults {
    fn default() -> Self {
        Self {
            destination: CaptureDestination::Both,
            routing: RoutingRules::default(),
            look: LookStack::default(),
            show_newest_capture: true,
            auto_export_picks: false,
            name_pattern: "{date} {camera}".into(),
            tags: Vec::new(),
            template_id: None,
        }
    }
}

/// Per-camera memory: the last look, destination and exposure the body was
/// left at, so reconnecting a known camera restores its working state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CameraMemory {
    #[serde(rename = "cameraID")]
    pub camera_id: String,
    #[serde(rename = "lastSeen", with = "swift_json::date")]
    pub last_seen: DateTime<Utc>,
    pub look: LookStack,
    pub destination: CaptureDestination,
    /// `TetherProperty` raw value → display string.
    #[serde(rename = "lastExposure", with = "swift_json::pair_array_map", default)]
    pub last_exposure: BTreeMap<String, String>,
    #[serde(
        rename = "templateID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub template_id: Option<String>,
    #[serde(
        rename = "connectionHost",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub connection_host: Option<String>,
}

impl CameraMemory {
    pub fn new(camera_id: impl Into<String>) -> Self {
        Self {
            camera_id: camera_id.into(),
            last_seen: Utc::now(),
            look: LookStack::default(),
            destination: CaptureDestination::Both,
            last_exposure: BTreeMap::new(),
            template_id: None,
            connection_host: None,
        }
    }
}

/// How the library was last viewed, per collection, so coming back lands
/// on the same frame with the same filter, sort and zoom.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ViewState {
    pub filter: CaptureFilter,
    pub sort: CaptureSort,
    pub columns: i64,
    #[serde(rename = "stackPairs")]
    pub stack_pairs: bool,
    #[serde(rename = "scrollToCaptureID", skip_serializing_if = "Option::is_none")]
    pub scroll_to_capture_id: Option<String>,
    #[serde(rename = "inspectorOpen")]
    pub inspector_open: bool,
}

impl Default for ViewState {
    fn default() -> Self {
        Self {
            filter: CaptureFilter::default(),
            sort: CaptureSort::CaptureTimeDescending,
            columns: 3,
            stack_pairs: true,
            scroll_to_capture_id: None,
            inspector_open: false,
        }
    }
}

/// Last export configuration, so "export again" is one click.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ExportMemory {
    pub destination: ExportDestination,
    pub options: ExportOptions,
    pub scope: String,
}

impl Default for ExportMemory {
    fn default() -> Self {
        Self {
            destination: ExportDestination::Photos,
            options: ExportOptions::default(),
            scope: "picks".into(),
        }
    }
}

/// Recents: the small lists that make the app feel like it knows you.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Recents {
    pub tags: Vec<String>,
    #[serde(rename = "collectionIDs")]
    pub collection_ids: Vec<String>,
    #[serde(rename = "ftpDestinationIDs")]
    pub ftp_destination_ids: Vec<String>,
    pub searches: Vec<String>,
}

fn push_recent(list: &mut Vec<String>, v: &str, max: usize) {
    list.retain(|x| x != v);
    list.insert(0, v.to_string());
    list.truncate(max);
}

/// A saved way of shooting: "Headshots", "Lookbook", "Client review day".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionTemplate {
    pub id: String,
    pub name: String,
    pub symbol: String,
    pub destination: CaptureDestination,
    pub routing: RoutingRules,
    pub look: LookStack,
    #[serde(rename = "showNewestCapture", default = "default_true")]
    pub show_newest_capture: bool,
    #[serde(rename = "autoExportPicks", default)]
    pub auto_export_picks: bool,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(rename = "namePattern")]
    pub name_pattern: String,
    #[serde(
        rename = "addToCollectionID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub add_to_collection_id: Option<String>,
    #[serde(rename = "useCount", default)]
    pub use_count: i64,
    #[serde(
        rename = "lastUsed",
        with = "swift_json::opt_date",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub last_used: Option<DateTime<Utc>>,
}

impl SessionTemplate {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            name: name.into(),
            symbol: "camera.aperture".into(),
            destination: CaptureDestination::Both,
            routing: RoutingRules::default(),
            look: LookStack::default(),
            show_newest_capture: true,
            auto_export_picks: false,
            tags: Vec::new(),
            name_pattern: "{date} {name}".into(),
            add_to_collection_id: None,
            use_count: 0,
            last_used: None,
        }
    }

    /// Expand `{date}`, `{name}`, `{camera}`, `{n}` for a new session name.
    pub fn session_name(
        &self,
        camera: Option<&CameraIdentity>,
        index: i64,
        now: DateTime<Utc>,
    ) -> String {
        let date = now.with_timezone(&Local).format("%Y-%m-%d").to_string();
        self.name_pattern
            .replace("{date}", &date)
            .replace("{name}", &self.name)
            .replace(
                "{camera}",
                camera.map(|c| c.display_name()).unwrap_or("Camera"),
            )
            .replace("{n}", &format!("{index:03}"))
            .trim_matches([' ', '\t'])
            .to_string()
    }
}

/// Between-session memory over the store's settings table.
pub struct WorkspaceMemory {
    store: Arc<SessionStore>,
    lock: Mutex<()>,
}

impl WorkspaceMemory {
    pub const SESSION_DEFAULTS: Key<SessionDefaults> = Key {
        name: "memory.session.defaults",
        default: SessionDefaults::default,
    };
    const CAMERAS: Key<HashMap<String, CameraMemory>> = Key {
        name: "memory.cameras",
        default: HashMap::new,
    };
    const VIEWS: Key<HashMap<String, ViewState>> = Key {
        name: "memory.library.views",
        default: HashMap::new,
    };
    pub const LAST_COLLECTION_ID: Key<String> = Key {
        name: "memory.library.lastCollection",
        default: || "builtin.all".to_string(),
    };
    pub const LAST_EXPORT: Key<ExportMemory> = Key {
        name: "memory.export.last",
        default: ExportMemory::default,
    };
    pub const RECENTS: Key<Recents> = Key {
        name: "memory.recents",
        default: Recents::default,
    };
    const TEMPLATES: Key<Vec<SessionTemplate>> = Key {
        name: "memory.session.templates",
        default: Vec::new,
    };
    /// Who shot it; applied to every export.
    pub const METADATA_PROFILE: Key<MetadataProfile> = Key {
        name: "memory.interop.metadata",
        default: MetadataProfile::default,
    };

    pub fn new(store: Arc<SessionStore>) -> Self {
        Self {
            store,
            lock: Mutex::new(()),
        }
    }

    fn guard(&self) -> std::sync::MutexGuard<'_, ()> {
        self.lock.lock().unwrap_or_else(|e| e.into_inner())
    }

    // MARK: Generic typed access

    pub fn get<T: DeserializeOwned>(&self, key: Key<T>) -> T {
        self.store
            .setting(key.name)
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_else(key.default)
    }

    pub fn set<T: Serialize>(&self, key: Key<T>, value: &T) {
        if let Ok(s) = serde_json::to_string(value) {
            self.store.set_setting(key.name, Some(&s));
        }
    }

    pub fn clear<T>(&self, key: Key<T>) {
        self.store.set_setting(key.name, None);
    }

    // MARK: Cameras

    pub fn camera(&self, id: &str) -> Option<CameraMemory> {
        self.get(Self::CAMERAS).remove(id)
    }

    pub fn remember_camera(&self, camera: CameraMemory) {
        let _g = self.guard();
        let mut all = self.get(Self::CAMERAS);
        all.insert(camera.camera_id.clone(), camera);
        self.set(Self::CAMERAS, &all);
    }

    /// `(TetherProperty raw value, display)` pairs read from the body.
    pub fn remember_exposure<'a>(
        &self,
        camera_id: &str,
        props: impl IntoIterator<Item = (&'a str, &'a str)>,
    ) {
        let _g = self.guard();
        let mut all = self.get(Self::CAMERAS);
        let mut m = all
            .remove(camera_id)
            .unwrap_or_else(|| CameraMemory::new(camera_id));
        for (p, display) in props {
            m.last_exposure.insert(p.to_string(), display.to_string());
        }
        m.last_seen = Utc::now();
        all.insert(camera_id.to_string(), m);
        self.set(Self::CAMERAS, &all);
    }

    // MARK: Views

    pub fn view_state(&self, collection_id: &str) -> ViewState {
        self.get(Self::VIEWS)
            .remove(collection_id)
            .unwrap_or_default()
    }

    pub fn set_view_state(&self, state: ViewState, collection_id: &str) {
        let _g = self.guard();
        let mut all = self.get(Self::VIEWS);
        all.insert(collection_id.to_string(), state);
        self.set(Self::VIEWS, &all);
        self.set(Self::LAST_COLLECTION_ID, &collection_id.to_string());
    }

    // MARK: Recents

    pub fn note_tag(&self, t: &str) {
        self.mutate_recents(|r| push_recent(&mut r.tags, t, 10));
    }

    pub fn note_collection(&self, id: &str) {
        self.mutate_recents(|r| push_recent(&mut r.collection_ids, id, 10));
    }

    pub fn note_search(&self, s: &str) {
        if !s.is_empty() {
            self.mutate_recents(|r| push_recent(&mut r.searches, s, 10));
        }
    }

    pub fn note_ftp(&self, id: &str) {
        self.mutate_recents(|r| push_recent(&mut r.ftp_destination_ids, id, 10));
    }

    fn mutate_recents(&self, f: impl FnOnce(&mut Recents)) {
        let _g = self.guard();
        let mut r = self.get(Self::RECENTS);
        f(&mut r);
        self.set(Self::RECENTS, &r);
    }

    // MARK: Session templates

    /// Most recently used first, then most used.
    pub fn templates(&self) -> Vec<SessionTemplate> {
        let mut all = self.get(Self::TEMPLATES);
        all.sort_by(|a, b| {
            let ka = (a.last_used.unwrap_or(DateTime::<Utc>::MIN_UTC), a.use_count);
            let kb = (b.last_used.unwrap_or(DateTime::<Utc>::MIN_UTC), b.use_count);
            kb.cmp(&ka)
        });
        all
    }

    pub fn save_template(&self, template: &SessionTemplate) {
        let _g = self.guard();
        self.save_template_locked(template);
    }

    fn save_template_locked(&self, template: &SessionTemplate) {
        let mut all = self.get(Self::TEMPLATES);
        match all.iter_mut().find(|t| t.id == template.id) {
            Some(t) => *t = template.clone(),
            None => all.push(template.clone()),
        }
        self.set(Self::TEMPLATES, &all);
    }

    pub fn delete_template(&self, id: &str) {
        let _g = self.guard();
        let all: Vec<SessionTemplate> = self
            .get(Self::TEMPLATES)
            .into_iter()
            .filter(|t| t.id != id)
            .collect();
        self.set(Self::TEMPLATES, &all);
    }

    /// Build a template from a session as it was shot ("Save as template").
    pub fn template_from(&self, session: &ShootSession, name: &str) -> SessionTemplate {
        let mut t = SessionTemplate::new(name);
        t.destination = session.destination;
        t.routing = session.routing.clone();
        t.look = LookStack::new(session.look_id.clone(), session.look_strength);
        t.show_newest_capture = session.show_newest_capture;
        t.auto_export_picks = session.routing.auto_export_picks;
        t
    }

    /// The suggestion for a new session: the template this camera used last,
    /// else the most recent template.
    pub fn suggested_template(&self, camera: Option<&CameraIdentity>) -> Option<SessionTemplate> {
        let all = self.get(Self::TEMPLATES);
        if let Some(cam) = camera {
            if let Some(id) = self.camera(&cam.id).and_then(|m| m.template_id) {
                if let Some(t) = all.iter().find(|t| t.id == id) {
                    return Some(t.clone());
                }
            }
        }
        self.templates().into_iter().next()
    }

    /// Apply a template (or the remembered defaults) to a new session and
    /// record the use.
    pub fn configure(
        &self,
        session: &mut ShootSession,
        template: Option<&SessionTemplate>,
        camera: Option<&CameraIdentity>,
        index: i64,
    ) {
        if let Some(t) = template {
            let mut t = t.clone();
            session.destination = t.destination;
            session.routing = t.routing.clone();
            session.look_id = t.look.look_id.clone();
            session.look_strength = t.look.strength;
            session.show_newest_capture = t.show_newest_capture;
            session.routing.auto_export_picks = t.auto_export_picks;
            if session.name.is_empty() {
                session.name = t.session_name(camera, index, Utc::now());
            }
            t.use_count += 1;
            t.last_used = Some(Utc::now());
            self.save_template(&t);
            let mut d = self.get(Self::SESSION_DEFAULTS);
            d.template_id = Some(t.id.clone());
            self.set(Self::SESSION_DEFAULTS, &d);
        } else {
            let d = self.get(Self::SESSION_DEFAULTS);
            session.destination = d.destination;
            session.routing = d.routing;
            session.look_id = d.look.look_id;
            session.look_strength = d.look.strength;
            session.show_newest_capture = d.show_newest_capture;
        }
        if let Some(cam) = camera {
            let mut m = self
                .camera(&cam.id)
                .unwrap_or_else(|| CameraMemory::new(&cam.id));
            if let Some(t) = template {
                m.template_id = Some(t.id.clone());
            }
            m.destination = session.destination;
            m.look = LookStack::new(session.look_id.clone(), session.look_strength);
            m.last_seen = Utc::now();
            self.remember_camera(m);
        }
    }

    /// Call when a session ends so the next one starts where this left off.
    pub fn learn(&self, session: &ShootSession) {
        let mut d = self.get(Self::SESSION_DEFAULTS);
        d.destination = session.destination;
        d.routing = session.routing.clone();
        d.look = LookStack::new(session.look_id.clone(), session.look_strength);
        d.show_newest_capture = session.show_newest_capture;
        d.auto_export_picks = session.routing.auto_export_picks;
        self.set(Self::SESSION_DEFAULTS, &d);
        if let Some(cam) = &session.camera {
            let mut m = self
                .camera(&cam.id)
                .unwrap_or_else(|| CameraMemory::new(&cam.id));
            m.look = d.look.clone();
            m.destination = d.destination;
            m.connection_host = session.last_host.clone().or(m.connection_host);
            m.last_seen = Utc::now();
            self.remember_camera(m);
        }
    }
}
