use axum::Json;
use serde::Serialize;

use crate::auth::Auth;
use crate::db::{Credits, Tier};

#[derive(Serialize)]
pub struct MeResponse {
    pub account_id: String,
    pub tier: Tier,
    pub credits: Credits,
    pub watermark_required: bool,
}

pub async fn me(Auth(acct): Auth) -> Json<MeResponse> {
    Json(MeResponse {
        account_id: acct.id.clone(),
        tier: acct.tier,
        credits: acct.credits_json(),
        watermark_required: acct.watermark_required(),
    })
}
