//! Tested-camera matrix, served verbatim from `data/tested-cameras.json`
//! (compiled into the binary).

use axum::extract::State;
use axum::Json;
use serde_json::Value;

use crate::error::AppError;
use crate::AppState;

const RAW: &str = include_str!("../../data/tested-cameras.json");

pub fn load() -> Result<Value, AppError> {
    let v: Value = serde_json::from_str(RAW)
        .map_err(|e| AppError::internal(format!("tested-cameras.json: {e}")))?;
    if v.get("updated_at").and_then(Value::as_str).is_none()
        || v.get("cameras").and_then(Value::as_array).is_none()
    {
        return Err(AppError::internal(
            "tested-cameras.json needs updated_at and cameras",
        ));
    }
    Ok(v)
}

pub async fn tested(State(state): State<AppState>) -> Json<Value> {
    Json((*state.cameras).clone())
}
