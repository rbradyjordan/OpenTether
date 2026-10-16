//! Cloud batch export: reserve a batch (credits + watermark rules), PUT each
//! item, HEAD to resume, complete, download a stored-only zip. Batches expire
//! seven days after completion (or creation, if never completed).

use std::io::Write as _;
use std::path::{Path as FsPath, PathBuf};
use std::time::Duration as StdDuration;

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use futures::StreamExt;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::auth::Auth;
use crate::db::{load_account, parse_time, Tier};
use crate::error::{AppError, Json as AppJson};
use crate::AppState;

pub const ITEM_LIMIT: usize = 200 * 1024 * 1024;
pub const MAX_ITEMS: usize = 500;
pub const EXPIRY_DAYS: i64 = 7;

#[derive(Deserialize)]
pub struct BatchItemReq {
    pub client_id: String,
    pub filename: String,
    pub kind: String,
    pub bytes: i64,
}

#[derive(Deserialize)]
pub struct CreateBatchBody {
    pub session_name: String,
    #[serde(default)]
    pub watermark: bool,
    #[serde(default)]
    pub look_id: Option<String>,
    pub items: Vec<BatchItemReq>,
    /// Optional session manifest (any JSON) written into the zip as
    /// `manifest.json` so the download carries ratings, tags and names.
    #[serde(default)]
    pub manifest: Option<serde_json::Value>,
}

#[derive(Serialize)]
pub struct BatchItemResp {
    pub client_id: String,
    pub item_id: String,
    pub put_url: String,
    pub watermark: bool,
}

#[derive(Serialize)]
pub struct CreateBatchResponse {
    pub batch_id: String,
    pub items: Vec<BatchItemResp>,
    pub credits_charged: i64,
    pub credits_remaining: i64,
}

fn item_url(batch: &str, item: &str) -> String {
    format!("/v1/exports/{batch}/items/{item}")
}

fn download_url(batch: &str) -> String {
    format!("/v1/exports/{batch}/download")
}

fn batch_dir(state: &AppState, batch: &str) -> PathBuf {
    state.config.storage.join("exports").join(batch)
}

fn parse_uuid(s: &str, what: &str) -> Result<String, AppError> {
    Uuid::parse_str(s)
        .map(|u| u.to_string())
        .map_err(|_| AppError::not_found(what))
}

/// Keeps a client filename usable inside the zip: basename only, no control
/// characters, non-empty.
pub fn sanitize_filename(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = base
        .chars()
        .filter(|c| {
            !c.is_control()
                && *c != ':'
                && *c != '*'
                && *c != '?'
                && *c != '"'
                && *c != '<'
                && *c != '>'
                && *c != '|'
        })
        .collect();
    let cleaned = cleaned.trim().trim_start_matches('.').to_string();
    if cleaned.is_empty() {
        "item".to_string()
    } else {
        cleaned
    }
}

