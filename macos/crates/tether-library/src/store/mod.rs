//! SQLite persistence (`Store/SessionStore.swift`, `Store/SQLiteDatabase.swift`).
//!
//! Sessions, captures, review state, export jobs, FTP and folder
//! destinations, the looks cache and small settings. The store is the
//! recovery journal: every capture is written as it is announced and updated
//! as it downloads, so a relaunch mid-shoot knows exactly what it has.
//!
//! Tables, columns, indexes and the JSON in the `json` columns are the
//! same as on iOS. The connection sits behind a mutex, so a `SessionStore`
//! can be shared (`Arc<SessionStore>`) across threads; every call is
//! synchronous.

pub mod database;
mod library;

use std::sync::{Mutex, MutexGuard};

use chrono::{DateTime, Utc};
use rusqlite::types::Value as SqlValue;
use rusqlite::Connection;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tether_types::CameraIdentity;

use crate::capture_item::{CaptureItem, ShootSession};
use crate::delivery::ExportJob;
use crate::interop::naming::FolderLayout;
use crate::looks::LookDescriptor;
use crate::swift_json;
use crate::Result;

pub use library::LibraryStats;

/// The library database.
pub struct SessionStore {
    conn: Mutex<Connection>,
    path: String,
}

/// Per-session tallies for the session list.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SessionCounts {
    pub total: i64,
    pub ready: i64,
    pub picks: i64,
    pub rejects: i64,
    pub rated: i64,
    pub failed: i64,
}

/// A camera seen before (for the "reconnect" shortcut).
#[derive(Debug, Clone, PartialEq)]
pub struct KnownCamera {
    pub identity: CameraIdentity,
    pub host: Option<String>,
    pub last_seen: DateTime<Utc>,
}

pub(crate) fn to_json<T: Serialize>(v: &T) -> SqlValue {
    serde_json::to_string(v)
        .map(SqlValue::Text)
        .unwrap_or(SqlValue::Null)
}

pub(crate) fn real(d: &DateTime<Utc>) -> SqlValue {
    SqlValue::Real(swift_json::unix_seconds(d))
}

pub(crate) fn text(s: &str) -> SqlValue {
    SqlValue::Text(s.to_string())
}

pub(crate) fn opt_text(s: Option<&str>) -> SqlValue {
    s.map(text).unwrap_or(SqlValue::Null)
}

/// Rows' `json` column decoded; rows that don't decode are skipped (as the
/// Swift `compactMap` does).
pub(crate) fn json_rows<T: DeserializeOwned>(
    conn: &Connection,
    sql: &str,
    params: &[SqlValue],
) -> Result<Vec<T>> {
    let mut stmt = conn.prepare_cached(sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(params.iter()), |r| {
        r.get::<_, Option<String>>(0)
    })?;
    let mut out = Vec::new();
    for r in rows {
        if let Some(s) = r? {
            if let Ok(v) = serde_json::from_str(&s) {
                out.push(v);
            }
        }
    }
    Ok(out)
}

pub(crate) fn exec(conn: &Connection, sql: &str, params: &[SqlValue]) -> Result<usize> {
    let mut stmt = conn.prepare_cached(sql)?;
    Ok(stmt.execute(rusqlite::params_from_iter(params.iter()))?)
}

impl SessionStore {
    /// Opens (or creates) the store at `path` and migrates it.
    pub fn open(path: &str) -> Result<SessionStore> {
        let conn = database::open(path)?;
        let store = SessionStore {
            conn: Mutex::new(conn),
            path: path.to_string(),
        };
        store.migrate()?;
        Ok(store)
    }

