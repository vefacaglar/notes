//! HTTP ve bellek içi senkronizasyon taşıma katmanı (`http_client`).
//!
//! Bu modül, sıfır-bilgi (Zero-Knowledge) şifreli zarfların (`EncryptedUpdateEnvelope`)
//! istemci ile sunucu arasında aktarılması için `SyncTransport` trait'ini,
//! üretim ortamı için `ReqwestSyncTransport` ve testler için `InMemorySyncTransport` sağlar.

use std::sync::Arc;
use std::time::Duration;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::error::{Result, SyncError};
use crate::protocol::{
    EncryptedUpdateEnvelope, SyncPullRequest, SyncPullResponse, SyncPushRequest, SyncPushResponse,
};

/// Senkronizasyon istemcisi yapılandırma parametreleri.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncClientConfig {
    /// Senkronizasyon sunucusunun temel URL adresi (örn. "http://127.0.0.1:3000")
    pub server_url: String,
    /// İsteğe bağlı taşıyıcı yetkilendirme belirteci (AuthKey / Bearer Token)
    pub auth_token: Option<String>,
    /// İstemci cihazın benzersiz tanımlayıcısı
    pub device_id: String,
    /// HTTP istek zaman aşımı süresi (milisaniye)
    pub timeout_ms: u64,
}

impl Default for SyncClientConfig {
    fn default() -> Self {
        Self {
            server_url: "http://127.0.0.1:3000".to_string(),
            auth_token: None,
            device_id: Uuid::new_v4().to_string(),
            timeout_ms: 10_000,
        }
    }
}

impl SyncClientConfig {
    /// Yeni bir yapılandırma örneği oluşturur.
    pub fn new(server_url: impl Into<String>, device_id: impl Into<String>) -> Self {
        Self {
            server_url: server_url.into().trim_end_matches('/').to_string(),
            auth_token: None,
            device_id: device_id.into(),
            timeout_ms: 10_000,
        }
    }

    /// Yetkilendirme belirteci ekler.
    pub fn with_auth_token(mut self, token: impl Into<String>) -> Self {
        self.auth_token = Some(token.into());
        self
    }

    /// Zaman aşımı süresini (ms) belirler.
    pub fn with_timeout_ms(mut self, timeout_ms: u64) -> Self {
        self.timeout_ms = timeout_ms;
        self
    }
}

/// Senkronizasyon taşıma katmanı trait'i.
#[async_trait]
pub trait SyncTransport: Send + Sync {
    /// Şifreli zarfları toplu olarak sunucuya iletir (Push).
    async fn push_envelopes(&self, request: &SyncPushRequest) -> Result<SyncPushResponse>;

    /// İstemcideki durum parametrelerine göre sunucudan eksik zarfları talep eder (Pull).
    async fn pull_envelopes(&self, request: &SyncPullRequest) -> Result<SyncPullResponse>;

    /// Sunucunun ayakta olup olmadığını kontrol eder (`GET /health`).
    async fn check_health(&self) -> Result<bool>;
}

/// `reqwest` tabanlı gerçek HTTP senkronizasyon taşıyıcısı.
#[derive(Debug, Clone)]
pub struct ReqwestSyncTransport {
    config: SyncClientConfig,
    client: reqwest::Client,
}

impl ReqwestSyncTransport {
    /// Yapılandırmadan yeni bir `ReqwestSyncTransport` örneği türetir.
    pub fn new(config: SyncClientConfig) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_millis(config.timeout_ms))
            .build()?;

        Ok(Self { config, client })
    }

    /// Önceden özelleştirilmiş `reqwest::Client` ile taşıyıcı oluşturur.
    pub fn with_client(config: SyncClientConfig, client: reqwest::Client) -> Self {
        Self { config, client }
    }

    /// Mevcut istemci yapılandırmasını döndürür.
    pub fn config(&self) -> &SyncClientConfig {
        &self.config
    }

    /// İstek oluşturucuya X-Device-Id, User-Agent ve tanımlıysa Bearer auth ekler.
    pub fn prepare_headers(&self, req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        let mut builder = req
            .header("X-Device-Id", &self.config.device_id)
            .header("User-Agent", format!("notes-sync/{}", env!("CARGO_PKG_VERSION")));

        if let Some(token) = &self.config.auth_token {
            builder = builder.bearer_auth(token);
        }

        builder
    }
}