pub async fn create_batch(
    State(state): State<AppState>,
    Auth(acct): Auth,
    AppJson(body): AppJson<CreateBatchBody>,
) -> Result<Json<CreateBatchResponse>, AppError> {
    if body.items.is_empty() {
        return Err(AppError::bad_request("no_items", "items must not be empty"));
    }
    if body.items.len() > MAX_ITEMS {
        return Err(AppError::bad_request(
            "too_many_items",
            format!("at most {MAX_ITEMS} items per batch"),
        ));
    }
    let session_name = body.session_name.trim();
    if session_name.is_empty() || session_name.len() > 200 {
        return Err(AppError::bad_request(
            "invalid_session_name",
            "session_name is required (max 200 chars)",
        ));
    }
    let mut seen = std::collections::HashSet::new();
    for it in &body.items {
        if it.kind != "jpeg" && it.kind != "raw" {
            return Err(AppError::bad_request(
                "invalid_kind",
                "kind must be \"jpeg\" or \"raw\"",
            ));
        }
        if it.bytes <= 0 || it.bytes > ITEM_LIMIT as i64 {
            return Err(AppError::bad_request(
                "invalid_bytes",
                "bytes must be between 1 and 200 MiB",
            ));
        }
        if it.client_id.trim().is_empty() || !seen.insert(it.client_id.as_str()) {
            return Err(AppError::bad_request(
                "invalid_client_id",
                "client_id must be unique and non-empty",
            ));
        }
    }
    if let Some(look) = body.look_id.as_deref() {
        let known = state
            .db
            .with(|c| crate::routes::looks::load_look(c, look))?;
        match known {
            Some(l)
                if l.account_id.is_none() || l.account_id.as_deref() == Some(acct.id.as_str()) => {}
            _ => return Err(AppError::not_found("look")),
        }
    }

    let now = Utc::now();
    let batch_id = Uuid::new_v4().to_string();
    let expires_at = now + Duration::days(EXPIRY_DAYS);
    let account_id = acct.id.clone();

    let (items, charged, remaining) = state.db.transaction(|c| {
        let fresh = load_account(c, "SELECT * FROM accounts WHERE id = ?1", &account_id)?
            .ok_or_else(AppError::unauthorized)?;
        let mut balance = fresh.credits;
        let mut charged = 0i64;
        let mut out = Vec::with_capacity(body.items.len());
        c.execute(
            "INSERT INTO export_batches (id, account_id, session_name, look_id, status, created_at, expires_at)
             VALUES (?1, ?2, ?3, ?4, 'open', ?5, ?6)",
            params![batch_id, account_id, session_name, body.look_id, now.to_rfc3339(), expires_at.to_rfc3339()],
        )?;
        for (pos, it) in body.items.iter().enumerate() {
            let is_jpeg = it.kind == "jpeg";
            // Credit rule: free tier pays 1 per JPEG; once the balance is gone the
            // remaining JPEGs are accepted with the watermark on. Pro pays nothing
            // and is never watermarked unless the client asks for it. RAW files can't
            // carry a burned-in mark, so they are never flagged.
            let watermark = if !is_jpeg {
                false
            } else if fresh.tier == Tier::Pro {
                body.watermark
            } else if balance > 0 {
                balance -= 1;
                charged += 1;
                body.watermark
            } else {
                true
            };
            let item_id = Uuid::new_v4().to_string();
            c.execute(
                "INSERT INTO export_items (id, batch_id, client_id, filename, kind, bytes_expected, watermark, position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![item_id, batch_id, it.client_id, sanitize_filename(&it.filename), it.kind, it.bytes, watermark as i64, pos as i64],
            )?;
            out.push(BatchItemResp {
                client_id: it.client_id.clone(),
                put_url: item_url(&batch_id, &item_id),
                item_id,
                watermark,
            });
        }
        c.execute("UPDATE accounts SET credits = ?2 WHERE id = ?1", params![account_id, balance])?;
        Ok((out, charged, balance))
    })?;
    if let Some(manifest) = &body.manifest {
        let dir = batch_dir(&state, &batch_id);
        tokio::fs::create_dir_all(&dir).await?;
        tokio::fs::write(
            dir.join("manifest.json"),
            serde_json::to_vec_pretty(manifest)
                .map_err(|e| AppError::internal(format!("manifest: {e}")))?,
        )
        .await?;
    }

    tokio::fs::create_dir_all(batch_dir(&state, &batch_id)).await?;
    tracing::info!(account = %acct.id, batch = %batch_id, items = items.len(), charged, "export batch created");
    Ok(Json(CreateBatchResponse {
        batch_id,
        items,
        credits_charged: charged,
        credits_remaining: remaining,
    }))
}

// ----- shared loaders -----

pub struct BatchRow {
    pub id: String,
    pub account_id: String,
    pub session_name: String,
    pub status: String,
    pub expires_at: Option<DateTime<Utc>>,
}

pub struct ItemRow {
    pub id: String,
    pub client_id: String,
    pub filename: String,
    pub kind: String,
    pub bytes_expected: i64,
    pub bytes_stored: Option<i64>,
    pub watermark: bool,
}

fn load_batch(c: &Connection, id: &str) -> rusqlite::Result<Option<BatchRow>> {
    c.query_row(
        "SELECT id, account_id, session_name, status, expires_at FROM export_batches WHERE id = ?1",
        [id],
        |r| {
            Ok(BatchRow {
                id: r.get(0)?,
                account_id: r.get(1)?,
                session_name: r.get(2)?,
                status: r.get(3)?,
                expires_at: parse_time(r.get(4)?),
            })
        },
    )
    .optional()
}

fn load_items(c: &Connection, batch: &str) -> rusqlite::Result<Vec<ItemRow>> {
    let mut stmt = c.prepare(
        "SELECT id, client_id, filename, kind, bytes_expected, bytes_stored, watermark
         FROM export_items WHERE batch_id = ?1 ORDER BY position",
    )?;
    let rows = stmt.query_map([batch], |r| {
        Ok(ItemRow {
            id: r.get(0)?,
            client_id: r.get(1)?,
            filename: r.get(2)?,
            kind: r.get(3)?,
            bytes_expected: r.get(4)?,
            bytes_stored: r.get(5)?,
            watermark: r.get::<_, i64>(6)? != 0,
        })
    })?;
    rows.collect()
}

