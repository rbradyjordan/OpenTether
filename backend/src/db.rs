//! SQLite storage. One connection behind a mutex; every query is short, so
//! handlers call `with` directly without blocking the runtime noticeably.

use std::path::Path;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Duration, Months, Utc};
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;

use crate::error::AppError;

pub const FREE_MONTHLY_GRANT: i64 = 10;

#[derive(Clone)]
pub struct Db {
    conn: Arc<Mutex<Connection>>,
}

impl Db {
    pub fn open(path: &Path) -> Result<Self, AppError> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA foreign_keys = ON;
             PRAGMA busy_timeout = 5000;",
        )?;
        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.migrate()?;
        Ok(db)
    }

    /// Idempotent schema; every statement is `IF NOT EXISTS`.
    fn migrate(&self) -> Result<(), AppError> {
        self.with(|c| {
            c.execute_batch(
                "CREATE TABLE IF NOT EXISTS accounts (
                    id            TEXT PRIMARY KEY,
                    device_id     TEXT NOT NULL UNIQUE,
                    platform      TEXT NOT NULL,
                    app_version   TEXT NOT NULL,
                    tier          TEXT NOT NULL DEFAULT 'free',
                    credits       INTEGER NOT NULL DEFAULT 0,
                    monthly_grant INTEGER NOT NULL DEFAULT 10,
                    renews_at     TEXT,
                    pro_until     TEXT,
                    created_at    TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tokens (
                    token_hash  TEXT PRIMARY KEY,
                    account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    created_at  TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS tokens_account ON tokens(account_id);
                CREATE TABLE IF NOT EXISTS looks (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL,
                    family      TEXT NOT NULL,
                    version     INTEGER NOT NULL DEFAULT 1,
                    size        INTEGER NOT NULL,
                    sha256      TEXT NOT NULL,
                    cube        TEXT NOT NULL,
                    warmth      REAL NOT NULL DEFAULT 0,
                    contrast    REAL NOT NULL DEFAULT 0,
                    saturation  REAL NOT NULL DEFAULT 0,
                    account_id  TEXT REFERENCES accounts(id) ON DELETE CASCADE,
                    sort_order  INTEGER NOT NULL DEFAULT 0,
                    created_at  TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS looks_account ON looks(account_id);
                CREATE TABLE IF NOT EXISTS export_batches (
                    id            TEXT PRIMARY KEY,
                    account_id    TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    session_name  TEXT NOT NULL,
                    look_id       TEXT,
                    status        TEXT NOT NULL DEFAULT 'open',
                    created_at    TEXT NOT NULL,
                    completed_at  TEXT,
                    expires_at    TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS export_items (
                    id             TEXT PRIMARY KEY,
                    batch_id       TEXT NOT NULL REFERENCES export_batches(id) ON DELETE CASCADE,
                    client_id      TEXT NOT NULL,
                    filename       TEXT NOT NULL,
                    kind           TEXT NOT NULL,
                    bytes_expected INTEGER NOT NULL,
                    bytes_stored   INTEGER,
                    watermark      INTEGER NOT NULL DEFAULT 0,
                    position       INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS export_items_batch ON export_items(batch_id);
                CREATE TABLE IF NOT EXISTS purchases (
                    transaction_id TEXT PRIMARY KEY,
                    account_id     TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    product_id     TEXT NOT NULL,
                    response_json  TEXT NOT NULL,
                    created_at     TEXT NOT NULL
                );",
            )
        })
    }

    pub fn with<T>(
        &self,
        f: impl FnOnce(&Connection) -> rusqlite::Result<T>,
    ) -> Result<T, AppError> {
        let conn = self
            .conn
            .lock()
            .map_err(|_| AppError::internal("database mutex poisoned"))?;
        Ok(f(&conn)?)
    }

    /// Like `with`, but the closure may fail with an [`AppError`] (404s, 402s…)
    /// and runs inside a transaction that is rolled back on any error.
    pub fn transaction<T>(
        &self,
        f: impl FnOnce(&Connection) -> Result<T, AppError>,
    ) -> Result<T, AppError> {
        let mut conn = self
            .conn
            .lock()
            .map_err(|_| AppError::internal("database mutex poisoned"))?;
        let tx = conn.transaction()?;
        let out = f(&tx)?;
        tx.commit()?;
        Ok(out)
    }

    // ----- accounts -----

    pub fn account_by_id(&self, id: &str) -> Result<Option<Account>, AppError> {
        self.with(|c| load_account(c, "SELECT * FROM accounts WHERE id = ?1", id))
    }

    pub fn account_by_token_hash(&self, hash: &str) -> Result<Option<Account>, AppError> {
        self.with(|c| {
            load_account(
                c,
                "SELECT a.* FROM accounts a JOIN tokens t ON t.account_id = a.id WHERE t.token_hash = ?1",
                hash,
            )
        })
    }

    /// Lazy ledger upkeep on every authenticated request: expire pro, apply
    /// the monthly grant (top-up, not additive), roll `renews_at` forward.
    pub fn refresh_account(
        &self,
        mut acct: Account,
        now: DateTime<Utc>,
    ) -> Result<Account, AppError> {
        let mut changed = false;
        if acct.tier == Tier::Pro && acct.pro_until.is_some_and(|until| until <= now) {
            acct.tier = Tier::Free;
            acct.pro_until = None;
            changed = true;
        }
        if let Some(mut renews) = acct.renews_at {
            if renews <= now {
                acct.credits = acct.credits.max(acct.monthly_grant);
                while renews <= now {
                    renews = renews
                        .checked_add_months(Months::new(1))
                        .unwrap_or(renews + Duration::days(30));
                }
                acct.renews_at = Some(renews);
                changed = true;
            }
        }
        if changed {
            self.with(|c| {
                c.execute(
                    "UPDATE accounts SET tier = ?2, pro_until = ?3, credits = ?4, renews_at = ?5 WHERE id = ?1",
                    params![
                        acct.id,
                        acct.tier.as_str(),
                        acct.pro_until.map(|t| t.to_rfc3339()),
                        acct.credits,
                        acct.renews_at.map(|t| t.to_rfc3339()),
                    ],
                )
            })?;
        }
        Ok(acct)
    }
}

pub fn load_account(c: &Connection, sql: &str, arg: &str) -> rusqlite::Result<Option<Account>> {
    c.query_row(sql, [arg], Account::from_row).optional()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    Free,
    Pro,
}

impl Tier {
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Free => "free",
            Tier::Pro => "pro",
        }
    }

    pub fn parse(s: &str) -> Self {
        if s == "pro" {
            Tier::Pro
        } else {
            Tier::Free
        }
    }
}

#[derive(Debug, Clone)]
pub struct Account {
    pub id: String,
    pub device_id: String,
    pub tier: Tier,
    pub credits: i64,
    pub monthly_grant: i64,
    pub renews_at: Option<DateTime<Utc>>,
    pub pro_until: Option<DateTime<Utc>>,
}

impl Account {
    pub fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            device_id: row.get("device_id")?,
            tier: Tier::parse(&row.get::<_, String>("tier")?),
            credits: row.get("credits")?,
            monthly_grant: row.get("monthly_grant")?,
            renews_at: parse_time(row.get::<_, Option<String>>("renews_at")?),
            pro_until: parse_time(row.get::<_, Option<String>>("pro_until")?),
        })
    }

    pub fn watermark_required(&self) -> bool {
        self.tier == Tier::Free && self.credits == 0
    }

    pub fn credits_json(&self) -> Credits {
        Credits {
            balance: self.credits,
            monthly_grant: self.monthly_grant,
            renews_at: self.renews_at,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Credits {
    pub balance: i64,
    pub monthly_grant: i64,
    pub renews_at: Option<DateTime<Utc>>,
}

pub fn parse_time(s: Option<String>) -> Option<DateTime<Utc>> {
    s.and_then(|s| DateTime::parse_from_rfc3339(&s).ok())
        .map(|t| t.with_timezone(&Utc))
}