#[async_trait]
impl SyncTransport for ReqwestSyncTransport {
    async fn push_envelopes(&self, request: &SyncPushRequest) -> Result<SyncPushResponse> {
        let url = format!("{}/api/v1/sync/push", self.config.server_url.trim_end_matches('/'));
        let req = self.client.post(&url).json(request);
        let req = self.prepare_headers(req);

        let response = req.send().await?;
        let status = response.status();

        if status.is_success() {
            let result = response.json::<SyncPushResponse>().await?;
            Ok(result)
        } else {
            let message = response.text().await.unwrap_or_else(|_| "Bilinmeyen sunucu hatası".to_string());
            Err(SyncError::Server {
                status: status.as_u16(),
                message,
            })
        }
    }

    async fn pull_envelopes(&self, request: &SyncPullRequest) -> Result<SyncPullResponse> {
        let url = format!("{}/api/v1/sync/pull", self.config.server_url.trim_end_matches('/'));
        let req = self.client.post(&url).json(request);
        let req = self.prepare_headers(req);

        let response = req.send().await?;
        let status = response.status();

        if status.is_success() {
            let result = response.json::<SyncPullResponse>().await?;
            Ok(result)
        } else {
            let message = response.text().await.unwrap_or_else(|_| "Bilinmeyen sunucu hatası".to_string());
            Err(SyncError::Server {
                status: status.as_u16(),
                message,
            })
        }
    }

    async fn check_health(&self) -> Result<bool> {
        let url = format!("{}/health", self.config.server_url.trim_end_matches('/'));
        let req = self.client.get(&url);
        let req = self.prepare_headers(req);

        match req.send().await {
            Ok(res) => Ok(res.status().is_success()),
            Err(e) => {
                tracing::warn!("Sağlık kontrolü başarısız: {}", e);
                Ok(false)
            }
        }
    }
}

/// Testler ve çevrimdışı simülasyonlar için bellek içi mock senkronizasyon taşıyıcısı.
#[derive(Debug, Default, Clone)]
pub struct InMemorySyncTransport {
    healthy: Arc<RwLock<bool>>,
    envelopes: Arc<RwLock<Vec<EncryptedUpdateEnvelope>>>,
}

impl InMemorySyncTransport {
    /// Boş ve sağlıklı durumda bir `InMemorySyncTransport` oluşturur.
    pub fn new() -> Self {
        Self {
            healthy: Arc::new(RwLock::new(true)),
            envelopes: Arc::new(RwLock::new(Vec::new())),
        }
    }

    /// Sunucu sağlık durumunu simüle eder.
    pub async fn set_healthy(&self, is_healthy: bool) {
        let mut h = self.healthy.write().await;
        *h = is_healthy;
    }

    /// Belleğe doğrudan zarf ekler.
    pub async fn insert_envelopes(&self, items: impl IntoIterator<Item = EncryptedUpdateEnvelope>) {
        let mut envs = self.envelopes.write().await;
        envs.extend(items);
    }

    /// Bellekte kayıtlı tüm zarfları listeler.
    pub async fn get_stored_envelopes(&self) -> Vec<EncryptedUpdateEnvelope> {
        let envs = self.envelopes.read().await;
        envs.clone()
    }

    /// Bellekteki tüm zarfları temizler.
    pub async fn clear(&self) {
        let mut envs = self.envelopes.write().await;
        envs.clear();
    }
}

#[async_trait]
impl SyncTransport for InMemorySyncTransport {
    async fn push_envelopes(&self, request: &SyncPushRequest) -> Result<SyncPushResponse> {
        if !*self.healthy.read().await {
            return Err(SyncError::Transport("Mock sunucu erişilemez durumda".into()));
        }

        let mut stored = self.envelopes.write().await;
        let mut accepted_ids = Vec::with_capacity(request.envelopes.len());

        for env in &request.envelopes {
            if !stored.iter().any(|existing| existing.id == env.id) {
                stored.push(env.clone());
            }
            accepted_ids.push(env.id);
        }

        Ok(SyncPushResponse {
            workspace_id: request.workspace_id,
            accepted_ids,
            rejected_ids: Vec::new(),
        })
    }

    async fn pull_envelopes(&self, request: &SyncPullRequest) -> Result<SyncPullResponse> {
        if !*self.healthy.read().await {
            return Err(SyncError::Transport("Mock sunucu erişilemez durumda".into()));
        }

        let stored = self.envelopes.read().await;
        let filtered: Vec<EncryptedUpdateEnvelope> = stored
            .iter()
            .filter(|env| {
                if env.workspace_id != request.workspace_id {
                    return false;
                }
                if let Some(doc_ids) = &request.doc_ids {
                    if !doc_ids.contains(&env.doc_id) {
                        return false;
                    }
                }
                if let Some(since) = request.since_timestamp {
                    if env.created_at <= since {
                        return false;
                    }
                }
                true
            })
            .cloned()
            .collect();

        let latest = filtered.iter().map(|e| e.created_at).max().unwrap_or(0);

        Ok(SyncPullResponse {
            workspace_id: request.workspace_id,
            envelopes: filtered,
            has_more: false,
            latest_timestamp: latest,
        })
    }

