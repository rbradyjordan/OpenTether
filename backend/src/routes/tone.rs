//! `POST /v1/tone/color-match`: multipart reference + target → per-account
//! `match` LUT. Charges one credit on the free tier.

use axum::extract::{Multipart, State};
use axum::http::StatusCode;
use axum::Json;
use chrono::Utc;
use rusqlite::params;
use serde::Serialize;
use uuid::Uuid;

use crate::auth::Auth;
use crate::colormatch::{color_match as run_match, decode_small, MatchError};
use crate::db::Tier;
use crate::error::AppError;
use crate::looks::{Lut3d, Rgb};
use crate::routes::looks::{cube_url, insert_look, NewLook};
use crate::AppState;

pub const UPLOAD_LIMIT: usize = 12 * 1024 * 1024;
/// Two 12 MiB images plus headroom for the small text fields.
pub const MULTIPART_LIMIT: usize = 2 * UPLOAD_LIMIT + 64 * 1024;

#[derive(Serialize)]
pub struct Stats {
    pub reference_mean: Rgb,
    pub target_mean: Rgb,
    pub matched_mean: Rgb,
}

#[derive(Serialize)]
pub struct ColorMatchResponse {
    pub lut_id: String,
    pub cube_url: String,
    pub sha256: String,
    pub credits_charged: i64,
    pub credits_remaining: i64,
    pub stats: Stats,
}

fn multipart_err(e: axum::extract::multipart::MultipartError) -> AppError {
    if e.status() == StatusCode::PAYLOAD_TOO_LARGE {
        AppError::payload_too_large("each image must be 12 MiB or smaller")
    } else {
        AppError::bad_request("invalid_multipart", e.body_text())
    }
}

pub async fn color_match_handler(
    state: AppState,
    acct: crate::db::Account,
    mut parts: Multipart,
) -> Result<Json<ColorMatchResponse>, AppError> {
    if acct.tier == Tier::Free && acct.credits <= 0 {
        return Err(AppError::insufficient_credits());
    }

    let mut reference: Option<Vec<u8>> = None;
    let mut target: Option<Vec<u8>> = None;
    let mut strength = 1.0f32;
    let mut lut_size = 33usize;

    while let Some(field) = parts.next_field().await.map_err(multipart_err)? {
        let name = field.name().unwrap_or("").to_string();
        match name.as_str() {
            "reference" | "target" => {
                let bytes = field.bytes().await.map_err(multipart_err)?;
                if bytes.len() > UPLOAD_LIMIT {
                    return Err(AppError::payload_too_large(format!(
                        "{name} exceeds 12 MiB"
                    )));
                }
                if bytes.is_empty() {
                    return Err(AppError::bad_request(
                        "empty_image",
                        format!("{name} is empty"),
                    ));
                }
                if name == "reference" {
                    reference = Some(bytes.to_vec());
                } else {
                    target = Some(bytes.to_vec());
                }
            }
            "strength" => {
                let text = field.text().await.map_err(multipart_err)?;
                strength = text
                    .trim()
                    .parse::<f32>()
                    .ok()
                    .filter(|s| (0.0..=1.0).contains(s))
                    .ok_or_else(|| {
                        AppError::bad_request(
                            "invalid_strength",
                            "strength must be a number in 0..1",
                        )
                    })?;
            }
            "lut_size" => {
                let text = field.text().await.map_err(multipart_err)?;
                lut_size = match text.trim() {
                    "17" => 17,
                    "33" => 33,
                    _ => {
                        return Err(AppError::bad_request(
                            "invalid_lut_size",
                            "lut_size must be 17 or 33",
                        ))
                    }
                };
            }
            _ => {
                // Unknown fields are drained and ignored.
                let _ = field.bytes().await.map_err(multipart_err)?;
            }
        }
    }
    let reference = reference
        .ok_or_else(|| AppError::bad_request("missing_field", "reference image is required"))?;
    let target =
        target.ok_or_else(|| AppError::bad_request("missing_field", "target image is required"))?;

    let result = tokio::task::spawn_blocking(move || -> Result<_, MatchError> {
        let r = decode_small(&reference, "reference")?;
        let t = decode_small(&target, "target")?;
        run_match(&r, &t, strength, lut_size)
    })
    .await
    .map_err(|e| AppError::internal(format!("colour match task: {e}")))?
    .map_err(|e| match e {
        MatchError::Decode { .. } => AppError::bad_request("invalid_image", e.to_string()),
        MatchError::BadLutSize => AppError::bad_request("invalid_lut_size", e.to_string()),
        MatchError::BadStrength => AppError::bad_request("invalid_strength", e.to_string()),
    })?;

    let lut_id = Uuid::new_v4().to_string();
    let name = format!("Match {}", Utc::now().format("%Y-%m-%d %H:%M"));
    let cube = result.lut.to_cube(&name);
    let sha = Lut3d::sha256_hex_of(&cube);

    // Charge and store atomically; the balance is re-read inside the transaction.
    let account_id = acct.id.clone();
    let (charged, remaining) = state.db.transaction(|c| {
        let fresh =
            crate::db::load_account(c, "SELECT * FROM accounts WHERE id = ?1", &account_id)?
                .ok_or_else(AppError::unauthorized)?;
        let charged = if fresh.tier == Tier::Free {
            if fresh.credits <= 0 {
                return Err(AppError::insufficient_credits());
            }
            1
        } else {
            0
        };
        c.execute(
            "UPDATE accounts SET credits = credits - ?2 WHERE id = ?1",
            params![account_id, charged],
        )?;
        insert_look(
            c,
            &NewLook {
                id: &lut_id,
                name: &name,
                family: "match",
                size: result.lut.size,
                cube: &cube,
                sha256: &sha,
                account_id: &account_id,
            },
        )?;
        Ok((charged, fresh.credits - charged))
    })?;

    tracing::info!(account = %acct.id, lut = %lut_id, charged, "colour match stored");
    Ok(Json(ColorMatchResponse {
        cube_url: cube_url(&lut_id),
        lut_id,
        sha256: sha,
        credits_charged: charged,
        credits_remaining: remaining,
        stats: Stats {
            reference_mean: result.reference_mean,
            target_mean: result.target_mean,
            matched_mean: result.matched_mean,
        },
    }))
}

pub async fn color_match(
    State(state): State<AppState>,
    Auth(acct): Auth,
    parts: Multipart,
) -> Result<Json<ColorMatchResponse>, AppError> {
    color_match_handler(state, acct, parts).await
}
