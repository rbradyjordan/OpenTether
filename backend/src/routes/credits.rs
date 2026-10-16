//! Credits: App Store purchases (dev mode or 501) and the admin grant.

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{Duration, Utc};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::auth::{Admin, Auth};
use crate::db::{load_account, Credits, Tier};
use crate::error::{AppError, Json as AppJson};
use crate::AppState;

pub const PRO_DAYS: i64 = 31;

#[derive(Deserialize)]
pub struct PurchaseBody {
    pub product_id: String,
    pub transaction_id: String,
    #[serde(default)]
    pub signed_transaction: Option<String>,
}

#[derive(Serialize)]
pub struct PurchaseResponse {
    pub tier: Tier,
    pub credits: Credits,
    pub replayed: bool,
}

#[derive(Debug, Clone, Copy)]
enum Product {
    Credits50,
    Credits200,
    ProMonthly,
}

impl Product {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "credits_50" => Some(Self::Credits50),
            "credits_200" => Some(Self::Credits200),
            "pro_monthly" => Some(Self::ProMonthly),
            _ => None,
        }
    }
}

pub async fn purchase(
    State(state): State<AppState>,
    Auth(acct): Auth,
    AppJson(body): AppJson<PurchaseBody>,
) -> Result<Json<Value>, AppError> {
    let product = Product::parse(&body.product_id).ok_or_else(|| {
        AppError::bad_request(
            "unknown_product",
            "product_id must be credits_50, credits_200 or pro_monthly",
        )
    })?;
    let tx_id = body.transaction_id.trim().to_string();
    if tx_id.is_empty() || tx_id.len() > 256 {
        return Err(AppError::bad_request(
            "invalid_transaction_id",
            "transaction_id is required",
        ));
    }

    // Replay check first: an idempotent retry must succeed even if the server
    // configuration changed in between.
    let replay = state.db.with(|c| {
        c.query_row(
            "SELECT account_id, response_json FROM purchases WHERE transaction_id = ?1",
            [&tx_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
    })?;
    if let Some((owner, stored)) = replay {
        if owner != acct.id {
            return Err(AppError::conflict(
                "transaction_conflict",
                "transaction_id belongs to another account",
            ));
        }
        let mut v: Value =
            serde_json::from_str(&stored).map_err(|e| AppError::internal(e.to_string()))?;
        v["replayed"] = Value::Bool(true);
        return Ok(Json(v));
    }

    if !state.config.dev_purchases {
        // TODO(app-store-server-api): verify `body.signed_transaction` (a JWS
        // from StoreKit 2 / App Store Server API): check the certificate chain
        // against Apple's root, decode the payload, confirm bundleId,
        // productId == body.product_id, transactionId == body.transaction_id and
        // that the transaction is not revoked, then fall through to the apply
        // step below. Until then purchases are refused outside dev mode.
        let _ = &body.signed_transaction;
        return Err(AppError::new(
            StatusCode::NOT_IMPLEMENTED,
            "verification_not_configured",
            "App Store receipt verification is not configured on this server",
        ));
    }

    let now = Utc::now();
    let account_id = acct.id.clone();
    let response = state.db.transaction(|c| {
        let fresh = load_account(c, "SELECT * FROM accounts WHERE id = ?1", &account_id)?
            .ok_or_else(AppError::unauthorized)?;
        let (tier, credits, pro_until) = match product {
            Product::Credits50 => (fresh.tier, fresh.credits + 50, fresh.pro_until),
            Product::Credits200 => (fresh.tier, fresh.credits + 200, fresh.pro_until),
            Product::ProMonthly => {
                let base = fresh.pro_until.filter(|t| *t > now && fresh.tier == Tier::Pro).unwrap_or(now);
                (Tier::Pro, fresh.credits, Some(base + Duration::days(PRO_DAYS)))
            }
        };
        c.execute(
            "UPDATE accounts SET tier = ?2, credits = ?3, pro_until = ?4 WHERE id = ?1",
            params![account_id, tier.as_str(), credits, pro_until.map(|t| t.to_rfc3339())],
        )?;
        let response = json!({
            "tier": tier,
            "credits": Credits { balance: credits, monthly_grant: fresh.monthly_grant, renews_at: fresh.renews_at },
            "replayed": false,
        });
        c.execute(
            "INSERT INTO purchases (transaction_id, account_id, product_id, response_json, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![tx_id, account_id, body.product_id, response.to_string(), now.to_rfc3339()],
        )?;
        Ok(response)
    })?;
    tracing::info!(account = %acct.id, product = %body.product_id, "dev purchase applied");
    Ok(Json(response))
}

#[derive(Deserialize)]
pub struct GrantBody {
    pub account_id: String,
    pub credits: i64,
}

#[derive(Serialize)]
pub struct GrantResponse {
    pub account_id: String,
    pub tier: Tier,
    pub credits: Credits,
}

pub async fn admin_grant(
    State(state): State<AppState>,
    _admin: Admin,
    AppJson(body): AppJson<GrantBody>,
) -> Result<Json<GrantResponse>, AppError> {
    if body.credits == 0 || body.credits.abs() > 1_000_000 {
        return Err(AppError::bad_request(
            "invalid_credits",
            "credits must be a non-zero amount up to 1,000,000",
        ));
    }
    let acct = state.db.transaction(|c| {
        let acct = load_account(c, "SELECT * FROM accounts WHERE id = ?1", &body.account_id)?
            .ok_or_else(|| AppError::not_found("account"))?;
        let balance = (acct.credits + body.credits).max(0);
        c.execute(
            "UPDATE accounts SET credits = ?2 WHERE id = ?1",
            params![acct.id, balance],
        )?;
        Ok(crate::db::Account {
            credits: balance,
            ..acct
        })
    })?;
    tracing::info!(account = %acct.id, delta = body.credits, "admin credit grant");
    Ok(Json(GrantResponse {
        account_id: acct.id.clone(),
        tier: acct.tier,
        credits: acct.credits_json(),
    }))
}
