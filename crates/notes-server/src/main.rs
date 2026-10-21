use axum::{routing::get, Router};
use std::net::SocketAddr;
use tracing::info;

async fn health_check() -> &'static str {
    "OK"
}

pub fn app() -> Router {
    Router::new().route("/health", get(health_check))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    info!("Notes Server dinleniyor: {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app()).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_app_router_creation() {
        let _ = app();
    }
}
