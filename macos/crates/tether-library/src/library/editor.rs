//! Selection and the review editor with undo/redo (`Library/ReviewEditor.swift`).

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use tokio::sync::broadcast;

use crate::capture_item::{CaptureFlag, CaptureItem, ColorLabel};
use crate::library::{CaptureFilter, Collection, CollectionKind, LibraryError, WorkspaceMemory};
use crate::store::SessionStore;
use crate::Result;

/// A selection of captures in a grid or filmstrip. Keeps an anchor so
/// shift-click range selection and "select to end" work.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Selection {
    ids: Vec<String>,
    anchor: Option<String>,
}

impl Selection {
    pub fn new(ids: Vec<String>) -> Self {
        let anchor = ids.last().cloned();
        Self { ids, anchor }
    }

    /// Ordered, no duplicates.
    pub fn ids(&self) -> &[String] {
        &self.ids
    }

    pub fn anchor(&self) -> Option<&str> {
        self.anchor.as_deref()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub fn count(&self) -> usize {
        self.ids.len()
    }

    pub fn set(&self) -> HashSet<String> {
        self.ids.iter().cloned().collect()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.ids.iter().any(|i| i == id)
    }

    pub fn toggle(&mut self, id: &str) {
        if let Some(i) = self.ids.iter().position(|x| x == id) {
            self.ids.remove(i);
        } else {
            self.ids.push(id.to_string());
        }
        self.anchor = Some(id.to_string());
    }

    pub fn replace(&mut self, id: &str) {
        self.ids = vec![id.to_string()];
        self.anchor = Some(id.to_string());
    }

    /// Range from the anchor to `id` within `ordered` (the view's order).
    pub fn extend(&mut self, id: &str, ordered: &[String]) {
        let ai = self
            .anchor
            .as_ref()
            .and_then(|a| ordered.iter().position(|x| x == a));
        let bi = ordered.iter().position(|x| x == id);
        let (Some(ai), Some(bi)) = (ai, bi) else {
            self.replace(id);
            return;
        };
        for r in &ordered[ai.min(bi)..=ai.max(bi)] {
            if !self.contains(r) {
                self.ids.push(r.clone());
            }
        }
    }

    pub fn select_all(&mut self, ordered: &[String]) {
        self.ids = ordered.to_vec();
        self.anchor = ordered.last().cloned();
    }

    pub fn invert(&mut self, ordered: &[String]) {
        let s = self.set();
        self.ids = ordered
            .iter()
            .filter(|x| !s.contains(*x))
            .cloned()
            .collect();
        self.anchor = self.ids.last().cloned();
    }

    pub fn clear(&mut self) {
        self.ids.clear();
        self.anchor = None;
    }

    /// Drops ids that no longer exist (after a delete or a filter change).
    pub fn keep_only(&mut self, existing: &HashSet<String>) {
        self.ids.retain(|x| existing.contains(x));
        if let Some(a) = &self.anchor {
            if !existing.contains(a) {
                self.anchor = self.ids.last().cloned();
            }
        }
    }
}

/// What one edit changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReviewChange {
    Rating {
        before: BTreeMap<String, i64>,
        after: i64,
    },
    Flag {
        before: BTreeMap<String, CaptureFlag>,
        after: CaptureFlag,
    },
    Label {
        before: BTreeMap<String, ColorLabel>,
        after: ColorLabel,
    },
    /// Only the (capture, tag) pairs that did not exist before, so undo
    /// never strips a tag the user had already applied.
    TagsAdded {
        added: BTreeMap<String, Vec<String>>,
    },
    TagsRemoved {
        ids: Vec<String>,
        tags: Vec<String>,
    },
    AddedToCollection {
        ids: Vec<String>,
        collection_id: String,
        already_present: BTreeSet<String>,
    },
    RemovedFromCollection {
        ids: Vec<String>,
        collection_id: String,
    },
}

