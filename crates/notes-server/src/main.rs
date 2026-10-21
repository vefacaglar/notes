use std::error::Error;
use tracing::info;

use notes_server::config::ServerConfig;
use notes_server::storage::ServerStore;
use notes_server::{build_router, AppState};

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // Tracing loglama sistemini başlat
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "notes_server=info,tower_http=info".into()),
        )
        .init();

    let config = ServerConfig::from_env();
    let addr = config.socket_addr()?;

    // SQLite deposunu yapılandır
    let store = match &config.database_path {
        Some(path) => {
            info!("SQLite veritabanı açılıyor: {:?}", path);
            ServerStore::open_path(path)?
        }
        None => {
            info!("Geçici bellek içi (in-memory) SQLite veritabanı kullanılıyor");
            ServerStore::open_in_memory()?
        }
    };

    let state = AppState::new(config, store);
    let app = build_router(state);

    info!("Notes Zero-Knowledge Cloud API dinleniyor: http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
