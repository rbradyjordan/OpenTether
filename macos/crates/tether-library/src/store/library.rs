//! The library side of the store (`Library/LibraryStore.swift`): every
//! capture across every session, with tags, collections and export history.
//! All queries are SQL over indexed columns so a 20 000-frame library
//! answers in milliseconds.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use rusqlite::types::Value as SqlValue;
use rusqlite::Connection;

use super::{exec, json_rows, opt_text, real, text, to_json, SessionStore};
use crate::capture_item::CaptureItem;
use crate::library::{
    CaptureFilter, CaptureSort, Collection, CollectionKind, ExportDestinationKey, LibraryError,
};
use crate::store::database::query_rows;
use crate::{swift_json, util, Result};

/// Totals for the library header.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LibraryStats {
    pub captures: i64,
    pub sessions: i64,
    pub picks: i64,
    pub rated: i64,
    pub bytes: i64,
    pub cameras: i64,
}

/// One delivery of a capture.
#[derive(Debug, Clone, PartialEq)]
pub struct ExportRecord {
    pub destination: String,
    pub at: DateTime<Utc>,
    pub remote_id: Option<String>,
}

fn add_column_if_missing(conn: &Connection, table: &str, column: &str, ty: &str) -> Result<()> {
    let cols = query_rows(conn, &format!("PRAGMA table_info({table})"), &[])?;
    if !cols.iter().any(|r| r.string("name") == Some(column)) {
        conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {ty}"))?;
    }
    Ok(())
}

pub(super) fn migrate_library(conn: &Connection) -> Result<()> {
    add_column_if_missing(conn, "captures", "camera_id", "TEXT")?;
    add_column_if_missing(conn, "captures", "look_id", "TEXT")?;
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS captures_rating ON captures(state, rating);
        CREATE INDEX IF NOT EXISTS captures_flag ON captures(state, flag);
        CREATE INDEX IF NOT EXISTS captures_received ON captures(received_at);
        CREATE INDEX IF NOT EXISTS captures_camera ON captures(camera_id);
        CREATE TABLE IF NOT EXISTS capture_tags (
            capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
            tag TEXT NOT NULL, added_at REAL NOT NULL,
            PRIMARY KEY (capture_id, tag)
        );
        CREATE INDEX IF NOT EXISTS capture_tags_tag ON capture_tags(tag);
        CREATE TABLE IF NOT EXISTS collections (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0, builtin INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL, json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS collection_items (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
            position INTEGER NOT NULL, added_at REAL NOT NULL,
            PRIMARY KEY (collection_id, capture_id)
        );
        CREATE TABLE IF NOT EXISTS capture_exports (
            capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
            destination TEXT NOT NULL, job_id TEXT NOT NULL, remote_id TEXT, exported_at REAL NOT NULL,
            PRIMARY KEY (capture_id, destination, job_id)
        );
        CREATE TABLE IF NOT EXISTS tag_history (tag TEXT PRIMARY KEY, uses INTEGER NOT NULL, last_used REAL NOT NULL);",
    )?;
    for (i, c) in Collection::built_ins().into_iter().enumerate() {
        let mut seeded = c;
        seeded.sort_order = i as i64;
        exec(
            conn,
            "INSERT INTO collections (id, name, kind, pinned, sort_order, builtin, updated_at, json) VALUES (?, ?, ?, ?, ?, 1, ?, ?) ON CONFLICT(id) DO NOTHING",
            &[
                text(&seeded.id),
                text(&seeded.name),
                text(seeded.kind.raw()),
                SqlValue::Integer(1),
                SqlValue::Integer(i as i64),
                real(&Utc::now()),
                to_json(&seeded),
            ],
        )?;
    }
    Ok(())
}

impl SessionStore {
    // MARK: Queries

    /// Captures matching a filter, in order. `limit`/`offset` page large grids.
    pub fn captures_matching(
        &self,
        filter: &CaptureFilter,
        sort: CaptureSort,
        limit: Option<i64>,
        offset: i64,
    ) -> Result<Vec<CaptureItem>> {
        let (w, mut p) = filter.sql(Utc::now());
        let mut sql = format!(
            "SELECT c.json FROM captures c WHERE {w} ORDER BY {}",
            sort.order_by()
        );
        if let Some(limit) = limit {
            sql += " LIMIT ? OFFSET ?";
            p.push(SqlValue::Integer(limit));
            p.push(SqlValue::Integer(offset));
        }
        json_rows(&self.conn(), &sql, &p)
    }

