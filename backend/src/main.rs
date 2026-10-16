use tether_cloud::{router, AppState, Config};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| "info,tower_http=info".into()),
        )
        .init();

    let config = Config::from_env()?;
    tracing::info!(
        bind = %config.bind,
        db = %config.db_path.display(),
        storage = %config.storage.display(),
        dev_purchases = config.dev_purchases,
        admin = config.admin_token.is_some(),
        version = tether_cloud::VERSION,
        "starting tether-cloud"
    );
    let state = AppState::new(config.clone())?;

    tokio::spawn(tether_cloud::routes::exports::expiry_loop(
        state.clone(),
        std::time::Duration::from_secs(3600),
    ));

    let listener = tokio::net::TcpListener::bind(config.bind).await?;
    tracing::info!(addr = %listener.local_addr()?, "listening");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
            tracing::info!("shutting down");
        })
        .await?;
    Ok(())
}