/// One reversible change to review state. Batch operations record one entry
/// with all affected captures, so Undo reverts the whole batch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewEdit {
    pub change: ReviewChange,
    pub at: DateTime<Utc>,
    /// For the menu and the toast: "Rate 4★", "Undo Pick".
    pub title: String,
    pub count: usize,
}

/// What the editor tells its observers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditorEvent {
    Changed(Vec<String>),
    UndoAvailable(Option<String>),
    RedoAvailable(Option<String>),
}

/// The live shoot, when one is open: told about every capture the editor
/// changed so the shoot screen and the library never disagree. The session
/// crate implements this (forwarding into its own task).
pub trait LiveCaptureHook: Send + Sync {
    fn replace_from_store(&self, items: &[CaptureItem]);
}

#[derive(Default)]
struct Stacks {
    undo: Vec<ReviewEdit>,
    redo: Vec<ReviewEdit>,
}

const MAX_UNDO: usize = 100;

/// Every review mutation goes through here: it writes the store, keeps
/// RAW+JPEG pairs in sync, records undo, and tells the live session (if one
/// is open). Calls are synchronous (SQLite); share it as `Arc<ReviewEditor>`.
pub struct ReviewEditor {
    store: Arc<SessionStore>,
    memory: Option<Arc<WorkspaceMemory>>,
    stacks: Mutex<Stacks>,
    live: Mutex<Option<Arc<dyn LiveCaptureHook>>>,
    events: broadcast::Sender<EditorEvent>,
}