    async fn check_health(&self) -> Result<bool> {
        let h = *self.healthy.read().await;
        Ok(h)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_in_memory_sync_transport_health() {
        let transport = InMemorySyncTransport::new();
        assert!(transport.check_health().await.unwrap());

        transport.set_healthy(false).await;
        assert!(!transport.check_health().await.unwrap());
    }

    #[tokio::test]
    async fn test_in_memory_sync_transport_push_pull() {
        let transport = InMemorySyncTransport::new();
        let ws_id = Uuid::new_v4();
        let doc_id = Uuid::new_v4();

        let env1 = EncryptedUpdateEnvelope {
            id: Uuid::new_v4(),
            workspace_id: ws_id,
            doc_id,
            client_id: 1,
            clock_sequence: 1,
            nonce: [1u8; 24],
            ciphertext: vec![10, 20, 30],
            created_at: 1700000000000,
        };

        let env2 = EncryptedUpdateEnvelope {
            id: Uuid::new_v4(),
            workspace_id: ws_id,
            doc_id,
            client_id: 1,
            clock_sequence: 2,
            nonce: [2u8; 24],
            ciphertext: vec![40, 50, 60],
            created_at: 1700000001000,
        };

        let push_req = SyncPushRequest::new(ws_id, 1, vec![env1.clone(), env2.clone()]);
        let push_res = transport.push_envelopes(&push_req).await.unwrap();
        assert_eq!(push_res.workspace_id, ws_id);
        assert_eq!(push_res.accepted_ids.len(), 2);
        assert_eq!(push_res.accepted_ids[0], env1.id);
        assert_eq!(push_res.accepted_ids[1], env2.id);

        let pull_req = SyncPullRequest {
            workspace_id: ws_id,
            doc_ids: None,
            since_timestamp: None,
            limit: None,
        };

        let pull_res = transport.pull_envelopes(&pull_req).await.unwrap();
        assert_eq!(pull_res.workspace_id, ws_id);
        assert_eq!(pull_res.envelopes.len(), 2);
        assert_eq!(pull_res.envelopes[0].id, env1.id);
        assert_eq!(pull_res.envelopes[1].id, env2.id);
    }

    #[tokio::test]
    async fn test_in_memory_sync_transport_unhealthy_errors() {
        let transport = InMemorySyncTransport::new();
        transport.set_healthy(false).await;

        let push_req = SyncPushRequest::new(Uuid::new_v4(), 1, vec![]);
        let res = transport.push_envelopes(&push_req).await;
        assert!(res.is_err());

        let pull_req = SyncPullRequest {
            workspace_id: Uuid::new_v4(),
            doc_ids: None,
            since_timestamp: None,
            limit: None,
        };
        let pull_res = transport.pull_envelopes(&pull_req).await;
        assert!(pull_res.is_err());
    }

    #[test]
    fn test_sync_client_config() {
        let config = SyncClientConfig::new("https://sync.example.com/", "test-device")
            .with_auth_token("secret-token")
            .with_timeout_ms(5000);

        assert_eq!(config.server_url, "https://sync.example.com");
        assert_eq!(config.device_id, "test-device");
        assert_eq!(config.auth_token, Some("secret-token".to_string()));
        assert_eq!(config.timeout_ms, 5000);
    }

    #[test]
    fn test_reqwest_transport_instantiation() {
        let config = SyncClientConfig::default();
        let transport = ReqwestSyncTransport::new(config);
        assert!(transport.is_ok());
    }

    #[test]
    fn test_reqwest_transport_bearer_auth_and_device_id_headers() {
        let config = SyncClientConfig::new("https://sync.example.com", "device-abc-123")
            .with_auth_token("test-bearer-token-xyz");
        let transport = ReqwestSyncTransport::new(config).unwrap();

        let dummy_url = "https://sync.example.com/test";
        let req_builder = transport.client.get(dummy_url);
        let prepared = transport.prepare_headers(req_builder);
        let req = prepared.build().unwrap();

        let device_header = req.headers().get("X-Device-Id").unwrap();
        assert_eq!(device_header.to_str().unwrap(), "device-abc-123");

        let auth_header = req.headers().get("Authorization").unwrap();
        assert_eq!(auth_header.to_str().unwrap(), "Bearer test-bearer-token-xyz");

        let user_agent = req.headers().get("User-Agent").unwrap();
        assert!(user_agent.to_str().unwrap().starts_with("notes-sync/"));
    }
}
