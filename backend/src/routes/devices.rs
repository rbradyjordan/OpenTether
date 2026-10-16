use axum::extract::State;
use axum::Json;
use chrono::{Months, Utc};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::{hash_token, new_token};
use crate::db::{Account, Credits, Tier, FREE_MONTHLY_GRANT};
use crate::error::{AppError, Json as AppJson};
use crate::AppState;

#[derive(Deserialize)]
pub struct RegisterBody {
    pub device_id: String,
    pub platform: String,
    pub app_version: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub token: String,
    pub account_id: String,
    pub tier: Tier,
    pub credits: Credits,
}

/// One account per `device_id`; re-registering rotates the token.
pub async fn register(
    State(state): State<AppState>,
    AppJson(body): AppJson<RegisterBody>,
) -> Result<Json<RegisterResponse>, AppError> {
    let device_id = Uuid::parse_str(body.device_id.trim())
        .map_err(|_| AppError::bad_request("invalid_device_id", "device_id must be a UUID"))?
        .to_string();
    if body.platform != "ios" {
        return Err(AppError::bad_request(
            "unsupported_platform",
            "platform must be \"ios\"",
        ));
    }
    if body.app_version.trim().is_empty() || body.app_version.len() > 32 {
        return Err(AppError::bad_request(
            "invalid_app_version",
            "app_version is required",
        ));
    }

    let token = new_token();
    let token_hash = hash_token(&token);
    let now = Utc::now();

    let account = state.db.transaction(|c| {
        let existing = crate::db::load_account(c, "SELECT * FROM accounts WHERE device_id = ?1", &device_id)?;
        let account = match existing {
            Some(acct) => {
                c.execute(
                    "UPDATE accounts SET platform = ?2, app_version = ?3 WHERE id = ?1",
                    params![acct.id, body.platform, body.app_version],
                )?;
                acct
            }
            None => {
                let id = Uuid::new_v4().to_string();
                let renews_at = now
                    .checked_add_months(Months::new(1))
                    .unwrap_or(now + chrono::Duration::days(30));
                c.execute(
                    "INSERT INTO accounts (id, device_id, platform, app_version, tier, credits, monthly_grant, renews_at, created_at)
                     VALUES (?1, ?2, ?3, ?4, 'free', ?5, ?5, ?6, ?7)",
                    params![id, device_id, body.platform, body.app_version, FREE_MONTHLY_GRANT, renews_at.to_rfc3339(), now.to_rfc3339()],
                )?;
                Account {
                    id,
                    device_id: device_id.clone(),
                    tier: Tier::Free,
                    credits: FREE_MONTHLY_GRANT,
                    monthly_grant: FREE_MONTHLY_GRANT,
                    renews_at: Some(renews_at),
                    pro_until: None,
                }
            }
        };
        // Revoke every previous token for this account, then issue the new one.
        c.execute("DELETE FROM tokens WHERE account_id = ?1", [&account.id])?;
        c.execute(
            "INSERT INTO tokens (token_hash, account_id, created_at) VALUES (?1, ?2, ?3)",
            params![token_hash, account.id, now.to_rfc3339()],
        )?;
        Ok(account)
    })?;
    let account = state.db.refresh_account(account, now)?;

    tracing::info!(account = %account.id, "device registered");
    Ok(Json(RegisterResponse {
        token,
        account_id: account.id.clone(),
        tier: account.tier,
        credits: account.credits_json(),
    }))
}