impl ReviewEditor {
    pub fn new(store: Arc<SessionStore>, memory: Option<Arc<WorkspaceMemory>>) -> Self {
        let (events, _) = broadcast::channel(64);
        Self {
            store,
            memory,
            stacks: Mutex::new(Stacks::default()),
            live: Mutex::new(None),
            events,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<EditorEvent> {
        self.events.subscribe()
    }

    /// Attach (or detach with `None`) the live session.
    pub fn attach(&self, session: Option<Arc<dyn LiveCaptureHook>>) {
        *self.live.lock().unwrap_or_else(|e| e.into_inner()) = session;
    }

    fn stacks(&self) -> std::sync::MutexGuard<'_, Stacks> {
        self.stacks.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn can_undo(&self) -> bool {
        !self.stacks().undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.stacks().redo.is_empty()
    }

    pub fn undo_title(&self) -> Option<String> {
        self.stacks().undo.last().map(|e| e.title.clone())
    }

    pub fn redo_title(&self) -> Option<String> {
        self.stacks().redo.last().map(|e| e.title.clone())
    }

    // MARK: Batch operations (each is one undo step)

    /// Expands a selection to include each item's RAW/JPEG twin.
    fn with_pairs(&self, ids: &[String]) -> Result<Vec<CaptureItem>> {
        let items = self.store.captures_by_ids(ids)?;
        let mut all = items.clone();
        let mut seen: HashSet<String> = ids.iter().cloned().collect();
        for i in &items {
            for twin in self
                .store
                .captures_with_pair_key(&i.session_id, &i.pair_key)?
            {
                if seen.insert(twin.id.clone()) {
                    all.push(twin);
                }
            }
        }
        Ok(all)
    }

    pub fn rate(&self, ids: &[String], stars: i64) -> Result<()> {
        if ids.is_empty() {
            return Err(LibraryError::NothingSelected.into());
        }
        let items = self.with_pairs(ids)?;
        let before = items.iter().map(|i| (i.id.clone(), i.rating)).collect();
        self.apply(&items, |c| c.rating = stars.clamp(0, 5))?;
        let title = if stars == 0 {
            "Clear rating".to_string()
        } else {
            format!("Rate {stars}★")
        };
        self.push(
            ReviewChange::Rating {
                before,
                after: stars,
            },
            title,
            ids.len(),
        );
        self.notify(items.iter().map(|i| i.id.clone()).collect());
        Ok(())
    }

    pub fn flag(&self, ids: &[String], flag: CaptureFlag) -> Result<()> {
        if ids.is_empty() {
            return Err(LibraryError::NothingSelected.into());
        }
        let items = self.with_pairs(ids)?;
        let before = items.iter().map(|i| (i.id.clone(), i.flag)).collect();
        self.apply(&items, |c| c.flag = flag)?;
        let title = match flag {
            CaptureFlag::None => "Unflag",
            CaptureFlag::Pick => "Pick",
            CaptureFlag::Reject => "Reject",
        };
        self.push(
            ReviewChange::Flag {
                before,
                after: flag,
            },
            title.into(),
            ids.len(),
        );
        self.notify(items.iter().map(|i| i.id.clone()).collect());
        Ok(())
    }

    /// Labels stay per file (no pair sync), like iOS.
    pub fn label(&self, ids: &[String], color: ColorLabel) -> Result<()> {
        if ids.is_empty() {
            return Err(LibraryError::NothingSelected.into());
        }
        let items = self.store.captures_by_ids(ids)?;
        let before = items
            .iter()
            .map(|i| (i.id.clone(), i.color_label))
            .collect();
        self.apply(&items, |c| c.color_label = color)?;
        let title = if color == ColorLabel::None {
            "Clear label".to_string()
        } else {
            format!("Label {}", color.raw())
        };
        self.push(
            ReviewChange::Label {
                before,
                after: color,
            },
            title,
            ids.len(),
        );
        self.notify(ids.to_vec());
        Ok(())
    }

    pub fn add_tags<S: AsRef<str>>(&self, tags: &[S], ids: &[String]) -> Result<()> {
        if ids.is_empty() {
            return Err(LibraryError::NothingSelected.into());
        }
        let clean: Vec<String> = tags
            .iter()
            .map(|t| SessionStore::normalize_tag(t.as_ref()))
            .filter(|t| !t.is_empty())
            .collect();
        if clean.is_empty() {
            return Ok(());
        }
        let mut added = BTreeMap::new();
        for id in ids {
            let existing: HashSet<String> = self.store.tags(id)?.into_iter().collect();
            let new: Vec<String> = clean
                .iter()
                .filter(|t| !existing.contains(*t))
                .cloned()
                .collect();
            if !new.is_empty() {
                added.insert(id.clone(), new);
            }
        }
        self.store.add_tags(&clean, ids)?;
        if let Some(m) = &self.memory {
            for t in &clean {
                m.note_tag(t);
            }
        }
        let title = format!(
            "Tag {}",
            clean
                .iter()
                .map(|t| format!("#{t}"))
                .collect::<Vec<_>>()
                .join(" ")
        );
        self.push(ReviewChange::TagsAdded { added }, title, ids.len());
        self.notify(ids.to_vec());
        Ok(())
    }

    pub fn remove_tags<S: AsRef<str>>(&self, tags: &[S], ids: &[String]) -> Result<()> {
        let clean: Vec<String> = tags
            .iter()
            .map(|t| SessionStore::normalize_tag(t.as_ref()))
            .collect();
        self.store.remove_tags(&clean, ids)?;
        self.push(
            ReviewChange::TagsRemoved {
                ids: ids.to_vec(),
                tags: clean,
            },
            "Remove tag".into(),
            ids.len(),
        );
        self.notify(ids.to_vec());
        Ok(())
    }

    pub fn add_to_collection(&self, ids: &[String], collection_id: &str) -> Result<()> {
        if ids.is_empty() {
            return Err(LibraryError::NothingSelected.into());
        }
        let collection = self
            .store
            .collection(collection_id)?
            .unwrap_or_else(|| Collection::new("", CollectionKind::Manual));
        let present: BTreeSet<String> = self
            .store
            .captures_in_collection(&collection, None, None, None, 0)?
            .into_iter()
            .map(|c| c.id)
            .collect();
        self.store.add_to_collection(ids, collection_id)?;
        if let Some(m) = &self.memory {
            m.note_collection(collection_id);
        }
        let name = self
            .store
            .collection(collection_id)?
            .map(|c| c.name)
            .unwrap_or_else(|| "collection".into());
        self.push(
            ReviewChange::AddedToCollection {
                ids: ids.to_vec(),
                collection_id: collection_id.to_string(),
                already_present: present,
            },
            format!("Add to {name}"),
            ids.len(),
        );
        self.notify(ids.to_vec());
        Ok(())
    }

    pub fn remove_from_collection(&self, ids: &[String], collection_id: &str) -> Result<()> {
        self.store.remove_from_collection(ids, collection_id)?;
        let name = self
            .store
            .collection(collection_id)?
            .map(|c| c.name)
            .unwrap_or_else(|| "collection".into());
        self.push(
            ReviewChange::RemovedFromCollection {
                ids: ids.to_vec(),
                collection_id: collection_id.to_string(),
            },
            format!("Remove from {name}"),
            ids.len(),
        );
        self.notify(ids.to_vec());
        Ok(())
    }

    /// Create a manual collection from a selection in one step.
    pub fn create_collection(
        &self,
        name: &str,
        ids: &[String],
        symbol: &str,
        tint: ColorLabel,
    ) -> Result<Collection> {
        let mut c = Collection::new(name, CollectionKind::Manual);
        c.symbol = symbol.to_string();
        c.tint = tint;
        self.store.save_collection(&c)?;
        if !ids.is_empty() {
            self.add_to_collection(ids, &c.id)?;
        }
        Ok(c)
    }

    /// Save the current filter as a smart collection.
    pub fn save_smart_collection(
        &self,
        name: &str,
        rule: CaptureFilter,
        symbol: &str,
    ) -> Result<Collection> {
        let c = Collection::smart(name, rule, symbol, None, false);
        self.store.save_collection(&c)?;
        if let Some(m) = &self.memory {
            m.note_collection(&c.id);
        }
        Ok(c)
    }

    // MARK: Undo / redo

    /// Returns the edit that was undone (title + count for the toast).
    pub fn undo(&self) -> Result<Option<ReviewEdit>> {
        let Some(edit) = self.stacks().undo.pop() else {
            return Ok(None);
        };
        if let Err(e) = self.revert(&edit) {
            self.stacks().undo.push(edit);
            return Err(e);
        }
        self.stacks().redo.push(edit.clone());
        self.announce();
        Ok(Some(edit))
    }

    pub fn redo(&self) -> Result<Option<ReviewEdit>> {
        let Some(edit) = self.stacks().redo.pop() else {
            return Ok(None);
        };
        if let Err(e) = self.reapply(&edit) {
            self.stacks().redo.push(edit);
            return Err(e);
        }
        self.stacks().undo.push(edit.clone());
        self.announce();
        Ok(Some(edit))
    }

    fn push(&self, change: ReviewChange, title: String, count: usize) {
        {
            let mut s = self.stacks();
            s.undo.push(ReviewEdit {
                change,
                at: Utc::now(),
                title,
                count,
            });
            if s.undo.len() > MAX_UNDO {
                s.undo.remove(0);
            }
            s.redo.clear();
        }
        self.announce();
    }

    fn announce(&self) {
        let (u, r) = {
            let s = self.stacks();
            (
                s.undo.last().map(|e| e.title.clone()),
                s.redo.last().map(|e| e.title.clone()),
            )
        };
        let _ = self.events.send(EditorEvent::UndoAvailable(u));
        let _ = self.events.send(EditorEvent::RedoAvailable(r));
    }

    fn keys<V>(m: &BTreeMap<String, V>) -> Vec<String> {
        m.keys().cloned().collect()
    }

    fn revert(&self, e: &ReviewEdit) -> Result<()> {
        match &e.change {
            ReviewChange::Rating { before, .. } => {
                let ids = Self::keys(before);
                self.apply(&self.store.captures_by_ids(&ids)?, |c| {
                    c.rating = before.get(&c.id).copied().unwrap_or(c.rating)
                })?;
                self.notify(ids);
            }
            ReviewChange::Flag { before, .. } => {
                let ids = Self::keys(before);
                self.apply(&self.store.captures_by_ids(&ids)?, |c| {
                    c.flag = before.get(&c.id).copied().unwrap_or(c.flag)
                })?;
                self.notify(ids);
            }
            ReviewChange::Label { before, .. } => {
                let ids = Self::keys(before);
                self.apply(&self.store.captures_by_ids(&ids)?, |c| {
                    c.color_label = before.get(&c.id).copied().unwrap_or(c.color_label)
                })?;
                self.notify(ids);
            }
            ReviewChange::TagsAdded { added } => {
                for (id, tags) in added {
                    self.store.remove_tags(tags, std::slice::from_ref(id))?;
                }
                self.notify(Self::keys(added));
            }
            ReviewChange::TagsRemoved { ids, tags } => {
                self.store.add_tags(tags, ids)?;
                self.notify(ids.clone());
            }
            ReviewChange::AddedToCollection {
                ids,
                collection_id,
                already_present,
            } => {
                let fresh: Vec<String> = ids
                    .iter()
                    .filter(|i| !already_present.contains(*i))
                    .cloned()
                    .collect();
                self.store.remove_from_collection(&fresh, collection_id)?;
                self.notify(ids.clone());
            }
            ReviewChange::RemovedFromCollection { ids, collection_id } => {
                self.store.add_to_collection(ids, collection_id)?;
                self.notify(ids.clone());
            }
        }
        Ok(())
    }

    fn reapply(&self, e: &ReviewEdit) -> Result<()> {
        match &e.change {
            ReviewChange::Rating { before, after } => {
                let ids = Self::keys(before);
                self.apply(&self.store.captures_by_ids(&ids)?, |c| c.rating = *after)?;
                self.notify(ids);
            }
            ReviewChange::Flag { before, after } => {
                let ids = Self::keys(before);
                self.apply(&self.store.captures_by_ids(&ids)?, |c| c.flag = *after)?;
                self.notify(ids);
            }
            ReviewChange::Label { before, after } => {
                let ids = Self::keys(before);
                self.apply(&self.store.captures_by_ids(&ids)?, |c| {
                    c.color_label = *after
                })?;
                self.notify(ids);
            }
            ReviewChange::TagsAdded { added } => {
                for (id, tags) in added {
                    self.store.add_tags(tags, std::slice::from_ref(id))?;
                }
                self.notify(Self::keys(added));
            }
            ReviewChange::TagsRemoved { ids, tags } => {
                self.store.remove_tags(tags, ids)?;
                self.notify(ids.clone());
            }
            ReviewChange::AddedToCollection {
                ids, collection_id, ..
            } => {
                self.store.add_to_collection(ids, collection_id)?;
                self.notify(ids.clone());
            }
            ReviewChange::RemovedFromCollection { ids, collection_id } => {
                self.store.remove_from_collection(ids, collection_id)?;
                self.notify(ids.clone());
            }
        }
        Ok(())
    }

    fn apply(&self, items: &[CaptureItem], mutate: impl Fn(&mut CaptureItem)) -> Result<()> {
        self.store.transaction(|conn| {
            for i in items {
                let mut i = i.clone();
                mutate(&mut i);
                SessionStore::save_capture_on(conn, &i)?;
            }
            Ok(())
        })
    }

    fn notify(&self, ids: Vec<String>) {
        let live = self.live.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(live) = live {
            if let Ok(items) = self.store.captures_by_ids(&ids) {
                live.replace_from_store(&items);
            }
        }
        let _ = self.events.send(EditorEvent::Changed(ids));
    }
}
