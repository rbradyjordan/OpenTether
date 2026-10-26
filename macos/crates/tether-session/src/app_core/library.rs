//! The library: queries, review commands with undo, collections, tags,
//! looks and catalog sync (`LibraryModel`, `CommandDispatcher`).

use std::collections::{BTreeSet, HashSet};
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tether_library::interop::{match_catalog, read_entries, CatalogChange};
use tether_library::library::memory::ViewState;
use tether_library::library::{
    CaptureFilter, CaptureSort, Collection, CollectionKind, Command, CommandContext, Commands,
    WorkspaceMemory,
};
use tether_library::looks::{
    color_match_frames, CpuLookRenderer, CubeLut, LookDescriptor, LookRendering, LookStack,
};
use tether_library::{CaptureFlag, CaptureItem, ColorLabel};
use tether_types::CameraIdentity;

use super::{AppCore, ImageKind};
use crate::error::{Error, Result};
use crate::events::{AppEvent, CaptureDto, CollectionDto, ToastKind};

/// What the grid shows. Sessions and cameras are "All photos" narrowed by id.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "camelCase")]
pub enum LibrarySource {
    Collection(String),
    Session(String),
    Camera(String),
}

impl Default for LibrarySource {
    fn default() -> Self {
        Self::Collection("builtin.all".into())
    }
}

impl LibrarySource {
    /// Key for workspace memory's view state.
    pub fn memory_key(&self) -> String {
        match self {
            Self::Collection(id) => id.clone(),
            Self::Session(id) => format!("session:{id}"),
            Self::Camera(id) => format!("camera:{id}"),
        }
    }

