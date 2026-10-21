use std::net::SocketAddr;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub database_path: Option<PathBuf>,
    pub broadcast_capacity: usize,
    pub token_ttl_seconds: i64,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 3000,
            database_path: None,
            broadcast_capacity: 1024,
            token_ttl_seconds: 86400, // 24 saat
        }
    }
}

impl ServerConfig {
    /// Çevre değişkenlerinden (`HOST`, `PORT`, `NOTES_DB_PATH`) konfigürasyon üretir.
    pub fn from_env() -> Self {
        let mut config = Self::default();

        if let Ok(host) = std::env::var("HOST") {
            config.host = host;
        }

        if let Ok(port_str) = std::env::var("PORT") {
            if let Ok(port) = port_str.parse::<u16>() {
                config.port = port;
            }
        }

        if let Ok(db_path) = std::env::var("NOTES_DB_PATH") {
            config.database_path = Some(PathBuf::from(db_path));
        }

        if let Ok(ttl_str) = std::env::var("TOKEN_TTL_SECONDS") {
            if let Ok(ttl) = ttl_str.parse::<i64>() {
                config.token_ttl_seconds = ttl;
            }
        }

        config
    }

    /// Sunucunun dinleyeceği `SocketAddr` adresini döner.
    pub fn socket_addr(&self) -> Result<SocketAddr, std::net::AddrParseError> {
        let addr_str = format!("{}:{}", self.host, self.port);
        addr_str.parse()
    }
}