fn owned_batch(state: &AppState, acct_id: &str, batch: &str) -> Result<BatchRow, AppError> {
    let batch = parse_uuid(batch, "batch")?;
    let row = state.db.with(|c| load_batch(c, &batch))?;
    match row {
        Some(b) if b.account_id == acct_id => Ok(b),
        _ => Err(AppError::not_found("batch")),
    }
}

fn owned_item(state: &AppState, batch: &BatchRow, item: &str) -> Result<ItemRow, AppError> {
    let item = parse_uuid(item, "item")?;
    let row = state.db.with(|c| {
        c.query_row(
            "SELECT id, client_id, filename, kind, bytes_expected, bytes_stored, watermark
             FROM export_items WHERE id = ?1 AND batch_id = ?2",
            params![item, batch.id],
            |r| {
                Ok(ItemRow {
                    id: r.get(0)?,
                    client_id: r.get(1)?,
                    filename: r.get(2)?,
                    kind: r.get(3)?,
                    bytes_expected: r.get(4)?,
                    bytes_stored: r.get(5)?,
                    watermark: r.get::<_, i64>(6)? != 0,
                })
            },
        )
        .optional()
    })?;
    row.ok_or_else(|| AppError::not_found("item"))
}

fn require_open(batch: &BatchRow) -> Result<(), AppError> {
    match batch.status.as_str() {
        "open" => Ok(()),
        "complete" => Err(AppError::conflict(
            "batch_complete",
            "batch is already complete",
        )),
        _ => Err(AppError::conflict("batch_expired", "batch has expired")),
    }
}

// ----- PUT / HEAD item -----

#[derive(Serialize)]
pub struct PutItemResponse {
    pub item_id: String,
    pub status: &'static str,
    pub bytes: i64,
}

pub async fn put_item(
    State(state): State<AppState>,
    Auth(acct): Auth,
    Path((batch, item)): Path<(String, String)>,
    body: Body,
) -> Result<Json<PutItemResponse>, AppError> {
    let batch = owned_batch(&state, &acct.id, &batch)?;
    require_open(&batch)?;
    let item = owned_item(&state, &batch, &item)?;

    let dir = batch_dir(&state, &batch.id);
    tokio::fs::create_dir_all(&dir).await?;
    let final_path = dir.join(&item.id);
    let part_path = dir.join(format!("{}.part", item.id));

    // Stream the body to disk, counting bytes; the route's RequestBodyLimitLayer
    // surfaces an overflow as a stream error which we report as 413.
    let mut file = tokio::fs::File::create(&part_path).await?;
    let mut stream = body.into_data_stream();
    let mut total: u64 = 0;
    let mut failure: Option<AppError> = None;
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(bytes) => {
                total += bytes.len() as u64;
                if total > ITEM_LIMIT as u64 {
                    failure = Some(AppError::payload_too_large("item exceeds 200 MiB"));
                    break;
                }
                if let Err(e) = file.write_all(&bytes).await {
                    failure = Some(e.into());
                    break;
                }
            }
            Err(e) => {
                let msg = e.to_string();
                failure = Some(
                    if msg.contains("length limit") || msg.contains("too large") {
                        AppError::payload_too_large("item exceeds 200 MiB")
                    } else {
                        AppError::bad_request("upload_interrupted", msg)
                    },
                );
                break;
            }
        }
    }
    if failure.is_none() {
        if let Err(e) = file.flush().await {
            failure = Some(e.into());
        }
    }
    drop(file);
    if let Some(err) = failure {
        let _ = tokio::fs::remove_file(&part_path).await;
        return Err(err);
    }
    if total == 0 {
        let _ = tokio::fs::remove_file(&part_path).await;
        return Err(AppError::bad_request("empty_body", "item body is empty"));
    }

    if item.watermark && item.kind == "jpeg" {
        let src = part_path.clone();
        let marked = tokio::task::spawn_blocking(move || -> Result<Option<Vec<u8>>, AppError> {
            let bytes = std::fs::read(&src)?;
            match crate::watermark::watermark_jpeg(&bytes) {
                Ok(out) => Ok(Some(out)),
                Err(e) => {
                    tracing::warn!(error = %e, "watermark skipped: stored copy left as uploaded");
                    Ok(None)
                }
            }
        })
        .await
        .map_err(|e| AppError::internal(format!("watermark task: {e}")))??;
        if let Some(bytes) = marked {
            tokio::fs::write(&part_path, &bytes).await?;
        }
    }
    tokio::fs::rename(&part_path, &final_path).await?;
    let stored = tokio::fs::metadata(&final_path).await?.len() as i64;

    state.db.with(|c| {
        c.execute(
            "UPDATE export_items SET bytes_stored = ?2 WHERE id = ?1",
            params![item.id, stored],
        )
    })?;
    // A fresh upload invalidates any cached zip.
    let _ = tokio::fs::remove_file(dir.join("download.zip")).await;
    tracing::info!(batch = %batch.id, item = %item.id, bytes = stored, watermark = item.watermark, "item stored");
    Ok(Json(PutItemResponse {
        item_id: item.id,
        status: "stored",
        bytes: stored,
    }))
}