    pub fn count_matching(&self, filter: &CaptureFilter) -> Result<i64> {
        let (w, p) = filter.sql(Utc::now());
        let conn = self.conn();
        Ok(conn.query_row(
            &format!("SELECT COUNT(*) AS n FROM captures c WHERE {w}"),
            rusqlite::params_from_iter(p.iter()),
            |r| r.get(0),
        )?)
    }

    /// IDs only, for selection math ("select all in view") without decoding JSON.
    pub fn capture_ids_matching(
        &self,
        filter: &CaptureFilter,
        sort: CaptureSort,
    ) -> Result<Vec<String>> {
        let (w, p) = filter.sql(Utc::now());
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT c.id FROM captures c WHERE {w} ORDER BY {}",
            sort.order_by()
        ))?;
        let rows = stmt.query_map(rusqlite::params_from_iter(p.iter()), |r| {
            r.get::<_, String>(0)
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Captures by id, in the order of `ids` (missing ones are skipped).
    pub fn captures_by_ids(&self, ids: &[String]) -> Result<Vec<CaptureItem>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.conn();
        let mut out: Vec<CaptureItem> = Vec::with_capacity(ids.len());
        for chunk in ids.chunks(400) {
            let q = vec!["?"; chunk.len()].join(",");
            let params: Vec<SqlValue> = chunk.iter().map(|s| text(s)).collect();
            out.extend(json_rows::<CaptureItem>(
                &conn,
                &format!("SELECT json FROM captures WHERE id IN ({q})"),
                &params,
            )?);
        }
        let order: HashMap<&str, usize> = ids
            .iter()
            .enumerate()
            .map(|(i, id)| (id.as_str(), i))
            .collect();
        out.sort_by_key(|c| order.get(c.id.as_str()).copied().unwrap_or(0));
        Ok(out)
    }

    // MARK: Collections

    pub fn save_collection(&self, c: &Collection) -> Result<()> {
        let mut c = c.clone();
        c.updated_at = Utc::now();
        exec(
            &self.conn(),
            "INSERT INTO collections (id, name, kind, pinned, sort_order, builtin, updated_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, pinned=excluded.pinned, sort_order=excluded.sort_order, updated_at=excluded.updated_at, json=excluded.json",
            &[
                text(&c.id),
                text(&c.name),
                text(c.kind.raw()),
                SqlValue::Integer(c.is_pinned as i64),
                SqlValue::Integer(c.sort_order),
                SqlValue::Integer(c.is_built_in as i64),
                real(&c.updated_at),
                to_json(&c),
            ],
        )?;
        Ok(())
    }

    pub fn collections(&self) -> Result<Vec<Collection>> {
        json_rows(
            &self.conn(),
            "SELECT json FROM collections ORDER BY builtin DESC, pinned DESC, sort_order ASC, name COLLATE NOCASE ASC",
            &[],
        )
    }

    pub fn collection(&self, id: &str) -> Result<Option<Collection>> {
        Ok(json_rows(
            &self.conn(),
            "SELECT json FROM collections WHERE id = ?",
            &[text(id)],
        )?
        .into_iter()
        .next())
    }

    /// Deletes a user collection (its photos stay). Built-ins refuse.
    pub fn delete_collection(&self, id: &str) -> Result<()> {
        match self.collection(id)? {
            Some(c) if !c.is_built_in => {
                exec(
                    &self.conn(),
                    "DELETE FROM collections WHERE id = ?",
                    &[text(id)],
                )?;
                Ok(())
            }
            _ => Err(LibraryError::BuiltInCollection.into()),
        }
    }

    /// Appends captures to a manual collection (already present ones are kept where they are).
    pub fn add_to_collection(&self, capture_ids: &[String], collection_id: &str) -> Result<()> {
        match self.collection(collection_id)? {
            Some(c) if c.kind == CollectionKind::Manual => {}
            _ => return Err(LibraryError::NotManual.into()),
        }
        self.transaction(|conn| {
            let max: i64 = conn.query_row(
                "SELECT COALESCE(MAX(position), -1) AS m FROM collection_items WHERE collection_id = ?",
                [collection_id],
                |r| r.get(0),
            )?;
            let next = max + 1;
            let now = real(&Utc::now());
            for (i, id) in capture_ids.iter().enumerate() {
                exec(
                    conn,
                    "INSERT INTO collection_items (collection_id, capture_id, position, added_at) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING",
                    &[text(collection_id), text(id), SqlValue::Integer(next + i as i64), now.clone()],
                )?;
            }
            exec(conn, "UPDATE collections SET updated_at = ? WHERE id = ?", &[now, text(collection_id)])?;
            Ok(())
        })
    }

    pub fn remove_from_collection(
        &self,
        capture_ids: &[String],
        collection_id: &str,
    ) -> Result<()> {
        let conn = self.conn();
        for id in capture_ids {
            exec(
                &conn,
                "DELETE FROM collection_items WHERE collection_id = ? AND capture_id = ?",
                &[text(collection_id), text(id)],
            )?;
        }
        Ok(())
    }

    /// Sets the hand order of a manual collection.
    pub fn reorder(&self, capture_ids: &[String], collection_id: &str) -> Result<()> {
        self.transaction(|conn| {
            for (i, id) in capture_ids.iter().enumerate() {
                exec(
                    conn,
                    "UPDATE collection_items SET position = ? WHERE collection_id = ? AND capture_id = ?",
                    &[SqlValue::Integer(i as i64), text(collection_id), text(id)],
                )?;
            }
            Ok(())
        })
    }

    /// Contents of any collection: smart ones run their rule, manual ones
    /// keep their hand order (optionally narrowed by an extra filter).
    pub fn captures_in_collection(
        &self,
        collection: &Collection,
        narrowed_by: Option<&CaptureFilter>,
        sort: Option<CaptureSort>,
        limit: Option<i64>,
        offset: i64,
    ) -> Result<Vec<CaptureItem>> {
        match collection.kind {
            CollectionKind::Smart => {
                let mut rule = collection.rule.clone().unwrap_or_default();
                if let Some(extra) = narrowed_by {
                    rule = rule.merged(extra);
                }
                self.captures_matching(&rule, sort.unwrap_or_default(), limit, offset)
            }
            CollectionKind::Manual => {
                let extra = narrowed_by
                    .cloned()
                    .unwrap_or_else(CaptureFilter::any_state);
                let (w, p) = extra.sql(Utc::now());
                let order = sort.map(|s| s.order_by()).unwrap_or("ci.position ASC");
                let mut sql = format!(
                    "SELECT c.json FROM collection_items ci JOIN captures c ON c.id = ci.capture_id WHERE ci.collection_id = ? AND {w} ORDER BY {order}"
                );
                let mut params = vec![text(&collection.id)];
                params.extend(p);
                if let Some(limit) = limit {
                    sql += " LIMIT ? OFFSET ?";
                    params.push(SqlValue::Integer(limit));
                    params.push(SqlValue::Integer(offset));
                }
                json_rows(&self.conn(), &sql, &params)
            }
        }
    }

    pub fn count_in_collection(&self, collection: &Collection) -> Result<i64> {
        match collection.kind {
            CollectionKind::Smart => {
                self.count_matching(&collection.rule.clone().unwrap_or_default())
            }
            CollectionKind::Manual => Ok(self.conn().query_row(
                "SELECT COUNT(*) AS n FROM collection_items WHERE collection_id = ?",
                [&collection.id],
                |r| r.get(0),
            )?),
        }
    }

    pub fn collection_ids_containing(&self, capture_id: &str) -> Result<Vec<String>> {
        let conn = self.conn();
        let mut stmt =
            conn.prepare_cached("SELECT collection_id FROM collection_items WHERE capture_id = ?")?;
        let rows = stmt.query_map([capture_id], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    // MARK: Tags

    pub fn tags(&self, capture_id: &str) -> Result<Vec<String>> {
        let conn = self.conn();
        let mut stmt =
            conn.prepare_cached("SELECT tag FROM capture_tags WHERE capture_id = ? ORDER BY tag")?;
        let rows = stmt.query_map([capture_id], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn add_tags<S: AsRef<str>>(&self, tags: &[S], capture_ids: &[String]) -> Result<()> {
        let clean: Vec<String> = tags
            .iter()
            .map(|t| Self::normalize_tag(t.as_ref()))
            .filter(|t| !t.is_empty())
            .collect();
        if clean.is_empty() {
            return Ok(());
        }
        self.transaction(|conn| {
            let now = real(&Utc::now());
            for id in capture_ids {
                for t in &clean {
                    exec(
                        conn,
                        "INSERT INTO capture_tags (capture_id, tag, added_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                        &[text(id), text(t), now.clone()],
                    )?;
                }
            }
            for t in &clean {
                exec(
                    conn,
                    "INSERT INTO tag_history (tag, uses, last_used) VALUES (?, 1, ?) ON CONFLICT(tag) DO UPDATE SET uses = uses + 1, last_used = excluded.last_used",
                    &[text(t), now.clone()],
                )?;
            }
            Ok(())
        })
    }

    pub fn remove_tags<S: AsRef<str>>(&self, tags: &[S], capture_ids: &[String]) -> Result<()> {
        let conn = self.conn();
        for id in capture_ids {
            for t in tags {
                exec(
                    &conn,
                    "DELETE FROM capture_tags WHERE capture_id = ? AND tag = ?",
                    &[text(id), text(&Self::normalize_tag(t.as_ref()))],
                )?;
            }
        }
        Ok(())
    }

    /// Tags ranked by use, most recent first on ties. Drives autocompletion.
    pub fn tag_suggestions(&self, prefix: &str, limit: i64) -> Result<Vec<String>> {
        let p = Self::normalize_tag(prefix);
        let conn = self.conn();
        let mut stmt = conn.prepare_cached(
            "SELECT tag FROM tag_history WHERE tag LIKE ? ORDER BY uses DESC, last_used DESC LIMIT ?",
        )?;
        let rows = stmt.query_map(rusqlite::params![format!("{p}%"), limit], |r| {
            r.get::<_, String>(0)
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// `"  #Hero Shot "` → `"hero-shot"`.
    pub fn normalize_tag(s: &str) -> String {
        s.trim().to_lowercase().replace('#', "").replace(' ', "-")
    }

    // MARK: Exports

    pub fn record_export(
        &self,
        capture_id: &str,
        destination: ExportDestinationKey,
        job_id: &str,
        remote_id: Option<&str>,
    ) -> Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO capture_exports (capture_id, destination, job_id, remote_id, exported_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
            &[text(capture_id), text(destination.raw()), text(job_id), opt_text(remote_id), real(&Utc::now())],
        )?;
        Ok(())
    }

    pub fn export_history(&self, capture_id: &str) -> Result<Vec<ExportRecord>> {
        let rows = query_rows(
            &self.conn(),
            "SELECT destination, exported_at, remote_id FROM capture_exports WHERE capture_id = ? ORDER BY exported_at DESC",
            &[text(capture_id)],
        )?;
        Ok(rows
            .into_iter()
            .map(|r| ExportRecord {
                destination: r.string("destination").unwrap_or("").to_string(),
                at: r
                    .double("exported_at")
                    .map(swift_json::from_unix_seconds)
                    .unwrap_or_else(Utc::now),
                remote_id: r.string("remote_id").map(str::to_string),
            })
            .collect())
    }

    /// Exported file names (lowercased, no folder) → capture ID, so a catalog
    /// that only knows the exported names ("AW26_001.CR3") can be matched back.
    pub fn exported_filenames(&self) -> Result<HashMap<String, String>> {
        let rows = query_rows(
            &self.conn(),
            "SELECT capture_id, remote_id FROM capture_exports WHERE remote_id IS NOT NULL ORDER BY exported_at",
            &[],
        )?;
        let mut out = HashMap::new();
        for r in rows {
            if let (Some(id), Some(remote)) = (r.string("capture_id"), r.string("remote_id")) {
                out.insert(
                    util::last_path_component(remote).to_lowercase(),
                    id.to_string(),
                );
            }
        }
        Ok(out)
    }

    // MARK: Library stats

    pub fn library_stats(&self) -> Result<LibraryStats> {
        let rows = query_rows(
            &self.conn(),
            "SELECT COUNT(*) AS n, SUM(CASE WHEN flag = 'pick' THEN 1 ELSE 0 END) AS picks, SUM(CASE WHEN rating > 0 THEN 1 ELSE 0 END) AS rated,
                    COUNT(DISTINCT session_id) AS sessions, COUNT(DISTINCT camera_id) AS cameras FROM captures WHERE state = 'ready'",
            &[],
        )?;
        let r = rows.into_iter().next().unwrap_or_default();
        Ok(LibraryStats {
            captures: r.int("n").unwrap_or(0),
            picks: r.int("picks").unwrap_or(0),
            rated: r.int("rated").unwrap_or(0),
            sessions: r.int("sessions").unwrap_or(0),
            cameras: r.int("cameras").unwrap_or(0),
            bytes: 0,
        })
    }
}