    pub fn in_memory() -> Result<SessionStore> {
        Self::open(":memory:")
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    pub(crate) fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Runs `body` inside `BEGIN IMMEDIATE … COMMIT` (rolled back on error).
    pub fn transaction<T>(&self, body: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let conn = self.conn();
        conn.execute_batch("BEGIN IMMEDIATE")?;
        match body(&conn) {
            Ok(v) => {
                conn.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }

    fn migrate(&self) -> Result<()> {
        let conn = self.conn();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL, ended_at REAL,
                status TEXT NOT NULL, json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS captures (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL, filename TEXT NOT NULL, kind TEXT NOT NULL, pair_key TEXT NOT NULL,
                rating INTEGER NOT NULL DEFAULT 0, flag TEXT NOT NULL DEFAULT 'none', color TEXT NOT NULL DEFAULT 'none',
                state TEXT NOT NULL, received_at REAL NOT NULL, json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS captures_session ON captures(session_id, sequence);
            CREATE TABLE IF NOT EXISTS export_jobs (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                status TEXT NOT NULL, json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS ftp_destinations (id TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS folder_destinations (id TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS looks (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, family TEXT NOT NULL, version INTEGER NOT NULL,
                sha256 TEXT NOT NULL, cube BLOB, fetched_at REAL, json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS known_cameras (
                id TEXT PRIMARY KEY, last_seen REAL NOT NULL, host TEXT, json TEXT NOT NULL
            );",
        )?;
        library::migrate_library(&conn)?;
        Ok(())
    }

    // MARK: Sessions

    pub fn save_session(&self, s: &ShootSession) -> Result<()> {
        Self::save_session_on(&self.conn(), s)
    }

    fn save_session_on(conn: &Connection, s: &ShootSession) -> Result<()> {
        exec(
            conn,
            "INSERT INTO sessions (id, name, created_at, ended_at, status, json) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, ended_at=excluded.ended_at, status=excluded.status, json=excluded.json",
            &[
                text(&s.id),
                text(&s.name),
                real(&s.created_at),
                s.ended_at.as_ref().map(real).unwrap_or(SqlValue::Null),
                text(s.status.raw()),
                to_json(s),
            ],
        )?;
        Ok(())
    }

    pub fn session(&self, id: &str) -> Result<Option<ShootSession>> {
        Ok(json_rows(
            &self.conn(),
            "SELECT json FROM sessions WHERE id = ?",
            &[text(id)],
        )?
        .into_iter()
        .next())
    }

    pub fn sessions(&self, limit: i64) -> Result<Vec<ShootSession>> {
        json_rows(
            &self.conn(),
            "SELECT json FROM sessions ORDER BY created_at DESC LIMIT ?",
            &[SqlValue::Integer(limit)],
        )
    }

    /// Sessions that were active when the app last stopped: offered as "Resume".
    pub fn interrupted_sessions(&self) -> Result<Vec<ShootSession>> {
        json_rows(
            &self.conn(),
            "SELECT json FROM sessions WHERE status IN ('active','interrupted') ORDER BY created_at DESC",
            &[],
        )
    }

    pub fn mark_interrupted_sessions(&self) -> Result<()> {
        let conn = self.conn();
        let rows: Vec<ShootSession> = json_rows(
            &conn,
            "SELECT json FROM sessions WHERE status = 'active'",
            &[],
        )?;
        for mut s in rows {
            s.status = crate::capture_item::SessionStatus::Interrupted;
            Self::save_session_on(&conn, &s)?;
        }
        Ok(())
    }

    pub fn delete_session(&self, id: &str) -> Result<()> {
        exec(
            &self.conn(),
            "DELETE FROM sessions WHERE id = ?",
            &[text(id)],
        )?;
        Ok(())
    }

    // MARK: Captures

    pub fn save_capture(&self, c: &CaptureItem) -> Result<()> {
        Self::save_capture_on(&self.conn(), c)
    }

    /// Saves many captures in one transaction.
    pub fn save_captures(&self, items: &[CaptureItem]) -> Result<()> {
        self.transaction(|conn| {
            for c in items {
                Self::save_capture_on(conn, c)?;
            }
            Ok(())
        })
    }

    pub(crate) fn save_capture_on(conn: &Connection, c: &CaptureItem) -> Result<()> {
        exec(
            conn,
            "INSERT INTO captures (id, session_id, sequence, filename, kind, pair_key, rating, flag, color, state, received_at, json, camera_id, look_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET filename=excluded.filename, kind=excluded.kind, pair_key=excluded.pair_key,
                 rating=excluded.rating, flag=excluded.flag, color=excluded.color, state=excluded.state, received_at=excluded.received_at,
                 json=excluded.json, camera_id=excluded.camera_id, look_id=excluded.look_id",
            &[
                text(&c.id),
                text(&c.session_id),
                SqlValue::Integer(c.sequence),
                text(&c.filename),
                text(c.kind.raw()),
                text(&c.pair_key),
                SqlValue::Integer(c.rating),
                text(c.flag.raw()),
                text(c.color_label.raw()),
                text(c.state.key()),
                real(&c.received_at),
                to_json(c),
                opt_text(c.camera_id.as_deref()),
                opt_text(c.look_id.as_deref()),
            ],
        )?;
        Ok(())
    }

    pub fn captures_in_session(&self, session_id: &str) -> Result<Vec<CaptureItem>> {
        json_rows(
            &self.conn(),
            "SELECT json FROM captures WHERE session_id = ? ORDER BY sequence ASC",
            &[text(session_id)],
        )
    }

    /// The RAW/JPEG twins of a pair (every capture sharing the pair key).
    pub fn captures_with_pair_key(
        &self,
        session_id: &str,
        pair_key: &str,
    ) -> Result<Vec<CaptureItem>> {
        json_rows(
            &self.conn(),
            "SELECT json FROM captures WHERE session_id = ? AND pair_key = ? ORDER BY sequence ASC",
            &[text(session_id), text(pair_key)],
        )
    }

    pub fn capture(&self, id: &str) -> Result<Option<CaptureItem>> {
        Ok(json_rows(
            &self.conn(),
            "SELECT json FROM captures WHERE id = ?",
            &[text(id)],
        )?
        .into_iter()
        .next())
    }

    pub fn next_sequence(&self, session_id: &str) -> Result<i64> {
        let conn = self.conn();
        let m: i64 = conn.query_row(
            "SELECT COALESCE(MAX(sequence), 0) AS m FROM captures WHERE session_id = ?",
            [session_id],
            |r| r.get(0),
        )?;
        Ok(m + 1)
    }

    pub fn delete_capture(&self, id: &str) -> Result<()> {
        exec(
            &self.conn(),
            "DELETE FROM captures WHERE id = ?",
            &[text(id)],
        )?;
        Ok(())
    }

    pub fn counts(&self, session_id: &str) -> Result<SessionCounts> {
        let conn = self.conn();
        let mut stmt =
            conn.prepare_cached("SELECT state, flag, rating FROM captures WHERE session_id = ?")?;
        let mut c = SessionCounts::default();
        let rows = stmt.query_map([session_id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?;
        for row in rows {
            let (state, flag, rating) = row?;
            c.total += 1;
            match state.as_str() {
                "ready" => c.ready += 1,
                "failed" => c.failed += 1,
                _ => {}
            }
            match flag.as_str() {
                "pick" => c.picks += 1,
                "reject" => c.rejects += 1,
                _ => {}
            }
            if rating > 0 {
                c.rated += 1;
            }
        }
        Ok(c)
    }

    // MARK: Export jobs

    pub fn save_export_job(&self, j: &ExportJob) -> Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO export_jobs (id, session_id, created_at, updated_at, status, json) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, status=excluded.status, json=excluded.json",
            &[
                text(&j.id),
                text(&j.session_id),
                real(&j.created_at),
                real(&Utc::now()),
                text(j.status.key()),
                to_json(j),
            ],
        )?;
        Ok(())
    }

    pub fn export_jobs(&self, session_id: Option<&str>) -> Result<Vec<ExportJob>> {
        match session_id {
            None => json_rows(
                &self.conn(),
                "SELECT json FROM export_jobs ORDER BY created_at DESC",
                &[],
            ),
            Some(s) => json_rows(
                &self.conn(),
                "SELECT json FROM export_jobs WHERE session_id = ? ORDER BY created_at DESC",
                &[text(s)],
            ),
        }
    }

    pub fn export_job(&self, id: &str) -> Result<Option<ExportJob>> {
        Ok(json_rows(
            &self.conn(),
            "SELECT json FROM export_jobs WHERE id = ?",
            &[text(id)],
        )?
        .into_iter()
        .next())
    }

    pub fn pending_export_jobs(&self) -> Result<Vec<ExportJob>> {
        json_rows(
            &self.conn(),
            "SELECT json FROM export_jobs WHERE status IN ('queued','running','paused') ORDER BY created_at ASC",
            &[],
        )
    }

    // MARK: Looks cache

    /// Saves a look; a `None` cube keeps the cube already stored.
    pub fn save_look(&self, look: &LookDescriptor, cube: Option<&[u8]>) -> Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO looks (id, name, family, version, sha256, cube, fetched_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, family=excluded.family, version=excluded.version, sha256=excluded.sha256,
                 cube=COALESCE(excluded.cube, looks.cube), fetched_at=excluded.fetched_at, json=excluded.json",
            &[
                text(&look.id),
                text(&look.name),
                text(&look.family),
                SqlValue::Integer(look.version),
                text(&look.sha256),
                cube.map(|c| SqlValue::Blob(c.to_vec())).unwrap_or(SqlValue::Null),
                real(&Utc::now()),
                to_json(look),
            ],
        )?;
        Ok(())
    }

    pub fn looks(&self) -> Result<Vec<LookDescriptor>> {
        json_rows(
            &self.conn(),
            "SELECT json FROM looks ORDER BY family, name",
            &[],
        )
    }

    pub fn cube(&self, look_id: &str) -> Result<Option<Vec<u8>>> {
        let conn = self.conn();
        let mut stmt = conn.prepare_cached("SELECT cube FROM looks WHERE id = ?")?;
        let mut rows = stmt.query([look_id])?;
        Ok(match rows.next()? {
            Some(r) => match r.get::<_, SqlValue>(0)? {
                SqlValue::Blob(b) => Some(b),
                _ => None,
            },
            None => None,
        })
    }

    pub fn delete_look(&self, id: &str) -> Result<()> {
        exec(&self.conn(), "DELETE FROM looks WHERE id = ?", &[text(id)])?;
        Ok(())
    }

    // MARK: FTP destinations

    pub fn save_ftp_destination(&self, d: &StoredFtpDestination) -> Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO ftp_destinations (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
            &[text(&d.id), to_json(d)],
        )?;
        Ok(())
    }

    pub fn ftp_destinations(&self) -> Result<Vec<StoredFtpDestination>> {
        json_rows(&self.conn(), "SELECT json FROM ftp_destinations", &[])
    }

    pub fn delete_ftp_destination(&self, id: &str) -> Result<()> {
        exec(
            &self.conn(),
            "DELETE FROM ftp_destinations WHERE id = ?",
            &[text(id)],
        )?;
        Ok(())
    }

    // MARK: Folder destinations

    pub fn save_folder_destination(&self, d: &StoredFolderDestination) -> Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO folder_destinations (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
            &[text(&d.id), to_json(d)],
        )?;
        Ok(())
    }

    pub fn folder_destinations(&self) -> Result<Vec<StoredFolderDestination>> {
        let mut all: Vec<StoredFolderDestination> =
            json_rows(&self.conn(), "SELECT json FROM folder_destinations", &[])?;
        all.sort_by_key(|d| d.name.to_lowercase());
        Ok(all)
    }

    pub fn folder_destination(&self, id: &str) -> Result<Option<StoredFolderDestination>> {
        Ok(json_rows(
            &self.conn(),
            "SELECT json FROM folder_destinations WHERE id = ?",
            &[text(id)],
        )?
        .into_iter()
        .next())
    }

    pub fn delete_folder_destination(&self, id: &str) -> Result<()> {
        exec(
            &self.conn(),
            "DELETE FROM folder_destinations WHERE id = ?",
            &[text(id)],
        )?;
        Ok(())
    }

    // MARK: Known cameras

    /// A `None` host keeps the one remembered before.
    pub fn remember_camera(&self, c: &CameraIdentity, host: Option<&str>) -> Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO known_cameras (id, last_seen, host, json) VALUES (?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen, host=COALESCE(excluded.host, known_cameras.host), json=excluded.json",
            &[text(&c.id), real(&Utc::now()), opt_text(host), to_json(c)],
        )?;
        Ok(())
    }

    pub fn known_cameras(&self) -> Result<Vec<KnownCamera>> {
        let rows = database::query_rows(
            &self.conn(),
            "SELECT json, host, last_seen FROM known_cameras ORDER BY last_seen DESC",
            &[],
        )?;
        Ok(rows
            .into_iter()
            .filter_map(|r| {
                let identity: CameraIdentity = serde_json::from_str(r.string("json")?).ok()?;
                Some(KnownCamera {
                    identity,
                    host: r.string("host").map(str::to_string),
                    last_seen: r
                        .double("last_seen")
                        .map(swift_json::from_unix_seconds)
                        .unwrap_or_else(Utc::now),
                })
            })
            .collect())
    }

    // MARK: Settings

    pub fn setting(&self, key: &str) -> Option<String> {
        let conn = self.conn();
        conn.query_row("SELECT value FROM settings WHERE key = ?", [key], |r| {
            r.get::<_, String>(0)
        })
        .ok()
    }

    /// `None` deletes the key.
    pub fn set_setting(&self, key: &str, value: Option<&str>) {
        let conn = self.conn();
        let _ = match value {
            Some(v) => exec(
                &conn,
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                &[text(key), text(v)],
            ),
            None => exec(&conn, "DELETE FROM settings WHERE key = ?", &[text(key)]),
        };
    }
}

/// What a picked folder looked like, so exports can follow that tool's layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum FolderKind {
    /// Any folder.
    #[default]
    Plain,
    /// The root of a Capture One session (it holds a `.cosessiondb`):
    /// files go straight into its Capture / Selects / Trash folders.
    CaptureOneSession,
    /// A folder Lightroom Classic watches (Auto Import): flat, sidecar first.
    LightroomAutoImport,
}

/// A folder the user picked. The bookmark is opaque here; the app resolves
/// it (security-scoped in the sandbox).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StoredFolderDestination {
    pub id: String,
    pub name: String,
    #[serde(with = "swift_json::base64_data")]
    pub bookmark: Vec<u8>,
    pub kind: FolderKind,
    /// Last resolved path, for display only ("iCloud Drive › Shoots").
    #[serde(
        rename = "displayPath",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub display_path: Option<String>,
}

impl StoredFolderDestination {
    pub fn new(name: impl Into<String>, bookmark: Vec<u8>, kind: FolderKind) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            name: name.into(),
            bookmark,
            kind,
            display_path: None,
        }
    }

    /// The layout exports into this folder should use by default.
    pub fn suggested_layout(&self) -> Option<FolderLayout> {
        match self.kind {
            FolderKind::Plain => None,
            FolderKind::CaptureOneSession => Some(FolderLayout::CaptureOneSessionRoot),
            FolderKind::LightroomAutoImport => Some(FolderLayout::Flat),
        }
    }

    /// Recognise a Capture One session root from the names of its entries.
    pub fn detect_kind<S: AsRef<str>>(entries: &[S]) -> FolderKind {
        if entries
            .iter()
            .any(|e| e.as_ref().to_lowercase().ends_with(".cosessiondb"))
        {
            FolderKind::CaptureOneSession
        } else {
            FolderKind::Plain
        }
    }
}

/// An FTP upload target the user saved (the password lives in the
/// Keychain; here only its reference).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StoredFtpDestination {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    /// `"plain"` | `"explicitTLS"` | `"implicitTLS"`.
    pub security: String,
    pub passive: bool,
    #[serde(rename = "remoteDirectory")]
    pub remote_directory: String,
    #[serde(rename = "passwordKeychainKey")]
    pub password_keychain_key: String,
}

impl StoredFtpDestination {
    /// Port 21, explicit TLS, passive, remote `/`, keychain key `ftp.<id>`.
    pub fn new(
        name: impl Into<String>,
        host: impl Into<String>,
        username: impl Into<String>,
    ) -> Self {
        let id = uuid::Uuid::new_v4().to_string().to_uppercase();
        Self {
            password_keychain_key: format!("ftp.{id}"),
            id,
            name: name.into(),
            host: host.into(),
            port: 21,
            username: username.into(),
            security: "explicitTLS".into(),
            passive: true,
            remote_directory: "/".into(),
        }
    }
}
