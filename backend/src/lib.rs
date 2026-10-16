//! Tether cloud backend: looks catalog, colour-match LUTs, credits ledger,
//! batch export and the tested-camera matrix. `main.rs` wires config and the
//! background expiry task around [`router`].

pub mod auth;
pub mod colormatch;
pub mod db;
pub mod error;
pub mod looks;
pub mod routes;
pub mod watermark;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post, put};
use axum::Router;
use tower_http::trace::TraceLayer;

use crate::db::Db;
use crate::error::AppError;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const JSON_BODY_LIMIT: usize = 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Config {
    pub bind: SocketAddr,
    pub db_path: PathBuf,
    pub storage: PathBuf,
    pub dev_purchases: bool,
    pub admin_token: Option<String>,
}

impl Config {
    pub fn from_env() -> Result<Self, AppError> {
        let bind = std::env::var("TETHER_BIND")
            .unwrap_or_else(|_| "127.0.0.1:8787".into())
            .parse()
            .map_err(|e| AppError::internal(format!("TETHER_BIND: {e}")))?;
        let truthy = |v: String| matches!(v.trim(), "1" | "true" | "yes" | "on");
        Ok(Self {
            bind,
            db_path: std::env::var("TETHER_DB")
                .unwrap_or_else(|_| "./data/tether.db".into())
                .into(),
            storage: std::env::var("TETHER_STORAGE")
                .unwrap_or_else(|_| "./data/storage".into())
                .into(),
            dev_purchases: std::env::var("TETHER_DEV_PURCHASES")
                .map(truthy)
                .unwrap_or(false),
            admin_token: std::env::var("TETHER_ADMIN_TOKEN")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        })
    }
}

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub config: Arc<Config>,
    pub cameras: Arc<serde_json::Value>,
}

impl AppState {
    /// Opens the database, runs migrations, seeds the looks catalog and
    /// creates the storage directories.
    pub fn new(config: Config) -> Result<Self, AppError> {
        let db = Db::open(&config.db_path)?;
        std::fs::create_dir_all(config.storage.join("exports"))?;
        routes::looks::seed_catalog(&db)?;
        let cameras = routes::cameras::load()?;
        Ok(Self {
            db,
            config: Arc::new(config),
            cameras: Arc::new(cameras),
        })
    }
}

/// The item PUT/HEAD route carries its own 200 MiB streaming limit instead of
/// the 1 MiB JSON default.
fn item_routes() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/exports/{batch}/items/{item}",
            put(routes::exports::put_item).head(routes::exports::head_item),
        )
        .layer(DefaultBodyLimit::disable())
        .layer(tower_http::limit::RequestBodyLimitLayer::new(
            routes::exports::ITEM_LIMIT,
        ))
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(routes::healthz))
        .route("/v1/devices/register", post(routes::devices::register))
        .route("/v1/me", get(routes::me::me))
        .route("/v1/looks", get(routes::looks::list))
        .route("/v1/looks/{file}", get(routes::looks::cube))
        .route(
            "/v1/tone/color-match",
            post(routes::tone::color_match)
                .layer(DefaultBodyLimit::max(routes::tone::MULTIPART_LIMIT)),
        )
        .route("/v1/exports/batch", post(routes::exports::create_batch))
        .route("/v1/exports/{batch}", get(routes::exports::get_batch))
        .route(
            "/v1/exports/{batch}/complete",
            post(routes::exports::complete),
        )
        .route(
            "/v1/exports/{batch}/download",
            get(routes::exports::download),
        )
        .merge(item_routes())
        .route("/v1/credits/purchase", post(routes::credits::purchase))
        .route(
            "/v1/admin/credits/grant",
            post(routes::credits::admin_grant),
        )
        .route("/v1/cameras/tested", get(routes::cameras::tested))
        .fallback(error::fallback_404)
        .layer(DefaultBodyLimit::max(JSON_BODY_LIMIT))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
