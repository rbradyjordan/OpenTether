pub mod cameras;
pub mod credits;
pub mod devices;
pub mod exports;
pub mod looks;
pub mod me;
pub mod tone;

use axum::Json;
use serde_json::{json, Value};

pub async fn healthz() -> Json<Value> {
    Json(json!({ "ok": true, "version": crate::VERSION }))
}