pub async fn head_item(
    State(state): State<AppState>,
    Auth(acct): Auth,
    Path((batch, item)): Path<(String, String)>,
) -> Result<Response, AppError> {
    let batch = owned_batch(&state, &acct.id, &batch)?;
    let item = owned_item(&state, &batch, &item)?;
    let Some(bytes) = item.bytes_stored else {
        return Err(AppError::not_found("stored item"));
    };
    if batch.status == "expired" {
        return Err(AppError::not_found("stored item"));
    }
    let len =
        HeaderValue::from_str(&bytes.to_string()).map_err(|e| AppError::internal(e.to_string()))?;
    Ok((
        StatusCode::OK,
        [(header::CONTENT_LENGTH, len)],
        Body::empty(),
    )
        .into_response())
}

// ----- complete / get -----

#[derive(Serialize)]
pub struct ItemStatus {
    pub item_id: String,
    pub client_id: String,
    pub filename: String,
    pub bytes_expected: i64,
    pub bytes_stored: i64,
    pub watermark: bool,
}

#[derive(Serialize)]
pub struct BatchStatus {
    pub batch_id: String,
    pub session_name: String,
    pub status: String,
    pub items: Vec<ItemStatus>,
    pub download_url: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
}

fn batch_status(state: &AppState, batch: BatchRow) -> Result<BatchStatus, AppError> {
    let items = state.db.with(|c| load_items(c, &batch.id))?;
    let download = (batch.status == "complete").then(|| download_url(&batch.id));
    Ok(BatchStatus {
        batch_id: batch.id,
        session_name: batch.session_name,
        status: batch.status,
        items: items
            .into_iter()
            .map(|i| ItemStatus {
                item_id: i.id,
                client_id: i.client_id,
                filename: i.filename,
                bytes_expected: i.bytes_expected,
                bytes_stored: i.bytes_stored.unwrap_or(0),
                watermark: i.watermark,
            })
            .collect(),
        download_url: download,
        expires_at: batch.expires_at,
    })
}

pub async fn get_batch(
    State(state): State<AppState>,
    Auth(acct): Auth,
    Path(batch): Path<String>,
) -> Result<Json<BatchStatus>, AppError> {
    let batch = owned_batch(&state, &acct.id, &batch)?;
    Ok(Json(batch_status(&state, batch)?))
}

pub async fn complete(
    State(state): State<AppState>,
    Auth(acct): Auth,
    Path(batch): Path<String>,
) -> Result<Json<BatchStatus>, AppError> {
    let mut batch = owned_batch(&state, &acct.id, &batch)?;
    if batch.status == "complete" {
        return Ok(Json(batch_status(&state, batch)?));
    }
    require_open(&batch)?;
    let items = state.db.with(|c| load_items(c, &batch.id))?;
    let missing: Vec<&str> = items
        .iter()
        .filter(|i| i.bytes_stored.is_none())
        .map(|i| i.id.as_str())
        .collect();
    if !missing.is_empty() {
        return Err(AppError::conflict(
            "items_missing",
            format!(
                "{} item(s) have not been uploaded: {}",
                missing.len(),
                missing.join(", ")
            ),
        ));
    }
    let now = Utc::now();
    let expires = now + Duration::days(EXPIRY_DAYS);
    state.db.with(|c| {
        c.execute(
            "UPDATE export_batches SET status = 'complete', completed_at = ?2, expires_at = ?3 WHERE id = ?1 AND status = 'open'",
            params![batch.id, now.to_rfc3339(), expires.to_rfc3339()],
        )
    })?;
    batch.status = "complete".into();
    batch.expires_at = Some(expires);
    tracing::info!(batch = %batch.id, "export batch complete");
    Ok(Json(batch_status(&state, batch)?))
}

// ----- download -----