    pub fn from_memory_key(key: &str) -> Self {
        if let Some(id) = key.strip_prefix("session:") {
            Self::Session(id.into())
        } else if let Some(id) = key.strip_prefix("camera:") {
            Self::Camera(id.into())
        } else {
            Self::Collection(key.into())
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LibraryQuery {
    pub source: LibrarySource,
    /// The filter bar; `None` = the source's remembered filter.
    pub filter: Option<CaptureFilter>,
    pub sort: Option<CaptureSort>,
    /// Filename / session name / tag contains.
    pub search: Option<String>,
    /// Page size (default 600, like iOS).
    pub limit: Option<i64>,
    pub offset: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryPage {
    pub items: Vec<CaptureDto>,
    pub total: i64,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryStatsDto {
    pub captures: i64,
    pub sessions: i64,
    pub picks: i64,
    pub rated: i64,
    pub bytes: i64,
    pub cameras: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownCameraDto {
    pub identity: CameraIdentity,
    pub host: Option<String>,
    pub last_seen: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogChangeDto {
    pub capture_id: String,
    pub filename: String,
    pub rating: Option<i64>,
    pub flag: Option<CaptureFlag>,
    pub label: Option<ColorLabel>,
    pub new_keywords: Vec<String>,
}

impl From<&CatalogChange> for CatalogChangeDto {
    fn from(c: &CatalogChange) -> Self {
        Self {
            capture_id: c.capture_id.clone(),
            filename: c.filename.clone(),
            rating: c.rating,
            flag: c.flag,
            label: c.label,
            new_keywords: c.new_keywords.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogPreview {
    pub catalog: String,
    pub changes: Vec<CatalogChangeDto>,
    pub unmatched: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookDto {
    pub id: String,
    pub name: String,
    pub family: String,
    pub size: i64,
    pub is_built_in: bool,
}

impl From<&LookDescriptor> for LookDto {
    fn from(l: &LookDescriptor) -> Self {
        Self {
            id: l.id.clone(),
            name: l.name.clone(),
            family: l.family.clone(),
            size: l.size,
            is_built_in: l.cube_url.starts_with("builtin:"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportRecordDto {
    pub destination: String,
    pub at: DateTime<Utc>,
    pub remote_id: Option<String>,
}

/// Fields to change on a collection (`None` leaves it as is).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CollectionUpdate {
    pub name: Option<String>,
    pub symbol: Option<String>,
    pub tint: Option<ColorLabel>,
    pub pinned: Option<bool>,
    pub sort_order: Option<i64>,
    pub rule: Option<CaptureFilter>,
}

pub const PAGE_SIZE: i64 = 600;

impl AppCore {
    // MARK: Queries

    /// One page of the grid for a source, filter, sort and search, as the
    /// iOS library loads it: smart collections page in SQL, manual ones keep
    /// their hand order.
    pub fn library_query(&self, q: &LibraryQuery) -> Result<LibraryPage> {
        let store = &self.inner.store;
        let state = self.view_state(&q.source);
        let mut filter = q.filter.clone().unwrap_or(state.filter);
        if let Some(text) = &q.search {
            let t = text.trim();
            filter.text = (!t.is_empty()).then(|| t.to_string());
        }
        let sort = q.sort.unwrap_or(state.sort);
        let collection_id = match &q.source {
            LibrarySource::Collection(id) => id.clone(),
            _ => "builtin.all".into(),
        };
        let collection = store
            .collection(&collection_id)?
            .ok_or_else(|| Error::NotFound(format!("Collection {collection_id}")))?;
        let mut extra = filter;
        let title = match &q.source {
            LibrarySource::Collection(_) => collection.name.clone(),
            LibrarySource::Session(id) => {
                extra.session_ids = Some(BTreeSet::from([id.clone()]));
                store
                    .session(id)?
                    .map(|s| s.name)
                    .unwrap_or_else(|| "Session".into())
            }
            LibrarySource::Camera(id) => {
                extra.camera_ids = Some(BTreeSet::from([id.clone()]));
                store
                    .known_cameras()?
                    .into_iter()
                    .find(|k| &k.identity.id == id)
                    .map(|k| k.identity.display_name().to_string())
                    .unwrap_or_else(|| "Camera".into())
            }
        };
        let limit = q.limit.unwrap_or(PAGE_SIZE);
        let (items, total) = match collection.kind {
            CollectionKind::Smart => {
                let rule = collection.rule.clone().unwrap_or_default().merged(&extra);
                (
                    store.captures_matching(&rule, sort, Some(limit), q.offset)?,
                    store.count_matching(&rule)?,
                )
            }
            CollectionKind::Manual => {
                let narrowed = (!(extra.is_empty() && extra.ready_only)).then_some(&extra);
                let sort = (sort != CaptureSort::CaptureTimeDescending).then_some(sort);
                let all = store.captures_in_collection(&collection, narrowed, sort, None, 0)?;
                let total = all.len() as i64;
                let start = (q.offset.max(0) as usize).min(all.len());
                let end = (start + limit.max(0) as usize).min(all.len());
                (all[start..end].to_vec(), total)
            }
        };
        Ok(LibraryPage {
            items: items.iter().map(CaptureDto::from).collect(),
            total,
            title,
        })
    }

    /// How a source was last viewed (filter, sort, columns…).
    pub fn view_state(&self, source: &LibrarySource) -> ViewState {
        self.inner.memory.view_state(&source.memory_key())
    }

    pub fn set_view_state(&self, source: &LibrarySource, state: ViewState) {
        self.inner
            .memory
            .set_view_state(state, &source.memory_key());
        if let LibrarySource::Collection(id) = source {
            self.inner
                .memory
                .set(WorkspaceMemory::LAST_COLLECTION_ID, id);
        }
    }

    pub fn last_library_source(&self) -> LibrarySource {
        LibrarySource::from_memory_key(&self.inner.memory.get(WorkspaceMemory::LAST_COLLECTION_ID))
    }

    pub fn get_capture(&self, id: &str) -> Result<CaptureDto> {
        self.inner
            .store
            .capture(id)?
            .map(|c| CaptureDto::from(&c))
            .ok_or_else(|| Error::NotFound(format!("Capture {id}")))
    }

    pub fn captures(&self, ids: &[String]) -> Result<Vec<CaptureDto>> {
        Ok(self
            .inner
            .store
            .captures_by_ids(ids)?
            .iter()
            .map(CaptureDto::from)
            .collect())
    }

    /// Ids in view order, for select-all and range selection.
    pub fn capture_ids(&self, q: &LibraryQuery) -> Result<Vec<String>> {
        let mut all = q.clone();
        all.offset = 0;
        all.limit = Some(i64::MAX / 2);
        Ok(self
            .library_query(&all)?
            .items
            .into_iter()
            .map(|c| c.id)
            .collect())
    }

    pub fn library_stats(&self) -> Result<LibraryStatsDto> {
        let s = self.inner.store.library_stats()?;
        Ok(LibraryStatsDto {
            captures: s.captures,
            sessions: s.sessions,
            picks: s.picks,
            rated: s.rated,
            bytes: s.bytes,
            cameras: s.cameras,
        })
    }

    pub fn known_cameras(&self) -> Result<Vec<KnownCameraDto>> {
        Ok(self
            .inner
            .store
            .known_cameras()?
            .into_iter()
            .map(|k| KnownCameraDto {
                identity: k.identity,
                host: k.host,
                last_seen: k.last_seen,
            })
            .collect())
    }

    pub fn tags(&self, capture_id: &str) -> Result<Vec<String>> {
        Ok(self.inner.store.tags(capture_id)?)
    }

    pub fn tag_suggestions(&self, prefix: &str) -> Result<Vec<String>> {
        Ok(self.inner.store.tag_suggestions(prefix, 20)?)
    }

    /// Every delivery of a capture (destination key, when, remote id).
    pub fn export_history(&self, capture_id: &str) -> Result<Vec<ExportRecordDto>> {
        Ok(self
            .inner
            .store
            .export_history(capture_id)?
            .into_iter()
            .map(|r| ExportRecordDto {
                destination: r.destination,
                at: r.at,
                remote_id: r.remote_id,
            })
            .collect())
    }

    // MARK: Review (every edit is one undo step)

    fn edited(&self, r: tether_library::Result<()>, what: &str) -> Result<()> {
        r.map_err(|e| {
            let e = Error::msg(format!("{what} failed: {e}"));
            self.toast(e.to_string(), ToastKind::Error);
            e
        })
    }

    pub fn rate(&self, ids: &[String], stars: i64) -> Result<()> {
        self.edited(self.inner.editor.rate(ids, stars), "Rate")
    }

    /// Sets the flag (send `None` to clear).
    pub fn flag(&self, ids: &[String], flag: CaptureFlag) -> Result<()> {
        self.edited(self.inner.editor.flag(ids, flag), "Flag")
    }

    pub fn label(&self, ids: &[String], color: ColorLabel) -> Result<()> {
        self.edited(self.inner.editor.label(ids, color), "Label")
    }

    pub fn add_tags(&self, tags: &[String], ids: &[String]) -> Result<()> {
        self.edited(self.inner.editor.add_tags(tags, ids), "Tag")
    }

    pub fn remove_tags(&self, tags: &[String], ids: &[String]) -> Result<()> {
        self.edited(self.inner.editor.remove_tags(tags, ids), "Remove tag")
    }

    pub fn add_to_collection(&self, ids: &[String], collection_id: &str) -> Result<()> {
        self.edited(
            self.inner.editor.add_to_collection(ids, collection_id),
            "Add to collection",
        )
    }

    pub fn remove_from_collection(&self, ids: &[String], collection_id: &str) -> Result<()> {
        self.edited(
            self.inner.editor.remove_from_collection(ids, collection_id),
            "Remove from collection",
        )
    }

    /// Undo the last review edit; returns its title ("Rate 4★").
    pub fn undo(&self) -> Result<Option<String>> {
        let edit = self.inner.editor.undo()?;
        if let Some(e) = &edit {
            self.toast(format!("Undid {}", e.title), ToastKind::Info);
        }
        Ok(edit.map(|e| e.title))
    }

    pub fn redo(&self) -> Result<Option<String>> {
        let edit = self.inner.editor.redo()?;
        if let Some(e) = &edit {
            self.toast(format!("Redid {}", e.title), ToastKind::Info);
        }
        Ok(edit.map(|e| e.title))
    }

    /// (undo title, redo title).
    pub fn undo_state(&self) -> (Option<String>, Option<String>) {
        (
            self.inner.editor.undo_title(),
            self.inner.editor.redo_title(),
        )
    }

    /// Removes files and rows; frames of the live shoot go through it so
    /// the filmstrip stays in step.
    pub fn delete_captures(&self, ids: &[String]) -> Result<()> {
        let live = self.active_session().ok();
        let live_ids: HashSet<String> = live
            .as_ref()
            .map(|s| s.snapshot().items.into_iter().map(|i| i.id).collect())
            .unwrap_or_default();
        for id in ids {
            if live_ids.contains(id) {
                if let Some(s) = &live {
                    s.delete(id);
                }
            } else if let Some(item) = self.inner.store.capture(id)? {
                remove_files(self, &item);
                self.inner.store.delete_capture(id)?;
            }
        }
        self.emit(AppEvent::LibraryChanged { ids: ids.to_vec() });
        self.emit(AppEvent::SessionsChanged);
        Ok(())
    }

    /// The commands that apply right now (menus, palette, shortcuts).
    pub fn available_commands(
        &self,
        selection_count: usize,
        collection_id: Option<&str>,
        in_shoot: bool,
    ) -> Vec<Command> {
        let live = self.active_session().ok();
        let ctx = CommandContext {
            selection_count,
            in_live_session: live
                .as_ref()
                .is_some_and(|s| in_shoot || s.status().is_live()),
            camera_capabilities: live.map(|s| s.capabilities()).unwrap_or_default(),
            in_collection: collection_id
                .and_then(|id| self.inner.store.collection(id).ok().flatten()),
            can_undo: self.inner.editor.can_undo(),
            can_redo: self.inner.editor.can_redo(),
        };
        Commands::available(&ctx)
    }

    pub fn search_commands(&self, query: &str, selection_count: usize) -> Vec<Command> {
        let ctx = CommandContext {
            selection_count,
            in_live_session: self.active_session().is_ok(),
            can_undo: self.inner.editor.can_undo(),
            can_redo: self.inner.editor.can_redo(),
            ..Default::default()
        };
        Commands::search(query, &ctx)
    }

    // MARK: Collections

    pub fn collections(&self) -> Result<Vec<CollectionDto>> {
        let store = &self.inner.store;
        Ok(store
            .collections()?
            .iter()
            .map(|c| CollectionDto::new(c, store.count_in_collection(c).unwrap_or(0)))
            .collect())
    }

    /// A manual collection, optionally seeded with a selection.
    pub fn create_collection(
        &self,
        name: &str,
        ids: &[String],
        symbol: Option<&str>,
        tint: Option<ColorLabel>,
    ) -> Result<CollectionDto> {
        let c = self.inner.editor.create_collection(
            name,
            ids,
            symbol.unwrap_or("rectangle.stack"),
            tint.unwrap_or(ColorLabel::None),
        )?;
        self.toast(format!("Created {}", c.name), ToastKind::Success);
        Ok(CollectionDto::new(
            &c,
            self.inner.store.count_in_collection(&c).unwrap_or(0),
        ))
    }

    /// Save a filter as a smart collection.
    pub fn save_smart_collection(
        &self,
        name: &str,
        rule: CaptureFilter,
        symbol: Option<&str>,
    ) -> Result<CollectionDto> {
        let c =
            self.inner
                .editor
                .save_smart_collection(name, rule, symbol.unwrap_or("gearshape"))?;
        Ok(CollectionDto::new(
            &c,
            self.inner.store.count_in_collection(&c).unwrap_or(0),
        ))
    }

    /// Rename, re-tint, pin, re-order or change a smart rule.
    pub fn update_collection(&self, id: &str, update: CollectionUpdate) -> Result<CollectionDto> {
        let CollectionUpdate {
            name,
            symbol,
            tint,
            pinned,
            sort_order,
            rule,
        } = update;
        let mut c: Collection = self
            .inner
            .store
            .collection(id)?
            .ok_or_else(|| Error::NotFound(format!("Collection {id}")))?;
        if c.is_built_in && (name.is_some() || rule.is_some()) {
            return Err(Error::msg("Built-in collections can't be changed."));
        }
        if let Some(n) = name.filter(|n| !n.trim().is_empty()) {
            c.name = n.trim().into();
        }
        if let Some(s) = symbol {
            c.symbol = s;
        }
        if let Some(t) = tint {
            c.tint = t;
        }
        if let Some(p) = pinned {
            c.is_pinned = p;
        }
        if let Some(o) = sort_order {
            c.sort_order = o;
        }
        if let (Some(r), CollectionKind::Smart) = (rule, c.kind) {
            c.rule = Some(r);
        }
        self.inner.store.save_collection(&c)?;
        Ok(CollectionDto::new(
            &c,
            self.inner.store.count_in_collection(&c).unwrap_or(0),
        ))
    }

    pub fn delete_collection(&self, id: &str) -> Result<()> {
        Ok(self.inner.store.delete_collection(id)?)
    }

    /// Hand order of a manual collection.
    pub fn reorder_collection(&self, collection_id: &str, ids: &[String]) -> Result<()> {
        Ok(self.inner.store.reorder(ids, collection_id)?)
    }

    // MARK: Looks

    pub fn looks(&self) -> Result<Vec<LookDto>> {
        Ok(self
            .inner
            .store
            .looks()?
            .iter()
            .map(LookDto::from)
            .collect())
    }

    /// Import a `.cube` file as a look.
    pub fn import_cube(&self, path: &Path, name: Option<&str>) -> Result<LookDto> {
        let bytes = std::fs::read(path)?;
        let text = String::from_utf8(bytes.clone())
            .map_err(|_| Error::msg("That .cube file is not text."))?;
        let lut = CubeLut::parse(&text)
            .map_err(|e| Error::msg(format!("Not a usable .cube file: {e}")))?;
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "Imported look".into());
        let title = name
            .map(str::to_string)
            .or_else(|| (!lut.title().is_empty()).then(|| lut.title().to_string()))
            .unwrap_or(stem);
        self.save_look(&title, "Imported", lut.size() as i64, bytes)
    }

    fn save_look(&self, name: &str, family: &str, size: i64, cube: Vec<u8>) -> Result<LookDto> {
        let id = format!("user-{}", uuid::Uuid::new_v4().simple());
        let desc = LookDescriptor::new(&id, name, family, size, &format!("local:{id}"));
        self.inner.store.save_look(&desc, Some(&cube))?;
        self.inner.looks.invalidate();
        Ok(LookDto::from(&desc))
    }

    pub fn delete_look(&self, id: &str) -> Result<()> {
        self.inner.store.delete_look(id)?;
        self.inner.looks.invalidate();
        Ok(())
    }

    fn preview_bytes(&self, capture_id: &str) -> Result<Vec<u8>> {
        let path = self
            .image_path(capture_id, ImageKind::Preview)
            .or_else(|_| self.image_path(capture_id, ImageKind::Original))?;
        Ok(std::fs::read(path)?)
    }

    /// On-device colour match: the target frame's colour moved onto the
    /// reference's, saved as a look.
    pub async fn color_match(
        &self,
        reference_id: &str,
        target_id: &str,
        strength: f32,
        name: &str,
    ) -> Result<LookDto> {
        let reference = self.preview_bytes(reference_id)?;
        let target = self.preview_bytes(target_id)?;
        let title = name.to_string();
        let lut = tokio::task::spawn_blocking(move || {
            color_match_frames(&reference, &target, strength, &title)
        })
        .await
        .map_err(|e| Error::msg(e.to_string()))??;
        self.save_look(
            name,
            "Colour match",
            lut.size() as i64,
            lut.serialized().into_bytes(),
        )
    }

    /// A capture rendered with a look, as JPEG (for the loupe and compare).
    pub async fn render_with_look(
        &self,
        capture_id: &str,
        look: LookStack,
        max_pixels: Option<u32>,
    ) -> Result<Vec<u8>> {
        let bytes = self.preview_bytes(capture_id)?;
        let lut = self
            .inner
            .looks
            .lut(&LookStack::new(look.look_id.clone(), 1.0))
            .await?;
        Ok(CpuLookRenderer::default()
            .render(bytes, lut, look.strength, max_pixels.or(Some(2048)))
            .await?)
    }

    // MARK: Catalog sync

    /// What a Lightroom or Capture One catalog would change here (ratings,
    /// picks, labels, keywords), matched by file name.
    pub fn catalog_preview(&self, path: &Path) -> Result<CatalogPreview> {
        let entries = read_entries(path)?;
        let store = &self.inner.store;
        let captures = store.captures_matching(
            &CaptureFilter::any_state(),
            CaptureSort::CaptureTimeAscending,
            None,
            0,
        )?;
        let exported = store.exported_filenames()?;
        let m = match_catalog(&entries, &captures, &exported, |id| {
            store.tags(id).unwrap_or_default()
        });
        Ok(CatalogPreview {
            catalog: path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            changes: m.changes.iter().map(CatalogChangeDto::from).collect(),
            unmatched: m.unmatched,
        })
    }

    /// Apply catalog changes through the editor (each kind of change is
    /// one undo step per frame). Returns how many frames changed.
    pub fn catalog_apply(&self, changes: &[CatalogChangeDto]) -> Result<usize> {
        let editor = &self.inner.editor;
        for c in changes {
            let ids = [c.capture_id.clone()];
            if let Some(r) = c.rating {
                editor.rate(&ids, r)?;
            }
            if let Some(f) = c.flag {
                editor.flag(&ids, f)?;
            }
            if let Some(l) = c.label {
                editor.label(&ids, l)?;
            }
            if !c.new_keywords.is_empty() {
                editor.add_tags(&c.new_keywords, &ids)?;
            }
        }
        self.toast(
            format!(
                "Synced {} frame{} from the catalog",
                changes.len(),
                if changes.len() == 1 { "" } else { "s" }
            ),
            ToastKind::Success,
        );
        Ok(changes.len())
    }
}

fn remove_files(core: &AppCore, item: &CaptureItem) {
    for p in [
        &item.relative_path,
        &item.proxy_relative_path,
        &item.thumbnail_relative_path,
    ]
    .into_iter()
    .flatten()
    {
        core.inner.cache.remove(p);
    }
}
