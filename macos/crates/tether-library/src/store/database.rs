//! Opening SQLite the way `SQLiteDatabase.swift` does: WAL, foreign keys,
//! a busy timeout; and read-only private snapshots of other apps' databases.

use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OpenFlags, Row};

use crate::Result;

/// Opens (creating if needed) a read-write database in WAL mode with
/// foreign keys on. `":memory:"` opens an in-memory database.
pub fn open(path: &str) -> Result<Connection> {
    let conn = if path == ":memory:" {
        Connection::open_in_memory()?
    } else {
        if let Some(parent) = Path::new(path).parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
        )?
    };
    conn.busy_timeout(Duration::from_millis(5000))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    Ok(conn)
}

/// Someone else's database read through a private copy: the file and its
/// `-wal` / `-shm` journals are copied to a temporary folder first, so
/// changes the other app has not checkpointed yet are included and the
/// original is never opened, locked or written. The copy is query-only and
/// is deleted when this value is dropped.
pub struct Snapshot {
    // Field order matters: the connection closes before the folder goes.
    conn: Connection,
    dir: tempfile::TempDir,
    path: PathBuf,
}

impl Snapshot {
    pub fn of(path: &Path) -> Result<Snapshot> {
        let dir = tempfile::Builder::new().prefix("catalog-").tempdir()?;
        let name = path
            .file_name()
            .map(|n| n.to_os_string())
            .unwrap_or_else(|| "catalog".into());
        let copy = dir.path().join(name);
        std::fs::copy(path, &copy)?;
        for suffix in ["-wal", "-shm"] {
            let mut journal = path.as_os_str().to_os_string();
            journal.push(suffix);
            let journal = PathBuf::from(journal);
            if journal.exists() {
                let mut target = copy.as_os_str().to_os_string();
                target.push(suffix);
                let _ = std::fs::copy(&journal, PathBuf::from(target));
            }
        }
        let conn = Connection::open_with_flags(
            &copy,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
        )?;
        conn.busy_timeout(Duration::from_millis(2000))?;
        conn.pragma_update(None, "query_only", "ON")?;
        Ok(Snapshot {
            conn,
            dir,
            path: copy,
        })
    }

    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    /// Path of the private copy (inside a temporary folder).
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn folder(&self) -> &Path {
        self.dir.path()
    }
}

/// A result row as name → value, like the Swift wrapper's `Row`.
#[derive(Debug, Clone, Default)]
pub struct RowMap(pub Vec<(String, SqlValue)>);

impl RowMap {
    pub fn from_row(row: &Row<'_>) -> rusqlite::Result<RowMap> {
        let stmt = row.as_ref();
        let mut out = Vec::with_capacity(stmt.column_count());
        for i in 0..stmt.column_count() {
            let name = stmt.column_name(i)?.to_string();
            out.push((name, row.get::<_, SqlValue>(i)?));
        }
        Ok(RowMap(out))
    }

    pub fn get(&self, name: &str) -> Option<&SqlValue> {
        self.0.iter().find(|(n, _)| n == name).map(|(_, v)| v)
    }

    /// Integer columns only (Swift `.int64`).
    pub fn int(&self, name: &str) -> Option<i64> {
        match self.get(name)? {
            SqlValue::Integer(i) => Some(*i),
            _ => None,
        }
    }

    /// Real or integer columns (Swift `.double`).
    pub fn double(&self, name: &str) -> Option<f64> {
        match self.get(name)? {
            SqlValue::Real(d) => Some(*d),
            SqlValue::Integer(i) => Some(*i as f64),
            _ => None,
        }
    }

    pub fn string(&self, name: &str) -> Option<&str> {
        match self.get(name)? {
            SqlValue::Text(s) => Some(s.as_str()),
            _ => None,
        }
    }
}

/// Runs a query and returns every row as a [`RowMap`].
pub fn query_rows(conn: &Connection, sql: &str, params: &[SqlValue]) -> Result<Vec<RowMap>> {
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(params.iter()), RowMap::from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}
