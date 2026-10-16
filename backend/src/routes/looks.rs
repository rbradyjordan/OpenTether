//! Looks catalog and `.cube` serving (catalog looks are public; `match`
//! LUTs are per-account and 404 for anyone else).

use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::auth::MaybeAuth;
use crate::db::Db;
use crate::error::AppError;
use crate::looks::{catalog_lut, Lut3d, CATALOG};
use crate::AppState;

#[derive(Serialize)]
pub struct HintJson {
    pub warmth: f32,
    pub contrast: f32,
    pub saturation: f32,
}

#[derive(Serialize)]
pub struct LookJson {
    pub id: String,
    pub name: String,
    pub family: String,
    pub version: i64,
    pub size: i64,
    pub sha256: String,
    pub cube_url: String,
    pub hint: HintJson,
}

#[derive(Serialize)]
pub struct LooksResponse {
    pub looks: Vec<LookJson>,
}

pub fn cube_url(id: &str) -> String {
    format!("/v1/looks/{id}.cube")
}

/// Idempotent: (re)writes the seven catalog rows from the procedural definitions.
pub fn seed_catalog(db: &Db) -> Result<(), AppError> {
    let now = Utc::now().to_rfc3339();
    db.with(|c| {
        for (i, def) in CATALOG.iter().enumerate() {
            let lut = catalog_lut(def);
            let cube = lut.to_cube(def.name);
            let sha = Lut3d::sha256_hex_of(&cube);
            c.execute(
                "INSERT INTO looks (id, name, family, version, size, sha256, cube, warmth, contrast, saturation, account_id, sort_order, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, NULL, ?11, ?12)
                 ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, family = excluded.family, version = excluded.version,
                    size = excluded.size, sha256 = excluded.sha256, cube = excluded.cube,
                    warmth = excluded.warmth, contrast = excluded.contrast, saturation = excluded.saturation,
                    sort_order = excluded.sort_order",
                params![
                    def.id, def.name, def.family, def.version, lut.size as i64, sha, cube,
                    def.hint.warmth, def.hint.contrast, def.hint.saturation, i as i64, now
                ],
            )?;
        }
        Ok(())
    })?;
    tracing::info!(count = CATALOG.len(), "looks catalog seeded");
    Ok(())
}

pub struct StoredLook {
    pub id: String,
    pub name: String,
    pub family: String,
    pub sha256: String,
    pub cube: String,
    pub account_id: Option<String>,
}

pub fn load_look(c: &Connection, id: &str) -> rusqlite::Result<Option<StoredLook>> {
    c.query_row(
        "SELECT id, name, family, sha256, cube, account_id FROM looks WHERE id = ?1",
        [id],
        |r| {
            Ok(StoredLook {
                id: r.get(0)?,
                name: r.get(1)?,
                family: r.get(2)?,
                sha256: r.get(3)?,
                cube: r.get(4)?,
                account_id: r.get(5)?,
            })
        },
    )
    .optional()
}

/// A per-account LUT to store (colour-match results).
pub struct NewLook<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub family: &'a str,
    pub size: usize,
    pub cube: &'a str,
    pub sha256: &'a str,
    pub account_id: &'a str,
}

pub fn insert_look(c: &Connection, look: &NewLook<'_>) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO looks (id, name, family, version, size, sha256, cube, account_id, created_at)
         VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8)",
        params![
            look.id,
            look.name,
            look.family,
            look.size as i64,
            look.sha256,
            look.cube,
            look.account_id,
            Utc::now().to_rfc3339()
        ],
    )?;
    Ok(())
}

pub async fn list(State(state): State<AppState>) -> Result<Json<LooksResponse>, AppError> {
    let looks = state.db.with(|c| {
        let mut stmt = c.prepare(
            "SELECT id, name, family, version, size, sha256, warmth, contrast, saturation
             FROM looks WHERE account_id IS NULL ORDER BY sort_order, id",
        )?;
        let rows = stmt.query_map([], |r| {
            let id: String = r.get(0)?;
            Ok(LookJson {
                cube_url: cube_url(&id),
                id,
                name: r.get(1)?,
                family: r.get(2)?,
                version: r.get(3)?,
                size: r.get(4)?,
                sha256: r.get(5)?,
                hint: HintJson {
                    warmth: r.get(6)?,
                    contrast: r.get(7)?,
                    saturation: r.get(8)?,
                },
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
    })?;
    Ok(Json(LooksResponse { looks }))
}

/// `GET /v1/looks/{id}.cube`
pub async fn cube(
    State(state): State<AppState>,
    Path(file): Path<String>,
    MaybeAuth(viewer): MaybeAuth,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let Some(id) = file.strip_suffix(".cube") else {
        return Err(AppError::not_found("look"));
    };
    let look = state
        .db
        .with(|c| load_look(c, id))?
        .ok_or_else(|| AppError::not_found("look"))?;
    if let Some(owner) = &look.account_id {
        if viewer.as_ref().map(|a| a.id.as_str()) != Some(owner.as_str()) {
            return Err(AppError::not_found("look"));
        }
    }
    let etag = format!("\"{}\"", look.sha256);
    let matches = headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| {
            v.split(',')
                .map(|t| t.trim().trim_start_matches("W/"))
                .any(|t| t == etag || t == "*")
        });
    let etag_value = HeaderValue::from_str(&etag).map_err(|e| AppError::internal(e.to_string()))?;
    if matches {
        return Ok(([(header::ETAG, etag_value)], StatusCode::NOT_MODIFIED).into_response());
    }
    Ok((
        StatusCode::OK,
        [
            (
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/plain; charset=utf-8"),
            ),
            (header::ETAG, etag_value),
            (
                header::CACHE_CONTROL,
                HeaderValue::from_static("private, max-age=86400"),
            ),
        ],
        look.cube,
    )
        .into_response())
}