fn build_zip(dir: &FsPath, items: &[ItemRow], out: &FsPath) -> Result<(), AppError> {
    let file = std::fs::File::create(out)?;
    let mut zip = zip::ZipWriter::new(std::io::BufWriter::new(file));
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .large_file(true);
    let mut used = std::collections::HashSet::new();
    let manifest = dir.join("manifest.json");
    if manifest.is_file() {
        used.insert("manifest.json".to_string());
        zip.start_file("manifest.json", opts)
            .map_err(|e| AppError::internal(format!("zip: {e}")))?;
        let mut src = std::fs::File::open(&manifest)?;
        std::io::copy(&mut src, &mut zip)?;
    }
    for item in items {
        if item.bytes_stored.is_none() {
            continue;
        }
        let mut name = item.filename.clone();
        if !used.insert(name.clone()) {
            name = format!("{}-{}", &item.id[..8], item.filename);
            used.insert(name.clone());
        }
        zip.start_file(name, opts)
            .map_err(|e| AppError::internal(format!("zip: {e}")))?;
        let mut src = std::fs::File::open(dir.join(&item.id))?;
        std::io::copy(&mut src, &mut zip)?;
    }
    let mut inner = zip
        .finish()
        .map_err(|e| AppError::internal(format!("zip: {e}")))?;
    inner.flush()?;
    Ok(())
}

pub async fn download(
    State(state): State<AppState>,
    Auth(acct): Auth,
    Path(batch): Path<String>,
) -> Result<Response, AppError> {
    let batch = owned_batch(&state, &acct.id, &batch)?;
    if batch.status != "complete" {
        return Err(AppError::conflict(
            if batch.status == "open" {
                "batch_not_complete"
            } else {
                "batch_expired"
            },
            format!("batch is {}", batch.status),
        ));
    }
    let items = state.db.with(|c| load_items(c, &batch.id))?;
    let dir = batch_dir(&state, &batch.id);
    let zip_path = dir.join("download.zip");
    if tokio::fs::metadata(&zip_path).await.is_err() {
        let (dir2, zip2) = (dir.clone(), zip_path.clone());
        tokio::task::spawn_blocking(move || build_zip(&dir2, &items, &zip2))
            .await
            .map_err(|e| AppError::internal(format!("zip task: {e}")))??;
    }
    let file = tokio::fs::File::open(&zip_path).await?;
    let len = file.metadata().await?.len();
    let filename = format!(
        "{}.zip",
        sanitize_filename(&batch.session_name).replace(' ', "_")
    );
    let disposition = HeaderValue::from_str(&format!("attachment; filename=\"{filename}\""))
        .unwrap_or_else(|_| HeaderValue::from_static("attachment; filename=\"export.zip\""));
    let body = Body::from_stream(ReaderStream::new(file));
    Ok((
        StatusCode::OK,
        [
            (
                header::CONTENT_TYPE,
                HeaderValue::from_static("application/zip"),
            ),
            (
                header::CONTENT_LENGTH,
                HeaderValue::from_str(&len.to_string())
                    .map_err(|e| AppError::internal(e.to_string()))?,
            ),
            (header::CONTENT_DISPOSITION, disposition),
        ],
        body,
    )
        .into_response())
}

// ----- expiry -----

/// Deletes files and marks every batch whose `expires_at` has passed. Returns
/// how many batches were expired.
pub async fn expire_once(state: &AppState, now: DateTime<Utc>) -> Result<usize, AppError> {
    let due: Vec<String> = state.db.with(|c| {
        let mut stmt = c.prepare(
            "SELECT id FROM export_batches WHERE status != 'expired' AND expires_at <= ?1",
        )?;
        let rows = stmt.query_map([now.to_rfc3339()], |r| r.get::<_, String>(0))?;
        rows.collect()
    })?;
    for id in &due {
        let dir = batch_dir(state, id);
        if let Err(e) = tokio::fs::remove_dir_all(&dir).await {
            if e.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(batch = %id, error = %e, "could not remove export directory");
            }
        }
        state.db.with(|c| {
            c.execute(
                "UPDATE export_batches SET status = 'expired' WHERE id = ?1",
                [id],
            )
        })?;
        tracing::info!(batch = %id, "export batch expired");
    }
    Ok(due.len())
}

pub async fn expiry_loop(state: AppState, every: StdDuration) {
    let mut tick = tokio::time::interval(every);
    loop {
        tick.tick().await;
        if let Err(e) = expire_once(&state, Utc::now()).await {
            tracing::error!(error = %e, "export expiry sweep failed");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::sanitize_filename;

    #[test]
    fn filenames_are_basenames() {
        assert_eq!(sanitize_filename("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("C:\\shoot\\IMG_0001.JPG"), "IMG_0001.JPG");
        assert_eq!(sanitize_filename("   "), "item");
        assert_eq!(sanitize_filename(".hidden"), "hidden");
        assert_eq!(sanitize_filename("a:b*c.jpg"), "abc.jpg");
    }
}
